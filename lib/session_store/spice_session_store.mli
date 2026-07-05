(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** CAS persistence for durable session documents.

    A store saves and loads full {!Spice_session.t} documents under a filesystem
    root. It owns document paths, directory creation, atomic replacement,
    cross-process advisory locking, optimistic revisions, timestamping on save,
    and lifecycle-filtered listing.

    Session semantics remain in {!Spice_session}. Construct a session with
    {!Spice_session.create}, persist it with {!create}, then compose changes
    with {!append} or {!save}. A returned {!Document.t} carries the revision
    that must be supplied to the next write.

    {b Concurrency.} Writers serialize {e across processes} on a single
    [sessions/.lock] advisory lock, and {e across fibers of one process} on a
    process-global mutex keyed by the canonical store root (POSIX advisory locks
    are per-process and so provide no intra-process exclusion on their own). The
    compare-and-set revision re-check in {!save} therefore runs without a
    concurrent same-process writer: two writers that race a write from the same
    revision produce exactly one commit and one {!Error.Conflict}, never a lost
    update. Handles minted separately over the same root share the mutex. *)

(** {1:stores Stores} *)

type t
(** The type for a session document store.

    Values are handles over [fs], [root], and [clock]. Constructing a store does
    not read, validate, or create files; filesystem effects happen when an
    operation is run. *)

val make :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  clock:_ Eio.Time.clock ->
  root:Spice_path.Abs.t ->
  t
(** [make ~fs ~clock ~root] is a store rooted at [root] under [fs].

    Documents are saved below [root / "sessions"]. [clock] is used by {!save}
    and operations built on it to set {!Spice_session.Metadata.updated_at}.
    [root] is interpreted by [fs]; callers should not construct document paths
    themselves. *)

val root : t -> Spice_path.Abs.t
(** [root t] is the store root given to {!make}. Host sidecars (such as the
    mutation ledger) live beside the session documents under this root; they are
    not part of the session document contract. *)

(** {1:documents Documents} *)

module Document : sig
  type t
  (** The type for a loaded or saved session document: a session paired with the
      revision of its exact persisted bytes.

      Only store operations mint a document, so its revision always matches its
      session bytes. Callers pass documents back to {!save} or {!append} to
      perform optimistic-concurrency writes without manually pairing sessions
      with revisions. A document becomes stale as soon as another successful
      write replaces the same session. *)

  val session : t -> Spice_session.t
  (** [session t] is [t]'s session document. *)

  val revision : t -> Spice_session.Revision.t
  (** [revision t] is [t]'s stale-write token. *)
end

(** {1:corruption Corruption} *)

module Corrupt : sig
  type t = private {
    id : Spice_session.Id.t option;
    path : string;
    message : string;
  }
  (** The type for a corrupt document discovered during listing. *)

  val id : t -> Spice_session.Id.t option
  (** [id t] is the session id parsed from the store path, when available. *)

  val path : t -> string
  (** [path t] is the offending document path. *)

  val message : t -> string
  (** [message t] is the decode or validation diagnostic. *)
end

(** {1:errors Errors} *)

module Error : sig
  (** Recoverable session store errors.

      Store operations return structured errors for missing documents,
      stale-write conflicts, invalid persisted data, session-domain failures,
      invalid caller input at IO boundaries, and filesystem failures. *)

  type t =
    | Not_found of Spice_session.Id.t
        (** No document exists for the requested session id. *)
    | Already_exists of Spice_session.Id.t
        (** A create operation found an existing document for the session id. *)
    | Conflict of {
        id : Spice_session.Id.t;
        expected : Spice_session.Revision.t;
        actual : Spice_session.Revision.t;
      }
        (** The document was changed after [expected] was observed. [actual] is
            the revision currently persisted for [id]. *)
    | Corrupt of { path : string; message : string }
        (** Persisted data at [path], or encoded data about to be written, is
            not a valid session store document. *)
    | Session of Spice_session.Error.t
        (** A session-domain operation rejected the requested semantic change.
        *)
    | Io of { path : string; message : string }
        (** A filesystem operation failed for [path]. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      The returned string is suitable for display and logs. Callers that need
      stable control flow should inspect [e] directly. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats an error for diagnostics. The output is not stable storage
      syntax. *)

  val diagnostic : ?id:Spice_session.Id.t -> t -> Spice_diagnostic.t
  (** [diagnostic ?id e] is the user-facing diagnostic for [e].

      For corrupt documents, [id] names the session the caller attempted to
      load, while the diagnostic context carries the persisted path and decoder
      details. *)
end

(** {1:operations Operations} *)

val create : t -> Spice_session.t -> (Document.t, Error.t) result
(** [create store session] creates and saves [session].

    The write creates the store directories as needed and fails rather than
    replacing an existing document. Unlike {!save}, [create] preserves the
    timestamps already present in [session].

    Returns {!Error.Already_exists} if a document for the same id already
    exists. Returns {!Error.Corrupt} if [session] cannot be encoded, and
    {!Error.Io} for filesystem failures. *)

val load : t -> Spice_session.Id.t -> (Document.t, Error.t) result
(** [load store id] loads session [id].

    The loaded document is decoded through {!Spice_session.jsont}, so semantic
    replay is validated before [Ok] is returned. Returns {!Error.Not_found} if
    no document exists for [id]. Returns {!Error.Corrupt} if the file is not a
    valid session document or if its embedded id differs from [id]. Returns
    {!Error.Io} for filesystem failures. *)

val save : t -> Document.t -> Spice_session.t -> (Document.t, Error.t) result
(** [save store doc session] replaces the saved document if [doc]'s revision is
    still current.

    On success, [session]'s {!Spice_session.Metadata.updated_at} is set from the
    store clock, the encoded document is written by atomic replacement, and the
    returned document carries the new revision. [create] is the operation for
    first writes.

    Raises [Invalid_argument] if [session]'s id differs from [doc]'s session id.
    Returns {!Error.Not_found} if the document has been removed,
    {!Error.Conflict} if another writer has changed it, {!Error.Corrupt} if the
    updated session cannot be encoded or timestamped, and {!Error.Io} for
    filesystem failures. *)

val append :
  t -> Document.t -> Spice_session.Event.t list -> (Document.t, Error.t) result
(** [append store doc events] appends [events] to [doc]'s session and saves the
    resulting document with [doc]'s revision as the optimistic precondition.

    Events are applied in list order with {!Spice_session.Log.append_all}.
    Returns {!Error.Session} if the events violate session semantics. Otherwise
    the persistence behavior and write errors are those of {!save}. *)

val list :
  t ->
  ?include_archived:bool ->
  ?include_deleted:bool ->
  ?filter:(Document.t -> bool) ->
  ?limit:int ->
  unit ->
  (Document.t list * Corrupt.t list, Error.t) result
(** [list store ()] lists saved session documents.

    Missing store directories produce [Ok []]. Non-session entries and session
    directories without a document are ignored. Existing documents are decoded
    and validated as in {!load}; corrupt documents are returned as structured
    facts and do not count against [limit].

    Archived and deleted sessions are excluded by default. [filter], when
    present, is applied after lifecycle filters and before [limit]. Results are
    ordered by newest [updated_at] first, with session id as a deterministic
    tie-breaker, then truncated to [limit].

    Raises [Invalid_argument] if [limit] is present and not positive. *)
