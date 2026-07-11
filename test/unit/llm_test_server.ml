(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap

type request = {
  request_line : string;
  headers : (string * string) list;
  body : string;
}

type response = Reply of string | Hold | Hold_after of string

let strip_cr line =
  if String.ends_with ~suffix:"\r" line then String.drop_last 1 line else line

let split_header line =
  match String.split_first ~sep:":" line with
  | None -> (String.lowercase_ascii line, "")
  | Some (name, value) -> (String.lowercase_ascii name, String.trim value)

let header request name =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    request.headers

let read_request fd =
  let input = Unix.in_channel_of_descr fd in
  let request_line = input_line input |> strip_cr in
  let rec read_headers acc =
    let line = input_line input |> strip_cr in
    if String.is_empty line then List.rev acc
    else read_headers (split_header line :: acc)
  in
  let headers = read_headers [] in
  let content_length =
    match header { request_line; headers; body = "" } "content-length" with
    | None -> 0
    | Some value -> Option.value (int_of_string_opt value) ~default:0
  in
  let body = really_input_string input content_length in
  { request_line; headers; body }

let write_all fd text =
  let bytes = Bytes.unsafe_of_string text in
  let rec loop offset =
    if offset < Bytes.length bytes then
      let count = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + count)
  in
  loop 0

let hold () =
  while true do
    Unix.pause ()
  done

let rec waitpid_nointr flags pid =
  match Unix.waitpid flags pid with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr flags pid

let read_requests path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let rec loop acc =
        match Marshal.from_channel input with
        | request -> loop (request :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let with_server ~name respond f =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen socket 8;
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX path ->
        failf "expected TCP test socket, got Unix socket %S" path
  in
  let requests_path =
    Filename.temp_file ("spice-" ^ name ^ "-requests") ".bin"
  in
  match Unix.fork () with
  | 0 -> (
      match
        let output = open_out_bin requests_path in
        Fun.protect
          ~finally:(fun () -> close_out_noerr output)
          (fun () ->
            let rec serve index =
              let client, _address = Unix.accept socket in
              Fun.protect
                ~finally:(fun () -> Unix.close client)
                (fun () ->
                  let request = read_request client in
                  Marshal.to_channel output request [];
                  flush output;
                  match respond index request with
                  | Reply text -> write_all client text
                  | Hold -> hold ()
                  | Hold_after text ->
                      write_all client text;
                      hold ());
              serve (index + 1)
            in
            serve 0)
      with
      | () -> exit 0
      | exception exn ->
          prerr_endline (Printexc.to_string exn);
          exit 2)
  | pid ->
      Unix.close socket;
      let cleanup () =
        match waitpid_nointr [ Unix.WNOHANG ] pid with
        | 0, _ ->
            (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
            ignore (waitpid_nointr [] pid)
        | _ -> ()
      in
      Fun.protect
        ~finally:(fun () -> Sys.remove requests_path)
        (fun () ->
          let value = Fun.protect ~finally:cleanup (fun () -> f port) in
          (value, read_requests requests_path))

let response_head ?(headers = []) ?(content_type = "application/json") status
    ~content_length =
  let reason = if status = 200 then "OK" else "Status" in
  let headers =
    ("Content-Type", content_type)
    :: ("Content-Length", string_of_int content_length)
    :: ("Connection", "close") :: headers
  in
  let headers =
    headers
    |> List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n")
    |> String.concat ""
  in
  Printf.sprintf "HTTP/1.1 %d %s\r\n%s\r\n" status reason headers
