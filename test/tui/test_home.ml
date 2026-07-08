(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] home stage (doc/ui-design/
   12-home.md). The home runs no turns, so there is no fake provider: the tests
   drive the real binary and golden the rendered screen.

   Full-screen goldens pin SPICE_REDUCED_MOTION=1 so the lockup settles to its
   static form and the idle grain never keeps repainting the heap region
   (08-brand.md §Motion); the animated path is exercised in [test_home_live].
   They also pin the readable 80x24 the spec mockups use.

   The harness always pins SPICE_SANDBOX_MODE=danger-full-access (Project.env),
   which the runtime reads into the config sandbox mode, so the dangerous-config
   warning line renders on every stage below — the honest screen for this
   environment. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* The home under test is the hidden [tui-next] subcommand. *)
let run ?env ?rows ?cols project f =
  Term.run ?env ?rows ?cols project f

(* First run: no git repo, so no worktree, no CRs, no session. The workspace
   block is the dune line alone (always shown; disconnected here, no watch),
   centered as a one-line block. The stage stands otherwise alone: centered
   lockup, facts, welcome notice, the inset composer, and the one dangerous-config
   warning, above the footer (12-home.md §States, first run). No hint line. *)
let%expect_test "first run — stage alone" =
  Project.with_temp "home-firstrun" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "sandbox: danger-full-access (config)");
  Screen.print ~project (Term.screen t);
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
24 |   ! not logged in · /login · …ce-tui-home-firstrun · gpt-5.5 medium · dune: ✗|}]

(* Workspace block: a committed baseline with an uncommitted edit and a
   [CR spice] in the changed file. The block (centered as a unit under the
   composer, its widest line — the worktree row — centering, lines left-aligned
   within) leads with the dune state (disconnected here — no watch), then the
   worktree and CR rows in their padded label-column form. No session yet, so no
   session line. The CR is in a CHANGED file, which is the only scope the home
   scans (12-home.md §Workspace block, matching /review). *)
let%expect_test "workspace block" =
  Project.with_git_fixture "home-workspace" @@ fun project ->
  Project.write project "lib/code.ml"
    "let alpha = 1\nlet beta = 20\n(* CR spice: check the beta path *)\n";
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (fun s -> Screen.has "worktree" s && Screen.has "CRs" s);
  print_fact "crs row present, addressed count"
    (Screen.has "1 open · 1 addressed to spice" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect {|crs row present, addressed count: true
01 |
02 |
03 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
04 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
05 |
06 |                            dev · openai/gpt-5.5 medium
07 |
08 |      ▎ welcome — and thanks for trying spice this early.
09 |      ▎ it's experimental: sessions and config may change without migration.
10 |
11 |           ────────────────────────────────────────────────────────────
12 |           ❯ message spice
13 |           ────────────────────────────────────────────────────────────
14 |
15 |                    dune       ✗ · diagnostics unavailable
16 |                    account    none — /login to connect
17 |                    worktree   1 file changed · +2 −3 · /review
18 |                    CRs        1 open · 1 addressed to spice
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · …e-tui-home-workspace · gpt-5.5 medium · dune: ✗|}]

(* Session line: a seeded session in the cwd populates the [session] fact with
   its title in quotes and a relative age. The age is wall-clock relative (a
   session seeded at epoch reads decades old and ticks over yearly), so this
   asserts the durable facts rather than goldening it. *)
let%expect_test "session line" =
  Project.with_git_fixture "home-session" @@ fun project ->
  Seed.prompt_session_titled project "ses_1"
    ~title:"Fix the streaming parser bug" ~prompt:"fix the parser";
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (fun s ->
      Screen.has "session" s && Screen.has "Fix the streaming parser bug" s);
  print_fact "session label present" (Screen.has "session" (Term.screen t));
  print_fact "title in quotes"
    (Screen.has "\"Fix the streaming parser bug\"" (Term.screen t));
  [%expect
    {|session label present: true
title in quotes: true|}]

