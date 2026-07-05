(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The review diff pane: the selected file's unified diff with a scope line
   above it, inside a scroll box. Each hunk is its own node so mixed files quiet
   hunk by hunk; the selected hunk carries the gutter cursor (accent when the
   diff pane holds focus, muted otherwise), and each node reports its scope to
   [on_hunk_click]. A CR anchored outside any hunk gets a synthesized
   context-only view. See doc/ui-design/11-review.md §Diff pane. *)

(* {1 Patch construction} *)

let patch_line line =
  let tag =
    match Spice_diff.Hunk.Line.kind line with
    | Spice_diff.Hunk.Line.Context -> Mosaic.Diff.Patch.Context
    | Spice_diff.Hunk.Line.Added -> Mosaic.Diff.Patch.Added
    | Spice_diff.Hunk.Line.Removed -> Mosaic.Diff.Patch.Removed
  in
  { Mosaic.Diff.Patch.tag; content = Spice_diff.Hunk.Line.text line }

let patch_hunk hunk =
  {
    Mosaic.Diff.Patch.old_start = Spice_diff.Hunk.old_start hunk;
    old_lines = Spice_diff.Hunk.old_count hunk;
    new_start = Spice_diff.Hunk.new_start hunk;
    new_lines = Spice_diff.Hunk.new_count hunk;
    lines = List.map patch_line (Spice_diff.Hunk.lines hunk);
  }

let diff_text_style = Mosaic.Ansi.Style.make ~fg:Style.color_muted ()
let dimmed_text_style = Mosaic.Ansi.Style.make ~fg:Style.color_faint ()

