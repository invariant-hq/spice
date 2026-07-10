(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Provider request expectations and replies shared by the in-process and PTY
   harness interpreters. *)

type reply =
  | Completion of {
      id : string;
      text : string;
      reasoning : string option;
      output_tokens : int option;
    }
      (** a Responses completion, streamed as deltas + the terminal event.
          [reasoning], when present, is a reasoning summary streamed as
          [reasoning_summary_text] deltas and carried as a [reasoning] output
          item ahead of the message — its leading [**bold**] line titles the
          settled thought. *)
  | Stream_hold of {
      id : string;
      text : string;
      reasoning : string option;
      output_tokens : int option;
    }
      (** like {!Completion}, but the SSE deltas are flushed and the reply then
          holds on its [gate] BEFORE the terminal event: the streamed text (and
          reasoning ticker) is on screen while the turn is still in flight,
          until {!release}. The mid-stream frame is settled-modulo-gate, so it
          is observable for exactly as long as the test needs. A gate is
          required. *)
  | Tool_call of {
      id : string;
      call_id : string;
      name : string;
      arguments : string;
      output_tokens : int option;
    }
      (** a Responses turn that calls one tool: the terminal event carries a
          [function_call] output item. The app runs the tool (or opens its
          dialog) and re-requests with the tool result, so serve the resume as
          the next script item. [arguments] is the tool's JSON argument object
          verbatim — it is escaped into the wire string. *)
  | Tool_calls of { id : string; calls : (string * string * string) list }
      (** a Responses turn that fans out to several tool calls in ONE terminal
          event: each triple is [(call_id, name, arguments)]. The host runs all
          of them — spawning several detached children in one parent step, say —
          and each resumes as its own follow-up request. *)
  | Http of { status : int; body : string }
      (** a plain HTTP reply, for the non-Responses endpoints a scenario touches
          (a login's model-list check, say) *)

type item = {
  expect_line : string;  (** the exact request line the item serves *)
  expect : string list;  (** substrings the request body must contain *)
  gate : string option;  (** hold the reply until [release] resolves it *)
  reply : reply;
}

type t = item list

let message ?(expect = []) ?gate ?reasoning ?output_tokens ~id text =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate;
    reply = Completion { id; text; reasoning; output_tokens };
  }

(* A completion whose deltas stream, then the terminal event holds on [gate]: the
   mid-flight streamed text is observable until {!release}. *)
let stream_hold ?(expect = []) ?reasoning ?output_tokens ~gate ~id text =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate = Some gate;
    reply = Stream_hold { id; text; reasoning; output_tokens };
  }

let http ?(expect = []) ?gate ~line ~status body =
  { expect_line = line; expect; gate; reply = Http { status; body } }

let tool_call ?(expect = []) ?gate ?output_tokens ~id ~call_id ~name ~arguments
    () =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate;
    reply = Tool_call { id; call_id; name; arguments; output_tokens };
  }

let tool_calls ?(expect = []) ?gate ~id ~calls () =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate;
    reply = Tool_calls { id; calls };
  }

(* Wire format shared by both provider interpreters. *)

(* Split [s] into up to three UTF-8-safe chunks so a single message streams as
   several deltas; the terminal response, not the concatenated deltas, is
   authoritative. *)
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

