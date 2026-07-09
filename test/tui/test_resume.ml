(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty test for [spice resume <id>] at launch (bin/cli_tui.ml
   resume_command; App.init ?session). Launching with a session id must open
   straight onto the session's replayed transcript — the same chat an in-app
   resume enters — never the home stage: the replayed durable events fold through
   the turn reducer and rebuild the transcript, which only happens once the shell
   is in its chat phase. No turn runs (replay is pure), so there is no fake
   provider; the test seeds a session document and spawns the [resume]
   subcommand. Enter is a SEPARATE write from any command text (the atomic-enter
   pty artifact); ages are wall-clock, so the test asserts transcript facts, not
   age strings. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* A resumable session carrying one finished turn whose user prompt becomes the
   replayed transcript's User block. Mirrors [test_sessions_screen]'s seed.
   [updated_at] orders sessions for the newest-session launch flags. *)
let seed_prompt_session ?(updated_at = 2) project id ~title ~prompt =
  Project.write project
    (Filename.concat ".spice/sessions" (Filename.concat id "session.json"))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":%d},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"%s"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id title (Project.root project) updated_at prompt)

(* Launching [spice resume <id>] opens on the replayed transcript, not the home
   prelude: the user prompt lands in the chat and the home welcome notice — a
   prelude-only element — is gone. Before the fix the launch path dropped the
   replayed events into a still-[Prelude] model and stranded the user on home. *)
let%expect_test "spice resume <id> opens on the replayed transcript" =
  Project.with_temp "resume-launch" @@ fun project ->
  seed_prompt_session project "ses_resume" ~title:"streaming parser fix"
    ~prompt:"trace the streaming parser bug";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "ses_resume" ]
  @@ fun t ->
  Term.wait t (Screen.has "trace the streaming parser bug");
  let s = Term.screen t in
  print_fact "replayed user prompt on screen"
    (Screen.has "trace the streaming parser bug" s);
  print_fact "not on the home prelude"
    (Screen.lacks "welcome — and thanks for trying spice" s);
  print_fact "composer present" (Screen.has "message spice" s);
  [%expect
    {|
    replayed user prompt on screen: true
    not on the home prelude: true
    composer present: true |}]

(* Resume A at launch, then resume B from the in-app [/sessions] panel: the
   transcript must show only B's replayed prompt. Entering B swaps to a fresh
   banner-headed transcript and replays B alone (runtime.ml [enter_session]
   detaches A; the resume supersession guard keeps a stale A replay from merging
   in). This drives the flow SEQUENTIALLY — each resume settles before the next —
   so it is deterministic; the racing supersession (a second pick landing while
   the first still loads) needs a slow first load the harness cannot force, so it
   is not asserted here. Enter is always a SEPARATE write from the command text
   (the atomic-enter pty artifact). FLAGGED for the build-fixer: assert-only;
   re-fill [%expect] from the run if the predicted facts drift. *)
let%expect_test "resume then resume shows only the second session" =
  Project.with_temp "resume-then-resume" @@ fun project ->
  seed_prompt_session project "ses_a" ~title:"streaming parser fix"
    ~prompt:"trace the streaming parser bug";
  seed_prompt_session project "ses_b" ~title:"config gadt rework"
    ~prompt:"rework the config gadt layer";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "ses_a" ]
  @@ fun t ->
  Term.wait t (Screen.has "trace the streaming parser bug");
  (* Open the quick-switch panel and filter down to B, then resume it. *)
  Term.send t "/sessions";
  Term.wait t (Screen.has "/sessions");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "config gadt rework");
  Term.send t "gadt";
  Term.wait t (fun s ->
      Screen.has "config gadt rework" s && Screen.lacks "streaming parser fix" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "rework the config gadt layer");
  let s = Term.screen t in
  print_fact "second session's prompt on screen"
    (Screen.has "rework the config gadt layer" s);
  print_fact "first session's prompt gone"
    (Screen.lacks "trace the streaming parser bug" s);
  [%expect
    {|
    second session's prompt on screen: true
    first session's prompt gone: true |}]

(* The launch flags resolve their session target before the TUI starts
   (bin/cli_tui.ml [run]): [-c]/[--continue] and [resume --last] pick the
   newest session in the workspace by [updated_at], [--session] loads the named
   one. Each must open on the replayed transcript, never the home stage. *)
let%expect_test "spice -c resumes the newest session" =
  Project.with_temp "resume-continue" @@ fun project ->
  seed_prompt_session project "ses_older" ~title:"older session"
    ~prompt:"the older prompt";
  seed_prompt_session project "ses_newer" ~updated_at:9 ~title:"newer session"
    ~prompt:"the newer prompt";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80 ~command:[ "-c" ]
  @@ fun t ->
  Term.wait t (Screen.has "the newer prompt");
  let s = Term.screen t in
  print_fact "newest session replayed" (Screen.has "the newer prompt" s);
  print_fact "older session not replayed" (Screen.lacks "the older prompt" s);
  [%expect
    {|
    newest session replayed: true
    older session not replayed: true |}]

let%expect_test "spice --session opens the named session" =
  Project.with_temp "resume-session-flag" @@ fun project ->
  seed_prompt_session project "ses_older" ~title:"older session"
    ~prompt:"the older prompt";
  seed_prompt_session project "ses_newer" ~updated_at:9 ~title:"newer session"
    ~prompt:"the newer prompt";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "--session"; "ses_older" ]
  @@ fun t ->
  Term.wait t (Screen.has "the older prompt");
  let s = Term.screen t in
  print_fact "named session replayed" (Screen.has "the older prompt" s);
  print_fact "newest session not replayed" (Screen.lacks "the newer prompt" s);
  [%expect
    {|
    named session replayed: true
    newest session not replayed: true |}]

let%expect_test "spice resume --last resumes the newest session" =
  Project.with_temp "resume-last" @@ fun project ->
  seed_prompt_session project "ses_older" ~title:"older session"
    ~prompt:"the older prompt";
  seed_prompt_session project "ses_newer" ~updated_at:9 ~title:"newer session"
    ~prompt:"the newer prompt";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "--last" ]
  @@ fun t ->
  Term.wait t (Screen.has "the newer prompt");
  let s = Term.screen t in
  print_fact "newest session replayed" (Screen.has "the newer prompt" s);
  print_fact "not on the home prelude"
    (Screen.lacks "welcome — and thanks for trying spice" s);
  [%expect
    {|
    newest session replayed: true
    not on the home prelude: true |}]

