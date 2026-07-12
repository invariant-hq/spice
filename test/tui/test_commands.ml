(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The slash palette and command dispatch (doc/ui-design/03-composer.md §Slash
   palette, 10-commands.md), re-expressed as full-frame goldens: opening the
   catalog, filtering, esc closing, the mode-switch chips, and a shell drop. No
   turns run here — the palette and the home-stage shell drop need no provider.

   The ctrl+o verbose lens lives in test_input (suite-coverage's regression
   guard). *)

(* Typing "/" on the empty draft opens the palette on the whole catalog: the
   five-slot window shows the head rows in display order with the seam row
   counting the rest. *)
let%expect_test "slash opens the palette on the catalog" =
  Tui.run ~name:"cmd-palette-open" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/";
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
12 |           ❯ /clear     Start a new session with empty context; previo…
13 |             /fork      Fork current session
14 |             /compact   Free up context by summarizing the conversatio…
15 |             /model     Select model and effort
16 |             ↓ 15 more
17 |           ────────────────────────────────────────────────────────────
18 |           ❯ /
19 |           ────────────────────────────────────────────────────────────
20 |
21 |                      dune       ✗ · diagnostics unavailable
22 |                      account    none — /login to connect
23 |
24 |                       sandbox: danger-full-access (config)|}]

(* Each keystroke narrows the rows (the composer text IS the filter): a
   distinctive prefix leaves the one matching command. *)
let%expect_test "filtering narrows the palette to the match" =
  Tui.run ~name:"cmd-palette-filter" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/q";
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
12 |           ❯ /quit  Exit Spice
13 |           ────────────────────────────────────────────────────────────
14 |           ❯ /q
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |                      account    none — /login to connect
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* A filter matching nothing shows the note row rather than an empty list. *)
let%expect_test "an unmatched filter shows the note row" =
  Tui.run ~name:"cmd-palette-nomatch" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/qzz";
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
12 |             no matching commands
13 |           ────────────────────────────────────────────────────────────
14 |           ❯ /qzz
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |                      account    none — /login to connect
19 |
20 |                       sandbox: danger-full-access (config)
21 |
22 |
23 |
24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗|}]

(* Esc is the ladder's first rung while the list is open: it closes the palette
   and clears the slash input, restoring the idle placeholder. *)
let%expect_test "esc closes the palette and clears the input" =
  Tui.run ~name:"cmd-palette-esc" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/q";
  Tui.settle t;
  Tui.keys t Key.escape;
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

(* /plan colours the composer frame with its chip and records nothing on the home
   stage (the chip is the record there). *)
let%expect_test "plan mode dresses the composer frame" =
  Tui.run ~name:"cmd-mode-plan" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/plan";
  Tui.settle t;
  Tui.enter t;
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
12 |            ⏸ plan ────────────────────────────────────────────────────
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

(* /build restores the wordless gray frame after /plan. *)
let%expect_test "build mode restores the wordless frame" =
  Tui.run ~name:"cmd-mode-build" @@ fun t ->
  Tui.settle t;
  Tui.keys t "/plan";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "/build";
  Tui.settle t;
  Tui.enter t;
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

(* A shell command runs on the executor and settles as one transcript block: the
   [!command] echo, then [⏺ Shell(command)] with its first output line as the
   [⎿] summary (03-composer.md §Shell mode). From the home this is the drop
   without a turn. *)
let%expect_test "a shell command settles as a transcript block" =
  Tui.run ~name:"cmd-shell" @@ fun t ->
  Tui.settle t;
  Tui.keys t "!echo spice-shell-ok";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ !echo spice-shell-ok
07 |
08 | ⏺ Shell(echo spice-shell-ok)
09 |   ⎿  spice-shell-ok
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

(* A per-run sandbox flag wins over the environment-backed config. The banner
   and home fact both name the effective mode and its flag provenance, so the
   override is proved before any command executes. *)
let%expect_test "the sandbox flag overrides the configured mode" =
  Tui.run ~name:"cmd-sandbox-flag" ~sandbox:`Read_only @@ fun t ->
  Tui.settle t;
  Tui.keys t "!printf sandbox-flag-ok";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: read-only (flag) · all reads
05 |
06 | ❯ !printf sandbox-flag-ok
07 |
08 | ⏺ Shell(printf sandbox-flag-ok)
09 |   ⎿  sandbox-flag-ok
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

let seed_invalid_shell project =
  Project.write_scratch project "config/spice/config.json"
    {|{"shell":"bad\u0000shell"}|}

let%expect_test "a shell runtime exception settles busy state" =
  Tui.run ~name:"cmd-shell-runtime-exception" ~seed:seed_invalid_shell
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "!printf never-runs";
  Tui.enter t;
  Tui.settle t;
  Printf.printf "runtime failure visible: %b\n"
    (String.includes ~affix:"shell must not contain NUL" (Tui.screen t));
  Tui.keys t "!printf admitted-again";
  Tui.enter t;
  Tui.settle t;
  Printf.printf "second shell admitted: %b\n"
    (String.includes ~affix:"printf admitted-again" (Tui.screen t));
  [%expect
    {|
    runtime failure visible: true
    second shell admitted: true|}]

let shell_recovery_script =
  [
    Provider_script.message ~expect:[ "continue after shell" ]
      ~id:"shell-recovery" "interaction recovered";
  ]

let%expect_test "invalid pasted shell input never acquires busy state" =
  Tui.run ~name:"cmd-shell-invalid-paste" ~provider:shell_recovery_script
  @@ fun t ->
  Tui.settle t;
  Tui.paste t "!\000";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Printf.printf "validation visible: %b\n"
    (String.includes ~affix:"shell command must not contain NUL" (Tui.screen t));
  Tui.keys t "continue after shell";
  Tui.enter t;
  Tui.settle t;
  Printf.printf "subsequent prompt completed: %b\n"
    (String.includes ~affix:"interaction recovered" (Tui.screen t));
  [%expect
    {|
    validation visible: true
    subsequent prompt completed: true|}]

[%%run_tests "spice.tui.commands"]
