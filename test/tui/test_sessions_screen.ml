(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] sessions browse screen
   (doc/ui-design/03-ia-screens-overlays.md §Sessions; the screen form of
   doc/plans/tui-next-surfaces.md phase 2). No turns run — resume replay is pure
   and rename/delete are host store writes — so there is no fake provider: the
   tests seed session documents, promote the quick-switch panel to the screen
   with [tab], and assert the rendered facts.

   The screen has no direct trigger yet; it is reached by opening [/sessions] and
   pressing [tab] (03-ia §Sessions). Enter is always a SEPARATE write from the
   command text (the atomic-enter pty artifact). Sessions are seeded with recent
   update times so recency buckets are deterministic; ages are wall-clock, so the
   tests assert facts and patterns, never exact age strings (goldens would
   drift). *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact
let run ?env ?rows ?cols project f = Term.run ?env ?rows ?cols project f

(* A resumable session carrying one finished turn, with an explicit update time
   so its recency bucket is deterministic and its first prompt becomes the row's
   preview echo. Mirrors [Seed.prompt_session_titled] with a settable
   [updated_at]. *)
let seed_prompt_session project id ~title ~prompt ~updated_at_ms =
  Project.write project
    (Filename.concat ".spice/sessions" (Filename.concat id "session.json"))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":%Ld},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"%s"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id title (Project.root project) updated_at_ms prompt)

let now_ms () = Int64.of_float (Unix.gettimeofday () *. 1000.)
let days_ago n = Int64.sub (now_ms ()) (Int64.of_int (n * 86400 * 1000))

(* Open the quick-switch panel, wait for its rows, then promote to the browse
   screen with [tab] and wait for the screen's keymap hint (which only the loaded
   screen shows). *)
let open_screen t =
  Term.send t "/sessions";
  Term.wait t (Screen.has "/sessions");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "▔▔▔▔" s && Screen.lacks "loading sessions" s);
  Term.send t Keys.tab;
  Term.wait t (Screen.has "f fork")

(* Recency groups render as muted headers, and only the selected (newest) row
   expands to its first-prompt echo. *)
let%expect_test "browse screen groups by recency and expands the selection" =
  Project.with_temp "screen-groups" @@ fun project ->
  seed_prompt_session project "ses_today" ~title:"parser streaming fix"
    ~prompt:"trace the streaming parser bug" ~updated_at_ms:(now_ms ());
  seed_prompt_session project "ses_week" ~title:"config gadt rework"
    ~prompt:"rework the config field gadt" ~updated_at_ms:(days_ago 3);
  seed_prompt_session project "ses_old" ~title:"review layer wiring"
    ~prompt:"wire the review screen seams" ~updated_at_ms:(days_ago 25);
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_screen t;
  Term.wait t (Screen.has "parser streaming fix");
  let s = Term.screen t in
  print_fact "today group header" (Screen.has "today" s);
  print_fact "this week group header" (Screen.has "this week" s);
  print_fact "older group header" (Screen.has "older" s);
  print_fact "all three titles present"
    (Screen.has "parser streaming fix" s
    && Screen.has "config gadt rework" s
    && Screen.has "review layer wiring" s);
  print_fact "session count fact" (Screen.has "3 sessions" s);
  print_fact "selected row expands to its first-prompt echo"
    (Screen.has "trace the streaming parser bug" s);
  print_fact "unselected rows do not expand"
    (Screen.lacks "rework the config field gadt" s
    && Screen.lacks "wire the review screen seams" s);
  [%expect
    {|
    today group header: true
    this week group header: true
    older group header: true
    all three titles present: true
    session count fact: true
    selected row expands to its first-prompt echo: true
    unselected rows do not expand: true |}]

