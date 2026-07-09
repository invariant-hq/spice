(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Auth = Spice_auth
module Browser = Auth.OAuth2_authorization_code
module Device = Auth.Device_code
module Protocol = Spice_provider.Auth.Login.Protocol

let read_body body = Eio.Buf_read.(of_flow ~max_size:4096 body |> take_all)

let respond_string ~status ~body () =
  Cohttp_eio.Server.respond_string ~status ~body ()

let with_server env callback f =
  Eio.Switch.run @@ fun sw ->
  let stop, stop_resolver = Eio.Promise.create () in
  let server_error = ref None in
  let socket =
    Eio.Net.listen env#net ~sw ~backlog:16 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let server =
    Cohttp_eio.Server.make
      ~callback:(fun conn request body ->
        ignore conn;
        callback request body)
      ()
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Cohttp_eio.Server.run ~stop
        ~on_error:(fun exn -> server_error := Some exn)
        socket server;
      `Stop_daemon);
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (address, port) ->
        ignore address;
        port
    | `Unix path -> failf "expected TCP listening socket, got Unix path %S" path
  in
  let base_uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d" port) in
  Fun.protect
    ~finally:(fun () ->
      Eio.Promise.resolve stop_resolver ();
      match !server_error with None -> () | Some exn -> raise exn)
    (fun () -> f ~sw ~base_uri)

let query_one name uri =
  match List.assoc_opt name (Uri.query uri) with
  | Some [ value ] -> value
  | Some [] -> failf "query parameter %S has no value" name
  | Some (_ :: _ :: _) -> failf "query parameter %S has multiple values" name
  | None -> failf "query parameter %S is missing" name

let authorization_setup ~token_endpoint =
  let client = Oauth2.Client.make ~id:"client-id" () in
  let authorization_endpoint = Uri.of_string "https://provider.example/auth" in
  let redirect_uri = Uri.of_string "http://localhost/callback" in
  let spec : Protocol.oauth2_authorization_code =
    {
      Protocol.authorization_client = client;
      Protocol.authorization_endpoint;
      Protocol.authorization_token_endpoint = token_endpoint;
      Protocol.redirect_uri = Some redirect_uri;
      Protocol.authorization_scope = [];
      Protocol.authorization_extra = [];
      Protocol.pkce = false;
    }
  in
  let started =
    match Browser.start ~random:(fun n -> String.make n '\001') spec with
    | Ok started -> started
    | Error error ->
        failf "failed to start browser auth: %a" Auth.Error.pp error
  in
  let state = query_one "state" (Browser.authorization_uri started) in
  let callback =
    Uri.of_string ("http://localhost/callback?code=code-1&state=" ^ state)
  in
  (started, callback)

let complete_secret_response env ~profile ~response_body =
  let observed_body = ref None in
  with_server env
    (fun request body ->
      equal string ~msg:"token path" "/token" (Http.Request.resource request);
      observed_body := Some (read_body body);
      respond_string ~status:`OK ~body:response_body ())
    (fun ~sw ~base_uri ->
      let token_endpoint = Uri.with_path base_uri "/token" in
      let started, callback = authorization_setup ~token_endpoint in
      let result =
        Auth.OAuth2_authorization_code.complete_secret
          ~http:(Oauth2_eio.make_client env#net)
          ~sw started ~callback ~now:10L ~profile
      in
      (match !observed_body with
      | Some body ->
          is_true ~msg:"authorization code is posted"
            (String.includes ~affix:"code=code-1" body)
      | None -> failf "token endpoint was not called");
      result)

let complete_secret env ~profile ~token_type =
  complete_secret_response env ~profile
    ~response_body:
      (Printf.sprintf
         {|{"access_token":"access-secret","token_type":%S,"refresh_token":"refresh-secret"}|}
         token_type)

let rejects_non_bearer_token_type env () =
  match
    complete_secret env ~profile:Auth.OAuth2_authorization_code.Generic
      ~token_type:"DPoP"
  with
  | Error (Auth.Error.Protocol message) ->
      is_true ~msg:"unsupported token type is reported"
        (String.includes ~affix:"unsupported OAuth token_type" message)
  | Error error -> failf "expected protocol error, got %a" Auth.Error.pp error
  | Ok _ -> failf "expected non-Bearer token rejection"

let rejects_non_bearer_openai_profile env () =
  match
    complete_secret env ~profile:Auth.OAuth2_authorization_code.Openai_chatgpt
      ~token_type:"DPoP"
  with
  | Error (Auth.Error.Protocol message) ->
      is_true ~msg:"unsupported OpenAI token type is reported"
        (String.includes ~affix:"unsupported OAuth token_type" message)
  | Error error -> failf "expected protocol error, got %a" Auth.Error.pp error
  | Ok _ -> failf "expected non-Bearer OpenAI token rejection"

let accepts_bearer_token_type env () =
  match
    complete_secret env ~profile:Auth.OAuth2_authorization_code.Generic
      ~token_type:"bearer"
  with
  | Ok _ -> ()
  | Error error -> failf "expected bearer token, got %a" Auth.Error.pp error

let rejects_empty_generic_access_token env () =
  match
    complete_secret_response env ~profile:Auth.OAuth2_authorization_code.Generic
      ~response_body:{|{"access_token":"","token_type":"Bearer"}|}
  with
  | Error (Auth.Error.Protocol message) ->
      is_true ~msg:"empty access token is reported"
        (String.includes ~affix:"access_token must not be empty" message)
  | Error error -> failf "expected protocol error, got %a" Auth.Error.pp error
  | Ok _ -> failf "expected empty access token rejection"

let rejects_empty_generic_refresh_token env () =
  match
    complete_secret_response env ~profile:Auth.OAuth2_authorization_code.Generic
      ~response_body:
        {|{"access_token":"access-secret","token_type":"Bearer","refresh_token":""}|}
  with
  | Error (Auth.Error.Protocol message) ->
      is_true ~msg:"empty refresh token is reported"
        (String.includes ~affix:"refresh_token must not be empty" message)
  | Error error -> failf "expected protocol error, got %a" Auth.Error.pp error
  | Ok _ -> failf "expected empty refresh token rejection"

let free_port env =
  Eio.Switch.run @@ fun sw ->
  let socket =
    Eio.Net.listen env#net ~sw ~backlog:1 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> port
  | `Unix path -> failf "expected TCP listening socket, got Unix path %S" path

let http_get env ~sw uri =
  let client = Cohttp_eio.Client.make ~https:None env#net in
  let response, body = Cohttp_eio.Client.call client ~sw `GET uri in
  ignore (read_body body);
  Http.Status.to_int (Http.Response.status response)

let accepts_only_matching_callbacks () =
  let token_endpoint = Uri.of_string "https://provider.example/token" in
  let started, callback = authorization_setup ~token_endpoint in
  let state = query_one "state" (Browser.authorization_uri started) in
  is_true ~msg:"state-matched code callback is accepted"
    (Browser.accepts_callback started callback);
  is_false ~msg:"forged state is rejected"
    (Browser.accepts_callback started
       (Uri.of_string "http://localhost/callback?code=code-1&state=forged"));
  is_false ~msg:"missing state is rejected"
    (Browser.accepts_callback started
       (Uri.of_string "http://localhost/callback?code=code-1"));
  is_true ~msg:"state-matched provider denial is accepted"
    (Browser.accepts_callback started
       (Uri.of_string
          ("http://localhost/callback?error=access_denied&state=" ^ state)))

let listener_ignores_unaccepted_callbacks env () =
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  Eio.Switch.run @@ fun sw ->
  let ready, ready_resolver = Eio.Promise.create () in
  let listener =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Auth.Local_callback.await_once ~stdenv:env
          ~on_ready:(fun () -> Eio.Promise.resolve ready_resolver ())
          ~accept:(fun callback ->
            match List.assoc_opt "state" (Uri.query callback) with
            | Some [ "good" ] -> true
            | Some _ | None -> false)
          ~redirect_uri ~timeout_s:5.0 ())
  in
  Eio.Promise.await ready;
  let get state =
    http_get env ~sw
      (Uri.of_string
         (Printf.sprintf "http://127.0.0.1:%d/callback?code=c&state=%s" port
            state))
  in
  equal int ~msg:"forged callback is answered with 400" 400 (get "forged");
  equal int ~msg:"accepted callback is answered with 200" 200 (get "good");
  match Eio.Promise.await_exn listener with
  | Ok callback ->
      equal string ~msg:"the accepted callback completes the wait" "good"
        (query_one "state" callback)
  | Error error ->
      failf "expected accepted callback, got %a" Auth.Error.pp error

let listener_reraises_cancellation env () =
  let port = free_port env in
  let redirect_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/callback" port)
  in
  Eio.Switch.run @@ fun sw ->
  let ready, ready_resolver = Eio.Promise.create () in
  let cancel_context, cancel_context_resolver = Eio.Promise.create () in
  let result =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun context ->
        Eio.Promise.resolve cancel_context_resolver context;
        Auth.Local_callback.await_once ~stdenv:env
          ~on_ready:(fun () -> Eio.Promise.resolve ready_resolver ())
          ~redirect_uri ~timeout_s:10.0 ())
  in
  Eio.Promise.await ready;
  Eio.Cancel.cancel
    (Eio.Promise.await cancel_context)
    (Failure "test cancellation");
  match Eio.Promise.await_exn result with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Ok _ -> failf "expected cancellation, got a callback"
  | Error error ->
      failf "cancellation was wrapped as auth error: %a" Auth.Error.pp error

let rejects_invalid_openai_auth_issuer () =
  match
    Auth.Openai_chatgpt.Config.make
      ~issuer:(Uri.of_string "file:///tmp/auth")
      ()
  with
  | Error (Auth.Error.Invalid_request message) ->
      is_true ~msg:"invalid issuer is reported"
        (String.includes ~affix:"issuer must use http or https" message)
  | Error error -> failf "expected invalid request, got %a" Auth.Error.pp error
  | Ok _ -> failf "expected invalid issuer rejection"

let oauth_device_spec ~base_uri =
  let client = Oauth2.Client.make ~id:"device-client" () in
  {
    Protocol.device_client = client;
    Protocol.device_endpoint = Uri.with_path base_uri "/device";
    Protocol.device_token_endpoint = Uri.with_path base_uri "/token";
    Protocol.device_scope = [ "profile" ];
    Protocol.device_extra = [];
  }

let with_oauth_device_server env token_responses f =
  let token_responses = ref token_responses in
  with_server env
    (fun request body ->
      let resource = Http.Request.resource request in
      if String.equal resource "/device" then (
        ignore (read_body body);
        respond_string ~status:`OK
          ~body:
            {|{"device_code":"device-secret","user_code":"USER-CODE","verification_uri":"https://provider.example/device","verification_uri_complete":"https://provider.example/device?user_code=USER-CODE","expires_in":30,"interval":2}|}
          ())
      else if String.equal resource "/token" then (
        ignore (read_body body);
        match !token_responses with
        | [] -> failf "unexpected device token poll"
        | (status, response_body) :: rest ->
            token_responses := rest;
            respond_string ~status ~body:response_body ())
      else failf "unexpected auth path %S" resource)
    (fun ~sw ~base_uri -> f ~sw ~base_uri)

