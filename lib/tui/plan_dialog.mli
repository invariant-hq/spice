(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The plan-approval dialog form (03-ia-screens-overlays.md §Dialogs,
    07-dialogs.md §Plan approval).

    The proposed plan lives in the dialog: its title beside the chip, its
    markdown body collapsed to the first lines and expanded with [ctrl+o], and a
    numbered option list. The form wears the plan-mode blue on its boundary and
    chip ({!Theme.color_mode_plan}). It is a pure view over a decoded
    {!Spice_protocol.Plan.Proposal.t}; {!Dialog} attaches the boundary ids and
    routes the decision. *)

type t
(** The type for the plan dialog's UI state — the cursor and the body-expand
    lens over one proposal. *)

val make : Spice_protocol.Plan.Proposal.t -> t
(** [make proposal] is the plan dialog for [proposal], cursor on the first
    option and body collapsed. *)

(** What a key resolves the dialog to. {!Dialog} maps {!Approve} and
    {!Keep_planning} to {!Spice_protocol.Command.Resolve_plan}, and {!Adjust} to
    the composer borrow. esc never approves — it is {!Keep_planning}. *)
type outcome =
  | Stay  (** Redraw; the dialog is still open (cursor move, body expand). *)
  | Approve  (** Approve the plan. *)
  | Adjust
      (** Reject with feedback: the typed text becomes the rejection reason. *)
  | Keep_planning
      (** Reject with no feedback and keep the planning turn going. *)

val key : Matrix.Input.Key.event -> t -> t * outcome
(** [key ev t] folds one key: a digit [1]–[3] selects that option, arrows /
    [ctrl+p]·[ctrl+n] move the cursor, and [enter] confirms it. [ctrl+o] toggles
    the body expand (a {!Stay}), and [esc] is {!Keep_planning}. Any other key is
    {!Stay}. *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the whole dialog as a plan-blue panel. *)
