(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] settings screen
   (doc/ui-design/03-ia-screens-overlays.md §Settings; phase 4 of
   doc/plans/tui-next-surfaces.md §Sequencing). The config/status/skills tabs
   run no turns, so there is no fake provider: the tests drive [/settings] on the
   real binary and golden the rendered screen.

   Goldens pin SPICE_REDUCED_MOTION=1 so the lockup settles static, and the
   readable 80x24 the spec mockups use. The harness pins
   SPICE_SANDBOX_MODE=danger-full-access (project.ml), so the sandbox-mode row
   carries its in-place danger caution. Config writes land in the user config
   file under the isolated XDG home; the write tests read it back. [/settings]
   Enter is always sent as a SEPARATE write from the command text: an atomic
   ["/settings\r"] is a known pty artifact. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* The right-arrow escape the shared Keys module does not carry. *)
let right = "\027[C"
let run ?env ?rows ?cols project f = Term.run ?env ?rows ?cols project f

(* The user config file the settings edits persist to: under the harness's
   isolated XDG config home ([<root>.xdg/config]), not the project tree. *)
let user_config project = Project.root project ^ ".xdg/config/spice/config.json"

let read_config project =
  let path = user_config project in
  if Sys.file_exists path then Util.read_file path else ""

let contains s needle = Util.contains s needle

(* Open the settings screen via [/settings], Enter sent separately, and wait for
   the config tab's first group header — proof the screen is up with facts. *)
let open_settings t =
  Term.send t "/settings";
  Term.wait t (Screen.has "/settings");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Model & reasoning")

(* The config tab opens with the four-tab row, the seven family groups windowed
   to the height, the [❯] cursor on the managed [Model] row, and — because the
   harness pins the dangerous sandbox mode — the in-place danger caution. *)
let%expect_test "settings opens on the config tab" =
  Project.with_temp "settings-open" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_settings t;
  print_fact "settings chip present" (Screen.has "settings" (Term.screen t));
  print_fact "tab row present"
    (Screen.has "config" (Term.screen t)
    && Screen.has "status" (Term.screen t)
    && Screen.has "usage" (Term.screen t)
    && Screen.has "skills" (Term.screen t));
  print_fact "model row cursor" (Screen.has "❯ Model" (Term.screen t));
  print_fact "danger caution shown"
    (Screen.has "no filesystem confinement" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|
    settings chip present: true
    tab row present: true
    model row cursor: true
    danger caution shown: true
    01 | ──  settings ─────────────────────────────────────────────────────────────env ──
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
    12 |     Permission mode          default
    13 |     Unattended permission    block
    14 |     Sandbox mode             danger-full-access  — no filesystem confinement
    15 |     Sandbox required         enforced
    16 |
    17 |   Context
    18 |     Auto compact             true
    19 |
    20 |   Instructions
    21 |     Global instructions      true
    22 |     Project instructions     true
    23 |     Claude.md instructions   true
    24 |   … +12 more |}]

(* [tab] switches to the status tab: a read-only fact sheet whose [version] and
   [permission] rows the config tab never shows. *)
let%expect_test "tab switches to the status fact sheet" =
  Project.with_temp "settings-status" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_settings t;
  Term.send t Keys.tab;
  Term.wait t (Screen.has "version");
  print_fact "status facts shown"
    (Screen.has "version" (Term.screen t)
    && Screen.has "permission" (Term.screen t)
    && Screen.has "sandbox" (Term.screen t));
  print_fact "config group gone"
    (Screen.lacks "Model & reasoning" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|
    status facts shown: true
    config group gone: true
    01 | ──  settings ───────────────────────────────────────────────────────────────────
    02 |
    03 |   config · status · usage · skills
    04 |
    05 |   version         dev
    06 |   session         none
    07 |   cwd             $PROJECT
    08 |   account         not connected · /login
    09 |   model           openai/gpt-5.5 · stable
    10 |   permission      default
    11 |   sandbox         danger-full-access
    12 |   trust           not enforced
    13 |   user config     $PROJECT.xdg/config/spice/con…
    14 |   project config  $PROJECT/.spice/config.json
    15 |
    16 |   c copy id · ←→ tab · esc back
    17 |
    18 |
    19 |
    20 |
    21 |
    22 |
    23 |
    24 | |}]

