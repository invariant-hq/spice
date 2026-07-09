(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The review screen: a panel over the diff of the worktree against a base. A
   persistent two-pane split — a directory-grouped nav on the left, the selected
   file's diff on the right, a full-height rule between — following the panel
   contract (rule, header, hint) but deliberately waiving the one-column law for
   this surface. Focus (nav or diff) decides which pane the movement keys drive
   and where the accent cursor renders. Below 80 columns the split degrades to a
   single focused pane. The model's cursor is the selection; this state holds
   only view-local orientation. Key routing and effects are wired elsewhere;
   this module is the view plus the pure focus transitions the router calls.

   [depth] names the focused pane: [Queue] is nav focus, [Diff] is diff focus.
   The names predate the split and are kept because the component is wired to
   them. *)

type depth = Queue | Diff
type notice = { text : string; warning : bool }

type state = {
  depth : depth;
  full_context : bool;
  notice : notice option;
  help : bool;
  compose : Review_compose.t option;
}

let init =
  {
    depth = Queue;
    full_context = false;
    notice = None;
    help = false;
    compose = None;
  }

(* {1 Transitions} *)

let cursor_has_file review =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Scope scope ->
      Option.is_some (Spice_review.Scope.path scope)
  | Spice_review.Cursor.Cr index ->
      Option.is_some (Spice_review.cr review index)

(* Focus the diff pane (enter on a nav row). None when already there or the
   cursor has no file to show. *)
let enter state review =
  match state.depth with
  | Queue when cursor_has_file review -> Some { state with depth = Diff }
  | Queue | Diff -> None

(* The esc ladder: diff focus returns to nav; nav focus returns None so the
   caller closes the panel. *)
let back state =
  match state.depth with
  | Diff -> Some { state with depth = Queue }
  | Queue -> None

(* Tab flips focus between the two panes. *)
let toggle_focus state =
  {
    state with
    depth = (match state.depth with Queue -> Diff | Diff -> Queue);
  }

let set_compose state compose = { state with compose }
let toggle_help state = { state with help = not state.help }
let toggle_context state = { state with full_context = not state.full_context }

let set_notice state ~text ~warning =
  { state with notice = Some { text; warning } }

let clear_notice state = { state with notice = None }

(* {1 Rendering helpers} *)

let hidden_overflow =
  { Mosaic.x = Mosaic.Overflow.Hidden; y = Mosaic.Overflow.Hidden }

let dim ?(style = Style.muted) line = Mosaic.text ~style ~wrap:`Word line
let faint line = Mosaic.text ~style:Style.faint ~wrap:`None line
let plain ?style line = Mosaic.text ?style ~wrap:`None ~flex_shrink:0. line
let rule width = Style.panel_rule ?width ()

let frame rows =
  Mosaic.box ~flex_direction:Mosaic.Flex_direction.Column ~flex_shrink:0.
    ~overflow:hidden_overflow
    ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.auto }
    rows

let spacer = Mosaic.box ~flex_grow:1. []

let verdict_word review =
  match Spice_review.verdict_freshness review with
  | `Pending -> ("pending", Style.muted)
  | `Approved -> ("approved", Style.success)
  | `Stale -> ("approved · stale", Style.warning)

(* The loader resolves the base to a full commit hash, so [?range] lets the
   host pass the user's original spec (e.g. "main..worktree") for the header
   label; without it we derive from the feature's own labels. *)
let range_label ?range review =
  match range with
  | Some range -> range
  | None ->
      let feature = Spice_review.feature review in
      Spice_review.Feature.base feature
      ^ ".."
      ^ Spice_review.Feature.tip feature

(* Header: bold [Review], the muted range, and a right cluster of progress and
   verdict. On the empty state the right cluster drops (spec §States). *)
let header ?(counts = true) ?range review =
  let range = range_label ?range review in
  let right =
    if not counts then []
    else
      let progress =
        Printf.sprintf "%d/%d reviewed"
          (Spice_review.reviewed_units review)
          (Spice_review.units review)
      in
      let verdict, verdict_style = verdict_word review in
      [
        plain ~style:Style.muted progress;
        plain ~style:Style.muted Style.separator;
        plain ~style:verdict_style verdict;
      ]
  in
  Mosaic.box ~flex_direction:Mosaic.Flex_direction.Row
    ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px 1 }
    ([
       plain ~style:Style.bold "Review"; plain ~style:Style.muted ("  " ^ range);
     ]
    @ [ spacer ] @ right)

