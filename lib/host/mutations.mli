(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host runtime for workspace mutation evidence.

    The durable sidecar for {!Spice_mutation} facts: a content-addressed blob
    store, a per-session JSONL ledger, and the checkpoint backend record. Facts
    and the pure combinators over them live in {!Spice_mutation}; this module
    only stores, loads, and snapshots.

    Ledger appends and blob writes are serialized across processes with file
    locks: a run and a revert may operate on the same session concurrently. *)

(** {1:log Ledger and blobs} *)

module Log : sig
  type t
  (** The type for the mutation ledger. *)

  val make : fs:Eio.Fs.dir_ty Eio.Path.t -> root:string -> t
  (** [make ~fs ~root] is the ledger below [root]. Session ledgers live at
      [root/sessions/<id>/mutations.jsonl], beside the session document; blob
      bytes live below [root/blobs]. *)

  val put_blob : t -> string -> (Spice_digest.Identity.t, string) result
  (** [put_blob t contents] stores [contents] content-addressed and returns its
      identity. Write-once: storing already-present contents is a cheap no-op.
      Callers must store every blob a row references before appending the row.
  *)

  val blob : t -> Spice_digest.Identity.t -> (string option, string) result
  (** [blob t identity] resolves stored contents, [None] when absent. *)

  val append :
    t ->
    session:Spice_session.Id.t ->
    Spice_mutation.Record.t list ->
    (unit, string) result
  (** [append t ~session records] atomically appends [records] in order to the
      session ledger, under a cross-process lock. Appending an empty list is a
      no-op. *)

  val read :
    t ->
    session:Spice_session.Id.t ->
    (Spice_mutation.Record.t list, string) result
  (** [read t ~session] is every recorded fact for [session] in append order. A
      session with no ledger reads as the empty list. *)
end

(** {1:backend Checkpoint backend} *)

module Backend : sig
  type capture = { reference : string; excluded : int }
  (** A successful snapshot: an opaque backend reference plus [excluded], the
      count of workspace files the backend left out (ignored or oversized).
      Reserved; the [git_tree] backend does not yet compute it and always
      reports [0]. *)

  type t = {
    name : string;  (** Backend name recorded on checkpoint facts. *)
    capture : unit -> (capture, string) result;
        (** [capture ()] snapshots the workspace root. *)
    paths :
      from_:string ->
      to_:string ->
      ( (Spice_path.Rel.t * [ `Added | `Modified | `Deleted ]) list,
        string )
      result;
        (** [paths ~from_ ~to_] is the set of paths that differ between two
            snapshot references. Snapshot-to-worktree comparison is deliberately
            absent: every comparison the product needs is between two captured
            references. *)
    read :
      reference:string ->
      Spice_path.Rel.t ->
      (Spice_edit.Observed.t, string) result;
        (** [read ~reference path] is the snapshot state of [path] in the same
            vocabulary as live reads; [Spice_mutation.Image.of_target] is its
            durable projection. *)
  }
  (** The type for checkpoint backends: three snapshot verbs and a name. Restore
      and diff are derivations through [Spice_edit] and [Spice_diff], not
      backend verbs. *)

  val git_tree :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    run:(string list -> (string, string) result) ->
    data_root:string ->
    workspace_root:string ->
    unit ->
    t option
  (** [git_tree ~fs ~run ~data_root ~workspace_root ()] is the private
      shadow-git backend for [workspace_root], or [None] when the root is not
      inside a git repository or no usable git binary answers [run].

      The shadow git-dir lives below the workspace manifest directory at
      [data_root/workspaces/<key>/checkpoints.git]; it shares the workspace
      object database through alternates and respects the workspace ignore
      files. [capture] stages everything into the persistent shadow index and
      writes a tree object; the tree hash is the reference. No commits are
      created. [run argv] executes [argv] and returns raw stdout (snapshot file
      contents flow through it); it is a function so this module owns no process
      machinery. *)
end

(** {1:runtime Recorder} *)

type recorder
(** The type for a mutation evidence recorder.

    A recorder owns the host-side mutation evidence bridge for a workspace:
    ledger appends, optional checkpoint capture, and typed change derivation. It
    intentionally has no dependency on the session interpreter. *)

val recorder :
  log:Log.t ->
  ?checkpoint:Backend.t ->
  workspace_root:string ->
  unit ->
  recorder
(** [recorder ~log ?checkpoint ~workspace_root ()] records mutation evidence in
    [log]. [checkpoint], when present, is used for durable workspace snapshots;
    otherwise checkpoint recording is disabled and change recording still works.
    [workspace_root] is copied into checkpoint facts as audit data. *)

(** {1:hook Session hook} *)

val hook : recorder -> Session.hooks -> Session.hooks
(** [hook recorder hooks] installs [recorder]'s mutation-evidence recording into
    [hooks].

    Around each executable tool call it captures the before-mutation checkpoint
    of the turn — at most once, when the claim may mutate — and, after the tool
    effect and before the durable tool-finished event, derives that call's typed
    change rows, appends them to the ledger, and emits
    {!Spice_protocol.Event.Workspace_changed} with the run-cumulative totals. On
    the terminal turn outcome it captures the end-of-run checkpoint that bounds
    shell mutation attribution to the run window, when a shell ran under an
    available before-mutation checkpoint.

    Recording never changes the session transcript: emitted
    {!Spice_protocol.Event.Workspace_changed} rows and any ledger or checkpoint
    failure ({!Spice_protocol.Event.Workspace_degraded}) go to the interpreter's
    live observer, supplied at fire time. So [hook]'s position in the
    composition does not matter — an observer installed after it (as
    {!Runner.with_hooks} and {!Live} do) still receives the recording's events.
    Deterministic checkpoint ids make the once-per-turn captures durable across
    continuation processes. *)
