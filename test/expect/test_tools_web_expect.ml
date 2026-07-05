(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Access = Spice_permission.Access
module Fetch = Spice_tools.Web_fetch
module Json = Jsont.Json
module Request = Spice_permission.Request
module Search = Spice_tools.Web_search
module Tool = Spice_tool
module Web = Spice_tools.Web

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let print_case name = Printf.printf "-- %s --\n" name

let print_url value =
  match Web.Url.of_string ~allow_private_network:false value with
  | Ok url ->
      Printf.printf "url ok: %s origin=%s\n" (Web.Url.to_string url)
        (Web.Url.origin url)
  | Error error -> Printf.printf "url error: %s\n" (Web.Url.error_message error)

let print_ipaddr label raw =
  let address = Eio.Net.Ipaddr.of_raw raw in
  Printf.printf "%s private=%b\n" label (Web.Url.private_ipaddr address)

let print_request request =
  Printf.printf "source: %s\n"
    (Option.value (Request.source request) ~default:"-");
  Request.accesses request
  |> List.iter (function
    | Access.Network { protocol; host; port } ->
        let protocol =
          match protocol with
          | `Http -> "http"
          | `Https -> "https"
          | `Ssh -> "ssh"
          | `Tcp -> "tcp"
          | `Udp -> "udp"
          | `Other protocol -> protocol
        in
        Printf.printf "network %s %s %s\n" protocol host
          (Option.value (Option.map string_of_int port) ~default:"-")
    | Access.Path _ | Access.Command _ | Access.Custom _ ->
        Printf.printf "non-network\n")

let print_permissions permissions =
  match permissions with
  | [] -> Printf.printf "permissions: none\n"
  | requests -> List.iter print_request requests

let print_status = function
  | Tool.Result.Completed -> Printf.printf "completed\n"
  | Tool.Result.Failed { kind; message; metadata = _ } ->
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "interrupted cancelled=%b: %s\n" cancelled reason

let replace_first ~sub ~by text =
  let sub_length = String.length sub in
  let text_length = String.length text in
  let rec loop index =
    if index + sub_length > text_length then text
    else if String.equal sub (String.sub text index sub_length) then
      String.sub text 0 index ^ by
      ^ String.sub text (index + sub_length) (text_length - index - sub_length)
    else loop (index + 1)
  in
  loop 0

let display_url url =
  match (Web.Url.host url, Web.Url.port url) with
  | "127.0.0.1", Some port ->
      replace_first
        ~sub:(":" ^ string_of_int port)
        ~by:":PORT" (Web.Url.to_string url)
  | _ -> Web.Url.to_string url

let print_fetch_result result =
  print_status (Tool.Result.status result);
  match Tool.Result.output result with
  | None -> Printf.printf "output: none\n"
  | Some output -> (
      match Fetch.Output.status output with
      | Fetch.Output.Fetched { code; body; code_text = _ } ->
          Printf.printf "fetched %d %S truncated=%b omitted=%d\n" code
            body.Fetch.Output.content body.Fetch.Output.truncated
            body.Fetch.Output.omitted_chars
      | Fetch.Output.Redirected { code; from_url; to_url } ->
          Printf.printf "redirected %d %s -> %s\n" code (display_url from_url)
            (display_url to_url)
      | Fetch.Output.Http_error { code; code_text; preview } ->
          Printf.printf "http_error %d %s preview=%b\n" code code_text
            (Option.is_some preview))

let respond_string ?(headers = []) ~status ~body () =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list headers)
    ~status ~body ()

let with_server env callback f =
  Eio.Switch.run @@ fun sw ->
  let stop, stop_resolver = Eio.Promise.create () in
  let socket =
    Eio.Net.listen (Eio.Stdenv.net env) ~sw ~backlog:16 ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let server =
    Cohttp_eio.Server.make
      ~callback:(fun conn request body ->
        ignore conn;
        callback request body)
      ()
  in
  let server_error = ref None in
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

