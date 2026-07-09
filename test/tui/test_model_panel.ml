(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] model + effort panel
   (doc/ui-design/05-overlays-pickers.md §Model picker in the 03-ia panel shell;
   phase 5 of doc/plans/tui-next-surfaces.md §Sequencing). The panel runs no
   turns — it reads the pure catalog and writes the user config — so there is no
   fake provider: the tests drive [/model] (and the settings model row) on the
   real binary and golden the rendered panel.

   The env authenticates OpenAI ([OPENAI_API_KEY]) so the configured
   [openai/gpt-5.5] renders as a normal, current row with its [✓] and a live
   effort line, while Anthropic/Google/DeepSeek stay locked — the mute-and-show
   rows the panel draws with [log in to use]. Goldens pin SPICE_REDUCED_MOTION=1
   for a static lockup and the readable 80x24 the spec mockups use. Config writes
   land in the user config under the isolated XDG home; the select test reads it
   back. Enter is always sent as a SEPARATE write from the command text (the
   atomic-enter pty artifact). *)

open Tui_harness

(* OpenAI authenticated (its models render normally, the current one carries ✓);
   the other providers stay locked for the mute-and-show rows. *)
let env = [ ("SPICE_REDUCED_MOTION", "1"); ("OPENAI_API_KEY", "test-key") ]
let print_fact = Util.print_fact

(* The right-arrow escape the shared Keys module does not carry. *)
let right = "\027[C"
let run ?rows ?cols project f = Term.run ~env ?rows ?cols project f
let user_config project = Project.root project ^ ".xdg/config/spice/config.json"

let read_config project =
  let path = user_config project in
  if Sys.file_exists path then Util.read_file path else ""

let contains s needle = Util.contains s needle

(* Open the model panel via [/model] from the home stage: the palette filters to
   the command, Enter runs it (Enter sent separately), and we wait for the
   hoisted default row — proof the catalog facts have arrived. *)
let open_model t =
  Term.send t "/model";
  Term.wait t (Screen.has "/model");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Default (recommended)")

(* The panel opens with the [model] chip, the provider groups (OpenAI unlocked,
   Anthropic locked), the current model's [✓], and the highlighted default's
   effort line. *)
let%expect_test "model panel opens grouped, with the current mark and effort" =
  Project.with_temp "model-open" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  open_model t;
  print_fact "model chip present" (Screen.has "model" (Term.screen t));
  print_fact "openai group present" (Screen.has "OpenAI" (Term.screen t));
  print_fact "hoisted default row"
    (Screen.has "Default (recommended)" (Term.screen t));
  print_fact "current mark present" (Screen.has "✓" (Term.screen t));
  print_fact "effort line present" (Screen.has "Medium effort" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|
    model chip present: true
    openai group present: true
    hoisted default row: true
    current mark present: true
    effort line present: true
    01 |
    02 |
    03 |
    04 |
    05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
    06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying spice this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
    14 |    model
    15 |
    16 |   ❯ Default (recommended)  GPT-5.5 · Default · 1.05M context · Best for eve… ✓
    17 |     OpenAI
    18 |     GPT-5.5         Default · 1.05M context · Best for everyday, complex tasks
    19 |     GPT-5.4                   1.05M context · Best for everyday, complex tasks
    20 |   ↓ 29 more
    21 |
    22 |   ◐ Medium effort (default)  ← → to adjust
    23 |
    24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close |}]

(* Type-to-filter narrows over name/provider/selector (03-ia §The filter law):
   [opus] keeps the locked Anthropic Opus rows and drops the OpenAI group. *)
let%expect_test "type-to-filter narrows the catalog" =
  Project.with_temp "model-filter" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  open_model t;
  Term.send t "opus";
  Term.wait t (fun s -> Screen.has "Opus" s && Screen.lacks "GPT-5.5" s);
  print_fact "opus rows kept" (Screen.has "Opus" (Term.screen t));
  print_fact "gpt rows dropped" (Screen.lacks "GPT-5.5" (Term.screen t));
  print_fact "alias gone once typing"
    (Screen.lacks "Default (recommended)" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|
    opus rows kept: true
    gpt rows dropped: true
    alias gone once typing: true
    01 |
    02 |
    03 |
    04 |
    05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
    06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
    07 |
    08 |                            dev · openai/gpt-5.5 medium
    09 |
    10 |      ▎ welcome — and thanks for trying spice this early.
    11 |      ▎ it's experimental: sessions and config may change without migration.
    12 |
    13 |
    14 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
    15 |    model   opus
    16 |
    17 |     Anthropic
    18 |   ❯ Claude Opus 4.8 1M context · Best for everyday, complex t… · log in to use
    19 |     Claude Opus 4.7 1M context · Best for everyday, complex t… · log in to use
    20 |     Claude Opus 4.6 1M context · Best for everyday, complex t… · log in to use
    21 |
    22 |   ○ No effort  ← → to adjust
    23 |
    24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close |}]

(* [←]/[→] adjust the highlighted model's effort within its supported set, and
   the [(default)] tag tracks the model default (05-overlays-pickers.md §Model
   picker). The default row is gpt-5.5, default effort Medium. *)