let diff_node ?(line_highlights = []) ?(text_style = diff_text_style)
    ?on_line_click ~theme ~line_signs patch =
  Mosaic.diff ~layout:Mosaic.Diff.Unified ~theme ~show_line_numbers:true
    ~wrap:`Word ~line_signs ~line_highlights ~text_style ?on_line_click
    ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.auto }
    patch

(* [Mosaic.Diff] declares three record types sharing [side]/[first]/[last], so
   building any at top level would rely on type-directed disambiguation the
   build rejects. Each type gets its own module: within a module only its own
   labels are in scope, so construction and field access stay unambiguous. *)
module Gutter_sign = struct
  type t = Mosaic.Line_number.line_sign = {
    before : string option;
    after : string option;
    before_color : Mosaic.Ansi.Color.t option;
    after_color : Mosaic.Ansi.Color.t option;
  }

  let cursor color =
    {
      before = Some "❯";
      after = None;
      before_color = Some color;
      after_color = None;
    }
end

module Line_color = struct
  type t = Mosaic.Line_number.line_color = {
    gutter : Mosaic.Ansi.Color.t;
    content : Mosaic.Ansi.Color.t option;
  }

  let solid c = { gutter = c; content = Some c }
end

module Diff_sign = struct
  type t = Mosaic.Diff.line_sign = {
    side : Mosaic.Diff.side;
    first : int;
    last : int;
    sign : Mosaic.Line_number.line_sign;
  }

  let make side n sign = { side; first = n; last = n; sign }
end

module Diff_highlight = struct
  type t = Mosaic.Diff.line_highlight = {
    side : Mosaic.Diff.side;
    first : int;
    last : int;
    color : Mosaic.Line_number.line_color;
  }

  let make side n color = { side; first = n; last = n; color }
end

module Source_line = struct
  type t = Mosaic.Diff.source_line = { side : Mosaic.Diff.side; line : int }

  let side t = t.side
  let line t = t.line
end

(* A subtle alpha wash derived from a theme role — no new base colors. The diff
   widget blends it over the line's normal background. *)
let wash base ~alpha =
  let r, g, b = Mosaic.Ansi.Color.to_rgb base in
  Mosaic.Ansi.Color.of_rgba r g b alpha

let cursor_alpha = 56
let compose_alpha = 120

let line_highlight ~base ~alpha side n =
  Diff_highlight.make side n (Line_color.solid (wash base ~alpha))

let diff_side = function
  | Spice_review.Scope.Old -> Mosaic.Diff.Old
  | Spice_review.Scope.New -> Mosaic.Diff.New

let scope_side = function
  | Mosaic.Diff.Old -> Spice_review.Scope.Old
  | Mosaic.Diff.New -> Spice_review.Scope.New

(* The cursor in the gutter, on a hunk's first displayed line. It rides the sign
   column's [before] slot, which the diff leaves free for callers. Accent when
   the diff pane holds focus, muted otherwise. *)
let cursor_signs ~color line =
  match line with
  | None -> []
  | Some (side, n) -> [ Diff_sign.make side n (Gutter_sign.cursor color) ]

let hunk_anchor hunk =
  if Spice_diff.Hunk.new_count hunk > 0 then
    (Mosaic.Diff.New, Spice_diff.Hunk.new_start hunk)
  else (Mosaic.Diff.Old, Spice_diff.Hunk.old_start hunk)

(* {1 Model reading} *)

let path_string = Spice_path.Rel.to_string

let file_hunks file =
  match Spice_review.Feature.File.content file with
  | Spice_review.Feature.File.Text hunks -> hunks
  | Spice_review.Feature.File.Opaque _ -> []

let reviewed_hunk review path hunk =
  Spice_review.is_reviewed review (Spice_review.Scope.of_hunk ~path hunk)

let file_counts file =
  List.fold_left
    (fun (adds, dels) hunk ->
      List.fold_left
        (fun (adds, dels) line ->
          match Spice_diff.Hunk.Line.kind line with
          | Spice_diff.Hunk.Line.Added -> (adds + 1, dels)
          | Spice_diff.Hunk.Line.Removed -> (adds, dels + 1)
          | Spice_diff.Hunk.Line.Context -> (adds, dels))
        (adds, dels)
        (Spice_diff.Hunk.lines hunk))
    (0, 0) (file_hunks file)

let find_feature_file review path_str =
  List.find_opt
    (fun file ->
      String.equal (path_string (Spice_review.Feature.File.path file)) path_str)
    (Spice_review.Feature.files (Spice_review.feature review))

(* What the cursor points at in the diff pane. [line] is set when the cursor is
   a Line scope (the unit of attention); [hunk] when it is a Hunk scope (the
   unit of coverage). Both drive the gutter cursor and line highlight. *)
type target =
  | File_diff of {
      file : Spice_review.Feature.File.t;
      hunk : Spice_diff.Hunk.t option;
      line : (Mosaic.Diff.side * int) option;
    }
  | Cr_anchor of Spice_cr.Occurrence.t * Spice_review.Feature.File.t option
  | Nothing

let target review =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Scope scope -> (
      match Spice_review.Scope.path scope with
      | None -> Nothing
      | Some path -> (
          match
            Spice_review.Feature.find_file (Spice_review.feature review) ~path
          with
          | None -> Nothing
          | Some file -> (
              match scope with
              | Spice_review.Scope.Hunk _ ->
                  let hunk =
                    List.find_opt
                      (fun h ->
                        Spice_review.Scope.equal scope
                          (Spice_review.Scope.of_hunk ~path h))
                      (file_hunks file)
                  in
                  File_diff { file; hunk; line = None }
              | Spice_review.Scope.Line (side, _, n) ->
                  File_diff
                    { file; hunk = None; line = Some (diff_side side, n) }
              | Spice_review.Scope.Feature | Spice_review.Scope.File _ ->
                  File_diff { file; hunk = None; line = None })))
  | Spice_review.Cursor.Cr index -> (
      match Spice_review.cr review index with
      | None -> Nothing
      | Some occ ->
          let file =
            find_feature_file review
              (Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ))
          in
          Cr_anchor (occ, file))

(* {1 Scope line} *)

let text ?(style = Style.muted) s =
  Mosaic.text ~style ~wrap:`None ~flex_shrink:0. s

let joined parts =
  let sep = text Style.separator in
  let rec go = function
    | [] -> []
    | [ (s, style) ] -> [ text ~style s ]
    | (s, style) :: rest -> text ~style s :: sep :: go rest
  in
  Mosaic.box ~flex_direction:Mosaic.Flex_direction.Row
    ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px 1 }
    (go parts)

let counts_word file =
  let adds, dels = file_counts file in
  Printf.sprintf "+%d −%d" adds dels

