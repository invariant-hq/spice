(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Startup consent for repository-controlled inputs and processes. *)

type choice = Untrusted | Trusted | Exit
(** The three user decisions. [Exit] never writes the trust store. *)

type input = Up | Down | Digit of int | Enter | Escape | Eof
(** Inputs understood by the pure prompt state. *)

type t
(** The pure prompt selection. *)

val make : root:Spice_path.Abs.t -> t
(** [make ~root] selects [Untrusted], the restricted continuation. *)

val update : input -> t -> t * choice option
(** [update input t] moves the selection or resolves a choice. Digits resolve
    immediately; [Enter] resolves the selected choice; [Escape] and [Eof]
    resolve [Exit]. *)

val render : t -> string
(** [render t] is the complete plain-text prompt. *)

type 'a outcome = Continue of 'a | Exit_prompt
(** The terminal driver's outcome. *)

type failure =
  | Save_failed of string
  | Continue_failed of string
  | Activation_failed of { message : string; rollback_error : string option }
(** A rejected decision. [Save_failed] means no new decision was persisted.
    [Continue_failed] means a restricted decision was saved but the host could
    not reload. [Activation_failed] means trusted activation failed;
    [rollback_error] is [None] when the decision was restored to untrusted. *)

val run :
  root:Spice_path.Abs.t ->
  decide:(choice -> ('a, failure) result) ->
  'a outcome
(** [run ~root ~decide] drives the prompt on the controlling terminal. A
    rejected [decide] explains whether saving, restricted continuation, or
    trusted activation failed, then remains in the prompt and permits retry.
    The terminal attributes are restored before return or exception. *)
