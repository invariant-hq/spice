(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The unified [@] file completion (doc/ui-design/03-composer.md §File
   completion). A real file tree is written into the temp project so the lazy
   directory enumeration has known content; the list is driven through the live
   app wiring. No turns run. *)

let seed p =
  Project.write p "lib/foo.ml" "let foo = 1\n";
  Project.write p "lib/sub/bar.ml" "let bar = 2\n";
  Project.write p "node_modules/junk.js" "module.exports = 0\n";
  Project.write p "readme.md" "# fixture\n"

(* "@" opens the unified list above the frame: directory rows carry a trailing
   "/", every row a "+" glyph, and the ignored [node_modules] is absent. A
   query narrows it (text-is-the-filter); a no-match query shows the note. *)
let%expect_test "@ opens the list; dirs carry a slash; a no-match query notes" =
  Tui.run ~name:"mention-open" ~seed @@ fun t ->
  Tui.settle t;
  Tui.keys t "@";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
12 |           ❯ + lib/
13 |             + dune-project
14 |             + readme.md
15 |           ────────────────────────────────────────────────────────────
16 |           ❯ @
17 |           ────────────────────────────────────────────────────────────
18 |
19 |                      dune       ✗ · diagnostics unavailable
20 |                      account    none — /login to connect
21 |
22 |                       sandbox: danger-full-access (config)
23 |
24 |   ! not logged in · /login · …ui-next-mention-open · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t "zzz";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
12 |             no matching files
13 |           ────────────────────────────────────────────────────────────
14 |           ❯ @zzz
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |                      account    none — /login to connect
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · …ui-next-mention-open · gpt-5.5 medium · dune: ✗|}]

(* Tab on the selected directory descends into it: its children load and inline
   below it, and the list stays open. *)
let%expect_test "tab descends into a directory, children appear" =
  Tui.run ~name:"mention-descend" ~seed @@ fun t ->
  Tui.settle t;
  Tui.keys t "@";
  Tui.settle t;
  Tui.keys t Keys.tab;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
12 |           ❯ + lib/
13 |             + lib/sub/
14 |             + lib/foo.ml
15 |             + dune-project
16 |             + readme.md
17 |           ────────────────────────────────────────────────────────────
18 |           ❯ @
19 |           ────────────────────────────────────────────────────────────
20 |
21 |                      dune       ✗ · diagnostics unavailable
22 |                      account    none — /login to connect
23 |
24 |                       sandbox: danger-full-access (config)|}]

(* ↵ on a selected file inserts it as an atomic [@]-prefixed reference and
   closes the list. *)
let%expect_test "enter on a file inserts the ref and closes the list" =
  Tui.run ~name:"mention-insert" ~seed @@ fun t ->
  Tui.settle t;
  Tui.keys t "@readme";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
12 |           ❯ + readme.md
13 |           ────────────────────────────────────────────────────────────
14 |           ❯ @readme
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |                      account    none — /login to connect
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · …-next-mention-insert · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t Keys.enter;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
13 |           ❯ @readme.md
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
24 |   ! not logged in · /login · …-next-mention-insert · gpt-5.5 medium · dune: ✗|}]

(* Esc closes the list and LEAVES the literal [@]-token in the draft — unlike
   the palette's esc, which clears its slash input. Backspacing the "@" away
   also closes the list, the draft empty again. *)
let%expect_test "esc leaves the @-token; backspace past @ closes and clears" =
  Tui.run ~name:"mention-esc" ~seed @@ fun t ->
  Tui.settle t;
  Tui.keys t "@lib";
  Tui.settle t;
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
13 |           ❯ @lib
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
24 |   ! not logged in · /login · …tui-next-mention-esc · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t Keys.backspace;
  Tui.keys t Keys.backspace;
  Tui.keys t Keys.backspace;
  Tui.keys t Keys.backspace;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
24 |   ! not logged in · /login · …tui-next-mention-esc · gpt-5.5 medium · dune: ✗|}]
