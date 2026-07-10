(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* Prompt history (lib/tui/history.ml, wired through the runtime), exercised on
   the transcript where recall and search actually happen. The global JSONL is
   seeded on disk before launch; a settled turn then runs, so the submitted
   prompt joins the seeded entries in history exactly as a real session's would.
   Arrow-walk recalls, and ctrl+r reverse search fuzzy-matches and inserts the
   pick into the draft (never submits). *)

let script =
  [
    Provider_script.message ~expect:[ "say hello" ] ~gate:"history" ~id:"resp-1"
      "Hello from the fake provider.";
  ]

let history_entry ~ts text =
  Printf.sprintf
    {|{"schema_version":1,"type":"composer.history_entry","session_id":"ses_test","ts":%d,"draft":{"text":%S}}|}
    ts text

let seed_history project lines =
  Project.write_path
    (Project.state project "history.jsonl")
    (String.concat "\n" lines ^ "\n")

let reach_transcript t =
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "history";
  Tui.settle t

(* The recall walks newest-first: the turn's own prompt comes back on the first
   [up], the disk-loaded prompt on the second — proving the boot load and the
   in-session submission share one history. *)
let%expect_test "up walks recall from the turn prompt into the loaded history" =
  Tui.run ~name:"history-load" ~provider:script ~seed:(fun p ->
      seed_history p [ history_entry ~ts:1000 "alpha prompt" ])
  @@ fun t ->
  reach_transcript t;
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
22 | ❯ say hello
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}];
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
22 | ❯ alpha prompt
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* ctrl+r opens reverse search over the loaded prompts; a fuzzy subsequence
   query narrows the list; ↵ inserts the pick into the draft and never submits
   (the draft keeps the text, no turn starts). *)
let%expect_test "ctrl+r fuzzy-searches history and inserts the pick" =
  Tui.run ~name:"history-search" ~provider:script ~seed:(fun p ->
      seed_history p
        [
          history_entry ~ts:1000 "alpha one"; history_entry ~ts:2000 "beta two";
        ])
  @@ fun t ->
  reach_transcript t;
  Tui.keys t Key.ctrl_r;
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
17 | reverse-i-search:
18 | ❯ say hello
19 |   beta two
20 |   alpha one
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ⌕ search history
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}];
  Tui.keys t "bt";
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
19 | reverse-i-search: bt
20 | ❯ beta two
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ⌕ bt
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}];
  Tui.keys t Key.enter;
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
22 | ❯ beta two
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]

(* ctrl+r borrows the current draft as an empty query; esc closes the search
   and restores the exact draft that was displaced — the surface is the
   composer's, not the list's. *)
let%expect_test "ctrl+r borrows the draft and esc restores it" =
  Tui.run ~name:"history-esc" ~provider:script @@ fun t ->
  reach_transcript t;
  Tui.keys t "keep me";
  Tui.settle t;
  Tui.keys t Key.ctrl_r;
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
19 | reverse-i-search:
20 | ❯ say hello
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ⌕ search history
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}];
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
22 | ❯ keep me
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗       ? for shortcuts|}]

(* A query matching no stored prompt shows the muted "no matching prompts"
   note. *)
let%expect_test "ctrl+r shows the no-match note" =
  Tui.run ~name:"history-nomatch" ~provider:script ~seed:(fun p ->
      seed_history p [ history_entry ~ts:1000 "alpha one" ])
  @@ fun t ->
  reach_transcript t;
  Tui.keys t Key.ctrl_r;
  Tui.settle t;
  Tui.keys t "zzq";
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
19 | reverse-i-search: zzq
20 |   no matching prompts
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ⌕ zzq
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   ↵ insert · esc cancel · type to search                             ⌕ history|}]
