(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* Home stage under the deterministic harness: full-frame goldens at a pinned
   size, no sleeps, no substring waits. Time is frozen at the harness epoch,
   so the animation sits at its first frame and ages are stable. *)

let%expect_test "home boots to a stable frame" =
  Tui.run ~name:"home-boot" @@ fun t ->
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

let%expect_test "typing lands in the composer" =
  Tui.run ~name:"home-typing" @@ fun t ->
  Tui.settle t;
  Tui.keys t "hello spice";
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
13 |           ❯ hello spice
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

let seed_recent_session project id ?title ~prompt ~updated_at () =
  let title =
    match title with None -> "" | Some value -> Printf.sprintf {|"title":%S,|} value
  in
  Util.write_file
    (Project.data project
       (Filename.concat "sessions" (Filename.concat id "session.json")))
    (Printf.sprintf
       {|{"version":1,"id":%S,"metadata":{%s"status":"active","cwd":%S,"created_at":1,"updated_at":%d},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":%S}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id title (Project.root project) updated_at prompt)

(* The home brief owns the live workspace facts. A real Git fixture with an
   uncommitted CR-bearing edit renders worktree and addressed-CR rows together. *)
let%expect_test "the home stage renders worktree and CR facts" =
  Tui.run ~name:"home-workspace"
    ~seed:(fun project ->
      Project.write project "lib/code.ml" "let beta = 2\n";
      Project.git_baseline project;
      Project.write project "lib/code.ml"
        "let beta = 20\n(* CR spice: check the beta path *)\n")
  @@ fun t ->
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
17 |                    worktree   1 file changed · +2 −1 · /review
18 |                    CRs        1 open · 1 addressed to spice
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* A recent top-level session is named by its title; an untitled session falls
   back to its first prompt rather than leaking its opaque id. *)
let%expect_test "recent session titles and prompt fallbacks render honestly" =
  Tui.run ~name:"home-session-fallback"
    ~seed:(fun project ->
      seed_recent_session project "ses_titled" ~title:"Parser refactor spike"
        ~prompt:"spike it" ~updated_at:999_999 ();
      seed_recent_session project "ses_untitled"
        ~prompt:"reproduce the parser crash" ~updated_at:1_000_000 ())
  @@ fun t ->
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
16 |                dune       ✗ · diagnostics unavailable
17 |                account    none — /login to connect
18 |                session    "reproduce the parser crash" · just now
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* Persisted subagent children never become the home stage's resumable recent
   session; the top-level parent remains the visible candidate. *)
let%expect_test "subagent child sessions are excluded from the home recent" =
  Tui.run ~name:"home-session-child"
    ~seed:(fun project ->
      seed_recent_session project "ses_main" ~title:"Main investigation"
        ~prompt:"investigate" ~updated_at:999_999 ();
      seed_recent_session project "ses_sub" ~title:"subagent explore: survey"
        ~prompt:"survey" ~updated_at:1_000_000 ();
      Seed.subagent_run project ~parent:"ses_main" ~child:"ses_sub"
        ~role:"explore" ~task:"survey"
        ~status_json:
          {|{"type":"completed","completed_at":1000,"summary":"done"}|})
  @@ fun t ->
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
16 |                    dune       ✗ · diagnostics unavailable
17 |                    account    none — /login to connect
18 |                    session    "Main investigation" · just now
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* Enter on an empty home draft resumes the recent session through the same
   host load and replay path as the sessions panel. *)
let%expect_test "enter on an empty home draft resumes the newest session" =
  Tui.run ~name:"home-session-enter"
    ~seed:(fun project ->
      seed_recent_session project "ses_recent" ~title:"Parser refactor spike"
        ~prompt:"spike it" ~updated_at:1_000_000 ())
  @@ fun t ->
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ spike it
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* The two-second brief tick re-reads Git state while the home remains idle. *)
let%expect_test "the home worktree count refreshes after an edit" =
  Tui.run ~name:"home-worktree-live"
    ~seed:(fun project ->
      Project.write project "lib/code.ml" "let beta = 2\n";
      Project.write project "notes.txt" "baseline\n";
      Project.git_baseline project;
      Project.write project "lib/code.ml" "let beta = 20\n")
  @@ fun t ->
  Tui.settle t;
  Project.write (Tui.project t) "notes.txt" "changed\n";
  Tui.advance t 2.0;
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
16 |                   dune       ✗ · diagnostics unavailable
17 |                   account    none — /login to connect
18 |                   worktree   2 files changed · +2 −2 · /review
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

let rec advance_until t ~marker remaining =
  if Util.contains (Tui.screen t) marker then ()
  else if remaining = 0 then failwith "home animation marker was never rendered"
  else (
    Tui.advance t 0.1;
    advance_until t ~marker (remaining - 1))

let pouring_row = "▄██ █▀  █ ▀▄▄ █▄▄  ▂▄▂"
let resting_row = "▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂"

(* Motion is deterministic under the virtual clock: it reaches a pour frame,
   returns to rest, loops into the same pour frame, and the first printable key
   freezes the lockup permanently. *)
let%expect_test "the home animation advances and freezes on a keystroke" =
  Tui.run ~name:"home-motion" ~env:[ ("SPICE_REDUCED_MOTION", "0") ]
  @@ fun t ->
  Tui.settle t;
  advance_until t ~marker:pouring_row 30;
  Tui.print t;
  [%expect {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄  ▂▄▂
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}];
  advance_until t ~marker:resting_row 30;
  advance_until t ~marker:pouring_row 30;
  Tui.print t;
  [%expect {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄  ▂▄▂
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}];
  Tui.keys t "x";
  Tui.settle t;
  Tui.advance t 1.0;
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
13 |           ❯ x
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* Reduced motion never enters the pour even when virtual time advances. *)
let%expect_test "reduced motion keeps the home lockup static" =
  Tui.run ~name:"home-reduced-motion" @@ fun t ->
  Tui.settle t;
  Tui.advance t 1.0;
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
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]
