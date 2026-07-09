(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Sidecar persistence for the host workflow artifacts.

    Plans, todos, goals, and subagent runs are host product state kept beside a
    session's replay log, below a workflow [root]. The artifact {e vocabulary} —
    the {!Spice_protocol.Plan.t}, {!Spice_protocol.Todo.t},
    {!Spice_protocol.Goal.t}, and {!Spice_protocol.Subagent_run.t} values, their
    constructors, transitions, and codecs — lives in {!Spice_protocol}; this
    module only stores, loads, lists, and, for plans and goals, resolves them.

    The artifacts share one JSON-file backend but not one storage shape: plans
    are keyed per session and id, todos and goals per session, and subagent runs
    per parent, one file per child. {!Plan}, {!Todo}, {!Goal}, and
    {!Subagent_run} own those key schemes and expose the verbs each surface
    needs. Storage failures report through {!Error}, the one boundary-visible
    piece of the backend.

    {b Serialization.} Writes to a single artifact file are truncate-and-replace
    and are not atomic against a concurrent writer of the {e same} file;
    correctness requires per-file single-writer discipline. The per-session/id
    plan and per-session todo and goal files meet this by construction. Subagent
    runs meet it by storing one file per child
    ([subagents/<parent>/<child>.json]) so a run's status transitions rewrite
    only that child's file — there is no per-parent aggregate for two children
    to race on. {!Plan.create} and the exclusive writes are check-then-write and
    do not serialize concurrent creators; a caller relying on the exclusivity
    must serialize creation itself. *)

(** {1:errors Errors} *)

module Error : sig
  (** Artifact storage errors. *)

  (** The type for an artifact storage error. *)
  type t =
    | Not_found of { kind : string; key : string }
        (** No stored [kind] artifact exists for [key]. *)
    | Conflict of { kind : string; key : string }
        (** The stored [kind] artifact for [key] is not in the state the
            operation requires: it already exists when a create expects none, or
            it has moved past the lifecycle state a transition expects. Recovery
            is to reload and re-inspect, not to repair the store. *)
    | Corrupt_file of { path : string; message : string }
        (** The file at [path] could not be encoded, decoded, or matched to the
            requested key. *)
    | Io of { path : string; message : string }
        (** A filesystem operation for [path] failed. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for logs and CLI output. The
      wording is not a stable machine-readable interface. *)

  val diagnostic : t -> Spice_diagnostic.t
  (** [diagnostic e] renders [e] for the host boundary. Storage errors carry no
      hints. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message} [e]. *)

  val to_protocol_error : t -> Spice_protocol.Error.t
  (** [to_protocol_error e] maps a storage error to the host-boundary error a
      turn propagates: a {!Corrupt_file} or {!Io} becomes
      {!Spice_protocol.Error.Storage}, and a {!Not_found} or {!Conflict} — a
      lower-layer invariant no mid-turn caller can repair — becomes
      {!Spice_protocol.Error.Internal} carrying {!message}. Both the tool
      dispatch [Handler] and [Run] map artifact failures through this, so the
      execution-error wording stays single-sourced. *)
end

(** {1:plans Plans} *)

module Plan : sig
  (** Per-session plan storage and the plan-approval boundary.

      A plan is stored in one file per id under [root/plans/<session>]. A model
      proposes a plan through the host-tool surface; the host saves it
      {!Spice_protocol.Plan.Status.Proposed} and the turn blocks. A user
      decision drives it through {!resolve}, which transitions the stored
      artifact and yields the model-visible answer text. Obsolete unscoped files
      directly under [root/plans] are rejected as {!Error.Corrupt_file}; they
      are never merged into the session-scoped namespace. *)

  val save :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    Spice_protocol.Plan.t ->
    (unit, Error.t) result
  (** [save ~fs ~root plan] writes [plan], replacing any plan with the same id.
      Encoding failures are {!Error.Corrupt_file}; filesystem failures are
      {!Error.Io}. *)

  val create :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    Spice_protocol.Plan.t ->
    (unit, Error.t) result
  (** [create ~fs ~root plan] writes [plan] only if no plan with its id exists;
      an existing id is {!Error.Conflict}. The existence check is not atomic
      against a concurrent creator (see the module note). *)

  val load :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    session:Spice_session.Id.t ->
    Spice_protocol.Plan.Id.t ->
    (Spice_protocol.Plan.t, Error.t) result
  (** [load ~fs ~root ~session id] loads [session]'s plan [id]. A missing plan
      is {!Error.Not_found}; a malformed file or a stored session or id that
      does not match the requested key is {!Error.Corrupt_file}. *)

  val list :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    session:Spice_session.Id.t ->
    (Spice_protocol.Plan.t list, Error.t) result
  (** [list ~fs ~root ~session] lists [session]'s plans. A missing directory is
      an empty list; results are newest first by
      {!Spice_protocol.Plan.updated_at}, then by id. Malformed files or a stored
      session that does not match [session] are {!Error.Corrupt_file}. *)

  val resolve :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    session:Spice_session.Id.t ->
    now:Spice_session.Time.t ->
    decision:Spice_protocol.Plan.Decision.t ->
    Spice_protocol.Plan.Proposal.t ->
    (string, Error.t) result
  (** [resolve ~fs ~root ~session ~now ~decision proposal] applies [decision] to
      [session]'s stored plan named by [proposal].

      It loads the proposal's plan, approves or rejects it at [now], saves the
      transitioned artifact, and returns the model-visible answer text the
      surface submits as an ordinary session answer. The answer wording lives
      here, once. Storage failures are {!Error.t}; a stored plan that is no
      longer proposable — a state race, e.g. a later turn superseded it while a
      stale prompt was open — is reported as {!Error.Conflict}, and recovery is
      to reload and re-inspect, not to repair the store. *)
