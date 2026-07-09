(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the composer itself (doc/ui-design/03-composer.md,
   doc/plans/tui-next-composer.md): multiline growth, large-paste collapse, the
   esc/ctrl+c ladder with prompt-history recall, the "?" help sheet, and the
   shell rung. No turns run, so like the palette tests these need only the real
   spice binary; every assertion waits on a real screen marker. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact
let run ?env ?rows ?cols project f = Term.run ?env ?rows ?cols project f

(* A hard newline (shift+enter / ctrl+j) grows the frame in place; the "❯ "
   marker sits on the first visual row only, wrapped and hard-newline rows
   aligning under the text. The harness sends no shift+enter, so this uses the
   linefeed the composer binds to Newline (the byte ctrl+j emits). *)
let%expect_test "a hard newline grows the frame, marker on the first row" =
  Project.with_temp "next-composer-multiline" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "line one";
  Term.wait t (Screen.has "line one");
  Term.send t Keys.linefeed;
  Term.send t "line two";
  Term.wait t (Screen.has "line two");
  print_fact "marker on the first row" (Screen.has "❯ line one" (Term.screen t));
  print_fact "second line grew the frame"
    (Screen.has "line two" (Term.screen t));
  print_fact "marker absent on the second row"
    (Screen.lacks "❯ line two" (Term.screen t));
  [%expect
    {|
    marker on the first row: true
    second line grew the frame: true
    marker absent on the second row: true|}]

(* A paste of three or more lines collapses to an atomic [Pasted text #N +M
   lines] chunk (one paste, so #1; three newlines, so +3); the payload never
   reaches the visible draft. A single backspace deletes the whole chunk, so the
   idle placeholder returns. *)
let%expect_test "a large paste collapses and backspace deletes the chunk" =
  Project.with_temp "next-composer-paste" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t (Keys.bracketed_paste "alpha\nbeta\ngamma\ndelta");
  Term.wait t (Screen.has "[Pasted text #1 +3 lines]");
  print_fact "chunk shown"
    (Screen.has "[Pasted text #1 +3 lines]" (Term.screen t));
  print_fact "payload hidden" (Screen.lacks "alpha" (Term.screen t));
  Term.send t Keys.backspace;
  Term.wait t (Screen.lacks "[Pasted text");
  print_fact "chunk deleted whole" (Screen.lacks "[Pasted text" (Term.screen t));
  print_fact "draft empty" (Screen.has "message spice" (Term.screen t));
  [%expect
    {|
    chunk shown: true
    payload hidden: true
    chunk deleted whole: true
    draft empty: true|}]

(* The esc ladder's clear rung is two-stage: the first press arms the footer
   notice, the second saves the draft to prompt history and clears it. Up then
   recalls the saved draft (the discard-to-history remember). *)
let%expect_test "esc clears a non-empty draft in two stages, up recalls it" =
  Project.with_temp "next-composer-esc-clear" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "draft to clear";
  Term.wait t (Screen.has "draft to clear");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Esc again to clear");
  print_fact "first esc arms the notice"
    (Screen.has "Esc again to clear" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (fun s ->
      Screen.lacks "draft to clear" s && Screen.has "message spice" s);
  print_fact "second esc clears the draft"
    (Screen.lacks "draft to clear" (Term.screen t));
  Term.send t Keys.up;
  Term.wait t (Screen.has "draft to clear");
  print_fact "up recalls the saved draft"
    (Screen.has "draft to clear" (Term.screen t));
  [%expect
    {|
    first esc arms the notice: true
    second esc clears the draft: true
    up recalls the saved draft: true|}]

(* ctrl+c on a non-empty draft is the one-press discard-to-history: the draft
   clears immediately, and up recalls it. *)
let%expect_test "ctrl+c discards a non-empty draft in one press, up recalls it"
    =
  Project.with_temp "next-composer-ctrlc" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "discard me";
  Term.wait t (Screen.has "discard me");
  Term.send t Keys.ctrl_c;
  Term.wait t (fun s ->
      Screen.lacks "discard me" s && Screen.has "message spice" s);
  print_fact "ctrl+c cleared the draft"
    (Screen.lacks "discard me" (Term.screen t));
  Term.send t Keys.up;
  Term.wait t (Screen.has "discard me");
  print_fact "up recalls the discarded draft"
    (Screen.has "discard me" (Term.screen t));
  [%expect
    {|
    ctrl+c cleared the draft: true
    up recalls the discarded draft: true|}]

(* "?" on an empty draft toggles the shortcuts sheet and is never typed into the
   draft (the idle placeholder stays, so the buffer is still empty); esc closes
   the sheet — the rung above shell-exit. *)
let%expect_test "? opens the help sheet without typing into the draft" =
  Project.with_temp "next-composer-help" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "?";
  Term.wait t (Screen.has "file paths");
  print_fact "help sheet open" (Screen.has "file paths" (Term.screen t));
  print_fact "draft still empty" (Screen.has "message spice" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (Screen.lacks "file paths");
  print_fact "esc closes the sheet" (Screen.lacks "file paths" (Term.screen t));
  [%expect
    {|
    help sheet open: true
    draft still empty: true
    esc closes the sheet: true|}]

(* A leading "!" enters shell mode; esc exits it by clearing the "!" draft, so
   the ❯ marker and idle placeholder return. Cosmetic note pinned, not fixed:
   the draft keeps its "!" verbatim beside the shell "!" marker, so the row
   reads with two "!" until the wave-4 executor consumes the prefix. *)
let%expect_test "esc exits shell mode by clearing the ! draft" =
  Project.with_temp "next-composer-shell-exit" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "!ls";
  Term.wait t (Screen.has "!ls");
  print_fact "shell draft shown" (Screen.has "!ls" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (fun s -> Screen.lacks "!ls" s && Screen.has "message spice" s);
  print_fact "esc cleared the shell draft" (Screen.lacks "!ls" (Term.screen t));
  print_fact "idle placeholder back"
    (Screen.has "message spice" (Term.screen t));
  [%expect
    {|
    shell draft shown: true
    esc cleared the shell draft: true
    idle placeholder back: true|}]
