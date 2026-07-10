(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Provider_script

type t = {
  base_url : string;
  gates : (string, unit Eio.Promise.t * unit Eio.Promise.u) Hashtbl.t;
  requests : (int, string) Hashtbl.t;
  mutable arrivals : int;
  arrived : Eio.Condition.t;
  mutable served : int;
  (* Responses currently suspended in [await_gate]. Future scripted gates do
     not make the application look held before their request arrives. *)
  mutable held : int;
}

let failf fmt = Printf.ksprintf failwith fmt
let base_url t = t.base_url
let served t = t.served
let any_held t = t.held > 0

let release t name =
  match Hashtbl.find_opt t.gates name with
  | None -> failf "provider: no gate named %S" name
  | Some (promise, resolver) ->
      if Eio.Promise.is_resolved promise then
        failf "provider: gate %S released twice" name
      else Eio.Promise.resolve resolver ()

let request t index = Hashtbl.find_opt t.requests index

let read_request buf =
  let request_line = Eio.Buf_read.line buf in
  let rec headers acc =
    match Eio.Buf_read.line buf with
    | "" -> List.rev acc
    | line -> headers (line :: acc)
  in
  let content_length =
    headers []
    |> List.find_map (fun line ->
        match String.index_opt line ':' with
        | Some i
          when String.equal
                 (String.lowercase_ascii (String.sub line 0 i))
                 "content-length" ->
            int_of_string_opt
              (String.trim
                 (String.sub line (i + 1) (String.length line - i - 1)))
        | _ -> None)
    |> Option.value ~default:0
  in
  let body =
    if content_length > 0 then Eio.Buf_read.take content_length buf else ""
  in
  (request_line, body)

let check_expectation index item ~request_line ~body =
  if not (String.equal request_line item.expect_line) then
    failf "provider: request %d line %S, expected %S" index request_line
      item.expect_line;
  List.iter
    (fun fragment ->
      if not (String.includes ~affix:fragment body) then
        failf "provider: request %d body does not contain %S:\n%s" index
          fragment body)
    item.expect

let respond t flow item =
  let await_gate () =
    match item.gate with
    | None -> ()
    | Some name ->
        t.held <- t.held + 1;
        Fun.protect
          (fun () -> Eio.Promise.await (fst (Hashtbl.find t.gates name)))
          ~finally:(fun () -> t.held <- t.held - 1)
  in
  match item.reply with
  | Stream_hold { id; text; reasoning; output_tokens } ->
      let deltas = sse_deltas ~text ~reasoning in
      let terminal = sse_terminal ~id ~text ~reasoning ~output_tokens in
      let content_length = String.length deltas + String.length terminal in
      Eio.Flow.copy_string (http_head ~content_length () ^ deltas) flow;
      await_gate ();
      Eio.Flow.copy_string terminal flow
  | reply ->
      await_gate ();
      let response =
        match reply with
        | Completion { id; text; reasoning; output_tokens } ->
            http_response (sse_body ~id ~text ~reasoning ~output_tokens)
        | Tool_call { id; call_id; name; arguments; output_tokens } ->
            http_response
              (tool_call_sse ~id ~call_id ~name ~arguments ~output_tokens)
        | Tool_calls { id; calls } -> http_response (tool_calls_sse ~id ~calls)
        | Http { status; body } ->
            http_response ~status ~content_type:"application/json" body
        | Stream_hold _ -> assert false
      in
      Eio.Flow.copy_string response flow

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
      respond t flow item;
      t.served <- index)
    items

let item_matches item ~request_line ~body =
  String.equal request_line item.expect_line
  && List.for_all
       (fun fragment -> String.includes ~affix:fragment body)
       item.expect

let serve_unordered t socket ~sw items =
  let pending = Array.of_list (List.map Option.some items) in
  let total = Array.length pending in
  let claim ~request_line ~body =
    let rec loop i =
      if i >= total then None
      else
        match pending.(i) with
        | Some item when item_matches item ~request_line ~body ->
            pending.(i) <- None;
            Some item
        | Some _ | None -> loop (i + 1)
    in
    loop 0
  in
  let handle flow =
    let buf = Eio.Buf_read.of_flow ~max_size:(1 lsl 22) flow in
    let request_line, body = read_request buf in
    let arrival = t.arrivals + 1 in
    t.arrivals <- arrival;
    Hashtbl.replace t.requests arrival body;
    Eio.Condition.broadcast t.arrived;
    match claim ~request_line ~body with
    | None ->
        failf "provider: request %d (%s) matched no pending item:\n%s" arrival
          request_line body
    | Some item ->
        respond t flow item;
        t.served <- t.served + 1
  in
  for _ = 1 to total do
    Eio.Fiber.fork_daemon ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
            let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
            handle flow);
        `Stop_daemon)
  done

let start ~sw ~net ?(unordered = false) items =
  let socket =
    Eio.Net.listen ~sw ~backlog:8 ~reuse_addr:true net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix path -> failf "provider: unix listening address %s" path
  in
  let t =
    {
      base_url = Printf.sprintf "http://127.0.0.1:%d/v1" port;
      gates = Hashtbl.create 4;
      requests = Hashtbl.create 4;
      arrivals = 0;
      arrived = Eio.Condition.create ();
      served = 0;
      held = 0;
    }
  in
  List.iter
    (fun item ->
      Option.iter
        (fun name ->
          if Hashtbl.mem t.gates name then
            failf "provider: duplicate gate %S" name;
          Hashtbl.replace t.gates name (Eio.Promise.create ()))
        item.gate)
    items;
  if unordered then serve_unordered t socket ~sw items
  else
    Eio.Fiber.fork_daemon ~sw (fun () ->
        serve t socket items;
        `Stop_daemon);
  t
