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
    the conversation — labelled honestly with the narrow scope an identical
    {!Spice_permission.Access.t} re-approves ("this command", "edits to
    lib/x.ml") since grants are exact (doc/manual/security.md) — and deny, which
    borrows the composer for feedback. It is a pure view over a durable
    {!Spice_session.Permission.Requested.t}. *)

type t
(** The type for the permission dialog's UI state. *)

val make : Spice_session.Permission.Requested.t -> t
(** [make request] is the permission dialog for [request], cursor on allow-once
    and the diff collapsed. *)

(** What a key resolves the dialog to. {!Allow} answers immediately; {!Deny}
    borrows the composer, where an empty submit denies plainly and typed text
    denies with feedback. esc is {!Deny}. *)
type outcome =
  | Stay  (** Redraw; the dialog is still open (cursor move, diff expand). *)
  | Allow of Spice_session.Permission.Resolved.allowance
      (** Grant the request with this scope ([Once] or the exact-grant
          [Exact_for_conversation]). *)
  | Deny  (** Deny with feedback: borrow the composer. *)

val key : Matrix.Input.Key.event -> t -> t * outcome
(** [key ev t] folds one key: [1]/[2]/[3] select their numbered option, arrows
    move the cursor, and [enter] confirms the selected option. The explicit
    mnemonics [y]/[a] allow once or for the conversation immediately;
    [d]/[n]/[esc] deny with feedback immediately. [ctrl+o] expands the diff. *)

val summary : t -> string
(** [summary t] is the one-line operation description the deny-feedback line
    quotes ("Run a shell command? $ …", "Edit lib/x.ml?"). *)

val scope_label : t -> string
(** [scope_label t] is the exact-grant scope the session-allow echo names ("this
    command", "edits to lib/x.ml"). *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the whole dialog as a panel. *)