(* Moving the selection expands a different row's echo and collapses the first. *)
let%expect_test "moving the selection moves the expansion" =
  Project.with_temp "screen-move" @@ fun project ->
  seed_prompt_session project "ses_a" ~title:"alpha work"
    ~prompt:"the alpha first prompt" ~updated_at_ms:(now_ms ());
  seed_prompt_session project "ses_b" ~title:"beta work"
    ~prompt:"the beta first prompt" ~updated_at_ms:(days_ago 1);
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_screen t;
  Term.wait t (Screen.has "the alpha first prompt");
  Term.send t Keys.down;
  Term.wait t (Screen.has "the beta first prompt");
  let s = Term.screen t in
  print_fact "second row now expanded" (Screen.has "the beta first prompt" s);
  print_fact "first row collapsed" (Screen.lacks "the alpha first prompt" s);
  [%expect
    {|
    second row now expanded: true
    first row collapsed: true |}]

(* The [/] filter opens the bare filter line; every printable narrows and the
   match count updates (03-ia §The filter law). *)
let%expect_test "the / filter narrows the rows with a match count" =
  Project.with_temp "screen-filter" @@ fun project ->
  seed_prompt_session project "ses_1" ~title:"parser streaming fix"
    ~prompt:"one" ~updated_at_ms:(now_ms ());
  seed_prompt_session project "ses_2" ~title:"config gadt rework" ~prompt:"two"
    ~updated_at_ms:(days_ago 1);
  seed_prompt_session project "ses_3" ~title:"review layer wiring"
    ~prompt:"three" ~updated_at_ms:(days_ago 2);
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_screen t;
  Term.send t "/";
  Term.send t "gadt";
  Term.wait t (fun s ->
      Screen.has "config gadt rework" s && Screen.lacks "parser streaming fix" s);
  let s = Term.screen t in
  print_fact "matching row kept" (Screen.has "config gadt rework" s);
  print_fact "non-matching rows dropped"
    (Screen.lacks "parser streaming fix" s
    && Screen.lacks "review layer wiring" s);
  print_fact "match count shown" (Screen.has "1 match" s);
  [%expect
    {|
    matching row kept: true
    non-matching rows dropped: true
    match count shown: true |}]

(* [r] turns the title into an inline input in place; typing edits it and [↵]
   saves through the host lifecycle verb, so the reloaded row shows the new
   title. *)
let%expect_test "r renames the selected session in place" =
  Project.with_temp "screen-rename" @@ fun project ->
  seed_prompt_session project "ses_r" ~title:"old title" ~prompt:"p"
    ~updated_at_ms:(now_ms ());
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_screen t;
  Term.wait t (Screen.has "old title");
  Term.send t "r";
  Term.send t " renamed";
  Term.send t Keys.enter;
  Term.wait t (Screen.has "old title renamed");
  print_fact "new title persisted and shown"
    (Screen.has "old title renamed" (Term.screen t));
  [%expect {| new title persisted and shown: true |}]

(* [d] converts the row to its own confirmation; a second [d] commits the delete
   through the host verb, and the reloaded screen drops the row. *)
let%expect_test "d deletes the selected session on a second press" =
  Project.with_temp "screen-delete" @@ fun project ->
  seed_prompt_session project "ses_keep" ~title:"keep me" ~prompt:"k"
    ~updated_at_ms:(now_ms ());
  seed_prompt_session project "ses_drop" ~title:"drop me" ~prompt:"d"
    ~updated_at_ms:(days_ago 1);
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_screen t;
  Term.wait t (Screen.has "keep me");
  (* Select the second row, then delete it with a double press. *)
  Term.send t Keys.down;
  Term.send t "d";
  Term.wait t (Screen.has "press d again");
  print_fact "confirmation replaces the row"
    (Screen.has "press d again" (Term.screen t));
  Term.send t "d";
  Term.wait t (Screen.lacks "drop me");
  print_fact "deleted row gone" (Screen.lacks "drop me" (Term.screen t));
  print_fact "sibling kept" (Screen.has "keep me" (Term.screen t));
  [%expect
    {|
    confirmation replaces the row: true
    deleted row gone: true
    sibling kept: true |}]

(* A single [d] then any other key abandons the confirmation and restores the
   row (03-ia §Sessions). *)
let%expect_test "a non-d key cancels the delete confirmation" =
  Project.with_temp "screen-delete-cancel" @@ fun project ->
  seed_prompt_session project "ses_x" ~title:"stays put" ~prompt:"p"
    ~updated_at_ms:(now_ms ());
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_screen t;
  Term.wait t (Screen.has "stays put");
  Term.send t "d";
  Term.wait t (Screen.has "press d again");
  Term.send t Keys.escape;
  Term.wait t (Screen.lacks "press d again");
  print_fact "row restored" (Screen.has "stays put" (Term.screen t));
  print_fact "still on the screen" (Screen.has "f fork" (Term.screen t));
  [%expect {|
    row restored: true
    still on the screen: true |}]

(* The esc ladder: esc clears an open filter first, then a second esc leaves the
   screen and returns to the composer (03-ia §The filter law). *)
let%expect_test "esc clears the filter then exits the screen" =
  Project.with_temp "screen-esc" @@ fun project ->
  seed_prompt_session project "ses_1" ~title:"first" ~prompt:"p"
    ~updated_at_ms:(now_ms ());
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_screen t;
  Term.send t "/";
  Term.send t "zzz";
  Term.wait t (Screen.has "no matches");
  Term.send t Keys.escape;
  (* Filter cleared, screen still up: the row is back and the keymap hint shows. *)
  Term.wait t (fun s -> Screen.has "first" s && Screen.lacks "no matches" s);
  print_fact "filter cleared, screen kept"
    (Screen.has "f fork" (Term.screen t) && Screen.has "first" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (Screen.has "message spice");
  print_fact "second esc returns to the composer"
    (Screen.has "message spice" (Term.screen t)
    && Screen.lacks "f fork" (Term.screen t));
  [%expect
    {|
    filter cleared, screen kept: true
    second esc returns to the composer: true |}]

(* Empty state: a workspace with no sessions shows one muted sentence. *)
let%expect_test "empty workspace shows the one-sentence empty state" =
  Project.with_temp "screen-empty" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/sessions";
  Term.wait t (Screen.has "/sessions");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "No recent sessions in this workspace.");
  Term.send t Keys.tab;
  Term.wait t (Screen.has "No sessions in this workspace.");
  print_fact "empty sentence shown"
    (Screen.has "No sessions in this workspace." (Term.screen t));
  [%expect {| empty sentence shown: true |}]

(* The panel's [tab] carries its filter over to the screen (03-ia §Sessions). *)
let%expect_test "tab carries the panel filter to the screen" =
  Project.with_temp "screen-carryover" @@ fun project ->
  (* The filtered-out title must belong to the OLDER session: the stage's
     [session "<newest>"] line stays on screen above the panel, so a
     [Screen.lacks] wait on the newest title can never succeed. *)
  seed_prompt_session project "ses_1" ~title:"parser streaming fix"
    ~prompt:"one" ~updated_at_ms:(days_ago 1);
  seed_prompt_session project "ses_2" ~title:"config gadt rework" ~prompt:"two"
    ~updated_at_ms:(now_ms ());
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/sessions";
  Term.wait t (Screen.has "/sessions");
  Term.send t Keys.enter;
  (* Wait on the OLDER title: it lives only in the panel rows (the stage's
     session line above shows the newest, "config gadt rework"), so its
     presence proves the panel is open AND loaded — a newest-title wait
     passes before the panel exists and the filter keys type into the
     transition. *)
  Term.wait t (Screen.has "parser streaming fix");
  Term.send t "gadt";
  Term.wait t (fun s ->
      Screen.has "config gadt rework" s && Screen.lacks "parser streaming fix" s);
  Term.send t Keys.tab;
  (* The carried filter arrives OPEN on the screen — still editable — so the
     hint is the open-filter set, not the browsing one ([f fork] renders only
     once the filter closes). [esc clear filter] is unique to this state. *)
  Term.wait t (Screen.has "esc clear filter");
  let s = Term.screen t in
  print_fact "filter carried to the screen" (Screen.has "gadt" s);
  print_fact "screen already narrowed"
    (Screen.has "config gadt rework" s && Screen.lacks "parser streaming fix" s);
  [%expect
    {|
    filter carried to the screen: true
    screen already narrowed: true |}]

[%%run_tests "spice.tui-next.sessions-screen"]
