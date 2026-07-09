(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The decision-dialog family — one surface over the permission, plan, and
    question forms (03-ia-screens-overlays.md §Dialogs,
    doc/plans/tui-next-dialog-seam.md §6).

    A dialog opens on a blocked turn's {!Spice_protocol.Pending.t} boundary,
    tagged with the owner it must answer through, and renders one of the three
    forms as a panel. Folding a key either keeps the dialog open, resolves it to
    a command the shell submits, or borrows the composer for feedback. The reply
    routes by {!owner}: the parent turn answers through {!Spice_host.Live}, a
    child (subagent) turn through its job — only the parent arm is live this
    iteration. *)

(** Which turn a pending boundary belongs to, so the reply reaches the right
    door. Only {!Main} is constructed today; {!Child} lands with the threads
    iteration. *)
type owner = Main | Child of Spice_session.Id.t

type pending = { owner : owner; boundary : Spice_protocol.Pending.t }
(** A pending boundary tagged with its owner — what the shell holds while a
    dialog is up. *)

type t
(** The type for an open decision dialog. *)

val of_pending : owner:owner -> Spice_protocol.Pending.t -> t option
(** [of_pending ~owner boundary] is the dialog for [boundary], or [None] for a
    host-tool boundary with no user-facing form (a call the current vocabulary
    cannot render or answer). A permission, plan, valid question, or undecodable
    [ask_user] (rendered as a free-text question) all open a dialog. *)

val pending : t -> pending
(** [pending t] is [t]'s owner-tagged boundary — the ids the shell needs to
    build the reply command. *)

(** The command the shell submits when a dialog resolves. The shell reads
    {!pending} for the turn, call, or permission id the command names. *)
type resolution =
  | Reply of {
      answer : Spice_permission.Policy.Review.answer;
      message : string option;
    }  (** A permission reply — {!Spice_protocol.Command.Reply}. *)
  | Answer of { text : string }
      (** A question answer — {!Spice_protocol.Command.Answer}. *)
  | Resolve_plan of {
      decision : Spice_protocol.Plan.Decision.t;
      accept_edits : bool;
    }
      (** A plan decision — {!Spice_protocol.Command.Resolve_plan};
          [accept_edits] asks the shell to also set the approval posture in the
          same stroke. *)

(** What folding a key asks the shell to do — the surface's outcome vocabulary
    the shell interprets (doc/plans/tui-next-surfaces.md §The three forms). *)
type event =
  | Stay  (** Redraw; the dialog is still open. *)
  | Resolve of { resolution : resolution; echo : string }
      (** Submit [resolution] and append the [echo] event notice, then close. *)
  | Borrow of { placeholder : string }
      (** Borrow the composer with [placeholder]; the dialog stays open in its
          collapsed feedback form and a later {!resolve_borrow} finishes it. *)
  | Flash of string  (** Reject the key and flash [message]. *)

val key : Matrix.Input.Key.event -> t -> t * event
(** [key ev t] folds one key into the active form. Only called while the dialog
    owns the keyboard — never while the composer is borrowed. *)

val borrowed : t -> bool
(** [borrowed t] is [true] while the composer is borrowed for feedback. *)

val borrow_summary : t -> string
(** [borrow_summary t] is the one-line collapsed record shown above the borrowed
    composer ("Denying: …", "Adjusting the plan", the question text). *)

val resolve_borrow : text:string -> t -> (resolution * string, string) result
(** [resolve_borrow ~text t] finishes a borrowed dialog from the submitted
    [text]: [Ok (resolution, echo)] to submit and close, or [Error message] to
    flash [message] and stay borrowed (an empty custom answer). An empty deny or
    plan-adjust submit resolves plainly rather than erroring. *)

val cancel_borrow : t -> t
(** [cancel_borrow t] steps back from the borrowed composer to the option list,
    restoring the dialog's own keyboard (the esc-ladder rung). *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the active form as a panel. Used while the dialog
    owns the keyboard; a borrowed dialog renders {!borrow_summary} beside the
    real composer instead. *)
