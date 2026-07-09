(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* One scripted turn against the in-process provider. The reply is held on a
   named gate, so the mid-flight state is observed for exactly as long as the
   test needs, the elapsed counter is advanced deterministically, and the
   settled state follows the release — zero sleeps end to end. *)

let%expect_test "a held turn shows working state, ticks, then settles" =
  let script =
    [
      Provider.message ~expect:[ "say hello" ] ~gate:"turn-1" ~id:"resp-1"
        "Hello from the fake provider.";
    ]
  in
  Tui.run ~name:"turn-hold" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  (* Pumping sync: the request reached the provider, which now holds. *)
  ignore (Tui.await_request t 1 : string);
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
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/tmp/spice-tui-next-turn-hold · gpt-5.5 medium · dune: ✗    ? for shortcuts|}];
  (* The working line's elapsed clock ticks exactly five virtual seconds. *)
  Tui.advance t 5.0;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ say hello
07 |
08 | ⠋ Working… (5s · esc to interrupt)
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
24 |   …/tmp/spice-tui-next-turn-hold · gpt-5.5 medium · dune: ✗    ? for shortcuts|}];
  Tui.release t "turn-1";
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
08 | ⏺ Hello from the fake provider.
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
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/tmp/spice-tui-next-turn-hold · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]
