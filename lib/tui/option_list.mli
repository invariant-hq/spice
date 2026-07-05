(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The numbered, cursor-navigated option list every decision dialog is built
    around (07-dialogs.md §Shared anatomy).

    Every visible option is numbered [1..N] and the number is a direct shortcut;
    the selected row shows [❯] and its number in {!Theme.color_accent}, the rest
    a blank cursor in {!Theme.muted}. Arrows and [ctrl+p]/[ctrl+n] move the
    cursor and [enter] confirms it — the number and the cursor never disagree
    because the number is the row's own label prefix. This module owns the
    cursor state and the one row drawing so no dialog re-derives either; each
    dialog supplies its own option labels and interprets the confirmed index. *)

type t
(** The type for an option-list cursor over a fixed number of rows.
    Invariant: the selected index is in [0, count). *)

val make : count:int -> t
(** [make ~count] is a cursor over [count] rows, selecting the first. [count] is
    clamped to at least one. *)

val selected : t -> int
(** [selected t] is the 0-based index of the selected row. *)

val up : t -> t
(** [up t] moves the cursor to the previous row, wrapping to the last from the
    first. *)

val down : t -> t
(** [down t] moves the cursor to the next row, wrapping to the first from the
    last. *)

val jump : int -> t -> t
(** [jump n t] selects the 1-based option [n] (the digit shortcut), or leaves
    [t] unchanged when [n] is outside [1..count]. *)

(** A row's checkbox state for a multi-select list, or its absence. *)
type checkbox = No_box | Checked | Unchecked

val row :
  selected:bool ->
  ?checkbox:checkbox ->
  number:int ->
  label:'a Mosaic.t ->
  unit ->
  'a Mosaic.t
(** [row ~selected ?checkbox ~number ~label ()] is one option row: the [❯]
    cursor (or a blank) then, for a multi-select list, the [[x]]/[[ ]]
    [checkbox], then ["N."] and the [label] node. The cursor, number, and a
    checked box render in {!Theme.color_accent} when [selected], else in
    {!Theme.muted}; [label] carries its own styling. [checkbox] defaults to
    {!No_box} (a single-select list draws no box). *)