let start_oauth_device ~sw ~base_uri env =
  match
    Device.start_oauth2
      ~http:(Oauth2_eio.make_client env#net)
      ~sw ~now:10L
      (oauth_device_spec ~base_uri)
  with
  | Ok device -> device
  | Error error -> failf "expected device start, got %a" Auth.Error.pp error

let poll_oauth_device ~sw env ~now device =
  match Device.poll ~http:(Oauth2_eio.make_client env#net) ~sw ~now device with
  | Ok poll -> poll
  | Error error -> failf "expected device poll, got %a" Auth.Error.pp error

let standard_device_poll_schedules_pending_and_slow_down env () =
  with_oauth_device_server env
    [
      (`Bad_request, {|{"error":"authorization_pending"}|});
      (`Bad_request, {|{"error":"slow_down"}|});
    ]
    (fun ~sw ~base_uri ->
      let device = start_oauth_device ~sw ~base_uri env in
      let challenge = Device.challenge device in
      equal string ~msg:"user code" "USER-CODE" challenge.Device.user_code;
      equal int ~msg:"initial poll delay" 2
        (Device.next_poll_delay_s ~now:10L device);
      match poll_oauth_device ~sw env ~now:12L device with
      | Device.Pending pending ->
          equal int ~msg:"pending keeps interval" 2
            (Device.next_poll_delay_s ~now:12L pending);
          begin match poll_oauth_device ~sw env ~now:14L pending with
          | Device.Pending slowed ->
              equal int ~msg:"slow down increases interval" 7
                (Device.next_poll_delay_s ~now:14L slowed)
          | Device.Authorized _ | Device.Expired _ | Device.Rejected _ ->
              failf "expected slow_down pending state"
          end
      | Device.Authorized _ | Device.Expired _ | Device.Rejected _ ->
          failf "expected authorization_pending state")

let standard_device_poll_reports_provider_expiry env () =
  with_oauth_device_server env
    [ (`Bad_request, {|{"error":"expired_device_code"}|}) ]
    (fun ~sw ~base_uri ->
      let device = start_oauth_device ~sw ~base_uri env in
      match poll_oauth_device ~sw env ~now:12L device with
      | Device.Expired _ -> ()
      | Device.Authorized _ | Device.Pending _ | Device.Rejected _ ->
          failf "expected provider-reported expiry")

let standard_device_poll_authorizes_bearer_tokens env () =
  with_oauth_device_server env
    [
      ( `OK,
        {|{"access_token":"device-access","token_type":"Bearer","refresh_token":"device-refresh"}|}
      );
    ]
    (fun ~sw ~base_uri ->
      let device = start_oauth_device ~sw ~base_uri env in
      match poll_oauth_device ~sw env ~now:12L device with
      | Device.Authorized _ -> ()
      | Device.Pending _ | Device.Expired _ | Device.Rejected _ ->
          failf "expected authorized device poll")

let with_eio test () = Eio_main.run @@ fun env -> test env ()

let () =
  run "auth"
    [
      group "config"
        [
          test "rejects invalid OpenAI auth issuers"
            rejects_invalid_openai_auth_issuer;
        ];
      group "oauth"
        [
          test ~timeout:3.0 "rejects non-Bearer generic token responses"
            (with_eio rejects_non_bearer_token_type);
          test ~timeout:3.0 "rejects non-Bearer OpenAI token responses"
            (with_eio rejects_non_bearer_openai_profile);
          test ~timeout:3.0 "accepts Bearer token responses"
            (with_eio accepts_bearer_token_type);
          test ~timeout:3.0 "rejects empty generic access tokens"
            (with_eio rejects_empty_generic_access_token);
          test ~timeout:3.0 "rejects empty generic refresh tokens"
            (with_eio rejects_empty_generic_refresh_token);
        ];
      group "browser"
        [
          test "accepts only matching callbacks" accepts_only_matching_callbacks;
          test ~timeout:5.0 "listener ignores unaccepted callbacks"
            (with_eio listener_ignores_unaccepted_callbacks);
          test ~timeout:5.0 "listener re-raises cancellation"
            (with_eio listener_reraises_cancellation);
        ];
      group "device"
        [
          test ~timeout:3.0 "schedules pending and slow_down polls"
            (with_eio standard_device_poll_schedules_pending_and_slow_down);
          test ~timeout:3.0 "reports provider device-code expiry"
            (with_eio standard_device_poll_reports_provider_expiry);
          test ~timeout:3.0 "authorizes Bearer token responses"
            (with_eio standard_device_poll_authorizes_bearer_tokens);
        ];
    ]
