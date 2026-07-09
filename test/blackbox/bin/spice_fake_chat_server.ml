(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* An OpenAI-compatible chat-completions fixture server, the wire surface a
   self-hosted server (llama.cpp, vLLM, LM Studio) and Ollama's [/v1] endpoint
   expose. It is the chat-completions counterpart to
   [spice_fake_provider_server], which speaks the OpenAI Responses protocol.

   It binds a loopback port, writes it to [--port-file], answers [GET /health]
   with 200, and answers [POST /v1/chat/completions] with a streamed SSE body:
   a couple of content deltas, a terminal chunk carrying [finish_reason] and
   usage, then [[DONE]]. Each request's body and headers are captured under
   [--capture] as [request-N.json] and [request-N.headers], so a cram test can
   assert on the encoded request and the authorization header. It serves
   [--requests] requests (default 1) and exits, so [wait] on it returns. *)

type options = {
  capture : string;
  port_file : string;
  reply : string;
  requests : int;
  accept_timeout_s : float;
}

let fail message =
  prerr_endline ("spice_fake_chat_server: " ^ message);
  exit 2

let strip_cr line =
  if String.length line > 0 && line.[String.length line - 1] = '\r' then
    String.sub line 0 (String.length line - 1)
  else line

let split_header line =
  match String.index_opt line ':' with
  | None -> (String.lowercase_ascii line, "")
  | Some i ->
      ( String.lowercase_ascii (String.sub line 0 i),
        String.trim (String.sub line (i + 1) (String.length line - i - 1)) )

type request = {
  request_line : string;
  headers : (string * string) list;
  body : string;
}

let read_http_request fd =
  let input = Unix.in_channel_of_descr fd in
  let request_line = input_line input |> strip_cr in
  let rec read_headers acc =
    let line = input_line input |> strip_cr in
    if line = "" then List.rev acc else read_headers (split_header line :: acc)
  in
  let headers = read_headers [] in
  let content_length =
    match List.assoc_opt "content-length" headers with
    | None -> 0
    | Some value -> Option.value (int_of_string_opt value) ~default:0
  in
  let body = really_input_string input content_length in
  { request_line; headers; body }

let mkdir_p path =
  let rec loop path =
    if path = "" || Sys.file_exists path then ()
    else (
      loop (Filename.dirname path);
      try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  loop path

let write_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () -> output_string output content)

let capture_request capture index request =
  write_file
    (Filename.concat capture (Printf.sprintf "request-%d.json" index))
    request.body;
  request.headers
  |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\n")
  |> String.concat ""
  |> write_file
       (Filename.concat capture (Printf.sprintf "request-%d.headers" index))

let json_escape s =
  let buffer = Buffer.create (String.length s + 2) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | c -> Buffer.add_char buffer c)
    s;
  Buffer.contents buffer

(* One [chat.completion.chunk] SSE data line carrying [delta]. *)
let sse_delta delta =
  Printf.sprintf
    "data: \
     {\"id\":\"chatcmpl-fixture\",\"object\":\"chat.completion.chunk\",\"model\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":%s,\"finish_reason\":null}]}\n\n"
    delta

let sse_body reply =
  let words = String.split_on_char ' ' reply in
  let deltas =
    sse_delta {|{"role":"assistant"}|}
    :: List.map
         (fun word ->
           sse_delta (Printf.sprintf {|{"content":"%s "}|} (json_escape word)))
         words
  in
  let terminal =
    "data: \
     {\"id\":\"chatcmpl-fixture\",\"object\":\"chat.completion.chunk\",\"model\":\"fixture\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":6,\"total_tokens\":11}}\n\n"
  in
  String.concat "" deltas ^ terminal ^ "data: [DONE]\n\n"

let write_all fd text =
  let bytes = Bytes.of_string text in
  let rec loop offset =
    if offset < Bytes.length bytes then
      let written = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + written)
  in
  loop 0

let http_head ~content_type ~content_length =
  Printf.sprintf
    "HTTP/1.1 200 OK\r\n\
     Content-Type: %s\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n"
    content_type content_length

let respond_health client =
  let body = {|{"status":"ok"}|} in
  write_all client
    (http_head ~content_type:"application/json"
       ~content_length:(String.length body)
    ^ body)

let respond_not_found client =
  write_all client
    "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

let respond_chat client reply =
  let body = sse_body reply in
  write_all client
    (http_head ~content_type:"text/event-stream"
       ~content_length:(String.length body)
    ^ body)

let request_path request =
  match String.split_on_char ' ' request.request_line with
  | _meth :: path :: _ -> path
  | _ -> request.request_line

let handle options client index request =
  capture_request options.capture index request;
  let path = request_path request in
  (* Tolerate a trailing slash so a base URL with or without one both match. *)
  let path =
    if String.length path > 1 && String.ends_with ~suffix:"/" path then
      String.sub path 0 (String.length path - 1)
    else path
  in
  if String.ends_with ~suffix:"/health" path then respond_health client
  else if String.ends_with ~suffix:"/chat/completions" path then
    respond_chat client options.reply
  else respond_not_found client

let accept_request socket index timeout =
  match Unix.select [ socket ] [] [] timeout with
  | [], _, _ ->
      fail
        (Printf.sprintf "timed out waiting for request %d after %.1fs" index
           timeout)
  | _ -> fst (Unix.accept socket)

let serve options =
  mkdir_p options.capture;
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.setsockopt socket Unix.SO_REUSEADDR true;
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen socket 8;
      let port =
        match Unix.getsockname socket with
        | Unix.ADDR_INET (_, port) -> port
        | Unix.ADDR_UNIX path -> fail ("expected inet socket, got " ^ path)
      in
      write_file options.port_file (string_of_int port);
      for index = 1 to options.requests do
        let client = accept_request socket index options.accept_timeout_s in
        Fun.protect
          ~finally:(fun () -> Unix.close client)
          (fun () -> handle options client index (read_http_request client))
      done)

let usage =
  "Usage: spice_fake_chat_server --capture DIR --port-file FILE [--reply TEXT] \
   [--requests N]"

let parse_args () =
  let capture = ref None in
  let port_file = ref None in
  let reply = ref "ollama compat reply" in
  let requests = ref 1 in
  let accept_timeout_s = ref 10. in
  let rec loop = function
    | [] -> ()
    | "--capture" :: value :: rest ->
        capture := Some value;
        loop rest
    | "--port-file" :: value :: rest ->
        port_file := Some value;
        loop rest
    | "--reply" :: value :: rest ->
        reply := value;
        loop rest
    | "--requests" :: value :: rest -> (
        match int_of_string_opt value with
        | Some n when n > 0 ->
            requests := n;
            loop rest
        | _ -> fail "--requests must be a positive integer")
    | "--accept-timeout" :: value :: rest -> (
        match float_of_string_opt value with
        | Some value when value > 0. ->
            accept_timeout_s := value;
            loop rest
        | _ -> fail "--accept-timeout must be a positive number")
    | "--help" :: _ ->
        print_endline usage;
        exit 0
    | option :: _ -> fail ("unexpected argument " ^ option)
  in
  loop (List.tl (Array.to_list Sys.argv));
  match (!capture, !port_file) with
  | Some capture, Some port_file ->
      {
        capture;
        port_file;
        reply = !reply;
        requests = !requests;
        accept_timeout_s = !accept_timeout_s;
      }
  | _ -> fail usage

let () = serve (parse_args ())
