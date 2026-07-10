(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The ordered, usage-attributed view of one session.

    A {!t} is the narrow waist of trace analysis: {!of_session} produces it from
    a decoded session document, {!Trace_metrics} derives flat numbers from it,
    and {!pp_digest} renders it for trace review. It reconstructs, in causal
    order, the provider responses of a run ({!Step.t}), the executable tool
    calls each response issued and their model-visible results ({!Call.t}), the
    compaction resets that delimit segments, and the per-turn tool declarations.

    The reconstruction follows the session's own event semantics
    ({!Spice_session.Event}): a step is one [Response_appended]; an executed
    call joins a response tool call to its [Tool_claim_finished] result by
    tool-call id; a rejected call is one answered without execution — a
    permission [Deny] or a directly appended error tool result — carrying the
    arguments from the response. Model-visible {e host} tool calls (those in a
    turn's [host_tools]) are not executable and do not appear as calls. *)

(** {1:calls Tool calls} *)

module Call : sig
  (** One executable tool call issued by a provider response and its
      model-visible result. *)

  (** The outcome of an executable tool call. *)
  type status =
    | Ok  (** The tool executed and reported success. *)
    | Failed  (** The tool executed and reported an error result. *)
    | Rejected
        (** The call was answered without a successful execution: a permission
            denial or a directly appended error tool result. *)

  type t
  (** The type for one executable tool call. *)

  val tool_call_id : t -> string
  (** [tool_call_id c] is the provider call identifier that joins [c] to its
      result and to timing. *)

  val name : t -> string
  (** [name c] is [c]'s model-visible tool name. *)

  val arguments : t -> Jsont.json
  (** [arguments c] is the complete decoded JSON input the model supplied.

      Arguments are kept as structured JSON rather than a raw string so analyses
      can compare them structurally (member order and whitespace do not matter)
      and read individual fields — the repeated-call grouping and the path and
      command projections below all need this. A raw-string form would force
      every consumer to re-parse. *)

  val result_text : t -> string
  (** [result_text c] is the model-visible textual result content, text blocks
      joined by newlines. Empty when the result carried no text. *)

  val status : t -> status
  (** [status c] is [c]'s outcome. *)

  val result_bytes : t -> int
  (** [result_bytes c] is the byte size of [c]'s model-visible textual result.
  *)

  val duration_s : t -> float option
  (** [duration_s c] is [c]'s execution wall-clock in seconds, recovered from
      timing when the run's artifacts were supplied and [c] executed, else
      [None]. *)

  val step_index : t -> int
  (** [step_index c] is the zero-based index of the response that issued [c]. *)

  val read_path : t -> string option
  (** [read_path c] is the [path] argument when [c] is a [read_file] call, else
      [None]. *)

  val shell_command : t -> string option
  (** [shell_command c] is the [command] argument when [c] is a [shell] call,
      else [None]. *)

  val arguments_digest : ?max_bytes:int -> t -> string
  (** [arguments_digest ?max_bytes c] is [c]'s arguments rendered as compact
      JSON, elided to a bounded head and tail of [max_bytes] bytes (default
      [80]) for token-bounded review. *)

  val result_digest : ?max_bytes:int -> t -> string
  (** [result_digest ?max_bytes c] is {!result_text}[ c] elided to a bounded
      head and tail of [max_bytes] bytes (default [80]). *)

  val status_to_string : status -> string
  (** [status_to_string s] is the stable lowercase spelling of [s]: ["ok"],
      ["failed"], or ["rejected"]. *)

  val pp_status : Format.formatter -> status -> unit
  (** [pp_status ppf s] formats {!status_to_string}[ s]. *)
end

(** {1:steps Steps} *)

module Step : sig
  (** One provider response and the calls it issued. *)

  type t
  (** The type for one step. *)

  val index : t -> int
  (** [index s] is [s]'s zero-based position among all responses. *)

  val segment_index : t -> int
  (** [segment_index s] is the zero-based index of the compaction segment [s]
      belongs to. *)

  val usage : t -> Spice_llm.Usage.t option
  (** [usage s] is the provider-reported token usage of [s]'s response, if
      reported. *)

  val calls : t -> Call.t list
  (** [calls s] are the executable tool calls [s] issued, in model order. *)

  val duration_s : t -> float option
  (** [duration_s s] is the wall-clock span in seconds from the earliest
      [tool.started] to the latest [tool.finished] among [s]'s timed calls, or
      [None] when [s] issued no timed call. *)
end

(** {1:traces Traces} *)

type t
(** The type for the ordered, usage-attributed view of one session. *)

val of_session : ?timing:Timing.t -> Spice_session.t -> t
(** [of_session ?timing session] reconstructs the trace of [session].

    [timing] supplies wall-clock durations when the run's artifacts were
    captured; it defaults to {!Timing.empty}, leaving every duration absent. *)

val steps : t -> Step.t list
(** [steps t] are [t]'s steps in response order. *)

val calls : t -> Call.t list
(** [calls t] are [t]'s executable tool calls in execution order — the
    concatenation of each step's {!Step.calls}. *)

val segments : t -> Step.t list list
(** [segments t] partitions {!steps} into compaction segments, in order. There
    is one segment per compaction reset plus one, so the list length is the
    segment count even when a boundary segment holds no steps. Context-shape
    metrics restart per segment because a compaction resets the replay
    transcript. *)

val declared_tools : t -> string list
(** [declared_tools t] is the sorted, deduplicated union of the tool names
    declared across [t]'s turns ([Turn_started]'s declarations) — the catalog
    snapshot {!pp_digest} surfaces for review, so a run is never faulted for not
    using a tool its catalog never offered. *)

val model : t -> Spice_llm.Model.t option
(** [model t] is the request model when every turn used the same one, else
    [None] — a difference between turns is not cleanly recoverable and is not
    guessed. *)

val reasoning_effort : t -> Spice_llm.Request.Options.Reasoning_effort.t option
(** [reasoning_effort t] is the requested reasoning effort when every turn
    agreed on the same explicit level, else [None] (no level set, or a
    difference between turns). *)

(** {1:derivations Shared derivations}

    These are the canonical orderings {!Trace_metrics} builds on, so related
    metrics never drift. *)

val rereads : t -> (Call.t * Call.t) list
(** [rereads t] are the [(original, reread)] pairs where [reread] is a
    [read_file] of a path last read by [original] with no intervening change to
    that path. A [write_file], [edit_file], [edit_lines], or [apply_patch]
    naming a path clears it; a [shell] call or any other potentially mutating
    tool conservatively clears every path; read-only tools do not. Pairs are in
    reread order. *)

val repeated_groups : t -> Call.t list list
(** [repeated_groups t] groups {!calls} by identical tool name and structurally
    equal arguments, keeping only groups of two or more, each in call order and
    ordered by first occurrence. *)

val failure_streaks : t -> Call.t list list
(** [failure_streaks t] are the maximal runs of consecutive {!calls} that all
    {!Call.Failed} and share one tool name, in order. Every failed call belongs
    to exactly one run; a success, a rejection, or a name change ends a run. *)

val shell_families : t -> (string * int) list
(** [shell_families t] is the histogram of [shell] command families, sorted by
    family. A family is the command's argv0, with the subcommand appended for
    [git], [dune], and [opam]. *)

(** {1:rendering Rendering} *)

val pp_digest :
  ?arg_bytes:int -> ?result_bytes:int -> Format.formatter -> t -> unit
(** [pp_digest ?arg_bytes ?result_bytes ppf t] renders [t] compactly for LLM
    review: the declared tool catalog (when non-empty), then each segment, each
    step's usage, and each call's name, elided arguments, status, and elided
    result. Arguments and results are bounded to [arg_bytes] (default [80]) and
    [result_bytes] (default [80]) head-and-tail bytes so the whole rendering
    stays token-bounded. *)
