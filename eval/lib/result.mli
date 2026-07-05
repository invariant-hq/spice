(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable eval result rows and deterministic scoring.

    A result is the narrow waist of the eval API: runner code produces {!type:t}
    values after attempting {!Task.t} values, and report code consumes them.
    Result construction is pure and computes the deterministic score from status
    and findings. *)

(** {1:types Types} *)

(** The stage at which a recoverable eval failure occurred. *)
type failure_stage =
  | Setup
      (** Failure while preparing the task workspace or running task setup. *)
  | Agent  (** Failure reported by, or while invoking, an agent adapter. *)
  | Check of string
      (** Failure while evaluating the named deterministic check. *)
  | Judge of string  (** Failure while judging the named quality check. *)
  | Harness
      (** Failure in runner infrastructure outside task, agent, check, or judge
          execution. *)

type failure = {
  stage : failure_stage;  (** The failed stage. *)
  message : string;
      (** Non-empty diagnostic message. Intended for humans, not parsing. *)
  failure_log : string option;
      (** Optional non-empty path or label for additional diagnostics. *)
}
(** A structured failure recorded in a result row. *)

(** Terminal status of an agent attempt. *)
type agent_status =
  | Completed  (** The agent finished normally. *)
  | Blocked
      (** The agent stopped because it needed external input or permission. *)
  | Timed_out  (** The runner's wall-clock limit expired. *)
  | Failed of failure
      (** The run failed with structured diagnostic information. *)

type agent = {
  name : string;  (** Non-empty agent adapter name. *)
  version : string option;  (** Optional non-empty adapter version. *)
  model : string option;  (** Optional non-empty model identifier. *)
}
(** Agent identity recorded in a result series. *)

type series = {
  task : string;  (** Non-empty task identifier. *)
  agent : agent;  (** Agent identity. *)
  judge_model : string option;
      (** Optional non-empty model identifier used for judge checks. *)
  spice_version : string option;
      (** Optional non-empty Spice version that produced the row. *)
}
(** A comparable result series.

    Reports group by the full series, so rows with different agent versions,
    models, judge models, or Spice versions are not mixed by default. *)

type metrics = {
  duration_s : float;  (** Non-negative wall-clock duration in seconds. *)
  usage : Usage.t option;
      (** Optional token usage observed during the agent attempt. *)
  turns : int option;  (** Optional non-negative turn count. *)
  tool_calls : int option;  (** Optional non-negative tool-call count. *)
  tool_failures : int option;
      (** Optional non-negative failed-tool-call count. If [tool_calls] is
          present, [tool_failures] must not exceed it. *)
  tool_rejections : int option;
      (** Optional non-negative rejected-tool-call count. *)
  log : string option;  (** Optional non-empty path or label for the run log. *)
}
(** Observed metrics for one result row. *)

val metrics :
  duration_s:float ->
  ?usage:Usage.t ->
  ?turns:int ->
  ?tool_calls:int ->
  ?tool_failures:int ->
  ?tool_rejections:int ->
  ?log:string ->
  unit ->
  metrics
(** [metrics ~duration_s ... ()] is a metrics record.

    Optional counters default to [None]. Raises [Invalid_argument] if
    [duration_s] is negative or not finite; if a present counter is negative; if
    [tool_failures] exceeds [tool_calls] when both are present; or if [log] is
    present and empty. *)

type sample = {
  sample_score : float;
      (** Judge sample score in the inclusive range \[[0];[1]\]. *)
  rationale : string;  (** Non-empty human-readable judge rationale. *)
}
(** One judge sample contributing to a scored finding. *)

(** The recorded verdict for one check. *)
type verdict =
  | Passed  (** A gate or penalty check passed. *)
  | Failed_check of string
      (** A gate or penalty check failed with a non-empty reason. *)
  | Scored of { score : float; samples : sample list }
      (** A judge check received [score] in the inclusive range \[[0];[1]\],
          with the samples used to compute or justify it. *)
  | Skipped  (** The check was not evaluated. *)

type finding
(** The result of one {!Check.t}.

    Gate and penalty findings can be {!Passed}, {!Failed_check}, or {!Skipped}.
    Judge findings can be {!Scored} or {!Skipped}. Constructors enforce this
    compatibility. *)

(** {1:constructors Constructors} *)

val finding : Check.t -> verdict -> finding
(** [finding check verdict] records [verdict] for [check].

    Raises [Invalid_argument] if [verdict] is incompatible with {!Check.kind};
    if a failure message or sample rationale is empty; or if a score is outside
    the inclusive range \[[0];[1]\]. *)

val passed : Check.t -> finding
(** [passed check] is [finding check Passed]. *)

val failed : Check.t -> string -> finding
(** [failed check message] is [finding check (Failed_check message)]. *)

val scored : Check.t -> score:float -> samples:sample list -> finding
(** [scored check ~score ~samples] is
    [finding check (Scored { score; samples })]. *)

val skipped : Check.t -> finding
(** [skipped check] is [finding check Skipped]. *)

(** {1:queries Queries} *)

val finding_check : finding -> Check.t
(** [finding_check f] is the check recorded by [f]. *)

val finding_verdict : finding -> verdict
(** [finding_verdict f] is the verdict recorded by [f]. *)

type score = private {
  success : bool;
      (** [true] iff the status is {!Completed} and no gate finding failed. *)
  quality : float option;
      (** Weighted mean of scored judge findings, or [None] if no judge finding
          was scored. *)
  penalties : float;  (** Sum of failed penalty points. *)
  final : float;
      (** [0.0] when [success] is [false]; otherwise
          [max 0.0 ((quality default 1.0) - penalties)]. *)
  missing_quality : bool;
      (** [true] iff the result contains at least one judge check and none were
          scored. *)
}
(** Deterministic score components for a result. *)

type t
(** A durable eval result row. *)

val make :
  series:series ->
  run_index:int ->
  status:agent_status ->
  metrics:metrics ->
  findings:finding list ->
  unit ->
  t
(** [make ~series ~run_index ~status ~metrics ~findings ()] is a result row with
    score computed from [status] and [findings].

    Raises [Invalid_argument] if [series] contains an empty required field or
    empty optional field, if [run_index] is negative, if [status] contains an
    invalid failure, or if [findings] contains duplicate check names. *)

val series : t -> series
(** [series result] is the comparable result series. *)

val run_index : t -> int
(** [run_index result] is the non-negative replicate index within its series. *)

val status : t -> agent_status
(** [status result] is the terminal agent status. *)

val metrics_of : t -> metrics
(** [metrics_of result] is the observed metrics record. *)

val findings : t -> finding list
(** [findings result] is the list of recorded check findings. *)

val score : t -> score
(** [score result] is the deterministic score computed at construction time. *)

(** {1:formatting Formatting and codecs} *)

val pp_status : Format.formatter -> agent_status -> unit
(** [pp_status ppf status] formats [status] for human-readable diagnostics. *)

val pp_finding : Format.formatter -> finding -> unit
(** [pp_finding ppf finding] formats [finding] for human-readable diagnostics.
*)

val pp_score : Format.formatter -> score -> unit
(** [pp_score ppf score] formats [score] for human-readable diagnostics. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf result] formats [result] for human-readable diagnostics. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are structurally equal. *)

val jsont : t Jsont.t
(** [jsont] maps result rows to JSON objects.

    The codec validates the same invariants as {!make}. The score is derived and
    is not stored in the row JSON. *)
