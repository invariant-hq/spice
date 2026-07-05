(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The [?] shortcuts sheet: the composer keybindings, grouped into columns.

    The sheet drops below the composer when [?] is pressed on an empty draft
    (03-composer.md §Keybindings). It is a pure view over a list of titled
    {!section}s, each a column of key/action rows. The data — which shortcuts
    exist — is the caller's, so the shell keeps the sheet honest to the keys it
    actually binds; {!sections} is the canonical set for the full composer to
    start from. *)

(** {1:types Types} *)

type entry = {
  keys : string;  (** The key or chord, e.g. ["ctrl+r"] or ["shift+enter"]. *)
  action : string;  (** What the key does, e.g. ["search history"]. *)
}
(** The type for one shortcut: a key and the action it triggers. *)

type section = {
  title : string;  (** The group's heading, e.g. ["composer"]. *)
  entries : entry list;
}
(** The type for a group of related shortcuts, rendered as one column. *)

(** {1:data Data} *)

val sections : section list
(** [sections] is the canonical shortcut set for the full composer, grouped for
    display. The shell trims it to the keys the current surface binds so the
    sheet never advertises an inactive shortcut. *)

(** {1:views Views} *)

val view : section list -> _ Mosaic.t
(** [view sections] renders the sheet as side-by-side columns, one per section:
    a muted title above [faint] keys aligned against their muted actions. Keys
    are drawn verbatim; the caller keeps the section count small enough to fit
    the terminal width. *)
