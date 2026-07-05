(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure benchmark descriptions, durable results, and reports.

    The core evaluation library is effect-free. It describes tasks and checks,
    records result rows produced by runner code, and aggregates those rows into
    reports. Agent adapters, workspace materialization, subprocess execution,
    diff capture, and judge invocation live outside this library. *)

module Usage = Usage
(** Provider-neutral token usage observed during eval runs. *)

module Check = Check
(** Named grading descriptions. *)

module Task = Task
(** Corpus task descriptions. *)

module Result = Result
(** Durable result rows and deterministic scoring. *)

module Report = Report
(** Pure report aggregation and comparison. *)
