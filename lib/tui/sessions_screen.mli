(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The sessions browse screen (03-ia-screens-overlays.md §Sessions): every
    resumable session in the workspace, grouped by recency, one selected row
    expanding, with the [f]/[r]/[d] verbs and the [/] filter.

    A mini-Elm surface (doc/plans/tui-next-surfaces.md): the shell holds [t],
    routes keys through {!key}, folds the resulting {!msg} with {!update} — which
    yields the next [t] and an {!event} the shell interprets — and renders
    {!view}. The screen reads no clock, config, or host; the runtime loads its
    rows and delivers them with {!loaded}, ages and recency groups already
    computed (formatting and bucketing are the TUI's; the facts are the host's,
    §Host seams).

    Resume, fork, rename, and delete are outcomes the shell carries out against
    the host and reports back by reloading the rows: {!Resume} and {!Fork} attach
    a session; {!Rename} and {!Delete} mutate through the host lifecycle verbs
    ({!Spice_host.Session.save_title}, {!Spice_host.Session.delete}). Rename and
    delete confirm {e in place} — the row becomes an inline input or its own
    confirmation — so no composer borrow is involved.

    The wide-width transcript pane (03-ia §Sessions, ~100+ cols) is deferred: the
    screen renders the narrow layout at every width this iteration
    (doc/plans/tui-next-surfaces.md §Sequencing 2, wide pane stubbed). *)

(** A row's recency bucket, computed by the runtime from the last-update time
    against the current clock. Rows render under a muted, non-selectable header
    per bucket ([today] / [this week] / [older]). *)
type group = Today | This_week | Older

type row = {
  id : Spice_session.Id.t;  (** The session a pick would resume or fork. *)
  title : string;
      (** The display title ({!Spice_protocol.Session_summary.display_title}),
          never a raw id. *)
  age : string;
      (** The relative age of the last update, formatted by the runtime
          (mirrors {!Home.Brief.relative_age}). *)
  turns : int;
      (** The conversational turn count
          ({!Spice_protocol.Session_summary.turns}), rendered as the row's
          right-aligned [age · N turns] fact. *)
  preview : string option;
      (** The first user prompt ({!Spice_protocol.Session_summary.preview}),
          echoed faint under the selected row as its reason-to-recognize-it. *)
  lineage : string option;
      (** The fork lineage line for a forked session, e.g.
          [fork of "parser fix"], resolved by the runtime from
          {!Spice_protocol.Session_summary.forked_from} against the loaded set;
          [None] for a root session. *)
  cwd : string;
      (** The home-relative working directory, shown on the selected row's facts
          line. *)
  search_key : string;
      (** The filter key ({!Spice_protocol.Session_summary.search_key}): id,
          title, preview, and cwd, matched case-insensitively. *)
  group : group;  (** The recency bucket this row renders under. *)
}
(** One browse row. The runtime builds these from
    {!Spice_protocol.Session_summary.t}; the screen groups, filters, expands, and
    renders them. *)

type t
(** The screen state: loading, a store-error line, or loaded rows with the filter
    line, the selection, and any in-place rename/delete affordance. *)

type msg
(** A key routed to the screen, opaque; produced by {!key}. *)

(** The screen's outcome, which the shell interprets. Every mutation outcome is
    carried out host-side and reflected by reloading the rows. *)
type event =
  | Stay  (** Remain open with the updated state. *)
  | Close  (** Esc with the filter already closed: return to the prior view. *)
  | Resume of Spice_session.Id.t
      (** [↵] on the selection: resume that session (replay + attach). *)
  | Fork of Spice_session.Id.t
      (** [f] on the selection: fork that session and resume into the child. *)
  | Rename of { id : Spice_session.Id.t; title : string }
      (** [↵] committing an inline rename: persist [title] for [id]. *)
  | Delete of Spice_session.Id.t
      (** The second [d] of the inline confirmation: delete [id]. *)

val loading : t
(** [loading] is the screen just opened, before its rows arrive: {!view} renders
    a muted loading line, the filter closed. *)

val promoted : filter:string -> select:Spice_session.Id.t option -> t
(** [promoted ~filter ~select] is the screen opened by [tab] from the
    quick-switch panel, carrying the panel's [filter] text and [select]ed session
    over (03-ia §Sessions, "filter + selection carried over"). It starts loading;
    {!loaded} applies [filter] (opening the filter line when non-empty) and moves
    the selection to [select]'s row. *)

val loaded : row list -> t -> t
(** [loaded rows t] folds the runtime-loaded [rows] into [t]. From a loading or
    error state it seeds the rows, honoring any pending {!promoted} filter and
    selection; from a loaded state it replaces the rows, keeping the filter and
    clamping the selection (so a post-rename or post-delete reload lands on a
    valid row). *)

val failed : string -> t
(** [failed message] is the screen showing a store-error line rather than the
    empty state — the honesty a transient listing failure requires (the recorded
    quick-switch gap, applied to the screen too). *)

val key : Matrix.Input.Key.event -> msg option
(** [key ev] is the screen's message for [ev], or [None] for a key it ignores.
    The screen owns its keyboard, so an ignored key simply dies. *)

val update : msg -> t -> t * event
(** [update msg t] folds one key under the filter law (03-ia §The filter law):

    - {b Browsing, filter closed.} Letters are the keymap — [/] opens the filter,
      [f] yields {!Fork}, [r] enters the inline rename, [d] enters the inline
      delete confirmation; [↑]/[↓] move the selection (wrapping); [↵] yields
      {!Resume}; esc yields {!Close}.
    - {b Browsing, filter open.} Every printable narrows and resets the selection
      to the top; backspace shortens it; [↑]/[↓] and [↵] act on the filtered
      rows; esc closes the filter (the ladder's first rung) without leaving.
    - {b Renaming.} Printables and backspace edit the inline title; [↵] yields
      {!Rename} of the trimmed non-empty title (empty cancels); esc cancels.
    - {b Confirming delete.} A second [d] yields {!Delete}; any other key (esc
      included) restores the row.

    Every other message is [(t, Stay)]. *)

val view : frame:Mosaic.Ansi.Color.t -> width:int -> rows:int -> t -> _ Mosaic.t
(** [view ~frame ~width ~rows t] renders the screen through {!Screen.view},
    [frame] tinting the top rule and the [sessions] chip and the fact naming the
    session count. Rows group under muted recency headers ([today] / [this week]
    / [older]); the selected row wears the [❯] accent cursor and a hover tint and
    expands to a faint first-prompt echo and a facts line (cwd, plus [↳ fork of
    …] when forked); an inline rename replaces the selected title with the typed
    input, an inline delete replaces the row with its confirmation. [rows] bounds
    the visible window — sessions past the budget collapse into a muted [… +N
    older] tail, the selection kept in view. The muted loading, empty, no-match,
    and error lines each stand in for the content when there are no rows to show.
*)
