(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The model + effort panel (doc/ui-design/05-overlays-pickers.md §Model picker),
   re-expressed as full-frame goldens. The panel runs no turns — it reads the
   pure catalog and writes the user config — so there is no provider.

   OpenAI is authenticated ([OPENAI_API_KEY]) so the configured [openai/gpt-5.5]
   renders as a normal current row with its [✓] and a live effort line, while
   Anthropic/Google/DeepSeek stay locked (the mute-and-show [log in to use]
   rows). The catalog is pure data, so the whole frame is stable. *)

let env = [ ("OPENAI_API_KEY", "test-key") ]

(* The right-arrow escape the shared Keys module does not carry. *)
let right = "\027[C"

(* The user config the panel writes, under the isolated XDG home. *)
let read_config t =
  let path = Project.scratch (Tui.project t) "config/spice/config.json" in
  if Sys.file_exists path then Util.read_file path else ""

(* Open the model panel via [/model] from the home stage: the palette filters to
   the command, and Enter runs it. *)
let open_model t =
  Tui.keys t "/model";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t

(* The panel opens with the [model] chip, the provider groups (OpenAI unlocked,
   Anthropic locked), the current model's [✓], and the highlighted default's
   effort line. *)
let%expect_test "model panel opens grouped, with the current mark and effort" =
  Tui.run ~name:"model-open" ~env @@ fun t ->
  Tui.settle t;
  open_model t;
  Tui.print t;
  [%expect
    {|01 |
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
19 |     GPT-5.5 Pro               1.05M context · Best for everyday, complex tasks
20 |   ↓ 36 more
21 |
22 |   ◐ Medium effort (default)  ← → to adjust
23 |
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}]

(* Type-to-filter narrows over name/provider/selector: [opus] keeps the locked
   Anthropic Opus rows and drops the OpenAI group. *)
let%expect_test "type-to-filter narrows the catalog" =
  Tui.run ~name:"model-filter" ~env @@ fun t ->
  Tui.settle t;
  open_model t;
  Tui.keys t "opus";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
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
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}]

(* [→] raises the highlighted model's effort within its supported ramp to High —
   above the model default, so the [(default)] marker clears. *)
let%expect_test "right raises effort and clears the default marker" =
  Tui.run ~name:"model-effort-up" ~env @@ fun t ->
  Tui.settle t;
  open_model t;
  Tui.keys t right;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
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
19 |     GPT-5.5 Pro               1.05M context · Best for everyday, complex tasks
20 |   ↓ 36 more
21 |
22 |   ● High effort  ← → to adjust
23 |
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}]

(* [←] returns to the model default, restoring the [(default)] marker. *)
let%expect_test "left returns effort to the default" =
  Tui.run ~name:"model-effort-down" ~env @@ fun t ->
  Tui.settle t;
  open_model t;
  Tui.keys t right;
  Tui.settle t;
  Tui.keys t Keys.left;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
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
19 |     GPT-5.5 Pro               1.05M context · Best for everyday, complex tasks
20 |   ↓ 36 more
21 |
22 |   ◐ Medium effort (default)  ← → to adjust
23 |
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}]

(* [↵] on a model persists [model] + [reasoning] to the user config, flashes the
   confirmation, and closes to the composer. The effort is raised first so both
   keys are written. *)
let%expect_test "select persists the model and effort, then closes" =
  Tui.run ~name:"model-select" ~env @@ fun t ->
  Tui.settle t;
  open_model t;
  Tui.keys t right;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                             dev · openai/gpt-5.5 high
09 |
10 |      ▎ welcome — and thanks for trying spice this early.
11 |      ▎ it's experimental: sessions and config may change without migration.
12 |
13 |           ────────────────────────────────────────────────────────────
14 |           ❯ message spice
15 |           ────────────────────────────────────────────────────────────
16 |
17 |                      dune       ✗ · diagnostics unavailable
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   model set to openai/gpt-5.5 · high effort — effective next turn|}];
  print_string
    (Printf.sprintf "model written: %b\nreasoning written: %b\n"
       (Util.contains (read_config t) "gpt-5.5")
       (Util.contains (read_config t) "reasoning"));
  [%expect
    {|
    model written: true
    reasoning written: true |}]

(* A digit jump-picks the nth visible model while the filter is empty, moving the
   selection off the hoisted default without confirming. *)
let%expect_test "digit jump-picks a visible model" =
  Tui.run ~name:"model-digit" ~env @@ fun t ->
  Tui.settle t;
  open_model t;
  Tui.keys t "2";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
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
16 |     Default (recommended)  GPT-5.5 · Default · 1.05M context · Best for eve… ✓
17 |     OpenAI
18 |   ❯ GPT-5.5         Default · 1.05M context · Best for everyday, complex tasks
19 |     GPT-5.5 Pro               1.05M context · Best for everyday, complex tasks
20 |   ↓ 36 more
21 |
22 |   ◐ Medium effort (default)  ← → to adjust
23 |
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}]

(* No-auth providers (DeepSeek, the local models) are NEVER locked: their account
   phase is [`Missing] only because no credential is stored, not because one is
   needed — so no [log in to use] affordance, unlike the locked cloud rows. *)
let%expect_test "no-auth local models are not locked" =
  Tui.run ~name:"model-local" ~env @@ fun t ->
  Tui.settle t;
  open_model t;
  Tui.keys t "deepseek";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
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
14 |    model   deepseek
15 |
16 |     DeepSeek
17 |   ❯ DeepSeek V4 Flash q2              4k context · Efficient for routine tasks
18 |     DeepSeek V4 Flash q2/q4  Default · 4k context · Efficient for routine tas…
19 |     DeepSeek V4 Flash q4              4k context · Efficient for routine tasks
20 |   ↓ 1 more
21 |
22 |   ○ No effort (default)  ← → to adjust
23 |
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}]

[%%run_tests "spice.tui-next.model-panel"]
