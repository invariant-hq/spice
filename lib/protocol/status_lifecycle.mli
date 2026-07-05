(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared monotonicity guard for timestamped lifecycle statuses.

    {!Plan.Status} and {!Subagent_run.Status} are the same design: a tagged
    lifecycle whose non-initial states each carry a transition time that must
    not precede the artifact's creation time. Both run this one guard from their
    constructors, transitions, and decoders, so the check is stated once. *)

val check_time :
  created_at:Spice_session.Time.t ->
  transition_time:('status -> Spice_session.Time.t option) ->
  error:('status -> string) ->
  'status ->
  (unit, string) result
(** [check_time ~created_at ~transition_time ~error status] is [Ok ()] when
    [status]'s transition time is absent — the initial state — or at or after
    [created_at], and [Error (error status)] when it precedes [created_at].
    [transition_time] projects the status's transition time; [error] builds the
    diagnostic for a status whose time is too early. *)
