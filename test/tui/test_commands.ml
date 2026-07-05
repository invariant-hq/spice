(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the slash palette and command dispatch
   (doc/ui-design/03-composer.md §Slash palette, 10-commands.md,
   doc/plans/tui-next-composer.md). No turns run, so like the home tests these
   need only the real spice binary. The palette advertises only wired commands
   (Command.implemented — the honest-state gate), and ↵ never sends the draft
   while the list is up. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

let run ?env ?rows ?cols project f =
  Term.run ?env ?rows ?cols project f

(* Typing "/" on the empty draft opens the palette; only the wired commands
   show ([/thinking], [/sessions], [/quit] today), so nothing advertised is
   dead. *)
let%expect_test "slash opens the palette with only wired commands" =
  Project.with_temp "next-palette-open" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/";
  Term.wait t (Screen.has "/sessions");
  print_fact "sessions row" (Screen.has "/sessions" (Term.screen t));
  print_fact "quit row" (Screen.has "/quit" (Term.screen t));
  print_fact "unwired command hidden" (Screen.lacks "/review" (Term.screen t));
  [%expect
    {|
    sessions row: true
    quit row: true
    unwired command hidden: true|}]

(* Each keystroke narrows the rows (the composer text IS the filter); a filter
   with no match shows the note row; backspacing past the "/" closes the
   palette entirely. *)
let%expect_test "filtering narrows and backspace past the slash closes" =
  Project.with_temp "next-palette-filter" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/q";
  Term.wait t (fun s -> Screen.has "/quit" s && Screen.lacks "/sessions" s);
  print_fact "narrowed to quit" (Screen.lacks "/sessions" (Term.screen t));
  Term.send t "zz";
  Term.wait t (Screen.has "no matching commands");
  print_fact "empty filter notes" (Screen.has "no matching commands" (Term.screen t));
  Term.send t Keys.backspace;
  Term.send t Keys.backspace;
  Term.send t Keys.backspace;
  Term.wait t (fun s -> Screen.has "/quit" s && Screen.has "/sessions" s);
  Term.send t Keys.backspace;
  Term.send t Keys.backspace;
  Term.wait t (Screen.lacks "/quit");
  print_fact "closed once the slash is gone" (Screen.lacks "/quit" (Term.screen t));
  [%expect
    {|
    narrowed to quit: true
    empty filter notes: true
    closed once the slash is gone: true|}]

(* Esc is the ladder's first rung while a list is open: it closes the palette
   and clears the slash input, restoring the idle placeholder. *)
let%expect_test "esc closes the palette and clears the input" =
  Project.with_temp "next-palette-esc" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/q";
  Term.wait t (Screen.has "/quit");
  Term.send t Keys.escape;
  Term.wait t (fun s -> Screen.lacks "/quit" s && Screen.has "message spice" s);
  print_fact "palette gone" (Screen.lacks "/quit" (Term.screen t));
  print_fact "draft cleared" (Screen.has "message spice" (Term.screen t));
  [%expect
    {|
    palette gone: true
    draft cleared: true|}]

(* ↵ on the selected no-argument command runs it — never sends the draft:
   filtering to [/sessions] and pressing ↵ opens the quick-switch panel below
   its ▔ boundary. *)
let%expect_test "enter runs the selected command" =
  Project.with_temp "next-palette-run" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/sessions";
  Term.wait t (fun s -> Screen.has "/sessions" s && Screen.lacks "/thinking" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "▔▔▔▔");
  print_fact "panel opened" (Screen.has "▔▔▔▔" (Term.screen t));
  [%expect {| panel opened: true |}]

(* A known-but-unwired command typed in full falls through the empty list to
   the honest flash; it never starts a turn. *)
let%expect_test "unwired commands flash honestly" =
  Project.with_temp "next-palette-honest" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/review";
  Term.wait t (Screen.has "no matching commands");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "/review lands in a later iteration");
  print_fact "unwired command flashed"
    (Screen.has "/review lands in a later iteration" (Term.screen t));
  [%expect {| unwired command flashed: true |}]

(* /plan colors the composer frame with its chip and records nothing on the
   home stage (the chip is the record there); /build restores the wordless gray
   frame (03-composer.md §Mode-colored frame, 10-commands.md §Mode switches). *)
let%expect_test "the mode switches dress the composer frame" =
  Project.with_temp "next-mode-switch" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/plan";
  Term.wait t (fun s -> Screen.has "/plan" s && Screen.lacks "/quit" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "⏸ plan");
  print_fact "plan chip on the top rule" (Screen.has "⏸ plan" (Term.screen t));
  Term.send t "/build";
  Term.wait t (fun s -> Screen.has "/build" s && Screen.lacks "/plan " s);
  Term.send t Keys.enter;
  Term.wait t (Screen.lacks "⏸ plan");
  print_fact "build restores the wordless frame"
    (Screen.lacks "⏸ plan" (Term.screen t));
  [%expect
    {|
    plan chip on the top rule: true
    build restores the wordless frame: true|}]

(* A shell command runs on the executor and settles as one transcript block:
   the [!command] echo, then [⏺ Shell(command)] with its first output line as
   the [⎿] summary (03-composer.md §Shell mode). From the home this is the
   drop without a turn. *)
let%expect_test "a shell command settles as a transcript block" =
  Project.with_temp "next-shell-run" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "!echo spice-shell-ok";
  Term.wait t (Screen.has "echo spice-shell-ok");
  Term.send t Keys.enter;
  (* The settled [⎿] summary is the honest wait: the pinned RUNNING header
     already reads [⏺ Shell(…)] and the draft itself contains the output
     text, so waiting on either would race the settle. *)
  Term.wait t (Screen.has "⎿  spice-shell-ok");
  print_fact "user echo block"
    (Screen.has "!echo spice-shell-ok" (Term.screen t));
  print_fact "shell block header" (Screen.has "Shell(" (Term.screen t));
  print_fact "output line as summary"
    (Screen.has "⎿  spice-shell-ok" (Term.screen t));
  print_fact "shell mode exited after submit"
    (Screen.lacks "! shell" (Term.screen t));
  [%expect
    {|
    user echo block: true
    shell block header: true
    output line as summary: true
    shell mode exited after submit: true|}]
