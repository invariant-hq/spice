(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The CR compose dialog: a compact opaque box floating over the dimmed panes.

    The dialog holds a single-line [draft] carrying the CR grammar itself
    (parsing happens on submit, in the component). Unlike the old TUI, the input
    is {e app-owned and painted}, not a native [Mosaic.input]: the review screen
    owns its keyboard wholly (no native widget, no key passthrough), so the
    component folds printables and backspace into the draft with {!append} and
    {!backspace}, and this module paints a cursor glyph at the insertion point.
    A parse or write problem renders as a [! …] line under the input with the
    draft preserved. *)

(** The type for what the compose targets. *)
type target =
  | Add of { path : Spice_path.Rel.t; line : int }
      (** Insert a new CR before [line] of [path]. *)
  | Edit of { occurrence : Spice_cr.Occurrence.t; ordinal : int }
      (** Rewrite [occurrence]. [ordinal] is [occurrence]'s zero-based ordinal
          among CRs with the same path and digest when the dialog opened. Submit
          re-resolves by identity and ordinal against the current review, so
          duplicate identical CRs cannot repoint the edit at the first match
          after a refresh. *)
  | Resolve of { occurrence : Spice_cr.Occurrence.t; ordinal : int }
      (** Resolve [occurrence] (prefilled with the [XCR] form). Captured by
          identity and [ordinal] like {!Edit}. *)

type t
(** The type for a compose session: its target, draft, and any problem line. *)

val make : target:target -> draft:string -> t
(** [make ~target ~draft] is a fresh compose session, no problem shown. *)

val target : t -> target
(** [target t] is [t]'s target. *)

val draft : t -> string
(** [draft t] is [t]'s current draft text. *)

val with_draft : t -> string -> t
(** [with_draft t draft] replaces the draft and clears any problem. *)

val with_problem : t -> string -> t
(** [with_problem t message] shows [message] as the [! …] line, draft kept. *)

val append : t -> string -> t
(** [append t s] appends printable text [s] to the draft and clears any problem.
*)

val backspace : t -> t
(** [backspace t] deletes the last UTF-8 codepoint of the draft (whole, never
    half) and clears any problem. *)

val dialog_width : int
(** [dialog_width] is the dialog's fixed column width. *)

val height : t -> int
(** [height t] is the dialog's row count (title + input + padding, plus an error
    line when a problem shows), so the panel can center it with an explicit
    inset. *)

val view : ?width:int -> t -> Spice_review.t -> _ Mosaic.t
(** [view t review] is the painted dialog: a muted title naming the target line,
    the draft with a painted accent cursor (a faint placeholder when empty), and
    a [! …] problem line when present, over an opaque {!Style.color_overlay}
    background. Renders no interactive widget — the component drives the draft.
*)
