(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type notice = Spice_protocol.Notice.t
type t = { mutex : Eio.Mutex.t; capacity : int; mutable queued : notice list }
type batch_state = Pending | Committed | Rolled_back
type batch = { queue : t; notices : notice list; mutable state : batch_state }

let create ?(capacity = 32) () =
  if capacity <= 0 then
    invalid_arg "Spice_host.Notice_queue.create: capacity must be positive";
  { mutex = Eio.Mutex.create (); capacity; queued = [] }

let key = Spice_protocol.Notice.key

let rec drop count = function
  | notices when count <= 0 -> notices
  | [] -> []
  | _ :: notices -> drop (count - 1) notices

let retain_capacity capacity notices =
  let excess = List.length notices - capacity in
  if excess <= 0 then notices else drop excess notices

(* Keep only the newest notice per key, preserving oldest-to-newest order. *)
let retain_newest_keys notices =
  let rec loop seen acc = function
    | [] -> acc
    | notice :: notices ->
        let k = key notice in
        if List.exists (String.equal k) seen then loop seen acc notices
        else loop (k :: seen) (notice :: acc) notices
  in
  loop [] [] (List.rev notices)

let publish t notice =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let k = key notice in
      let queued =
        List.filter
          (fun existing -> not (String.equal (key existing) k))
          t.queued
        @ [ notice ]
      in
      t.queued <- retain_capacity t.capacity queued)

let take t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let notices = t.queued in
      t.queued <- [];
      { queue = t; notices; state = Pending })

let notices batch = batch.notices

(* A batch resolves at most once; a resolved batch is inert. Held under the
   queue's mutex so commit/rollback and concurrent producers agree on order. *)
let resolve batch state f =
  Eio.Mutex.use_rw ~protect:true batch.queue.mutex (fun () ->
      match batch.state with
      | Pending ->
          batch.state <- state;
          f ()
      | Committed | Rolled_back -> ())

let commit batch = resolve batch Committed (fun () -> ())

let rollback batch =
  resolve batch Rolled_back (fun () ->
      let t = batch.queue in
      let restored = batch.notices @ t.queued in
      t.queued <- retain_capacity t.capacity (retain_newest_keys restored))

let is_empty t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match t.queued with [] -> true | _ :: _ -> false)
