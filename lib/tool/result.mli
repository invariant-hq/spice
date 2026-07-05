(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Terminal tool invocation results.

    A result records the single terminal state of a tool run and optionally
    carries typed output. The output remains typed until {!Spice_tool.Call.run}
    maps it through the tool's {!Output.encoder}.

    Expected tool-domain failures should be represented with {!failed}.
    Cooperative stops should be represented with {!interrupted}. Use exceptions
    only for programming errors or failures the host intentionally wants to
    handle outside the tool-result protocol. *)

type failure =
  [ `Invalid_input
  | `Permission_denied
  | `Not_found
  | `Stale
  | `Unavailable
  | `Timed_out
  | `Failed ]
(** The type for stable categories of expected tool-domain failures.

    These categories are intentionally broad. Put human-facing detail in the
    failure message and machine-readable host detail, when needed, in failure
    metadata.

    [`Invalid_input] here is a handler-domain failure after dispatch succeeded.
    Provider JSON decoding failures are {!Error.Invalid_input}. *)

type status =
  | Completed
      (** The tool completed successfully. Successful results always carry
          output. *)
  | Failed of { kind : failure; message : string; metadata : Jsont.json option }
      (** The tool completed with an expected domain failure.

          [message] is a non-empty human-readable diagnostic. [metadata], when
          present, is already-encoded host data associated with the failure. *)
  | Interrupted of { reason : string; cancelled : bool }
      (** The tool stopped before normal completion.

          [reason] is a non-empty human-readable diagnostic. [cancelled] is
          [true] iff the interruption corresponds to caller-requested
          cancellation; other interruptions may use [false]. *)

type 'a t
(** The type for one terminal tool result carrying typed output ['a]. *)

val completed : output:'a -> unit -> 'a t
(** [completed ~output ()] is a successful result carrying [output]. *)

val failed : ?output:'a -> ?metadata:Jsont.json -> failure -> string -> 'a t
(** [failed ?output ?metadata kind message] is a failed result.

    [output], when present, is partial typed output still useful to the host or
    model. [metadata], when present, is already-encoded host data. [message] is
    non-empty human-readable detail available through {!message}; use [kind] for
    stable grouping.

    Raises [Invalid_argument] if [message] is empty. *)

val interrupted : ?output:'a -> reason:string -> cancelled:bool -> unit -> 'a t
(** [interrupted ?output ~reason ~cancelled ()] is an interrupted result.

    [output], when present, is partial typed output produced before the
    interruption. [cancelled] records whether the interruption was caused by a
    cancellation request. Use [cancelled:false] for host stops that are not
    caller cancellation.

    Raises [Invalid_argument] if [reason] is empty. *)

val status : _ t -> status
(** [status t] is [t]'s terminal status. *)

val output : 'a t -> 'a option
(** [output t] is [Some output] if [t] carries typed output and [None]
    otherwise. *)

val message : _ t -> string option
(** [message t] is [Some message] for {!Failed} results, [Some reason] for
    {!Interrupted} results, and [None] for {!Completed} results. *)

val failure_to_string : failure -> string
(** [failure_to_string f] is [f]'s stable lowercase label. *)

val failure_of_string : string -> failure option
(** [failure_of_string s] parses [s] as a failure label.

    It is [None] if [s] is not one of the labels produced by
    {!failure_to_string}. *)
