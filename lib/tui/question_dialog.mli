(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The question dialog form (03-ia-screens-overlays.md §Dialogs, 07-dialogs.md
    §Question).

    A structured [ask_user] renders its options verbatim, each an accent/muted
    label with an optional muted description, plus a permanent
    [✎ type your own answer] row that borrows the composer — so a question is
    never a dead end. Single-select answers with the chosen label; multi-select
    adds [[x]]/[[ ]] checkboxes, toggles with space or a digit, and submits the
    checked labels joined. A bare free-text question (no options, or an
    undecodable [ask_user] the user must still unblock) renders the prompt and
    the [✎] row alone. The answer is always {!Spice_protocol.Command.Answer}
    text. *)

type t
(** The type for the question dialog's UI state. *)

val of_request : Spice_protocol.Question.Request.t -> t
(** [of_request request] is the dialog for a structured (or bare) question. *)

val of_text : string -> t
(** [of_text text] is a free-text question dialog presenting [text] with no
    options — the form an undecodable [ask_user] takes so the user can unblock
    the turn with a correction ({!Spice_protocol.Call.answerable_question}). *)

(** What a key resolves the dialog to. *)
type outcome =
  | Stay  (** Redraw; the dialog is still open (cursor move, a toggle). *)
  | Answer of string
      (** Answer with this text — a chosen label or the checked labels joined —
          via {!Spice_protocol.Command.Answer}. *)
  | Custom  (** Borrow the composer to type a free-form answer. *)
  | Flash of string
      (** Reject the key and flash [message] (an empty multi-select submit). *)

val key : Matrix.Input.Key.event -> t -> t * outcome
(** [key ev t] folds one key: a digit picks (single) or toggles (multi) that
    option, [space] toggles the option under the cursor (multi), arrows move the
    cursor, [enter] answers with the selection, and [esc] or the [✎] row borrow
    the composer. *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the whole dialog as a panel. *)