let file_scope_line review file hunk =
  let path = Spice_review.Feature.File.path file in
  let reviewed =
    match hunk with
    | Some hunk -> reviewed_hunk review path hunk
    | None -> Spice_review.is_reviewed review (Spice_review.Scope.File path)
  in
  let state =
    if reviewed then ("reviewed", Style.success) else ("unreviewed", Style.muted)
  in
  let hunk_word =
    match hunk with
    | None -> []
    | Some hunk ->
        let hunks = file_hunks file in
        let total = List.length hunks in
        let index =
          let rec find i = function
            | [] -> 1
            | h :: rest ->
                if Spice_diff.Hunk.equal h hunk then i else find (i + 1) rest
          in
          find 1 hunks
        in
        [ (Printf.sprintf "hunk %d/%d" index total, Style.muted) ]
  in
  joined
    (((path_string path, Style.muted) :: hunk_word)
    @ [ state; (counts_word file, Style.muted) ])

let cr_scope_line occ =
  let location =
    Printf.sprintf "%s:%d"
      (Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ))
      (Spice_cr.Occurrence.line occ)
  in
  let handle, state =
    match Spice_cr.Occurrence.comment occ with
    | Ok cr ->
        let handle =
          match Spice_cr.recipient cr with
          | Some h -> "CR " ^ Spice_cr.Handle.to_string h
          | None -> "CR"
        in
        let state =
          match Spice_cr.status cr with
          | Spice_cr.Status.Open _ -> "open"
          | Spice_cr.Status.Resolved _ -> "resolved"
        in
        (handle, state)
    | Error _ -> ("CR", "malformed")
  in
  joined
    [ (location, Style.muted); (handle, Style.muted); (state, Style.muted) ]

(* {1 Bodies} *)

