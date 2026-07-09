(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap

type observed_request = {
  resource : string;
  content_type : string option;
  body : string;
}

let max_test_body_bytes = 2_097_152
let string_of_error error = Format.asprintf "%a" Oauth2_eio.Error.pp error

let read_body body =
  Eio.Buf_read.(of_flow ~max_size:max_test_body_bytes body |> take_all)

let header_value headers name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    headers

let request_content_type request =
  Http.Header.get (Http.Request.headers request) "content-type"

let respond_string ?(headers = []) ~status ~body () =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list headers)
    ~status ~body ()

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

let check_observed expected = function
  | None -> failf "server did not observe a request"
  | Some observed -> expected observed

let client env = Oauth2_eio.make_client env#net

let token_request endpoint =
  let oauth_client = Oauth2.Client.make ~id:"spice-client" () in
  let grant = Oauth2.Grant.client_credentials () in
  Oauth2.Grant.request ~client:oauth_client ~endpoint grant

let test_post_preserves_response_and_sets_form_content_type env () =
  let observed = ref None in
  with_server env
    (fun request body ->
      observed :=
        Some
          {
            resource = Http.Request.resource request;
            content_type = request_content_type request;
            body = read_body body;
          };
      respond_string
        ~headers:[ ("x-oauth2-test", "preserved") ]
        ~status:`Accepted ~body:"preserved body" ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/post" in
      match
        Oauth2_eio.post (client env) ~sw ~uri ~body:"grant_type=test" ()
      with
      | Error (`Network message) -> failf "%s" message
      | Ok response ->
          equal int ~msg:"status" 202 response.Oauth2.Response.status;
          equal (option string) ~msg:"response header" (Some "preserved")
            (header_value response.Oauth2.Response.headers "x-oauth2-test");
          equal string ~msg:"response body" "preserved body"
            response.Oauth2.Response.body);
  check_observed
    (fun request ->
      equal string ~msg:"resource" "/post" request.resource;
      equal (option string) ~msg:"content type"
        (Some "application/x-www-form-urlencoded") request.content_type;
      equal string ~msg:"request body" "grant_type=test" request.body)
    !observed

let test_post_preserves_caller_content_type env () =
  let observed = ref None in
  with_server env
    (fun request body ->
      observed :=
        Some
          {
            resource = Http.Request.resource request;
            content_type = request_content_type request;
            body = read_body body;
          };
      respond_string ~status:`OK ~body:"{}" ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/json" in
      match
        Oauth2_eio.post (client env) ~sw ~uri
          ~headers:[ ("Content-Type", "application/json") ]
          ~body:{|{"grant_type":"test"}|} ()
      with
      | Error (`Network message) -> failf "%s" message
      | Ok response ->
          equal int ~msg:"status" 200 response.Oauth2.Response.status);
  check_observed
    (fun request ->
      equal string ~msg:"resource" "/json" request.resource;
      equal (option string) ~msg:"content type" (Some "application/json")
        request.content_type;
      equal string ~msg:"request body" {|{"grant_type":"test"}|} request.body)
    !observed

let test_post_rejects_oversized_body env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:(String.make 1_048_577 'x') ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/large" in
      match
        Oauth2_eio.post (client env) ~sw ~uri ~body:"grant_type=test" ()
      with
      | Error (`Network message) ->
          is_true ~msg:"oversized body reports response body read failure"
            (String.includes ~affix:"response body read failed" message)
      | Ok response ->
          failf "expected oversized response failure, got status %d"
            response.Oauth2.Response.status)

let test_post_accepts_exact_response_body_limit env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:(String.make 16 'x') ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/exact" in
      match
        Oauth2_eio.post (client env) ~sw ~max_response_body_size:16 ~uri
          ~body:"grant_type=test" ()
      with
      | Error (`Network message) -> failf "%s" message
      | Ok response ->
          equal int ~msg:"exact response size" 16
            (String.length response.Oauth2.Response.body))

let test_post_rejects_negative_response_body_limit env () =
  let observed = ref false in
  with_server env
    (fun request body ->
      observed := true;
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:"unreachable" ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/negative-limit" in
      match
        Oauth2_eio.post (client env) ~sw ~max_response_body_size:(-1) ~uri
          ~body:"grant_type=test" ()
      with
      | Error (`Network message) ->
          is_true ~msg:"negative response limit is explicit"
            (String.includes ~affix:"negative response body limit" message);
          is_false ~msg:"negative response limit does not send request"
            !observed
      | Ok response ->
          failf "expected negative limit failure, got status %d"
            response.Oauth2.Response.status)

let test_post_reraises_cancellation env () =
  let accepted, accepted_resolver = Eio.Promise.create () in
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      ignore (Eio.Promise.try_resolve accepted_resolver ());
      Eio.Fiber.await_cancel ())
    (fun ~sw ~base_uri ->
      let uri = Uri.with_path base_uri "/slow" in
      let cancel_context, cancel_context_resolver = Eio.Promise.create () in
      let result =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Cancel.sub @@ fun cancel_context ->
            Eio.Promise.resolve cancel_context_resolver cancel_context;
            Oauth2_eio.post (client env) ~sw ~uri ~body:"grant_type=test" ())
      in
      Eio.Promise.await accepted;
      Eio.Cancel.cancel
        (Eio.Promise.await cancel_context)
        (Failure "test cancellation");
      match Eio.Promise.await_exn result with
      | exception Eio.Cancel.Cancelled _ -> ()
      | Error (`Network message) ->
          failf "cancellation was wrapped as network error: %s" message
      | Ok response ->
          failf "expected cancellation, got status %d"
            response.Oauth2.Response.status)

