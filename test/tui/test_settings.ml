(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The settings screen (doc/ui-design/03-ia-screens-overlays.md §Settings),
   re-expressed as full-frame goldens: the config tab, the status fact sheet, an
   enum row's radio commit, a boolean toggle, the skills tab, and the filter/esc
   ladder. No turns run. The harness pins SPICE_SANDBOX_MODE=danger-full-access,
   so the sandbox row carries its in-place danger caution. Config edits persist to
   the user config under the isolated XDG home; the write tests read it back. *)

(* The right-arrow escape the shared Keys module does not carry. *)
let right = "\027[C"

let read_config t =
  let path = Project.scratch (Tui.project t) "config/spice/config.json" in
  if Sys.file_exists path then Project.read_path path else ""

(* Open the settings screen via [/settings], Enter run through the palette. *)
let open_settings t =
  Tui.keys t "/settings";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t

let overflow_marker screen =
  screen |> String.split_on_char '\n'
  |> List.find_opt (String.includes ~affix:"… +")
  |> Option.map String.trim
  |> Option.value ~default:"all"

(* The screen chrome pins its hint row while the config window spends the
   remaining height on selectable rows, group headers, inter-group gaps, and —
   when needed — the overflow marker itself. The seven QA heights cover every
   boundary where a newly-affordable group changes the hidden-row count. *)
let%expect_test
    "config height sweep keeps its footer and reports every hidden row" =
  Tui.run ~name:"settings-height-sweep" ~size:(120, 24) @@ fun t ->
  Tui.settle t;
  open_settings t;
  List.iter
    (fun height ->
      Tui.resize t ~width:120 ~height;
      Tui.settle t;
      let screen = Tui.screen t in
      Printf.printf "%d | footer=%b | %s | web-search=%b\n" height
        (Screen.contains screen "↵ edit")
        (overflow_marker screen)
        (Screen.contains screen "Web search"))
    [ 24; 28; 30; 32; 36; 40; 44 ];
  [%expect
    {|
    24 | footer=true | … +14 more | web-search=false
    28 | footer=true | … +12 more | web-search=false
    30 | footer=true | … +10 more | web-search=false
    32 | footer=true | … +8 more | web-search=false
    36 | footer=true | … +6 more | web-search=false
    40 | footer=true | … +4 more | web-search=false
    44 | footer=true | all | web-search=true |}]

(* The config tab opens with the four-tab row, the family groups windowed to the
   height, the [❯] cursor on the managed Model row, and — because the harness
   pins the dangerous sandbox mode — the in-place danger caution. *)
let%expect_test "settings opens on the config tab" =
  Tui.run ~name:"settings-open" @@ fun t ->
  Tui.settle t;
  open_settings t;
  Tui.print t;
  [%expect
    {|01 | ──  settings ─────────────────────────────────────────────────────────────env ──
02 |
03 |   config · status · usage · skills
04 |
05 |   Model & reasoning
06 |   ❯ Model                    openai/gpt-5.5
07 |     Small model              —
08 |     Reasoning                —
09 |     Thinking summaries       true
10 |
11 |   Permissions & sandbox
12 |     Unattended permission    block
13 |     Sandbox mode             danger-full-access  — no filesystem confinement
14 |     Sandbox required         enforced
15 |     Sandbox reads            all
16 |
17 |   Context
18 |     Auto compact             true
19 |
20 |   Instructions
21 |     Global instructions      true
22 |   … +14 more
23 |
24 |   ↵ edit · ↑↓ move · ←→ tab/value · / filter · esc back|}]

(* [tab] switches to the status tab: a read-only fact sheet whose version and
   permission rows the config tab never shows. *)
let%expect_test "tab switches to the status fact sheet" =
  Tui.run ~name:"settings-status" @@ fun t ->
  Tui.settle t;
  open_settings t;
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ──  settings ───────────────────────────────────────────────────────────────────
02 |
03 |   config · status · usage · skills
04 |
05 |   version            dev
06 |   session            none
07 |   cwd                $PROJECT
08 |   account            not connected · /login
09 |   model              openai/gpt-5.5 · stable
10 |   permission review  default
11 |   sandbox            danger-full-access
12 |   trust              trusted · $PROJECT
13 |   user config        $PROJECT.xdg/config/spice/…
14 |   project config     $PROJECT/.spice/config.json
15 |
16 |
17 |
18 |
19 |
20 |
21 |
22 |
23 |
24 |   c copy id · ←→ tab · esc back|}]