let hint_line_plain state =
  match state.notice with
  | Some notice ->
      let style = if notice.warning then Style.warning else Style.muted in
      Mosaic.text ~style ~wrap:`None notice.text
  | None ->
      let parts =
        match state.depth with
        | Queue ->
            [
              "tab focus diff";
              "space mark";
              "enter open";
              "c comment";
              "a approve";
              "t task spice";
              "esc close";
            ]
        | Diff ->
            [
              "tab focus nav";
              "space mark hunk";
              "c comment";
              "]/[ hunk";
              "ctrl+o context";
              "esc nav";
            ]
      in
      faint (String.concat Style.separator parts)

let hint_line state =
  match state.compose with
  | Some compose ->
      let verb =
        match Review_compose.target compose with
        | Review_compose.Add _ -> "enter add CR"
        | Review_compose.Edit _ -> "enter save CR"
        | Review_compose.Resolve _ -> "enter resolve CR"
      in
      faint (String.concat Style.separator [ verb; "esc cancel" ])
  | None -> hint_line_plain state

(* {1 Help table} *)

let help_rows =
  [
    ("tab", "switch focus (nav / diff)");
    ("↑/↓, j/k", "move selection / hunk");
    ("]/[", "next / previous hunk (diff)");
    ("enter", "focus the diff pane");
    ("space", "mark reviewed and advance");
    ("n / p", "next / previous CR");
    ("c / e", "add / edit CR");
    ("x / d", "resolve / remove CR");
    ("a", "toggle approved / pending");
    ("t", "task spice to review");
    ("ctrl+o", "cycle diff context");
    ("?", "toggle this table");
    ("esc", "back / close");
  ]

let help_table () =
  List.map
    (fun (key, description) ->
      faint ("  " ^ Style.pad_right 14 key ^ description))
    help_rows

(* {1 Body} *)

(* The human base label: the part before ".." of the range override, else the
   feature's own base. *)
let base_label ?range review =
  match range with
  | Some range -> (
      match String.index_opt range '.' with
      | Some i -> String.sub range 0 i
      | None -> range)
  | None -> Spice_review.Feature.base (Spice_review.feature review)

let empty_line ?range review =
  dim
    ("  no changes to review — the worktree matches " ^ base_label ?range review)

(* {1 Split layout} *)

let split_min = 80

(* Nav is fixed near 32 columns but never more than ~40% of the width. *)
let nav_width width = min 32 (max 20 (width * 2 / 5))

(* The full-height rule between the panes. *)
let separator height =
  Mosaic.box ~flex_direction:Mosaic.Flex_direction.Column ~flex_shrink:0.
    ~size:{ Mosaic.width = Mosaic.px 1; height = Mosaic.px height }
    (List.init height (fun _ ->
         Mosaic.text ~style:Style.rule ~wrap:`None Style.v_separator))

let pane ~grow ~shrink ~width ~height rows =
  Mosaic.box ~flex_direction:Mosaic.Flex_direction.Column ~flex_grow:grow
    ~flex_shrink:shrink ~overflow:hidden_overflow
    ~size:{ Mosaic.width; height = Mosaic.px height }
    rows

let split ~width ~height ~nav ~diff =
  let nav_w = nav_width width in
  Mosaic.box ~flex_direction:Mosaic.Flex_direction.Row
    ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px height }
    [
      pane ~grow:0. ~shrink:0. ~width:(Mosaic.px nav_w) ~height nav;
      separator height;
      pane ~grow:1. ~shrink:1. ~width:Mosaic.auto ~height diff;
    ]

(* {1 Compose dialog} *)

(* The line the CR will land on, as a [(path_string, line)] pair the diff pane
   highlights. *)
