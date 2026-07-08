(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Interactive, condition-driven driver for a spice TUI under a real PTY.

   Nothing here is scheduled against wall-clock time: [send] writes
   immediately, and every observation is a [wait] on a screen predicate. The
   deadline exists only to fail loudly; a passing test never spends time in
   it. *)

type t = {
  pty : Pty.t;
  vte : Vte.t;
  raw : Buffer.t;
  buf : Bytes.t;
  project : Project.t;
  mutable sync_active : bool;
  mutable exited : bool;
  mutable last_nonblank : string option;
}

let default_rows = 14
let default_cols = 112
let default_deadline = 10.0
let monotonic = Unix.gettimeofday

let nonblank screen =
  let rec loop i =
    i < String.length screen
    &&
    match String.unsafe_get screen i with
    | ' ' | '\n' -> loop (i + 1)
    | _ -> true
  in
  loop 0

(* Around screen transitions (alt-screen leave on exit, full repaints) the
   grid passes through blank states; observing them would let a [lacks]
   predicate pass vacuously and would print empty goldens after exit. *)
let screen t =
  let current = Vte.to_string t.vte in
  if nonblank current then current
  else Option.value t.last_nonblank ~default:current

let raw t = Buffer.contents t.raw
let exited t = t.exited

(* Terminals bracket frames in synchronized-output guards (mode 2026); a
   predicate must never observe the screen while a guard is open, or it can
   match on a torn frame. *)
let update_sync_state ~sync_active raw_delta =
  let enable = "\027[?2026h" in
  let disable = "\027[?2026l" in
  let raw_len = String.length raw_delta in
  let starts_with_at index needle =
    let needle_len = String.length needle in
    index + needle_len <= raw_len
    && String.equal (String.sub raw_delta index needle_len) needle
  in
  let rec loop index active =
    if index >= raw_len then active
    else if starts_with_at index enable then
      loop (index + String.length enable) true
    else if starts_with_at index disable then
      loop (index + String.length disable) false
    else loop (index + 1) active
  in
  loop 0 sync_active

let pump t ~wait_s =
  if t.exited then ()
  else
    let readable =
      try
        let r, _, _ = Unix.select [ Pty.file_descr t.pty ] [] [] wait_s in
        r <> []
      with Unix.Unix_error (Unix.EINTR, _, _) -> false
    in
    if readable then
      match Pty.read t.pty t.buf 0 (Bytes.length t.buf) with
      | 0 -> t.exited <- true
      | n ->
          let raw_delta = Bytes.sub_string t.buf 0 n in
          Buffer.add_string t.raw raw_delta;
          Vte.feed t.vte t.buf 0 n;
          t.sync_active <-
            update_sync_state ~sync_active:t.sync_active raw_delta;
          if not t.sync_active then
            let current = Vte.to_string t.vte in
            if nonblank current then t.last_nonblank <- Some current
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
      | exception Unix.Unix_error _ ->
          (* On some platforms reading the master after the child exits
             reports EIO rather than EOF. *)
          t.exited <- true

let fail_with_screen t message =
  Printf.printf "--- %s; last screen ---\n" message;
  Screen.print ~project:t.project (screen t);
  failwith message

let wait ?(deadline = default_deadline) t predicate =
  let limit = monotonic () +. deadline in
  let settled () = (not t.sync_active) && predicate (screen t) in
  let rec loop () =
    if settled () then ()
    else if t.exited then
      fail_with_screen t "Term.wait: spice exited before condition held"
    else if monotonic () >= limit then fail_with_screen t "Term.wait: timed out"
    else (
      pump t ~wait_s:0.02;
      loop ())
  in
  loop ()

let wait_raw ?(deadline = default_deadline) t predicate =
  let limit = monotonic () +. deadline in
  let rec loop () =
    if predicate (Buffer.contents t.raw) then ()
    else if t.exited then
      fail_with_screen t "Term.wait_raw: spice exited before condition held"
    else if monotonic () >= limit then
      fail_with_screen t "Term.wait_raw: timed out"
    else (
      pump t ~wait_s:0.02;
      loop ())
  in
  loop ()

let wait_exit ?(deadline = default_deadline) t =
  let limit = monotonic () +. deadline in
  while (not t.exited) && monotonic () < limit do
    pump t ~wait_s:0.02
  done;
  if not t.exited then fail_with_screen t "Term.wait_exit: timed out"

let send t text =
  let len = String.length text in
  let rec loop off =
    if off < len then
      match Pty.write_string t.pty text off (len - off) with
      | 0 ->
          Unix.sleepf 0.001;
          loop off
      | written -> loop (off + written)
      | (exception Unix.Unix_error (Unix.EAGAIN, _, _))
      | (exception Unix.Unix_error (Unix.EWOULDBLOCK, _, _))
      | (exception Unix.Unix_error (Unix.EINTR, _, _)) ->
          Unix.sleepf 0.001;
          loop off
  in
  loop 0

(* Graceful shutdown through the double-ctrl-c affordance. Use before reading
   files spice writes on the way down; plain teardown (closing the PTY) is
   otherwise enough. *)
let quit t =
  send t "\003";
  wait t (Screen.has "Press Ctrl+C again to exit");
  send t "\003";
  wait_exit t

let spice_bin () = Util.resolve_env_path "SPICE_BIN"

(* The footer renders a "dune:" status on every screen once the app is up;
   its presence is the boot marker. *)
let booted = Screen.has "dune:"

let run ?provider ?(command = []) ?(args = []) ?unset ?(env = [])
    ?(rows = default_rows) ?(cols = default_cols) ?(ready = booted) project f =
  let root = Project.root project in
  let openai_base_url = Option.map Provider.base_url provider in
  let winsize = Pty.{ rows; cols; xpixel = 0; ypixel = 0 } in
  (* cmdliner resolves subcommands from the first positional argument, so a
     subcommand under test must precede the [--cwd] option. *)
  let pty =
    Pty.spawn ~cwd:root
      ~env:(Project.env ?openai_base_url ?unset ~extra:env project)
      ~winsize ~prog:(spice_bin ())
      ~args:(command @ ("--cwd" :: root :: args))
      ()
  in
  Pty.set_nonblock pty;
  let t =
    {
      pty;
      vte = Vte.create ~rows ~cols ();
      raw = Buffer.create 4096;
      buf = Bytes.create 4096;
      project;
      sync_active = false;
      exited = false;
      last_nonblank = None;
    }
  in
  Fun.protect
    ~finally:(fun () -> Pty.close t.pty)
    (fun () ->
      wait t ready;
      f t)
