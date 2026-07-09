(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the per-tool transcript grammar (doc/ui-design/
   02-tools.md). A turn runs a real tool in the temp project: the fake provider
   returns a [function_call] the host executes for real, then a held second
   response the host requests with the tool result folded in, carrying the
   settled answer. Two harness facts shape the fixtures: the gpt-5.5 pin selects
   the apply_patch editor family (so edit_file/write_file need a [tools.editor]
   override to exist), and writes/shell prompt for permission under the default
   posture (reads auto-allow) — see [configure_edits]/[edit_env].

   Facts, not screen goldens: the diff gutter and elapsed clocks are noisy, so
   each test asserts the load-bearing observables — a real diff's added/removed
   text, the Create preview cap and overflow, Read's summary-only shape, a
   failed edit rendering no bogus diff, the todo boards' call-site placement and
   fold, and a shell call gated by a permission decision. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* The 1-based screen row a needle first lands on, or 0 when absent — used to
   assert one block sits above another. *)
let row_of needle screen =
  let rec find i = function
    | [] -> 0
    | line :: rest -> if Util.contains line needle then i else find (i + 1) rest
  in
  find 1 (String.split_on_char '\n' screen)

let run ?env ?rows ?cols ?provider project f =
  Term.run ?env ?rows ?cols ?provider project f

let json_strings texts =
  String.concat "," (List.map (Printf.sprintf "%S") texts)

(* A completed Responses payload whose single output item is a [function_call]:
   the host runs the named tool for real against the temp project, then requests
   a follow-up step (matched by the final response's [function_call_output] body
   token). [arguments] is the tool input as a JSON string, so it is [%S]-escaped
   into a JSON string literal. *)
let tool_call_line ~id ~call_id ~name ~arguments ~body_contains =
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-%s","call_id":%S,"name":%S,"arguments":%S}]}}|}
    (json_strings body_contains)
    id call_id call_id name arguments

