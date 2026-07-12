(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The permission dialog form.

    The asking tool's operation is the review surface: a command shows its
    verbatim [$] line and cwd, a file edit shows the proposed diff (from
    {!Spice_permission.Request.Change.diff}) with its [+A −B] counts collapsed
    to a window and expanded with [ctrl+o], and a bundled request shows a
    per-file list. The three options are allow once, allow this exact scope for
    the session — labelled honestly with the narrow scope an identical
    {!Spice_permission.Access.t} re-approves ("this command", "edits to
    lib/x.ml") since grants are exact (doc/manual/security.md) — and deny, which
    borrows the composer for feedback. When the reviewed accesses have a family
    generalization ({!Spice_permission.Suggest}), a fourth "always allow" option
    offers to save a durable rule over that family at a chosen scope. It is a
    pure view over a durable {!Spice_session.Permission.Requested.t}. *)

type t
(** The type for the permission dialog's UI state. *)

(** Where an "always allow" answer saves its derived rule. [Session] keeps it in
    the run only; [User] also writes the durable user config, which loads its
    rules on every run. A project-local scope is deliberately absent: workspace
    files never originate permission authority (their rules are stripped on
    load), so saving there would silently not persist. *)
type scope = Session | User

val make : Spice_session.Permission.Requested.t -> t
(** [make request] is the permission dialog for [request], cursor on allow-once,
    the diff collapsed, and the always-allow scope defaulting to {!Session}. The
    always-allow option is present only when the reviewed accesses have a family
    generalization. *)

(** What a key resolves the dialog to. {!Allow} and {!Always} answer
    immediately; {!Deny} borrows the composer, where an empty submit denies
    plainly and typed text denies with feedback. esc is {!Deny}. *)
type outcome =
  | Stay  (** Redraw; the dialog is still open (cursor move, diff expand). *)
  | Allow of Spice_session.Permission.Resolved.allowance
      (** Grant the request with this scope ([Once] or the exact-grant
          [Session]). *)
  | Always of { rules : Spice_permission.Policy.Rule.t list; scope : scope }
      (** Grant the request and install these durable family rules at [scope].
          The blocked call is also allowed for the session so it proceeds. *)
  | Deny  (** Deny with feedback: borrow the composer. *)

val key : Matrix.Input.Key.event -> t -> t * outcome
(** [key ev t] folds one key: [1]/[y] allow once, [2]/[a] allow for the session,
    [3]/[d]/[n]/[esc] deny with feedback, [4] always allow at the current scope,
    [s] cycles the always-allow scope, arrows move the cursor, [enter] confirms
    the selected option, and [ctrl+o] expands the diff. [4] and [s] are inert
    when no family rule can be derived. *)

val summary : t -> string
(** [summary t] is the one-line operation description the deny-feedback line
    quotes ("Run a shell command? $ …", "Edit lib/x.ml?"). *)

val scope_label : t -> string
(** [scope_label t] is the exact-grant scope the session-allow echo names ("this
    command", "edits to lib/x.ml"). *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the whole dialog as a panel. *)
