(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The design language for the TUI: color roles, the glyph vocabulary, and the
    brand marks.

    This is one flat constant vocabulary with no invariants, gathered in one
    place so the design language reads top to bottom. The heap in particular is
    deliberately both a brand mark and the footer context meter — brand and
    telemetry are the same drawing. *)

(** {1:colors Color roles}

    [accent] is the single brand hue (paprika): the lockup, the heap, the
    selection cursor, spinners, and active-input affordances. [success],
    [warning], and [error] are outcome colors and mean nothing else. [muted] is
    secondary text, [faint] tertiary text, and [rule] horizontal rules and quiet
    borders. The mode colors are state colors owned by the composer frame —
    never prose, never rules elsewhere, never outcomes. *)

val color_accent : Mosaic.Ansi.Color.t
(** [color_accent] is paprika [rgb(214, 96, 60)] — the one brand hue. *)

val color_mode_plan : Mosaic.Ansi.Color.t
(** [color_mode_plan] is the steel blue [rgb(125, 152, 220)] of the plan-mode
    composer frame and its chips. *)

val color_mode_review : Mosaic.Ansi.Color.t
(** [color_mode_review] is the violet [rgb(156, 138, 224)] of the review-mode
    composer frame and its chips. *)

val color_history : Mosaic.Ansi.Color.t
(** [color_history] is the teal [rgb(78, 176, 152)] of the history-search input
    mode: the [⌕] marker and its footer badge, nothing else. *)

val color_chip_fg : Mosaic.Ansi.Color.t
(** [color_chip_fg] is the near-black foreground of every filled chip; the chip
    background is the color its frame currently wears. *)

val color_muted : Mosaic.Ansi.Color.t
(** [color_muted] is secondary text. *)

val color_faint : Mosaic.Ansi.Color.t
(** [color_faint] is tertiary text. *)

val color_rule : Mosaic.Ansi.Color.t
(** [color_rule] is horizontal rules and quiet borders. *)

val color_success : Mosaic.Ansi.Color.t
(** [color_success] is the positive outcome color. *)

val color_warning : Mosaic.Ansi.Color.t
(** [color_warning] is the caution outcome color. *)

val color_error : Mosaic.Ansi.Color.t
(** [color_error] is the failure outcome color. *)

val color_user_bg : Mosaic.Ansi.Color.t
(** [color_user_bg] is the background wash behind user-authored transcript
    lines. *)

val color_hover_bg : Mosaic.Ansi.Color.t
(** [color_hover_bg] is the subtle wash behind a focused list row. *)

val color_overlay : Mosaic.Ansi.Color.t
(** [color_overlay] is the opaque near-black backdrop a transient overlay paints
    to occlude the content beneath it — the terminal-default color is
    transparent (alpha 0), so an overlay that must hide what it covers fills
    with this instead. It backs the app notice a screen overlays on its bottom
    row. *)

val color_code_kw : Mosaic.Ansi.Color.t
(** [color_code_kw] is the soft violet of keywords inside code fences. It and
    {!color_code_str} are L/C-matched below the outcome colors so nothing in a
    fence can read as success/error/warning; they appear only inside fences. *)

val color_code_str : Mosaic.Ansi.Color.t
(** [color_code_str] is the soft green of string literals inside code fences.
    See {!color_code_kw}. *)

val accent : Mosaic.Ansi.Style.t
(** [accent] is bold {!color_accent} text — the brand style. *)

val atom : Mosaic.Ansi.Style.t
(** [atom] is unbolded {!color_accent} text for app-owned tokens: file
    references, paste chunks, and inline slash commands. *)

val muted : Mosaic.Ansi.Style.t
(** [muted] is {!color_muted} text. *)

val faint : Mosaic.Ansi.Style.t
(** [faint] is {!color_faint} text. *)

val rule : Mosaic.Ansi.Style.t
(** [rule] is {!color_rule} text. *)

val bold : Mosaic.Ansi.Style.t
(** [bold] is bold default-foreground text. *)

val success : Mosaic.Ansi.Style.t
(** [success] is bold {!color_success} text. *)

val warning : Mosaic.Ansi.Style.t
(** [warning] is bold {!color_warning} text. *)

val error : Mosaic.Ansi.Style.t
(** [error] is bold {!color_error} text. *)

val user : Mosaic.Ansi.Style.t
(** [user] is the {!color_user_bg} background wash. *)

val thinking : Mosaic.Ansi.Style.t
(** [thinking] is muted italic — reasoning: the [∴] mark, the settled thought
    one-liner, and the all-muted reasoning body. *)

val running : Mosaic.Ansi.Style.t
(** [running] is unbolded {!color_accent}, the running [⏺] dot and spinner. It
    is the accent role stripped of blink: a running tool is the only accent dot
    on screen and it holds still. *)

val code_kw : Mosaic.Ansi.Style.t
(** [code_kw] is {!color_code_kw} text — code-fence keywords, fences only. *)

val code_str : Mosaic.Ansi.Style.t
(** [code_str] is {!color_code_str} text — code-fence string literals, fences
    only. *)

