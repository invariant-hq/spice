(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The screen form: the shared chrome every screen wears, and the key reader
    the filter law classifies against (03-ia-screens-overlays.md §The three
    forms, §The filter law).

    A screen owns the whole region — it is not a panel below a boundary. Its
    anatomy is one drawing: a top rule carrying the screen's name as a filled
    chip and a right-aligned fact ([── [sessions] ──…── 12 sessions ──]), an
    optional bare filter line, the content region, and the hint row.

    A screen never type-filters by default: letters are its keymap ([f] fork,
    [r] rename, [d] delete…). The [/] key opens the bare filter line, and only
    while that line is focused do printables narrow instead. {!classify} reports
    the neutral class of a key event; the concrete screen applies the filter law
    on top of it, knowing whether its filter is focused (the letter-vs-filter
    split is screen-specific because the keymap letters are). This mirrors
    {!Panel.classify}'s role for the panel form. *)

(** A non-printable key or recognized chord a screen resolves. *)
type action =
  | Enter  (** Confirm the selection (resume). *)
  | Escape  (** The safe exit: clear the filter first, then leave the screen. *)
  | Tab  (** Switch (unused by the sessions screen). *)
  | Up  (** Move the selection up. *)
  | Down  (** Move the selection down. *)
  | Left  (** Left. *)
  | Right  (** Right. *)
  | Backspace  (** Shorten the filter by one character. *)
  | Page_up  (** Page the wide pane up. *)
  | Page_down  (** Page the wide pane down. *)
  | Other
      (** Every non-printable key or chord not named above; a surface lets it
          die (a screen owns its keyboard). *)

(** The neutral classification of a key event. A screen with an unfocused filter
    reads a {!Char} as a letter keymap ([/] opening the filter); a screen with a
    focused filter reads the same {!Char} as filter input. *)
type key =
  | Char of string
      (** A printable character with no ctrl/alt/super held, as its UTF-8
          encoding — a keymap letter, a digit, or (unfocused) the [/] that opens
          the filter, or (focused) one narrowing character. *)
  | Action of action  (** A non-printable key or recognized chord. *)

val classify : Matrix.Input.Key.event -> key
(** [classify ev] is [ev]'s neutral class: {!Char} for a bare printable
    character (including ["/"] and digits), and {!Action} otherwise.
    [ctrl+p]/[ctrl+n] are the chorded aliases for the arrows and classify as
    [Action Up]/[Action Down]; any other printable held with ctrl/alt/super, and
    any control character, classify as [Action Other]. Shift is not a chord — a
    capital letter is {!Char}. Backspace and Delete both classify as
    [Action Backspace]. *)

type filter = { query : string; matches : int }
(** The bare filter line's state, when it is open: the typed [query] and the
    [matches] count of rows it keeps. *)

val view :
  frame:Mosaic.Ansi.Color.t ->
  name:string ->
  fact:string ->
  filter:filter option ->
  hint:string list ->
  width:int ->
  content:'a Mosaic.t list ->
  'a Mosaic.t
(** [view ~frame ~name ~fact ~filter ~hint ~width ~content] is the screen shell.
    The top rule spans [width] in [frame]: [── ] then the [name] as a filled
    chip ({!Theme.chip}), dashes filling to a right-aligned muted [fact], then a
    trailing [ ──] (the [── [sessions] ──…── 12 sessions ──] grammar). When
    [filter] is [Some], a bare filter line follows — an accent ["/"], the
    [query], then the [matches] count faint — with no rule, no cursor, and no
    placeholder (03-ia §The filter law). The [content] rows and the [hint]
    affordances (joined as the screen's footer row) close it. Every row spans
    [width]. [hint] holds only affordances that work in the current build (the
    honest-hint rule, doc/plans/tui-next.md). *)