(* An enum row expands to the inline [●] radio on [→] and commits a Write_field
   the runtime persists. The Reasoning row is unset at launch, so committing it
   adds [user] to the rule's sources fact and writes the key to the user config. *)
let%expect_test "enum row expands to a radio and commits" =
  Tui.run ~name:"settings-enum" @@ fun t ->
  Tui.settle t;
  open_settings t;
  (* Model, Small model, Reasoning: two Downs land on the enum row. *)
  Tui.keys t Key.down;
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.keys t right;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ──  settings ──────────────────────────────────────────────────────user + env ──
02 |
03 |   config · status · usage · skills
04 |
05 |   Model & reasoning
06 |     Model                    openai/gpt-5.5
07 |     Small model              —
08 |   ❯ Reasoning                none  ● minimal  low  medium  high  xhigh  max
09 |     Thinking summaries       true
10 |
11 |   Permissions & sandbox
12 |     Unattended permission    block
13 |     Sandbox mode             danger-full-access  — no filesystem confinement
14 |     Sandbox required         enforced
15 |     Sandbox reads            all
16 |
17 |   Context
18 |     Auto compact             true
19 |
20 |   Instructions
21 |     Global instructions      true
22 |   … +14 more
23 |
24 |   ←→ choose · esc close|}];
  print_string
    (Printf.sprintf "reasoning written: %b\n"
       (Screen.contains (read_config t) "reasoning"));
  [%expect {| reasoning written: true |}]

(* A boolean row toggles on [↵] and persists. Thinking summaries defaults true;
   toggling writes [tui.thinking] to the user config. *)
let%expect_test "boolean row toggles and persists" =
  Tui.run ~name:"settings-bool" @@ fun t ->
  Tui.settle t;
  open_settings t;
  Tui.keys t Key.down;
  Tui.keys t Key.down;
  Tui.keys t Key.down;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  print_string
    (Printf.sprintf "thinking written: %b\nfalse written: %b\n"
       (Screen.contains (read_config t) "thinking")
       (Screen.contains (read_config t) "false"));
  [%expect {|thinking written: true
false written: true|}]

(* The skills tab lists the discovered builtin skills and toggles one on [↵],
   writing [skills.disabled] to the user config; the toggled row reads
   [disabled]. The token counts are catalog data, deterministic per build. *)
let%expect_test "skills tab lists and toggles a skill" =
  Tui.run ~name:"settings-skills" @@ fun t ->
  Tui.settle t;
  open_settings t;
  Tui.keys t Key.tab;
  Tui.keys t Key.tab;
  Tui.keys t Key.tab;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ──  settings ──────────────────────────────────────────────────────~41121 tok ──
02 |
03 |   config · status · usage · skills
04 |
05 |   ❯ ocaml-benchmarking                            disabled  builtin   —
06 |     config_disabled
07 |     ocaml-concurrency                           active    builtin   ~2,401 tok
08 |     ocaml-debug                                 active    builtin   ~1,929 tok
09 |     ocaml-doc                                   active    builtin   ~4,402 tok
10 |     ocaml-dune                                  active    builtin   ~3,642 tok
11 |     ocaml-ffi                                   active    builtin   ~4,077 tok
12 |     ocaml-library-design                        active    builtin   ~4,420 tok
13 |     ocaml-module-design                         active    builtin   ~3,927 tok
14 |     ocaml-perf                                  active    builtin   ~3,268 tok
15 |     ocaml-project-setup                         active    builtin   ~1,639 tok
16 |     ocaml-release                               active    builtin   ~2,649 tok
17 |     ocaml-testing                               active    builtin   ~3,255 tok
18 |     ocaml-tidy                                  active    builtin   ~3,948 tok
19 |
20 |
21 |
22 |
23 |
24 |   ↵ toggle · t sort · ↑↓ move · ←→ tab · / filter · esc back|}];
  print_string
    (Printf.sprintf "disabled written: %b\n"
       (Screen.contains (read_config t) "disabled"));
  [%expect {| disabled written: true |}]

(* The [/] filter narrows the active tab's rows: [sandbox] keeps the two sandbox
   rows and drops the rest. *)
let%expect_test "filter narrows the config rows" =
  Tui.run ~name:"settings-filter" @@ fun t ->
  Tui.settle t;
  open_settings t;
  Tui.keys t "/";
  Tui.keys t "sandbox";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ──  settings ─────────────────────────────────────────────────────────────env ──
02 |   /sandbox  3 matches
03 |
04 |   config · status · usage · skills
05 |
06 |   Permissions & sandbox
07 |   ❯ Sandbox mode             danger-full-access  — no filesystem confinement
08 |     Sandbox required         enforced
09 |     Sandbox reads            all
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
21 |
22 |
23 |
24 |   ↑↓ select · esc clear filter|}]

(* The esc ladder: esc clears an open filter, a second esc closes the screen and
   restores the composer. *)
let%expect_test "esc clears the filter then closes the screen" =
  Tui.run ~name:"settings-esc" @@ fun t ->
  Tui.settle t;
  open_settings t;
  Tui.keys t "/";
  Tui.keys t "sandbox";
  Tui.settle t;
  Tui.keys t Key.escape;
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

[%%run_tests "spice.tui.settings"]
