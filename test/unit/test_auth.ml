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

let expect_authorization msg = function
  | Ok value -> value
  | Error (`Reserved name) -> failf "%s: reserved parameter %S" msg name

let authorization_setup ~token_endpoint =
  let client = Oauth2.Client.make ~id:"client-id" () in
  let authorization_endpoint = Uri.of_string "https://provider.example/auth" in
  let redirect_uri = Uri.of_string "http://localhost/callback" in
  let state = Oauth2.State.of_string "state-1" in
  let authorization =
    expect_authorization "authorization"
      (Oauth2.Authorization.make ~client ~endpoint:authorization_endpoint
         ~redirect_uri ~state ())
  in
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
  let started : Browser.started =
    {
      Browser.authorization;
      Browser.authorization_uri = Oauth2.Authorization.uri authorization;
      Browser.redirect_uri;
    }
  in
  let callback =
    Uri.of_string "http://localhost/callback?code=code-1&state=state-1"
  in
  (spec, started, callback)

let complete_secret_response env ~profile ~response_body =
  let observed_body = ref None in
  with_server env
    (fun request body ->
      equal string ~msg:"token path" "/token" (Http.Request.resource request);
      observed_body := Some (read_body body);
      respond_string ~status:`OK ~body:response_body ())
    (fun ~sw ~base_uri ->
      let token_endpoint = Uri.with_path base_uri "/token" in
      let spec, started, callback = authorization_setup ~token_endpoint in
      let result =
        Auth.OAuth2_authorization_code.complete_secret
          ~http:(Oauth2_eio.make_client env#net)
          ~sw spec started ~callback ~now:10L ~profile
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

let with_eio test () = Eio_main.run @@ fun env -> test env ()

let () =
  run "auth"
    [
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
