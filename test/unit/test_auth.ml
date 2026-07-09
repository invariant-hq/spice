(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Auth = Spice_auth
module Browser = Auth.OAuth2_authorization_code
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
    | Error error -> failf "failed to start browser auth: %a" Auth.Error.pp error
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

let rejects_invalid_openai_auth_issuer () =
  match
    Auth.Openai_chatgpt.Config.make ~issuer:(Uri.of_string "file:///tmp/auth") ()
  with
  | Error (Auth.Error.Invalid_request message) ->
      is_true ~msg:"invalid issuer is reported"
        (String.includes ~affix:"issuer must use http or https" message)
  | Error error -> failf "expected invalid request, got %a" Auth.Error.pp error
  | Ok _ -> failf "expected invalid issuer rejection"

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
    ]
