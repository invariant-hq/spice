(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable session turns.

    A turn is one accepted model/tool loop in a session. It records the stable
    turn identity, the accepted input that starts the loop, and the effective
    provider-neutral request choices used for the loop.

    Turns are inert data. They are not live handles and cannot be used to await,
    cancel, stream, or inspect in-progress execution. State replay permits at
    most one active unfinished turn at a time. *)

(** {1:ids Identifiers} *)

module Id : sig
  type t
  (** The type for stable turn identifiers.

      Invariant: an identifier's stable textual form is non-empty. *)

  val of_string : string -> t
  (** [of_string s] is [s] as a turn id.

      Raises [Invalid_argument] if [s] is empty. *)

  val to_string : t -> string
  (** [to_string id] is [id]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same turn id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representations.

      The order is compatible with {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an id for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps turn ids to JSON strings. Decoding validates the same
      non-empty invariant as {!of_string}. *)
end

(** {1:inputs Accepted inputs} *)

module Input : sig
  (** Accepted turn inputs. *)

  (** The type for accepted turn inputs. *)
  type t = private
    | User of Spice_llm.Content.t list
        (** The turn starts by appending a user message with this non-empty
            content. *)
    | Continue
        (** The turn continues execution from the current transcript without
            appending a user message. *)

  val user : Spice_llm.Content.t list -> t
  (** [user content] is a user turn input.

      Raises [Invalid_argument] if [content] is empty. *)

  val user_text : string -> t
  (** [user_text s] is a user turn input with one text block.

      Raises [Invalid_argument] if [s] is empty. *)

  val text : t -> string option
  (** [text t] is the user-visible text of [t], when [t] contains at least one
      text content block. Text blocks are joined with single spaces; non-text
      blocks are skipped. *)

  val continue : t
  (** [continue] is an input that resumes from the current transcript without
      appending a message. Replay still requires no other turn to be active. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same turn input. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an input for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps turn inputs to JSON values. Decoding validates the non-empty
      user-content invariant. *)
end

(** {1:outcomes Terminal outcomes} *)

module Outcome : sig
  (** Terminal turn outcomes. *)

  (** The type for terminal turn outcomes. *)
  type t = private
    | Completed  (** The turn reached an ordinary terminal point. *)
    | Step_limit
        (** The execution loop stopped at its configured step limit. Like
            {!Completed}, this is a clean outcome. *)
    | Interrupted of { reason : string option; cancelled : bool }
        (** The turn was interrupted by the host or user. [reason], when
            present, is non-empty. *)
    | Failed of { message : string }
        (** The turn failed before reaching a normal terminal point. [message]
            is a non-empty diagnostic, not stable syntax for programmatic
            handling. *)

  val completed : t
  (** [completed] is {!Completed}. *)

  val step_limit : t
  (** [step_limit] is {!Step_limit}. *)

  val interrupted : ?reason:string -> cancelled:bool -> unit -> t
  (** [interrupted ?reason ~cancelled ()] is an interrupted outcome.

      Raises [Invalid_argument] if [reason] is present and empty. *)

  val failed : message:string -> t
  (** [failed ~message] is a failed outcome.

      Raises [Invalid_argument] if [message] is empty. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same outcome. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an outcome for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps turn outcomes to JSON values. Decoding validates non-empty
      interrupted reasons and failure messages. *)
end

(** {1:turns Turns} *)

type t
(** The type for an accepted turn start.

    Invariant: [mode] and [origin], when present, are non-empty. [max_steps],
    when present, is positive. Declaration names and host-tool names are unique,
    and every host-tool name has a declaration. State replay also requires the
    turn id to be unique and no other turn to be active. *)

val make :
  id:Id.t ->
  input:Input.t ->
  model:Spice_llm.Model.t ->
  ?options:Spice_llm.Request.Options.t ->
  ?mode:string ->
  ?origin:string ->
  ?max_steps:int ->
  declarations:Spice_llm.Tool.t list ->
  host_tools:string list ->
  unit ->
  t
(** [make ~id ~input ~model ?options ?mode ?origin ?max_steps ~declarations
    ~host_tools ()] is
    an accepted turn start.

    [options] defaults to {!Spice_llm.Request.Options.default}. [mode], when
    present, records the host mode selected for this turn. [origin], when
    present, records what caused the turn — e.g. a host goal continuation rather
    than a user prompt. Both are inert session data; interpretation belongs to
    the host and product projections, and an absent or unknown spelling degrades
    to the default there. [max_steps], when absent, is inherited from the
    session executor. [declarations] is the complete provider-facing tool
    snapshot accepted for this turn. [host_tools] is the subset of declaration
    names whose calls are handled by the product host rather than the executable
    tool catalog.

    Raises [Invalid_argument] if [mode] or [origin] is empty, if [max_steps] is
    present and not positive, if declaration or host-tool names are duplicated,
    or if a host-tool name has no declaration. *)

val id : t -> Id.t
(** [id t] is [t]'s stable id. *)

val input : t -> Input.t
(** [input t] is [t]'s accepted input. *)

val model : t -> Spice_llm.Model.t
(** [model t] is [t]'s effective model. *)

val options : t -> Spice_llm.Request.Options.t
(** [options t] is [t]'s provider-neutral request options. *)

val mode : t -> string option
(** [mode t] is the host mode recorded for [t], if any. *)

val origin : t -> string option
(** [origin t] is the turn origin recorded for [t], if any. Absent for
    user-initiated turns. *)

val max_steps : t -> int option
(** [max_steps t] is [t]'s execution-loop step limit, if recorded. *)

val declarations : t -> Spice_llm.Tool.t list
(** [declarations t] is the provider-facing tool snapshot accepted for [t]. *)

val host_tools : t -> string list
(** [host_tools t] are the model-visible host-handled tool names recorded for
    [t]. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] contain the same turn data. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a turn for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps turns to JSON values. Decoding validates local constructor
    invariants, including the declaration/host-tool contract; replay validity is
    checked by {!State.apply}. *)
