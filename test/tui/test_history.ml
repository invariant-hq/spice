(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for prompt history (lib/tui-next/history.ml, wired through
   the runtime): the global JSONL loads at boot, arrow-walk recalls it, and
   ctrl+r reverse search fuzzy-matches and inserts (never submits). No turns
   run, so like the composer tests these need only the real spice binary.

   Isolation (verified before writing): the harness (Project.env) overrides HOME
   and XDG_CONFIG_HOME into <root>.xdg/{home,config}, outside the project root,
   and with_temp deletes them on exit. lib/host/config_home.ml resolves the
   config dir from an absolute XDG_CONFIG_HOME first (non-Windows), so the auth
   store — and history.jsonl beside it — land at
   <root>.xdg/config/spice/history.jsonl. No test can touch a real user path.

   History is seeded by writing that JSONL directly {e before} launch rather than
   by discarding drafts in-session: a ctrl+c/esc discard does NOT currently reach
   the disk append (app.ml drops the composer's Draft_saved event on those
   paths), so the write path is untestable end-to-end here — see the report. The
   load path this exercises is fully wired, and a hand-written line proves the
   loader accepts the shared byte-compatible shape. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

let run ?env ?rows ?cols project f =
  Term.run ?env ?rows ?cols project f

(* The deterministic history path under the harness's isolated config home. *)
let history_path project =
  List.fold_left Filename.concat
    (Project.root project ^ ".xdg")
    [ "config"; "spice"; "history.jsonl" ]

(* One [composer.history_entry] line in the shared schema the runtime loads. The
   session id is any non-empty string; the loader ranks it as an earlier session
   (the boot session is a fresh id), which does not affect visibility. *)
let entry_line ~ts text =
  Printf.sprintf
    {|{"schema_version":1,"type":"composer.history_entry","session_id":"ses_test","ts":%d,"draft":{"text":%S}}|}
    ts text

(* Seed history on disk before launch (oldest first, as the file is appended);
   the runtime loads it at boot and feeds both the arrow-walk and ctrl+r. *)
let seed_history project lines =
  Util.write_file (history_path project) (String.concat "\n" lines ^ "\n")

(* A prompt on disk is loaded at boot and recalled by Up on the empty draft — the
   load path history.ml owns, end to end through the runtime. *)
let%expect_test "loaded history is recalled with Up" =
  Project.with_temp "next-history-load" @@ fun project ->
  seed_history project [ entry_line ~ts:1000 "alpha prompt" ];
  run project ~env:reduced_motion ~rows:24 ~cols:80 (fun t ->
      Term.wait t (Screen.has "dune:");
      Term.send t Keys.up;
      Term.wait t (Screen.has "alpha prompt");
      print_fact "up recalls the prompt loaded from disk"
        (Screen.has "alpha prompt" (Term.screen t)));
  [%expect {| up recalls the prompt loaded from disk: true |}]

(* ctrl+r opens reverse search (⌕ marker, "reverse-i-search:" header) over the
   loaded prompts; a fuzzy subsequence query narrows the list; ↵ inserts the pick
   into the draft and never submits (the draft keeps the text, no turn starts). *)
let%expect_test "ctrl+r fuzzy-searches history and inserts the pick" =
  Project.with_temp "next-history-search" @@ fun project ->
  seed_history project
    [ entry_line ~ts:1000 "alpha one"; entry_line ~ts:2000 "beta two" ];
  run project ~env:reduced_motion ~rows:24 ~cols:80 (fun t ->
      Term.wait t (Screen.has "dune:");
      Term.send t Keys.ctrl_r;
      Term.wait t (Screen.has "reverse-i-search:");
      print_fact "reverse-i-search header shown"
        (Screen.has "reverse-i-search:" (Term.screen t));
      print_fact "history marker shown" (Screen.has "⌕" (Term.screen t));
      print_fact "both prompts listed"
        (Screen.has "alpha one" (Term.screen t)
        && Screen.has "beta two" (Term.screen t));
      Term.send t "bt";
      Term.wait t (fun s ->
          Screen.has "beta two" s && Screen.lacks "alpha one" s);
      print_fact "fuzzy bt narrows to beta two"
        (Screen.has "beta two" (Term.screen t));
      print_fact "alpha one filtered out"
        (Screen.lacks "alpha one" (Term.screen t));
      Term.send t Keys.enter;
      Term.wait t (fun s ->
          Screen.lacks "reverse-i-search:" s && Screen.has "beta two" s);
      print_fact "enter closed the search"
        (Screen.lacks "reverse-i-search:" (Term.screen t));
      print_fact "pick inserted into the draft, not submitted"
        (Screen.has "beta two" (Term.screen t)
        && Screen.lacks "message spice" (Term.screen t)));
  [%expect
    {|
    reverse-i-search header shown: true
    history marker shown: true
    both prompts listed: true
    fuzzy bt narrows to beta two: true
    alpha one filtered out: true
    enter closed the search: true
    pick inserted into the draft, not submitted: true|}]

(* ctrl+r borrows the current draft as an empty query; esc closes the search and
   restores the exact draft that was displaced. Works even with no stored
   history — the surface is the composer's, not the list's. *)
let%expect_test "esc restores the draft borrowed by ctrl+r" =
  Project.with_temp "next-history-esc" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 (fun t ->
      Term.wait t (Screen.has "dune:");
      Term.send t "keep me";
      Term.wait t (Screen.has "keep me");
      Term.send t Keys.ctrl_r;
      Term.wait t (fun s ->
          Screen.has "reverse-i-search:" s && Screen.lacks "keep me" s);
      print_fact "ctrl+r opened search and borrowed the draft"
        (Screen.has "reverse-i-search:" (Term.screen t)
        && Screen.lacks "keep me" (Term.screen t));
      print_fact "empty history notes"
        (Screen.has "no prompt history" (Term.screen t));
      Term.send t Keys.escape;
      Term.wait t (fun s ->
          Screen.has "keep me" s && Screen.lacks "reverse-i-search:" s);
      print_fact "esc restored the borrowed draft"
        (Screen.has "keep me" (Term.screen t));
      print_fact "esc closed the search"
        (Screen.lacks "reverse-i-search:" (Term.screen t)));
  [%expect
    {|
    ctrl+r opened search and borrowed the draft: true
    empty history notes: true
    esc restored the borrowed draft: true
    esc closed the search: true|}]

(* A query matching no stored prompt shows the muted "no matching prompts" note
   (distinct from the empty "no prompt history"). *)
let%expect_test "ctrl+r shows the no-match note" =
  Project.with_temp "next-history-nomatch" @@ fun project ->
  seed_history project [ entry_line ~ts:1000 "alpha one" ];
  run project ~env:reduced_motion ~rows:24 ~cols:80 (fun t ->
      Term.wait t (Screen.has "dune:");
      Term.send t Keys.ctrl_r;
      Term.wait t (Screen.has "reverse-i-search:");
      Term.send t "zzz";
      Term.wait t (Screen.has "no matching prompts");
      print_fact "no-match note shown"
        (Screen.has "no matching prompts" (Term.screen t)));
  [%expect {| no-match note shown: true |}]
