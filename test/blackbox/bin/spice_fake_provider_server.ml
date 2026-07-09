(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Json = Jsont.Json

type options = {
  script : string;
  capture : string;
  port_file : string;
  accept_timeout_s : float;
  unordered : bool;
}

type request = {
  request_line_text : string;
  headers : (string * string) list;
  body : string;
}

type expectation = {
  request_line : string option;
  body_contains : string list;
  body_not_contains : string list;
}

type reply =
  | Sse of Jsont.json  (** Responses-API completion wrapped as one SSE event. *)
  | Http of { status : int; body : Jsont.json }
      (** Plain HTTP reply with a JSON body, for non-streaming endpoints. *)

type script_item = {
  expect : expectation option;
  delay_ms : int option;
  stream_delay_ms : int option;
  reply : reply;
}

let fail message =
  prerr_endline ("spice_fake_provider_server: " ^ message);
  exit 2

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> fail ("JSON encode failed: " ^ message)

let json_of_string path line =
  match Jsont_bytesrw.decode_string Jsont.json line with
  | Ok json -> json
  | Error message -> fail (path ^ ": JSON decode failed: " ^ message)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field object_name name json =
  match object_field name json with
  | None -> None
  | Some (Jsont.String (value, _)) -> Some value
  | Some value ->
      fail
        (Printf.sprintf "%s.%s must be a string, got %s" object_name name
           (json_string value))

let string_list_field object_name name json =
  match object_field name json with
  | None -> []
  | Some (Jsont.Array (items, _)) ->
      List.mapi
        (fun index -> function
          | Jsont.String (value, _) -> value
          | value ->
              fail
                (Printf.sprintf "%s.%s[%d] must be a string, got %s" object_name
                   name index (json_string value)))
        items
  | Some value ->
      fail
        (Printf.sprintf "%s.%s must be an array of strings, got %s" object_name
           name (json_string value))

let expectation_of_json json =
  {
    request_line = string_field "expect" "request_line" json;
    body_contains = string_list_field "expect" "body_contains" json;
    body_not_contains = string_list_field "expect" "body_not_contains" json;
  }

let int_field object_name name json =
  match object_field name json with
  | None -> None
  | Some value -> (
      match Json.decode Jsont.int value with
      | Ok value -> Some value
      | Error _ ->
          fail (Printf.sprintf "%s.%s must be an integer" object_name name))

let script_item_of_json json =
  let expect =
    match object_field "expect" json with
    | None -> None
    | Some expect -> Some (expectation_of_json expect)
  in
  let delay_ms = int_field "script item" "delay_ms" json in
  let stream_delay_ms = int_field "script item" "stream_delay_ms" json in
  match object_field "http" json with
  | Some http ->
      let status = Option.value (int_field "http" "status" http) ~default:200 in
      let body =
        Option.value (object_field "json" http) ~default:(Json.object' [])
      in
      { expect; delay_ms; stream_delay_ms; reply = Http { status; body } }
  | None -> (
      match object_field "response" json with
      | None -> { expect = None; delay_ms; stream_delay_ms; reply = Sse json }
      | Some response ->
          { expect; delay_ms; stream_delay_ms; reply = Sse response })

let read_lines path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let rec loop acc =
        match input_line input with
        | line ->
            let line = String.trim line in
            if String.is_empty line then loop acc else loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let load_script path =
  match List.map (json_of_string path) (read_lines path) with
  | [] -> fail (path ^ ": script must contain at least one response")
  | items -> List.map script_item_of_json items

let strip_cr line =
  if String.ends_with ~suffix:"\r" line then String.drop_last 1 line else line

let split_header line =
  match String.split_first ~sep:":" line with
  | None -> (String.lowercase_ascii line, "")
  | Some (name, value) ->
      let name = String.lowercase_ascii name in
      let value = String.trim value in
      (name, value)

let header request name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    request.headers

let read_http_request fd : request =
  let input = Unix.in_channel_of_descr fd in
  let request_line = input_line input |> strip_cr in
  let rec read_headers acc =
    let line = input_line input |> strip_cr in
    if String.is_empty line then List.rev acc
    else read_headers (split_header line :: acc)
  in
  let headers = read_headers [] in
  let request : request =
    { request_line_text = request_line; headers; body = "" }
  in
  let content_length =
    match header request "content-length" with
    | None -> 0
    | Some value -> Option.value (int_of_string_opt value) ~default:0
  in
  let body = really_input_string input content_length in
  { request_line_text = request_line; headers; body }

let mkdir_p path =
  let rec loop path =
    if String.is_empty path || Sys.file_exists path then ()
    else (
      loop (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  loop path

let write_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () -> output_string output content)

let capture_request capture index request =
  let path = Filename.concat capture (Printf.sprintf "request-%d.json" index) in
  write_file path request.body;
  let headers_path =
    Filename.concat capture (Printf.sprintf "request-%d.headers" index)
  in
  request.headers
  |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\n")
  |> String.concat "" |> write_file headers_path

(* Non-fatal expectation test, for unordered matching. *)
let expectation_matches (expectation : expectation) (request : request) =
  Option.fold ~none:true
    ~some:(fun expected -> String.equal expected request.request_line_text)
    expectation.request_line
  && List.for_all
       (fun substring -> String.includes ~affix:substring request.body)
       expectation.body_contains
  && List.for_all
       (fun substring -> not (String.includes ~affix:substring request.body))
       expectation.body_not_contains

let check_expectation index (expectation : expectation) (request : request) =
  let request_label = Printf.sprintf "request %d" index in
  Option.iter
    (fun expected ->
      if not (String.equal expected request.request_line_text) then
        fail
          (Printf.sprintf "%s: expected request line %S, got %S" request_label
             expected request.request_line_text))
    expectation.request_line;
  List.iter
    (fun substring ->
      if not (String.includes ~affix:substring request.body) then
        fail
          (Printf.sprintf "%s: expected body to contain %S" request_label
             substring))
    expectation.body_contains;
  List.iter
    (fun substring ->
      if String.includes ~affix:substring request.body then
        fail
          (Printf.sprintf "%s: expected body not to contain %S" request_label
             substring))
    expectation.body_not_contains

let sse_event response =
  let data =
    Json.object'
      [
        Json.mem (Json.name "type") (Json.string "response.completed");
        Json.mem (Json.name "response") response;
      ]
  in
  "event: response.completed\n" ^ "data: " ^ json_string data ^ "\n\n"

let json_array = function
  | Jsont.Array (items, _) -> items
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Object _ ->
      []

(* A visible fragment of a completed Responses payload, streamed as deltas
   before the terminal event. The terminal [response.completed] still carries
   the whole payload, so fragments are display-only and never change the
   collected response. *)
type fragment = Text of string | Reasoning of string

let response_fragments response =
  match object_field "output" response with
  | None -> []
  | Some output ->
      json_array output
      |> List.concat_map (fun item ->
          match string_field "output item" "type" item with
          | Some "message" -> (
              match object_field "content" item with
              | None -> []
              | Some content ->
                  json_array content
                  |> List.filter_map (fun part ->
                      match string_field "content part" "type" part with
                      | Some "output_text" ->
                          Option.map
                            (fun text -> Text text)
                            (string_field "content part" "text" part)
                      | _ -> None))
          | Some "reasoning" -> (
              match object_field "summary" item with
              | None -> []
              | Some summary ->
                  json_array summary
                  |> List.filter_map (fun part ->
                      Option.map
                        (fun text -> Reasoning text)
                        (string_field "summary part" "text" part)))
          | _ -> [])

(* Split [s] into up to three UTF-8-safe chunks so a single fragment streams as
   several deltas. A split never breaks a codepoint; boundaries are arbitrary
   because the terminal response, not the concatenated deltas, is authoritative. *)
let chunk_text s =
  let n = String.length s in
  if n = 0 then []
  else
    let starts =
      let rec loop i acc =
        if i >= n then List.rev acc
        else
          let c = Char.code (String.get s i) in
          let width =
            if c < 0x80 then 1
            else if c < 0xE0 then 2
            else if c < 0xF0 then 3
            else 4
          in
          loop (min n (i + width)) (i :: acc)
      in
      Array.of_list (loop 0 [])
    in
    let total = Array.length starts in
    let parts = min 3 total in
    let per = (total + parts - 1) / parts in
    let rec build i acc =
      if i >= total then List.rev acc
      else
        let stop_index = min total (i + per) in
        let start = starts.(i) in
        let stop = if stop_index >= total then n else starts.(stop_index) in
        build stop_index (String.sub s start (stop - start) :: acc)
    in
    build 0 []

let sse_delta name delta =
  let data =
    Json.object'
      [
        Json.mem (Json.name "type") (Json.string name);
        Json.mem (Json.name "delta") (Json.string delta);
      ]
  in
  "event: " ^ name ^ "\ndata: " ^ json_string data ^ "\n\n"

(* The completed payload split into its streamed OpenAI Responses delta events —
   visible text and reasoning fragments in output order — and the terminal
   [response.completed] event that follows them. Keeping the two apart lets the
   server pace the stream ([stream_delay_ms]): flush the deltas, hold, then send
   the terminal event, so a client observes streamed-but-unsettled content. The
   collected response stays exactly the terminal payload either way. *)
let sse_parts response =
  let deltas =
    response_fragments response
    |> List.concat_map (fun fragment ->
        let name, text =
          match fragment with
          | Text text -> ("response.output_text.delta", text)
          | Reasoning text -> ("response.reasoning_summary_text.delta", text)
        in
        List.map (sse_delta name) (chunk_text text))
  in
  (String.concat "" deltas, sse_event response)

let status_reason = function
  | 200 -> "OK"
  | 400 -> "Bad Request"
  | 401 -> "Unauthorized"
  | 402 -> "Payment Required"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 429 -> "Too Many Requests"
  | 500 -> "Internal Server Error"
  | 503 -> "Service Unavailable"
  | _ -> "Status"

let http_head ?(status = 200) ?(content_type = "text/event-stream")
    ~content_length () =
  let headers =
    [
      ("Content-Type", content_type);
      ("Content-Length", string_of_int content_length);
      ("Connection", "close");
    ]
  in
  let header_text =
    headers
    |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n")
    |> String.concat ""
  in
  Printf.sprintf "HTTP/1.1 %d %s\r\n%s\r\n" status (status_reason status)
    header_text

let http_response ?status ?content_type body =
  http_head ?status ?content_type ~content_length:(String.length body) () ^ body

let write_all fd text =
  let bytes = Bytes.of_string text in
  let rec loop offset =
    if offset < Bytes.length bytes then
      let written = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + written)
  in
  loop 0

let port_of_socket socket =
  match Unix.getsockname socket with
  | Unix.ADDR_INET (address, port) ->
      ignore (Unix.string_of_inet_addr address);
      port
  | Unix.ADDR_UNIX path -> fail ("expected inet socket, got unix socket " ^ path)

let accept_request socket index timeout =
  match Unix.select [ socket ] [] [] timeout with
  | [], _, _ ->
      fail
        (Printf.sprintf "timed out waiting for request %d after %.1fs" index
           timeout)
  | _ ->
      let accepted = Unix.accept socket in
      fst accepted

(* Send the reply, honoring [stream_delay_ms] on SSE replies: flush the HTTP head
   plus the delta events, hold, then send the terminal event. Content-Length
   still spans the whole body, so the split is invisible to the client beyond the
   delivery gap. An SSE reply with no [stream_delay_ms] writes head and body in a
   single call, byte-identical to the pre-pacing path. *)
let send_reply client item =
  match item.reply with
  | Http { status; body } ->
      write_all client
        (http_response ~status ~content_type:"application/json"
           (json_string body))
  | Sse response -> (
      let deltas, terminal = sse_parts response in
      match item.stream_delay_ms with
      | None -> write_all client (http_response (deltas ^ terminal))
      | Some stream_delay_ms ->
          let content_length = String.length deltas + String.length terminal in
          write_all client (http_head ~content_length () ^ deltas);
          Unix.sleepf (float_of_int stream_delay_ms /. 1000.);
          write_all client terminal)

let handle_client options client item ~arrival request =
  capture_request options.capture arrival request;
  Option.iter
    (fun delay_ms -> Unix.sleepf (float_of_int delay_ms /. 1000.))
    item.delay_ms;
  send_reply client item

(* Sequential service: request N must satisfy script item N. *)
let serve_ordered options socket items =
  List.iteri
    (fun index item ->
      let client = accept_request socket (index + 1) options.accept_timeout_s in
      Fun.protect
        ~finally:(fun () -> Unix.close client)
        (fun () ->
          let request = read_http_request client in
          Option.iter
            (fun expectation ->
              check_expectation (index + 1) expectation request)
            item.expect;
          handle_client options client item ~arrival:(index + 1) request))
    items

(* Unordered service: each arriving request consumes the first pending item
   whose expectation it satisfies (an item with no expectation matches any
   request). Concurrent callers — a parent session and its detached children —
   arrive in nondeterministic order; matching by content keeps the script
   deterministic. Captures are numbered by arrival order. *)
let serve_unordered options socket items =
  let pending = Array.of_list (List.map Option.some items) in
  let total = Array.length pending in
  let match_index request =
    let rec loop i =
      if i >= total then None
      else
        match pending.(i) with
        | Some item
          when Option.fold ~none:true
                 ~some:(fun expectation ->
                   expectation_matches expectation request)
                 item.expect ->
            Some (i, item)
        | Some _ | None -> loop (i + 1)
    in
    loop 0
  in
  for arrival = 1 to total do
    let client = accept_request socket arrival options.accept_timeout_s in
    Fun.protect
      ~finally:(fun () -> Unix.close client)
      (fun () ->
        let request = read_http_request client in
        match match_index request with
        | None ->
            fail
              (Printf.sprintf
                 "request %d matched no pending script item; body: %s" arrival
                 (String.sub request.body 0
                    (min 400 (String.length request.body))))
        | Some (i, item) ->
            pending.(i) <- None;
            handle_client options client item ~arrival request)
  done

let serve options items =
  mkdir_p options.capture;
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen socket 8;
      write_file options.port_file (string_of_int (port_of_socket socket));
      if options.unordered then serve_unordered options socket items
      else serve_ordered options socket items)

let usage =
  "Usage: spice_fake_provider_server --script FILE --capture DIR --port-file \
   FILE"

let parse_args () =
  let script = ref None in
  let capture = ref None in
  let port_file = ref None in
  let accept_timeout_s = ref 10. in
  let unordered = ref false in
  let set option value slot =
    match !slot with
    | None -> slot := Some value
    | Some _ -> fail ("duplicate " ^ option)
  in
  let rec loop = function
    | [] -> ()
    | "--script" :: value :: rest ->
        set "--script" value script;
        loop rest
    | "--responses" :: value :: rest ->
        set "--responses" value script;
        loop rest
    | "--capture" :: value :: rest ->
        set "--capture" value capture;
        loop rest
    | "--port-file" :: value :: rest ->
        set "--port-file" value port_file;
        loop rest
    | "--unordered" :: rest ->
        unordered := true;
        loop rest
    | "--accept-timeout" :: value :: rest -> (
        match float_of_string_opt value with
        | Some value when value > 0. ->
            accept_timeout_s := value;
            loop rest
        | _ -> fail "--accept-timeout must be a positive number")
    | "--help" :: [] ->
        print_endline usage;
        exit 0
    | option :: _ when String.starts_with ~prefix:"--" option ->
        fail ("unknown option " ^ option)
    | arg :: _ -> fail ("unexpected argument " ^ arg)
  in
  let argv = Array.to_list Sys.argv |> List.tl in
  loop argv;
  match (!script, !capture, !port_file) with
  | Some script, Some capture, Some port_file ->
      {
        script;
        capture;
        port_file;
        accept_timeout_s = !accept_timeout_s;
        unordered = !unordered;
      }
  | _ -> fail usage

let () =
  let options = parse_args () in
  let items = load_script options.script in
  serve options items