(* /fork forks the attached session into a child and continues there
   (10-commands.md §/fork): the fresh transcript carries the ❯ /fork echo and
   the lineage record naming the parent's title, and the inherited history
   replays below both. On the home stage nothing is attached, so the command
   flashes the guard instead. *)
let%expect_test "fork continues in a child with the lineage record" =
  Project.with_temp "fork-command" @@ fun project ->
  seed_prompt_session project "ses_parent" ~title:"streaming parser fix"
    ~prompt:"trace the streaming parser bug";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "ses_parent" ]
  @@ fun t ->
  Term.wait t (Screen.has "trace the streaming parser bug");
  Term.send t "/fork";
  Term.wait t (fun s -> Screen.has "/fork" s && Screen.lacks "/thinking" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "forked to a new session");
  let s = Term.screen t in
  print_fact "fork echo recorded" (Screen.has "❯ /fork" s);
  print_fact "lineage names the parent title"
    (Screen.has {|↳ from "streaming parser fix"|} s);
  Term.wait t (Screen.has "trace the streaming parser bug");
  print_fact "inherited history replayed"
    (Screen.has "trace the streaming parser bug" (Term.screen t));
  [%expect
    {|
    fork echo recorded: true
    lineage names the parent title: true
    inherited history replayed: true |}]

let%expect_test "fork on the home stage flashes the no-session guard" =
  Project.with_temp "fork-no-session" @@ fun project ->
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/fork";
  Term.wait t (fun s -> Screen.has "/fork" s && Screen.lacks "/thinking" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "fork: no active session");
  print_fact "guard flashed"
    (Screen.has "fork: no active session" (Term.screen t));
  [%expect {| guard flashed: true |}]

(* /clear starts over on a fresh, empty chat (10-commands.md §/clear): the
   re-bannered transcript carries the echo and the settle copy, the previous
   conversation is gone from screen but its session stays on disk (the
   quick-switch panel still lists it), and the next submit attaches a NEW
   session — the re-armed fresh path — whose turn runs normally. *)
