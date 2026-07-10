(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* Ambient state variants the happy-path tests never render: the exit chord's
   in-process armed state, and a connected account (vs the default logged-out
   home). These are the deterministic, non-colliding slices of the "error/empty
   states + exit" surface; the remaining slices are blocked or owned elsewhere
   (see the note at the bottom). *)

(* The exit flow's assertable in-process state: ctrl+c on an EMPTY draft arms the
   quit chord (a footer notice) rather than discarding a draft (that is the
   non-empty case in test_composer) — the second press would quit. The goodbye
   frame printed after the alt-screen closes is pty-only and lives in the smoke
   layer; the armed notice is observable at the app boundary. *)
let%expect_test "ctrl+c on an empty draft arms the quit chord" =
  Tui.run ~name:"states-quit-arm" @@ fun t ->
  Tui.settle t;
  Tui.keys t Key.ctrl_c;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                            dev · openai/gpt-5.5 medium
08 |
09 |      ▎ welcome — and thanks for trying spice this early.
10 |      ▎ it's experimental: sessions and config may change without migration.
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ message spice
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |                      account    none — /login to connect
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   Press Ctrl+C again to exit|}]

(* A connected account (a credential in the environment) changes the home stage:
   the account line reads connected and the footer drops its "! not logged in"
   standing notice. The default harness home is logged out (test_home), so this
   is the complementary state. *)
let%expect_test "a connected account changes the account line and footer" =
  Tui.run ~name:"states-connected" ~env:[ ("OPENAI_API_KEY", "test-key-abcd") ]
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |      ▎ welcome — and thanks for trying spice this early.
11 |      ▎ it's experimental: sessions and config may change without migration.
12 |
13 |           ────────────────────────────────────────────────────────────
14 |           ❯ message spice
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* The quit chord exits the app cleanly, in-process. A second ctrl+c on the armed
   empty draft quits; [await_exit] returns (proving the app terminated rather than
   hanging — a real assertion, since a broken quit chord would spin the settle
   budget), and the outcome is a clean [Ok] carrying no session (the documented
   invariant until the turn loop lands). The goodbye frame printed after the
   alt-screen closes is pty-only; this is the assertable in-process slice of the
   exit flow beyond the armed state above. Uses suite-port-3's await_exit/outcome
   harness seam. *)
let%expect_test "the quit chord exits the app cleanly" =
  Tui.run ~name:"states-quit-exit" @@ fun t ->
  Tui.settle t;
  Tui.keys t Key.ctrl_c;
  Tui.settle t;
  Tui.keys t Key.ctrl_c;
  Tui.await_exit t;
  (* [outcome] raises if the run errored, so retrieving it proves a clean Ok
     exit (its [last_session] is [None] until the turn loop lands). *)
  ignore (Tui.outcome t);
  print_string "exited cleanly\n";
  [%expect {| exited cleanly |}]

(* Deliberately not covered here (see the coverage report):
   - workspace-tooling knob variants (auto/on): the eager launch spawns a real
     `dune` subprocess whose readiness is outside the virtual clock, making the
     first sampled footer depend on host scheduling. Deterministic dune-state
     coverage needs the faked dune-RPC seam (v3 plan §6, a Phase-2 item), not env
     knobs.
   - empty-store / sessions-empty and the git workspace block: owned by the
     session-lifecycle and home ports (suite-port-3).
   - a confined (read-only/workspace-write) sandbox mode was observed to suppress
     the logged-out account line AND footer nudge (account_absent reads false: no
     auth-requiring provider is listed under a network-confined sandbox) while
     the model line still reads openai/gpt-5.5 — an ambiguous intended-vs-bug
     case left unpinned; see the report. *)
