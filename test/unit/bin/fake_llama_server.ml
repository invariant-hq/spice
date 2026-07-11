(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* A stand-in for llama-server used by test_llm_local. It accepts the argv
   shape Spice_llm_local passes to the real binary, binds the requested
   loopback port, answers [GET /health] with 200, and answers
   [POST /v1/chat/completions] with the SSE body read from the file named by
   SPICE_FAKE_LLAMA_SSE. When SPICE_FAKE_LLAMA_DUMP is set, each chat request
   body is written there (truncating), so the test can assert on the encoded
   request. Runs until killed. *)

let port_of_argv () =
  let rec loop = function
    | "--port" :: port :: _ -> int_of_string port
    | _ :: rest -> loop rest
    | [] -> failwith "fake_llama_server: missing --port"
  in
  loop (Array.to_list Sys.argv)

let strip_cr line =
  if String.ends_with ~suffix:"\r" line then
    String.sub line 0 (String.length line - 1)
  else line

let read_request ic =
  let request_line = strip_cr (input_line ic) in
  let rec headers acc =
    let line = strip_cr (input_line ic) in
    if String.equal line "" then List.rev acc
    else
      let header =
        match String.index_opt line ':' with
        | None -> (String.lowercase_ascii line, "")
        | Some i ->
            ( String.lowercase_ascii (String.sub line 0 i),
              String.trim (String.sub line (i + 1) (String.length line - i - 1))
            )
      in
      headers (header :: acc)
  in
  let headers = headers [] in
  let content_length =
    match List.assoc_opt "content-length" headers with
    | None -> 0
    | Some value -> ( try int_of_string value with Failure _ -> 0)
  in
  let body = really_input_string ic content_length in
  (request_line, body)

let respond fd ?(content_type = "application/json") status body =
  let text =
    Printf.sprintf
      "HTTP/1.1 %d Status\r\n\
       Content-Type: %s\r\n\
       Content-Length: %d\r\n\
       Connection: close\r\n\
       \r\n\
       %s"
      status content_type (String.length body) body
  in
  let bytes = Bytes.of_string text in
  ignore (Unix.write fd bytes 0 (Bytes.length bytes))

let partial_health fd =
  let text =
    "HTTP/1.1 200 OK\r\n\
     Content-Type: application/json\r\n\
     Content-Length: 128\r\n\
     Connection: close\r\n\
     \r\n\
     {"
  in
  let bytes = Bytes.of_string text in
  ignore (Unix.write fd bytes 0 (Bytes.length bytes));
  let byte = Bytes.create 1 in
  let rec wait_for_close () =
    match Unix.read fd byte 0 1 with 0 -> () | _ -> wait_for_close ()
  in
  wait_for_close ()

let append_line path line =
  let output = open_out_gen [ Open_creat; Open_append; Open_text ] 0o600 path in
  output_string output line;
  output_char output '\n';
  close_out_noerr output

let getenv_nonempty name =
  match Sys.getenv_opt name with
  | Some value when not (String.is_empty value) -> Some value
  | Some _ | None -> None

let enabled name = Option.is_some (getenv_nonempty name)

let record name value =
  Option.iter (fun path -> append_line path value) (getenv_nonempty name)

let rec accept socket =
  match Unix.accept socket with
  | client -> client
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> accept socket

let file_contents path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let () =
  let port = port_of_argv () in
  record "SPICE_FAKE_LLAMA_PID_FILE" (string_of_int (Unix.getpid ()));
  if enabled "SPICE_FAKE_LLAMA_IGNORE_TERM" then
    Sys.set_signal Sys.sigterm
      (Sys.Signal_handle (fun _ ->
           record "SPICE_FAKE_LLAMA_TERM_FILE" "term"));
  if enabled "SPICE_FAKE_LLAMA_EXIT_BEFORE_BIND" then exit 23;
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
  Unix.listen socket 8;
  let health_requests = ref 0 in
  let partial_health_count =
    match Sys.getenv_opt "SPICE_FAKE_LLAMA_PARTIAL_HEALTH_COUNT" with
    | None -> 0
    | Some value -> Option.value (int_of_string_opt value) ~default:0
  in
  while true do
    let client, _ = accept socket in
    Fun.protect
      ~finally:(fun () -> try Unix.close client with Unix.Unix_error _ -> ())
      (fun () ->
        let ic = Unix.in_channel_of_descr client in
        match read_request ic with
        | exception End_of_file -> ()
        | request_line, body ->
            if String.starts_with ~prefix:"GET /health" request_line then begin
              incr health_requests;
              Option.iter
                (fun path ->
                  if not (String.is_empty path) then
                    append_line path (string_of_int !health_requests))
                (Sys.getenv_opt "SPICE_FAKE_LLAMA_HEALTH_DUMP");
              if enabled "SPICE_FAKE_LLAMA_UNHEALTHY" then
                respond client 503 {|{"status":"loading"}|}
              else if !health_requests <= partial_health_count then
                partial_health client
              else respond client 200 {|{"status":"ok"}|}
            end
            else if
              String.starts_with ~prefix:"POST /v1/chat/completions"
                request_line
            then begin
              (match Sys.getenv_opt "SPICE_FAKE_LLAMA_DUMP" with
              | Some path when not (String.equal path "") ->
                  let oc = open_out_bin path in
                  output_string oc body;
                  close_out_noerr oc
              | Some _ | None -> ());
              begin match Sys.getenv_opt "SPICE_FAKE_LLAMA_SSE" with
              | Some path when not (String.equal path "") ->
                  respond client ~content_type:"text/event-stream" 200
                    (file_contents path)
              | Some _ | None ->
                  respond client 500 {|{"error":{"message":"no scenario"}}|}
              end;
              if enabled "SPICE_FAKE_LLAMA_EXIT_AFTER_CHAT" then exit 0
            end
            else respond client 404 {|{"error":{"message":"not found"}}|})
  done
