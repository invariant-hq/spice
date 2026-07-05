(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Stale-safe workspace text edit plans.

    [spice.edit] defines inert descriptions of UTF-8 workspace text mutations
    and applies them through an explicit host IO boundary. The central type is
    {!type:t}: a full-file edit plan carrying the text preconditions required to
    reject stale writes before mutation starts.

    Constructing a plan and rendering its diff never reads or mutates the
    filesystem. Applying a plan requires an {!Apply.io}, which supplies locking,
    path revalidation, reads, and transition commits.

    Patch parsers, anchored editing tools, AST refactoring tools, and
    coding-agent tools should compute final complete file contents, construct
    plans with {!create}, {!rewrite}, {!delete}, and {!concat}, and then call
    {!apply}.

    [spice.edit] is not a patch parser, permission policy, checkpoint manager,
    revert engine, or session audit log. Those layers may render diffs, request
    permission, apply the plan, and record {!Result.t} or {!Apply_error.t}. *)

(** {1:kinds Kinds} *)

type kind = [ `Create | `Modify | `Delete ]
(** The kind of a planned filesystem mutation. *)

(** {1:states States} *)

module State : sig
  (** Complete target states used by planned text transitions. *)

  type t =
    | Missing  (** No file should exist. *)
    | Text of string  (** Complete validated UTF-8 file contents. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same state. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1:observed Observed States} *)

module Observed : sig
  (** Current write-side target states.

      Values are returned by {!Apply.io.read} during application.
      [Text contents] means [contents] is the complete current UTF-8 contents of
      a regular file. IO implementations must report unreadable, invalid,
      binary, oversized, or otherwise non-text targets with a structured
      {!Error.t} or [Other], according to the host tool's policy. *)

  type kind = [ `Missing | `Text | `Other ]
  (** The type for coarse current target states:
      - [`Missing], no target exists.
      - [`Text], a regular UTF-8 text file exists.
      - [`Other], a target exists but is not editable as text. *)

  type t =
    | Missing  (** No target exists at the path. *)
    | Text of string  (** A regular UTF-8 text file with complete contents. *)
    | Other
        (** A target exists, but cannot be edited as a regular UTF-8 text file.
        *)

  val text : t -> string option
  (** [text t] is [Some contents] for [Text contents] and [None] otherwise. *)

  val identity : t -> Spice_digest.Identity.t option
  (** [identity t] is the content identity for text targets. *)

  val equal_kind : kind -> kind -> bool
  (** [equal_kind a b] is [true] iff [a] and [b] are the same target kind. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same target state. *)

  val pp_kind : Format.formatter -> kind -> unit
  (** [pp_kind ppf kind] formats [kind] for diagnostics. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1:errors Errors} *)

module Error : sig
  (** Edit plan and application errors.

      Errors are structured so callers can branch on constructors. {!message}
      and {!pp} are for diagnostics only. *)

  type t = private
    | Invalid_text of Spice_workspace.Path.t option * string
        (** Supplied or read text is not valid UTF-8. In
            [Invalid_text (path, reason)], [reason] is non-empty and [path], if
            present, is the associated target. *)
    | Duplicate_path of Spice_workspace.Path.t
        (** Two planned changes, or two revalidated changes, target the same
            path. *)
    | State_mismatch of {
        path : Spice_workspace.Path.t;
            (** The revalidated path whose current state was checked. *)
        expected : Observed.kind;
            (** The target state required by the planned operation. *)
        actual : Observed.kind;  (** The target state returned by IO [read]. *)
      }  (** The current target state does not satisfy the planned operation. *)
    | Conflict of {
        path : Spice_workspace.Path.t;
            (** The revalidated path whose text precondition was checked. *)
        expected : State.t;
            (** The complete before state required by the planned change. *)
        actual : Observed.t;  (** The current state returned by IO [read]. *)
      }
        (** The current target no longer equals the complete before state
            carried by the edit plan. *)
    | Too_large of {
        path : Spice_workspace.Path.t;  (** The target path. *)
        size : int64;  (** The observed size in bytes. *)
        max_size : int64;
            (** The IO implementation's maximum complete-read size in bytes. *)
      }
        (** A complete text target exceeded the IO implementation's size bound.
        *)
    | Workspace of
        Spice_workspace.Path.t option * Spice_workspace.Resolve_error.t
        (** A workspace path resolution failure surfaced while reading or
            planning an edit. *)
    | Out_of_workspace of Spice_workspace.Path.t
        (** A revalidated edit target no longer belongs to the workspace. This
            is an edit-staleness failure, distinct from initial resolution. *)
    | Protected_path of Spice_workspace.Path.t * string
        (** A revalidated edit target is protected workspace metadata (for
            example [.git] or [.spice]) that tools must not modify. The string
            is the protected top-level name. This is the write-side policy that
            mirrors the command sandbox's protected-meta carveouts, so the edit
            tools cannot rewrite version-control or authority state that the
            confined shell cannot reach either. *)
    | Io of Spice_workspace.Path.t option * string
        (** IO implementation failure or contract violation. [reason] is
            non-empty. *)

  val path : t -> Spice_workspace.Path.t option
  (** [path e] is the target path most directly associated with [e], if any. *)

  val invalid_text : ?path:Spice_workspace.Path.t -> string -> t
  (** [invalid_text ?path reason] reports invalid UTF-8 text.

      Raises [Invalid_argument] if [reason] is empty. *)

  val duplicate_path : Spice_workspace.Path.t -> t
  (** [duplicate_path path] reports a duplicate edit target. *)

  val state_mismatch :
    path:Spice_workspace.Path.t ->
    expected:Observed.kind ->
    actual:Observed.kind ->
    t
  (** [state_mismatch ~path ~expected ~actual] reports that [path]'s current
      target state does not satisfy the planned operation. *)

  val conflict :
    path:Spice_workspace.Path.t -> expected:State.t -> actual:Observed.t -> t
  (** [conflict ~path ~expected ~actual] reports that [actual] no longer equals
      the complete before state [expected] required by a planned change. *)

  val too_large :
    path:Spice_workspace.Path.t -> size:int64 -> max_size:int64 -> t
  (** [too_large ~path ~size ~max_size] reports a target above the IO
      implementation's complete-read bound.

      Raises [Invalid_argument] if [size] or [max_size] is negative. *)

  val workspace :
    ?path:Spice_workspace.Path.t -> Spice_workspace.Resolve_error.t -> t
  (** [workspace ?path e] wraps a workspace path resolution failure. *)

  val out_of_workspace : Spice_workspace.Path.t -> t
  (** [out_of_workspace path] reports that a revalidated edit target no longer
      belongs to the workspace. *)

  val protected_path : path:Spice_workspace.Path.t -> name:string -> t
  (** [protected_path ~path ~name] reports that [path] lies within the protected
      workspace metadata directory [name] and cannot be modified by tools.

      Raises [Invalid_argument] if [name] is empty. *)

  val io : ?path:Spice_workspace.Path.t -> string -> t
  (** [io ?path reason] reports an IO implementation failure or contract
      violation.

      Raises [Invalid_argument] if [reason] is empty. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for logs and debugging. The
      exact text is not a stable matching surface and does not define
      tool-facing presentation policy. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same error. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)
end

(** {1:applying Applying} *)

module Apply : sig
  (** Edit plan application. *)

  type io = {
    with_write_lock :
      'a.
      Spice_workspace.Path.t list ->
      (unit -> ('a, Error.t) result) ->
      ('a, Error.t) result;
        (** [with_write_lock paths f] runs [f] in a critical section that
            serializes writes to every target in [paths]. [paths] contains
            planned paths and no duplicates.

            The lock must cover the namespace broad enough for every target that
            [revalidate] may return for those paths. [with_write_lock] must not
            run [f] when lock acquisition fails. If [f] returns [Error e],
            [with_write_lock] must return [Error e] unchanged unless lock
            release itself fails. *)
    revalidate :
      Spice_workspace.Path.t -> (Spice_workspace.Path.t, Error.t) result;
        (** [revalidate path] rechecks write-side path validity and returns the
            path that subsequent reads and mutations must use.

            [apply] rejects returned paths outside the supplied workspace and
            rejects duplicate returned paths before reading or mutating any
            target. Revalidation runs while the write lock is held. *)
    read : Spice_workspace.Path.t -> (Observed.t, Error.t) result;
        (** [read path] is the current target state for a revalidated path.

            Regular files that cannot be decoded as UTF-8 should be reported as
            {!Error.Invalid_text}. Regular files above the implementation's
            complete-read bound should be reported as {!Error.Too_large}. [read]
            runs while the write lock is held, after all revalidation succeeds,
            and before any mutation. *)
    commit :
      path:Spice_workspace.Path.t ->
      before:State.t ->
      after:State.t ->
      (unit, Error.t) result;
        (** [commit ~path ~before ~after] atomically applies the validated
            complete transition at [path].

            It is called only after every target in the plan has been
            revalidated, read, and checked against [before]. Parent directory
            creation and cleanup are outside the edit contract. *)
  }
  (** The type for edit application IO. All functions are called by {!apply};
      callers that only construct plans or render diffs do not need an IO value.
      Implementations should return structured {!Error.t} values rather than
      raise for recoverable workspace or backing-store failures. *)
end

(** {1:results Results} *)

module Result : sig
  (** Successful edit application results. *)

  module Entry : sig
    (** Single applied changes. *)

    type t
    (** The type for one successfully applied change.

        [target_path] is the revalidated path passed to IO [commit], which may
        differ from the planned path because revalidation may canonicalize or
        otherwise change the mutation target. [before] is the state observed
        during preflight validation. [after] is derived from the plan once the
        corresponding IO mutation succeeds. *)

    val kind : t -> kind
    (** [kind t] is the filesystem mutation kind of the applied change. *)

    val target_path : t -> Spice_workspace.Path.t
    (** [target_path t] is the revalidated path passed to IO [commit]. *)

    val before : t -> Observed.t
    (** [before t] is the target state read before mutation. *)

    val after : t -> Observed.t
    (** [after t] is the planned target state after successful mutation. The
        target is not read again after writing or removal. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same result entry. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics. *)
  end

  type t
  (** The type for a successful edit application. *)

  val empty : t
  (** [empty] is the successful result for an empty edit plan. *)

  val is_empty : t -> bool
  (** [is_empty t] is [true] iff [t] contains no applied entries. *)

  val entries : t -> Entry.t list
  (** [entries t] is the successfully applied entries in mutation order. The
      list is empty iff {!is_empty} is [true]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same application result. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

module Apply_error : sig
  (** Failed edit applications. *)

  type t
  (** The type for failed edit applications.

      {!applied} is empty for failures before mutation starts, including lock,
      revalidation, duplicate-path, read, state-mismatch, and conflict failures.
      If a write or removal fails after earlier mutations succeeded, {!applied}
      records the completed entries in mutation order and excludes the operation
      that reported the failure. It is not a complete forensic account of
      filesystem state after an uncertain IO failure. *)

  val error : t -> Error.t
  (** [error t] is the failure that stopped application. *)

  val applied : t -> Result.Entry.t list
  (** [applied t] is the confirmed entries completed before [error t]. *)

  val message : t -> string
  (** [message t] is [Error.message (error t)]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same apply error. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1:plans Plans} *)

type t
(** The type for workspace text edit plans.

    A plan contains at most one change per planned path. The plan may be empty.
    Applying an empty plan is a no-op and performs no IO. Non-empty plans are
    built from complete UTF-8 file contents and carry all text preconditions
    needed by {!apply}. *)

val empty : t
(** [empty] is the empty edit plan. *)

val is_empty : t -> bool
(** [is_empty t] is [true] iff [t] contains no planned changes. *)

val create :
  path:Spice_workspace.Path.t -> contents:string -> (t, Error.t) result
(** [create ~path ~contents] is a one-file creation plan.

    Applying the plan succeeds only if [path] revalidates inside the supplied
    workspace, the revalidated target is distinct from every other target in the
    plan, and the target is still missing. Parent directory creation is outside
    the edit contract.

    Errors with {!Error.Invalid_text} if [contents] is not valid UTF-8. *)

val rewrite :
  path:Spice_workspace.Path.t ->
  before:string ->
  after:string ->
  (t, Error.t) result
(** [rewrite ~path ~before ~after] is a full-file rewrite plan.

    [before] is the complete UTF-8 text that must still be present at the
    revalidated target when the plan is applied. The revalidated target must be
    distinct from every other target in the plan. Returns {!empty} when [before]
    and [after] are equal.

    Errors with {!Error.Invalid_text} if [before] or [after] is not valid UTF-8.
*)

val delete : path:Spice_workspace.Path.t -> before:string -> (t, Error.t) result
(** [delete ~path ~before] is a file deletion plan.

    Applying the plan succeeds only if [path] revalidates inside the supplied
    workspace, the revalidated target is distinct from every other target in the
    plan, and the target is still a complete text file whose contents are
    [before].

    Errors with {!Error.Invalid_text} if [before] is not valid UTF-8. *)

val concat : t list -> (t, Error.t) result
(** [concat plans] combines [plans] into one edit plan.

    Empty plans are ignored. [concat []] is {!empty}. The order of changes in
    the result follows the order of [plans] and the order of changes within each
    plan.

    Errors with {!Error.Duplicate_path} if two non-empty plans target the same
    planned path. Duplicate paths that appear only after write-side revalidation
    are reported by {!apply}. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same edit plan. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)

val diff :
  ?label:(Spice_workspace.Path.t -> Spice_diff.Label.t) ->
  ?mode:Spice_diff.render_mode ->
  ?limits:Spice_diff.Limits.t ->
  ?context:int ->
  t ->
  Spice_diff.t
(** [diff ?label ?mode ?limits ?context t] renders [t] as a display diff.

    Rendering performs no filesystem I/O, permission checks, path revalidation,
    or conflict checks. The returned diff is display evidence, not a replay
    format. *)

val apply :
  io:Apply.io ->
  workspace:Spice_workspace.t ->
  t ->
  (Result.t, Apply_error.t) result
(** [apply ~io ~workspace t] applies [t] through [io].

    Application of a non-empty plan runs under [io.with_write_lock (paths t)],
    revalidates every path, checks that all revalidated paths remain inside
    [workspace] and are distinct, reads every current target state, verifies all
    text preconditions, and only then starts mutating files. Applying {!empty}
    is a no-op and does not acquire a lock.

    File mutations are committed in plan order. Each transition commit is atomic
    according to the IO contract; whole-plan rollback is not guaranteed.

    On failure, the returned {!Apply_error.t} contains the stopping error and
    the confirmed entries applied before that error. {!Apply_error.applied} is
    empty for lock, revalidation, duplicate-path, read, state-mismatch, and
    conflict failures because those happen before mutation starts. If a commit
    reports an error, the failing operation is not included in
    {!Apply_error.applied}.

    Failure causes include:
    - {!Error.Out_of_workspace}, when revalidation leaves [workspace].
    - {!Error.Duplicate_path}, when distinct plan paths revalidate to the same
      target.
    - {!Error.State_mismatch}, {!Error.Conflict}, {!Error.Invalid_text}, or
      {!Error.Too_large}, when current target states do not satisfy the plan.
    - {!Error.Io}, when the IO implementation reports a backing-store failure or
      contract violation. *)
