(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Semantic streams of provider progress.

    Streams expose provider output as ordered semantic values. Live events are
    not transcript authority; the terminal {!Response.t} contains the assistant
    message that may be added to a {!Transcript.t}. Streams are single-pass and
    own any provider resources until they are closed or consumed. Closing a
    stream abandons any unread provider output. *)

module Event : sig
  (** Live non-terminal stream events.

      Events are display and early-execution signals only; the terminal
      {!Response.t} is the transcript authority. *)

  module Tool_input : sig
    (** Live partial tool-call input deltas. *)

    type t
    (** The type for live partial tool-call input progress.

        These deltas are for display and early execution heuristics only. The
        complete {!Tool.Call.t} in a later event or terminal response is the
        durable call value. *)

    val make :
      key:string ->
      ?call_id:string ->
      ?name:string ->
      input_delta:string ->
      unit ->
      t
    (** [make ~key ?call_id ?name ~input_delta ()] is live partial tool input
        for stream-local output [key].

        Raises [Invalid_argument] if [key] or [input_delta] is empty, or
        [call_id] or [name] is empty when present. *)

    val key : t -> string
    (** [key t] is [t]'s stream-local output key. *)

    val call_id : t -> string option
    (** [call_id t] is the associated provider call id, if known. *)

    val name : t -> string option
    (** [name t] is the associated tool name, if known. *)

    val input_delta : t -> string
    (** [input_delta t] is [t]'s live input text delta. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] have the same payload. *)
  end

  type t = private
    | Text_delta of string
    | Reasoning_summary_delta of string
    | Tool_input_delta of Tool_input.t
    | Tool_call of Tool.Call.t
    | Usage of Usage.t
        (** The type for live non-terminal stream events.

            String deltas are non-empty. *)

  val text_delta : string -> t
  (** [text_delta s] is visible assistant text delta [s].

      Raises [Invalid_argument] if [s] is empty. *)

  val reasoning_summary_delta : string -> t
  (** [reasoning_summary_delta s] is reasoning summary delta [s].

      Raises [Invalid_argument] if [s] is empty. *)

  val tool_input_delta : Tool_input.t -> t
  (** [tool_input_delta delta] is live partial tool input [delta]. *)

  val tool_call : Tool.Call.t -> t
  (** [tool_call call] is a live complete tool call.

      The event supports early execution when a host can do so safely and can
      reconcile with the terminal response. The terminal response remains the
      durable transcript authority. *)

  val usage : Usage.t -> t
  (** [usage usage] is a live usage snapshot. *)
end

type item =
  | Event of Event.t
  | Finished of Response.t
  | Failed of Error.t
      (** The type for stream items.

          A valid producer emits zero or more {!Event} items followed by exactly
          one terminal {!Finished} or {!Failed} item. The wrapper converts a
          producer that ends early into {!Failed} with
          {!Error.Malformed_stream}. *)

type t
(** The type for pull streams. *)

val make : ?close:(unit -> unit) -> (unit -> item option) -> t
(** [make next] is a pull stream backed by [next].

    [close] releases provider resources, if supplied. {!next} closes [t] after
    the first terminal item and hides any later callback items. The callback
    must be single-consumer safe. Exceptions from [next] are converted to a
    terminal {!Failed} transport error. Exceptions from [close] are not caught
    by {!close}. *)

val of_list : ?close:(unit -> unit) -> item list -> t
(** [of_list items] is a stream that returns [items] in order.

    The same terminal-item rules as {!make} apply. *)

val next : t -> item option
(** [next t] returns the next item, or [None] when [t] is closed or exhausted.

    If the producer ends before a terminal item, [next t] returns
    [Failed error], where [error] has kind {!Error.Malformed_stream}, closes
    [t], and later calls return [None]. If [next t] returns [Finished _] or
    [Failed _], [t] is closed before [next] returns. If the producer raises,
    [next t] returns [Failed error], where [error] has kind {!Error.Transport}
    and phase {!Error.Stream}, closes [t], and later calls return [None]. *)

val close : t -> unit
(** [close t] releases resources owned by [t]. It is idempotent.

    Exceptions raised by the close callback propagate from the first call that
    invokes it. *)

val use : t -> (t -> 'a) -> 'a
(** [use t f] runs [f t] and closes [t] afterwards, including when [f] raises.
    If [f] raises, exceptions from closing are suppressed. *)

val collect : t -> (Response.t, Error.t) result
(** [collect t] consumes and closes [t], then returns the terminal response.

    [collect] returns [Error error] for [Failed error] and a
    {!Error.Malformed_stream} error if [t] ends before a terminal item. *)

val fold_events :
  t -> init:'a -> f:('a -> Event.t -> 'a) -> ('a * Response.t, Error.t) result
(** [fold_events t ~init ~f] consumes and closes [t], folds [f] over each live
    event, and returns the final accumulator and terminal response.

    Exceptions raised by [f] propagate after [t] is closed. *)

val iter_events : t -> f:(Event.t -> unit) -> (Response.t, Error.t) result
(** [iter_events t ~f] consumes and closes [t], calls [f] for each live event,
    and returns the terminal response. *)