(* Untitled session: the session line must never render the raw session id. An
   untitled session with a first prompt shows that prompt as its title
   (12-home.md §Workspace block); the lead's real-repo run had "ses_…" leak. *)
let%expect_test "untitled session falls back to its prompt" =
  Project.with_git_fixture "home-untitled" @@ fun project ->
  Seed.prompt_session project "ses_9" ~prompt:"reproduce the parser crash";
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (fun s ->
      Screen.has "session" s && Screen.has "reproduce the parser crash" s);
  print_fact "prompt stands in for the title"
    (Screen.has "reproduce the parser crash" (Term.screen t));
  print_fact "raw id never shown" (Screen.lacks "ses_9" (Term.screen t));
  [%expect {|prompt stands in for the title: true
raw id never shown: true|}]

(* Subagent children are excluded: a session with a subagent-run record beside
   it is a child, not top-level work, so the newest-session query never picks it
   (12-home.md §Workspace block) — the same hide-children filter the session
   picker uses. The top-level session is the one that surfaces. *)
let%expect_test "subagent child sessions are excluded" =
  Project.with_git_fixture "home-subagent" @@ fun project ->
  Seed.session ~title:"Main investigation" project "ses_main";
  Seed.session ~title:"subagent explore: survey" project "ses_sub";
  Seed.subagent_run project ~parent:"ses_main" ~child:"ses_sub" ~role:"explore"
    ~task:"survey"
    ~status_json:{|{"type":"completed","completed_at":62000,"summary":"done"}|};
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (fun s ->
      Screen.has "session" s && Screen.has "Main investigation" s);
  print_fact "top-level session present"
    (Screen.has "Main investigation" (Term.screen t));
  print_fact "subagent child excluded"
    (Screen.lacks "subagent explore" (Term.screen t));
  [%expect {|top-level session present: true
subagent child excluded: true|}]

(* [↵] on an empty draft resumes the newest session directly — the recognition
   surface is the workspace block's session line (12-home.md §Keybindings, the
   v2 revision): the home stage swaps for the session's replayed transcript. *)
let%expect_test "enter on an empty draft resumes the newest session" =
  Project.with_git_fixture "home-resume" @@ fun project ->
  Seed.prompt_session_titled project "ses_1" ~title:"Parser refactor spike"
    ~prompt:"spike it";
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "Parser refactor spike");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "❯ spike it");
  print_fact "replayed prompt on screen"
    (Screen.has "❯ spike it" (Term.screen t));
  print_fact "home stage gone"
    (Screen.lacks "welcome — and thanks for trying spice" (Term.screen t));
  [%expect
    {|
    replayed prompt on screen: true
    home stage gone: true|}]

(* Short (<20 rows): the workspace facts shed bottom-up so the stage — lockup,
   composer, footer — survives longest (12-home.md §States). At the 14-row
   harness default the worktree/session rows are gone from the body while the
   dune line, composer, and footer stand. *)
let%expect_test "short terminal sheds workspace facts" =
  Project.with_git_fixture "home-short" @@ fun project ->
  Project.write project "lib/code.ml" "let alpha = 1\nlet beta = 20\n";
  Seed.prompt_session_titled project "ses_1" ~title:"Home screen rethink"
    ~prompt:"rethink";
  run project ~env:reduced_motion ~rows:14 @@ fun t ->
  Term.wait t (Screen.has "message spice");
  print_fact "composer survives" (Screen.has "message spice" (Term.screen t));
  print_fact "footer survives" (Screen.has "dune:" (Term.screen t));
  print_fact "worktree row shed" (Screen.lacks "worktree" (Term.screen t));
  print_fact "session row shed" (Screen.lacks "Home screen rethink" (Term.screen t));
  [%expect
    {|composer survives: true
footer survives: true
worktree row shed: true
session row shed: true|}]

