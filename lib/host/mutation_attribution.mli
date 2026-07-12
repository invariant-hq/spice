(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Run-local attribution of filesystem watcher batches.

    This private host seam joins two independently useful facts: raw watcher
    events and exact paths attributed to an active mutating tool claim. It
    buffers batches while such claims are active and publishes only residual
    paths once all claims have settled. The filesystem watcher remains unaware
    of tools, claims, and mutation evidence. *)

type t
(** The type for one run's active attribution state. *)

val create : publish:(Spice_fswatch.Event.t list -> unit) -> unit -> t
(** [create ~publish ()] is empty attribution state. [publish] receives raw
    external-change batches after exact claim-owned paths have been removed. *)

val observe : t -> Spice_fswatch.Event.t list -> unit
(** [observe t events] publishes [events] immediately when no mutating claim is
    active. Otherwise it buffers them until all active claims settle. *)

val hook :
  shell_changes:(unit -> unit -> Spice_path.Rel.t list) ->
  t ->
  Session.hooks ->
  Session.hooks
(** [hook ~shell_changes t hooks] attributes mutating tool claims in [hooks].

    Receipt-backed editors contribute their concrete revalidated receipt paths.
    For shell, [shell_changes ()] captures the before boundary and returns a
    function that captures the end boundary and derives their changed paths. The
    existing hook chain runs before the claim settles, so durable typed mutation
    rows remain unchanged. *)
