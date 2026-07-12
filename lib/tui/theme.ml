(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

let color_accent = Ansi.Color.of_rgb 214 96 60
let color_mode_plan = Ansi.Color.of_rgb 125 152 220
let color_mode_review = Ansi.Color.of_rgb 156 138 224
let color_muted = Ansi.Color.grayscale ~level:14
let color_faint = Ansi.Color.grayscale ~level:11
let color_rule = Ansi.Color.grayscale ~level:8
let color_success = Ansi.Color.of_rgb 77 217 128
let color_warning = Ansi.Color.of_rgb 235 180 76
let color_error = Ansi.Color.of_rgb 255 95 95

(* History-search is an input mode (03-ia-screens-overlays.md §Composer input
   modes): teal, L/C-matched to paprika like the frame mode colors. It touches
   only the ⌕ marker and its footer badge. *)
let color_history = Ansi.Color.of_rgb 78 176 152

(* Filled-chip foreground (DELTAS: "fg = near-black, terminal bg tone"); the
   chip background is whatever color the frame currently wears. *)
let color_chip_fg = Ansi.Color.grayscale ~level:2
let color_user_bg = Ansi.Color.of_rgb 82 60 38
let color_hover_bg = Ansi.Color.grayscale ~level:3
let color_overlay = Ansi.Color.grayscale ~level:2
let color_code_kw = Ansi.Color.of_rgb 157 148 198
let color_code_str = Ansi.Color.of_rgb 143 174 150
let accent = Ansi.Style.make ~fg:color_accent ~bold:true ()
let atom = Ansi.Style.make ~fg:color_accent ()
let muted = Ansi.Style.make ~fg:color_muted ()
let faint = Ansi.Style.make ~fg:color_faint ()
let rule = Ansi.Style.make ~fg:color_rule ()
let bold = Ansi.Style.make ~bold:true ()
let success = Ansi.Style.make ~fg:color_success ~bold:true ()
let warning = Ansi.Style.make ~fg:color_warning ~bold:true ()
let error = Ansi.Style.make ~fg:color_error ~bold:true ()
let user = Ansi.Style.make ~bg:color_user_bg ()
let thinking = Ansi.Style.make ~fg:color_muted ~italic:true ()
let running = Ansi.Style.make ~fg:color_accent ()
let code_kw = Ansi.Style.make ~fg:color_code_kw ()
let code_str = Ansi.Style.make ~fg:color_code_str ()

(* The filled chip (03-ia-screens-overlays.md §Theme & glyph deltas): the label
   on the current frame color with the near-black {!color_chip_fg} foreground,
   one padding space each side. One drawing for panel names, screen names, and
   the composer's mode chips — the frame color is the only thing that varies. *)
let chip ~color label =
  text
    ~style:(Ansi.Style.make ~bg:color ~fg:color_chip_fg ())
    ~wrap:`None ~flex_shrink:0.
    (" " ^ label ^ " ")

let cursor = "❯ "
let separator = " · "

(* Input-mode markers replace the ❯ marker glyph itself; the history and kind
   glyphs are from the IA spec's vocabulary (03-ia-screens-overlays.md §Theme &
   glyph deltas). ◇ is reserved for MCP resources. *)
let shell_marker = "!"
let history_marker = "⌕"
let kind_file = "+"
let kind_thread = "*"
let own_answer = "✎"
let problem = "! "
let tool = "⏺"
let thought = "∴"
let watcher = "⊙"
let interrupted = "◌"
let failed = "✗"
let gutter = "⎿"
let disclosure_closed = "▸"
let disclosure_open = "▾"
let waiting = "⋯"

(* The panel boundary (03-ia-screens-overlays.md §Theme & glyph deltas): the
   upper-eighth block, deliberately unlike every [─] rule, marking where a panel
   replaces the composer region below the transcript. *)
let panel_boundary = "▔"

let spinner_frames = [| "⠋"; "⠙"; "⠹"; "⠸"; "⠼"; "⠴"; "⠦"; "⠧"; "⠇"; "⠏" |]

let mode_build = "⏵"
let mode_plan = "⏸"
let mode_review = "⏴"
let heap = "▂▄▆▄▂"

let heap_meter_levels = [| "▄▆█▆▄"; "▃▄▆▄▃"; "▂▃▄▃▂"; "▁▁▂▁▁" |]

let lockup = [ "▄▀▀ █▀▄ · ▄▀▀ ██▀   ·"; "▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂" ]

type pour_frame = { grain : string; mound : string }

(* The pour (08-brand.md §Motion, brand-preview.sh): nine two-row heap-region
   frames. Each carries a 3-column grain slot (row 1, above the mound's centre)
   and the 5-column mound (row 2). A grain appears aloft, then vanishes as it
   lands and raises the mound one step, so the grain visibly drops one grain at a
   time while the mound builds empty → ▂ → ▂▄▂ → ▂▄▄▄▂ → ▂▄▆▄▂. The closing frame
   is the lockup's rest — the grain settled to the right ({!grain_aloft}) over the
   full {!heap} — so the pour ends on the lockup byte-for-byte. *)
let pour_frames =
  [|
    { grain = " · "; mound = "     " };
    { grain = "   "; mound = "  ▂  " };
    { grain = " · "; mound = "  ▂  " };
    { grain = "   "; mound = " ▂▄▂ " };
    { grain = "·  "; mound = " ▂▄▂ " };
    { grain = "   "; mound = "▂▄▄▄▂" };
    { grain = " · "; mound = "▂▄▄▄▂" };
    { grain = "   "; mound = "▂▄▆▄▂" };
    { grain = "  ·"; mound = "▂▄▆▄▂" };
  |]

let grain_aloft = "·"
