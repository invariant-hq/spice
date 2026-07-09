(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] session quick-switch panel
   (doc/ui-design/03-ia-screens-overlays.md §Sessions, quick-switch panel; the
   surface seam of doc/plans/tui-next-surfaces.md phase 1). No turns run, so
   there is no fake provider: the tests seed session documents, drive [/sessions]
   on the real binary, and golden the rendered panel.

   Goldens pin SPICE_REDUCED_MOTION=1 so the lockup settles static, and the
   readable 80x24 the spec mockups use. Sessions are seeded with near-now update
   times so their relative age reads a stable "just now" — a fixed epoch would
   drift yearly (test_home's session line avoids goldening age for that reason).
   [/sessions] Enter is always sent as a SEPARATE write from the command text:
   an atomic ["/sessions\r"] is a known pty artifact. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* The panel under test is the hidden [tui-next] subcommand. *)
let run ?env ?rows ?cols project f = Term.run ?env ?rows ?cols project f

(* A resumable session document with an explicit update time, so recency order
   and the "just now" age are deterministic. Mirrors [Seed.session] but sets
   [updated_at] rather than fixing it at 1. *)
let seed_session project id ~title ~updated_at_ms =
  Util.write_file
    (Project.data project
       (Filename.concat "sessions" (Filename.concat id "session.json")))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":%Ld},"events":[]}|}
       id title (Project.root project) updated_at_ms)

(* A resumable session carrying one finished turn, so resuming it replays a real
   transcript (the first user prompt lands as a User block). Mirrors
   [Seed.prompt_session_titled] but takes an explicit recent [updated_at] so the
   row lists near the top. *)
let seed_prompt_session project id ~title ~prompt ~updated_at_ms =
  Util.write_file
    (Project.data project
       (Filename.concat "sessions" (Filename.concat id "session.json")))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":%Ld},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"%s"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id title (Project.root project) updated_at_ms prompt)

(* Four sessions, newest first, all within a minute of now so every age reads
   "just now". Returns nothing; the titles are asserted against the goldens. *)
let seed_four project =
  let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
  let at k = Int64.sub now (Int64.of_int (k * 1000)) in
  seed_session project "ses_1" ~title:"parser streaming fix"
    ~updated_at_ms:(at 0);
  seed_session project "ses_2" ~title:"config gadt rework" ~updated_at_ms:(at 1);
  seed_session project "ses_3" ~title:"review layer wiring"
    ~updated_at_ms:(at 2);
  seed_session project "ses_4" ~title:"auth flow polish" ~updated_at_ms:(at 3)

(* Submit the [/sessions] command with Enter as a SEPARATE write. The panel
   opens in its loading state, so callers wait on real content (a title, or the
   empty sentence) rather than the hint line, which the loading panel already
   shows. *)
let submit_sessions t =
  Term.send t "/sessions";
  Term.wait t (Screen.has "/sessions");
  Term.send t Keys.enter

(* Opening from the home stage: the four recents render below a full-width [▔]
   boundary and the filled [sessions] chip, the composer region replaced, the
   stage still above with its inset composer hidden, and the panel's own hint
   line in place of the footer. The newest row wears the [❯] cursor. *)
