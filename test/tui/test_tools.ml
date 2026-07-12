(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The per-tool transcript grammar (doc/ui-design/02-tools.md), re-expressed as
   full-frame goldens. A turn runs a real tool in the temp project: the fake
   provider returns a [function_call] item the host executes for real, then a
   follow-up completion the host requests with the tool result folded in
   (matched on [function_call_output]). Two harness facts shape the fixtures:
   the gpt-5.5 pin selects the apply_patch editor family (so edit_file/write_file
   need a [tools.editor] override to exist), and writes/shell prompt for
   permission under the default posture (reads auto-allow). Where the old pty
   suite retreated to substring facts against noisy diff gutters and elapsed
   clocks, the virtual clock makes the whole frame stable.

   The ask_user question dialog lives in test_dialogs (suite-coverage). *)

(* The gpt-5.5 fake pin carries the apply_patch capability, so its default editor
   family is apply_patch — edit_file/write_file are unregistered. The
   [tools.editor = string-replace] project override forces that family
   regardless of model. *)
let configure_edits project =
  Project.write project ".spice/config.json"
    {|{"tools":{"editor":"string-replace"}}|}

(* Auto-allow the write so it runs for real: a project config cannot escalate
   permission (self-grant protection), but SPICE_PERMISSION_MODE — the one
   escalation-trusted channel — can. Only the tests whose write must run
   unprompted set it. Shell prompts under every posture, so the permission test
   below needs nothing: it runs under the default one. *)
let edit_env = [ ("SPICE_PERMISSION_MODE", "accept-edits") ]

(* The follow-up completion: the model's request now carries the tool result, so
   it matches on [function_call_output] and settles the answer. It is held on a
   gate ([fin]) so the settled frame is observed only after {!Tui.release}, which
   waits deterministically for the turn to settle (the harness pumps the loop
   until the provider has served the response and its completion — the socket
   read, the blocking session save, the settled dispatch — has quiesced), so a
   following bare settle is stable. No [Tui.advance] is used: advancing virtual
   time past the release would let a background workspace-change save race the
   turn save into a "session conflict" on these real edit/write turns. *)
let final ~id answer =
  Provider_script.message ~expect:[ "function_call_output" ] ~gate:"fin" ~id
    answer

(* Drive one tool-calling turn to its settled transcript: submit the prompt, sync
   on the initial request and the follow-up the tool result triggers, then release
   the held final and settle. No dialog interrupts this path. *)
let run_turn t prompt =
  Tui.keys t prompt;
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t

(* Update: an edit renders the full inline diff, always (02-tools.md §File
   edits). The seeded file's changed line shows on both sides — old removed, new
   added — under the [Update(path)] header, and the summary counts the change. *)
let%expect_test "an edit renders a real inline diff" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "bump" ] ~id:"resp-update-call"
        ~call_id:"call-update" ~name:"edit_file"
        ~arguments:
          {|{"path":"notes.ml","old_string":"let y = 2","new_string":"let y = 3"}|}
        ();
      final ~id:"resp-update-final" "Bumped y to three.";
    ]
  in
  Tui.run ~name:"tools-update" ~env:edit_env ~provider:script
    ~seed:(fun project ->
      configure_edits project;
      Project.write project "notes.ml" "let x = 1\nlet y = 2\n")
  @@ fun t ->
  Tui.settle t;
  run_turn t "bump the value";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        permission: auto edits
05 |        sandbox: danger-full-access (config)
06 |
07 | ❯ bump the value
08 |
09 | ⏺ Update(notes.ml)
10 |   ⎿  Added 1 line, removed 1 line
11 |      1   let x = 1
12 |      2 - let y = 2
13 |      2 + let y = 3
14 |
15 | ⏺ Bumped y to three.
16 |
17 | ⊙ workspace changed · 1 files · +1 −1 · /review
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* Create: [Wrote N lines] then the first four content lines, the rest folded
   into [… +N lines ▸] (02-tools.md §File edits). A six-line write shows lines
   one through four and hides five and six behind the overflow row. *)
let%expect_test "a write shows a capped content preview" =
  let contents = "line1\nline2\nline3\nline4\nline5\nline6\n" in
  let script =
    [
      Provider_script.tool_call ~expect:[ "scaffold" ] ~id:"resp-create-call"
        ~call_id:"call-create" ~name:"write_file"
        ~arguments:
          (Printf.sprintf {|{"path":"fresh.txt","contents":%S}|} contents)
        ();
      final ~id:"resp-create-final" "Wrote the scaffold.";
    ]
  in
  Tui.run ~name:"tools-create" ~env:edit_env ~provider:script
    ~seed:configure_edits
  @@ fun t ->
  Tui.settle t;
  run_turn t "scaffold the file";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        permission: auto edits
