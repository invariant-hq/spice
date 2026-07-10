(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Wall-clock timing recovered from run artifacts.

    The persisted session document carries no timestamps: session events are
    inert facts by design ({!Spice_session.Event}). Wall-clock timing for a run
    is recovered instead from the two headless-run artifacts the eval harness
    captures alongside the session: the [--json] event stream ([agent.jsonl])
    and a sidecar ([agent.timing.jsonl]) that stamps each stream line with its
    arrival time. This module joins them into per-tool-call intervals that a
    {!Trace.t} attaches to its steps and calls.

    Timing is best-effort and coarse. Arrival stamps are per read-chunk — lines
    delivered in one read share a stamp — and only executable tool lifecycle
    events surface in the stream, so timing exists at tool-call granularity,
    keyed by the provider tool-call id. A run analyzed without these artifacts
    simply has no timing; every duration is then absent. *)

type t
(** The type for recovered run timing. *)

val empty : t
(** [empty] carries no timing. Every {!call_interval} lookup is [None]. *)

val of_artifacts : agent_jsonl:string -> timing_jsonl:string -> t
(** [of_artifacts ~agent_jsonl ~timing_jsonl] joins a captured [--json] event
    stream with its arrival-stamp sidecar.

    [agent_jsonl] is the verbatim [agent.jsonl] content: one JSON event object
    per line. [timing_jsonl] is the verbatim [agent.timing.jsonl] content: one
    [{"line":N,"ts_ms":T}] object per line, where [N] is the 1-based line number
    of the stamped line in [agent_jsonl] and [T] its arrival time in Unix
    milliseconds. Lines arriving in one read chunk share a stamp.

    Parsing is total and lenient: blank, unparseable, or unrecognized lines are
    skipped rather than raised. The join records, per [tool.started] and
    [tool.finished] event, the arrival stamp of its line, keyed by the event's
    [tool_call_id]. *)

val call_interval : t -> tool_call_id:string -> (float * float) option
(** [call_interval t ~tool_call_id] is the [(started_ms, finished_ms)] pair of
    Unix-millisecond arrival stamps for the [tool.started] and [tool.finished]
    events of [tool_call_id], or [None] if either stamp is missing. [Trace]
    derives call and step durations from these intervals. *)