let%expect_test "clear starts a fresh session and preserves the previous" =
  Project.with_temp "clear-command" @@ fun project ->
  seed_prompt_session project "ses_clear" ~title:"streaming parser fix"
    ~prompt:"trace the streaming parser bug";
  let answer = "The tokenizer drops the final chunk." in
  Provider.with_openai project ~answer ~body_contains:[ "off-by-one" ]
  @@ fun provider ->
  Term.run project ~provider ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "ses_clear" ]
  @@ fun t ->
  Term.wait t (Screen.has "trace the streaming parser bug");
  Term.send t "/clear";
  Term.wait t (fun s -> Screen.has "/clear" s && Screen.lacks "/fork" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "cleared the conversation");
  let s = Term.screen t in
  print_fact "clear echo recorded" (Screen.has "❯ /clear" s);
  print_fact "settle copy names the resume path"
    (Screen.has "previous saved, /sessions to resume" s);
  print_fact "previous conversation gone"
    (Screen.lacks "trace the streaming parser bug" s);
  print_fact "chat layout, not the home stage"
    (Screen.lacks "welcome — and thanks for trying spice" s);
  Term.send t "where is the off-by-one";
  Term.wait t (Screen.has "❯ where is the off-by-one");
  Term.send t Keys.enter;
  Term.wait t (Screen.has answer);
  print_fact "a fresh session attaches and runs a turn"
    (Screen.has answer (Term.screen t));
  Term.send t "/sessions";
  Term.wait t (Screen.has "Show recent sessions");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "streaming parser fix");
  print_fact "previous session still on disk"
    (Screen.has "streaming parser fix" (Term.screen t));
  [%expect
    {|
    clear echo recorded: true
    settle copy names the resume path: true
    previous conversation gone: true
    chat layout, not the home stage: true
    a fresh session attaches and runs a turn: true
    previous session still on disk: true |}]

(* /compact runs the standalone host compaction over the attached document:
   the echo lands, then the settle record. The seeded transcript is far below
   the model policy's retained tail, so the deterministic pty-reachable
   outcome is the honest refusal — which drives the full dispatch → runtime →
   Live.write → Session.compact → delivery loop; an installed compaction's
   [compacted] seam rides the same live-event path the reducer already
   renders. The document's history stays on screen either way — compaction
   changes what the model sees next turn, not what happened. *)
let%expect_test "compact records the host's verdict and keeps the history" =
  Project.with_temp "compact-command" @@ fun project ->
  seed_prompt_session project "ses_compact" ~title:"streaming parser fix"
    ~prompt:"trace the streaming parser bug";
  (* The provider credential is needed for the summary-client binding; the
     policy refuses before any request is made. *)
  Provider.with_openai project ~answer:"unused" ~body_contains:[]
  @@ fun provider ->
  Term.run project ~provider ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "ses_compact" ]
  @@ fun t ->
  Term.wait t (Screen.has "trace the streaming parser bug");
  Term.send t "/compact";
  Term.wait t (fun s -> Screen.has "/compact" s && Screen.lacks "/clear" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "conversation already fits");
  let s = Term.screen t in
  print_fact "compact echo recorded" (Screen.has "❯ /compact" s);
  print_fact "the host's verdict recorded"
    (Screen.has "compaction failed: conversation already fits" s);
  print_fact "history stays on screen"
    (Screen.has "trace the streaming parser bug" s);
  [%expect
    {|
    compact echo recorded: true
    the host's verdict recorded: true
    history stays on screen: true |}]

let%expect_test "compact on the home stage flashes the no-session guard" =
  Project.with_temp "compact-no-session" @@ fun project ->
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/compact";
  Term.wait t (fun s -> Screen.has "/compact" s && Screen.lacks "/clear" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "no session to compact");
  print_fact "guard flashed"
    (Screen.has "no session to compact" (Term.screen t));
  [%expect {| guard flashed: true |}]

(* /rename: bare (pasted, so the palette never intercepts) it seeds the draft
   with [/rename ] — the palette's argument-insert idiom — so typing just the
   title and submitting fires the rename; the echo carrying the full
   [/rename <title>] line proves the seed happened. The write persists: the
   sessions browse screen (which replaces the chat view, so the title string
   can only come from a row) shows the new title. *)
let%expect_test "rename seeds bare, renames with a title, and persists" =
  Project.with_temp "rename-command" @@ fun project ->
  seed_prompt_session project "ses_rename" ~title:"streaming parser fix"
    ~prompt:"trace the streaming parser bug";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "ses_rename" ]
  @@ fun t ->
  Term.wait t (Screen.has "trace the streaming parser bug");
  (* Uppercase, so the canonical lowercase seed is a VISIBLE change to wait on
     before typing — the controlled composer widget syncs the seeded value a
     frame later, and typing into the stale widget would clobber the seed. *)
  Term.send t (Keys.bracketed_paste "/RENAME");
  Term.wait t (Screen.has "❯ /RENAME");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "❯ /rename");
  Term.send t "the tokenizer rewrite";
  Term.send t Keys.enter;
  Term.wait t (Screen.has {|renamed to "the tokenizer rewrite"|});
  print_fact "echo proves the seeded prefix"
    (Screen.has "❯ /rename the tokenizer rewrite" (Term.screen t));
  Term.send t "/sessions";
  Term.wait t (Screen.has "Show recent sessions");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "▔▔▔▔" s && Screen.lacks "loading sessions" s);
  Term.send t Keys.tab;
  Term.wait t (Screen.has "f fork");
  let s = Term.screen t in
  print_fact "chat view replaced by the browse screen"
    (Screen.lacks "renamed to" s);
  print_fact "new title persisted to the store"
    (Screen.has "the tokenizer rewrite" s);
  [%expect
    {|
    echo proves the seeded prefix: true
    chat view replaced by the browse screen: true
    new title persisted to the store: true |}]

