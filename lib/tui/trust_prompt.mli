(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Startup consent for ambient project customization. *)

type choice = Untrusted | Trusted | Exit
(** The three user decisions. [Exit] never writes the trust store. *)

type input = Up | Down | Digit of int | Enter | Escape | Eof
(** Inputs understood by the pure prompt state. *)

type t
(** The pure prompt selection. *)

val make : root:Spice_path.Abs.t -> t
(** [make ~root] selects [Untrusted], the safe continuation. *)

val update : input -> t -> t * choice option
(** [update input t] moves the selection or resolves a choice. Digits resolve
    immediately; [Enter] resolves the selected choice; [Escape] and [Eof]
    resolve [Exit]. *)

val render : t -> string
(** [render t] is the complete plain-text prompt. *)

type 'a outcome = Continue of 'a | Exit_prompt
(** The terminal driver's outcome. *)

val run :
  root:Spice_path.Abs.t ->
  decide:(choice -> ('a, string) result) ->
  'a outcome
(** [run ~root ~decide] drives the prompt on the controlling terminal. A
    rejected [decide] remains in the prompt with its error and permits retry.
    The terminal attributes are restored before return or exception. *)
