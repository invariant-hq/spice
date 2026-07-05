(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

(* The prose style: monochrome except the one accent (inline code). Every key is
   pinned so nothing inherits the terminal's defaults (01-transcript.md
   §Assistant text). H1 underlines, H2/H3 bold, H4+ bold muted; inline code is
   the unbolded accent ([atom]); rules and table borders are [rule]. The
   blockquote [▎] bar and its text share one style key, so both take
   muted-italic — the bar cannot be colored [rule] independently of the text. *)
let md_style : Markdown.style =
  let open Markdown in
  function
  | Default -> Ansi.Style.default
  | Heading 1 -> Ansi.Style.make ~bold:true ~underline:true ()
  | Heading (2 | 3) -> Ansi.Style.make ~bold:true ()
  | Heading _ -> Ansi.Style.make ~fg:Theme.color_muted ~bold:true ()
  | Emphasis -> Ansi.Style.make ~italic:true ()
  | Strong -> Ansi.Style.make ~bold:true ()
  | Code_span -> Theme.atom
  | Code_block -> Ansi.Style.default
  | Link -> Ansi.Style.make ~underline:true ()
  | Image -> Theme.muted
  | Blockquote -> Theme.thinking
  | Thematic_break -> Theme.rule
  | List_marker -> Theme.muted
  | Strikethrough -> Ansi.Style.make ~strikethrough:true ()
  | Task_marker -> Ansi.Style.make ~bold:true ()
  | Table_border -> Theme.rule
  | Conceal_punctuation -> Theme.faint

(* The reasoning variant: structure survives (bold, italic) but every element
   falls to muted or fainter (01-transcript.md §Reasoning). *)
let md_style_thinking : Markdown.style =
  let open Markdown in
  function
  | Heading _ | Strong | Task_marker ->
      Ansi.Style.make ~fg:Theme.color_muted ~bold:true ()
  | Emphasis | Blockquote -> Theme.thinking
  | Strikethrough -> Ansi.Style.make ~fg:Theme.color_muted ~strikethrough:true ()
  | Thematic_break | Table_border -> Theme.rule
  | Conceal_punctuation -> Theme.faint
  | Default | Code_span | Code_block | Link | Image | List_marker -> Theme.muted

(* ── Code fences: the degradation ladder ────────────────────────────────── *)

(* Fenced code is highlighted through tree-sitter and mapped to the fence
   palette: a shipped grammar turns the block into [(start, end, scope)] triples,
   and this subdued style maps scope families to the palette — keywords soft
   violet, strings soft green, comments muted, everything else default. Scope
   lookup falls back along dotted prefixes, so mapping the family roots covers
   their variants. The hues are L/C-matched below the outcome colors and appear
   only inside fences (01-transcript.md §Code fences). *)
let subdued_style =
  Syntax_style.make ~base:Ansi.Style.default
    [
      ("keyword", Theme.code_kw);
      ("string", Theme.code_str);
      ("comment", Theme.muted);
    ]

(* The degradation ladder is the set of shipped grammars: a language with a
   grammar highlights, one without renders as plain monochrome code. It climbs
   only by adding grammars to the tree-sitter package — never by hand-rolled
   keyword guessing. *)
let highlighter lang =
  match String.lowercase_ascii (String.trim lang) with
  | "ocaml" | "ml" -> Some Tree_sitter_ocaml.highlight_ocaml
  | "mli" -> Some Tree_sitter_ocaml.highlight_interface
  | "json" -> Some Tree_sitter_json.highlight
  | _ -> None

(* [Mosaic.markdown] renders each fence itself as a borderless code view — no
   border, background, or gutter (01-transcript.md §Code fences) — and asks this
   hook for the highlighting. It is a stable top-level value on purpose: the
   markdown widget compares props by physical equality, so a per-view closure
   would re-render and re-parse every frame. [None] leaves a fence plain, the
   ladder's monochrome rung; tree-sitter tolerates the unclosed body of a
   streaming tail. *)
let code_syntax ~language ~content =
  match Option.bind language highlighter with
  | Some highlight ->
      Some
        (Code.syntax ~style:subdued_style
           (Syntax_highlight.of_triples (highlight content)))
  | None -> None

(* Highlighting is settled-only: a streaming view re-parses on growth, and
   re-highlighting a growing fence from scratch each time is quadratic
   tree-sitter work on the UI domain — the dominant cost of the streamed-fence
   freeze. The tail therefore renders fences on the ladder's plain rung, and
   color lands when the block settles. *)
let view ?(streaming = false) md =
  if streaming then
    markdown ~md_style ~conceal:true ~streaming:true
      ~size:{ width = pct 100; height = auto }
      md
  else
    markdown ~md_style ~conceal:true ~code_syntax
      ~size:{ width = pct 100; height = auto }
      md

let thinking ?(streaming = false) md =
  markdown ~md_style:md_style_thinking ~conceal:true ~streaming
    ~size:{ width = pct 100; height = auto }
    md
