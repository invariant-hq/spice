(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the slash palette and command dispatch
   (doc/ui-design/03-composer.md §Slash palette, 10-commands.md,
   doc/plans/tui-next-composer.md). No turns run, so like the home tests these
   need only the real spice binary. Every cataloged command is backed end to
   end, and ↵ never sends the draft while the list is up. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact
let run ?env ?rows ?cols project f = Term.run ?env ?rows ?cols project f

(* Typing "/" on the empty draft opens the palette on the whole catalog: the
   five-slot window shows the head rows in display order with the seam row
   counting the rest. *)
let%expect_test "slash opens the palette on the catalog" =
  Project.with_temp "next-palette-open" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/";
  Term.wait t (Screen.has "/model");
  print_fact "clear row" (Screen.has "/clear" (Term.screen t));
  print_fact "fork row" (Screen.has "/fork" (Term.screen t));
  print_fact "model row" (Screen.has "/model" (Term.screen t));
  [%expect {|
    clear row: true
    fork row: true
    model row: true|}]

(* Each keystroke narrows the rows (the composer text IS the filter); a filter
   with no match shows the note row; backspacing past the "/" closes the
   palette entirely. *)
let%expect_test "filtering narrows and backspace past the slash closes" =
  Project.with_temp "next-palette-filter" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/q";
  Term.wait t (fun s -> Screen.has "/quit" s && Screen.lacks "/model" s);
  print_fact "narrowed to quit" (Screen.lacks "/model" (Term.screen t));
  Term.send t "zz";
  Term.wait t (Screen.has "no matching commands");
  print_fact "empty filter notes"
    (Screen.has "no matching commands" (Term.screen t));
  Term.send t Keys.backspace;
  Term.send t Keys.backspace;
  Term.send t Keys.backspace;
  Term.wait t (fun s -> Screen.has "/model" s && Screen.has "/fork" s);
  Term.send t Keys.backspace;
  Term.send t Keys.backspace;
  Term.wait t (Screen.lacks "/model");
  print_fact "closed once the slash is gone"
    (Screen.lacks "/model" (Term.screen t));
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
  [%expect {|
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

(* /verbose flips the ctrl+o expand lens through the palette: honest flash on
   the home stage (nothing to expand — ctrl+o is chat-gated for the same
   reason), then in chat the echo plus the event record, toggling both ways.
   The chat is entered via a shell command, so no provider runs. *)
let%expect_test "verbose toggles the expand lens with a record" =
  Project.with_temp "next-verbose" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "/verbose";
  Term.wait t (fun s -> Screen.has "/verbose" s && Screen.lacks "/thinking" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "no tool output to expand yet");
  print_fact "home stage flashes honestly"
    (Screen.has "no tool output to expand yet" (Term.screen t));
  Term.send t "!echo drop-to-chat";
  Term.wait t (Screen.has "echo drop-to-chat");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "⎿  drop-to-chat");
  Term.send t "/verbose";
  Term.wait t (fun s -> Screen.has "/verbose" s && Screen.lacks "/thinking" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "tool output expanded");
  print_fact "echo recorded" (Screen.has "❯ /verbose" (Term.screen t));
  print_fact "expanded event recorded"
    (Screen.has "tool output expanded" (Term.screen t));
  Term.send t "/verbose";
  Term.wait t (fun s -> Screen.has "/verbose" s && Screen.lacks "/thinking" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "tool output collapsed");
  print_fact "collapse event recorded"
    (Screen.has "tool output collapsed" (Term.screen t));
  [%expect
    {|
    home stage flashes honestly: true
    echo recorded: true
    expanded event recorded: true
    collapse event recorded: true|}]

(* [--sandbox read-only] overrides the configured mode for the run
   (Startup sandbox → Sandbox.resolve ?flag): the home stage's warning line
   stays quiet (the harness config's danger-full-access is overridden), the
   record names the flag origin, and a worktree write is actually refused —
   the flag reaches the enforcement, not just the label. *)
let%expect_test "the sandbox flag overrides the configured mode" =
  Project.with_temp "next-sandbox-flag" @@ fun project ->
  Term.run project ~env:reduced_motion ~rows:24 ~cols:80
    ~args:[ "--sandbox"; "read-only" ]
  @@ fun t ->
  Term.wait t (Screen.has "dune:");
  print_fact "config danger warning overridden"
    (Screen.lacks "danger-full-access" (Term.screen t));
  Term.send t "!touch sandbox-probe.txt";
  Term.wait t (Screen.has "touch sandbox-probe.txt");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Operation not permitted");
  print_fact "record names the flag origin"
    (Screen.has "read-only (flag)" (Term.screen t));
  print_fact "write refused under the flag"
    (Screen.has "Operation not permitted" (Term.screen t));
  [%expect
    {|
    config danger warning overridden: true
    record names the flag origin: true
    write refused under the flag: true|}]