let compose_anchor state =
  match state.compose with
  | None -> None
  | Some compose -> (
      match Review_compose.target compose with
      | Review_compose.Add { path; line } ->
          Some (Spice_path.Rel.to_string path, line)
      | Review_compose.Edit { occurrence; _ }
      | Review_compose.Resolve { occurrence; _ } ->
          Some
            ( Spice_path.Rel.to_string (Spice_cr.Occurrence.path occurrence),
              Spice_cr.Occurrence.line occurrence ))

(* The composer is a compact opaque dialog floating over the center of the
   dimmed panes. It is absolutely positioned with an inset computed from the
   dialog's fixed size, so both panes keep their full height behind it. The
   input is app-owned and painted, so the dialog carries no interactive widget.
*)
let dialog_overlay ~width ~height compose review =
  let dialog_w = Review_compose.dialog_width in
  let dialog_h = Review_compose.height compose in
  let left = max 0 ((width - dialog_w) / 2) in
  let top = max 0 ((height - dialog_h) / 2) in
  Mosaic.box ~position:Mosaic.Position.Absolute
    ~inset:
      (Mosaic.inset_lrtb left
         (max 0 (width - left - dialog_w))
         top
         (max 0 (height - top - dialog_h)))
    ~z_index:10
    [ Review_compose.view compose review ]

(* {1 Views} *)

let view ?width ?height ?range ?on_click ?on_line_click state review =
  if Spice_review.Feature.is_empty (Spice_review.feature review) then
    frame
      [
        rule width;
        header ~counts:false ?range review;
        faint "esc close";
        Mosaic.empty;
        empty_line ?range review;
      ]
  else
    let composing = Option.is_some state.compose in
    let width_px = Option.value width ~default:Style.default_rule_width in
    let total = Option.value height ~default:24 in
    (* Chrome is rule, header, blank, and the bottom legend — four rows. *)
    let pane_h = max 3 (total - 4) in
    let nav_focused = state.depth = Queue in
    let anchor = compose_anchor state in
    (* Narrow mode renders the nav as the single full-width pane. *)
    let nav_w = if width_px < split_min then width_px else nav_width width_px in
    let nav () =
      Review_rows.view ~width:nav_w ~height:pane_h
        ~focused:(nav_focused && not composing)
        ~dimmed:composing ?on_click review
    in
    let diff () =
      Review_diff.view ~height:pane_h
        ~focused:((not nav_focused) && not composing)
        ~dimmed:composing ?compose_anchor:anchor ?on_line_click review
        ~full_context:state.full_context
    in
    let overlay =
      match state.compose with
      | None -> []
      | Some compose ->
          [ dialog_overlay ~width:width_px ~height:total compose review ]
    in
    let body =
      if state.help then help_table ()
      else if width_px < split_min then
        (* Narrow: one full-width pane, the focused one. *)
        if nav_focused then nav () else diff ()
      else
        [ split ~width:width_px ~height:pane_h ~nav:(nav ()) ~diff:(diff ()) ]
    in
    (* The key legend is the screen's own footer: bottom-pinned by a flex-grow
       spacer, swapped for a refresh notice by [hint_line]. *)
    Mosaic.box ~flex_direction:Mosaic.Flex_direction.Column ~flex_shrink:0.
      ~overflow:hidden_overflow
      ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px total }
      ([ rule width; header ?range review; Mosaic.empty ]
      @ body
      @ [ spacer; hint_line state ]
      @ overlay)

let loading_view ?width ?height:_ () =
  frame
    [
      rule width;
      Mosaic.box ~flex_direction:Mosaic.Flex_direction.Row
        ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px 1 }
        [
          plain ~style:Style.bold "Review";
          spacer;
          plain ~style:Style.muted "computing…";
        ];
      Mosaic.empty;
    ]

let error_view ?width ?height:_ ~message () =
  frame
    [
      rule width;
      plain ~style:Style.bold "Review";
      Mosaic.text ~style:Style.error ~wrap:`Word (Style.problem ^ message);
      faint "esc close";
    ]
