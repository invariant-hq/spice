(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The panel form: the shared chrome every panel wears, and the filter law that
    classifies its keys (03-ia-screens-overlays.md §The three forms, §The filter
    law).

    A panel replaces the composer region below a full-width [▔] boundary while
    the transcript stays visible above (or, on the home stage, above the panel
    with the inset composer hidden). Its anatomy is one drawing: the boundary
    row, the panel's name as a filled chip, the content, then the panel's own
    hint line in place of the footer. The frame color tints the boundary and the
    chip — {!Theme.color_rule} (gray) for a plain panel, a mode color for a
    dialog.

    {!classify} is the filter law the shells own so no concrete surface
    re-derives it: every printable narrows the filter, a digit jump-picks while
    the filter is empty, and the rest are action keys. *)

(** The action keys a panel resolves — non-printables and chords, never letters
    (03-ia §The filter law). *)
type action =
  | Enter  (** Resolve the selection. *)
  | Escape  (** The safe exit (the esc ladder's topmost rung). *)
  | Tab  (** Promote / switch (unused until the browse screen lands). *)
  | Left  (** Left, an action key on a panel. *)
  | Right  (** Right, an action key on a panel. *)
  | Up  (** Move the selection up. *)
  | Down  (** Move the selection down. *)
  | Backspace  (** Shorten the filter by one character. *)
  | Ctrl_d  (** The [ctrl+d] chord. *)
  | Other
      (** Every non-printable key or chord not named above; a surface lets it
          die (a panel is modal below the boundary). *)

(** The classification of a key event under the filter law. *)
type key =
  | Printable of string
      (** A printable character with no ctrl/alt/super held, as its UTF-8
          encoding: it narrows the filter. *)
  | Digit of int
      (** A bare decimal digit [0]–[9]. It jump-picks the nth row while the
          filter is empty and narrows (as the digit's own text) once the filter
          is non-empty — the split a surface applies. Reported apart from
          {!Printable} so the surface need not re-parse it. *)
  | Action of action  (** A non-printable key or recognized chord. *)

val classify : Matrix.Input.Key.event -> key
(** [classify ev] is [ev]'s class under the filter law: {!Printable} for a bare
    printable character, {!Digit} for a bare decimal digit, and {!Action}
    otherwise. [ctrl+d] classifies as [Action Ctrl_d]; [ctrl+p]/[ctrl+n] are the
    chorded aliases for the arrows and classify as [Action Up]/[Action Down], as
    do [pageup]/[pagedown] (a short panel list steps rather than pages); any
    other printable held with ctrl/alt/super, and any control character,
    classify as [Action Other]. Shift is not a chord — a capital letter is
    {!Printable}. Backspace and Delete both classify as [Action Backspace]. *)

val view :
  frame:Mosaic.Ansi.Color.t ->
  name:string ->
  filter:string ->
  hint:string list ->
  width:int ->
  content:'a Mosaic.t list ->
  'a Mosaic.t
(** [view ~frame ~name ~filter ~hint ~width ~content] is the panel shell,
    bottom-anchored where the composer and footer were: a full-width [▔]
    boundary row in [frame], the [name] as a filled chip beneath it (with the
    current [filter] echoed faint to its right when non-empty — a panel has no
    filter line of its own), the [content] rows, then the [hint] affordances
    joined as the panel's own footer row. Every row spans [width]. [hint] holds
    only affordances that work in the current build (the honest-hint rule,
    doc/plans/tui-next.md). *)