let%expect_test "arrows adjust effort and track the default marker" =
  Project.with_temp "model-effort" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  open_model t;
  Term.wait t (Screen.has "Medium effort (default)");
  print_fact "default effort marked"
    (Screen.has "Medium effort (default)" (Term.screen t));
  (* Right raises within the supported ramp to High — above the default, so the
     [(default)] marker clears. The scale is monotonic: no separate "provider
     default" stop, so [→] never drops to the lowest level first. *)
  Term.send t right;
  Term.wait t (Screen.has "High effort");
  print_fact "effort adjusted" (Screen.has "High effort" (Term.screen t));
  print_fact "default marker cleared" (Screen.lacks "(default)" (Term.screen t));
  (* Left returns to the model default, restoring the marker. *)
  Term.send t Keys.left;
  Term.wait t (Screen.has "Medium effort (default)");
  print_fact "default marker restored"
    (Screen.has "Medium effort (default)" (Term.screen t));
  [%expect
    {|
    default effort marked: true
    effort adjusted: true
    default marker cleared: true
    default marker restored: true |}]

(* [↵] on a model persists [model] + [reasoning] to the user config, flashes the
   confirmation, and closes to the composer. The effort is set first so both keys
   are written. *)
let%expect_test "select persists the model and effort, then closes" =
  Project.with_temp "model-select" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  open_model t;
  (* Change the effort off the default so a reasoning key is written alongside
     the model. *)
  Term.send t right;
  Term.wait t (Screen.has "High effort");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "model set to");
  print_fact "confirmation flashed" (Screen.has "model set to" (Term.screen t));
  print_fact "composer restored" (Screen.has "message spice" (Term.screen t));
  print_fact "panel chrome gone"
    (Screen.lacks "Default (recommended)" (Term.screen t));
  print_fact "model written to user config"
    (contains (read_config project) "model"
    && contains (read_config project) "gpt-5.5");
  print_fact "reasoning written to user config"
    (contains (read_config project) "reasoning");
  [%expect
    {|
    confirmation flashed: true
    composer restored: true
    panel chrome gone: true
    model written to user config: true
    reasoning written to user config: true |}]

(* A digit jump-picks the nth visible model while the filter is empty, moving the
   selection off the hoisted default without confirming (03-ia §The filter law,
   reconciled: digits pick visible rows though rows carry no rendered numbers). *)
let%expect_test "digit jump-picks a visible model" =
  Project.with_temp "model-digit" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  open_model t;
  print_fact "default selected initially"
    (Screen.has "❯ Default (recommended)" (Term.screen t));
  (* [2] moves the cursor to the second slot (the first concrete model). *)
  Term.send t "2";
  Term.wait t (Screen.lacks "❯ Default (recommended)");
  print_fact "cursor moved off default"
    (Screen.lacks "❯ Default (recommended)" (Term.screen t));
  print_fact "panel still open"
    (Screen.has "Default (recommended)" (Term.screen t));
  [%expect
    {|
    default selected initially: true
    cursor moved off default: true
    panel still open: true |}]

(* Opened from the settings config model row, esc restores that screen unchanged
   (03-ia §Settings, the one managed row). *)
let%expect_test "esc from a settings-opened panel restores the screen" =
  Project.with_temp "model-esc" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/settings";
  Term.wait t (Screen.has "/settings");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Model & reasoning");
  (* The config tab opens with the cursor on the managed Model row. *)
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Default (recommended)");
  print_fact "panel opened from settings"
    (Screen.has "Default (recommended)" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Model & reasoning");
  print_fact "settings screen restored"
    (Screen.has "Model & reasoning" (Term.screen t)
    && Screen.has "config" (Term.screen t));
  print_fact "panel chrome gone"
    (Screen.lacks "Default (recommended)" (Term.screen t));
  [%expect
    {|
    panel opened from settings: true
    settings screen restored: true
    panel chrome gone: true |}]

(* No-auth providers (DeepSeek, the local models) are NEVER locked: their
   account phase is [`Missing] only because no credential is stored, not because
   one is needed (09-auth.md "no login needed"). Regression — they used to
   render [log in to use] and route selection to the login flow. *)
let%expect_test "no-auth local models are not locked" =
  Project.with_temp "model-local" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  open_model t;
  Term.send t "deepseek";
  Term.wait t (Screen.has "DeepSeek V4 Flash");
  let s = Term.screen t in
  print_fact "deepseek row present" (Screen.has "DeepSeek V4 Flash" s);
  print_fact "not locked (no log-in affordance)"
    (Screen.lacks "log in to use" s);
  [%expect
    {|
    deepseek row present: true
    not locked (no log-in affordance): true |}]

(* A pick takes effect in the frame: the runtime pins the session selection and
   pushes the rebuilt snapshot, so the home model line (and the footer's compact
   label, rendered from the same snapshot) name the picked model without a
   restart — the label tracks what the next turn's binding will use. Facts
   only, no golden: the picked model's effort suffix is catalog data this test
   does not pin. *)
let%expect_test "a pick updates the rendered model facts" =
  Project.with_temp "model-pick-refresh" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dev · openai/gpt-5.5");
  print_fact "launch model line"
    (Screen.has "dev · openai/gpt-5.5" (Term.screen t));
  open_model t;
  (* Filter to GPT-5.4 and confirm the highlighted row. *)
  Term.send t "gpt-5.4";
  Term.wait t (fun s -> Screen.has "GPT-5.4" s && Screen.lacks "GPT-5.5" s);
  Term.send t Keys.enter;
  Term.wait t (Screen.has "model set to");
  (* The model line re-renders from the pushed snapshot; the [dev · ] prefix
     disambiguates it from the confirmation flash naming the same selector. *)
  Term.wait t (Screen.has "dev · openai/gpt-5.4");
  print_fact "model line tracks the pick"
    (Screen.has "dev · openai/gpt-5.4" (Term.screen t));
  [%expect
    {|
    launch model line: true
    model line tracks the pick: true |}]

[%%run_tests "spice.tui-next.model-panel"]
