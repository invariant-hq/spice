(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Machine-readable session spend and activity metrics.

    Metrics are a second event fold beside {!State}: they carry the analytics
    counters the replay type deliberately omits. {!of_events} is the only
    projection; {!Spice_session.Metrics.of_session} wraps it over a session's
    validated event log. *)

type t = private {
  usage : Spice_llm.Usage.t;
      (** Lane-wise sum of provider-reported response usage. Responses without
          usage contribute {!Spice_llm.Usage.zero}. *)
  responses : int;  (** Number of completed provider responses. *)
  turns : int;  (** Number of terminal turn events. *)
  tool_calls : int;  (** Number of finished executable tool calls. *)
  tool_failures : int;
      (** Number of finished executable tool calls marked as errors. *)
  tool_rejections : int;
      (** Number of model tool calls answered with an error result without being
          executed. Denied permission replies are counted by
          [permission_denials], not here. *)
  tool_calls_by_name : (string * int) list;
      (** Finished executable tool-call counts by model-visible tool name,
          sorted by name. *)
  permission_denials : int;  (** Number of denied permission replies. *)
}
(** The type for cumulative session metrics. Counts are non-negative. *)

val of_events : Event.t list -> t
(** [of_events events] is the low-level cumulative metrics projection of an
    already-validated event log.

    Raises [Invalid_argument] if an integer lane overflows. *)

val empty : t
(** [empty] is the zero metrics value. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same metrics. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats metrics for diagnostics. The output is not stable storage
    syntax. *)

val jsont : t Jsont.t
(** [jsont] maps metrics to JSON objects. *)
