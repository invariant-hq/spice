(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Derived session waiting boundaries.

    A waiting describes why turn execution cannot currently proceed. Durable
    permission and claim boundaries and derived host-tool waiting are all
    reconstructed by {!State.waiting} from the active turn and transcript.
    Waiting values do not contain live waiters, callbacks, fibers, or product
    UI state.

    Use {!State.waiting} to reconstruct the current read-time boundary. *)

type host_tool = private { turn : Turn.Id.t; call : Spice_llm.Tool.Call.t }
(** The type for host-handled tool waits.

    Values are produced by state replay and consumed by the run planner to ensure
    host answers cannot bypass executable-tool dispatch and permission policy by
    supplying raw call ids. *)

(** The type for derived session waiting. *)
type t =
  | Permission of Permission.Requested.t
      (** The active turn is waiting for a permission reply. *)
  | Tool_claim of Tool_claim.Started.t
      (** The active turn is waiting for an executable tool result. *)
  | Host_tool of host_tool
      (** The active turn is waiting for a host-handled tool answer. *)

val permission : Permission.Requested.t -> t
(** [permission request] is a permission waiting. *)

val tool_claim : Tool_claim.Started.t -> t
(** [tool_claim execution] is an unfinished tool claim waiting. *)

val host_tool : turn:Turn.Id.t -> Spice_llm.Tool.Call.t -> t
(** [host_tool ~turn call] is a host-handled tool waiting.

    This is exposed for replay projections and tests. *)

val turn : t -> Turn.Id.t
(** [turn t] is the turn waiting on [t]. *)

val call : t -> Spice_llm.Tool.Call.t
(** [call t] is the model tool call [t] is waiting on. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same waiting. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a waiting for diagnostics. *)
