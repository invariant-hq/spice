(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** A transient single-line editor owned by a decision dialog.

    It handles UTF-8 cursor boundaries, insertion, paste, submit, and cancel.
    It deliberately has no prompt history, slash-command, shell, or queued-turn
    behavior. *)

type t

val empty : t

type outcome = Stay of t | Submit of string | Cancel

val key : Matrix.Input.Key.event -> t -> outcome
val paste : string -> t -> t
val rows : t -> _ Mosaic.t list
(** [rows t] renders the ruled inline field with its cursor in place. *)
