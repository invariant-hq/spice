(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* Session lifecycle, re-expressed as full-frame goldens: resume at launch onto a
   seeded document's replayed transcript, resume-then-submit landing a reply in
   that transcript, the /sessions quick-switch panel (recents, filter, empty
   state, resume, browse), and the /fork and /rename commands over an attached
   session. The old pty suite could not golden the panel because relative ages
   were wall-clock; under the virtual clock the age is a deterministic function
   of test time, so the whole frame is stable.

   Virtual time is pinned at the epoch (1000 s ⇒ 1_000_000 ms) for every test, so
   sessions seeded a few ms below it read "just now". *)

(* The virtual clock's launch instant in milliseconds — the session metadata's
   [updated_at] unit. Sessions seeded at or just below this read as most recent. *)
let now_ms = 1_000_000

(* A resumable session with an explicit update time (recency order and age are
   deterministic under virtual time) and no events, so it lists but replays
   empty. *)
let seed_session project id ~title ~updated_at_ms =
  Util.write_file
    (Project.data project
       (Filename.concat "sessions" (Filename.concat id "session.json")))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":%d},"events":[]}|}
       id title (Project.root project) updated_at_ms)

(* Four sessions, newest first, all a few ms below the epoch so every age reads
   "just now" and recency order is fixed. *)
let seed_four project =
  seed_session project "ses_1" ~title:"parser streaming fix" ~updated_at_ms:now_ms;
  seed_session project "ses_2" ~title:"config gadt rework"
    ~updated_at_ms:(now_ms - 1000);
  seed_session project "ses_3" ~title:"review layer wiring"
    ~updated_at_ms:(now_ms - 2000);
  seed_session project "ses_4" ~title:"auth flow polish"
    ~updated_at_ms:(now_ms - 3000)

(* A resumable session carrying one finished turn, so resuming it replays a real
   transcript. Recent enough to head the recents list. *)
let seed_prompt project id ~title ~prompt =
  Util.write_file
    (Project.data project
       (Filename.concat "sessions" (Filename.concat id "session.json")))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":%d},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"%s"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"max_steps":100,"declarations":[],"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id title (Project.root project) now_ms prompt)

let open_panel t =
  Tui.keys t "/sessions";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t

let open_screen t =
  open_panel t;
  Tui.keys t Keys.tab;
  Tui.settle t

(* {2 Resume at launch} *)

(* Resume opens on the replayed transcript, not the home prelude: the seeded
   session's finished turn folds back through the reducer so its user prompt
   lands as a User block, and the home welcome notice is gone. *)
let%expect_test "resume opens on the replayed transcript" =
  Tui.run ~name:"session-resume" ~session:"ses_resume"
    ~seed:(fun project ->
      seed_prompt project "ses_resume" ~title:"streaming parser fix"
        ~prompt:"trace the streaming parser bug")
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ trace the streaming parser bug
07 |
08 |
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

(* Resume then submit a turn: the reply lands in the SAME transcript, below the
   replayed prompt — the resumed document is attached and continued, not a fresh
   session. The completion is gated so the settled frame is observed after the
   release (the stable pattern; an ungated final races the working spinner). *)
let%expect_test "resume then submit lands the reply in the resumed transcript" =
  let script =
    [
      Provider.message ~expect:[ "off-by-one" ] ~gate:"fin" ~id:"resp-1"
        "The streaming parser drops the final chunk.";
    ]
  in
  Tui.run ~name:"session-resume-submit" ~session:"ses_resume" ~provider:script
    ~seed:(fun project ->
      seed_prompt project "ses_resume" ~title:"streaming parser fix"
        ~prompt:"trace the streaming parser bug")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "where is the off-by-one";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  (* NOTE: the composer (row 22) retains the submitted text after this turn on a
     RESUMED session, where a home-stage submit clears it to the placeholder (cf.
     test_tools). Deterministic — survives an advance+settle — so goldened as-is;
     flagged as a candidate product bug in the resumed-chat composer reset. *)
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ trace the streaming parser bug
07 |
08 | ❯ where is the off-by-one
09 |
10 | ⏺ The streaming parser drops the final chunk.
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
22 | ❯ where is the off-by-one
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* {2 Quick-switch panel} *)

(* /sessions from the home stage: the recents render below a full-width boundary
   and the sessions chip, newest first, the newest row cursored. *)