(* OCaml's [%S] escaping coincides with JSON for the ASCII test strings these
   scripts carry (as in the out-of-process server's builders). *)

(* The terminal event's output items: an optional [reasoning] summary ahead of
   the assistant message. The reasoning's leading [**bold**] line titles the
   settled thought. *)
let output_items ~text ~reasoning =
  let reasoning_item =
    match reasoning with
    | None -> ""
    | Some summary ->
        Printf.sprintf
          {|{"type":"reasoning","summary":[{"type":"summary_text","text":%S}]},|}
          summary
  in
  Printf.sprintf
    {|[%s{"type":"message","role":"assistant","content":[{"type":"output_text","text":%S}]}]|}
    reasoning_item text

let usage_json = function
  | None -> ""
  | Some output_tokens ->
      Printf.sprintf {|,"usage":{"input_tokens":0,"output_tokens":%d}|}
        output_tokens

let completion_json ~id ~text ~reasoning ~output_tokens =
  Printf.sprintf
    {|{"id":%S,"status":"completed","model":"gpt-5.5","output":%s%s}|} id
    (output_items ~text ~reasoning)
    (usage_json output_tokens)

(* A single SSE delta event; the [type] field mirrors the event name. *)
let delta_event ~name ~delta =
  Printf.sprintf "event: %s\ndata: {\"type\":%S,\"delta\":%S}\n\n" name name
    delta

(* The streamed deltas: reasoning summary fragments (display-only ticker), then
   the visible text fragments. The terminal response, not the deltas, is
   authoritative. *)
let sse_deltas ~text ~reasoning =
  let stream name s =
    chunk_text s
    |> List.map (fun c -> delta_event ~name ~delta:c)
    |> String.concat ""
  in
  let reasoning_deltas =
    match reasoning with
    | None -> ""
    | Some summary -> stream "response.reasoning_summary_text.delta" summary
  in
  reasoning_deltas ^ stream "response.output_text.delta" text

let sse_terminal ~id ~text ~reasoning ~output_tokens =
  Printf.sprintf
    "event: response.completed\n\
     data: {\"type\":\"response.completed\",\"response\":%s}\n\n"
    (completion_json ~id ~text ~reasoning ~output_tokens)

let sse_body ~id ~text ~reasoning ~output_tokens =
  sse_deltas ~text ~reasoning ^ sse_terminal ~id ~text ~reasoning ~output_tokens

(* A single tool call, delivered whole in the terminal event: there is no text
   to stream, so no deltas. [arguments] is a JSON object serialized as a string
   value (the Responses shape), so [%S] escapes it in place. *)
let tool_call_sse ~id ~call_id ~name ~arguments ~output_tokens =
  Printf.sprintf
    "event: response.completed\n\
     data: \
     {\"type\":\"response.completed\",\"response\":{\"id\":%S,\"status\":\"completed\",\"model\":\"gpt-5.5\",\"output\":[{\"type\":\"function_call\",\"id\":%S,\"call_id\":%S,\"name\":%S,\"arguments\":%S}]%s}}\n\n"
    id (id ^ "-fc") call_id name arguments (usage_json output_tokens)

(* Several [function_call] output items in one terminal event, so a single parent
   step fans out to several tool calls (three detached children, say). *)
let tool_calls_sse ~id ~calls =
  let items =
    List.mapi
      (fun index (call_id, name, arguments) ->
        Printf.sprintf
          {|{"type":"function_call","id":%S,"call_id":%S,"name":%S,"arguments":%S}|}
          (Printf.sprintf "%s-fc%d" id index)
          call_id name arguments)
      calls
    |> String.concat ","
  in
  Printf.sprintf
    "event: response.completed\n\
     data: \
     {\"type\":\"response.completed\",\"response\":{\"id\":%S,\"status\":\"completed\",\"model\":\"gpt-5.5\",\"output\":[%s]}}\n\n"
    id items

let status_reason = function
  | 200 -> "OK"
  | 401 -> "Unauthorized"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 429 -> "Too Many Requests"
  | _ -> "Status"

(* The HTTP response head with a Content-Length spanning the whole body. Split
   from the body so a streaming reply can flush head + deltas, hold on its gate,
   then write the terminal event — the split is invisible to the client beyond
   the delivery gap. *)
let http_head ?(status = 200) ?(content_type = "text/event-stream")
    ~content_length () =
  Printf.sprintf
    "HTTP/1.1 %d %s\r\n\
     Content-Type: %s\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n"
    status (status_reason status) content_type content_length

let http_response ?(status = 200) ?(content_type = "text/event-stream") body =
  http_head ~status ~content_type ~content_length:(String.length body) () ^ body

let json_strings strings =
  strings |> List.map (Printf.sprintf "%S") |> String.concat ","

let expectation_json item =
  Printf.sprintf {|"expect":{"request_line":%S,"body_contains":[%s]}|}
    item.expect_line (json_strings item.expect)

let delay_json = function
  | None -> ""
  | Some milliseconds -> Printf.sprintf {|,"delay_ms":%d|} milliseconds

let response_json = function
  | Completion { id; text; reasoning; output_tokens }
  | Stream_hold { id; text; reasoning; output_tokens } ->
      completion_json ~id ~text ~reasoning ~output_tokens
  | Tool_call { id; call_id; name; arguments; output_tokens } ->
      Printf.sprintf
        {|{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":%S,"call_id":%S,"name":%S,"arguments":%S}]%s}|}
        id (id ^ "-fc") call_id name arguments (usage_json output_tokens)
  | Tool_calls { id; calls } ->
      let items =
        List.mapi
          (fun index (call_id, name, arguments) ->
            Printf.sprintf
              {|{"type":"function_call","id":%S,"call_id":%S,"name":%S,"arguments":%S}|}
              (Printf.sprintf "%s-fc%d" id index)
              call_id name arguments)
          calls
        |> String.concat ","
      in
      Printf.sprintf
        {|{"id":%S,"status":"completed","model":"gpt-5.5","output":[%s]}|} id
        items
  | Http _ -> invalid_arg "Provider_script.response_json: HTTP reply"

let to_process_line ?delay_ms item =
  Option.iter
    (fun gate ->
      invalid_arg
        (Printf.sprintf
           "Provider_script.to_process_line: gate %S requires the in-process \
            runtime"
           gate))
    item.gate;
  match item.reply with
  | Stream_hold _ ->
      invalid_arg
        "Provider_script.to_process_line: stream holds require the in-process \
         runtime"
  | Http { status; body } ->
      Printf.sprintf {|{%s%s,"http":{"status":%d,"json":%s}}|}
        (expectation_json item) (delay_json delay_ms) status body
  | reply ->
      Printf.sprintf {|{%s%s,"response":%s}|} (expectation_json item)
        (delay_json delay_ms) (response_json reply)
