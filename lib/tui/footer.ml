(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

type severity = Ok | Warn | Critical
type input_mode = Shell | History_search

(* The heap sinks as context fills, framed as runway left (04-header-footer.md
   §7). The ≤25% band keeps the low mound but turns the whole segment warning;
   the ≤10% band collapses to the lowest mound, turns error, and appends the
   /compact call to action. *)
let heap_meter ~left_pct =
  let levels = Theme.heap_meter_levels in
  if left_pct <= 10 then (levels.(3), Critical)
  else if left_pct <= 25 then (levels.(2), Warn)
  else if left_pct <= 50 then (levels.(2), Ok)
  else if left_pct <= 75 then (levels.(1), Ok)
  else (levels.(0), Ok)

let sep = seg Theme.muted Theme.separator
let display_width s = Matrix.Text.measure ~width_method:`Unicode ~tab_width:2 s

(* Iteration 1 runs no turn, so no context is used yet. *)
let used_tokens = 0

(* The footer glyph reflects connectivity only (12-home.md §Degraded): a
   disconnected watch is [✗] in [error], a connected watch — clean, failing, or a
   build verdict not yet latched (Unknown) — is [✓] in [success]. Only the glyph
   is colored; the surrounding [dune: ] stays muted (12-home.md Theme usage). The
   build verdict itself is the brief's [dune] line, never this glyph. *)
let ok_glyph = Ansi.Style.make ~fg:Theme.color_success ()
let bad_glyph = Ansi.Style.make ~fg:Theme.color_error ()

let dune_glyph = function
  | Spice_ocaml_dune.Rpc.Instance.Health.Disconnected -> (bad_glyph, "✗")
  | Spice_ocaml_dune.Rpc.Instance.Health.Clean
  | Spice_ocaml_dune.Rpc.Instance.Health.Failing _
  | Spice_ocaml_dune.Rpc.Instance.Health.Unknown ->
      (ok_glyph, "✓")

(* The heap meter measures runway a turn has consumed, so it renders only once
   used tokens are positive and the model's window is known (04-header-footer.md
   §7). Iteration 1 runs no turn — [used_tokens] is 0 — so the home footer stays
   meterless (12-home.md footer). *)
let context_segment window =
  match window with
  | Some window when used_tokens > 0 ->
      let left_pct =
        if window <= 0 then 100
        else
          let used = 100 * used_tokens / window in
          max 0 (100 - used)
      in
      let glyph, severity = heap_meter ~left_pct in
      let glyph_style, text_style, text =
        match severity with
        | Ok -> (Theme.atom, Theme.muted, Printf.sprintf "%d%% left" left_pct)
        | Warn ->
            (Theme.warning, Theme.warning, Printf.sprintf "%d%% left" left_pct)
        | Critical ->
            (Theme.error, Theme.error, Printf.sprintf "%d%% · /compact" left_pct)
      in
      Some
        (box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
           ~size:{ width = auto; height = px 1 }
           [ seg glyph_style glyph; seg text_style (" " ^ text) ])
  | Some _ | None -> None

(* Committed strings (03-composer.md §Shell mode, and the lead's spec sync):
   the input mode claims the right hint slot for its badge and the left fact
   segments for its key hints. *)
let input_mode_hint = function
  | Shell -> "esc exit shell · ↵ run"
  | History_search -> "↵ insert · esc cancel · type to search"

let history_style = Ansi.Style.make ~fg:Theme.color_history ()

let input_mode_badge = function
  | Shell -> (Theme.warning, Theme.shell_marker ^ " shell")
  | History_search -> (history_style, Theme.history_marker ^ " history")

(* The live-children fact (04-header-footer.md §2 [agent] slot): [* N agents]
   while any child run is unsettled, muted, between the model and the dune
   verdict. The mark is [Theme.kind_thread] — the IA vocabulary's agent-thread
   glyph (03-ia §Theme & glyph deltas), so the same idea reads the same here as
   in the @-mention list, never the reserved [◇] (MCP resources). *)
let agents_fact = function
  | None -> None
  | Some 1 -> Some (Theme.kind_thread ^ " 1 agent")
  | Some n -> Some (Printf.sprintf "%s %d agents" Theme.kind_thread n)

(* The narrowest cwd worth keeping the [? for shortcuts] hint beside: once the
   row cannot hold both a cwd this wide and the hint, the hint yields first
   (04-header-footer.md §4). *)
let cwd_floor = 12

(* The leaf-sized cwd the row always keeps: below it, an optional fact yields
   rather than squeeze the cwd out entirely (04 §2, cwd never fully drops). *)
let cwd_leaf = 8

(* The idle footer's left facts, and whether the [? for shortcuts] hint still
   fits beside them. The cwd left-truncates in OCaml rather than under the
   flex-truncate measure quirk (doc/plans/tui-next.md §Rules); [reserved] is a
   column estimate of the kept segments — the model, dune
   verdict, context and agent facts (each with its separator), and, while it is
   kept, the hint.

   Degradation follows the spec priority (04 §2), lowest value first: the hint
   yields before any fact; then optional facts drop in the order context → dune
   verdict → agent count → model until the row holds what remains plus a
   [cwd_leaf]-wide cwd; the cwd itself never fully drops — it left-truncates to
   whatever is left, down to a floor. *)
let idle_facts (snapshot : Snapshot.t) ~dune ~width ~agents ~account_absent =
  let model = Snapshot.model_line_compact snapshot in
  let context = context_segment snapshot.Snapshot.context_window in
  let agents = agents_fact agents in
  let sep_cols = 3 in
  let model_cols = sep_cols + String.length model in
  let dune_cols =
    sep_cols + 7
    (* [dune: X] *)
  in
  let agents_cols =
    match agents with Some s -> sep_cols + display_width s | None -> 0
  in
  let context_cols = if Option.is_some context then sep_cols + 12 else 0 in
  (* The logged-out nudge (09-auth.md §9, 04-header-footer.md §2 account slot): a
     loud [! not logged in · /login] leftmost, never dropped — an error state is
     kept while every optional fact degrades around it (00-overview §7). Its
     columns, including the separator to the cwd, are fixed reserve. *)
  let nudge =
    if account_absent then
      [ seg Theme.error "! not logged in"; sep; seg Theme.atom "/login" ]
    else []
  in
  let nudge_cols =
    if account_absent then
      display_width "! not logged in"
      + sep_cols + display_width "/login" + sep_cols
    else 0
  in
  let reserved ~has_hint ~keep_model ~keep_agents ~keep_dune ~keep_context =
    2 (* indent *)
    + 2 (* right pad *) + 1 (* min spacer *)
    + nudge_cols
    + (if has_hint then display_width "? for shortcuts" + 1 else 0)
    + (if keep_model then model_cols else 0)
    + (if keep_agents then agents_cols else 0)
    + (if keep_dune then dune_cols else 0)
    + if keep_context then context_cols else 0
  in
  let has_hint =
    width
    - reserved ~has_hint:true ~keep_model:true ~keep_agents:true ~keep_dune:true
        ~keep_context:true
    >= cwd_floor
  in
  (* Keep a segment only while the row still holds it beside a leaf-sized cwd.
     Each decision folds in the ones already made, so the checks walk the drop
     order and stop at the richest set that fits. *)
  let fits ~keep_model ~keep_agents ~keep_dune ~keep_context =
    width - reserved ~has_hint ~keep_model ~keep_agents ~keep_dune ~keep_context
    >= cwd_leaf
  in
  let keep_context =
    fits ~keep_model:true ~keep_agents:true ~keep_dune:true ~keep_context:true
  in
  let keep_dune =
    fits ~keep_model:true ~keep_agents:true ~keep_dune:true ~keep_context
  in
  let keep_agents =
    fits ~keep_model:true ~keep_agents:true ~keep_dune ~keep_context
  in
  let keep_model =
    fits ~keep_model:true ~keep_agents ~keep_dune ~keep_context
  in
  let budget =
    max 3
      (width
      - reserved ~has_hint ~keep_model ~keep_agents ~keep_dune ~keep_context)
  in
  let cwd =
    Path_display.left_truncate ~width:budget
      (Path_display.home_relative snapshot.Snapshot.cwd)
  in
  let glyph_style, glyph = dune_glyph dune in
  let facts =
    nudge
    @ (if account_absent then [ sep ] else [])
    @ [ seg Theme.muted cwd ]
    @ (if keep_model then [ sep; seg Theme.muted model ] else [])
    @ (match agents with
      | Some s when keep_agents -> [ sep; seg Theme.muted s ]
      | _ -> [])
    @ (if keep_dune then
         [ sep; seg Theme.muted "dune: "; seg glyph_style glyph ]
       else [])
    @ match context with Some c when keep_context -> [ sep; c ] | _ -> []
  in
  (facts, has_hint)

let view ?input_mode ?agents ?home_badge
    ?(account_absent = false) (snapshot : Snapshot.t) ~dune ~width =
  (* Only the idle facts carry the [? for shortcuts] hint, and they alone decide
     whether it fits (04-header-footer.md §4): a shell or history badge claims
     the right slot outright, so those states never show it. [has_hint] is
     meaningful only in the idle branch below. *)
  let left, has_hint =
    match input_mode with
    | Some mode -> ([ seg Theme.faint (input_mode_hint mode) ], false)
    | None ->
        idle_facts snapshot ~dune ~width ~agents ~account_absent
  in
  let right =
    match input_mode with
    | Some mode ->
        let style, badge = input_mode_badge mode in
        [ seg style badge ]
    | None -> (
        (* A drilled-in thread's footer claims the right slot for its way-home
           badge (03-ia §Agent threads: [esc for main]), ahead of the shortcut
           hint — the badge is the escape affordance and must never drop. *)
        match home_badge with
        | Some badge -> [ seg Theme.accent badge ]
        | None -> if has_hint then [ seg Theme.faint "? for shortcuts" ] else []
        )
  in
  let spacer =
    box ~flex_grow:1. ~flex_shrink:1. ~size:{ width = auto; height = px 1 } []
  in
  box ~key:"footer" ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    (left @ (spacer :: right))
