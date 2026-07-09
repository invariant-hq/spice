(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The unified [@] file completion (doc/ui-design/03-composer.md §File
   completion), exercised on the transcript — where a session composes most of
   its messages. A real file tree is written into the temp project so the lazy
   directory enumeration has known content; one settled turn runs first so the
   list opens over a transcript, not the home stage. *)

let script =
  [
    Provider.message ~expect:[ "say hello" ] ~id:"resp-1"
      "Hello from the fake provider.";
  ]

let seed p =
  Project.write p "lib/foo.ml" "let foo = 1\n";
  Project.write p "lib/sub/bar.ml" "let bar = 2\n";
  Project.write p "node_modules/junk.js" "module.exports = 0\n";
  Project.write p "readme.md" "# fixture\n"

let reach_transcript t =
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t

(* "@" opens the unified list above the composer: directory rows carry a
   trailing "/", every row a "+" glyph, and the ignored [node_modules] is
   absent. A query narrows it (text-is-the-filter); a no-match query notes. *)
let%expect_test "@ opens the list; dirs carry a slash; a no-match query notes" =
  Tui.run ~name:"mention-open" ~provider:script ~seed @@ fun t ->
  reach_transcript t;
  Tui.keys t "@";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
18 | ❯ + lib/
19 |   + dune-project
20 |   + readme.md
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ @
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/spice-tui-next-mention-open · gpt-5.5 medium · dune: ✗     ? for shortcuts|}];
  Tui.keys t "zzz";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
20 |   no matching files
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ @zzz
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/spice-tui-next-mention-open · gpt-5.5 medium · dune: ✗     ? for shortcuts|}]

(* Tab on the selected directory descends into it: its children load and inline
   below it, and the list stays open. *)
let%expect_test "tab descends into a directory, children appear" =
  Tui.run ~name:"mention-descend" ~provider:script ~seed @@ fun t ->
  reach_transcript t;
  Tui.keys t "@";
  Tui.settle t;
  Tui.keys t Keys.tab;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
16 | ❯ + lib/
17 |   + lib/sub/
18 |   + lib/foo.ml
19 |   + dune-project
20 |   + readme.md
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ @
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/spice-tui-next-mention-descend · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* ↵ on a selected file inserts it as an atomic [@]-prefixed reference and
   closes the list. *)
let%expect_test "enter on a file inserts the ref and closes the list" =
  Tui.run ~name:"mention-insert" ~provider:script ~seed @@ fun t ->
  reach_transcript t;
  Tui.keys t "@readme";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
20 | ❯ + readme.md
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ @readme
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/spice-tui-next-mention-insert · gpt-5.5 medium · dune: ✗   ? for shortcuts|}];
  Tui.keys t Keys.enter;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
22 | ❯ @readme.md
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/spice-tui-next-mention-insert · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

(* Esc closes the list and LEAVES the literal [@]-token in the draft — unlike
   the palette's esc, which clears its slash input. Backspacing the "@" away
   also closes the list, the draft empty again. *)
let%expect_test "esc leaves the @-token; backspace past @ closes and clears" =
  Tui.run ~name:"mention-esc" ~provider:script ~seed @@ fun t ->
  reach_transcript t;
  Tui.keys t "@lib";
  Tui.settle t;
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
22 | ❯ @lib
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/tmp/spice-tui-next-mention-esc · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.keys t Keys.backspace;
  Tui.keys t Keys.backspace;
  Tui.keys t Keys.backspace;
  Tui.keys t Keys.backspace;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
24 |   …/tmp/spice-tui-next-mention-esc · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]
