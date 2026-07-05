(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure reports over eval results.

    Reports aggregate durable {!Result.t} rows into per-series summaries and
    headline metrics. Pricing is not part of the core schema: callers inject a
    cost function when they want cost columns. *)

(** {1:types Types} *)

type task_summary = {
  series : Result.series;  (** The full result series for this summary. *)
  runs : int;  (** Number of rows in the series. *)
  successes : int;
      (** Number of rows whose {!Result.score.success} is [true]. *)
  mean_score : float;
      (** Arithmetic mean of final scores over all rows in the series. *)
  score_variance : float;
      (** Population variance of final scores over all rows in the series. *)
  mean_duration_s : float;
      (** Mean wall-clock duration over all rows in the series. *)
  mean_success_input_tokens : float option;
      (** Mean {!Usage.input_total} over successful rows reporting usage. *)
  mean_success_output_tokens : float option;
      (** Mean {!Usage.output_total} over successful rows reporting usage. *)
  mean_success_cost : float option;
      (** Mean cost over successful rows for which the injected cost function
          returns [Some cost]. *)
  mean_cache_hit : float option;
      (** Mean per-row cache hit rate over rows reporting usage. Each row's rate
          is [cache_read / Usage.input_total usage]; rows with zero input total
          are ignored. *)
}
(** Aggregated metrics for one {!Result.series}. *)

type t
(** A report over zero or more result rows. *)

(** {1:constructors Constructors} *)

val of_results : ?cost:(Result.t -> float option) -> Result.t list -> t
(** [of_results ?cost results] groups rows by their full {!Result.series}.

    [cost result] is the cost for one row, in the caller's chosen currency. Rows
    for which [cost] is absent or returns [None] are excluded from cost
    aggregates. When [cost] is absent, all cost metrics are [None]. *)

(** {1:queries Queries} *)

val tasks : t -> task_summary list
(** [tasks report] is the sorted list of per-series summaries. *)

val success_rate : t -> float
(** [success_rate report] is successful rows divided by total rows, or [0.0] for
    an empty report. *)

val mean_score : t -> float
(** [mean_score report] is the arithmetic mean of per-series mean scores, or
    [0.0] for an empty report. *)

val cost_of_success : t -> float option
(** [cost_of_success report] is the mean cost over successful priced rows, if
    any. *)

val wasted_cost : t -> float option
(** [wasted_cost report] is the total cost of unsuccessful priced rows, if any.
*)

val cache_hit_rate : t -> float option
(** [cache_hit_rate report] is total cache-read tokens divided by total input
    tokens over rows reporting usage, if any. *)

(** {1:comparison Comparison} *)

(** A report-level metric that can be compared. *)
type metric =
  | Success_rate  (** Compare {!success_rate}; higher is better. *)
  | Mean_score  (** Compare {!mean_score}; higher is better. *)
  | Cost_of_success  (** Compare {!cost_of_success}; lower is better. *)
  | Cache_hit_rate  (** Compare {!cache_hit_rate}; higher is better. *)

type verdict =
  | Improved
  | Regressed
  | Unchanged  (** A tolerance-aware comparison verdict. *)

val compare :
  ?success_tolerance:float ->
  ?score_tolerance:float ->
  ?cost_tolerance:float ->
  ?cache_hit_tolerance:float ->
  baseline:t ->
  t ->
  (metric * verdict) list
(** [compare ~baseline report] compares [report] against [baseline].

    Defaults are:
    - [success_tolerance = 0.0]
    - [score_tolerance = 0.05]
    - [cost_tolerance = 0.10], relative to the baseline cost
    - [cache_hit_tolerance = 0.05]

    Optional metrics are omitted unless both reports carry the metric. *)

val compare_tasks :
  ?score_tolerance:float -> baseline:t -> t -> (Result.series * verdict) list
(** [compare_tasks ~baseline report] compares per-series mean scores for series
    present in both reports.

    [score_tolerance] defaults to [0.05]. Series present in only one report are
    omitted. *)

(** {1:formatting Formatting} *)

val pp : Format.formatter -> t -> unit
(** [pp ppf report] formats the per-series summaries for human-readable
    diagnostics. The output is not a stable serialization format. *)