end

(** {1:todos Todos} *)

module Todo : sig
  (** Per-session todo storage.

      A session's whole todo list is stored in one file per session under
      [root/todos]. The model replaces the list in one call, so there are no
      per-item transitions. *)

  val save :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    session:Spice_session.Id.t ->
    Spice_protocol.Todo.t ->
    (unit, Error.t) result
  (** [save ~fs ~root ~session todos] replaces the whole stored list for
      [session]. Encoding failures are {!Error.Corrupt_file}; filesystem
      failures are {!Error.Io}. *)

  val load :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    Spice_session.Id.t ->
    (Spice_protocol.Todo.t, Error.t) result
  (** [load ~fs ~root session] loads todos for [session]. A missing list is
      {!Spice_protocol.Todo.empty}; a malformed file is {!Error.Corrupt_file}.
  *)
end

(** {1:goals Goals} *)

module Goal : sig
  (** Per-session goal storage and the goal update boundary.

      A session's goal is stored in one file per session under [root/goals]. At
      most one goal exists per session; setting a new goal after a terminal one
      replaces the file — V1 keeps no goal history. A stored goal whose session
      does not match its key is {!Error.Corrupt_file}. *)

  val save :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    Spice_protocol.Goal.t ->
    (unit, Error.t) result
  (** [save ~fs ~root goal] writes [goal], replacing any goal for its session.
      Encoding failures are {!Error.Corrupt_file}; filesystem failures are
      {!Error.Io}. *)

  val load :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    Spice_session.Id.t ->
    (Spice_protocol.Goal.t option, Error.t) result
  (** [load ~fs ~root session] is [session]'s goal, or [None] when no goal was
      ever set. A malformed file, or one whose stored session disagrees with
      [session], is {!Error.Corrupt_file}. *)

  (** The type for a goal update's model-visible resolution: the confirmation
      for an applied transition, or the refusal the model can correct from. *)
  type update_result = Updated of string | Refused of string

  val update :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    now:Spice_session.Time.t ->
    session:Spice_session.Id.t ->
    Spice_protocol.Goal.Update.t ->
    (update_result, Error.t) result
  (** [update ~fs ~root ~now ~session update] applies the model's report to
      [session]'s stored goal.

      It loads the goal, applies {!Spice_protocol.Goal.apply} at [now], saves
      the transitioned artifact, and returns the model-visible confirmation —
      including final token usage for a completed budgeted goal. The answer
      wording lives here, once. A missing goal or a transition the artifact
      rejects (e.g. the user paused or cleared it mid-turn) is {!Refused} with
      the diagnostic; the model sees it as an error result and can correct.
      Storage failures are {!Error.t}. *)
end

(** {1:subagent_runs Subagent runs} *)

module Subagent_run : sig
  (** Per-child subagent-run storage.

      Each run is stored in its own file at
      [root/subagents/<parent>/<child>.json], keyed by the child session it
      records. One file per child lets a run's status transitions rewrite only
      that child's file, with no per-parent aggregate for concurrent children to
      race on. A file whose stored parent or child does not match its path is
      {!Error.Corrupt_file}. *)

  val put :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    Spice_protocol.Subagent_run.t ->
    (unit, Error.t) result
  (** [put ~fs ~root run] writes [run] to its child's file below its parent,
      replacing any prior record for that child. This records a new run and
      persists every later status transition; the single-writer discipline is
      per child. Encoding failures are {!Error.Corrupt_file}; filesystem
      failures are {!Error.Io}. *)

  val load :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    parent:Spice_session.Id.t ->
    child:Spice_session.Id.t ->
    (Spice_protocol.Subagent_run.t option, Error.t) result
  (** [load ~fs ~root ~parent ~child] is the run [parent] spawned for [child],
      or [None] when no such file exists. A malformed file, or one whose stored
      parent or child disagrees with [parent]/[child], is {!Error.Corrupt_file}.
  *)

  val list :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    parent:Spice_session.Id.t ->
    (Spice_protocol.Subagent_run.t list, Error.t) result
  (** [list ~fs ~root ~parent] lists the runs [parent] spawned, sorted by
      creation time and then child id. A missing directory is an empty list;
      non-JSON entries are ignored. A file whose stored parent does not match
      [parent] is {!Error.Corrupt_file}. *)

  val children :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    root:string ->
    (Spice_session.Id.t list, Error.t) result
  (** [children ~fs ~root] is every child session id with a run record, across
      all parents, from filenames alone — no run file is decoded. For callers
      that need only the membership set, like the session picker's hide-children
      filter. *)
end