05 |        sandbox: danger-full-access (config)
06 |
07 | ❯ scaffold the file
08 |
09 | ⏺ Create(fresh.txt)
10 |   ⎿  Wrote 6 lines
11 |       line1
12 |       line2
13 |       line3
14 |       line4
15 |       … +2 lines
16 |
17 | ⏺ Wrote the scaffold.
18 |
19 | ⊙ workspace changed · 1 files · +6 −0 · /review
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* Read: summary only, content behind disclosure (02-tools.md §Read). The read
   settles a [Read] block with a trailing [▸] and no file text inline — the
   seeded marker never reaches the screen. Reads auto-allow, so no override. *)
let%expect_test "a read shows a summary only" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "inspect" ] ~id:"resp-read-call"
        ~call_id:"call-read" ~name:"read_file"
        ~arguments:{|{"path":"data.txt"}|} ();
      final ~id:"resp-read-final" "Read the data file.";
    ]
  in
  Tui.run ~name:"tools-read" ~provider:script ~seed:(fun project ->
      Project.write project "data.txt"
        "alpha\nbeta\nSECRET_MARKER\ndelta\nepsilon\nzeta\neta\ntheta\n")
  @@ fun t ->
  Tui.settle t;
  run_turn t "inspect the data";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ inspect the data
07 |
08 | ⏺ Read(data.txt)
09 |   ⎿  Read 8 lines
10 |
11 | ⏺ Read the data file.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗        ? for shortcuts|}]

(* A failed edit renders no diff: an edit whose [old_string] is absent never
   changes the file, so the block carries the failure summary rather than a bogus
   diff — the would-be new text never appears (02-tools.md §Header and result
   grammar). Colour is not assertable, so the observable is the missing diff. *)
let%expect_test "a failed edit renders no diff" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "rename" ] ~id:"resp-failed-call"
        ~call_id:"call-failed" ~name:"edit_file"
        ~arguments:
          {|{"path":"src.ml","old_string":"GAMMA_ABSENT","new_string":"REPLACEMENT_TEXT"}|}
        ();
      final ~id:"resp-failed-final" "The edit could not apply.";
    ]
  in
  Tui.run ~name:"tools-failed" ~env:edit_env ~provider:script
    ~seed:(fun project ->
      configure_edits project;
      Project.write project "src.ml" "alpha\nbeta\n")
  @@ fun t ->
  Tui.settle t;
  run_turn t "rename the symbol";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        permission: auto edits
05 |        sandbox: danger-full-access (config)
06 |
07 | ❯ rename the symbol
08 |
09 | ⏺ Update(src.ml)
10 |   ⎿  src.ml: old_string was not found
11 |
12 | ⏺ The edit could not apply.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* Todo boards for the placement test: the first with nothing done, the second
   with the scaffold item completed. Their headers differ, so a screen carrying
   both proves two boards exist. *)
let board_early =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"in_progress","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"pending","priority":"medium","position":1}]}|}

let board_late =
  {|{"todos":[{"id":"t1","content":"scaffold the module","status":"completed","priority":"high","position":0},{"id":"t2","content":"write the tests","status":"in_progress","priority":"medium","position":1}]}|}

(* Todo: each todo_write lands a board AT ITS CALL SITE, like any tool result
   (02-tools.md §Todo block). A write, a read, then a second write leaves two
   boards with the read between them — not one floating board. Extra height so
   both boards and the read fit the frame. *)
let%expect_test "todo boards land at their call sites" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "plan" ] ~id:"r-t1" ~call_id:"c-t1"
        ~name:"todo_write" ~arguments:board_early ();
      Provider_script.tool_call ~expect:[ "function_call_output" ] ~id:"r-tr"
        ~call_id:"c-tr" ~name:"read_file" ~arguments:{|{"path":"data.txt"}|} ();
      Provider_script.tool_call ~expect:[ "function_call_output" ] ~id:"r-t2"
        ~call_id:"c-t2" ~name:"todo_write" ~arguments:board_late ();
      final ~id:"r-tf" "Planned and inspected.";
    ]
  in
  Tui.run ~name:"tools-todo-sites" ~size:(80, 30) ~provider:script
    ~seed:(fun project -> Project.write project "data.txt" "notes\n")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  ignore (Tui.await_request t 3 : string);
  ignore (Tui.await_request t 4 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ plan the work
07 |
08 | ⏺ Todo(2 tasks · 0 done · 1 running)
09 |       ◼ scaffold the module
10 |       ◻ write the tests
11 |
12 | ⏺ Read(data.txt)
13 |   ⎿  Read 1 line
14 |
15 | ⏺ Todo(2 tasks · 1 done · 1 running)
16 |       ◼ write the tests
17 |       ⎿ … 1 done
18 |
19 | ⏺ Planned and inspected.
20 |
21 |
22 |
23 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
24 |   ◻ 2 tasks · 1 done · 1 running
25 |   ◼ write the tests
26 |   … 1 done
27 | ────────────────────────────────────────────────────────────────────────────────
28 | ❯ message spice
29 | ────────────────────────────────────────────────────────────────────────────────
30 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* The one folding law: two todo_writes in a row, nothing between, collapse to
   the newest board — the same last-block-only fold as failure [× N]
   (02-tools.md §Todo block). The first board's header is replaced, not stacked. *)
let%expect_test "consecutive todo writes fold to one board" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "plan" ] ~id:"r-f1" ~call_id:"c-f1"
        ~name:"todo_write" ~arguments:board_early ();
      Provider_script.tool_call ~expect:[ "function_call_output" ] ~id:"r-f2"
        ~call_id:"c-f2" ~name:"todo_write" ~arguments:board_late ();
      final ~id:"r-ff" "Re-planned the work.";
    ]
  in
  Tui.run ~name:"tools-todo-fold" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "plan the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  ignore (Tui.await_request t 2 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ plan the work
