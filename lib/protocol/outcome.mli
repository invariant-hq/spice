(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Where an execution step settled.

    An outcome is the terminal shape of one {!Command.t}: the turn either
    blocked on a boundary that needs a continuation command, or finished. It
    carries the boundary only, not the saved document — the document is an
    in-process convenience that cannot cross a wire, so remote clients observe
    state through {!Event.t}. *)

type t =
  | Waiting of {
      waiting : Spice_session.Waiting.t;
          (** Why the active turn cannot continue. Product-agnostic. *)
      call : Call.t option;
          (** The classified host call when [waiting] is a host-tool boundary
              ({!Call.classify}), pre-applied so surfaces render without
              re-decoding. [None] for permission, tool-claim, and executable
              waits. *)
    }  (** The step blocked and needs a continuation {!Command.t}. *)
  | Finished of {
      turn : Spice_session.Turn.Id.t;  (** Finished turn id. *)
      outcome : Spice_session.Turn.Outcome.t;  (** Terminal outcome. *)
    }  (** The step reached a terminal turn outcome. *)

val waiting : t -> Spice_session.Waiting.t option
(** [waiting t] is [Some w] when [t] is {!Waiting} on [w], and [None] when [t]
    is {!Finished}. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)
