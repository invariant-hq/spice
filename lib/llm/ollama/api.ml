(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.llm.local.api" ~doc:"Local provider HTTP transport"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Error = struct
  type response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  type t = Response of response | Transport of string | Decode of string
end

module Client = struct
  type t = {
    base_url : string;
    headers : (string * string) list;
    sw : Eio.Switch.t;
    env : Eio_unix.Stdenv.base;
  }

  let make ?(headers = []) ~base_url ~sw ~env () = { base_url; headers; sw; env }
end

let max_error_body_size = 65_536

let cohttp_headers headers =
  List.fold_left
    (fun acc (name, value) -> Cohttp.Header.add acc name value)
    (Cohttp.Header.init ()) headers

let read_body body =
  let chunk = Cstruct.create 4096 in
  let buffer = Buffer.create 1024 in
  let rec loop remaining =
    if remaining > 0 then
      match Eio.Flow.single_read body chunk with
      | exception End_of_file -> ()
      | count ->
          let count = min count remaining in
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub chunk 0 count));
          loop (remaining - count)
  in
  loop max_error_body_size;
  Buffer.contents buffer

let http_client (t : Client.t) =
  Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net t.Client.env)

let call ?body t meth path headers =
  try
    let response, response_body =
      Cohttp_eio.Client.call (http_client t) ~sw:t.Client.sw
        ~headers:(cohttp_headers (t.Client.headers @ headers))
        ?body:(Option.map Cohttp_eio.Body.of_string body)
        meth
        (Uri.of_string (t.Client.base_url ^ path))
    in
    let status = Cohttp.Code.code_of_status (Cohttp.Response.status response) in
    if status < 200 || status >= 300 then
      Error
        (Error.Response
           {
             Error.status;
             headers = Cohttp.Header.to_list (Cohttp.Response.headers response);
             body = read_body response_body;
           })
    else Ok response_body
  with exn -> Error (Error.Transport (Printexc.to_string exn))

let health ?(timeout_s = 2.0) t =
  let clock = Eio.Stdenv.clock t.Client.env in
  match
    Eio.Time.with_timeout clock timeout_s (fun () ->
        Ok (call t `GET "/health" []))
  with
  | Error `Timeout -> Error (Error.Transport "health check timed out")
  | Ok (Error _ as error) -> error
  | Ok (Ok body) ->
      ignore (read_body body);
      Ok ()

(* Buffered line reading over an Eio flow, tolerant of CRLF. *)
type line_reader = {
  flow : Eio.Flow.source_ty Eio.Std.r;
  chunk : Cstruct.t;
  mutable head : int;
  mutable tail : int;
  mutable closed : bool;
}

let make_line_reader flow =
  {
    flow :> Eio.Flow.source_ty Eio.Std.r;
    chunk = Cstruct.create 4096;
    head = 0;
    tail = 0;
    closed = false;
  }

let refill_line_reader reader =
  reader.head <- 0;
  reader.tail <- 0;
  match Eio.Flow.single_read reader.flow reader.chunk with
  | exception End_of_file -> reader.closed <- true
  | count -> reader.tail <- count

let read_line reader =
  let buffer = Buffer.create 256 in
  let rec loop () =
    if reader.head >= reader.tail then
      if reader.closed then
        if Buffer.length buffer = 0 then raise End_of_file
        else Buffer.contents buffer
      else (
        refill_line_reader reader;
        if reader.closed && reader.tail = 0 then
          if Buffer.length buffer = 0 then raise End_of_file
          else Buffer.contents buffer
        else loop ())
    else
      let char = Cstruct.get_char reader.chunk reader.head in
      reader.head <- reader.head + 1;
      match char with
      | '\n' -> Buffer.contents buffer
      | '\r' -> loop ()
      | char ->
          Buffer.add_char buffer char;
          loop ()
  in
  loop ()

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let int_member name value = json_member name (Jsont.Json.int value)
let number_member name value = json_member name (Jsont.Json.number value)
let list_member name value = json_member name (Jsont.Json.list value)

module Chat = struct
  type request = {
    model : string;
    messages : Jsont.json list;
    tools : Jsont.json list;
    tool_choice : Jsont.json option;
    response_format : Jsont.json option;
    reasoning_effort : string option;
    max_tokens : int option;
    temperature : float option;
  }

  type event = Chunk of Jsont.json | Done

  type stream = {
    next : unit -> (event, Error.t) result option;
    close : unit -> unit;
  }

  let next stream = stream.next ()
  let close stream = stream.close ()

  let add_opt member name value fields =
    match value with
    | None -> fields
    | Some value -> member name value :: fields

  let body request =
    let fields =
      [
        string_member "model" request.model;
        list_member "messages" request.messages;
        bool_member "stream" true;
        json_member "stream_options"
          (Jsont.Json.object' [ bool_member "include_usage" true ]);
      ]
    in
    let fields =
      match request.tools with
      | [] -> fields
      | tools -> list_member "tools" tools :: fields
    in
    let fields = add_opt json_member "tool_choice" request.tool_choice fields in
    let fields =
      add_opt json_member "response_format" request.response_format fields
    in
    let fields =
      add_opt string_member "reasoning_effort" request.reasoning_effort fields
    in
    let fields = add_opt int_member "max_tokens" request.max_tokens fields in
    let fields =
      add_opt number_member "temperature" request.temperature fields
    in
    Jsont.Json.object' (List.rev fields)

  (* Chat-completions server-sent events are unnamed: every event is a
     [data:] line holding a chunk object, until the [DONE] sentinel. *)
  let next_sse_event read_line =
    let data = Buffer.create 1024 in
    let finish () =
      match Buffer.contents data with
      | "" -> None
      | "[DONE]" -> Some (Ok Done)
      | raw -> (
          match Jsont_bytesrw.decode_string Jsont.json raw with
          | Error message ->
              Some
                (Error
                   (Error.Decode ("chat stream JSON decode failed: " ^ message)))
          | Ok json -> Some (Ok (Chunk json)))
    in
    let rec loop () =
      match read_line () with
      | exception End_of_file -> finish ()
      | line ->
          if String.is_empty line then
            match finish () with None -> loop () | Some _ as event -> event
          else (
            (match String.split_first ~sep:":" line with
            | None -> ()
            | Some (key, value) ->
                let value =
                  if String.starts_with ~prefix:" " value then
                    String.drop_first 1 value
                  else value
                in
                if String.equal key "data" then (
                  if Buffer.length data > 0 then Buffer.add_char data '\n';
                  Buffer.add_string data value));
            loop ())
    in
    loop ()

  let stream_of_flow body =
    let reader = make_line_reader body in
    let closed = ref false in
    {
      next =
        (fun () ->
          if !closed then None else next_sse_event (fun () -> read_line reader));
      close = (fun () -> closed := true);
    }

  let create_stream client request =
    match Jsont_bytesrw.encode_string Jsont.json (body request) with
    | Error message -> Error (Error.Decode ("JSON encode failed: " ^ message))
    | Ok body -> (
        match
          call ~body client `POST "/v1/chat/completions"
            [
              ("content-type", "application/json");
              ("accept", "text/event-stream");
            ]
        with
        | Ok flow -> Ok (stream_of_flow flow)
        | Error error ->
            (match error with
            | Error.Response { Error.status; _ } ->
                Log.debug (fun m -> m "chat request failed status=%d" status)
            | Error.Transport message ->
                Log.debug (fun m ->
                    m "chat request transport error: %s" message)
            | Error.Decode message ->
                Log.debug (fun m -> m "chat request decode error: %s" message));
            Error error)
end
