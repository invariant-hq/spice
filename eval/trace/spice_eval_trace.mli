(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session-document trace analysis for the eval suite.

    A persisted Spice session document is the ground truth of one agent run: it
    carries the ordered event log with per-response usage, executable tool calls
    and their model-visible results, permission replies, and compaction resets.
    This library decodes that document into {!Trace.t} — the ordered,
    usage-attributed view of a run — and derives from it flat {!Trace_metrics.t}
    numbers.

    The library is pure: it consumes an already-decoded {!Spice_session.t} and
    two verbatim run-artifact strings (the [--json] event stream and its
    arrival-stamp sidecar), and produces values with JSON codecs. It performs no
    I/O and drives no agent. It is deliberately separate from [spice_eval] so
    the core eval library stays agent-agnostic: rows from agents with no Spice
    session (claude, codex) carry no trace, and the dependency arrow runs one
    way. *)

module Timing = Timing
(** Wall-clock timing recovered from run artifacts. *)

module Trace = Trace
(** The ordered, usage-attributed view of one session. *)

module Trace_metrics = Trace_metrics
(** Flat derived metrics over a {!Trace.t}. *)
