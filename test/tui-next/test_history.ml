(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* Prompt history (lib/tui/history.ml, wired through the runtime): the global
   JSONL loads at boot, arrow-walk recalls it, and ctrl+r reverse search
   fuzzy-matches and inserts the pick into the draft (never submits). The
   history file is seeded on disk before launch under the isolated config home;
   no turns run. *)

(* A prompt on disk is recalled by Up on the empty draft — the load path,
   end to end through the runtime. *)
let%expect_test "up recalls a prompt loaded from disk" =
  Tui.run ~name:"history-load" ~seed:(fun p ->
      Seed.history p [ Seed.history_entry ~ts:1000 "alpha prompt" ])
  @@ fun t ->
  Tui.settle t;
  Tui.keys t Keys.up;
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
13 |           ❯ alpha prompt
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
24 |   ! not logged in · /login · …ui-next-history-load · gpt-5.5 medium · dune: ✗|}]

(* ctrl+r opens reverse search over the loaded prompts; a fuzzy subsequence
   query narrows the list; ↵ inserts the pick into the draft and never submits
   (the draft keeps the text, no turn starts). *)
let%expect_test "ctrl+r fuzzy-searches history and inserts the pick" =
  Tui.run ~name:"history-search" ~seed:(fun p ->
      Seed.history p
        [
          Seed.history_entry ~ts:1000 "alpha one";
          Seed.history_entry ~ts:2000 "beta two";
        ])
  @@ fun t ->
  Tui.settle t;
  Tui.keys t Keys.ctrl_r;
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
12 |           reverse-i-search:
13 |           ❯ beta two
14 |             alpha one
15 |           ────────────────────────────────────────────────────────────
16 |           ⌕ search history
17 |           ────────────────────────────────────────────────────────────
18 |
19 |                      dune       ✗ · diagnostics unavailable
20 |                      account    none — /login to connect
21 |
22 |                       sandbox: danger-full-access (config)
23 |
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}];
  Tui.keys t "bt";
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
12 |           reverse-i-search: bt
13 |           ❯ beta two
14 |           ────────────────────────────────────────────────────────────
15 |           ⌕ bt
16 |           ────────────────────────────────────────────────────────────
17 |
18 |                      dune       ✗ · diagnostics unavailable
19 |                      account    none — /login to connect
20 |
21 |                       sandbox: danger-full-access (config)
22 |
23 |
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}];
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
13 |           ❯ beta two
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
24 |   ! not logged in · /login · …-next-history-search · gpt-5.5 medium · dune: ✗|}]

(* ctrl+r borrows the current draft as an empty query; esc closes the search
   and restores the exact draft that was displaced, even with no stored
   history — the surface is the composer's, not the list's. *)
let%expect_test "ctrl+r borrows the draft and esc restores it" =
  Tui.run ~name:"history-esc" @@ fun t ->
  Tui.settle t;
  Tui.keys t "keep me";
  Tui.settle t;
  Tui.keys t Keys.ctrl_r;
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
12 |           reverse-i-search:
13 |             no prompt history
14 |           ────────────────────────────────────────────────────────────
15 |           ⌕ search history
16 |           ────────────────────────────────────────────────────────────
17 |
18 |                      dune       ✗ · diagnostics unavailable
19 |                      account    none — /login to connect
20 |
21 |                       sandbox: danger-full-access (config)
22 |
23 |
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}];
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
13 |           ❯ keep me
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
24 |   ! not logged in · /login · …tui-next-history-esc · gpt-5.5 medium · dune: ✗|}]

(* A query matching no stored prompt shows the muted "no matching prompts" note
   (distinct from the empty "no prompt history"). *)
let%expect_test "ctrl+r shows the no-match note" =
  Tui.run ~name:"history-nomatch" ~seed:(fun p ->
      Seed.history p [ Seed.history_entry ~ts:1000 "alpha one" ])
  @@ fun t ->
  Tui.settle t;
  Tui.keys t Keys.ctrl_r;
  Tui.settle t;
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
12 |           reverse-i-search: zzz
13 |             no matching prompts
14 |           ────────────────────────────────────────────────────────────
15 |           ⌕ zzz
16 |           ────────────────────────────────────────────────────────────
17 |
18 |                      dune       ✗ · diagnostics unavailable
19 |                      account    none — /login to connect
20 |
21 |                       sandbox: danger-full-access (config)
22 |
23 |
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}]
