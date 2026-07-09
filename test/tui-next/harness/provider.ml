(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* In-process fake OpenAI Responses provider.

   An Eio fiber serves the same wire format as the out-of-process
   [spice_fake_provider_server]: HTTP/1.1, the completion streamed as
   [response.output_text.delta] events followed by the terminal
   [response.completed] event, Content-Length spanning the whole body.

   Timed holds are replaced by named gates: an item with [gate] awaits an
   [Eio.Promise] the test resolves with {!release}, so a mid-flight state
   stays observable for exactly as long as the test needs — no wall-clock
   sleeps anywhere. {!await_request} is the event-based synchronization for
   "the turn's request reached the provider". *)

type reply =
  | Completion of { id : string; text : string; reasoning : string option }
      (** a Responses completion, streamed as deltas + the terminal event.
          [reasoning], when present, is a reasoning summary streamed as
          [reasoning_summary_text] deltas and carried as a [reasoning] output
          item ahead of the message — its leading [**bold**] line titles the
          settled thought. *)
  | Stream_hold of { id : string; text : string; reasoning : string option }
      (** like {!Completion}, but the SSE deltas are flushed and the reply then
          holds on its [gate] BEFORE the terminal event: the streamed text (and
          reasoning ticker) is on screen while the turn is still in flight, until
          {!release}. The mid-stream frame is settled-modulo-gate, so it is
          observable for exactly as long as the test needs. A gate is required. *)
  | Tool_call of {
      id : string;
      call_id : string;
      name : string;
      arguments : string;
    }
      (** a Responses turn that calls one tool: the terminal event carries a
          [function_call] output item. The app runs the tool (or opens its
          dialog) and re-requests with the tool result, so serve the resume as
          the next script item. [arguments] is the tool's JSON argument object
          verbatim — it is escaped into the wire string. *)
  | Http of { status : int; body : string }
      (** a plain HTTP reply, for the non-Responses endpoints a scenario touches
          (a login's model-list check, say) *)

type item = {
  expect_line : string;  (** the exact request line the item serves *)
  expect : string list;  (** substrings the request body must contain *)
  gate : string option;  (** hold the reply until [release] resolves it *)
  reply : reply;
}

let message ?(expect = []) ?gate ?reasoning ~id text =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate;
    reply = Completion { id; text; reasoning };
  }

(* A completion whose deltas stream, then the terminal event holds on [gate]: the
   mid-flight streamed text is observable until {!release}. *)
let stream_hold ?(expect = []) ?reasoning ~gate ~id text =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate = Some gate;
    reply = Stream_hold { id; text; reasoning };
  }

let http ?(expect = []) ?gate ~line ~status body =
  { expect_line = line; expect; gate; reply = Http { status; body } }

let tool_call ?(expect = []) ?gate ~id ~call_id ~name ~arguments () =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate;
    reply = Tool_call { id; call_id; name; arguments };
  }

type t = {
  base_url : string;
  gates : (string, unit Eio.Promise.t * unit Eio.Promise.u) Hashtbl.t;
  requests : (int, string) Hashtbl.t;  (** arrival order -> body *)
  mutable arrivals : int;
  arrived : Eio.Condition.t;
  mutable served : int;
      (** count of responses whose reply is fully written to the socket. Its
          advance is the deterministic half of {!Tui.release}'s wait: the whole
          (Content-Length-delimited) response is on the wire and the turn's
          completion — the socket read, the blocking session-save [fsync], the
          settled dispatch, none of which the quiescence probe can see — is now
          bounded work the release can pump out. *)
}

let base_url t = t.base_url

(* The number of responses fully written to the socket (see {!served}).
   {!Tui.release} pumps the loop until this advances past the released turn. *)
let served t = t.served

(* [true] while any named gate is still unresolved: the driver relaxes its
   quiescence rule around held gates so mid-flight states are observable. *)
let any_held t =
  Hashtbl.fold
    (fun _ (promise, _) held -> held || not (Eio.Promise.is_resolved promise))
    t.gates false

let release t name =
  match Hashtbl.find_opt t.gates name with
  | None -> Util.failf "provider: no gate named %S" name
  | Some (promise, resolver) ->
      if Eio.Promise.is_resolved promise then
        Util.failf "provider: gate %S released twice" name
      else Eio.Promise.resolve resolver ()

let await_request t index =
  while t.arrivals < index do
    Eio.Condition.await_no_mutex t.arrived
  done;
  Hashtbl.find t.requests index

let request t index = Hashtbl.find_opt t.requests index

(* {2 Wire format} *)

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

let completion_json ~id ~text ~reasoning =
  Printf.sprintf {|{"id":%S,"status":"completed","model":"gpt-5.5","output":%s}|}
    id (output_items ~text ~reasoning)

(* A single SSE delta event; the [type] field mirrors the event name. *)
let delta_event ~name ~delta =
  Printf.sprintf "event: %s\ndata: {\"type\":%S,\"delta\":%S}\n\n" name name delta

(* The streamed deltas: reasoning summary fragments (display-only ticker), then
   the visible text fragments. The terminal response, not the deltas, is
   authoritative. *)