(* An [ask_user] host-tool call: the model asks a question with no assistant
   text, so the host suspends the turn on the question boundary and a dialog
   collects the answer (mirrors test_transcript's question fixture). *)
let question_line ~id ~call_id ~body_contains ~question =
  let arguments = Printf.sprintf {|{"question":%S}|} question in
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-question","call_id":%S,"name":"ask_user","arguments":%S}]}}|}
    (json_strings body_contains)
    id call_id arguments

(* The follow-up step: the model's request now carries the tool result, so it
   matches on [function_call_output] and settles the answer. *)
let answer_line ~id ~answer =
  Provider.response_line ~id ~body_contains:[ "function_call_output" ]
    ~body_not_contains:[] ~answer

(* The gpt-5.5 fake pin carries the apply_patch capability, so its default
   editor family is apply_patch — [edit_file]/[write_file] are then unregistered
   ("unknown tool"). The [tools.editor = string-replace] project override forces
   the edit_file/write_file family regardless of model. *)
let configure_edits project =
  Project.write project ".spice/config.json"
    {|{"tools":{"editor":"string-replace"}}|}

(* Auto-allow the write so it runs for real: a project config cannot escalate
   permission (self-grant protection), but [SPICE_PERMISSION_MODE] — the one
   escalation-trusted channel — can. Shell still prompts under accept-edits,
   which the permission test relies on. *)
let edit_env = reduced_motion @ [ ("SPICE_PERMISSION_MODE", "accept-edits") ]

(* Update: an edit renders the full inline diff, always (02-tools.md §File
   edits). The seeded file's changed line shows on both sides — the old value
   removed, the new added — under the [Update(path)] header, and the summary
   counts the change. *)
let%expect_test "an edit renders a real inline diff" =
  Project.with_temp "next-tools-update" @@ fun project ->
  configure_edits project;
  Project.write project "notes.ml" "let x = 1\nlet y = 2\n";
  let call =
    tool_call_line ~id:"resp-update-call" ~call_id:"call-update"
      ~name:"edit_file"
      ~arguments:
        {|{"path":"notes.ml","old_string":"let y = 2","new_string":"let y = 3"}|}
      ~body_contains:[ "bump" ]
  in
  let final =
    answer_line ~id:"resp-update-final" ~answer:"Bumped y to three."
  in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:edit_env ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "bump the value";
  Term.wait t (Screen.has "❯ bump the value");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Bumped y to three." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "Update header renders" (Screen.has "Update" s);
  print_fact "header names the file" (Screen.has "notes.ml" s);
  print_fact "old line removed in the diff" (Screen.has "let y = 2" s);
  print_fact "new line added in the diff" (Screen.has "let y = 3" s);
  print_fact "summary counts the change" (Screen.has "Added 1 line" s);
  [%expect
    {|
    Update header renders: true
    header names the file: true
    old line removed in the diff: true
    new line added in the diff: true
    summary counts the change: true|}]

(* Create: [Wrote N lines] then the first four content lines, the rest folded
   into [… +N lines ▸] (02-tools.md §File edits). A six-line write shows lines
   one through four and hides five and six behind the overflow row. *)
let%expect_test "a write shows a capped content preview" =
  Project.with_temp "next-tools-create" @@ fun project ->
  configure_edits project;
  let contents = "line1\nline2\nline3\nline4\nline5\nline6\n" in
  let call =
    tool_call_line ~id:"resp-create-call" ~call_id:"call-create"
      ~name:"write_file"
      ~arguments:
        (Printf.sprintf {|{"path":"fresh.txt","contents":%S}|} contents)
      ~body_contains:[ "scaffold" ]
  in
  let final =
    answer_line ~id:"resp-create-final" ~answer:"Wrote the scaffold."
  in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:edit_env ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "scaffold the file";
  Term.wait t (Screen.has "❯ scaffold the file");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Wrote the scaffold." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "Create header renders" (Screen.has "Create" s);
  print_fact "wrote-count summary" (Screen.has "Wrote 6 lines" s);
  print_fact "first line previewed" (Screen.has "line1" s);
  print_fact "fourth line previewed" (Screen.has "line4" s);
  print_fact "fifth line hidden" (Screen.lacks "line5" s);
  print_fact "overflow row shows the remainder" (Screen.has "+2 lines" s);
  [%expect
    {|
    Create header renders: true
    wrote-count summary: true
    first line previewed: true
    fourth line previewed: true
    fifth line hidden: true
    overflow row shows the remainder: true|}]

(* Read: summary only, content behind disclosure (02-tools.md §Read). The read
   settles a [Read] block with a trailing [▸] and no file text inline — the
   seeded marker never reaches the screen. *)
let%expect_test "a read shows a summary only" =
  Project.with_temp "next-tools-read" @@ fun project ->
  Project.write project "data.txt"
    "alpha\nbeta\nSECRET_MARKER\ndelta\nepsilon\nzeta\neta\ntheta\n";
  let call =
    tool_call_line ~id:"resp-read-call" ~call_id:"call-read" ~name:"read_file"
      ~arguments:{|{"path":"data.txt"}|} ~body_contains:[ "inspect" ]
  in
  let final = answer_line ~id:"resp-read-final" ~answer:"Read the data file." in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "inspect the data";
  Term.wait t (Screen.has "❯ inspect the data");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Read the data file." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "Read header renders" (Screen.has "Read" s);
  print_fact "content stays behind disclosure" (Screen.lacks "SECRET_MARKER" s);
  print_fact "disclosure marker present" (Screen.has "▸" s);
  [%expect
    {|
    Read header renders: true
    content stays behind disclosure: true
    disclosure marker present: true|}]

(* A failed edit renders no diff: an edit whose [old_string] is absent never
   changes the file, so the block carries the failure summary rather than a
   bogus diff — the would-be new text never appears (02-tools.md §Header and
   result grammar, failed dot). Colour is not assertable in a VTE dump, so the
   observable is the missing diff, not the red dot. *)
let%expect_test "a failed edit renders no diff" =
  Project.with_temp "next-tools-failed" @@ fun project ->
  configure_edits project;
  Project.write project "src.ml" "alpha\nbeta\n";
  let call =
    tool_call_line ~id:"resp-failed-call" ~call_id:"call-failed"
      ~name:"edit_file"
      ~arguments:
        {|{"path":"src.ml","old_string":"GAMMA_ABSENT","new_string":"REPLACEMENT_TEXT"}|}
      ~body_contains:[ "rename" ]
  in
  let final =
    answer_line ~id:"resp-failed-final" ~answer:"The edit could not apply."
  in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:edit_env ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "rename the symbol";
  Term.wait t (Screen.has "❯ rename the symbol");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "The edit could not apply." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "the edit verb still renders" (Screen.has "Update" s);
  print_fact "no diff shows the would-be replacement"
    (Screen.lacks "REPLACEMENT_TEXT" s);
  [%expect
    {|
    the edit verb still renders: true
    no diff shows the would-be replacement: true|}]

(* Two todo boards for the placement test: the first with nothing done, the
   second with the scaffold item completed. Their headers differ ([0 done] vs
   [1 done]), so a screen carrying both proves two boards exist. *)
let board_early =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"pending","priority":"medium","position":1}]}|}