let%expect_test "quick-switch panel opens from the home stage" =
  Tui.run ~name:"session-panel-open" ~seed:seed_four @@ fun t ->
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
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
12 |
13 |
14 |
15 |
16 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
17 |    sessions
18 |
19 |   ❯ parser streaming fix                                              just now
20 |     config gadt rework                                                just now
21 |     review layer wiring                                               just now
22 |     auth flow polish                                                  just now
23 |
24 |   ↵ resume · tab browse · type to filter · ↑↓ select · esc close|}]

(* Type-to-filter (the filter law): a distinctive word narrows the four rows to
   one, and the filter echoes faint beside the chip. *)
let%expect_test "type-to-filter narrows the rows" =
  Tui.run ~name:"session-panel-filter" ~seed:seed_four @@ fun t ->
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "gadt";
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
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
20 |    sessions   gadt
21 |
22 |   ❯ config gadt rework                                                just now
23 |
24 |   ↵ resume · tab browse · type to filter · ↑↓ select · esc close|}]

(* Empty state: a workspace with no sessions shows one muted sentence rather than
   an empty content region. *)
let%expect_test "empty workspace shows the one-sentence empty state" =
  Tui.run ~name:"session-panel-empty" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
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
13 |
14 |
15 |
16 |
17 |
18 |
19 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
20 |    sessions
21 |
22 |   No recent sessions in this workspace.
23 |
24 |   ↵ resume · tab browse · type to filter · ↑↓ select · esc close|}]

(* ↵ on the selection attaches and replays the session, so the chat opens with
   the transcript rebuilt and the panel chrome gone. *)
let%expect_test "enter resumes the selected session into chat" =
  Tui.run ~name:"session-panel-resume"
    ~seed:(fun project ->
      seed_prompt project "ses_resume" ~title:"resume target"
        ~prompt:"hello from the past")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ hello from the past
07 |
08 |
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

(* tab promotes the quick-switch panel to the browse screen: its keymap hint
   ([f fork], [r rename]) — which the panel never shows — confirms the screen. *)
let%expect_test "tab promotes the panel to the browse screen" =
  Tui.run ~name:"session-panel-browse" ~seed:seed_four @@ fun t ->
  Tui.settle t;
  Tui.keys t "/sessions";
  Tui.enter t;
  Tui.settle t;
  Tui.keys t Keys.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ──  sessions ──────────────────────────────────────────────────────4 sessions ──
02 |
03 |   today
04 |   ❯ parser streaming fix                                   just now · 0 turns
05 |     $PROJECT
06 |     config gadt rework                                     just now · 0 turns
07 |     review layer wiring                                    just now · 0 turns
08 |     auth flow polish                                       just now · 0 turns
09 |
10 |   ↵ resume · f fork · r rename · d delete · / filter · esc back
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
21 |
22 |
23 |
24 ||}]

(* {2 Fork and rename} *)

(* /fork forks the attached session into a child and continues there: the fresh
   transcript carries the /fork echo, the lineage record naming the parent's
   title, and the inherited history replays below. *)
let%expect_test "fork continues in a child with the lineage record" =
  Tui.run ~name:"session-fork" ~session:"ses_parent"
    ~seed:(fun project ->
      seed_prompt project "ses_parent" ~title:"streaming parser fix"
        ~prompt:"trace the streaming parser bug")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/fork";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ /fork
07 |
08 |   forked to a new session · ↳ from "streaming parser fix"
09 |
10 | ❯ trace the streaming parser bug
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
22 | ❯ /fork
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* /fork on the home stage flashes the no-session guard. *)
let%expect_test "fork on the home stage flashes the no-session guard" =
  Tui.run ~name:"session-fork-guard" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/fork";
  Tui.enter t;
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
14 |           ❯ /fork
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   fork: no active session|}]

(* /rename over an attached session: pasted (so the palette never intercepts) it
   seeds the composer with [/rename ], so typing the title and submitting fires
   the rename. The echo carrying the full [/rename <title>] line proves the seed
   happened, and the settle copy names the new title. *)
