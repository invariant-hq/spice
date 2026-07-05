(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax
module Protocol = Spice_provider.Auth.Login.Protocol

let log_src =
  Logs.Src.create "spice.auth" ~doc:"Credential login and refresh flows"

module Log = (val Logs.src_log log_src : Logs.LOG)

let invalid fn message = invalid_arg ("Spice_auth." ^ fn ^ ": " ^ message)

let check_non_empty fn field = function
  | "" -> invalid fn (field ^ " must not be empty")
  | _ -> ()

let check_non_negative fn field value =
  if value < 0 then invalid fn (field ^ " must not be negative")

let user_error_message message =
  match String.split_first ~sep:":" message with
  | None -> message
  | Some (_, rest) -> String.trim rest

module Error = struct
  type t =
    | Invalid_secret of string
    | Invalid_request of string
    | Network of string
    | Protocol of string
    | Rejected of string
    | Timeout of string
    | Not_refreshable

  let oauth2_callback_message = function
    | `Oauth error -> Oauth2.Error.to_string error
    | `Missing field -> "authorization callback missing " ^ field
    | `Duplicate field -> "authorization callback duplicates " ^ field
    | `State_mismatch -> "authorization callback state mismatch"
    | `Redirect_uri_mismatch -> "authorization callback redirect URI mismatch"

  let http_error_message error =
    Format.asprintf "%a" Oauth2_eio.Error.pp_transport error

  let malformed_message context malformed =
    Format.asprintf "%s: %a" context Oauth2.pp_malformed malformed

  let response_message context response =
    Printf.sprintf "%s: HTTP error %d: body length %d" context
      response.Oauth2.Response.status
      (String.length response.Oauth2.Response.body)

  let of_oauth2 = function
    | `Transport error -> Network (http_error_message error)
    | `Oauth error -> Rejected (Oauth2.Error.to_string error)
    | `Malformed malformed ->
        Protocol (malformed_message "malformed OAuth response" malformed)
    | `Http response -> Protocol (response_message "OAuth response" response)

  let message = function
    | Invalid_secret message -> message
    | Invalid_request message -> message
    | Network message -> message
    | Protocol message -> message
    | Rejected message -> message
    | Timeout message -> message
    | Not_refreshable -> "secret is not refreshable"

  let pp ppf error = Format.pp_print_string ppf (message error)
end

module Secret = struct
  let api_key key =
    match Spice_account.Secret.api_key key with
    | secret -> Ok secret
    | exception Invalid_argument message ->
        let message = user_error_message message in
        let message =
          let prefix = "key " in
          if String.starts_with ~prefix message then
            String.drop_first (String.length prefix) message
          else message
        in
        Error (Error.Invalid_secret ("API key " ^ message))

  let timestamp_add seconds now = Int64.add now (Int64.of_int seconds)

  (* Generic OAuth secret construction. Provider-specific interpretation, such
     as extracting OpenAI account ids, lives in {!Openai_chatgpt}. *)
  let oauth_token ~now token =
    let access_token = Oauth2.Token.access_token token in
    let refresh_token = Oauth2.Token.refresh_token token in
    let expires_at =
      Option.map
        (fun seconds -> timestamp_add seconds now)
        (Oauth2.Token.expires_in token)
    in
    Spice_account.Secret.oauth ~access_token ?refresh_token ?expires_at ()
end

module Http = struct
  let tls_client ~stdenv =
    match Oauth2_eio.make_tls_client (Eio.Stdenv.net stdenv) with
    | Ok http -> Ok http
    | Error (`Tls_error message) -> Error (Error.Network message)
end