07 |
08 | ⏺ Todo(2 tasks · 1 done · 1 running)
09 |       ◼ write the tests
10 |       ⎿ … 1 done
11 |
12 | ⏺ Re-planned the work.
13 |
14 |
15 |
16 |
17 | ┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈┈
18 |   ◻ 2 tasks · 1 done · 1 running
19 |   ◼ write the tests
20 |   … 1 done
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

(* A shell call is gated by a permission decision under the default ask-first
   posture (02-tools.md §Header, Awaiting permission): the prompt is a dialog,
   and once the decision resolves the call is recorded in the document.
   Approving runs it and settles its [Shell] block. *)
let%expect_test "a shell permission prompt gates the call and records it" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "run it" ] ~id:"r-perm"
        ~call_id:"c-perm" ~name:"shell"
        ~arguments:{|{"command":"echo recorded"}|} ();
      final ~id:"r-perm-final" "Ran the command.";
    ]
  in
  Tui.run ~name:"tools-perm" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "run it";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.await_suspend t;
  (* The shell call prompts: the permission dialog owns the screen. *)
  Tui.print t;
  [%expect
    {|01 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
02 |    permission
03 |
04 |   Run this command?
05 |
06 |   $ echo recorded
07 |   in $PROJECT/.
08 |
09 | ❯ 1. Yes, run it once
10 |   2. Yes, don't ask again for this command this session
11 |   3. No, and tell Spice what to do differently
12 |   4. Yes, always allow echo
13 |      saves for this session — press s to change
14 |
15 |   1-4 choose · enter confirm · s scope · esc deny with feedback
16 |
17 |
18 |
19 |
20 |
21 |
22 |
23 |
24 ||}];
  (* Approve (the highlighted first option); the call runs and its Shell block
     settles into the document. *)
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ run it
07 |
08 |   allowed once
09 |
10 | ⏺ Shell(echo recorded)
11 |   ⎿  done · 0s
12 |
13 | ⏺ Ran the command.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗        ? for shortcuts|}]

let process_exists pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception Unix.Unix_error _ -> true

let process_group_exists pgid =
  match Unix.kill (-pgid) 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception Unix.Unix_error _ -> true

let%expect_test "quitting joins and reaps a blocked shell tool" =
  let command =
    "echo $$ > .blocked-shell.pid; trap '' TERM; while :; do sleep 1; done"
  in
  let script =
    [
      Provider_script.tool_call ~expect:[ "block the shell" ]
        ~id:"r-blocked-shell" ~call_id:"c-blocked-shell" ~name:"shell"
        ~arguments:(Printf.sprintf {|{"command":%S,"timeout_ms":600000}|} command)
        ();
    ]
  in
  Tui.run ~name:"tools-blocked-shell-close" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "block the shell";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.await_suspend t;
  Tui.enter t;
  Tui.await_file t ".blocked-shell.pid";
  let pid =
    Project.read (Tui.project t) ".blocked-shell.pid"
    |> String.trim |> int_of_string
  in
  Tui.keys t Key.ctrl_c;
  Tui.keys t Key.ctrl_c;
  Tui.await_exit ~timeout:3. t;
  Printf.printf "exited: %b\n" (match Tui.outcome t with _ -> true);
  Printf.printf "shell alive: %b\n" (process_exists pid);
  Printf.printf "shell process group alive: %b\n" (process_group_exists pid);
  [%expect
    {|
    exited: true
    shell alive: false
    shell process group alive: false|}]

(* Shell failure (02-tools.md §Shell): a nonzero exit is humanized to
   [exited N · <duration>] — never the raw [command exited with status N] — and
   the LAST output lines auto-show with a [… +N lines ▸] overflow. The duration
   is wall-clock-derived in the block, so this asserts the humanized exit and
   the output tail, not the elapsed figure. *)