let%expect_test "quick-switch panel opens from the home stage" =
  Project.with_temp "panel-open" @@ fun project ->
  seed_four project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  submit_sessions t;
  (* Wait on the second title: it lives only in the panel (the stage's session
     line above shows only the newest), so its presence confirms the panel is
     open AND its rows have loaded — not the racy stage session line. *)
  Term.wait t (Screen.has "config gadt rework");
  print_fact "boundary present" (Screen.has "▔▔▔▔" (Term.screen t));
  print_fact "sessions chip present" (Screen.has "sessions" (Term.screen t));
  print_fact "all four titles present"
    (Screen.has "parser streaming fix" (Term.screen t)
    && Screen.has "config gadt rework" (Term.screen t)
    && Screen.has "review layer wiring" (Term.screen t)
    && Screen.has "auth flow polish" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|boundary present: true
sessions chip present: true
all four titles present: true
01 |
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

(* Type-to-filter (the filter law, 03-ia §The filter law): every printable
   narrows the four rows. A distinctive word leaves one row; the filter echoes
   faint beside the chip. *)
let%expect_test "type-to-filter narrows the rows" =
  Project.with_temp "panel-filter" @@ fun project ->
  seed_four project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  submit_sessions t;
  (* Wait on the second title: it lives only in the panel (the stage's session
     line above shows only the newest), so its presence confirms the panel is
     open AND its rows have loaded — not the racy stage session line. *)
  Term.wait t (Screen.has "config gadt rework");
  Term.send t "gadt";
  Term.wait t (fun s ->
      Screen.has "config gadt rework" s && Screen.lacks "auth flow polish" s);
  print_fact "matching row kept"
    (Screen.has "config gadt rework" (Term.screen t));
  (* The newest session also shows in the stage's session line above the panel,
     so narrowing is asserted through the panel-only rows, which vanish. *)
  print_fact "non-matching rows dropped"
    (Screen.lacks "review layer wiring" (Term.screen t)
    && Screen.lacks "auth flow polish" (Term.screen t));
  print_fact "filter echoed beside the chip" (Screen.has "gadt" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|matching row kept: true
non-matching rows dropped: true
filter echoed beside the chip: true
01 | 
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

(* Esc is the safe exit: it closes the panel and restores the composer with its
   [message spice] placeholder; the panel chrome is gone. *)
let%expect_test "esc closes the panel and restores the composer" =
  Project.with_temp "panel-esc" @@ fun project ->
  seed_four project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  submit_sessions t;
  (* Wait on the second title: it lives only in the panel (the stage's session
     line above shows only the newest), so its presence confirms the panel is
     open AND its rows have loaded — not the racy stage session line. *)
  Term.wait t (Screen.has "config gadt rework");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "message spice");
  print_fact "composer restored" (Screen.has "message spice" (Term.screen t));
  print_fact "panel hint gone" (Screen.lacks "type to filter" (Term.screen t));
  print_fact "boundary gone" (Screen.lacks "▔▔▔▔" (Term.screen t));
  [%expect
    {|
    composer restored: true
    panel hint gone: true
    boundary gone: true |}]

(* Esc restores the stage byte-for-byte (03-ia §Forms, "esc restores composer +
   draft untouched"). Opened from an empty composer, the round trip must leave
   the screen identical — the surface never invents a draft, and the shell
   cleared the [/sessions] command it consumed on open. *)
let%expect_test "esc-restore leaves the stage byte-stable" =
  Project.with_temp "panel-stable" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  (* Capture the stage only once the brief has settled, so [before] and [after]
     compare fully-loaded stages rather than a loading spinner against a loaded
     one. The empty workspace's facts are stable across refresh ticks. *)
  Term.wait t (Screen.has "sandbox: danger-full-access (config)");
  let before = Term.screen t in
  submit_sessions t;
  Term.wait t (Screen.has "No recent sessions in this workspace.");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "message spice");
  let after = Term.screen t in
  print_fact "stage byte-stable across open/esc" (String.equal before after);
  [%expect {| stage byte-stable across open/esc: true |}]

(* Empty state (03-ia §Sessions, empty state): a workspace with no sessions shows
   one muted sentence rather than an empty content region. *)
let%expect_test "empty workspace shows the one-sentence empty state" =
  Project.with_temp "panel-empty" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  submit_sessions t;
  Term.wait t (Screen.has "No recent sessions in this workspace.");
  print_fact "empty sentence shown"
    (Screen.has "No recent sessions in this workspace." (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|empty sentence shown: true
01 |
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
20 |    sessions
21 |
22 |   No recent sessions in this workspace.
23 | 
24 |   ↵ resume · tab browse · type to filter · ↑↓ select · esc close|}]

(* Resume for real (doc/plans/tui-next-surfaces.md §Sequencing 5): [↵] on the
   selection attaches and replays the session, so the chat opens with the
   session's transcript rebuilt — the first user prompt lands as a User block —
   and the panel chrome is gone. Resume needs no provider: the replay is pure and
   the {!Spice_host.Live} attach is deferred to the first continuation. *)
let%expect_test "↵ resumes the selected session into chat" =
  Project.with_temp "panel-resume" @@ fun project ->
  let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
  seed_prompt_session project "ses_resume" ~title:"resume target"
    ~prompt:"hello from the past" ~updated_at_ms:now;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  submit_sessions t;
  (* Wait for the panel to finish loading before resuming: [resume target] also
     shows in the stage's session line above, so gate on the panel's boundary
     with its loading spinner gone. *)
  Term.wait t (fun s ->
      Screen.has "▔▔▔▔" s && Screen.lacks "loading sessions" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "hello from the past");
  print_fact "prompt replayed into the transcript"
    (Screen.has "hello from the past" (Term.screen t));
  print_fact "panel chrome gone" (Screen.lacks "▔▔▔▔" (Term.screen t));
  print_fact "composer back" (Screen.has "message spice" (Term.screen t));
  [%expect
    {|
    prompt replayed into the transcript: true
    panel chrome gone: true
    composer back: true |}]

(* [tab] promotes the quick-switch panel to the browse screen (03-ia §Sessions).
   The screen replaces the panel: its keymap hint ([f fork], [r rename]) — which
   the panel never shows — confirms the screen is up with its rows loaded. *)
let%expect_test "tab promotes the panel to the browse screen" =
  Project.with_temp "panel-promote" @@ fun project ->
  seed_four project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  submit_sessions t;
  Term.wait t (Screen.has "config gadt rework");
  Term.send t Keys.tab;
  Term.wait t (Screen.has "f fork");
  print_fact "screen keymap present"
    (Screen.has "f fork" (Term.screen t)
    && Screen.has "r rename" (Term.screen t));
  print_fact "recency group header present" (Screen.has "today" (Term.screen t));
  [%expect
    {|
    screen keymap present: true
    recency group header present: true |}]

[%%run_tests "spice.tui-next.sessions-panel"]