module Local_callback = struct
  let html_success =
    "<!doctype html><html><body><h1>Authorization successful</h1><p>You can \
     close this window and return to Spice.</p></body></html>"

  let html_error =
    "<!doctype html><html><body><h1>Authorization failed</h1><p>Return to \
     Spice and try again.</p></body></html>"

  let callback_absolute_uri ~redirect_uri request_uri =
    redirect_uri |> fun uri ->
    Uri.with_path uri (Uri.path request_uri) |> fun uri ->
    Uri.with_query uri (Uri.query request_uri) |> fun uri ->
    Uri.with_fragment uri (Uri.fragment request_uri)

  let callback_port redirect_uri =
    match Uri.port redirect_uri with
    | Some port -> Ok port
    | None ->
        Error
          (Error.Invalid_request
             "browser redirect URI must include an explicit port")

  let callback_hosts redirect_uri =
    match Uri.host redirect_uri with
    | Some "127.0.0.1" -> Ok [ Eio.Net.Ipaddr.V4.loopback ]
    | Some "::1" -> Ok [ Eio.Net.Ipaddr.V6.loopback ]
    | Some "localhost" ->
        Ok [ Eio.Net.Ipaddr.V4.loopback; Eio.Net.Ipaddr.V6.loopback ]
    | Some host ->
        Error
          (Error.Invalid_request ("unsupported browser redirect host: " ^ host))
    | None ->
        Error (Error.Invalid_request "browser redirect URI must include a host")

  let respond_html ~status body =
    Cohttp_eio.Server.respond_string
      ~headers:(Cohttp.Header.of_list [ ("Content-Type", "text/html") ])
      ~status ~body ()

  let listen_all stdenv sw hosts port =
    let listen host =
      Eio.Net.listen (Eio.Stdenv.net stdenv) ~sw ~backlog:4 ~reuse_addr:true
        (`Tcp (host, port))
    in
    let rec loop sockets first_error = function
      | [] -> (
          match (sockets, first_error) with
          | [], Some exn -> Error (Error.Network (Printexc.to_string exn))
          | [], None -> Error (Error.Network "no callback hosts were available")
          | _ :: _, _ -> Ok (List.rev sockets))
      | host :: hosts -> (
          match listen host with
          | socket -> loop (socket :: sockets) first_error hosts
          | exception exn ->
              Log.debug (fun m ->
                  m "callback host bind failed error=%s"
                    (Printexc.to_string exn));
              let first_error =
                match first_error with
                | None -> Some exn
                | Some _ -> first_error
              in
              loop sockets first_error hosts)
    in
    loop [] None hosts

  let await_once ~stdenv ?(on_ready = fun () -> ()) ~redirect_uri ~timeout_s ()
      =
    let* hosts = callback_hosts redirect_uri in
    let* port = callback_port redirect_uri in
    try
      Eio.Switch.run ~name:"oauth2-local-callback" @@ fun sw ->
      let stop, stop_resolver = Eio.Promise.create () in
      let result, result_resolver = Eio.Promise.create () in
      let server =
        Cohttp_eio.Server.make
          ~callback:(fun connection request body ->
            ignore connection;
            ignore body;
            let request_uri = Cohttp.Request.uri request in
            if String.equal (Uri.path request_uri) (Uri.path redirect_uri) then
              let callback = callback_absolute_uri ~redirect_uri request_uri in
              if Eio.Promise.try_resolve result_resolver (Ok callback) then (
                Log.info (fun m -> m "authorization callback received");
                respond_html ~status:`OK html_success)
              else respond_html ~status:`Bad_request html_error
            else respond_html ~status:`Not_found html_error)
          ()
      in
      let* sockets = listen_all stdenv sw hosts port in
      List.iter
        (fun socket ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              Cohttp_eio.Server.run ~stop
                ~on_error:(fun exn -> ignore exn)
                socket server;
              `Stop_daemon))
        sockets;
      on_ready ();
      Log.info (fun m -> m "local callback server listening port=%d" port);
      Fun.protect
        ~finally:(fun () -> ignore (Eio.Promise.try_resolve stop_resolver ()))
        (fun () ->
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock stdenv) timeout_s
            (fun () -> Eio.Promise.await result))
    with
    | Eio.Time.Timeout ->
        Error (Error.Timeout "browser authorization timed out")
    | exn -> Error (Error.Network (Printexc.to_string exn))
end

module Openai_chatgpt = struct
  module Config = struct
    type t = {
      issuer : Uri.t;
      client_id : string;
      expires_in : int;
      poll_interval : int;
    }

    let default_issuer = Uri.of_string "https://auth.openai.com"
    let default_client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
    let default_expires_in = 900
    let default_poll_interval = 5

    let valid_scheme = function
      | Some scheme ->
          String.equal (String.lowercase_ascii scheme) "https"
          || String.equal (String.lowercase_ascii scheme) "http"
      | None -> false

    let check_issuer issuer =
      if not (valid_scheme (Uri.scheme issuer)) then
        invalid "Openai_chatgpt.Config.make" "issuer must use http or https";
      if Option.is_none (Uri.host issuer) then
        invalid "Openai_chatgpt.Config.make" "issuer must have a host";
      if Option.is_some (Uri.verbatim_query issuer) then
        invalid "Openai_chatgpt.Config.make" "issuer must not have a query";
      if Option.is_some (Uri.fragment issuer) then
        invalid "Openai_chatgpt.Config.make" "issuer must not have a fragment"

    let make ?(issuer = default_issuer) ?(client_id = default_client_id)
        ?(expires_in = default_expires_in)
        ?(poll_interval = default_poll_interval) () =
      check_issuer issuer;
      check_non_empty "Openai_chatgpt.Config.make" "client_id" client_id;
      check_non_negative "Openai_chatgpt.Config.make" "expires_in" expires_in;
      check_non_negative "Openai_chatgpt.Config.make" "poll_interval"
        poll_interval;
      { issuer; client_id; expires_in; poll_interval }

    let default = make ()
    let client_id t = t.client_id
    let expires_in t = t.expires_in
    let poll_interval t = t.poll_interval

    let trim_right_slashes path =
      let rec loop i =
        if i <= 0 then ""
        else if Char.equal (String.unsafe_get path (i - 1)) '/' then loop (i - 1)
        else String.sub path 0 i
      in
      loop (String.length path)

    let append_path issuer suffix =
      let base = trim_right_slashes (Uri.path issuer) in
      let suffix =
        if String.starts_with ~prefix:"/" suffix then suffix else "/" ^ suffix
      in
      let uri = Uri.with_path issuer (base ^ suffix) in
      Uri.with_fragment (Uri.with_query' uri []) None

    let user_code_endpoint t =
      append_path t.issuer "/api/accounts/deviceauth/usercode"

    let device_token_endpoint t =
      append_path t.issuer "/api/accounts/deviceauth/token"

    let oauth_token_endpoint t = append_path t.issuer "/oauth/token"
    let oauth_revoke_endpoint t = append_path t.issuer "/oauth/revoke"
    let verification_uri t = append_path t.issuer "/codex/device"
    let device_redirect_uri t = append_path t.issuer "/deviceauth/callback"
  end

  let malformed ?field ?raw message =
    ({ Oauth2.field; Oauth2.message; Oauth2.raw } : Oauth2.malformed)

  let protocol_malformed malformed =
    Error.Protocol
      (Error.malformed_message "malformed OpenAI ChatGPT auth response"
         malformed)

  let malformed_error ?field ?raw message =
    protocol_malformed (malformed ?field ?raw message)

  (* Provider-specific field decoders. OpenAI returns some integers as JSON
     strings, so these compose over {!Oauth2.Json} and report failures through
     the shared [Oauth2.malformed] shape; parse functions map that shape to
     {!Error.t} once at the response boundary. *)

  let non_empty_string field json =
    let* value = Oauth2.Json.string field json in
    if String.equal value "" then
      Error (malformed ~field ~raw:json "expected non-empty string")
    else Ok value

  let int_string field json =
    match json with
    | Jsont.String (value, _) -> (
        match int_of_string_opt value with
        | Some value -> Ok value
        | None -> Error (malformed ~field ~raw:json "expected integer"))
    | value -> Oauth2.Json.int field value

  let non_negative_int_string field json =
    let* value = int_string field json in
    if value >= 0 then Ok value
    else Error (malformed ~field ~raw:json "expected non-negative integer")

  let http_error response =
    Error.Protocol
      (Error.response_message "OpenAI ChatGPT auth response" response)

  let oauth_error error =
    Error.Rejected (Format.asprintf "OAuth error: %a" Oauth2.Error.pp error)

  (* JSON request-body construction. Response decoding uses {!Oauth2.Json}. *)
  module Json = struct
    let mem name value = Jsont.Json.mem (Jsont.Json.name name) value
    let string value = Jsont.Json.string value
    let object' fields = Jsont.Json.object' fields

    let encode json =
      match Jsont_bytesrw.encode_string Jsont.json json with
      | Ok body -> Ok body
      | Error message ->
          Error (Error.Invalid_request ("cannot encode JSON: " ^ message))
  end

  let response_decode_error = function
    | `Oauth error -> Error (oauth_error error)
    | `Http response -> Error (http_error response)
    | `Malformed malformed -> Error (protocol_malformed malformed)

  let decode_oauth_or_http response =
    response_decode_error (Oauth2.Response.error_of_non_success response)

  let decode_success_json parse response =
    if Oauth2.Response.is_success response then
      match Oauth2.Response.json response with
      | Error malformed -> Error (protocol_malformed malformed)
      | Ok json -> Result.map_error protocol_malformed (parse json)
    else decode_oauth_or_http response

  let post http ~sw ~uri ?(headers = []) ~body () =
    match Oauth2_eio.post http ~sw ~uri ~headers ~body () with
    | Error error -> Error (Error.Network (Error.http_error_message error))
    | Ok response -> Ok response

  let post_json http ~sw ~uri json =
    match Json.encode json with
    | Error error -> Error error
    | Ok body ->
        post http ~sw ~uri
          ~headers:[ ("Content-Type", "application/json") ]
          ~body ()

  let post_form http ~sw ~uri params =
    post http ~sw ~uri ~body:(Oauth2.encode_form params) ()

  let timestamp_add seconds now = Int64.add now (Int64.of_int seconds)
  let expires_at ~now = Option.map (fun seconds -> timestamp_add seconds now)

  let jwt_payload id_token =
    let segments = String.split_on_char '.' id_token in
    match List.nth_opt segments 1 with
    | Some payload when List.length segments >= 2 ->
        Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet payload
    | Some _ | None -> Error (`Msg "expected JWT with at least two segments")

  let string_field name json =
    match Oauth2.Json.field name json with
    | Some (Jsont.String (value, _)) when not (String.equal value "") ->
        Some value
    | Some (Jsont.Null _)
    | Some (Jsont.Bool _)
    | Some (Jsont.Number _)
    | Some (Jsont.String _)
    | Some (Jsont.Array _)
    | Some (Jsont.Object _)
    | None ->
        None

  let account_id_of_id_token id_token =
    match jwt_payload id_token with
    | Error (`Msg _) -> None
    | Ok payload -> (
        match Jsont_bytesrw.decode_string Jsont.json payload with
        | Error _ -> None
        | Ok json -> (
            match string_field "chatgpt_account_id" json with
            | Some account_id -> Some account_id
            | None -> (
                match Oauth2.Json.field "https://api.openai.com/auth" json with
                | Some auth -> string_field "chatgpt_account_id" auth
                | None -> None)))

  let account_id_of_tokens ~id_token ~access_token =
    match Option.bind id_token account_id_of_id_token with
    | Some account_id -> Some account_id
    | None -> account_id_of_id_token access_token

  let secret_of_oauth_parts ~access_token ?refresh_token ?expires_at ?account_id
      () =
    match
      Spice_account.Secret.oauth ~access_token ?refresh_token ?expires_at
        ?account_id ()
    with
    | secret -> Ok secret
    | exception Invalid_argument message ->
        Error (malformed_error ("invalid token secret: " ^ message))

  type token = {
    access_token : string;
    refresh_token : string;
    expires_at : Spice_account.timestamp option;
    account_id : string option;
  }

  let parse_token ~now json =
    let* id_token = Oauth2.Json.required "id_token" non_empty_string json in
    let* access_token =
      Oauth2.Json.required "access_token" non_empty_string json
    in
    let* refresh_token =
      Oauth2.Json.required "refresh_token" non_empty_string json
    in
    let* expires_in =
      Oauth2.Json.optional "expires_in" non_negative_int_string json
    in
    Ok
      {
        access_token;
        refresh_token;
        expires_at = expires_at ~now expires_in;
        account_id = account_id_of_id_token id_token;
      }

  let secret_of_token token =
    secret_of_oauth_parts ~access_token:token.access_token
      ~refresh_token:token.refresh_token ?expires_at:token.expires_at
      ?account_id:token.account_id ()

  let secret_of_oauth_token ~now oauth_token =
    let access_token = Oauth2.Token.access_token oauth_token in
    let refresh_token = Oauth2.Token.refresh_token oauth_token in
    let id_token = Oauth2.Token.field_string "id_token" oauth_token in
    let account_id = account_id_of_tokens ~id_token ~access_token in
    let expires_at = expires_at ~now (Oauth2.Token.expires_in oauth_token) in
    secret_of_oauth_parts ~access_token ?refresh_token ?expires_at ?account_id
      ()

  let decode_token ~now response =
    let* token = decode_success_json (parse_token ~now) response in
    secret_of_token token

  type code_exchange = {
    authorization_code : string;
    code_challenge : string;
    code_verifier : string;
  }

  let parse_code_exchange json =
    let* authorization_code =
      Oauth2.Json.required "authorization_code" non_empty_string json
    in
    let* code_challenge =
      Oauth2.Json.required "code_challenge" non_empty_string json
    in
    let* code_verifier =
      Oauth2.Json.required "code_verifier" non_empty_string json
    in
    Ok { authorization_code; code_challenge; code_verifier }

  let pkce_of_code_exchange code =
    match Oauth2.Pkce.of_verifier code.code_verifier with
    | Error (`Invalid_verifier reason) ->
        Error
          (malformed_error ~field:"code_verifier"
             ("invalid PKCE verifier: " ^ reason))
    | Ok pkce ->
        if String.equal (Oauth2.Pkce.challenge pkce) code.code_challenge then
          Ok pkce
        else
          Error
            (malformed_error ~field:"code_challenge"
               "does not match code_verifier")

  let exchange_authorization_code http ~sw ~now config code =
    let* pkce = pkce_of_code_exchange code in
    let params =
      [
        ("grant_type", "authorization_code");
        ("code", code.authorization_code);
        ("redirect_uri", Uri.to_string (Config.device_redirect_uri config));
        ("client_id", Config.client_id config);
        ("code_verifier", Oauth2.Pkce.verifier pkce);
      ]
    in
    let* response =
      post_form http ~sw ~uri:(Config.oauth_token_endpoint config) params
    in
    decode_token ~now response

  type current = {
    access_token : string;
    expires_at : Spice_account.timestamp option;
    account_id : string option;
  }

  let refreshable_secret secret =
    Spice_account.Secret.expose secret
      ~api_key:(fun ~key:_ -> Error Error.Not_refreshable)
      ~bearer:(fun ~token:_ -> Error Error.Not_refreshable)
      ~oauth:(fun ~access_token ~refresh_token ~expires_at ~account_id ->
        match refresh_token with
        | None -> Error Error.Not_refreshable
        | Some refresh_token ->
            Ok
              ( ({ access_token; expires_at; account_id } : current),
                refresh_token ))

  type refresh_response = {
    refresh_id_token : string option;
    refresh_access_token : string option;
    refresh_refresh_token : string option;
    refresh_expires_at : Spice_account.timestamp option;
  }

  let parse_refresh_response ~now json =
    let* id_token = Oauth2.Json.optional "id_token" non_empty_string json in
    let* access_token =
      Oauth2.Json.optional "access_token" non_empty_string json
    in
    let* refresh_token =
      Oauth2.Json.optional "refresh_token" non_empty_string json
    in
    let* expires_in =
      Oauth2.Json.optional "expires_in" non_negative_int_string json
    in
    Ok
      {
        refresh_id_token = id_token;
        refresh_access_token = access_token;
        refresh_refresh_token = refresh_token;
        refresh_expires_at = expires_at ~now expires_in;
      }

  let refresh_response_secret (current : current) ~current_refresh_token
      (response : refresh_response) =
    let access_token =
      Option.value response.refresh_access_token ~default:current.access_token
    in
    let refresh_token =
      Option.value response.refresh_refresh_token ~default:current_refresh_token
    in
    let expires_at =
      match response.refresh_expires_at with
      | Some expires_at -> Some expires_at
      | None ->
          if Option.is_some response.refresh_access_token then None
          else current.expires_at
    in
    let account_id =
      match response.refresh_id_token with
      | Some id_token -> (
          match account_id_of_id_token id_token with
          | Some account_id -> Some account_id
          | None -> current.account_id)
      | None -> current.account_id
    in
    secret_of_oauth_parts ~access_token ~refresh_token ?expires_at ?account_id
      ()

  let refresh ~http ~sw ~now config secret =
    let* current, refresh_token = refreshable_secret secret in
    let body =
      Json.object'
        [
          Json.mem "client_id" (Json.string (Config.client_id config));
          Json.mem "grant_type" (Json.string "refresh_token");
          Json.mem "refresh_token" (Json.string refresh_token);
        ]
    in
    let* response =
      post_json http ~sw ~uri:(Config.oauth_token_endpoint config) body
    in
    let* refresh_response =
      decode_success_json (parse_refresh_response ~now) response
    in
    let* secret =
      refresh_response_secret current ~current_refresh_token:refresh_token
        refresh_response
    in
    Log.info (fun m ->
        m "oauth token refreshed has_expiry=%b"
          (Option.is_some refresh_response.refresh_expires_at));
    Ok secret

  let revocable_secret secret =
    Spice_account.Secret.expose secret
      ~api_key:(fun ~key:_ -> Error Error.Not_refreshable)
      ~bearer:(fun ~token:_ -> Error Error.Not_refreshable)
      ~oauth:(fun ~access_token ~refresh_token ~expires_at:_ ~account_id:_ ->
        match refresh_token with
        | Some refresh_token -> Ok (refresh_token, "refresh_token")
        | None -> Ok (access_token, "access_token"))

  let revoke ~http ~sw config secret =
    let* token, token_type_hint = revocable_secret secret in
    let body =
      Json.object'
        [
          Json.mem "client_id" (Json.string (Config.client_id config));
          Json.mem "token" (Json.string token);
          Json.mem "token_type_hint" (Json.string token_type_hint);
        ]
    in
    let* response =
      post_json http ~sw ~uri:(Config.oauth_revoke_endpoint config) body
    in
    if Oauth2.Response.is_success response then (
      Log.info (fun m -> m "oauth token revoked");
      Ok ())
    else decode_oauth_or_http response
end

module OAuth2_authorization_code = struct
  type started = {
    authorization : Oauth2.Authorization.t;
    authorization_uri : Uri.t;
    redirect_uri : Uri.t;
  }

  type token_profile = Generic | Openai_chatgpt

  let start ~random (spec : Protocol.oauth2_authorization_code) =
    let redirect_uri =
      match spec.Protocol.redirect_uri with
      | Some redirect_uri -> Ok redirect_uri
      | None ->
          Error
            (Error.Invalid_request
               "browser auth protocol requires an explicit redirect URI")
    in
    let pkce =
      if spec.Protocol.pkce then
        match Oauth2.Pkce.generate ~random with
        | pkce -> Ok (Some pkce)
        | exception Invalid_argument message ->
            Error (Error.Invalid_request message)
      else Ok None
    in
    let state =
      match Oauth2.State.generate ~random with
      | state -> Ok state
      | exception Invalid_argument message ->
          Error (Error.Invalid_request message)
    in
    let* redirect_uri = redirect_uri in
    let* pkce = pkce in
    let* state = state in
    match
      Oauth2.Authorization.make ~client:spec.Protocol.authorization_client
        ~endpoint:spec.Protocol.authorization_endpoint ~redirect_uri ~state
        ?pkce ~scope:spec.Protocol.authorization_scope
        ~extra:spec.Protocol.authorization_extra ()
    with
    | Error (`Reserved name) ->
        Error
          (Error.Invalid_request ("reserved authorization parameter: " ^ name))
    | Ok authorization ->
        Log.info (fun m ->
            m "authorization flow started endpoint_host=%s"
              (Option.value ~default:"<none>"
                 (Uri.host spec.Protocol.authorization_endpoint)));
        Ok
          {
            authorization;
            authorization_uri = Oauth2.Authorization.uri authorization;
            redirect_uri = Oauth2.Authorization.redirect_uri authorization;
          }

  let complete ~http ~sw (spec : Protocol.oauth2_authorization_code) started
      ~callback =
    match Oauth2.Authorization.callback started.authorization callback with
    | Error (`Oauth error) ->
        Error (Error.Rejected (Oauth2.Error.to_string error))
    | Error error ->
        Error (Error.Invalid_request (Error.oauth2_callback_message error))
    | Ok code -> (
        let grant = Oauth2.Authorization.grant code in
        match
          Oauth2.Grant.request ~client:spec.Protocol.authorization_client
            ~endpoint:spec.Protocol.authorization_token_endpoint grant
          |> Oauth2_eio.send http ~sw
        with
        | Ok token ->
            Log.info (fun m ->
                m "authorization code exchanged endpoint_host=%s"
                  (Option.value ~default:"<none>"
                     (Uri.host spec.Protocol.authorization_token_endpoint)));
            Ok token
        | Error error -> Error (Error.of_oauth2 error))

  let complete_secret ~http ~sw spec started ~callback ~now ~profile =
    let* token = complete ~http ~sw spec started ~callback in
    match profile with
    | Generic -> Ok (Secret.oauth_token ~now token)
    | Openai_chatgpt -> Openai_chatgpt.secret_of_oauth_token ~now token
end

module Device_code = struct
  type challenge = {
    verification_uri : Uri.t;
    verification_uri_complete : Uri.t option;
    user_code : string;
  }

  type schedule = {
    expires_at : Spice_account.timestamp;
    expires_in : int;
    interval : int;
    next_poll_after : Spice_account.timestamp;
  }

  (* The state closes over its transport so {!poll} needs no protocol
     declaration or configuration. Standard OAuth carries the [Oauth2.Device.t]
     grant plus its spec; the OpenAI flow carries the config and device
     identifier (the user code is the displayed [challenge.user_code]). *)
  type transport =
    | Oauth2 of { device : Oauth2.Device.t; spec : Protocol.oauth2_device_code }
    | Openai of { config : Openai_chatgpt.Config.t; device_auth_id : string }

  type t = { schedule : schedule; challenge : challenge; transport : transport }

  type poll =
    | Authorized of Spice_account.Secret.t
    | Pending of t
    | Expired of t
    | Rejected of Error.t

  let timestamp_add seconds now = Int64.add now (Int64.of_int seconds)
  let challenge t = t.challenge
  let expires_at t = t.schedule.expires_at
  let expires_in t = t.schedule.expires_in

  let next_poll_delay_s ~now t =
    let delay = Int64.sub t.schedule.next_poll_after now in
    if Int64.compare delay 0L <= 0 then 0
    else if Int64.compare delay (Int64.of_int max_int) > 0 then max_int
    else Int64.to_int delay

  let with_next_poll ~now t =
    {
      t with
      schedule =
        {
          t.schedule with
          next_poll_after = timestamp_add t.schedule.interval now;
        };
    }

  let with_slow_down ~now t =
    let interval = t.schedule.interval + 5 in
    {
      t with
      schedule =
        {
          t.schedule with
          interval;
          next_poll_after = timestamp_add interval now;
        };
    }

  (* --- Standard OAuth 2.0 device code (RFC 8628) --- *)

  let start_oauth2 ~http ~sw ~now (spec : Protocol.oauth2_device_code) =
    match
      Oauth2.Device.request ~client:spec.Protocol.device_client
        ~endpoint:spec.Protocol.device_endpoint
        ~scope:spec.Protocol.device_scope ~extra:spec.Protocol.device_extra ()
    with
    | Error (`Reserved name) ->
        Error (Error.Invalid_request ("reserved OAuth parameter: " ^ name))
    | Ok request -> (
        match Oauth2_eio.send http ~sw request with
        | Ok device ->
            let interval = Oauth2.Device.interval device in
            let expires_in = Oauth2.Device.expires_in device in
            let expires_at = timestamp_add expires_in now in
            Log.info (fun m ->
                m "device flow started expires_at=%Ld interval=%d" expires_at
                  interval);
            Ok
              {
                schedule =
                  {
                    expires_at;
                    expires_in;
                    interval;
                    next_poll_after = timestamp_add interval now;
                  };
                challenge =
                  {
                    verification_uri = Oauth2.Device.verification_uri device;
                    verification_uri_complete =
                      Oauth2.Device.verification_uri_complete device;
                    user_code = Oauth2.Device.user_code device;
                  };
                transport = Oauth2 { device; spec };
              }
        | Error error -> Error (Error.of_oauth2 error))

  let expired_code code =
    String.equal code "expired_token"
    || String.equal code "expired_device_code"
    || String.equal code "device_expired"

  let poll_oauth2 ~http ~sw ~now t device (spec : Protocol.oauth2_device_code) =
    let grant = Oauth2.Grant.device_code device in
    match
      Oauth2.Grant.request ~client:spec.Protocol.device_client
        ~endpoint:spec.Protocol.device_token_endpoint grant
      |> Oauth2_eio.send http ~sw
    with
    | Ok token ->
        Log.info (fun m -> m "device authorization completed");
        Ok (Authorized (Secret.oauth_token ~now token))
    | Error (`Oauth error) -> (
        match Oauth2.Device.classify_poll_error error with
        | `Authorization_pending ->
            Log.debug (fun m -> m "device poll pending");
            Ok (Pending (with_next_poll ~now t))
        | `Slow_down ->
            Log.debug (fun m -> m "device poll slow_down, backing off");
            Ok (Pending (with_slow_down ~now t))
        | `Other error when expired_code (Oauth2.Error.code error) ->
            Log.info (fun m -> m "device code expired");
            Ok (Expired t)
        | `Other error ->
            Ok (Rejected (Error.Rejected (Oauth2.Error.to_string error))))
    | Error error -> Error (Error.of_oauth2 error)

  (* --- OpenAI ChatGPT device authorization --- *)

  type user_code_response = {
    parsed_device_auth_id : string;
    parsed_user_code : string;
    parsed_expires_in : int;
    parsed_interval : int;
  }

  let user_code json =
    let* user_code =
      Oauth2.Json.optional "user_code" Openai_chatgpt.non_empty_string json
    in
    match user_code with
    | Some value -> Ok value
    | None -> (
        let* alt =
          Oauth2.Json.optional "usercode" Openai_chatgpt.non_empty_string json
        in
        match alt with
        | Some value -> Ok value
        | None ->
            Error
              (Openai_chatgpt.malformed ~field:"user_code"
                 "missing required field"))

  let parse_user_code config json =
    let* device_auth_id =
      Oauth2.Json.required "device_auth_id" Openai_chatgpt.non_empty_string json
    in
    let* user_code = user_code json in
    let* expires_in =
      Oauth2.Json.optional "expires_in" Openai_chatgpt.non_negative_int_string
        json
    in
    let* interval =
      Oauth2.Json.optional "interval" Openai_chatgpt.non_negative_int_string
        json
    in
    Ok
      {
        parsed_device_auth_id = device_auth_id;
        parsed_user_code = user_code;
        parsed_expires_in =
          Option.value expires_in
            ~default:(Openai_chatgpt.Config.expires_in config);
        parsed_interval =
          Option.value interval
            ~default:(Openai_chatgpt.Config.poll_interval config);
      }

  let start_openai_chatgpt ~http ~sw ~now config =
    let body =
      Openai_chatgpt.Json.object'
        [
          Openai_chatgpt.Json.mem "client_id"
            (Openai_chatgpt.Json.string
               (Openai_chatgpt.Config.client_id config));
        ]
    in
    let* response =
      Openai_chatgpt.post_json http ~sw
        ~uri:(Openai_chatgpt.Config.user_code_endpoint config)
        body
    in
    let* parsed =
      Openai_chatgpt.decode_success_json (parse_user_code config) response
    in
    let expires_at = timestamp_add parsed.parsed_expires_in now in
    Log.info (fun m ->
        m "chatgpt device flow started expires_at=%Ld interval=%d" expires_at
          parsed.parsed_interval);
    Ok
      {
        schedule =
          {
            expires_at;
            expires_in = parsed.parsed_expires_in;
            interval = parsed.parsed_interval;
            next_poll_after = timestamp_add parsed.parsed_interval now;
          };
        challenge =
          {
            verification_uri = Openai_chatgpt.Config.verification_uri config;
            verification_uri_complete = None;
            user_code = parsed.parsed_user_code;
          };
        transport =
          Openai { config; device_auth_id = parsed.parsed_device_auth_id };
      }

  let poll_openai ~http ~sw ~now t ~config ~device_auth_id =
    let body =
      Openai_chatgpt.Json.object'
        [
          Openai_chatgpt.Json.mem "device_auth_id"
            (Openai_chatgpt.Json.string device_auth_id);
          Openai_chatgpt.Json.mem "user_code"
            (Openai_chatgpt.Json.string t.challenge.user_code);
        ]
    in
    let* response =
      Openai_chatgpt.post_json http ~sw
        ~uri:(Openai_chatgpt.Config.device_token_endpoint config)
        body
    in
    match response.Oauth2.Response.status with
    | 403 | 404 ->
        Log.debug (fun m -> m "chatgpt device poll pending");
        Ok (Pending (with_next_poll ~now t))
    | _ when Oauth2.Response.is_success response ->
        let* code =
          match Oauth2.Response.json response with
          | Error malformed ->
              Error (Openai_chatgpt.protocol_malformed malformed)
          | Ok json ->
              Result.map_error Openai_chatgpt.protocol_malformed
                (Openai_chatgpt.parse_code_exchange json)
        in
        let* secret =
          Openai_chatgpt.exchange_authorization_code http ~sw ~now config code
        in
        Log.info (fun m -> m "chatgpt device authorization completed");
        Ok (Authorized secret)
    | _ -> Openai_chatgpt.decode_oauth_or_http response

  let poll ~http ~sw ~now t =
    if Int64.compare now t.schedule.expires_at >= 0 then (
      Log.info (fun m -> m "device code expired");
      Ok (Expired t))
    else
      match t.transport with
      | Oauth2 { device; spec } -> poll_oauth2 ~http ~sw ~now t device spec
      | Openai { config; device_auth_id } ->
          poll_openai ~http ~sw ~now t ~config ~device_auth_id
end
