(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Json = Jsont.Json
module O = Oauth2

let pp_params ppf params =
  let pp_binding ppf (name, value) = Format.fprintf ppf "%s=%s" name value in
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
    pp_binding ppf params

let params_value = testable ~pp:pp_params ~equal:(fun a b -> a = b) ()
let check_params msg expected actual = equal params_value ~msg expected actual

let expect_ok msg = function
  | Ok value -> value
  | Error _ -> failf "%s: expected Ok" msg

let check_lacks msg ~needle text =
  is_false ~msg (String.includes ~affix:needle text)

let response ?(status = 200) body =
  {
    O.Response.status;
    headers = [ ("content-type", "application/json") ];
    body;
  }

let pct_decode_form value =
  String.map (function '+' -> ' ' | c -> c) value |> Uri.pct_decode

let decode_query query =
  let decode_pair pair =
    match String.split_first ~sep:"=" pair with
    | None -> (pct_decode_form pair, "")
    | Some (name, value) -> (pct_decode_form name, pct_decode_form value)
  in
  query |> String.split_all ~sep:"&" |> List.map decode_pair

let query_params uri =
  match Uri.verbatim_query uri with
  | None -> []
  | Some query -> decode_query query

let get_unique name params =
  match
    List.filter_map
      (fun (field, value) ->
        if String.equal field name then Some value else None)
      params
  with
  | [] -> Ok None
  | [ value ] -> Ok (Some value)
  | _ :: _ :: _ -> Error (`Duplicate name)

(* [Request.body] is the wire form body; decode it back to inspect parameters,
   since the builders no longer expose their parameter lists directly. *)
let request_params request = decode_query (O.Request.body request)

let grant_params request =
  List.filter
    (fun (name, _) -> not (List.mem name [ "client_id"; "client_secret" ]))
    (request_params request)

let expect_reserved msg expected = function
  | Error (`Reserved actual) -> equal string ~msg expected actual
  | Ok _ -> failf "%s: expected reserved parameter rejection" msg

let client id auth = O.Client.make ~id ?auth ()

let token_grant ?pkce () =
  O.Grant.authorization_code ~code:"auth-code"
    ~redirect_uri:(Uri.of_string "http://localhost/callback")
    ?pkce ()

let expect_token_malformed_field msg field json =
  match O.Token.parse json with
  | Error (`Malformed malformed) ->
      equal (option string) ~msg (Some field) malformed.O.field
  | Error (`Oauth error) ->
      failf "%s: expected malformed, got OAuth error %s" msg
        (O.Error.code error)
  | Ok _ -> failf "%s: expected malformed" msg

let expect_device_malformed_field msg field json =
  match O.Device.parse json with
  | Error (`Malformed malformed) ->
      equal (option string) ~msg (Some field) malformed.O.field
  | Error (`Oauth error) ->
      failf "%s: expected malformed, got OAuth error %s" msg
        (O.Error.code error)
  | Ok _ -> failf "%s: expected malformed" msg

let response_helpers () =
  is_true ~msg:"200 is success"
    (O.Response.is_success (response ~status:200 ""));
  is_true ~msg:"299 is success"
    (O.Response.is_success (response ~status:299 ""));
  is_false ~msg:"199 is not success"
    (O.Response.is_success (response ~status:199 ""));
  is_false ~msg:"300 is not success"
    (O.Response.is_success (response ~status:300 ""));
  let content_response =
    {
      O.Response.status = 400;
      headers = [ ("CONTENT-TYPE", "text/plain") ];
      body = "";
    }
  in
  equal (option string) ~msg:"content-type is case-insensitive"
    (Some "text/plain")
    (O.Response.content_type content_response);
  (match O.Response.json (response {|{"ok":true}|}) with
  | Ok (Jsont.Object _) -> ()
  | Ok _ -> failf "response JSON: expected object"
  | Error malformed ->
      failf "response JSON: unexpected malformed %a" O.pp_malformed malformed);
  (match O.Response.json (response "{") with
  | Error malformed ->
      is_true ~msg:"malformed JSON message"
        (String.includes ~affix:"invalid JSON" malformed.O.message)
  | Ok _ -> failf "response malformed JSON: expected error");
  (match
     O.Response.error_of_non_success
       (response ~status:400
          {|{"error":"invalid_grant","error_description":"expired"}|})
   with
  | `Oauth error ->
      equal string ~msg:"oauth before HTTP" "invalid_grant" (O.Error.code error)
  | `Malformed malformed ->
      failf "oauth before HTTP: unexpected malformed %a" O.pp_malformed
        malformed
  | `Http _ -> failf "oauth before HTTP: expected OAuth error");
  (match O.Response.error_of_non_success (response ~status:500 "plain") with
  | `Http http_response ->
      equal int ~msg:"plain non-JSON falls back to HTTP" 500
        http_response.O.Response.status
  | `Oauth error ->
      failf "plain non-JSON: unexpected OAuth error %s" (O.Error.code error)
  | `Malformed malformed ->
      failf "plain non-JSON: unexpected malformed %a" O.pp_malformed malformed);
  (match
     O.Response.error_of_non_success (response ~status:400 {|{"error":123}|})
   with
  | `Malformed malformed ->
      equal (option string) ~msg:"malformed oauth error field" (Some "error")
        malformed.O.field
  | `Oauth error ->
      failf "malformed OAuth error: unexpected OAuth error %s"
        (O.Error.code error)
  | `Http _ -> failf "malformed OAuth error: expected malformed");
  let parse_access = function
    | Jsont.Object _ -> Ok "parsed"
    | json ->
        Error
          (`Malformed
             { O.field = None; message = "expected object"; raw = Some json })
  in
  equal string ~msg:"decode_json success" "parsed"
    (expect_ok "decode_json success"
       (O.Response.decode_json parse_access (response {|{"access":"ok"}|})));
  match O.Response.decode_json parse_access (response ~status:500 "plain") with
  | Error (`Http http_response) ->
      equal int ~msg:"decode_json HTTP fallback" 500
        http_response.O.Response.status
  | Error (`Oauth error) ->
      failf "decode_json HTTP fallback: unexpected OAuth error %s"
        (O.Error.code error)
  | Error (`Malformed malformed) ->
      failf "decode_json HTTP fallback: unexpected malformed %a" O.pp_malformed
        malformed
  | Ok _ -> failf "decode_json HTTP fallback: expected error"

let params () =
  equal string ~msg:"form encoding" "a=1&a=2&space=x+y&sym=%21%2A%28%29"
    (O.encode_form
       [ ("a", "1"); ("a", "2"); ("space", "x y"); ("sym", "!*()") ]);
  let reserved = (`Reserved "client_secret" : O.Param_error.t) in
  let rendered = Format.asprintf "%a" O.Param_error.pp reserved in
  is_true ~msg:"param error message names field"
    (String.includes ~affix:"client_secret" (O.Param_error.message reserved));
  is_true ~msg:"param error pp names field"
    (String.includes ~affix:"client_secret" rendered)

let client_auth_requests () =
  let endpoint = Uri.of_string "https://provider.example/token" in
  let grant = token_grant () in
  let public =
    O.Grant.request ~client:(client "public-client" None) ~endpoint grant
  in
  check_params "public client params"
    [
      ("client_id", "public-client");
      ("grant_type", "authorization_code");
      ("code", "auth-code");
      ("redirect_uri", "http://localhost/callback");
    ]
    (request_params public);
  equal string ~msg:"public encoded body"
    "client_id=public-client&grant_type=authorization_code&code=auth-code&redirect_uri=http%3A%2F%2Flocalhost%2Fcallback"
    (O.Request.body public);
  (match O.Request.headers public with
  | [] -> ()
  | headers ->
      failf "public client headers: expected no headers, got %d"
        (List.length headers));
  let secret_post =
    O.Grant.request
      ~client:(client "post-client" (Some (`Secret_post "post-secret")))
      ~endpoint grant
  in
  check_params "secret_post params"
    [
      ("client_id", "post-client");
      ("client_secret", "post-secret");
      ("grant_type", "authorization_code");
      ("code", "auth-code");
      ("redirect_uri", "http://localhost/callback");
    ]
    (request_params secret_post);
  (match O.Request.headers secret_post with
  | [] -> ()
  | headers ->
      failf "secret_post headers: expected no headers, got %d"
        (List.length headers));
  let secret_basic =
    O.Grant.request
      ~client:(client "basic-client" (Some (`Secret_basic "basic-secret")))
      ~endpoint grant
  in
  check_params "secret_basic params"
    [
      ("grant_type", "authorization_code");
      ("code", "auth-code");
      ("redirect_uri", "http://localhost/callback");
    ]
    (request_params secret_basic);
  (match O.Request.headers secret_basic with
  | [ ("Authorization", header) ] ->
      equal string ~msg:"secret_basic header"
        "Basic YmFzaWMtY2xpZW50OmJhc2ljLXNlY3JldA==" header
  | headers ->
      failf "secret_basic headers: expected one Authorization header, got %d"
        (List.length headers));
  let reserved_basic =
    O.Grant.request
      ~client:(client "client id:+" (Some (`Secret_basic "secret:% ")))
      ~endpoint grant
  in
  match O.Request.headers reserved_basic with
  | [ ("Authorization", header) ] ->
      equal string ~msg:"secret_basic reserved characters"
        "Basic Y2xpZW50K2lkJTNBJTJCOnNlY3JldCUzQSUyNSs=" header
  | headers ->
      failf
        "secret_basic reserved headers: expected one Authorization header, got \
         %d"
        (List.length headers)

let deterministic_random n = String.init n (fun i -> Char.chr (i * 17 mod 256))

let pkce () =
  let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk" in
  let pkce = expect_ok "pkce verifier" (O.Pkce.of_verifier verifier) in
  equal string ~msg:"pkce verifier" verifier (O.Pkce.verifier pkce);
  equal string ~msg:"pkce challenge"
    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" (O.Pkce.challenge pkce);
  let generated = O.Pkce.generate ~random:deterministic_random in
  let regenerated =
    expect_ok "generated pkce verifier"
      (O.Pkce.of_verifier (O.Pkce.verifier generated))
  in
  equal string ~msg:"generated pkce challenge"
    (O.Pkce.challenge regenerated)
    (O.Pkce.challenge generated);
  is_true ~msg:"generated verifier length"
    (String.length (O.Pkce.verifier generated) >= 43);
  (match O.Pkce.of_verifier "short" with
  | Error (`Invalid_verifier reason) ->
      is_true ~msg:"short verifier reason"
        (String.includes ~affix:"shorter" reason)
  | Ok _ -> failf "short verifier: expected invalid verifier");
  let bad = String.make 43 'a' ^ "!" in
  match O.Pkce.of_verifier bad with
  | Error (`Invalid_verifier reason) ->
      is_true ~msg:"bad verifier reason"
        (String.includes ~affix:"outside" reason)
  | Ok _ -> failf "bad verifier: expected invalid verifier"

let authorization_request () =
  let client = client "client-id" None in
  let endpoint = Uri.of_string "https://provider.example/authorize" in
  let redirect_uri = Uri.of_string "http://localhost/callback" in
  let state = O.State.of_string "state-1" in
  let pkce =
    expect_ok "authorization pkce"
      (O.Pkce.of_verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  in
  let request =
    expect_ok "authorization request"
      (O.Authorization.make ~client ~endpoint ~redirect_uri ~state ~pkce
         ~scope:[ "read"; "write" ]
         ~extra:[ ("prompt", "consent") ]
         ())
  in
  let params = query_params (O.Authorization.uri request) in
  equal (option string) ~msg:"authorization response_type" (Some "code")
    (expect_ok "authorization response_type"
       (get_unique "response_type" params));
  equal (option string) ~msg:"authorization client_id" (Some "client-id")
    (expect_ok "authorization client_id" (get_unique "client_id" params));
  equal (option string) ~msg:"authorization redirect_uri"
    (Some "http://localhost/callback")
    (expect_ok "authorization redirect_uri" (get_unique "redirect_uri" params));
  equal (option string) ~msg:"authorization state" (Some "state-1")
    (expect_ok "authorization state" (get_unique "state" params));
  equal (option string) ~msg:"authorization scope" (Some "read write")
    (expect_ok "authorization scope" (get_unique "scope" params));
  equal (option string) ~msg:"authorization challenge"
    (Some (O.Pkce.challenge pkce))
    (expect_ok "authorization challenge" (get_unique "code_challenge" params));
  equal (option string) ~msg:"authorization challenge method" (Some "S256")
    (expect_ok "authorization challenge method"
       (get_unique "code_challenge_method" params));
  equal (option string) ~msg:"authorization extra" (Some "consent")
    (expect_ok "authorization extra" (get_unique "prompt" params));
  List.iter
    (fun name ->
      expect_reserved
        ("authorization reserved extra " ^ name)
        name
        (O.Authorization.make ~client ~endpoint ~redirect_uri ~state
           ~extra:[ (name, "bad") ]
           ());
      expect_reserved
        ("authorization endpoint reserved " ^ name)
        name
        (O.Authorization.make ~client
           ~endpoint:
             (Uri.of_string
                ("https://provider.example/authorize?" ^ name ^ "=bad"))
           ~redirect_uri ~state ()))
    [
      "response_type";
      "client_id";
      "redirect_uri";
      "state";
      "scope";
      "code_challenge";
      "code_challenge_method";
    ];
  let endpoint_with_query =
    Uri.of_string
      "https://provider.example/authorize?login_hint=user@example.com"
  in
  let request_with_query =
    expect_ok "authorization endpoint query"
      (O.Authorization.make ~client ~endpoint:endpoint_with_query ~redirect_uri
         ~state ())
  in
  let params_with_query =
    query_params (O.Authorization.uri request_with_query)
  in
  equal (option string) ~msg:"authorization preserves endpoint query"
    (Some "user@example.com")
    (expect_ok "authorization login_hint"
       (get_unique "login_hint" params_with_query));
  let endpoint_with_comma_query =
    Uri.of_string "https://provider.example/authorize?login_hint=a,b"
  in
  let request_with_comma_query =
    expect_ok "authorization endpoint comma query"
      (O.Authorization.make ~client ~endpoint:endpoint_with_comma_query
         ~redirect_uri ~state ())
  in
  let params_with_comma_query =
    query_params (O.Authorization.uri request_with_comma_query)
  in
  equal (option string) ~msg:"authorization preserves comma query" (Some "a,b")
    (expect_ok "authorization login_hint comma"
       (get_unique "login_hint" params_with_comma_query));
  List.iter
    (fun name ->
      expect_reserved
        ("authorization redirect reserved " ^ name)
        name
        (O.Authorization.make ~client ~endpoint
           ~redirect_uri:
             (Uri.of_string ("http://localhost/callback?" ^ name ^ "=bad"))
           ~state ()))
    [ "code"; "state"; "error"; "error_description"; "error_uri" ]

let callback () =
  let client = client "client-id" None in
  let endpoint = Uri.of_string "https://provider.example/authorize" in
  let redirect_uri = Uri.of_string "http://localhost/callback" in
  let pkce =
    expect_ok "callback pkce"
      (O.Pkce.of_verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  in
  let authorization =
    expect_ok "callback authorization"
      (O.Authorization.make ~client ~endpoint ~redirect_uri
         ~state:(O.State.of_string "state-1")
         ~pkce ())
  in
  let code =
    expect_ok "callback success"
      (O.Authorization.callback authorization
         (Uri.of_string "http://localhost/callback?code=code-1&state=state-1"))
  in
  equal string ~msg:"callback code" "code-1" (O.Authorization.code code);
  let token_endpoint = Uri.of_string "https://provider.example/token" in
  check_params "callback grant preserves redirect and pkce"
    [
      ("grant_type", "authorization_code");
      ("code", "code-1");
      ("redirect_uri", "http://localhost/callback");
      ("code_verifier", O.Pkce.verifier pkce);
    ]
    (grant_params
       (O.Grant.request ~client ~endpoint:token_endpoint
          (O.Authorization.grant code)));
  let comma_code =
    expect_ok "callback comma code"
      (O.Authorization.callback authorization
         (Uri.of_string "http://localhost/callback?code=a,b&state=state-1"))
  in
  equal string ~msg:"callback code keeps comma" "a,b"
    (O.Authorization.code comma_code);
  (match
     O.Authorization.callback authorization
       (Uri.of_string "https://localhost/callback?code=code-1&state=state-1")
   with
  | Error `Redirect_uri_mismatch -> ()
  | Ok _ | Error _ ->
      failf "callback wrong scheme: expected redirect URI mismatch");
  (match
     O.Authorization.callback authorization
       (Uri.of_string "http://localhost/other?code=code-1&state=state-1")
   with
  | Error `Redirect_uri_mismatch -> ()
  | Ok _ | Error _ ->
      failf "callback wrong path: expected redirect URI mismatch");
  let authorization_with_redirect_query =
    expect_ok "callback authorization with redirect query"
      (O.Authorization.make ~client ~endpoint
         ~redirect_uri:(Uri.of_string "http://localhost/callback?tenant=spice")
         ~state:(O.State.of_string "state-1")
         ())
  in
  let queried_code =
    expect_ok "callback keeps redirect query"
      (O.Authorization.callback authorization_with_redirect_query
         (Uri.of_string
            "http://localhost/callback?tenant=spice&code=code-1&state=state-1"))
  in
  equal string ~msg:"callback queried code" "code-1"
    (O.Authorization.code queried_code);
  (match
     O.Authorization.callback authorization_with_redirect_query
       (Uri.of_string "http://localhost/callback?code=code-1&state=state-1")
   with
  | Error `Redirect_uri_mismatch -> ()
  | Ok _ | Error _ ->
      failf "callback missing redirect query: expected redirect URI mismatch");
  let authorization_with_duplicate_redirect_query =
    expect_ok "callback authorization with duplicate redirect query"
      (O.Authorization.make ~client ~endpoint
         ~redirect_uri:
           (Uri.of_string "http://localhost/callback?tenant=spice&tenant=spice")
         ~state:(O.State.of_string "state-1")
         ())
  in
  (match
     O.Authorization.callback authorization_with_duplicate_redirect_query
       (Uri.of_string
          "http://localhost/callback?tenant=spice&code=code-1&state=state-1")
   with
  | Error `Redirect_uri_mismatch -> ()
  | Ok _ | Error _ ->
      failf
        "callback missing duplicate redirect query: expected redirect URI \
         mismatch");
  ignore
    (expect_ok "callback duplicate redirect query"
       (O.Authorization.callback authorization_with_duplicate_redirect_query
          (Uri.of_string
             "http://localhost/callback?tenant=spice&tenant=spice&code=code-1&state=state-1"))
      : O.Authorization.code);
  (match
     O.Authorization.callback authorization
       (Uri.of_string
          "http://localhost/callback?error=access_denied&error_description=no&state=state-1")
   with
  | Error (`Oauth error) ->
      equal string ~msg:"callback oauth error" "access_denied"
        (O.Error.code error)
  | Ok _ | Error _ -> failf "callback oauth error: expected OAuth error");
  (match
     O.Authorization.callback authorization
       (Uri.of_string "http://localhost/callback?error=access_denied")
   with
  | Error (`Missing field) ->
      equal string ~msg:"callback oauth missing state" "state" field
  | Ok _ | Error _ ->
      failf "callback oauth missing state: expected missing state");
  (match
     O.Authorization.callback authorization
       (Uri.of_string
          "http://localhost/callback?error=access_denied&state=state-1&state=state-1")
   with
  | Error (`Duplicate field) ->
      equal string ~msg:"callback duplicate state" "state" field
  | Ok _ | Error _ -> failf "callback duplicate state: expected duplicate state");
  List.iter
    (fun uri ->
      match O.Authorization.callback authorization (Uri.of_string uri) with
      | Error (`Duplicate field) ->
          equal string ~msg:"callback mixed duplicate state" "state" field
      | Ok _ | Error _ ->
          failf "callback mixed duplicate state: expected duplicate state")
    [
      "http://localhost/callback?error=access_denied&state=attacker&state=state-1";
      "http://localhost/callback?error=access_denied&state=state-1&state=attacker";
    ];
  List.iter
    (fun (field, uri) ->
      match O.Authorization.callback authorization (Uri.of_string uri) with
      | Error (`Duplicate actual) ->
          equal string ~msg:("callback duplicate " ^ field) field actual
      | Ok _ | Error _ ->
          failf "callback duplicate %s: expected duplicate field" field)
    [
      ( "error",
        "http://localhost/callback?error=access_denied&error=server_error&state=state-1"
      );
      ( "error_description",
        "http://localhost/callback?error=access_denied&error_description=one&error_description=two&state=state-1"
      );
      ( "error_uri",
        "http://localhost/callback?error=access_denied&error_uri=https://provider.example/one&error_uri=https://provider.example/two&state=state-1"
      );
    ];
  List.iter
    (fun (field, uri) ->
      match O.Authorization.callback authorization (Uri.of_string uri) with
      | Error (`Duplicate actual) ->
          equal string ~msg:("callback duplicate success " ^ field) field actual
      | Ok _ | Error _ ->
          failf "callback duplicate success %s: expected duplicate field" field)
    [
      ( "error_description",
        "http://localhost/callback?code=code-1&state=state-1&error_description=one&error_description=two"
      );
      ( "error_uri",
        "http://localhost/callback?code=code-1&state=state-1&error_uri=https://provider.example/one&error_uri=https://provider.example/two"
      );
    ];
  (match
     O.Authorization.callback authorization
       (Uri.of_string "http://localhost/callback?state=state-1")
   with
  | Error (`Missing field) -> equal string ~msg:"callback missing" "code" field
  | Ok _ | Error _ -> failf "callback missing: expected missing code");
  (match
     O.Authorization.callback authorization
       (Uri.of_string "http://localhost/callback?code=a&code=b&state=state-1")
   with
  | Error (`Duplicate field) ->
      equal string ~msg:"callback duplicate" "code" field
  | Ok _ | Error _ -> failf "callback duplicate: expected duplicate code");
  match
    O.Authorization.callback authorization
      (Uri.of_string "http://localhost/callback?error=access_denied&state=other")
  with
  | Error `State_mismatch -> ()
  | Ok _ | Error _ ->
      failf "callback oauth wrong state: expected state mismatch"

let token () =
  let token =
    expect_ok "token parse success"
      (O.Token.parse
         (json_object
            [
              ("access_token", Json.string "access-secret");
              ("token_type", Json.string "Bearer");
              ("expires_in", Json.int 3600);
              ("refresh_token", Json.string "refresh-secret");
              ("scope", Json.string "read write");
              ("id_token", Json.string "id-secret");
              ("custom_int", Json.string "42");
            ]))
  in
  equal string ~msg:"token access" "access-secret" (O.Token.access_token token);
  equal string ~msg:"token type" "Bearer" (O.Token.token_type token);
  equal (option int) ~msg:"token expires" (Some 3600) (O.Token.expires_in token);
  equal (option string) ~msg:"token refresh" (Some "refresh-secret")
    (O.Token.refresh_token token);
  equal
    (option (list string))
    ~msg:"token scope"
    (Some [ "read"; "write" ])
    (O.Token.scope token);
  equal (option string) ~msg:"token unknown string" (Some "id-secret")
    (O.Token.field_string "id_token" token);
  equal (option int) ~msg:"token unknown int" (Some 42)
    (O.Token.field_int "custom_int" token);
  is_true ~msg:"token raw keeps unknown field"
    (Option.is_some (O.Token.field "id_token" token));
  let rendered = Format.asprintf "%a" O.Token.pp token in
  check_lacks "token pp access redaction" ~needle:"access-secret" rendered;
  check_lacks "token pp refresh redaction" ~needle:"refresh-secret" rendered;
  check_lacks "token pp unknown redaction" ~needle:"id-secret" rendered;
  (match
     O.Token.parse
       (json_object
          [
            ("error", Json.string "invalid_grant");
            ("error_description", Json.string "expired");
          ])
   with
  | Error (`Oauth error) ->
      equal string ~msg:"token oauth error" "invalid_grant" (O.Error.code error)
  | Ok _ | Error _ -> failf "token oauth error: expected OAuth error");
  expect_token_malformed_field "token malformed missing token_type" "token_type"
    (json_object [ ("access_token", Json.string "access-secret") ]);
  expect_token_malformed_field "token duplicate access_token" "access_token"
    (json_object
       [
         ("access_token", Json.string "access-1");
         ("access_token", Json.string "access-2");
         ("token_type", Json.string "Bearer");
       ]);
  expect_token_malformed_field "token negative expires_in" "expires_in"
    (json_object
       [
         ("access_token", Json.string "access-secret");
         ("token_type", Json.string "Bearer");
         ("expires_in", Json.int (-1));
       ]);
  expect_token_malformed_field "token fractional expires_in" "expires_in"
    (json_object
       [
         ("access_token", Json.string "access-secret");
         ("token_type", Json.string "Bearer");
         ("expires_in", Json.number 1.5);
       ]);
  expect_token_malformed_field "token string expires_in" "expires_in"
    (json_object
       [
         ("access_token", Json.string "access-secret");
         ("token_type", Json.string "Bearer");
         ("expires_in", Json.string "3600");
       ]);
  expect_token_malformed_field "token huge expires_in" "expires_in"
    (json_object
       [
         ("access_token", Json.string "access-secret");
         ("token_type", Json.string "Bearer");
         ("expires_in", Json.number (Float.ldexp 1.0 62));
       ]);
  let zero_expires =
    expect_ok "token zero expires_in"
      (O.Token.parse
         (json_object
            [
              ("access_token", Json.string "access-secret");
              ("token_type", Json.string "Bearer");
              ("expires_in", Json.int 0);
            ]))
  in
  equal (option int) ~msg:"token zero expires_in" (Some 0)
    (O.Token.expires_in zero_expires);
  expect_token_malformed_field "token duplicate error" "error"
    (json_object
       [
         ("error", Json.string "invalid_grant");
         ("error", Json.string "invalid_request");
       ]);
  expect_token_malformed_field "token duplicate error_description"
    "error_description"
    (json_object
       [
         ("error", Json.string "invalid_grant");
         ("error_description", Json.string "one");
         ("error_description", Json.string "two");
       ]);
  expect_token_malformed_field "token duplicate error_uri" "error_uri"
    (json_object
       [
         ("error", Json.string "invalid_grant");
         ("error_uri", Json.string "https://provider.example/one");
         ("error_uri", Json.string "https://provider.example/two");
       ]);
  expect_token_malformed_field "token non-string error" "error"
    (json_object [ ("error", Json.int 123) ])

let device_authorization () =
  let device =
    expect_ok "device parse default interval"
      (O.Device.parse
         (json_object
            [
              ("device_code", Json.string "device-secret");
              ("user_code", Json.string "USER-CODE");
              ("verification_uri", Json.string "https://provider.example/device");
              ("expires_in", Json.int 600);
            ]))
  in
  equal string ~msg:"device code" "device-secret" (O.Device.device_code device);
  equal string ~msg:"device user code" "USER-CODE" (O.Device.user_code device);
  equal string ~msg:"device verification uri" "https://provider.example/device"
    (Uri.to_string (O.Device.verification_uri device));
  equal int ~msg:"device expires" 600 (O.Device.expires_in device);
  equal int ~msg:"device default interval" 5 (O.Device.interval device);
  is_true ~msg:"device verification_uri_complete is absent"
    (Option.is_none (O.Device.verification_uri_complete device));
  expect_device_malformed_field "device negative expires_in" "expires_in"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.int (-1));
       ]);
  expect_device_malformed_field "device fractional expires_in" "expires_in"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.number 1.5);
       ]);
  expect_device_malformed_field "device string expires_in" "expires_in"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.string "600");
       ]);
  expect_device_malformed_field "device huge expires_in" "expires_in"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.number (Float.ldexp 1.0 62));
       ]);
  expect_device_malformed_field "device zero interval" "interval"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.int 600);
         ("interval", Json.int 0);
       ]);
  expect_device_malformed_field "device negative interval" "interval"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.int 600);
         ("interval", Json.int (-1));
       ]);
  expect_device_malformed_field "device fractional interval" "interval"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.int 600);
         ("interval", Json.number 1.5);
       ]);
  expect_device_malformed_field "device string interval" "interval"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.int 600);
         ("interval", Json.string "5");
       ]);
  expect_device_malformed_field "device huge interval" "interval"
    (json_object
       [
         ("device_code", Json.string "device-secret");
         ("user_code", Json.string "USER-CODE");
         ("verification_uri", Json.string "https://provider.example/device");
         ("expires_in", Json.int 600);
         ("interval", Json.number (Float.ldexp 1.0 62));
       ]);
  let interval_one =
    expect_ok "device interval one"
      (O.Device.parse
         (json_object
            [
              ("device_code", Json.string "device-secret");
              ("user_code", Json.string "USER-CODE");
              ("verification_uri", Json.string "https://provider.example/device");
              ("expires_in", Json.int 600);
              ("interval", Json.int 1);
            ]))
  in
  equal int ~msg:"device interval one" 1 (O.Device.interval interval_one);
  expect_device_malformed_field "device duplicate error" "error"
    (json_object
       [
         ("error", Json.string "authorization_pending");
         ("error", Json.string "slow_down");
       ]);
  expect_device_malformed_field "device duplicate error_description"
    "error_description"
    (json_object
       [
         ("error", Json.string "authorization_pending");
         ("error_description", Json.string "one");
         ("error_description", Json.string "two");
       ]);
  expect_device_malformed_field "device duplicate error_uri" "error_uri"
    (json_object
       [
         ("error", Json.string "authorization_pending");
         ("error_uri", Json.string "https://provider.example/one");
         ("error_uri", Json.string "https://provider.example/two");
       ]);
  let pending = O.Error.make ~code:"authorization_pending" () in
  let slow = O.Error.make ~code:"slow_down" () in
  let other = O.Error.make ~code:"access_denied" () in
  (match O.Device.classify_poll_error pending with
  | `Authorization_pending -> ()
  | `Slow_down | `Other _ ->
      failf "device classify pending: expected authorization_pending");
  (match O.Device.classify_poll_error slow with
  | `Slow_down -> ()
  | `Authorization_pending | `Other _ ->
      failf "device classify slow: expected slow_down");
  (match O.Device.classify_poll_error other with
  | `Other error ->
      equal string ~msg:"device classify other" "access_denied"
        (O.Error.code error)
  | `Authorization_pending | `Slow_down ->
      failf "device classify other: expected other");
  expect_reserved "device reserved scope" "scope"
    (O.Device.request
       ~client:(client "device-client" None)
       ~endpoint:(Uri.of_string "https://provider.example/device")
       ~extra:[ ("scope", "bad") ]
       ());
  let request =
    expect_ok "device request"
      (O.Device.request
         ~client:(client "device-client" (Some (`Secret_post "device-secret")))
         ~endpoint:(Uri.of_string "https://provider.example/device")
         ~scope:[ "read" ]
         ~extra:[ ("audience", "api") ]
         ())
  in
  check_params "device request params"
    [
      ("client_id", "device-client");
      ("client_secret", "device-secret");
      ("scope", "read");
      ("audience", "api");
    ]
    (request_params request);
  let decoded =
    expect_ok "device request decode"
      (O.Request.decode request
         (response
            {|{"device_code":"dc","user_code":"uc","verification_uri":"https://provider.example/device","expires_in":300,"interval":9}|}))
  in
  equal int ~msg:"device decoded interval" 9 (O.Device.interval decoded)

let grants_and_revocation () =
  let endpoint = Uri.of_string "https://provider.example/token" in
  let pkce =
    expect_ok "grant pkce"
      (O.Pkce.of_verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
  in
  let authorization =
    O.Grant.authorization_code ~code:"code-secret"
      ~redirect_uri:(Uri.of_string "http://localhost/callback")
      ~pkce ()
    |> O.Grant.with_extra [ ("resource", "api") ]
    |> expect_ok "grant authorization"
  in
  check_params "authorization grant params"
    [
      ("grant_type", "authorization_code");
      ("code", "code-secret");
      ("redirect_uri", "http://localhost/callback");
      ("code_verifier", O.Pkce.verifier pkce);
      ("resource", "api");
    ]
    (grant_params
       (O.Grant.request
          ~client:(client "grant-client" None)
          ~endpoint authorization));
  let request =
    O.Grant.request
      ~client:(client "client-id" (Some (`Secret_post "client-secret")))
      ~endpoint authorization
  in
  equal string ~msg:"authorization grant body"
    ("client_id=client-id&client_secret=client-secret&grant_type=authorization_code"
   ^ "&code=code-secret&redirect_uri=http%3A%2F%2Flocalhost%2Fcallback"
   ^ "&code_verifier=" ^ O.Pkce.verifier pkce ^ "&resource=api")
    (O.Request.body request);
  let request_with_header =
    O.Request.with_header "X-OAuth2-Test" "preserved" request
  in
  (match O.Request.headers request_with_header with
  | [ ("X-OAuth2-Test", "preserved") ] -> ()
  | headers ->
      failf "with_header: expected one added header, got %d"
        (List.length headers));
  let decoded =
    expect_ok "with_header keeps token decoder"
      (O.Request.decode request_with_header
         (response {|{"access_token":"access-secret","token_type":"Bearer"}|}))
  in
  equal string ~msg:"with_header decoded token" "access-secret"
    (O.Token.access_token decoded);
  expect_reserved "refresh reserved client_id" "client_id"
    (O.Grant.refresh_token ~refresh_token:"refresh-secret" ()
    |> O.Grant.with_extra [ ("client_id", "bad") ]);
  expect_reserved "extension reserved grant_type" "grant_type"
    (O.Grant.extension ~grant_type:"urn:custom"
       ~params:[ ("grant_type", "bad") ]);
  let refresh =
    O.Grant.refresh_token ~refresh_token:"refresh-secret" ~scope:[ "read" ] ()
  in
  check_params "refresh grant params"
    [
      ("grant_type", "refresh_token");
      ("refresh_token", "refresh-secret");
      ("scope", "read");
    ]
    (grant_params
       (O.Grant.request ~client:(client "grant-client" None) ~endpoint refresh));
  let client_credentials =
    O.Grant.client_credentials ~scope:[ "read"; "write" ] ()
  in
  check_params "client credentials grant params"
    [ ("grant_type", "client_credentials"); ("scope", "read write") ]
    (grant_params
       (O.Grant.request
          ~client:(client "grant-client" None)
          ~endpoint client_credentials));
  expect_reserved "revocation reserved token" "token"
    (O.Revocation.make ~token:"token-secret" ()
    |> O.Revocation.with_extra [ ("token", "bad") ]);
  let revocation =
    O.Revocation.make ~token:"token-secret" ~hint:`Refresh_token ()
    |> O.Revocation.with_extra [ ("resource", "api") ]
    |> expect_ok "revocation"
  in
  check_params "revocation params"
    [
      ("token", "token-secret");
      ("token_type_hint", "refresh_token");
      ("resource", "api");
    ]
    (grant_params
       (O.Revocation.request
          ~client:(client "revoke-client" None)
          ~endpoint:(Uri.of_string "https://provider.example/revoke")
          revocation));
  let revocation_request =
    O.Revocation.request
      ~client:(client "client-id" (Some (`Secret_basic "client-secret")))
      ~endpoint:(Uri.of_string "https://provider.example/revoke")
      revocation
  in
  check_params "revocation request params"
    [
      ("token", "token-secret");
      ("token_type_hint", "refresh_token");
      ("resource", "api");
    ]
    (request_params revocation_request);
  (match O.Request.headers revocation_request with
  | [ ("Authorization", header) ] ->
      equal string ~msg:"revocation basic header"
        "Basic Y2xpZW50LWlkOmNsaWVudC1zZWNyZXQ=" header
  | headers ->
      failf
        "revocation basic headers: expected one Authorization header, got %d"
        (List.length headers));
  ignore
    (expect_ok "revocation decode success"
       (O.Request.decode revocation_request
          {
            O.Response.status = 200;
            O.Response.headers = [];
            O.Response.body = "";
          })
      : unit)

let secret_safety () =
  let token =
    expect_ok "secret token parse"
      (O.Token.parse
         (json_object
            [
              ("access_token", Json.string "access-secret");
              ("token_type", Json.string "Bearer");
              ("refresh_token", Json.string "refresh-secret");
              ("client_secret", Json.string "client-secret");
              ("device_code", Json.string "device-secret");
              ("authorization_code", Json.string "code-secret");
              ("id_token", Json.string "id-secret");
            ]))
  in
  let rendered_token = Format.asprintf "%a" O.Token.pp token in
  List.iter
    (fun (msg, secret) -> check_lacks msg ~needle:secret rendered_token)
    [
      ("token pp hides access token", "access-secret");
      ("token pp hides refresh token", "refresh-secret");
      ("token pp hides client secret", "client-secret");
      ("token pp hides device code", "device-secret");
      ("token pp hides authorization code", "code-secret");
      ("token pp hides unknown id token", "id-secret");
    ];
  let malformed =
    {
      O.field = Some "device_code";
      message = "bad device code";
      raw =
        Some
          (json_object
             [
               ("client_secret", Json.string "client-secret");
               ("device_code", Json.string "device-secret");
               ("authorization_code", Json.string "code-secret");
             ]);
    }
  in
  let rendered_malformed = Format.asprintf "%a" O.pp_malformed malformed in
  List.iter
    (fun (msg, secret) -> check_lacks msg ~needle:secret rendered_malformed)
    [
      ("malformed pp hides client secret", "client-secret");
      ("malformed pp hides device code", "device-secret");
      ("malformed pp hides authorization code", "code-secret");
    ]

let expect_malformed_field msg field = function
  | Ok _ -> failf "%s: expected malformed" msg
  | Error (malformed : O.malformed) ->
      equal (option string) ~msg (Some field) malformed.O.field

let json_accessors () =
  let json =
    expect_ok "json parse"
      (O.Json.parse
         {|{"name":"x","count":3,"link":"https://provider.example/doc","dup":"a","dup":"b","nil":null}|})
  in
  (match O.Json.parse "{" with
  | Error malformed ->
      is_true ~msg:"invalid JSON is malformed"
        (String.includes ~affix:"invalid JSON" malformed.O.message)
  | Ok _ -> failf "parse invalid JSON: expected malformed");
  is_true ~msg:"field returns a present binding"
    (Option.is_some (O.Json.field "name" json));
  is_true ~msg:"field on an absent key is None"
    (Option.is_none (O.Json.field "missing" json));
  (* required: present, missing, duplicate. *)
  equal string ~msg:"required decodes a present field" "x"
    (expect_ok "required name" (O.Json.required "name" O.Json.string json));
  expect_malformed_field "required rejects a missing field" "missing"
    (O.Json.required "missing" O.Json.string json);
  expect_malformed_field "required rejects a duplicate field" "dup"
    (O.Json.required "dup" O.Json.string json);
  (* optional: present, absent, JSON null, duplicate. *)
  equal (option string) ~msg:"optional decodes a present field" (Some "x")
    (expect_ok "optional name" (O.Json.optional "name" O.Json.string json));
  equal (option string) ~msg:"optional treats an absent field as None" None
    (expect_ok "optional missing"
       (O.Json.optional "missing" O.Json.string json));
  equal (option string) ~msg:"optional treats a JSON null as None" None
    (expect_ok "optional null" (O.Json.optional "nil" O.Json.string json));
  expect_malformed_field "optional rejects a duplicate field" "dup"
    (O.Json.optional "dup" O.Json.string json);
  (* typed decoders and their malformed field reporting. *)
  equal int ~msg:"int decodes a JSON integer" 3
    (expect_ok "required count" (O.Json.required "count" O.Json.int json));
  equal string ~msg:"uri decodes a JSON string" "https://provider.example/doc"
    (Uri.to_string
       (expect_ok "required link" (O.Json.required "link" O.Json.uri json)));
  expect_malformed_field "string rejects a non-string value" "count"
    (O.Json.required "count" O.Json.string json);
  expect_malformed_field "int rejects a non-integer value" "name"
    (O.Json.required "name" O.Json.int json)

let error_description_null () =
  let json =
    expect_ok "error json"
      (O.Json.parse {|{"error":"invalid_grant","error_description":null}|})
  in
  match O.Error.parse_json json with
  | Ok (Some error) ->
      equal string ~msg:"null error_description keeps the error code"
        "invalid_grant" (O.Error.code error);
      equal (option string)
        ~msg:"a JSON null error_description is treated as absent" None
        (O.Error.description error)
  | Ok None -> failf "error_description null: expected an OAuth error"
  | Error malformed ->
      failf "error_description null: unexpected malformed %a" O.pp_malformed
        malformed

let () =
  run "oauth2.core"
    [
      group "parameters" [ test "preserve and encode parameters" params ];
      group "json"
        [
          test "decodes provider JSON with shared accessors" json_accessors;
          test "treats a JSON null error field as absent" error_description_null;
        ];
      group "client"
        [ test "compiles client authentication requests" client_auth_requests ];
      group "authorization"
        [
          test "builds and validates PKCE" pkce;
          test "builds authorization requests" authorization_request;
          test "parses callbacks" callback;
        ];
      group "responses"
        [
          test "classifies raw OAuth responses" response_helpers;
          test "parses and redacts tokens" token;
          test "parses device authorization responses" device_authorization;
          test "does not print secret-bearing values" secret_safety;
        ];
      group "requests"
        [ test "builds grants and revocation requests" grants_and_revocation ];
    ]
