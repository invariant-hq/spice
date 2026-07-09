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
  | Completion of { id : string; text : string }
      (** a Responses completion, streamed as deltas + the terminal event *)
  | Http of { status : int; body : string }
      (** a plain HTTP reply, for the non-Responses endpoints a scenario touches
          (a login's model-list check, say) *)

type item = {
  expect_line : string;  (** the exact request line the item serves *)
  expect : string list;  (** substrings the request body must contain *)
  gate : string option;  (** hold the reply until [release] resolves it *)
  reply : reply;
}

let message ?(expect = []) ?gate ~id text =
  {
    expect_line = "POST /v1/responses HTTP/1.1";
    expect;
    gate;
    reply = Completion { id; text };
  }

let http ?(expect = []) ?gate ~line ~status body =
  { expect_line = line; expect; gate; reply = Http { status; body } }

type t = {
  base_url : string;
  gates : (string, unit Eio.Promise.t * unit Eio.Promise.u) Hashtbl.t;
  requests : (int, string) Hashtbl.t;  (** arrival order -> body *)
  mutable arrivals : int;
  arrived : Eio.Condition.t;
}

let base_url t = t.base_url

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
let completion_json ~id ~text =
  Printf.sprintf
    {|{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":%S}]}]}|}
    id text

let sse_body ~id ~text =
  let deltas =
    chunk_text text
    |> List.map (fun chunk ->
        Printf.sprintf
          "event: response.output_text.delta\n\
           data: {\"type\":\"response.output_text.delta\",\"delta\":%S}\n\n"
          chunk)
    |> String.concat ""
  in
  let terminal =
    Printf.sprintf
      "event: response.completed\n\
       data: {\"type\":\"response.completed\",\"response\":%s}\n\n"
      (completion_json ~id ~text)
  in
  deltas ^ terminal

let status_reason = function
  | 200 -> "OK"
  | 401 -> "Unauthorized"
  | 403 -> "Forbidden"
  | 404 -> "Not Found"
  | 429 -> "Too Many Requests"
  | _ -> "Status"

let http_response ?(status = 200) ?(content_type = "text/event-stream") body =
  Printf.sprintf
    "HTTP/1.1 %d %s\r\n\
     Content-Type: %s\r\n\
     Content-Length: %d\r\n\
     Connection: close\r\n\
     \r\n\
     %s"
    status (status_reason status) content_type (String.length body) body

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
      (match item.gate with
      | None -> ()
      | Some name -> Eio.Promise.await (fst (Hashtbl.find t.gates name)));
      let response =
        match item.reply with
        | Completion { id; text } -> http_response (sse_body ~id ~text)
        | Http { status; body } ->
            http_response ~status ~content_type:"application/json" body
      in
      Eio.Flow.copy_string response flow)
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