let opaque_body kind =
  let word =
    match kind with `Binary -> "binary file" | `Too_large -> "large file"
  in
  [
    Mosaic.text ~style:Style.muted ~wrap:`Word
      ("  " ^ word ^ " — cannot render as text");
  ]

let cursor_color ~focused =
  if focused then Style.color_accent else Style.color_muted

(* The diff widget reports the exact source line clicked; we turn it into a Line
   scope for the host. The line is the unit of attention, so clicks are lines. *)
let line_click_handler ~path on_line_click =
  match on_line_click with
  | None -> None
  | Some f ->
      Some
        (fun hit ->
          match hit.Mosaic.Diff.source with
          | Some sl ->
              Some
                (f
                   (Spice_review.Scope.Line
                      ( scope_side (Source_line.side sl),
                        path,
                        Source_line.line sl )))
          | None -> None)

(* The gutter cursor and its subtle highlight sit on the attention line, unless
   the pane is dimmed (a compose dialog owns attention). *)
let cursor_effects ~focused ~dimmed cursor_line =
  if dimmed then ([], [])
  else
    let signs = cursor_signs ~color:(cursor_color ~focused) cursor_line in
    let highlights =
      match cursor_line with
      | Some (side, n) ->
          [
            line_highlight ~base:(cursor_color ~focused) ~alpha:cursor_alpha
              side n;
          ]
      | None -> []
    in
    (signs, highlights)

(* The compose anchor gets a distinct, stronger wash so the CR's landing line is
   unmistakable while the panes are dimmed behind the dialog. *)
(* [compose_line] is a [(path_string, line)] anchor; matched by string so an Add
   target's relative path and an occurrence's boundary path unify. *)
let compose_highlight file compose_line =
  match compose_line with
  | Some (path, n)
    when String.equal path (path_string (Spice_review.Feature.File.path file))
    ->
      [
        line_highlight ~base:Style.color_warning ~alpha:compose_alpha
          Mosaic.Diff.New n;
      ]
  | _ -> []

let hunk_node review file ~cursor_line ~compose_line ~focused ~dimmed
    ~on_line_click hunk =
  let path = Spice_review.Feature.File.path file in
  let reviewed = reviewed_hunk review path hunk in
  let theme =
    if reviewed then Style.diff_quieted
    else if dimmed then Style.diff_dimmed
    else Style.diff_theme
  in
  let text_style = if dimmed then dimmed_text_style else diff_text_style in
  let line_signs, cursor_hl = cursor_effects ~focused ~dimmed cursor_line in
  diff_node ~theme ~line_signs
    ~line_highlights:(cursor_hl @ compose_highlight file compose_line)
    ~text_style
    ?on_line_click:(line_click_handler ~path on_line_click)
    (Mosaic.Diff.Patch.make [ patch_hunk hunk ])

let hunks_body review file ~cursor_line ~compose_line ~focused ~dimmed
    ~on_line_click =
  List.map
    (hunk_node review file ~cursor_line ~compose_line ~focused ~dimmed
       ~on_line_click)
    (file_hunks file)

(* Full-file context: recompute the diff at effectively-infinite context so the
   whole file shows with changed lines highlighted. One node; the attention line
   still carries its cursor and highlight. *)
let full_context_body review file ~cursor_line ~compose_line ~focused ~dimmed
    ~on_line_click =
  let path = Spice_review.Feature.File.path file in
  let before =
    Option.value (Spice_review.Feature.File.before file) ~default:""
  in
  let after = Option.value (Spice_review.Feature.File.after file) ~default:"" in
  match Spice_diff.hunks ~context:max_int ~before ~after () with
  | None | Some [] ->
      hunks_body review file ~cursor_line ~compose_line ~focused ~dimmed
        ~on_line_click
  | Some hunks ->
      let reviewed =
        Spice_review.is_reviewed review (Spice_review.Scope.File path)
      in
      let theme =
        if reviewed then Style.diff_quieted
        else if dimmed then Style.diff_dimmed
        else Style.diff_theme
      in
      let text_style = if dimmed then dimmed_text_style else diff_text_style in
      let line_signs, cursor_hl = cursor_effects ~focused ~dimmed cursor_line in
      [
        diff_node ~theme ~line_signs
          ~line_highlights:(cursor_hl @ compose_highlight file compose_line)
          ~text_style
          ?on_line_click:(line_click_handler ~path on_line_click)
          (Mosaic.Diff.Patch.make (List.map patch_hunk hunks));
      ]

let file_body review file ~cursor_line ~compose_line ~focused ~dimmed
    ~on_line_click ~full_context =
  match Spice_review.Feature.File.content file with
  | Spice_review.Feature.File.Opaque kind -> opaque_body kind
  | Spice_review.Feature.File.Text _ ->
      if full_context then
        full_context_body review file ~cursor_line ~compose_line ~focused
          ~dimmed ~on_line_click
      else
        hunks_body review file ~cursor_line ~compose_line ~focused ~dimmed
          ~on_line_click

(* A CR anchored outside any hunk: a context-only window around the anchor line,
   line numbers on, no add/del backgrounds. The anchor line keeps its cursor. *)
let cr_context_body ~focused ~dimmed ~compose_line ~on_line_click occ file =
  let line = Spice_cr.Occurrence.line occ in
  match Option.bind file Spice_review.Feature.File.after with
  | None ->
      [
        Mosaic.text ~style:Style.muted ~wrap:`Word
          ("  " ^ Spice_cr.Occurrence.raw occ);
      ]
  | Some after ->
      let lines = Array.of_list (String.split_on_char '\n' after) in
      let n = Array.length lines in
      let first = max 1 (line - 6) in
      let last = min n (line + 6) in
      let body =
        List.init
          (max 0 (last - first + 1))
          (fun i ->
            {
              Mosaic.Diff.Patch.tag = Mosaic.Diff.Patch.Context;
              content = lines.(first - 1 + i);
            })
      in
      let hunk =
        {
          Mosaic.Diff.Patch.old_start = first;
          old_lines = List.length body;
          new_start = first;
          new_lines = List.length body;
          lines = body;
        }
      in
      let line_signs, cursor_hl =
        cursor_effects ~focused ~dimmed (Some (Mosaic.Diff.New, line))
      in
      let compose_hl =
        Option.fold ~none:[]
          ~some:(fun file -> compose_highlight file compose_line)
          file
      in
      let on_click =
        Option.bind file (fun file ->
            line_click_handler
              ~path:(Spice_review.Feature.File.path file)
              on_line_click)
      in
      [
        diff_node ~theme:Style.diff_theme ~line_signs
          ~line_highlights:(cursor_hl @ compose_hl)
          ~text_style:(if dimmed then dimmed_text_style else diff_text_style)
          ?on_line_click:on_click
          (Mosaic.Diff.Patch.make [ hunk ]);
      ]

