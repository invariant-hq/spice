(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Git worktree loader for review input.

    This is the effect boundary between {!Spice_review} and a Git worktree: it
    resolves a base revision, reads base blobs and worktree files, computes a
    {!Spice_review.Feature.t} for the changes, scans CR occurrences, and
    fingerprints the reviewable state so hosts can cheaply detect change.
    Nothing here mutates the repository or its index.

    Untracked files review as additions; [.gitignore]d paths are excluded, and
    the workspace meta directories ([.git], [.spice], [_build], [_opam]) are
    dropped from the reviewed feature. A tracked file under a meta directory is
    still excluded from the feature, but can move the {!fingerprint}: the
    fingerprint diff is not meta-filtered. *)

(** {1:errors Errors} *)

module Error : sig
  (** Loader errors. *)

  (** The class of a loader {!type-t}. Every case carries a rendered {!message};
      only {!Bad_revision}'s payload (the spec) differs from it. *)
  type kind =
    | Not_a_repository  (** [cwd] was not inside a Git worktree. *)
    | Bad_revision of string  (** The revision spec named no commit. *)
    | Git_failed of string
        (** A git subprocess failed; the string is its stderr. *)
    | Raced
        (** The worktree kept changing during a load; retried and still
            unstable. *)
    | Io of string
        (** A worktree file could not be read; the string is the cause. *)

  type t
  (** The type for loader errors. *)

  val kind : t -> kind
  (** [kind error] is [error]'s class. *)

  val message : t -> string
  (** [message error] is a human-readable description of [error]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf error] formats [error]'s message. *)
end

(** {1:repositories Repositories} *)

type t
(** The type for repository handles. A handle records the injected Git runner,
    filesystem capability, and resolved worktree root; it owns no processes or
    file descriptors. *)

type run = cwd:string -> string list -> (string, string) result
(** A prepared Git runner. The argument list excludes [git] and [-C cwd]. The
    host owns process construction, confinement, environment, and capture;
    [Error message] is a display-safe refusal or process diagnostic. *)

val discover :
  run:run -> fs:_ Eio.Path.t -> cwd:string -> (t, Error.t) result
(** [discover ~run ~fs ~cwd] is the repository whose worktree contains [cwd].
    Errors with {!Error.Not_a_repository} when [cwd] is not inside a Git
    worktree. *)

val root : t -> string
(** [root t] is [t]'s worktree root as an absolute path string. *)

val resolve_base : t -> string -> (string, Error.t) result
(** [resolve_base t spec] resolves revision [spec] to a full, immutable commit
    hash. This hash — not a symbolic ref — is what the loaders expect as [~base]
    so that a {!fingerprint} and the {!load} it guards always name the same
    state. Errors with {!Error.Bad_revision} when [spec] names no commit. *)

val user_handle : t -> Spice_cr.Handle.t
(** [user_handle t] is a CR handle for the repository user, derived from
    [git config user.name] with whitespace and colons replaced by dashes. Falls
    back to the handle ["user"]. *)

(** {1:loading Loading} *)

val fingerprint : t -> base:string -> (string, Error.t) result
(** [fingerprint t ~base] is the current fingerprint of the reviewable state
    from [base] to the worktree: the tracked diff plus untracked file paths and
    content identities. [base] must be a resolved commit hash (see
    {!resolve_base}); a symbolic ref would let the fingerprinted state drift out
    from under the {!load} it guards. *)

val load : t -> base:string -> (Spice_review.Live.load, Error.t) result
(** [load t ~base] loads the worktree changes against commit [base] as a
    {!Spice_review.Live.load}: the feature holds tracked edits plus untracked
    files as additions with the tip label ["WORKTREE"], the CR occurrences are
    scanned from the worktree texts of non-deleted changed files, and the
    fingerprint tokens the reviewable state.

    The snapshot is guarded by fingerprints taken before and after reading
    content, with a small bounded retry; a worktree that keeps changing errors
    with {!Error.Raced}. *)

val load_if_changed :
  t ->
  base:string ->
  known:string option ->
  ([ `Unchanged | `Loaded of Spice_review.Live.load ], Error.t) result
(** [load_if_changed t ~base ~known] is [`Unchanged] when the current
    fingerprint equals [known], and a fresh [`Loaded] otherwise. This is the
    operation {!Spice_review.Live} [Load] actions map to. *)

(** {1:glance Glance projections}

    Cheap, feature-free projections for surfaces that summarize the worktree at
    a glance — the home brief in particular — without paying for the full
    {!load}. All agree with {!load} on which files count.

    A live surface that polls on a cadence should drive {!glance_if_changed},
    which gates the whole projection on the shared {!fingerprint}: an idle
    worktree costs one probe per tick and the caller reuses its cached brief.
    The single-fact {!stats} and {!crs} queries are the building blocks and each
    recomputes on every call. *)

val stats : t -> base:string -> (Spice_diff.stats, Error.t) result
(** [stats t ~base] is the change statistics from commit [base] to the worktree
    without building the reviewable feature: file count, added lines, and
    removed lines.

    The file count is the set {!load} reviews — tracked changes against [base]
    (renames disabled), plus untracked files as additions, both with the
    workspace meta directories ([.git], [.spice], [_build], [_opam]) excluded —
    so the home brief and the [/review] screen agree on it. Tracked line counts
    are git's own (from [git diff --numstat]); untracked additions are counted
    with {!Spice_diff}'s line rule over the worktree text, exactly as {!load}'s
    additions would be. Because the tracked side reports git's counts rather
    than the review screen's recomputed Myers hunks, pathological inputs can
    differ by a line or two from a full {!load}; the file count never does.
    Binary tracked changes count toward files with no line counts, mirroring the
    review's opaque files.

    [base] must be a resolved commit hash (see {!resolve_base}). *)

val crs : t -> base:string -> (Spice_cr.Occurrence.t list, Error.t) result
(** [crs t ~base] scans CR occurrences from the worktree texts of the files
    changed from commit [base], without building the reviewable feature.

    The scanned set is the one {!load} reports: every changed, non-deleted file
    (tracked against [base] with renames disabled, plus untracked files), with
    the workspace meta directories excluded, scanned with its conventional
    comment syntax. Occurrences are returned in feature file order then source
    order. This is the cheap path behind a CR count at a glance; fold it into
    open and addressed totals with {!Spice_cr.Occurrence.counts} and
    {!user_handle}.

    [base] must be a resolved commit hash (see {!resolve_base}). *)

type glance = {
  stats : Spice_diff.stats;  (** Worktree change statistics, as {!val-stats}. *)
  crs : Spice_cr.Occurrence.t list;
      (** CR occurrences in changed files, as {!val-crs}. *)
  fingerprint : string;
      (** Opaque, process-local equality token for the scanned state — the same
          value {!val-fingerprint} returns. Never persist it. *)
}
(** The type for a one-scan worktree glance: the {!val-stats} and {!val-crs}
    projections tagged with the {!field-fingerprint} of the state they describe.
*)

val glance_if_changed :
  t ->
  base:string ->
  known:string option ->
  ([ `Unchanged | `Loaded of glance ], Error.t) result
(** [glance_if_changed t ~base ~known] is [`Unchanged] when the worktree
    fingerprint still equals [known], and a fresh [`Loaded] glance otherwise —
    the combined {!val-stats}/{!val-crs} projection a home poller drives on a
    short cadence.

    The fingerprint is taken first (one [git diff] plus the untracked scan, the
    same primitive {!load_if_changed} uses); an unchanged worktree pays only
    that and returns without running numstat, name-status, or reading files. A
    changed worktree then computes {!val-stats} and {!val-crs}, keyed by the new
    fingerprint so the caller can cache the derived brief against it and
    short-circuit the next tick. Unlike {!load}, the glance takes no
    before/after fingerprint guard: a worktree that changes mid-scan yields a
    momentarily skewed count that the next tick corrects — tolerable for a
    glance, not for a review.

    [base] must be a resolved commit hash (see {!resolve_base}). *)

(** {1:records Review records} *)

module Records : sig
  (** The durable review-record store in a caller-owned global directory.

      Records live at [dir/<key>.json], keyed by the review's base and mode.
      Writes are atomic (exclusive-create then rename) and the store is pruned
      to its newest entries. Restore is validated by
      {!Spice_review.Persist.restore}, so a missing or corrupt record only costs
      saved marks. *)

  val key : base:string -> string
  (** [key ~base] is the record key for a worktree review against [base]. *)

  val load :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    dir:string ->
    key:string ->
    Spice_review.Persist.t option
  (** [load ~fs ~dir ~key] is the saved record under [dir], when one
      exists and decodes; anything else is [None]. *)

  val save :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    dir:string ->
    key:string ->
    Spice_review.Persist.t ->
    (unit, string) result
  (** [save ~fs ~dir ~key record] writes [record] atomically under [dir] and
      prunes the store to its newest entries. *)
end

(** {1:apply Applying CR mutations} *)

type apply_error =
  | Stale_worktree
      (** The worktree fingerprint no longer matches the review's; retry after
          the review refreshes. *)
  | Apply_failed of string  (** Any other failure, display-safe. *)

val apply_op :
  t ->
  base:string ->
  expected:string ->
  Spice_review.Op.t ->
  (Spice_review.Live.load, apply_error) result
(** [apply_op t ~base ~expected op] re-verifies the worktree fingerprint against
    [expected], applies [op]'s pure {!Spice_cr} edit to its file, writes it
    atomically, and reloads the snapshot. A moved worktree is {!Stale_worktree};
    stale occurrences, files without a conventional comment syntax, and racing
    edits are {!Apply_failed} — the caller keeps its previous review either way.
*)
