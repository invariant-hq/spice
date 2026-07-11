(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the Spice TUI exit goodbye (the parting frame
   printed to the normal terminal once the TUI restores the alternate screen).
   The brand lockup always prints, and a resume hint prints only when a session
   exists — a prelude quit with no conversation prints the lockup alone.

   The goodbye lands on the primary screen after the alternate screen restores,
   so the assertions read the final captured frame once spice has exited
   ([Pty.quit] drives the double-Ctrl+C chord and waits for exit). The alt-screen
   composer placeholder [message spice] being gone from the captured frame is what
   distinguishes the restored goodbye from the running UI — the lockup alone would
   also match the banner record still on the alternate screen. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact label value = Printf.printf "%s: %b\n" label value

let run ?env ?rows ?cols ?provider project f =
  Pty.run ?env ?rows ?cols ?provider ~trust:true project f

(* The static lockup's second row — the frozen mark the goodbye reprints
   (Theme.lockup). Its wordmark and resting heap are stable across runs. *)
let lockup_row = "▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂"

(* Quitting after a conversation prints the goodbye with a resume pointer: the
   session was created on the first submit, so the goodbye names how to reopen it
   ([spice resume ID]). The generated id is not asserted — only the stable lockup
   and the copy-pasteable command prefix. *)
let%expect_test
    "quitting after a conversation prints the lockup and resume hint" =
  Project.with_temp "next-exit-session" @@ fun project ->
  let answer = "The retry logic backs off exponentially." in
  Provider_process.with_openai project ~answer ~expect:[ "retry" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Pty.wait t (Screen.has "dune:");
  Pty.send t "explain the retry logic";
  Pty.wait t (Screen.has "❯ explain the retry logic");
  Pty.send t Key.enter;
  Pty.wait t (fun s -> Screen.has answer s && Screen.has "? for shortcuts" s);
  Pty.quit t;
  let screen = Pty.screen t in
  print_fact "goodbye replaced the running UI"
    (Screen.lacks "message spice" screen);
  print_fact "lockup on the restored screen" (Screen.has lockup_row screen);
  print_fact "resume command named" (Screen.has "spice resume" screen);
  [%expect
    {|
    goodbye replaced the running UI: true
    lockup on the restored screen: true
    resume command named: true|}]

(* Quitting from the prelude with no conversation mirrors the old TUI's
   no-session exit: the lockup prints, but there is no session to resume, so no
   resume hint. *)
let%expect_test
    "quitting from the prelude prints the lockup with no resume hint" =
  Project.with_temp "next-exit-prelude" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Pty.wait t (Screen.has "dune:");
  Pty.quit t;
  let screen = Pty.screen t in
  print_fact "goodbye replaced the running UI"
    (Screen.lacks "message spice" screen);
  print_fact "lockup on the restored screen" (Screen.has lockup_row screen);
  print_fact "no resume hint without a session"
    (Screen.lacks "spice resume" screen);
  [%expect
    {|
    goodbye replaced the running UI: true
    lockup on the restored screen: true
    no resume hint without a session: true|}]

[%%run_tests "spice.tui-pty.goodbye"]
