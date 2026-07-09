(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the unified [@] completion (doc/ui-design/03-composer.md
   §File completion open, doc/plans/tui-next-composer.md). Each test writes a real
   file tree into the temp project so the lazy Load_dir enumeration has known
   content, then drives the list through the live app wiring. No turns run, so
   like the palette tests these need only the real spice binary; every assertion
   waits on a real screen marker. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact
let run ?env ?rows ?cols project f = Term.run ?env ?rows ?cols project f

(* A small workspace: one directory with a nested subdirectory, a top-level
   file, and an ignored [node_modules] that must never surface. *)
let seed project =
  Project.write project "lib/foo.ml" "let foo = 1\n";
  Project.write project "lib/sub/bar.ml" "let bar = 2\n";
  Project.write project "node_modules/junk.js" "module.exports = 0\n";
  Project.write project "readme.md" "# fixture\n"

(* Typing "@" on the empty draft opens the unified list above the frame: the
   directory rows carry a trailing "/", every row a "+" glyph, and the ignored
   [node_modules] directory is absent. *)
let%expect_test "@ opens the list, dirs carry a trailing slash, ignores hidden"
    =
  Project.with_temp "next-mention-open" @@ fun project ->
  seed project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "@";
  Term.wait t (Screen.has "+ lib/");
  print_fact "directory row with trailing slash"
    (Screen.has "+ lib/" (Term.screen t));
  print_fact "top-level file row" (Screen.has "+ readme.md" (Term.screen t));
  print_fact "ignored directory hidden"
    (Screen.lacks "node_modules" (Term.screen t));
  [%expect
    {|
    directory row with trailing slash: true
    top-level file row: true
    ignored directory hidden: true|}]

(* The [@]-token after the "@" is the filter (the text-is-the-filter law); a
   query that matches nothing shows the note row. *)
let%expect_test "typing after @ filters, no match shows the note" =
  Project.with_temp "next-mention-filter" @@ fun project ->
  seed project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "@";
  Term.wait t (Screen.has "+ lib/");
  Term.send t "zzz";
  Term.wait t (Screen.has "no matching files");
  print_fact "no match note" (Screen.has "no matching files" (Term.screen t));
  print_fact "rows gone" (Screen.lacks "+ lib/" (Term.screen t));
  [%expect {|
    no match note: true
    rows gone: true|}]

(* Tab on the selected directory descends into it: its children load and inline
   below it, and the list stays open. *)
let%expect_test
    "tab descends into a directory, children appear, list stays open" =
  Project.with_temp "next-mention-descend" @@ fun project ->
  seed project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "@";
  Term.wait t (Screen.has "+ lib/");
  Term.send t Keys.tab;
  Term.wait t (Screen.has "lib/foo.ml");
  print_fact "child file appeared" (Screen.has "lib/foo.ml" (Term.screen t));
  print_fact "nested directory appeared" (Screen.has "lib/sub/" (Term.screen t));
  print_fact "list still open" (Screen.has "+ lib/" (Term.screen t));
  [%expect
    {|
    child file appeared: true
    nested directory appeared: true
    list still open: true|}]

(* ↵ on a selected file inserts it as an atomic reference and closes the list.
   The "+" glyph belongs to the list row alone, so its absence proves the list
   closed. The atom keeps its "@" trigger — [@readme.md], quoted [@"a b.md"]
   for whitespace (03-composer.md §File completion). *)
let%expect_test "enter on a file inserts the ref and closes the list" =
  Project.with_temp "next-mention-insert" @@ fun project ->
  seed project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "@";
  Term.wait t (Screen.has "+ lib/");
  Term.send t "readme";
  Term.wait t (fun s -> Screen.has "+ readme.md" s && Screen.lacks "+ lib/" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.lacks "+ readme.md");
  print_fact "list closed" (Screen.lacks "+ readme.md" (Term.screen t));
  print_fact "ref label in the draft" (Screen.has "readme.md" (Term.screen t));
  print_fact "atom keeps the @ trigger (spec)"
    (Screen.has "@readme.md" (Term.screen t));
  [%expect
    {|
    list closed: true
    ref label in the draft: true
    atom keeps the @ trigger (spec): true|}]

(* Esc while the list is open closes it and LEAVES the literal [@]-token in the
   draft (03-composer.md §File completion) — unlike the palette's esc, which
   clears its slash input. *)
let%expect_test "esc closes the list and leaves the @-token" =
  Project.with_temp "next-mention-esc" @@ fun project ->
  seed project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "@lib";
  Term.wait t (Screen.has "+ lib/");
  Term.send t Keys.escape;
  Term.wait t (fun s -> Screen.lacks "+ lib/" s && Screen.has "@lib" s);
  print_fact "list closed" (Screen.lacks "+ lib/" (Term.screen t));
  print_fact "@-token left in the draft" (Screen.has "@lib" (Term.screen t));
  [%expect {|
    list closed: true
    @-token left in the draft: true|}]

(* Backspacing the token away (deleting the "@") closes the list, the draft
   empty again — this matches the spec's "backspacing past the trigger closes". *)
let%expect_test "backspacing the token away closes the list" =
  Project.with_temp "next-mention-backspace" @@ fun project ->
  seed project;
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "@";
  Term.wait t (Screen.has "+ lib/");
  Term.send t Keys.backspace;
  Term.wait t (fun s -> Screen.lacks "+ lib/" s && Screen.has "message spice" s);
  print_fact "list closed" (Screen.lacks "+ lib/" (Term.screen t));
  print_fact "draft empty" (Screen.has "message spice" (Term.screen t));
  [%expect {|
    list closed: true
    draft empty: true|}]
