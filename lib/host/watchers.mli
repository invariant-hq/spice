(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Notice producers for workspace watchers.

    Watchers observe host-side state and enqueue {!Spice_protocol.Notice.t}
    values through a {!Notice_queue.t}; they do not mutate durable session
    documents. This is a private implementation module of {!Producers}, which
    starts and stops the watchers for a run; {!Fswatch.default_ignore} is the
    one piece the surrounding library re-exports for surfaces that walk the
    workspace themselves. *)

module Fswatch : sig
  (** Best-effort filesystem change watcher for a workspace root. *)

  val default_ignore : Spice_path.Rel.t -> bool
  (** [default_ignore path] is [true] when any workspace-relative path component
      is [".git"], ["_build"], ["_opam"], or [".spice"]. The workspace root
      itself is not ignored. *)

  val start :
    ?notice:bool ->
    ?on_events:(Spice_fswatch.Event.t list -> unit) ->
    sw:Eio.Switch.t ->
    clock:_ Eio.Time.clock ->
    inbox:Notice_queue.t ->
    root:string ->
    unit ->
    unit ->
    unit
  (** [start ?notice ?on_events ~sw ~clock ~inbox ~root ()] starts a best-effort
      filesystem watcher for [root] and returns a stop function.

      Non-empty file-change batches enqueue info notices summarizing the changed
      paths, bounded to a small preview. The watcher ignores {!default_ignore}
      paths, runs until [sw] is released, and owns no durable state. A startup
      failure enqueues a warning notice instead of failing the run. A later
      watcher failure enqueues one warning notice and stops that watcher daemon.
      [notice] defaults to [true]; when [false], the watcher still invokes
      [on_events] but publishes no file-change notices. Operational failure
      warnings remain enabled because a failed shared watcher also makes every
      [on_events] observer unavailable.

      [on_events], when supplied, is called with each non-empty batch after
      {!default_ignore} has been applied and before the notice body truncates
      its path preview. It is intended for host-side observers that should share
      the single filesystem watcher, such as {!Cr_comments.observe}. *)
end

module Cr_comments : sig
  (** Watcher reporting open [CR]/[XCR] comments in changed source files. *)

  type t
  (** The type for current source CR-comment watcher state. *)

  val create :
    fs:_ Eio.Path.t -> root:string -> inbox:Notice_queue.t -> unit -> t
  (** [create ~fs ~root ~inbox ()] is a CR-comment observer for workspace root
      [root].

      Construction performs no workspace I/O. The observer discovers comments on
      first creation or change through the run's existing filesystem event
      stream, tracks open or malformed [CR]/[XCR] comments per file, and
      enqueues notices when the known aggregate set changes. A transition to no
      remaining known comments enqueues a clearing notice. *)

  val observe : t -> Spice_fswatch.Event.t list -> unit
  (** [observe t events] updates [t] from filesystem [events].

      Created and changed files are rescanned when their extension has a known
      comment syntax. One batch examines at most 4,096 events, 128 source files,
      4 MiB of aggregate source text, and 2 MiB per source. Exceeding a budget
      preserves any previously known state for unscanned files and enqueues a
      nonfatal warning. Deleted files clear any remembered comments for that
      path. Resolved [XCR] comments are ignored; open [CR] and malformed
      CR-looking comments are reported. Repeated observations of the same
      aggregate issue set enqueue no new notice. *)
end

module Dune_diagnostics : sig
  (** Watcher reporting Dune RPC diagnostics and build status. *)

  type refresh = unit -> unit
  (** The type for a request-boundary diagnostic refresh. *)

  type t
  (** A stoppable Dune diagnostics producer. *)

  val start :
    ?diagnostics:bool ->
    ?build:bool ->
    sw:Eio.Switch.t ->
    clock:_ Eio.Time.clock ->
    inbox:Notice_queue.t ->
    dune:Spice_ocaml_dune.Rpc.Instance.t ->
    unit ->
    t
  (** [start ?diagnostics ?build ~sw ~clock ~inbox ~dune ()] starts a
      reconnecting Dune RPC watcher when at least one Dune notice producer is
      enabled.

      The watcher shares the workspace-level [dune] instance with OCaml Dune
      tools, so tool calls and watcher events observe the same latest endpoint,
      diagnostic store, and build state. When the shared instance was configured
      with a host-owned starter, the background diagnostics loop may trigger
      that lazy startup path. Diagnostic events and periodic current diagnostic
      snapshots enqueue notices for the current Dune diagnostic set, including a
      clearing notice when the set becomes empty. Terminal build-progress events
      enqueue build-status notices for success, failure, and interruption.

      {!refresh} requests the current diagnostic set once and
      publishes a notice if it changed, but only after endpoint discovery has
      already found a matching Dune RPC server. Hosts should call it immediately
      before draining notices for an ordinary model request so proactive
      diagnostics do not depend on watcher scheduling. The host should bound
      this callback at the request boundary; Dune RPC may delay
      current-diagnostics responses for some project states.

      [diagnostics] and [build] default to [true] and independently control the
      two Dune notice kinds. When both are [false], no watcher is started.

      The watcher is best effort: connection loss, missing Dune RPC endpoints,
      and other run errors do not fail the host run. The daemon sleeps briefly
      and retries until [sw] is released. Repeated failures with the same
      diagnostic message enqueue no additional notice until the watcher observes
      a successful Dune event. *)

  val refresh : t -> unit
  (** [refresh t] performs the bounded request-boundary refresh while [t] is
      active and is a no-op after {!stop}. *)

  val stop : t -> unit
  (** [stop t] prevents further polling or refreshes and stops the shared Dune
      instance's host-owned starter. It is idempotent. *)
end
