(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Flat derived metrics over a {!Trace.t}.

    A {!t} is a pure fold of one trace into a flat record of numbers, with a
    JSON codec for the analysis sidecar. Fields an analysis cannot recover are
    options left absent rather than zeroed.

    These numbers are diagnostic. Syntactic counts here (re-reads, repeated
    calls, the longest failure streak) are gameable by prompt treatments, so
    they inform hypotheses but are never decision metrics. *)

type t = {
  responses : int;  (** Number of provider responses (steps). *)
  tool_calls : int;
      (** Number of executed executable tool calls (status {!Trace.Call.Ok} or
          {!Trace.Call.Failed}). Matches the session's own tool-call count. *)
  tool_failures : int;  (** Executed calls that reported an error result. *)
  tool_rejections : int;
      (** Executable calls answered without a successful execution: permission
          denials and pre-execution error results. This unifies what the session
          metrics split into rejections and permission denials, and it excludes
          host-tool results, so it is the count of {!Trace.Call.Rejected} calls
          rather than the session's [tool_rejections]. *)
  input_tokens : int;  (** Sum of the non-cached input lane across responses. *)
  output_tokens : int;  (** Sum of the visible output lane. *)
  reasoning_tokens : int;  (** Sum of the reasoning lane. *)
  cache_read_tokens : int;  (** Sum of the cache-read lane. *)
  cache_write_tokens : int;  (** Sum of the cache-write lane. *)
  input_first : int option;
      (** [Usage.input_total] of the first response that reported usage. *)
  input_last : int option;
      (** [Usage.input_total] of the last response that reported usage. *)
  input_growth_mean : float option;
      (** Mean of consecutive input-total deltas between responses, computed
          within compaction segments and never across a reset. Absent when fewer
          than two responses in any one segment reported usage. *)
  cache_hit_rate : float option;
      (** Cache-read tokens over total input tokens, or [None] when no input
          tokens were reported. *)
  calls_by_name : (string * int) list;
      (** Executable-call counts by tool name, sorted by name. Counts every call
          in {!Trace.calls} — executed and rejected. *)
  result_bytes_total : int;
      (** Total model-visible result bytes across executable calls. *)
  result_bytes_by_name : (string * int) list;
      (** Result bytes by tool name, sorted by name. *)
  reread_count : int;
      (** Number of unchanged re-reads (see {!Trace.rereads}). *)
  repeated_call_count : int;
      (** Number of identical calls beyond the first in their group, summed over
          groups (see {!Trace.repeated_groups}). *)
  failure_streak_max : int;
      (** Longest run of consecutive same-tool failures, or [0]. *)
  segments : int;  (** Number of compaction segments. *)
  shell_families : (string * int) list;
      (** [shell] command-family histogram, sorted by family (see
          {!Trace.shell_families}). *)
  model : string option;
      (** Qualified [provider/model] id when every turn agreed, else [None]. *)
  reasoning_effort : string option;
      (** Reasoning-effort spelling when every turn agreed on one, else [None].
      *)
}
(** The type for flat trace metrics. *)

val of_trace : Trace.t -> t
(** [of_trace trace] is the metrics of [trace]. *)

val jsont : t Jsont.t
(** [jsont] maps metrics to a flat JSON object. *)
