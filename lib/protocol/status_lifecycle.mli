(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared time guards for timestamped lifecycle statuses.

    {!Plan.Status} and {!Subagent_run.Status} are the same design: a tagged
    lifecycle whose non-initial states each carry a transition time. Snapshot
    construction checks that time against creation; transitions additionally
    check it against the value's latest update. *)

val check_snapshot_time :
  created_at:Spice_session.Time.t ->
  transition_time:('status -> Spice_session.Time.t option) ->
  error:('status -> string) ->
  'status ->
  (unit, string) result
(** [check_snapshot_time ~created_at ~transition_time ~error status] validates
    one stored status in isolation: its transition time is absent — the initial
    state — or at or after [created_at]. *)

val check_transition_time :
  updated_at:Spice_session.Time.t ->
  transition_at:Spice_session.Time.t ->
  error:string ->
  (unit, string) result
(** [check_transition_time ~updated_at ~transition_at ~error] requires a new
    transition time to be at or after the value's latest update. Equal times are
    valid for coarse clocks. *)
