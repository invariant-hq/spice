(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The composer surface on the home stage (doc/ui-design/03-composer.md): a
   hard newline grows the frame in place, a large paste collapses to an atomic
   chunk, the esc / ctrl+c ladder saves the draft to prompt history, and the
   "?" and "!" affordances toggle the help sheet and shell mode without leaking
   into the draft. No turns run — these are pure home-stage frames. *)

(* A hard newline (the linefeed the composer binds to Newline) grows the frame;
   the "❯ " marker sits on the first visual row only. The two-stage esc ladder
   then arms a footer notice and, on the second press, saves the draft to
   history and clears it, which [up] recalls verbatim. *)
let%expect_test "hard newline grows the frame; esc clears and up recalls" =
  Tui.run ~name:"composer-multiline" @@ fun t ->
  Tui.settle t;
  Tui.keys t "line one";
  Tui.keys t Keys.linefeed;
  Tui.keys t "line two";
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
13 |           ❯ line one
14 |             line two
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |                      account    none — /login to connect
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · …t-composer-multiline · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t Keys.escape;
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
13 |           ❯ line one
14 |             line two
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |                      account    none — /login to connect
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   Esc again to clear|}];
  Tui.keys t Keys.escape;
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
24 |   ! not logged in · /login · …t-composer-multiline · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t Keys.up;
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
13 |           ❯ line one
14 |             line two
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |                      account    none — /login to connect
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · …t-composer-multiline · gpt-5.5 medium · dune: ✗|}]

(* A paste of three-or-more lines collapses to an atomic [Pasted text #N +M
   lines] chunk; the payload never reaches the visible draft, and a single
   backspace deletes the whole chunk, so the idle placeholder returns. *)
let%expect_test "a large paste collapses and backspace deletes the chunk" =
  Tui.run ~name:"composer-paste" @@ fun t ->
  Tui.settle t;
  Tui.paste t "alpha\nbeta\ngamma\ndelta";
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
13 |           ❯ [Pasted text #1 +3 lines]
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
24 |   ! not logged in · /login · …-next-composer-paste · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t Keys.backspace;
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
24 |   ! not logged in · /login · …-next-composer-paste · gpt-5.5 medium · dune: ✗|}]

(* ctrl+c on a non-empty draft is the one-press discard-to-history: the draft
   clears immediately, and [up] recalls it. *)
let%expect_test "ctrl+c discards a draft in one press and up recalls it" =
  Tui.run ~name:"composer-ctrlc" @@ fun t ->
  Tui.settle t;
  Tui.keys t "discard me";
  Tui.settle t;
  Tui.keys t Keys.ctrl_c;
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
24 |   ! not logged in · /login · …-next-composer-ctrlc · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t Keys.up;
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
13 |           ❯ discard me
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
24 |   ! not logged in · /login · …-next-composer-ctrlc · gpt-5.5 medium · dune: ✗|}]

(* "?" on an empty draft toggles the shortcuts sheet without typing into the
   draft; esc closes it. A leading "!" enters shell mode; esc exits it by
   clearing the "!" draft, so the ❯ marker and idle placeholder return. *)
let%expect_test
    "the help sheet and shell mode toggle without touching the draft" =
  Tui.run ~name:"composer-affordances" @@ fun t ->
  Tui.settle t;
  Tui.keys t "?";
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
20 |   composer       history                      controls
21 |   /  commands    shift+enter  newline         ←                focus agents
22 |   @  file paths  ↑ ↓          prompt history  ctrl+o           verbose output
23 |   !  shell mode  ctrl+r       search history  shift+tab        cycle approvals
24 |   ?  this help   esc esc      interrupt turn  pageup pagedown  scroll|}];
  Tui.keys t Keys.escape;
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
24 |   ! not logged in · /login · …composer-affordances · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t "!ls";
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
13 |           ! !ls
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
24 |   esc exit shell · ↵ run                                               ! shell|}];
  Tui.keys t Keys.escape;
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
24 |   ! not logged in · /login · …composer-affordances · gpt-5.5 medium · dune: ✗|}]