(* Typed on the home stage, the palette's ↵ inserts [/rename ]; submitting a
   title with nothing attached flashes the guard. *)
let%expect_test "rename on the home stage flashes the no-session guard" =
  Project.with_temp "rename-no-session" @@ fun project ->
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/rename";
  Term.wait t (fun s -> Screen.has "/rename" s && Screen.lacks "/fork" s);
  Term.send t Keys.enter;
  (* The insert closes the palette; wait for its row to vanish so the seeded
     widget value has synced before the title keystrokes land. *)
  Term.wait t (Screen.lacks "Rename the active session");
  Term.send t "nope";
  Term.send t Keys.enter;
  Term.wait t (Screen.has "no session to rename");
  print_fact "guard flashed" (Screen.has "no session to rename" (Term.screen t));
  [%expect {| guard flashed: true |}]

(* [--draft] seeds the composer without starting anything: the process stays on
   the home stage with the text ready to edit (App.init [Draft]). *)
let%expect_test "spice --draft seeds the composer on the home stage" =
  Project.with_temp "launch-draft" @@ fun project ->
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "--draft"; "fix the parser first" ]
  @@ fun t ->
  Term.wait t (Screen.has "fix the parser first");
  let s = Term.screen t in
  print_fact "draft in the composer" (Screen.has "❯ fix the parser first" s);
  print_fact "still on the home prelude"
    (Screen.has "welcome — and thanks for trying spice" s);
  [%expect
    {|
    draft in the composer: true
    still on the home prelude: true |}]

(* [-p]/[--prompt] submits the text as the first turn: the TUI opens on the
   chat layout with the prompt echoed and the reply streaming — the home stage
   never shows (App.init [Submit] takes the drop before the first frame). *)
let%expect_test "spice -p submits the first prompt at launch" =
  Project.with_temp "launch-prompt" @@ fun project ->
  let answer = "The parser drops the final chunk." in
  Provider.with_openai project ~answer ~body_contains:[ "fix the parser" ]
  @@ fun provider ->
  Term.run project ~provider ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "-p"; "fix the parser" ]
  @@ fun t ->
  Term.wait t (Screen.has answer);
  let s = Term.screen t in
  print_fact "prompt echoed" (Screen.has "❯ fix the parser" s);
  print_fact "reply streamed" (Screen.has answer s);
  print_fact "not on the home prelude"
    (Screen.lacks "welcome — and thanks for trying spice" s);
  [%expect
    {|
    prompt echoed: true
    reply streamed: true
    not on the home prelude: true |}]

(* Resume the seeded session, then submit a turn: the reply must land in the
   SAME transcript, below the replayed prompt. This exercises the consumer path
   end-to-end (runtime.ml [ensure_attachment] -> [consume_resume] -> [build_run]
   + [Live.attach] + [Live.submit]) that the pure-replay tests above never reach
   — they submit no turn, so they drive only the producer's [enter_session]
   replay. A real turn runs, so this drives the fake provider; Enter is a
   SEPARATE write from the prompt (the atomic-enter pty artifact). FLAGGED for
   the build-fixer: assert-only; re-fill [%expect] from the run if the predicted
   facts drift. *)
let%expect_test "resume then submit lands the reply in the resumed transcript" =
  Project.with_temp "resume-then-submit" @@ fun project ->
  seed_prompt_session project "ses_resume" ~title:"streaming parser fix"
    ~prompt:"trace the streaming parser bug";
  let answer = "The streaming parser drops the final chunk." in
  Provider.with_openai project ~answer ~body_contains:[ "off-by-one" ]
  @@ fun provider ->
  Term.run project ~provider ~env:reduced_motion ~rows:24 ~cols:80
    ~command:[ "resume"; "ses_resume" ]
  @@ fun t ->
  Term.wait t (Screen.has "trace the streaming parser bug");
  Term.send t "where is the off-by-one";
  Term.wait t (Screen.has "❯ where is the off-by-one");
  Term.send t Keys.enter;
  Term.wait t (Screen.has answer);
  let s = Term.screen t in
  print_fact "resumed prompt still on screen"
    (Screen.has "trace the streaming parser bug" s);
  print_fact "new prompt on screen" (Screen.has "where is the off-by-one" s);
  print_fact "reply on screen" (Screen.has answer s);
  [%expect
    {|
    resumed prompt still on screen: true
    new prompt on screen: true
    reply on screen: true |}]

[%%run_tests "spice.tui-next.resume"]