let sse_deltas ~text ~reasoning =
  let stream name s =
    chunk_text s |> List.map (fun c -> delta_event ~name ~delta:c) |> String.concat ""
  in
  let reasoning_deltas =
    match reasoning with
    | None -> ""
    | Some summary -> stream "response.reasoning_summary_text.delta" summary
  in
  reasoning_deltas ^ stream "response.output_text.delta" text

let sse_terminal ~id ~text ~reasoning =
  Printf.sprintf
    "event: response.completed\n\
     data: {\"type\":\"response.completed\",\"response\":%s}\n\n"
    (completion_json ~id ~text ~reasoning)

let sse_body ~id ~text ~reasoning =
  sse_deltas ~text ~reasoning ^ sse_terminal ~id ~text ~reasoning

(* A single tool call, delivered whole in the terminal event: there is no text
   to stream, so no deltas. [arguments] is a JSON object serialized as a string
   value (the Responses shape), so [%S] escapes it in place. *)
let tool_call_sse ~id ~call_id ~name ~arguments =
  Printf.sprintf
    "event: response.completed\n\
     data: {\"type\":\"response.completed\",\"response\":{\"id\":%S,\"status\":\"completed\",\"model\":\"gpt-5.5\",\"output\":[{\"type\":\"function_call\",\"id\":%S,\"call_id\":%S,\"name\":%S,\"arguments\":%S}]}}\n\n"
    id (id ^ "-fc") call_id name arguments

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

(* {2 Serving} *)

let read_request buf =
  let request_line = Eio.Buf_read.line buf in
  let rec headers acc =
    match Eio.Buf_read.line buf with
    | "" -> List.rev acc
    | line -> headers (line :: acc)
  in
  let headers = headers [] in
  let content_length =
    List.find_map
      (fun line ->
        match String.index_opt line ':' with
        | Some i
          when String.equal
                 (String.lowercase_ascii (String.sub line 0 i))
                 "content-length" ->
            int_of_string_opt
              (String.trim
                 (String.sub line (i + 1) (String.length line - i - 1)))
        | _ -> None)
      headers
    |> Option.value ~default:0
  in
  let body =
    if content_length > 0 then Eio.Buf_read.take content_length buf else ""
  in
  (request_line, body)

let check_expectation index item ~request_line ~body =
  if not (String.equal request_line item.expect_line) then
    Util.failf "provider: request %d line %S, expected %S" index request_line
      item.expect_line;
  List.iter
    (fun fragment ->
      if not (Util.contains body fragment) then
        Util.failf "provider: request %d body does not contain %S:\n%s" index
          fragment body)
    item.expect

let serve t socket items =
  List.iteri
    (fun index item ->
      let index = index + 1 in
      Eio.Switch.run @@ fun sw ->
      let flow, _addr = Eio.Net.accept ~sw socket in
      let buf = Eio.Buf_read.of_flow ~max_size:(1 lsl 22) flow in
      let request_line, body = read_request buf in
      t.arrivals <- index;
      Hashtbl.replace t.requests index body;
      Eio.Condition.broadcast t.arrived;
      check_expectation index item ~request_line ~body;
      let await_gate () =
        match item.gate with
        | None -> ()
        | Some name -> Eio.Promise.await (fst (Hashtbl.find t.gates name))
      in
      (match item.reply with
      | Stream_hold { id; text; reasoning } ->
          (* Flush the head + deltas, hold on the gate, then write the terminal:
             the streamed text is on screen while the turn is in flight, until
             {!release}. Content-Length spans head..terminal so the split is
             invisible to the client. *)
          let deltas = sse_deltas ~text ~reasoning in
          let terminal = sse_terminal ~id ~text ~reasoning in
          let content_length = String.length deltas + String.length terminal in
          Eio.Flow.copy_string (http_head ~content_length () ^ deltas) flow;
          await_gate ();
          Eio.Flow.copy_string terminal flow
      | reply ->
          await_gate ();
          let response =
            match reply with
            | Completion { id; text; reasoning } ->
                http_response (sse_body ~id ~text ~reasoning)
            | Tool_call { id; call_id; name; arguments } ->
                http_response (tool_call_sse ~id ~call_id ~name ~arguments)
            | Http { status; body } ->
                http_response ~status ~content_type:"application/json" body
            | Stream_hold _ -> assert false
          in
          Eio.Flow.copy_string response flow);
      t.served <- index)
    items

let start ~sw ~net items =
  let socket =
    Eio.Net.listen ~sw ~backlog:8 ~reuse_addr:true net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> Util.failf "provider: unix listening address %s" path
  in
  let t =
    {
      base_url = Printf.sprintf "http://127.0.0.1:%d/v1" port;
      gates = Hashtbl.create 4;
      requests = Hashtbl.create 4;
      arrivals = 0;
      arrived = Eio.Condition.create ();
      served = 0;
    }
  in
  List.iter
    (fun item ->
      Option.iter
        (fun name ->
          if Hashtbl.mem t.gates name then
            Util.failf "provider: duplicate gate %S" name;
          Hashtbl.replace t.gates name (Eio.Promise.create ()))
        item.gate)
    items;
  Eio.Fiber.fork_daemon ~sw (fun () ->
      serve t socket items;
      `Stop_daemon);
  t
