(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Assistant markdown and the reasoning body (01-transcript.md §Assistant text
    and markdown, §Reasoning).

    Both renderers wrap {!Mosaic.markdown} under an explicit style: monochrome
    prose with exactly one accent (inline code), and the all-muted-italic
    reasoning variant. Neither adds a gutter — the caller ({!Transcript}) owns
    the [⏺]/[∴] column.

    Code fences are highlighted in place through {!Mosaic.markdown}'s
    [code_syntax] hook (01-transcript.md §Code fences): markdown renders each
    fence itself as a borderless code view — no border, background, or gutter —
    and the hook returns tree-sitter highlights mapped by a subdued, fence-only
    style to {!Theme.code_kw} / {!Theme.code_str} / muted. There is no
    hand-rolled lexing — a language without a shipped grammar renders as plain
    monochrome code, and the ladder climbs only by adding grammars to the
    tree-sitter package. The worst case is plain default-foreground code, never
    a miscolored fence, and a fence nested in a list or blockquote keeps its
    context. *)

val view : ?streaming:bool -> string -> _ Mosaic.t
(** [view md] renders assistant markdown [md]. Code fences take the ladder;
    everything else takes the prose style. [streaming] (default [false]) tells
    the markdown renderer to tolerate an unclosed trailing construct as it
    arrives — the live assistant tail passes [true]. A streaming view renders
    fences on the ladder's plain rung (highlighting is settled-only:
    re-highlighting a growing fence per delta is quadratic tree-sitter work on
    the UI domain); the settled block colors them. *)

val thinking : ?streaming:bool -> string -> _ Mosaic.t
(** [thinking md] renders reasoning markdown [md] all-muted italic: structure
    survives (bold, italic, rules) but nothing shouts, and fences stay muted
    rather than taking the fence palette (reasoning is quiet by construction).
    [streaming] is as in {!view}. *)
