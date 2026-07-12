(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The model + effort panel (doc/ui-design/05-overlays-pickers.md §Model picker),
   re-expressed as full-frame goldens. The panel itself runs no turns — it reads
   the pure catalog and writes the user config — so most cases need no provider.

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
  if Sys.file_exists path then Project.read_path path else ""

(* Open the model panel via [/model] from the home stage: the palette filters to
   the command, and Enter runs it. *)
let open_model t =
  Tui.keys t "/model";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t

(* Drop into chat through the real provider boundary, then open [/model] over
   that settled transcript. *)
let open_model_over_turn t prompt =
  Tui.keys t prompt;
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  open_model t

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
  Tui.keys t Key.left;
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
       (Screen.contains (read_config t) "gpt-5.5")
       (Screen.contains (read_config t) "reasoning"));
  [%expect {|
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

(* The settings model row opens this same panel as a child surface; escape must
   restore the settings screen rather than falling through to the home stage. *)
let%expect_test "escape from a settings-opened model panel restores settings" =
  Tui.run ~name:"model-settings-escape" ~env @@ fun t ->
  Tui.settle t;
  Tui.keys t "/settings";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t Key.escape;
  Tui.settle t;
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

(* A panel is pinned where the composer and footer were, leaving the transcript
   as the growing region above it. At the baseline 80x24 geometry, even a short
   transcript keeps its complete context while the panel is open; escape
   restores the same transcript with the composer and footer. *)
let%expect_test "panel preserves a short transcript and escape restores chat" =
  let script =
    [
      Provider_script.message ~expect:[ "short panel" ] ~gate:"fin"
        ~id:"resp-short-panel" "The panel should keep this answer visible.";
    ]
  in
  Tui.run ~name:"model-panel-short-transcript" ~size:(80, 24) ~env
    ~provider:script @@ fun t ->
  Tui.settle t;
  open_model_over_turn t "show a short panel transcript";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ show a short panel transcript
07 |
08 | ⏺ The panel should keep this answer visible.
09 |
10 |
11 |
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
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ show a short panel transcript
07 |
08 | ⏺ The panel should keep this answer visible.
09 |
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

let overflowing_answer =
  List.init 20 (fun index ->
      Printf.sprintf "Tail marker %02d keeps the overflowing transcript anchored."
        (index + 1))
  |> String.concat "\n\n"

(* Wide chat mounts the side pane, exercising the pane-backed [chat_above]
   branch as well as the bare 80-column branch above. Opening the panel at
   120x32 keeps the overflowing transcript pinned to its newest rows immediately
   above the panel; escape expands the viewport without moving away from the
   tail. *)
let%expect_test "panel keeps an overflowing wide transcript at the tail" =
  let script =
    [
      Provider_script.message ~expect:[ "wide panel" ] ~gate:"fin"
        ~id:"resp-wide-panel" overflowing_answer;
    ]
  in
  Tui.run ~name:"model-panel-wide-overflow" ~size:(120, 32) ~env
    ~provider:script @@ fun t ->
  Tui.settle t;
  open_model_over_turn t "show the wide panel over overflow";
  Tui.print t;
  [%expect
    {|01 |                                                                                 │ workspace
02 |   Tail marker 13 keeps the overflowing transcript anchored.                     │   dune disconnected
03 |                                                                                 │
04 |   Tail marker 14 keeps the overflowing transcript anchored.                     │
05 |                                                                                 │
06 |   Tail marker 15 keeps the overflowing transcript anchored.                     │
07 |                                                                                 │
08 |   Tail marker 16 keeps the overflowing transcript anchored.                     │
09 |                                                                                 │
10 |   Tail marker 17 keeps the overflowing transcript anchored.                     │
11 |                                                                                 │
12 |   Tail marker 18 keeps the overflowing transcript anchored.                     │
13 |                                                                                 │
14 |   Tail marker 19 keeps the overflowing transcript anchored.                     │
15 |                                                                                 │
16 |   Tail marker 20 keeps the overflowing transcript anchored.                     │
17 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
18 |    model
19 |
20 |   ❯ Default (recommended)                       GPT-5.5 · Default · 1.05M context · Best for everyday, complex tasks ✓
21 |     OpenAI
22 |     GPT-5.5                                                 Default · 1.05M context · Best for everyday, complex tasks
23 |     GPT-5.5 Pro                                                       1.05M context · Best for everyday, complex tasks
24 |     GPT-5.4                                                           1.05M context · Best for everyday, complex tasks
25 |     GPT-5.4 Pro                                                       1.05M context · Best for everyday, complex tasks
26 |     GPT-5.4 mini                                                            400k context · Efficient for routine tasks
27 |     GPT-5.4 nano                                                              400k context · Fastest for quick answers
28 |   ↓ 32 more
29 |
30 |   ◐ Medium effort (default)  ← → to adjust
31 |
32 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}];
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |   Tail marker 07 keeps the overflowing transcript anchored.                     │ workspace
02 |                                                                                 │   dune disconnected
03 |   Tail marker 08 keeps the overflowing transcript anchored.                     │
04 |                                                                                 │
05 |   Tail marker 09 keeps the overflowing transcript anchored.                     │
06 |                                                                                 │
07 |   Tail marker 10 keeps the overflowing transcript anchored.                     │
08 |                                                                                 │
09 |   Tail marker 11 keeps the overflowing transcript anchored.                     │
10 |                                                                                 │
11 |   Tail marker 12 keeps the overflowing transcript anchored.                     │
12 |                                                                                 │
13 |   Tail marker 13 keeps the overflowing transcript anchored.                     │
14 |                                                                                 │
15 |   Tail marker 14 keeps the overflowing transcript anchored.                     │
16 |                                                                                 │
17 |   Tail marker 15 keeps the overflowing transcript anchored.                     │
18 |                                                                                 │
19 |   Tail marker 16 keeps the overflowing transcript anchored.                     │
20 |                                                                                 │
21 |   Tail marker 17 keeps the overflowing transcript anchored.                     │
22 |                                                                                 │
23 |   Tail marker 18 keeps the overflowing transcript anchored.                     │
24 |                                                                                 │
25 |   Tail marker 19 keeps the overflowing transcript anchored.                     │
26 |                                                                                 │
27 |   Tail marker 20 keeps the overflowing transcript anchored.                     │
28 |
29 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
30 | ❯ message spice
31 | ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
32 |   $PROJECT · gpt-5.5 medium · dune: ✗                          ? for shortcuts|}]

[%%run_tests "spice.tui.model-panel"]