let board_late =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"completed","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"in_progress","priority":"medium","position":1}]}|}

(* Todo: each todo_write lands a board AT ITS CALL SITE, like any tool result
   (02-tools.md §Todo block). A write, a read, then a second write leaves two
   boards with the read between them — not one floating board. *)
let%expect_test "todo boards land at their call sites" =
  Project.with_temp "next-tools-todo-sites" @@ fun project ->
  Project.write project "data.txt" "notes\n";
  let todo1 =
    tool_call_line ~id:"r-t1" ~call_id:"c-t1" ~name:"todo_write"
      ~arguments:board_early ~body_contains:[ "plan" ]
  in
  let read =
    tool_call_line ~id:"r-tr" ~call_id:"c-tr" ~name:"read_file"
      ~arguments:{|{"path":"data.txt"}|}
      ~body_contains:[ "function_call_output" ]
  in
  let todo2 =
    tool_call_line ~id:"r-t2" ~call_id:"c-t2" ~name:"todo_write"
      ~arguments:board_late ~body_contains:[ "function_call_output" ]
  in
  let final = answer_line ~id:"r-tf" ~answer:"Planned and inspected." in
  Provider.with_responses project [ todo1; read; todo2; final ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:30 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Planned and inspected." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "first board at its call site" (Screen.has "0 done · 1 running" s);
  print_fact "second board at its call site" (Screen.has "1 done · 1 running" s);
  print_fact "the read block sits between the two boards"
    (let a = row_of "0 done · 1 running" s in
     let r = row_of "Read" s in
     let b = row_of "1 done · 1 running" s in
     a < r && r < b);
  [%expect
    {|
    first board at its call site: true
    second board at its call site: true
    the read block sits between the two boards: true|}]

(* The one folding law: two todo_writes in a row, nothing between, collapse to
   the newest board — the same last-block-only fold as failure [× N]
   (02-tools.md §Todo block). The first board's header is replaced, not stacked. *)
let%expect_test "consecutive todo writes fold to one board" =
  Project.with_temp "next-tools-todo-fold" @@ fun project ->
  let todo1 =
    tool_call_line ~id:"r-f1" ~call_id:"c-f1" ~name:"todo_write"
      ~arguments:board_early ~body_contains:[ "plan" ]
  in
  let todo2 =
    tool_call_line ~id:"r-f2" ~call_id:"c-f2" ~name:"todo_write"
      ~arguments:board_late ~body_contains:[ "function_call_output" ]
  in
  let final = answer_line ~id:"r-ff" ~answer:"Re-planned the work." in
  Provider.with_responses project [ todo1; todo2; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "plan the work";
  Term.wait t (Screen.has "❯ plan the work");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Re-planned the work." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "the newest board is shown" (Screen.has "1 done · 1 running" s);
  print_fact "the first board was replaced, not stacked"
    (Screen.lacks "0 done · 1 running" s);
  [%expect
    {|
    the newest board is shown: true
    the first board was replaced, not stacked: true|}]

(* A shell call is gated by a permission decision under the default ask-first
   posture (02-tools.md §Header, Awaiting permission): the prompt is a dialog,
   and once the decision resolves the call is recorded in the document — the
   reducer never lets an outcome notice be the only trace of what was pending.
   Approving the call runs it and settles its [Shell] block; the [interrupted]
   and [denied] settle forms are exercised by the reducer's Turn_finished flush
   and Permission_resolved handling. *)
let%expect_test "a shell permission prompt gates the call and records it" =
  Project.with_temp "next-tools-perm" @@ fun project ->
  let call =
    tool_call_line ~id:"r-perm" ~call_id:"c-perm" ~name:"shell"
      ~arguments:{|{"command":"echo recorded"}|} ~body_contains:[ "run it" ]
  in
  let final = answer_line ~id:"r-perm-final" ~answer:"Ran the command." in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "run it";
  Term.wait t (Screen.has "❯ run it");
  Term.send t Keys.enter;
  (* The shell call prompts: the permission dialog owns the screen. *)
  Term.wait t (Screen.has "Run a shell command?");
  print_fact "shell prompts for permission"
    (Screen.has "Run a shell command?" (Term.screen t));
  (* Approve once (the highlighted first option); the call then runs and its
     Shell block settles into the document. *)
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Ran the command." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "the approved call runs and settles a Shell block"
    (Screen.has "Shell" s);
  print_fact "the command is on the record" (Screen.has "echo recorded" s);
  [%expect
    {|
    shell prompts for permission: true
    the approved call runs and settles a Shell block: true
    the command is on the record: true|}]

(* Shell failure (02-tools.md §Shell): a nonzero exit is humanized to
   [exited N · <duration>] — never the raw [command exited with status N] tool
   message — and the LAST five output lines auto-show with a [… +N lines ▸]
   overflow. Approved through the permission dialog so the command runs. *)
let%expect_test "a failed shell humanizes the exit and shows the output tail" =
  Project.with_temp "next-tools-shellfail" @@ fun project ->
  (* Generate the lines in a loop so the output tokens [OUT1..OUT7] appear only
     in the captured output, never in the command echoed by the header. *)
  let cmd = {|for i in 1 2 3 4 5 6 7; do echo OUT$i; done; exit 3|} in
  let call =
    tool_call_line ~id:"r-sf" ~call_id:"c-sf" ~name:"shell"
      ~arguments:(Printf.sprintf {|{"command":%S}|} cmd)
      ~body_contains:[ "fail it" ]
  in
  let final = answer_line ~id:"r-sf-final" ~answer:"The command failed." in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "fail it";
  Term.wait t (Screen.has "❯ fail it");
  Term.send t Keys.enter;
  (* Approve the run (a compound command lists more than one operation, so wait
     on the confirm affordance common to every permission dialog). *)
  Term.wait t (Screen.has "enter confirm");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "The command failed." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "exit code is humanized" (Screen.has "exited 3" s);
  print_fact "the raw tool message is not the summary"
    (Screen.lacks "command exited with status" s);
  print_fact "the last output line shows" (Screen.has "OUT7" s);
  print_fact "an earlier line is behind the overflow" (Screen.lacks "OUT1" s);
  print_fact "the overflow row counts the hidden lines"
    (Screen.has "+2 lines" s);
  [%expect
    {|
    exit code is humanized: true
    the raw tool message is not the summary: true
    the last output line shows: true
    an earlier line is behind the overflow: true
    the overflow row counts the hidden lines: true|}]

(* A long failure summary wraps under the [⎿] column rather than truncating at
   the terminal edge (02-tools.md §Header): a read of a deeply-nested missing
   path fails with a message long enough to wrap, and the token that ends it
   reaches the screen — it would be lost past column 80 if the line clipped. *)
let%expect_test "a long failure summary wraps instead of truncating" =
  Project.with_temp "next-tools-wrap" @@ fun project ->
  let path =
    "a/very/deeply/nested/directory/path/that/surely/does/not/exist/UNIQUEENDTOKEN.txt"
  in
  let call =
    tool_call_line ~id:"r-wrap" ~call_id:"c-wrap" ~name:"read_file"
      ~arguments:(Printf.sprintf {|{"path":%S}|} path)
      ~body_contains:[ "read it" ]
  in
  let final = answer_line ~id:"r-wrap-final" ~answer:"The file was missing." in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "read it";
  Term.wait t (Screen.has "❯ read it");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "The file was missing." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "the read verb renders" (Screen.has "Read" s);
  print_fact "the end of the long message is on screen (wrapped, not clipped)"
    (Screen.has "UNIQUEENDTOKEN" s);
  [%expect
    {|
    the read verb renders: true
    the end of the long message is on screen (wrapped, not clipped): true|}]

(* Host questions (02-tools.md §Host questions): ask_user records the QUESTION as
   the argument and the ANSWER as the result — never [⏺ Ask_user ⎿ done]. The
   dialog collects the answer; the settled block quotes it. *)
let%expect_test "an answered question records the question and answer" =
  Project.with_temp "next-tools-question" @@ fun project ->
  let question =
    question_line ~id:"r-q" ~call_id:"c-q" ~body_contains:[ "help me choose" ]
      ~question:"Which test runner should I wire up?"
  in
  let final = answer_line ~id:"r-q-final" ~answer:"Wired it up." in
  Provider.with_responses project [ question; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "help me choose";
  Term.wait t (Screen.has "❯ help me choose");
  Term.send t Keys.enter;
  (* The question dialog shows the question and a "type your own answer" option;
     selecting it borrows the composer, where the answer is typed and submitted. *)
  Term.wait t (Screen.has "Which test runner should I wire up?");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "type your answer");
  Term.send t "dune runtest";
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Wired it up." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "the question is the header argument"
    (Screen.has "Which test runner should I wire up?" s);
  print_fact "the result records the answer" (Screen.has "answered" s);
  print_fact "the answer is quoted" (Screen.has "dune runtest" s);
  [%expect
    {|
    the question is the header argument: true
    the result records the answer: true
    the answer is quoted: true|}]

(* A continuation command creates a fresh live event projector. It must seed
   host-tool recognition from the active turn so an auto-handled call in the
   resumed model step emits both its pending and settled events. *)
let%expect_test "a host tool after a question settles in the transcript" =
  Project.with_temp "next-tools-question-then-todo" @@ fun project ->
  let question =
    question_line ~id:"r-qt-question" ~call_id:"c-qt-question"
      ~body_contains:[ "help me sequence" ] ~question:"What should come first?"
  in
  let todo =
    tool_call_line ~id:"r-qt-todo" ~call_id:"c-qt-todo" ~name:"todo_write"
      ~arguments:board_early
      ~body_contains:[ "function_call_output"; "c-qt-question"; "inspect" ]
  in
  let final = answer_line ~id:"r-qt-final" ~answer:"Sequenced the work." in
  Provider.with_responses project [ question; todo; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "help me sequence the work";
  Term.send t Keys.enter;
  Term.wait t (Screen.has "What should come first?");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "type your answer");
  Term.send t "inspect";
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Sequenced the work." s && Screen.has "? for shortcuts" s);
  Screen.print ~project (Term.screen t);
  [%expect
    {|
     01 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
     02 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
     03 |        sandbox: danger-full-access (config)
     04 |
     05 | ❯ help me sequence the work
     06 |
     07 |   answered
     08 |
     09 | ⏺ Question(What should come first?)
     10 |   ⎿  answered · "inspect"
     11 |
     12 | ⏺ Todo(2 tasks · 0 done · 1 running)
     13 |       ◼ scaffold the module
     14 |       ◻ write the tests
     15 |
     16 | ⏺ Sequenced the work.
     17 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
     18 |   ◻ 2 tasks · 0 done · 1 running
     19 |   ◼ scaffold the module
     20 |   ◻ write the tests
     21 | ────────────────────────────────────────────────────────────────────────────────
     22 | ❯ message spice
     23 | ────────────────────────────────────────────────────────────────────────────────
     24 |   …i-next-tools-question-then-todo · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* OCaml structural search (02-tools.md §OCaml tools, Navigation and
   evaluation): [ocaml_search_expressions] shares the [Search] verb and reports
   [Found N matches across M files] off its own count shape. Unlike the
   Merlin-backed navigation tools (ocaml_type_at, ocaml_find_definitions,
   ocaml_find_references), it is pure-parser and read-only — no ocamlmerlin
   subprocess and no Dune RPC handshake — so it is drivable in the pty harness
   where those hang. Two [List.map __ __] applications in one seeded file give a
   deterministic [2 matches across 1 file]; [__] matches any expression. *)
let%expect_test
    "ocaml_search_expressions renders a Search verb with real counts" =
  Project.with_temp "next-tools-searchexpr" @@ fun project ->
  Project.write project "probe.ml"
    "let a = List.map succ [ 1; 2; 3 ]\nlet b = List.map pred [ 4; 5 ]\n";
  let call =
    tool_call_line ~id:"r-se" ~call_id:"c-se" ~name:"ocaml_search_expressions"
      ~arguments:{|{"pattern":"List.map __ __","paths":["probe.ml"]}|}
      ~body_contains:[ "search it" ]
  in
  let final =
    answer_line ~id:"r-se-final" ~answer:"Searched the expressions."
  in
  Provider.with_responses project [ call; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "search it";
  Term.wait t (Screen.has "❯ search it");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Searched the expressions." s && Screen.has "? for shortcuts" s);
  let s = Term.screen t in
  print_fact "the Search verb names the pattern"
    (Screen.has "Search(List.map" s);
  print_fact "the summary counts the real matches"
    (Screen.has "Found 2 matches" s);
  print_fact "the summary counts the files" (Screen.has "1 file" s);
  print_fact "the raw tool name never appears"
    (Screen.lacks "Ocaml_search_expressions" s);
  [%expect
    {|
    the Search verb names the pattern: true
    the summary counts the real matches: true
    the summary counts the files: true
    the raw tool name never appears: true|}]

[%%run_tests "spice.tui-next.tools"]
