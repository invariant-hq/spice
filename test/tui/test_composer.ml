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

let unknown_slash_draft = "/tmp/build.log has the error, can you look"
let shell_draft = "printf shell-escape"

(* A slash-prefixed line that matches no command is still an ordinary prompt.
   Enter closes the empty palette and submits through the same turn path as any
   other prompt; the provider expectation pins the exact text that crosses the
   boundary. *)
let%expect_test "enter submits a slash draft when no command matches" =
  let script =
    script
    @ [
        Provider_script.message ~expect:[ unknown_slash_draft ] ~id:"resp-2"
          "I can inspect that build log.";
      ]
  in
  Tui.run ~name:"composer-unknown-slash-submit" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t unknown_slash_draft;
  Tui.enter t;
  Tui.settle t;
  Printf.printf "submitted: %b\n"
    (Screen.has "I can inspect that build log." (Tui.screen t));
  [%expect {|submitted: true|}]

(* Escape owns only the open palette: it must leave the no-match text in the
   composer. A later Escape then enters the ordinary guarded clear rung, whose
   second press saves the draft to history before clearing it; Up recovers the
   exact slash-prefixed prompt. *)
let%expect_test
    "escape preserves an unknown slash draft for guarded discard and recall" =
  Tui.run ~name:"composer-unknown-slash-escape" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t unknown_slash_draft;
  Tui.settle t;
  Printf.printf "palette open: %b\n"
    (Screen.has "no matching commands" (Tui.screen t));
  Tui.keys t Key.escape;
  Tui.settle t;
  let after_palette_escape = Tui.screen t in
  Printf.printf "palette closed: %b\ndraft preserved: %b\n"
    (Screen.lacks "no matching commands" after_palette_escape)
    (Screen.has unknown_slash_draft after_palette_escape);
  Tui.keys t Key.escape;
  Tui.settle t;
  Printf.printf "clear guarded: %b\n"
    (Screen.has "Esc again to clear" (Tui.screen t));
  Tui.keys t Key.escape;
  Tui.settle t;
  Printf.printf "discarded: %b\n"
    (Screen.lacks unknown_slash_draft (Tui.screen t));
  Tui.keys t Key.up;
  Tui.settle t;
  Printf.printf "recalled: %b\n"
    (Screen.has unknown_slash_draft (Tui.screen t));
  [%expect
    {|
    palette open: true
    palette closed: true
    draft preserved: true
    clear guarded: true
    discarded: true
    recalled: true|}]

(* Shell mode changes how a draft is submitted, not the law for discarding it.
   A non-empty command therefore takes the same guarded two presses as prose;
   the second press saves the shell invocation, and Up restores both its mode
   and its command. *)
let%expect_test "shell escape is guarded and up recalls the command" =
  Tui.run ~name:"composer-shell-escape" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t ("!" ^ shell_draft);
  Tui.keys t Key.escape;
  Tui.settle t;
  let guarded = Tui.screen t in
  Printf.printf "clear guarded: %b\ncommand preserved: %b\n"
    (Screen.has "Esc again to clear" guarded)
    (Screen.has shell_draft guarded);
  Tui.keys t Key.escape;
  Tui.settle t;
  Printf.printf "discarded: %b\n" (Screen.lacks shell_draft (Tui.screen t));
  Tui.keys t Key.up;
  Tui.settle t;
  let recalled = Tui.screen t in
  Printf.printf "shell recalled: %b\ncommand recalled: %b\n"
    (Screen.has "! shell" recalled)
    (Screen.has shell_draft recalled);
  [%expect
    {|
    clear guarded: true
    command preserved: true
    discarded: true
    shell recalled: true
    command recalled: true|}]

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
15 | ────────────────────────────────────────────────────────────────────────────────
16 | ❯ message spice
17 | ────────────────────────────────────────────────────────────────────────────────
18 |   composer       history                      controls
19 |   /  commands    shift+enter  newline         ←                focus agents
20 |   @  file paths  ↑ ↓          prompt history  ctrl+o           verbose reasoning
21 |   !  shell mode  ctrl+r       search history  shift+tab        toggle approvals
22 |   ?  this help   esc esc      interrupt turn  pageup pagedown  scroll
23 |                                               ctrl+c ctrl+c    quit
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
  Tui.keys t "!";
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
22 | ! shell command
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

(* The leading trigger selects shell mode and is consumed before the controlled
   textarea renders. The warning-colored [!] is therefore the only shell marker
   beside the command; the command buffer must not contribute a second one. *)
let%expect_test "shell mode renders one marker beside the command" =
  Tui.run ~name:"composer-shell-marker" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t "!echo composer-marker";
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
22 | ! echo composer-marker
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   esc exit shell · ↵ run                                               ! shell|}]