let%expect_test "rename seeds bare, renames with a title, and echoes the result" =
  Tui.run ~name:"session-rename" ~session:"ses_rename"
    ~seed:(fun project ->
      seed_prompt project "ses_rename" ~title:"streaming parser fix"
        ~prompt:"trace the streaming parser bug")
  @@ fun t ->
  Tui.settle t;
  (* Uppercase so the canonical lowercase seed is a visible change to settle on
     before typing — the controlled composer syncs the seeded value a frame
     later, and typing into the stale widget would clobber the seed. *)
  Tui.paste t "/RENAME";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "the tokenizer rewrite";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ trace the streaming parser bug
07 |
08 | ❯ /rename the tokenizer rewrite
09 |
10 |   renamed to "the tokenizer rewrite"
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
  (* The new title persisted to the store, not just the transcript. *)
  print_string
    (if Seed.session_file_contains (Tui.project t) "ses_rename"
          "the tokenizer rewrite"
     then "persisted: true\n"
     else "persisted: false\n");
  [%expect {| persisted: true |}]

(* {2 Launch inputs} *)

(* [--draft] seeds the composer without starting anything: the process stays on
   the home stage with the text ready to edit. *)
let%expect_test "draft seeds the composer on the home stage" =
  Tui.run ~name:"session-draft" ~draft:"fix the parser first" @@ fun t ->
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
14 |           ❯ fix the parser first
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}]

(* [-p]/[--prompt] submits the text as the first turn: the TUI opens on the chat
   layout with the prompt echoed and the reply settled — the home stage never
   shows. The completion is gated for the stable settled frame. *)
let%expect_test "prompt submits the first turn at launch" =
  let script =
    [
      Provider.message ~expect:[ "fix the parser" ] ~gate:"fin" ~id:"resp-1"
        "The parser drops the final chunk.";
    ]
  in
  Tui.run ~name:"session-prompt" ~submit:"fix the parser" ~provider:script
  @@ fun t ->
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ fix the parser
07 |
08 | ⏺ The parser drops the final chunk.
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

(* Resuming through the quick switcher replaces the attached replay rather than
   merging it with the previous session. *)
let%expect_test "resuming a second session replaces the first replay" =
  Tui.run ~name:"session-resume-replace" ~session:"ses_a"
    ~seed:(fun project ->
      seed_prompt project "ses_a" ~title:"streaming parser fix"
        ~prompt:"trace the streaming parser bug";
      seed_prompt project "ses_b" ~title:"config gadt rework"
        ~prompt:"rework the config gadt layer")
  @@ fun t ->
  Tui.settle t;
  open_panel t;
  Tui.keys t "gadt";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ rework the config gadt layer
07 |
08 |
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

(* The browse screen owns selection expansion, filtering, inline rename, and
   the two-press delete confirmation. Drive the lifecycle in one seeded store so
   every mutation is visible in the next full frame. *)
let%expect_test "browse navigation, filtering, rename, and delete round trip" =
  Tui.run ~name:"session-screen-lifecycle" ~seed:seed_four @@ fun t ->
  Tui.settle t;
  open_screen t;
  Tui.keys t Keys.down;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 | ──  sessions ──────────────────────────────────────────────────────4 sessions ──
02 |
03 |   today
04 |     parser streaming fix                                   just now · 0 turns
05 |   ❯ config gadt rework                                     just now · 0 turns
06 |     $PROJECT
07 |     review layer wiring                                    just now · 0 turns
08 |     auth flow polish                                       just now · 0 turns
09 |
10 |   ↵ resume · f fork · r rename · d delete · / filter · esc back
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
21 |
22 |
23 |
24 ||}];
  Tui.keys t "/gadt";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 | ──  sessions ──────────────────────────────────────────────────────4 sessions ──
02 |   /gadt  1 match
03 |
04 |   today
05 |   ❯ config gadt rework                                     just now · 0 turns
06 |     $PROJECT
07 |
08 |   ↵ resume · ↑↓ select · esc clear filter
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
21 |
22 |
23 |
24 ||}];
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.keys t "r";
  Tui.settle t;
  Tui.keys t " renamed";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 | ──  sessions ──────────────────────────────────────────────────────4 sessions ──
02 |
03 |   today
04 |   ❯ parser streaming fix renamed                           just now · 0 turns
05 |     $PROJECT
06 |     config gadt rework                                     just now · 0 turns
07 |     review layer wiring                                    just now · 0 turns
08 |     auth flow polish                                       just now · 0 turns
09 |
10 |   ↵ resume · f fork · r rename · d delete · / filter · esc back
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
21 |
22 |
23 |
24 ||}];
  Tui.keys t "d";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 | ──  sessions ──────────────────────────────────────────────────────4 sessions ──