let test_make_tls_client_initializes_https env () =
  match Oauth2_eio.make_tls_client env#net with
  | Ok client -> ignore client
  | Error (`Tls_error message) ->
      failf "expected TLS client construction, got %s" message

let test_pp_error_redacts_http_body () =
  let response =
    {
      Oauth2.Response.status = 400;
      Oauth2.Response.headers = [ ("Content-Type", "application/json") ];
      Oauth2.Response.body = {|{"access_token":"secret-token"}|};
    }
  in
  let rendered = string_of_error (`Http response) in
  is_true ~msg:"status is printed" (String.includes ~affix:"400" rendered);
  is_true ~msg:"body length is printed"
    (String.includes ~affix:"body length" rendered);
  is_true ~msg:"content type is printed"
    (String.includes ~affix:"application/json" rendered);
  is_false ~msg:"token body is redacted"
    (String.includes ~affix:"secret-token" rendered);
  is_false ~msg:"raw body shape is redacted"
    (String.includes ~affix:"access_token" rendered)

let test_send_decodes_success env () =
  with_server env
    (fun request body ->
      equal string ~msg:"token path" "/token" (Http.Request.resource request);
      equal string ~msg:"token body"
        "client_id=spice-client&grant_type=client_credentials" (read_body body);
      respond_string ~status:`OK
        ~body:
          {|{"access_token":"access-123","token_type":"Bearer","expires_in":3600,"scope":"repo user"}|}
        ())
    (fun ~sw ~base_uri ->
      let request = token_request (Uri.with_path base_uri "/token") in
      match Oauth2_eio.send (client env) ~sw request with
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error)
      | Ok token ->
          equal string ~msg:"access token" "access-123"
            (Oauth2.Token.access_token token);
          equal string ~msg:"token type" "Bearer"
            (Oauth2.Token.token_type token);
          equal (option int) ~msg:"expires in" (Some 3600)
            (Oauth2.Token.expires_in token);
          equal
            (option (list string))
            ~msg:"scope"
            (Some [ "repo"; "user" ])
            (Oauth2.Token.scope token))

let test_send_forwards_basic_auth_header env () =
  with_server env
    (fun request body ->
      equal string ~msg:"token path" "/token" (Http.Request.resource request);
      equal (option string) ~msg:"authorization header"
        (Some "Basic YmFzaWMtY2xpZW50OmJhc2ljLXNlY3JldA==")
        (Http.Header.get (Http.Request.headers request) "authorization");
      let body = read_body body in
      is_false ~msg:"client id omitted from basic body"
        (String.includes ~affix:"client_id" body);
      is_false ~msg:"client secret omitted from basic body"
        (String.includes ~affix:"client_secret" body);
      equal string ~msg:"token body" "grant_type=client_credentials" body;
      respond_string ~status:`OK
        ~body:{|{"access_token":"access-123","token_type":"Bearer"}|} ())
    (fun ~sw ~base_uri ->
      let oauth_client =
        Oauth2.Client.make ~id:"basic-client"
          ~auth:(`Secret_basic "basic-secret") ()
      in
      let request =
        Oauth2.Grant.client_credentials ()
        |> Oauth2.Grant.request ~client:oauth_client
             ~endpoint:(Uri.with_path base_uri "/token")
      in
      match Oauth2_eio.send (client env) ~sw request with
      | Ok token ->
          equal string ~msg:"access token" "access-123"
            (Oauth2.Token.access_token token)
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error))

let test_send_maps_oauth_error_before_http env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`Bad_request
        ~body:
          {|{"error":"invalid_grant","error_description":"authorization code expired"}|}
        ())
    (fun ~sw ~base_uri ->
      let request = token_request (Uri.with_path base_uri "/token") in
      match Oauth2_eio.send (client env) ~sw request with
      | Error (`Oauth error) ->
          equal string ~msg:"oauth code" "invalid_grant"
            (Oauth2.Error.code error);
          equal (option string) ~msg:"oauth description"
            (Some "authorization code expired")
            (Oauth2.Error.description error)
      | Error (`Http response) ->
          failf "expected OAuth error before HTTP %d"
            response.Oauth2.Response.status
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error)
      | Ok _token -> failf "expected OAuth error")