let test_fetch_https _uri raw = raw

let%expect_test "URL validation and policy permissions" =
  print_case "urls";
  print_url "https://Example.com:8443/docs?q=1";
  print_url "file:///tmp/readme";
  print_url "https://user@example.com/private";
  print_url "https://localhost/private";
  print_case "resolved addresses";
  print_ipaddr "93.184.216.34" "\093\184\216\034";
  print_ipaddr "127.0.0.1" "\127\000\000\001";
  print_ipaddr "::1"
    "\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\001";
  print_ipaddr "fd00::"
    "\253\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000";
  print_case "fetch permissions";
  let input = Fetch.Input.make "https://example.com/docs" in
  let disabled = Web.Policy.make () in
  print_permissions (Fetch.permissions ~policy:disabled input);
  let enabled = Web.Policy.make ~enabled:true () in
  print_permissions (Fetch.permissions ~policy:enabled input);
  print_case "fetch permission upgrade";
  let http_input = Fetch.Input.make "http://example.com/docs" in
  print_permissions (Fetch.permissions ~policy:enabled http_input);
  let no_upgrade =
    Web.Policy.make ~enabled:true ~upgrade_http_to_https:false ()
  in
  print_permissions (Fetch.permissions ~policy:no_upgrade http_input);
  [%expect
    {|
    -- urls --
    url ok: https://example.com:8443/docs?q=1 origin=https://example.com:8443
    url error: unsupported URL scheme: file
    url error: URL must not include username or password
    url error: private or local host is not allowed: localhost
    -- resolved addresses --
    93.184.216.34 private=false
    127.0.0.1 private=true
    ::1 private=true
    fd00:: private=true
    -- fetch permissions --
    permissions: none
    source: web_fetch
    network https example.com 443
    -- fetch permission upgrade --
    source: web_fetch
    network https example.com 443
    source: web_fetch
    network http example.com 80 |}]

let%expect_test "search input validation and permissions" =
  print_case "input";
  let input =
    Search.Input.make ~limit:3 ~allowed_domains:[ "Example.COM" ]
      ~blocked_domains:[ "ads.example.com" ] ~freshness:Search.Input.Week
      " spice web tools "
  in
  Printf.printf "query=%S limit=%d allowed=%s blocked=%s\n"
    (Search.Input.query input) (Search.Input.limit input)
    (String.concat "," (Search.Input.allowed_domains input))
    (String.concat "," (Search.Input.blocked_domains input));
  print_case "decode error";
  let bad =
    json_obj
      [
        ("query", Json.string "spice");
        ("allowed_domains", Json.list [ Json.string "*.example.com" ]);
      ]
  in
  begin match Search.Input.decode bad with
  | Ok _ -> Printf.printf "decode error=false\n"
  | Error _ -> Printf.printf "decode error=true\n"
  end;
  let bad_label =
    json_obj
      [
        ("query", Json.string "spice");
        ("allowed_domains", Json.list [ Json.string "example..com" ]);
      ]
  in
  begin match Search.Input.decode bad_label with
  | Ok _ -> Printf.printf "empty label error=false\n"
  | Error _ -> Printf.printf "empty label error=true\n"
  end;
  let bad_effort =
    json_obj
      [ ("query", Json.string "spice"); ("effort", Json.string "medium") ]
  in
  begin match Search.Input.decode bad_effort with
  | Ok _ -> Printf.printf "effort error=false\n"
  | Error _ -> Printf.printf "effort error=true\n"
  end;
  print_case "permissions";
  let disabled = Web.Policy.make ~enabled:true () in
  print_permissions (Search.permissions ~policy:disabled input);
  let brave =
    Web.Policy.make ~enabled:true
      ~search_backend:(Web.Policy.Brave { api_key = "secret" })
      ()
  in
  print_permissions (Search.permissions ~policy:brave input);
  [%expect
    {|
    -- input --
    query="spice web tools" limit=3 allowed=example.com blocked=ads.example.com
    -- decode error --
    decode error=true
    empty label error=true
    effort error=true
    -- permissions --
    permissions: none
    source: web_search
    network https api.search.brave.com 443 |}]