val chip : color:Mosaic.Ansi.Color.t -> string -> _ Mosaic.t
(** [chip ~color label] is the filled chip: [label] with one padding space each
    side, drawn in {!color_chip_fg} on a [color] background. [color] is the
    frame color the chip's surface currently wears — {!color_rule} for a plain
    panel, a mode color for a dialog. One drawing is used for panel names,
    screen names, and the composer's mode chips. *)

(** {1:glyphs Glyph vocabulary}

    Every surface draws its marks, cursors, and separators from here so the same
    idea always looks the same. *)

val cursor : string
(** [cursor] prefixes the composer prompt and the selected list row (["❯ "]). *)

val separator : string
(** [separator] joins inline facts ([" · "]). *)


val problem : string
(** [problem] marks a problem line (["! "]). *)

val shell_marker : string
(** [shell_marker] (["!"]) replaces the prompt marker while the composer is in
    shell mode, drawn in {!warning}. *)

val history_marker : string
(** [history_marker] (["⌕"]) replaces the prompt marker while history search
    (ctrl+r) is active, drawn in {!color_history}. *)

val kind_file : string
(** [kind_file] (["+"]) keys a file row in the unified [@] completion list. *)

val kind_thread : string
(** [kind_thread] (["*"]) keys an agent-thread row in the unified [@] completion
    list. [◇] stays reserved for MCP resources. *)

val own_answer : string
(** [own_answer] (["✎"]) heads the permanent "type your own answer" row of a
    question dialog — the inline escape a question always offers. *)

(** The transcript glyph cast: six marks, one meaning each. Each carries its
    color from the surface that draws it — the mark is the shape, the
    {{!section:colors} color role} is the state. *)

val tool : string
(** [tool] ([⏺]) keys the model acting: an assistant text block and every tool
    header. The dot alone is colored — {!running} while live, {!muted} once
    settled, {!error} on failure. *)

val thought : string
(** [thought] ([∴]) keys the model thinking, drawn in {!thinking}. *)

val watcher : string
(** [watcher] ([⊙]) keys the world speaking — a data notice from a watcher. *)

val interrupted : string
(** [interrupted] ([◌]) keys a user interruption, drawn in {!muted}. *)

val failed : string
(** [failed] ([✗]) keys a failure, drawn in {!error}. *)

val gutter : string
(** [gutter] ([⎿]) opens a tool result line under its header. *)

val disclosure_closed : string
(** [disclosure_closed] ([▸]) ends a collapsed expandable summary, drawn
    {!faint} at rest. *)

val disclosure_open : string
(** [disclosure_open] ([▾]) marks an expanded summary. *)

val waiting : string
(** [waiting] ([⋯]) heads the static working line when a dialog owns the
    keyboard — no motion. *)

val panel_boundary : string
(** [panel_boundary] ([▔], upper-eighth block) is the full-width row a panel
    draws where it replaces the composer region, deliberately unlike every [─]
    rule. It is drawn in the panel's frame color. *)

val spinner_frames : string array
(** [spinner_frames] is the braille spinner cycle, drawn in {!running}: the
    working line's turning glyph and every running-tool dot animation. A view
    advances one frame per tick. *)

val mode_build : string
(** [mode_build] is the build-mode glyph ([⏵], forward). Build is the default
    and never shown; the glyph travels with the mode name everywhere else. *)

val mode_plan : string
(** [mode_plan] is the plan-mode glyph ([⏸], pause). *)

val mode_review : string
(** [mode_review] is the review-mode glyph ([⏴], look back). *)

val heap : string
(** [heap] is the heap ([▂▄▆▄▂]): the standalone brand mark and the settled
    context meter. *)

val heap_meter_levels : string array
(** [heap_meter_levels] are the context-meter heap renderings from most to least
    runway: [[|"▄▆█▆▄"; "▃▄▆▄▃"; "▂▃▄▃▂"; "▁▁▂▁▁"|]]. *)

(** {1:brand Brand}

    The lockup and the one sanctioned animation, the pour. A view renders these
    rows in {!accent} and never recolors, stretches, or repeats them. *)

val lockup : string list
(** [lockup] is the two-row wordmark, 23 columns wide, rendered in {!accent}:

    {v
    ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
    ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
    v}

    The i's tittle is a grain and a poured heap sits beside the name with one
    grain aloft. Facts sit to its right; the lockup earns no vertical clearance
    of its own. *)

type pour_frame = {
  grain : string;
      (** The 3-column grain slot, drawn on row 1 above the mound. *)
  mound : string;  (** The 5-column mound (the heap region of row 2). *)
}
(** One heap-region frame of the pour: both rows, so the grain can appear and
    vanish relative to the mound as a grain drops and lands. *)

val pour_frames : pour_frame array
(** [pour_frames] are the nine two-row renderings of the pour. A grain appears
    aloft, then vanishes as it lands and raises the mound one step: the mound
    grows through the pinned keyframes ["     "], ["  ▂  "], [" ▂▄▂ "],
    ["▂▄▄▄▂"], ["▂▄▆▄▂"] while the grain drops one grain at a time.
    [pour_frames.(8)] is the lockup's rest — the grain settled to the right
    ({!grain_aloft}) over the full {!heap} — so it matches {!lockup}
    byte-for-byte. A view renders one frame per ~80–150ms tick. *)

val grain_aloft : string
(** [grain_aloft] is the single falling grain ([·]): it drops through the pour
    and comes to rest as the lockup's aloft grain. *)