let test_send_maps_malformed_success_json env () =
  with_server env
    (fun request body ->
      ignore request;
      ignore (read_body body);
      respond_string ~status:`OK ~body:{|{"token_type":"Bearer"}|} ())
    (fun ~sw ~base_uri ->
      let request = token_request (Uri.with_path base_uri "/token") in
      match Oauth2_eio.send (client env) ~sw request with
      | Error (`Malformed malformed) ->
          equal (option string) ~msg:"malformed field" (Some "access_token")
            malformed.Oauth2.field
      | Error error ->
          failf "unexpected OAuth2_eio.send error: %s" (string_of_error error)
      | Ok _token -> failf "expected malformed token response")

let revocation token = Oauth2.Revocation.make ~token ()

let test_revoke_success_and_http_error env () =
  let oauth_client = Oauth2.Client.make ~id:"spice-client" () in
  with_server env
    (fun request body ->
      equal string ~msg:"revocation success path" "/revoke-ok"
        (Http.Request.resource request);
      equal string ~msg:"revocation success body"
        "client_id=spice-client&token=token-ok" (read_body body);
      respond_string ~status:`No_content ~body:"" ())
    (fun ~sw ~base_uri ->
      let endpoint = Uri.with_path base_uri "/revoke-ok" in
      match
        Oauth2.Revocation.request ~client:oauth_client ~endpoint
          (revocation "token-ok")
        |> Oauth2_eio.send (client env) ~sw
      with
      | Ok () -> ()
      | Error error ->
          failf "unexpected revoke error: %s" (string_of_error error));
  with_server env
    (fun request body ->
      equal string ~msg:"revocation error path" "/revoke-error"
        (Http.Request.resource request);
      equal string ~msg:"revocation error body"
        "client_id=spice-client&token=token-error" (read_body body);
      respond_string ~status:`Internal_server_error ~body:"plain failure" ())
    (fun ~sw ~base_uri ->
      let endpoint = Uri.with_path base_uri "/revoke-error" in
      match
        Oauth2.Revocation.request ~client:oauth_client ~endpoint
          (revocation "token-error")
        |> Oauth2_eio.send (client env) ~sw
      with
      | Error (`Http response) ->
          equal int ~msg:"status" 500 response.Oauth2.Response.status;
          equal string ~msg:"body" "plain failure" response.Oauth2.Response.body
      | Error error ->
          failf "unexpected revoke error: %s" (string_of_error error)
      | Ok () -> failf "expected HTTP revocation error")

let test_device_authorization_reserved_extra_is_pure_error env () =
  ignore env;
  let oauth_client = Oauth2.Client.make ~id:"spice-client" () in
  let endpoint = Uri.of_string "http://127.0.0.1:1/device" in
  let extra = [ ("client_id", "conflict") ] in
  match Oauth2.Device.request ~client:oauth_client ~endpoint ~extra () with
  | Error (`Reserved name) ->
      equal string ~msg:"reserved parameter" "client_id" name
  | Ok _request -> failf "expected invalid request"

let with_eio test () = Eio_main.run @@ fun env -> test env ()

let () =
  run "oauth2.eio"
    [
      group "post"
        [
          test ~timeout:3.0 "preserves raw response and default content type"
            (with_eio test_post_preserves_response_and_sets_form_content_type);
          test ~timeout:3.0 "preserves caller content type"
            (with_eio test_post_preserves_caller_content_type);
          test ~timeout:3.0 "rejects oversized response body"
            (with_eio test_post_rejects_oversized_body);
          test ~timeout:3.0 "accepts exact response body limit"
            (with_eio test_post_accepts_exact_response_body_limit);
          test ~timeout:3.0 "rejects negative response body limit"
            (with_eio test_post_rejects_negative_response_body_limit);
          test ~timeout:3.0 "re-raises cancellation"
            (with_eio test_post_reraises_cancellation);
        ];
      group "errors"
        [
          test "redacts HTTP body in pretty-printer"
            test_pp_error_redacts_http_body;
        ];
      group "send"
        [
          test ~timeout:3.0 "decodes successful pure request"
            (with_eio test_send_decodes_success);
          test ~timeout:3.0 "forwards request headers"
            (with_eio test_send_forwards_basic_auth_header);
          test ~timeout:3.0 "maps OAuth JSON error before HTTP"
            (with_eio test_send_maps_oauth_error_before_http);
          test ~timeout:3.0 "maps malformed success JSON"
            (with_eio test_send_maps_malformed_success_json);
        ];
      group "standard requests"
        [
          test ~timeout:3.0 "revoke handles success and HTTP error"
            (with_eio test_revoke_success_and_http_error);
          test ~timeout:3.0
            "device authorization rejects reserved extra before transport"
            (with_eio test_device_authorization_reserved_extra_is_pure_error);
        ];
      group "https"
        [
          test ~timeout:3.0 "constructs TLS client"
            (with_eio test_make_tls_client_initializes_https);
        ];
    ]