(* A CR anchored inside a hunk: the file diff, cursor on the anchor line. *)
let anchor_in_hunk file line =
  List.exists
    (fun hunk ->
      let first = Spice_diff.Hunk.new_start hunk in
      let last = first + Spice_diff.Hunk.new_count hunk - 1 in
      line >= first && line <= last)
    (file_hunks file)

(* {1 Auto-scroll} *)

(* The attention line's zero-based row within the stacked hunk nodes: prior
   hunks' line counts plus its index in its own hunk. Approximate under
   wrapping, which is enough to keep it on screen. *)
let line_index hunk (side, n) =
  let matches l =
    match side with
    | Mosaic.Diff.New -> Spice_diff.Hunk.Line.new_line l = Some n
    | Mosaic.Diff.Old -> Spice_diff.Hunk.Line.old_line l = Some n
  in
  let rec go i = function
    | [] -> None
    | l :: rest -> if matches l then Some i else go (i + 1) rest
  in
  go 0 (Spice_diff.Hunk.lines hunk)

let content_row file cursor_line =
  let rec go acc = function
    | [] -> None
    | hunk :: rest -> (
        match line_index hunk cursor_line with
        | Some i -> Some (acc + i)
        | None -> go (acc + List.length (Spice_diff.Hunk.lines hunk)) rest)
  in
  go 0 (file_hunks file)

let side_tag = function Mosaic.Diff.Old -> "o" | Mosaic.Diff.New -> "n"

(* A one-shot reveal keyed on the cursor, so it re-fires on every cursor change
   but not after a manual scroll (Scroll_box's reveal contract). The margin is
   a third of the viewport: line steps stay put until the cursor nears an edge,
   and a hunk jump lands with a third of the pane visible past the target
   instead of parking it on the bottom row. *)
let reveal_of ~viewport file cursor_line =
  match cursor_line with
  | None -> None
  | Some (side, n) -> (
      match content_row file (side, n) with
      | None -> None
      | Some y ->
          Some
            {
              Mosaic.Scroll_box.key =
                Printf.sprintf "rl-%s-%s%d"
                  (path_string (Spice_review.Feature.File.path file))
                  (side_tag side) n;
              x = None;
              y = Some y;
              align_x = `Nearest;
              align_y = `Nearest;
              margin = max 2 (viewport / 3);
            })

(* {1 View} *)

(* The attention line: the Line cursor, else the Hunk cursor's first line. *)
let attention hunk line =
  match line with Some l -> Some l | None -> Option.map hunk_anchor hunk

let view ?width:_ ?height ?(focused = true) ?(dimmed = false) ?compose_anchor
    ?on_line_click review ~full_context =
  let body_height =
    match height with None -> 20 | Some height -> max 3 (height - 2)
  in
  let scope, body, reveal =
    match target review with
    | Nothing ->
        ( None,
          [ Mosaic.text ~style:Style.muted ~wrap:`Word "  nothing to show" ],
          None )
    | File_diff { file; hunk; line } ->
        let cursor_line = attention hunk line in
        ( Some (file_scope_line review file hunk),
          file_body review file ~cursor_line ~compose_line:compose_anchor
            ~focused ~dimmed ~on_line_click ~full_context,
          if full_context then None
          else reveal_of ~viewport:body_height file cursor_line )
    | Cr_anchor (occ, file) ->
        let line = Spice_cr.Occurrence.line occ in
        let in_hunk =
          match file with Some f -> anchor_in_hunk f line | None -> false
        in
        let body =
          match file with
          | Some f when in_hunk ->
              file_body review f
                ~cursor_line:(Some (Mosaic.Diff.New, line))
                ~compose_line:compose_anchor ~focused ~dimmed ~on_line_click
                ~full_context
          | _ ->
              cr_context_body ~focused ~dimmed ~compose_line:compose_anchor
                ~on_line_click occ file
        in
        let reveal =
          match file with
          | Some f when in_hunk && not full_context ->
              reveal_of ~viewport:body_height f (Some (Mosaic.Diff.New, line))
          | _ -> None
        in
        (Some (cr_scope_line occ), body, reveal)
  in
  let scroll =
    Mosaic.scroll_box ~key:"review-diff" ~scroll_y:true ~show_scrollbars:false
      ?reveal
      ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.px body_height }
      body
  in
  (match scope with None -> [] | Some line -> [ line; Mosaic.empty ])
  @ [ scroll ]
