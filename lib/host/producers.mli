(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The standard notice producers for a run.

    [Producers] bundles the host's config-gated notice sources — the filesystem
    watcher, the CR-comment observer sharing it, and the Dune diagnostics/build
    watchers — behind one value with one {!stop}. It owns the workspace Dune RPC
    instance for the run so the tool catalog and the watchers share one
    endpoint, and so a run has exactly one teardown instead of separate
    fswatch/dune strands. This is a private module {!Run} owns: {!Run.start}
    starts it, {!Run.stop} stops it, and no other consumer reaches it.

    Producers publish {!Spice_protocol.Notice.t} values into the queue; session
    execution consumes them through {!Session.with_notices}. *)

type t
(** The type for a run's started notice producers. *)

val start :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  Host.t ->
  inbox:Notice_queue.t ->
  workspace:Spice_workspace.t ->
  sandbox:Spice_sandbox.t ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  root:string ->
  unit ->
  t
(** [start ~sw ~stdenv host ~inbox ~workspace ~sandbox ~cwd ~root ()] starts the enabled
    notice producers for [host] over [inbox].

    Each producer is gated on its [Config.Notices] flag. The filesystem watcher
    and CR-comment observer watch [root] (the workspace root path); the Dune
    watchers share the created Dune RPC instance, whose optional build-watch
    starter runs in [cwd] (the run directory Eio path, see {!Context.eio_cwd}).
    [workspace] backs Dune RPC endpoint discovery. [sandbox] confines every
    automatic Dune or Merlin process. All producers run until [sw]
    is released or {!stop} is called; startup failures degrade to warning
    notices rather than failing the run. *)

val dune : t -> Spice_ocaml_dune.Rpc.Instance.t
(** [dune t] is the shared workspace Dune RPC instance [t] owns. Pass it to
    {!Toolset.make} so the OCaml Dune tools and the Dune watchers observe the
    same endpoint, diagnostic store, and build state. *)

val project_source : t -> Spice_ocaml_dune.Project_source.t
(** [project_source t] is the boot-captured project-shape source [t] owns,
    captured in the lock-free window before the Dune watch took the build lock.
    Pass it to {!Toolset.make} so the describe-backed OCaml tools serve the
    snapshot under a held lock instead of failing a one-shot [dune describe].
    Its drift flag is advanced from [t]'s filesystem watcher. *)

val merlin_program : t -> string list
(** [merlin_program t] is the lock-free [ocamlmerlin] invocation prefix [t]
    resolved once at boot from [ocaml.merlin_program]. Pass it to
    {!Toolset.make} so the Merlin-backed tools exec a concrete binary without
    re-engaging dune per query. *)

val before_request : t -> unit -> unit
(** [before_request t] is the request-boundary refresh: it requests the current
    Dune diagnostic set once and publishes a notice if it changed. Feed it to
    {!Session.with_notices} so proactive diagnostics do not depend on watcher
    scheduling. It is [ignore] when no Dune watcher is enabled. *)

val stop : t -> unit
(** [stop t] stops every producer [t] started and the Dune RPC instance it owns.
    Idempotent for the run switch's lifetime. *)