(* Short-terminal survival order (12-home.md §States): the footer is the shell's
   own row and always renders, so [run]'s [dune:] boot wait already proves it
   stands at 12, 10, and 8 rows (a missing footer would time the wait out); the
   composer survives down to 10 rows and folds only under it; the welcome notice
   is the first section to shed, gone below 16 rows. Fact prints, not a golden —
   the exact vertical centering shifts with height. *)
let%expect_test "short terminal keeps the footer and sheds top-down" =
  Project.with_temp "home-survival" @@ fun project ->
  run project ~env:reduced_motion ~rows:12 @@ fun t ->
  print_fact "12 rows: footer stands" (Screen.has "dune:" (Term.screen t));
  print_fact "12 rows: composer stands"
    (Screen.has "message spice" (Term.screen t));
  print_fact "12 rows: notice shed" (Screen.lacks "welcome" (Term.screen t));
  [%expect
    {|12 rows: footer stands: true
12 rows: composer stands: true
12 rows: notice shed: true|}];
  run project ~env:reduced_motion ~rows:10 @@ fun t ->
  print_fact "10 rows: footer stands" (Screen.has "dune:" (Term.screen t));
  print_fact "10 rows: composer stands"
    (Screen.has "message spice" (Term.screen t));
  [%expect
    {|10 rows: footer stands: true
10 rows: composer stands: true|}];
  run project ~env:reduced_motion ~rows:8 @@ fun t ->
  print_fact "8 rows: footer stands" (Screen.has "dune:" (Term.screen t));
  print_fact "8 rows: composer folded"
    (Screen.lacks "message spice" (Term.screen t));
  [%expect
    {|8 rows: footer stands: true
8 rows: composer folded: true|}]

(* Dangerous-config warning: the harness pins SPICE_SANDBOX_MODE=danger-full-
   access as an environment variable (Project.env), and the runtime's
   config_warning reads the config sandbox mode — so the one loud [warning] line
   renders from the env pin alone, no user config file needed. *)
let%expect_test "dangerous config warning" =
  Project.with_temp "home-danger" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "sandbox: danger-full-access (config)");
  print_fact "sandbox warning renders"
    (Screen.has "sandbox: danger-full-access (config)" (Term.screen t));
  [%expect {|sandbox warning renders: true|}]

(* Narrow footer (04-header-footer.md §4): below ~60 columns the [? for
   shortcuts] hint cannot fit beside the cwd, model, and dune verdict, so it
   drops rather than collide with them — with no posture pill in play. The dune
   verdict (the pty boot marker) always survives. *)
(* The logged-out [! not logged in · /login] nudge is a fixed, never-dropped
   reserve (04-header-footer.md §2 account slot), so the band where the row sheds
   the hint yet still holds the dune verdict sits wider than the bare-facts case:
   72 cols drops the hint (needs ≥ 87 to keep) while the verdict still fits. *)
let%expect_test "narrow footer drops the shortcuts hint" =
  Project.with_temp "home-narrow-footer" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:72 @@ fun t ->
  Term.wait t (Screen.has "sandbox: danger-full-access (config)");
  print_fact "dune verdict stays" (Screen.has "dune:" (Term.screen t));
  print_fact "shortcuts hint dropped" (Screen.lacks "shortcuts" (Term.screen t));
  print_fact "hint never jams onto the verdict"
    (Screen.lacks "✗? for" (Term.screen t));
  [%expect
    {|dune verdict stays: true
shortcuts hint dropped: true
hint never jams onto the verdict: true|}]

(* The drop (12-home.md §The drop) now starts a real turn, so its coverage moved
   to [test_transcript.ml] ("the drop and a settled answer"), where the fake
   provider settles the turn deterministically. The home suite keeps its "no fake
   provider" charter — it exercises the stage before the drop only. *)

[%%run_tests "spice.tui-next.home"]