let%expect_test "a failed shell humanizes the exit and shows the output tail" =
  let cmd = {|for i in 1 2 3 4 5 6 7; do echo OUT$i; done; exit 3|} in
  let script =
    [
      Provider_script.tool_call ~expect:[ "fail it" ] ~id:"r-sf" ~call_id:"c-sf"
        ~name:"shell"
        ~arguments:(Printf.sprintf {|{"command":%S}|} cmd)
        ();
      final ~id:"r-sf-final" "The command failed.";
    ]
  in
  Tui.run ~name:"tools-shellfail" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "fail it";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.await_suspend t;
  (* Approve the run. *)
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ fail it
07 |
08 |   allowed once
09 |
10 | ⏺ Shell(for i in 1 2 3 4 5 6 7; do echo OUT$i; done; exit 3)
11 |   ⎿  exited 3 · 0s
12 |       OUT3
13 |       OUT4
14 |       OUT5
15 |       OUT6
16 |       OUT7
17 |       … +2 lines
18 |
19 | ⏺ The command failed.
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

(* A long failure summary wraps under the [⎿] column rather than truncating at
   the terminal edge (02-tools.md §Header): a read of a deeply-nested missing
   path fails with a message long enough to wrap, and the token that ends it
   reaches the screen — it would be lost past column 80 if the line clipped. *)
let%expect_test "a long failure summary wraps instead of truncating" =
  let path =
    "a/very/deeply/nested/directory/path/that/surely/does/not/exist/UNIQUEENDTOKEN.txt"
  in
  let script =
    [
      Provider_script.tool_call ~expect:[ "read it" ] ~id:"r-wrap"
        ~call_id:"c-wrap" ~name:"read_file"
        ~arguments:(Printf.sprintf {|{"path":%S}|} path)
        ();
      final ~id:"r-wrap-final" "The file was missing.";
    ]
  in
  Tui.run ~name:"tools-wrap" ~provider:script @@ fun t ->
  Tui.settle t;
  run_turn t "read it";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ read it
07 |
08 | ⏺ Read(a/very/deeply/nested/directory/path/that/surely/does/not/exist/UNIQUE…)
09 |   ⎿  a/very/deeply/nested/directory/path/that/surely/does/not/exist/
10 |      UNIQUEENDTOKEN.txt: path does not exist
11 |
12 | ⏺ The file was missing.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗        ? for shortcuts|}]

(* OCaml structural search (02-tools.md §OCaml tools): [ocaml_search_expressions]
   shares the [Search] verb and reports [Found N matches across M files] off its
   own count shape. Unlike the Merlin-backed navigation tools it is pure-parser
   and read-only — no ocamlmerlin subprocess and no Dune RPC. Two [List.map __ __]
   applications in one seeded file give a deterministic [2 matches across 1
   file]; [__] matches any expression. *)
let%expect_test
    "ocaml_search_expressions renders a Search verb with real counts" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "search it" ] ~id:"r-se"
        ~call_id:"c-se" ~name:"ocaml_search_expressions"
        ~arguments:{|{"pattern":"List.map __ __","paths":["probe.ml"]}|} ();
      final ~id:"r-se-final" "Searched the expressions.";
    ]
  in
  Tui.run ~name:"tools-searchexpr" ~provider:script ~seed:(fun project ->
      Project.write project "probe.ml"
        "let a = List.map succ [ 1; 2; 3 ]\nlet b = List.map pred [ 4; 5 ]\n")
  @@ fun t ->
  Tui.settle t;
  run_turn t "search it";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ search it
07 |
08 | ⏺ Search(List.map __ __)
09 |   ⎿  Found 2 matches across 1 file
10 |
11 | ⏺ Searched the expressions.
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

(* A question continuation creates a fresh event projector without forgetting
   that the turn is already active. The following auto-handled todo call must
   therefore render at its call site before the final answer settles. *)
let%expect_test "a host tool after a question settles in the transcript" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "help me sequence" ]
        ~id:"resp-question" ~call_id:"call-question" ~name:"ask_user"
        ~arguments:{|{"question":"What should come first?"}|} ();
      Provider_script.tool_call
        ~expect:[ "function_call_output"; "call-question"; "inspect" ]
        ~id:"resp-question-todo" ~call_id:"call-question-todo"
        ~name:"todo_write" ~arguments:board_early ();
      final ~id:"resp-question-final" "Sequenced the work.";
    ]
  in
  Tui.run ~name:"tools-question-then-todo" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "help me sequence the work";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.await_suspend t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "inspect";
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  ignore (Tui.await_request t 3 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
02 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
03 |        sandbox: danger-full-access (config)
04 |
05 | ❯ help me sequence the work
06 |
07 |   answered
08 |
09 | ⏺ Question(What should come first?)
10 |   ⎿  answered · "User answered: inspect"
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

[%%run_tests "spice.tui.tools"]
