(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Live subagent progress events.

    A progress value tags a child session's own {!Event.t} with the identity of
    the run that produced it, so a surface tracking several concurrent children
    — including same-role siblings and nested grandchildren — can attribute
    every event to its run (doc/plans/subagent-tui.md §8.2).

    Progress is in-process rendering vocabulary only: it is never persisted. The
    durable record of a run is {!Subagent_run}; the child's own session log
    holds its transcript. *)

type t = {
  run : Spice_session.Id.t;
      (** The run key: the child session id. There is no separate run id
          namespace. *)
  parent : Spice_session.Id.t;  (** The spawning session. *)
  role : Subagent.Role.t;  (** The child's role. *)
  depth : int;  (** Child depth below the root session; root children are 1. *)
  event : Event.t;  (** The child's event, untranslated. *)
}
(** The type for identified child progress events. *)
