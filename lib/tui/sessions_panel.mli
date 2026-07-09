(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The session quick-switch panel (03-ia-screens-overlays.md §Sessions,
    quick-switch panel): the four most recent sessions in the workspace,
    type-to-filter, digit jump-pick, [↑↓] selection, esc closes.

    A mini-Elm surface (doc/plans/tui-next-surfaces.md): the shell holds [t],
    routes keys through {!key}, folds the resulting {!msg} with {!update} —
    which yields the next [t] and an {!event} the shell interprets — and renders
    {!view}. The panel never reads the shell's draft, config, clock, or the
    host; the runtime loads its rows and delivers them with {!loaded}, ages
    already formatted, or reports a transient store failure with {!failed}.

    [↵] (or a digit jump-pick) yields {!Resume} — the shell attaches and replays
    that session for real — and [tab] yields {!Promote}, opening the browse
    screen with the filter and selection carried over. The hint advertises both,
    now that they work (doc/plans/tui-next-surfaces.md §Sequencing 5). *)

type row = {
  id : Spice_session.Id.t;  (** The session a pick would resume. *)
  title : string;
      (** The display title ({!Spice_protocol.Session_summary.display_title}),
          never a raw id. *)
  age : string;
      (** The relative age of the last update, formatted by the runtime (mirrors
          {!Home.Brief.relative_age}). *)
  search_key : string;
      (** The filter key ({!Spice_protocol.Session_summary.search_key}): id,
          title, preview, and cwd, matched case-insensitively. *)
}
(** One quick-switch row. The runtime builds these from
    {!Spice_protocol.Session_summary.t}; the panel renders and filters them. *)

type t
(** The panel state: loading (rows not yet arrived), a store-error line, or
    loaded rows with a filter and a selection into the filtered rows. *)

type msg
(** A key routed to the panel, opaque; produced by {!key}. *)

(** The panel's outcome, which the shell interprets. *)
type event =
  | Stay  (** Remain open with the updated state. *)
  | Close  (** Esc: close and restore the composer unchanged. *)
  | Resume of Spice_session.Id.t
      (** A pick ([↵] on the selection, or a digit jump-pick while the filter is
          empty): resume that session — the shell attaches its
          {!Spice_host.Live} and replays it into the chat transcript. *)
  | Promote of { filter : string; select : Spice_session.Id.t option }
      (** [tab]: promote to the browse screen, carrying the current [filter]
          text and the [select]ed session so the screen opens where the panel
          left off (03-ia §Sessions). *)

val loading : t
(** [loading] is the panel just opened, before its rows arrive: {!view} renders
    a muted loading line and an empty filter. *)

val loaded : row list -> t -> t
(** [loaded rows t] folds the runtime-loaded [rows] into [t], keeping the
    current filter and clamping the selection to the newly filtered rows. Called
    once per open; a later load replaces the rows. *)

val failed : string -> t -> t
(** [failed message t] renders the store-error line [message] rather than the
    empty state, which would read as "no sessions" (the recorded honesty gap). A
    failed refresh keeps rows that already arrived. *)

val key : Matrix.Input.Key.event -> msg option
(** [key ev] is the panel's message for [ev] under the filter law
    ({!Panel.classify}), or [None] for a key the panel ignores — so it dies in
    the modal shell rather than leaking to a chord. *)

val update : msg -> t -> t * event
(** [update msg t] folds one key. A printable narrows the filter and resets the
    selection to the top; backspace shortens it (and clears to all rows when it
    empties); a digit jump-picks the nth filtered row while the filter is empty
    (out of range: no-op) and narrows otherwise; [↑]/[↓] move the selection
    (wrapping); [↵] yields {!Resume} of the selected row when one exists; [tab]
    yields {!Promote}; esc yields {!Close}. Every other message is [(t, Stay)].
*)

val view : frame:Mosaic.Ansi.Color.t -> width:int -> t -> _ Mosaic.t
(** [view ~frame ~width t] renders the panel through {!Panel.view}, [frame]
    tinting the boundary and the [sessions] chip: up to four rows (title left,
    right-aligned age), a [❯] accent cursor and hover tint on the selection, the
    muted loading line before rows arrive, the [! …] error line on a store
    failure, the one-sentence empty state when the workspace has none, the
    no-match line when the filter excludes all, and the honest hint. *)
