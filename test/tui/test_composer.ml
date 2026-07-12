(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The composer surface, exercised on the transcript (doc/ui-design/03-composer.md)
   rather than the home stage — that is where a session spends most of its time,
   so a surface's behaviour is proved where users actually meet it. Each test
   runs one settled turn first so the composer sits below a real exchange; the
   home stage's own layout is covered by test_home. *)

let script =
  [
    Provider_script.message ~expect:[ "say hello" ] ~gate:"composer"
      ~id:"resp-1" "Hello from the fake provider.";
  ]

(* One completed turn, leaving the composer below a settled reply. *)
let reach_transcript t =
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "composer";
  Tui.settle t

(* A hard newline (the linefeed the composer binds to Newline) grows the frame
   in place below the transcript; the "❯ " marker sits on the first visual row
   only. The two-stage esc ladder then arms a footer notice and, on the second
   press, saves the draft to history and clears it, which [up] recalls. *)
let%expect_test "newline grows the composer; esc clears and up recalls" =
  Tui.run ~name:"composer-multiline" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t "line one";
  Tui.keys t Key.linefeed;
  Tui.keys t "line two";
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
20 | ────────────────────────────────────────────────────────────────────────────────
21 | ❯ line one
22 |   line two
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}];
  Tui.keys t Key.escape;
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
20 | ────────────────────────────────────────────────────────────────────────────────
21 | ❯ line one
22 |   line two
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   Esc again to clear|}];
  Tui.keys t Key.escape;
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}];
  Tui.keys t Key.up;
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
20 | ────────────────────────────────────────────────────────────────────────────────
21 | ❯ line one
22 |   line two
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]

(* A paste of three-or-more lines collapses to an atomic [Pasted text #N +M
   lines] chunk; the payload never reaches the visible draft, and a single
   backspace deletes the whole chunk, so the idle placeholder returns. *)
let%expect_test "a large paste collapses and backspace deletes the chunk" =
  Tui.run ~name:"composer-paste" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.paste t "alpha\nbeta\ngamma\ndelta";
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
22 | ❯ [Pasted text #1 +3 lines]
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}];
  Tui.keys t Key.backspace;
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]

(* ctrl+c on a non-empty draft is the one-press discard-to-history: the draft
   clears immediately, and [up] recalls it. *)
let%expect_test "ctrl+c discards a draft in one press and up recalls it" =
  Tui.run ~name:"composer-ctrlc" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t "discard me";
  Tui.settle t;
  Tui.keys t Key.ctrl_c;
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}];
  Tui.keys t Key.up;
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
22 | ❯ discard me
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]

(* "?" on an empty draft toggles the shortcuts sheet without typing into the
   draft; esc closes it. A leading "!" enters shell mode; esc exits it by
   clearing the "!" draft, so the ❯ marker and idle placeholder return. *)
let%expect_test
    "the help sheet and shell mode toggle without touching the draft" =
  Tui.run ~name:"composer-affordances" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t "?";
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
16 | ────────────────────────────────────────────────────────────────────────────────
17 | ❯ message spice
18 | ────────────────────────────────────────────────────────────────────────────────
19 |   composer       history                      controls
20 |   /  commands    shift+enter  newline         ←                focus agents
21 |   @  file paths  ↑ ↓          prompt history  ctrl+o           verbose reasoning
22 |   !  shell mode  ctrl+r       search history  pageup pagedown  scroll
23 |   ?  this help   esc esc      interrupt turn  ctrl+c ctrl+c    quit
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.keys t Key.escape;
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.keys t "!ls";
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
22 | ! !ls
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   esc exit shell · ↵ run                                               ! shell|}];
  Tui.keys t Key.escape;
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]
