(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

(* Color roles (00-overview.md §Color roles). Values track tui-next's Theme:
   [color_accent] is paprika, the one brand hue; [success]/[warning]/[error] are
   outcome colors and mean nothing else; [muted]/[faint] are secondary/tertiary
   text; [rule] is horizontal rules. *)

let color_muted = Ansi.Color.grayscale ~level:14
let color_faint = Ansi.Color.grayscale ~level:11
let color_rule = Ansi.Color.grayscale ~level:8

(* Synced by hand with Spice_tui.Theme.color_accent (Theme is private to
   spice_tui, so it cannot be shared); change both together. *)
let color_accent = Ansi.Color.of_rgb 214 96 60
let color_success = Ansi.Color.of_rgb 77 217 128
let color_warning = Ansi.Color.of_rgb 235 180 76
let color_error = Ansi.Color.of_rgb 255 95 95

(* Opaque backdrop for the compose dialog — the review screen's one sanctioned
   filled surface (11-review.md). Dark enough to sit over the dimmed panes. *)
let color_overlay = Ansi.Color.grayscale ~level:2

(* Text styles. *)

let muted = Ansi.Style.make ~fg:color_muted ()
let faint = Ansi.Style.make ~fg:color_faint ()
let rule = Ansi.Style.make ~fg:color_rule ()
let bold = Ansi.Style.make ~bold:true ()
let accent = Ansi.Style.make ~fg:color_accent ~bold:true ()
let success = Ansi.Style.make ~fg:color_success ~bold:true ()
let warning = Ansi.Style.make ~fg:color_warning ~bold:true ()
let error = Ansi.Style.make ~fg:color_error ~bold:true ()

(* Glyphs (00-overview.md §Glyph vocabulary). [cursor_blank] keeps unselected
   rows aligned with [cursor] rows. *)

let cursor = "❯ "
let cursor_blank = "  "
let problem = "! "
let separator = " · "
let v_separator = "│"
let tree_group = "▾"
let todo_pending = "[ ]"
let todo_done = "[✓]"

(* Layout helpers. *)

let default_rule_width = 100

let repeat glyph width =
  let buffer = Buffer.create (width * String.length glyph) in
  for _ = 1 to width do
    Buffer.add_string buffer glyph
  done;
  Buffer.contents buffer

(* [panel_rule] tops a full-screen panel. One rule idiom: every rule is "─" in
   the rule color. *)
let panel_rule ?(width = default_rule_width) () =
  Mosaic.text ~style:rule ~wrap:`None (repeat "─" width)

(* [window ~limit ~selected ~count] is the [(start, length)] slice of a
   [count]-row list that keeps [selected] visible within [limit] rows. *)
let window ~limit ~selected ~count =
  if count <= limit then (0, count)
  else
    let start = min (max 0 (selected - limit + 1)) (count - limit) in
    (start, limit)

(* Scroll indicators for windowed lists. *)
let scrolled_above count =
  Mosaic.text ~style:muted ~wrap:`None (Printf.sprintf "  ↑ %d more" count)

let scrolled_below count =
  Mosaic.text ~style:muted ~wrap:`None (Printf.sprintf "  ↓ %d more" count)

let pad_right width value =
  if String.length value >= width then value
  else value ^ String.make (width - String.length value) ' '

(* Diff themes. [diff_theme] matches the transcript's diff rendering so every
   diff in spice reads the same; [diff_quieted] is the reviewed-scope variant,
   which drops the add/del backgrounds and mutes the signs so settled content
   stops shouting (11-review.md §File diff). *)

let color_diff_add_bg = Ansi.Color.of_rgb 16 64 32
let color_diff_del_bg = Ansi.Color.of_rgb 72 24 32
let color_diff_add_gutter_bg = Ansi.Color.of_rgb 10 44 24
let color_diff_del_gutter_bg = Ansi.Color.of_rgb 50 16 22

let diff_theme =
  {
    Mosaic.Diff.default_theme with
    Mosaic.Diff.added_bg = color_diff_add_bg;
    removed_bg = color_diff_del_bg;
    added_line_number_bg = Some color_diff_add_gutter_bg;
    removed_line_number_bg = Some color_diff_del_gutter_bg;
    line_number_fg = color_muted;
  }

(* Dimmed variant for when the compose dialog owns the screen: the same picture,
   darker — backgrounds halved, signs and numbers faint — so the diff reads as
   dimmed instead of losing its colors. *)
let dimmed_color color =
  let r, g, b = Ansi.Color.to_rgb color in
  Ansi.Color.of_rgb (r / 2) (g / 2) (b / 2)

let diff_dimmed =
  {
    diff_theme with
    Mosaic.Diff.added_bg = dimmed_color color_diff_add_bg;
    removed_bg = dimmed_color color_diff_del_bg;
    added_line_number_bg = Some (dimmed_color color_diff_add_gutter_bg);
    removed_line_number_bg = Some (dimmed_color color_diff_del_gutter_bg);
    line_number_fg = color_faint;
    added_sign_color = color_faint;
    removed_sign_color = color_faint;
  }

(* Reviewed scopes: backgrounds flattened to the terminal default and the +/-
   signs muted. Foreground muting comes from the caller's [text_style]. No new
   colors, only the drop. *)
let diff_quieted =
  {
    diff_theme with
    Mosaic.Diff.added_bg = Ansi.Color.default;
    removed_bg = Ansi.Color.default;
    added_line_number_bg = None;
    removed_line_number_bg = None;
    added_sign_color = color_muted;
    removed_sign_color = color_muted;
  }