let%expect_test "web catalog selection" =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let http = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
  let fetch_https = test_fetch_https in
  let names policy =
    Spice_tools.web ~sw
      ~mono_clock:(Eio.Stdenv.mono_clock env)
      ~net:(Eio.Stdenv.net env) ~fetch_https ~http ~policy ()
    |> List.map Tool.name |> String.concat ","
  in
  Printf.printf "disabled: %s\n" (names (Web.Policy.make ()));
  Printf.printf "fetch: %s\n" (names (Web.Policy.make ~enabled:true ()));
  Printf.printf "fetch+search: %s\n"
    (names
       (Web.Policy.make ~enabled:true
          ~search_backend:(Web.Policy.Brave { api_key = "secret" })
          ()));
  [%expect
    {|
    disabled:
    fetch: web_fetch
    fetch+search: web_fetch,web_search |}]

let%expect_test "fetch local html as markdown" =
  Eio_main.run @@ fun env ->
  with_server env
    (fun request body ->
      ignore request;
      ignore body;
      respond_string ~status:`OK
        ~headers:[ ("content-type", "text/html; charset=utf-8") ]
        ~body:
          "<html><head><style>body{}</style></head><body><h1>Title</h1><p>Hello \
           &amp; goodbye.</p><script>alert(1)</script></body></html>"
        ())
    (fun ~sw ~base_uri ->
      let policy =
        Web.Policy.make ~enabled:true ~allow_private_network:true
          ~upgrade_http_to_https:false ~max_output_chars:200 ()
      in
      let https = test_fetch_https in
      let input =
        Fetch.Input.make ~format:Fetch.Input.Markdown (Uri.to_string base_uri)
      in
      Fetch.run ~sw
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~net:(Eio.Stdenv.net env) ~https ~policy input
      |> print_fetch_result);
  [%expect
    {|
    completed
    fetched 200 "# Title\n\nHello & goodbye." truncated=false omitted=0 |}]

let%expect_test "fetch redirect handling" =
  Eio_main.run @@ fun env ->
  with_server env
    (fun request body ->
      ignore body;
      match Uri.path (Cohttp.Request.uri request) with
      | "/same" ->
          respond_string ~status:`Found
            ~headers:[ ("location", "/target") ]
            ~body:"" ()
      | "/target" ->
          respond_string ~status:`OK
            ~headers:[ ("content-type", "text/plain; charset=utf-8") ]
            ~body:"redirected local" ()
      | "/cross" ->
          respond_string ~status:`Found
            ~headers:[ ("location", "http://example.com/elsewhere") ]
            ~body:"" ()
      | path -> respond_string ~status:`Not_found ~body:("missing " ^ path) ())
    (fun ~sw ~base_uri ->
      let policy =
        Web.Policy.make ~enabled:true ~allow_private_network:true
          ~upgrade_http_to_https:false ~max_output_chars:200 ()
      in
      let https = test_fetch_https in
      let fetch path =
        let url =
          Uri.resolve "" base_uri (Uri.of_string path) |> Uri.to_string
        in
        let input = Fetch.Input.make ~format:Fetch.Input.Text url in
        Fetch.run ~sw
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~net:(Eio.Stdenv.net env) ~https ~policy input
        |> print_fetch_result
      in
      print_case "same host";
      fetch "/same";
      print_case "cross host";
      fetch "/cross");
  [%expect
    {|
    -- same host --
    completed
    fetched 200 "redirected local" truncated=false omitted=0
    -- cross host --
    completed
    redirected 302 http://127.0.0.1:PORT/cross -> http://example.com/elsewhere |}]

[%%run_tests "spice.tools.web.expect"]
