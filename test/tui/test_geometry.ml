(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* Geometry sweeps. One boot, many injected resizes: the deterministic harness
   makes a resize an [Input.Resize] event, so a single run can walk the whole
   shedding ladder and the side-pane presence threshold as a sequence of full
   frames — the v3 plan's replacement for one pty boot per geometry. Time is
   frozen at the epoch, so every frame is a pure function of the size. *)

(* The idle home stage across the width/height ladder. The stage sheds bottom-up
   as rows fall (workspace facts, then the welcome notice), keeps the footer and
   composer to the floor, and drops the footer shortcuts hint as columns narrow;
   nothing here runs a turn. *)
let%expect_test "the idle home stage across the size ladder" =
  Tui.run ~name:"geometry-idle" @@ fun t ->
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}];
  (* Narrow: the footer keeps its dune verdict but drops the shortcuts hint
     rather than colliding it onto the verdict. *)
  Tui.resize t ~width:72 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                          ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                          ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                        dev · openai/gpt-5.5 medium
08 |
09 |        ▎ welcome — and thanks for trying spice this early.
10 |        ▎ it's experimental: sessions and config may change without
11 |        ▎ migration.
12 |
13 |       ────────────────────────────────────────────────────────────
14 |       ❯ message spice
15 |       ────────────────────────────────────────────────────────────
16 |
17 |                  dune       ✗ · diagnostics unavailable
18 |                  account    none — /login to connect
19 |
20 |                   sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}];
  (* Short: workspace facts shed, footer and composer stand. *)
  Tui.resize t ~width:80 ~height:14;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
03 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
04 |
05 |                            dev · openai/gpt-5.5 medium
06 |
07 |           ────────────────────────────────────────────────────────────
08 |           ❯ message spice
09 |           ────────────────────────────────────────────────────────────
10 |
11 |                       sandbox: danger-full-access (config)
12 |
13 |
14 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}];
  (* Very short: the floor — footer always renders. *)
  Tui.resize t ~width:80 ~height:10;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
02 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
03 |
04 |                            dev · openai/gpt-5.5 medium
05 |
06 |           ────────────────────────────────────────────────────────────
07 |           ❯ message spice
08 |           ────────────────────────────────────────────────────────────
09 |
10 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* The side pane is a pure function of width, not turn state: it opens at the
   documented wide threshold and is absent below it. Observed here with the turn
   HELD on a gate (stable, no post-release settle race), so the pane presence is
   read against a deterministic in-flight frame: wide (pane rule [│] present,
   hosting the workspace glance) then narrowed past the threshold (pane gone). At
   120 cols the brand line carries the untruncated cwd, so [$PROJECT] shifts the
   pane rule left on that one row — deterministic on this machine, like every
   wide-frame footer in the suite. *)
let%expect_test "the side pane presence tracks the width threshold in chat" =
  let script =
    [
      Provider_script.message ~expect:[ "say hello" ] ~gate:"fin" ~id:"resp-1"
        "Hello from spice.";
    ]
  in
  Tui.run ~name:"geometry-pane" ~size:(120, 24) ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |                                                                                 │ workspace
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium                           │   dune disconnected
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT                  │
04 |        sandbox: danger-full-access (config)                                     │
05 |                                                                                 │
06 | ❯ say hello                                                                     │
07 |                                                                                 │
08 | ⠋ Working… (0s · esc to interrupt)                                              │
09 |                                                                                 │
10 |                                                                                 │
11 |                                                                                 │
12 |                                                                                 │
13 |                                                                                 │
14 |                                                                                 │
15 |                                                                                 │
16 |                                                                                 │
17 |                                                                                 │
18 |                                                                                 │
19 |                                                                                 │
20 |
21 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗                                      ? for shortcuts|}];
  Tui.resize t ~width:100 ~height:24;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ say hello
07 |
08 | ⠋ Working… (0s · esc to interrupt)
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗                  ? for shortcuts|}];
  (* Release for a clean teardown; the held frame above is the geometry contract
     under test, so the settled frame is not duplicated here. *)
  Tui.release t "fin";
  Tui.settle t

(* A resize mid-turn reflows the in-flight frame: the provider holds, so the
   working line is observable across the resize; narrowing the terminal re-lays
   the transcript and composer and sheds workspace facts without disturbing the
   elapsed counter (time is not advanced). Both goldened frames are HELD, so they
   are stable; the post-release settled frame is not asserted (see below). *)
let%expect_test "a resize mid-turn reflows the in-flight frame" =
  let held =
    [
      Provider_script.message ~expect:[ "resize me" ] ~gate:"turn-1"
        ~id:"resp-1" "Reflowed and settled.";
    ]
  in
  Tui.run ~name:"geometry-midturn" ~provider:held @@ fun t ->
  Tui.settle t;
  Tui.keys t "resize me";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ resize me
07 |
08 | ⠋ Working… (0s · esc to interrupt)
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.resize t ~width:72 ~height:16;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ resize me
07 |
08 | ⠋ Working… (0s · esc to interrupt)
09 |
10 |
11 |
12 |
13 | ────────────────────────────────────────────────────────────────────────
14 | ❯ queue a message — sends after this turn
15 | ────────────────────────────────────────────────────────────────────────
16 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  (* Release for a clean teardown. The two held frames above are the reflow
     contract, so the post-release settled frame is not duplicated here. *)
  Tui.release t "turn-1";
  Tui.settle t