(* An enum row expands to the inline [●] radio on [→] and commits a Write_field
   the runtime persists (03-ia §Settings). The reasoning row is unset at launch
   (its default is the model's), so committing it adds [user] to the rule's
   sources fact and writes the key to the user config file. *)
let%expect_test "enum row expands to a radio and commits" =
  Project.with_temp "settings-enum" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_settings t;
  (* Model, Small model, Reasoning: two Downs land on the enum row. *)
  Term.send t Keys.down;
  Term.send t Keys.down;
  Term.wait t (Screen.has "❯ Reasoning");
  Term.send t right;
  (* The write reloads the facts; the rule's sources fact gains [user]. *)
  Term.wait t (Screen.has "user + env");
  print_fact "radio dot shown" (Screen.has "●" (Term.screen t));
  print_fact "sources fact gained user"
    (Screen.has "user + env" (Term.screen t));
  print_fact "reasoning written to user config"
    (contains (read_config project) "reasoning");
  Screen.print ~project (Term.screen t);
  [%expect
    {|
    radio dot shown: true
    sources fact gained user: true
    reasoning written to user config: true
    01 | ──  settings ──────────────────────────────────────────────────────user + env ──
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
    12 |     Permission mode          default
    13 |     Unattended permission    block
    14 |     Sandbox mode             danger-full-access  — no filesystem confinement
    15 |     Sandbox required         enforced
    16 |
    17 |   Context
    18 |     Auto compact             true
    19 |
    20 |   Instructions
    21 |     Global instructions      true
    22 |     Project instructions     true
    23 |     Claude.md instructions   true
    24 |   … +12 more |}]

(* A boolean row toggles on [↵] and persists. Thinking summaries defaults true;
   toggling writes [tui.thinking] to the user config. *)
let%expect_test "boolean row toggles and persists" =
  Project.with_temp "settings-bool" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_settings t;
  Term.send t Keys.down;
  Term.send t Keys.down;
  Term.send t Keys.down;
  Term.wait t (Screen.has "❯ Thinking summaries");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "user + env");
  (* The config JSON nests the key as ["tui": {"thinking": false}]. *)
  print_fact "tui.thinking written to user config"
    (contains (read_config project) "thinking"
    && contains (read_config project) "false");
  [%expect {| tui.thinking written to user config: true |}]

(* The skills tab lists the discovered skills and toggles one on [↵], writing
   [skills.disabled] to the user config; the toggled row's state reads
   [disabled]. *)
let%expect_test "skills tab lists and toggles a skill" =
  Project.with_temp "settings-skills" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_settings t;
  Term.send t Keys.tab;
  Term.send t Keys.tab;
  Term.send t Keys.tab;
  Term.wait t (Screen.has "t sort");
  print_fact "skills tab up" (Screen.has "t sort" (Term.screen t));
  Term.send t Keys.enter;
  Term.wait t (Screen.has "disabled");
  print_fact "row now disabled" (Screen.has "disabled" (Term.screen t));
  (* The config JSON nests the key as ["skills": {"disabled": [...]}]. *)
  print_fact "skills.disabled written"
    (contains (read_config project) "disabled"
    && contains (read_config project) "ocaml-benchmarking");
  Screen.print ~project (Term.screen t);
  [%expect
    {|
    skills tab up: true
    row now disabled: true
    skills.disabled written: true
    01 | ──  settings ──────────────────────────────────────────────────────~41121 tok ──
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
    20 |   ↵ toggle · t sort · ↑↓ move · ←→ tab · / filter · esc back
    21 |
    22 |
    23 |
    24 | |}]

(* The [/] filter narrows the active tab's rows (03-ia §The filter law): typing
   [sandbox] keeps the two sandbox rows and drops the rest. Esc clears the filter
   before it exits. *)
let%expect_test "filter narrows the config rows" =
  Project.with_temp "settings-filter" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_settings t;
  Term.send t "/";
  Term.send t "sandbox";
  Term.wait t (fun s ->
      Screen.has "Sandbox mode" s && Screen.lacks "Reasoning" s);
  print_fact "sandbox rows kept"
    (Screen.has "Sandbox mode" (Term.screen t)
    && Screen.has "Sandbox required" (Term.screen t));
  print_fact "non-matching rows dropped"
    (Screen.lacks "Reasoning" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Reasoning");
  print_fact "esc cleared the filter" (Screen.has "Reasoning" (Term.screen t));
  [%expect
    {|
    sandbox rows kept: true
    non-matching rows dropped: true
    esc cleared the filter: true |}]

(* The esc ladder: esc clears an open filter, a second esc closes the screen and
   restores the composer with its draft untouched. *)
let%expect_test "esc closes the screen after clearing the filter" =
  Project.with_temp "settings-esc" @@ fun project ->
  run project ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  open_settings t;
  Term.send t "/";
  Term.send t "sandbox";
  Term.wait t (Screen.lacks "Reasoning");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Reasoning");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "message spice");
  print_fact "composer restored" (Screen.has "message spice" (Term.screen t));
  print_fact "screen chrome gone"
    (Screen.lacks "Model & reasoning" (Term.screen t));
  [%expect {|
    composer restored: true
    screen chrome gone: true |}]

[%%run_tests "spice.tui-next.settings"]