02 |
03 |   today
04 |   delete "parser streaming fix renamed"? press d again · esc cancel
05 |     config gadt rework                                     just now · 0 turns
06 |     review layer wiring                                    just now · 0 turns
07 |     auth flow polish                                       just now · 0 turns
08 |
09 |   d delete · esc cancel
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
21 |
22 |
23 |
24 ||}];
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.keys t "d";
  Tui.settle t;
  Tui.keys t "d";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 | ──  sessions ──────────────────────────────────────────────────────3 sessions ──
02 |
03 |   today
04 |   ❯ config gadt rework                                     just now · 0 turns
05 |     $PROJECT
06 |     review layer wiring                                    just now · 0 turns
07 |     auth flow polish                                       just now · 0 turns
08 |
09 |   ↵ resume · f fork · r rename · d delete · / filter · esc back
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
21 |
22 |
23 |
24 ||}]

(* Tab promotes an empty panel to the screen's own empty state. A panel filter
   is otherwise carried into the screen and remains open for editing. *)
let%expect_test "browse empty state and panel filter carry-over" =
  (Tui.run ~name:"session-screen-empty" @@ fun t ->
   Tui.settle t;
   open_screen t;
   Tui.print t;
   [%expect {|01 | ──  sessions ──────────────────────────────────────────────────────0 sessions ──
02 |
03 |   No sessions in this workspace.
04 |
05 |   ↵ resume · f fork · r rename · d delete · / filter · esc back
06 |
07 |
08 |
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
21 |
22 |
23 |
24 ||}]);
  Tui.run ~name:"session-screen-carry" ~seed:seed_four @@ fun t ->
  Tui.settle t;
  open_panel t;
  Tui.keys t "gadt";
  Tui.settle t;
  Tui.keys t Keys.tab;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 | ──  sessions ──────────────────────────────────────────────────────4 sessions ──
02 |   /gadt  1 match
03 |
04 |   today
05 |   ❯ config gadt rework                                     just now · 0 turns
06 |     $PROJECT
07 |
08 |   ↵ resume · ↑↓ select · esc clear filter
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
21 |
22 |
23 |
24 ||}]

(* /clear detaches the old transcript but preserves its document; the next
   prompt attaches a fresh session and runs normally. *)
let%expect_test "clear preserves the old session and attaches a fresh turn" =
  let script =
    [
      Provider.message ~expect:[ "off-by-one" ] ~gate:"fin" ~id:"resp-clear"
        "The tokenizer drops the final chunk.";
    ]
  in
  Tui.run ~name:"session-clear" ~session:"ses_clear" ~provider:script
    ~seed:(fun project ->
      seed_prompt project "ses_clear" ~title:"streaming parser fix"
        ~prompt:"trace the streaming parser bug")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/clear";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "where is the off-by-one";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ /clear
07 |
08 |   cleared the conversation · previous saved, /sessions to resume
09 |
10 | ❯ where is the off-by-one
11 |
12 | ⏺ The tokenizer drops the final chunk.
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ where is the off-by-one
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}];
  print_string
    (if Seed.session_file_contains (Tui.project t) "ses_clear"
          "trace the streaming parser bug"
     then "previous session preserved\n"
     else "previous session missing\n");
  [%expect {| previous session preserved |}]

(* /compact records the host refusal without removing visible history. The
   home-stage /compact and /rename commands surface their no-session guards. *)
let%expect_test "compact result and no-session command guards render" =
  (Tui.run ~name:"session-compact" ~session:"ses_compact" ~provider:[]
     ~seed:(fun project ->
       seed_prompt project "ses_compact" ~title:"streaming parser fix"
         ~prompt:"trace the streaming parser bug")
   @@ fun t ->
   Tui.settle t;
   Tui.keys t "/compact";
   Tui.settle t;
   Tui.enter t;
   Tui.settle t;
   Tui.print t;
   [%expect {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ trace the streaming parser bug
07 |
08 | ❯ /compact
09 |
10 |   compaction failed: conversation already fits within the retained tail;
11 | nothing to compact
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]);
  Tui.run ~name:"session-command-guards" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/compact";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
24 |   no session to compact|}];
  Tui.keys t "/rename";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "nope";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
24 |   no session to rename|}]

[%%run_tests "spice.tui.session"]
