(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure code-review state over one feature snapshot.

    A review is the reviewed/unreviewed/approved state of one feature — the diff
    between a base and a tip text state — together with its CR comment index and
    a cursor. Producers load feature snapshots and CR occurrences; this module
    records marks, a verdict, and orientation over them, and carries that state
    forward when the snapshot is {!refresh}ed.

    The module is pure: no filesystem, VCS, clock, or persistence effects. Base
    and tip are opaque display labels; nothing here resolves revisions, reads
    files, or edits source comments. The {!Live} state machine expresses when a
    host should reload and how reload results replace the review, but the host
    performs every effect.

    Carry-forward is conservative by construction: a mark survives a refresh
    only when content evidence proves its scope unchanged, and a verdict
    recorded for older content is visibly {{!Verdict.freshness}stale}, never
    silently fresh. When in doubt, state is dropped and the unit returns to
    unreviewed. *)

(** {1:errors Errors} *)

module Error : sig
  (** Review errors. *)

  (** The type for stable, matchable review error classes.

      Human-readable messages are diagnostics only; use [kind] values for
      control flow and tests. *)
  type kind =
    | Invalid_scope
        (** A scope cannot be realized against the current feature. *)
    | Invalid_cursor
        (** A cursor target does not exist in the current review. *)
    | Invalid_file
        (** A feature file cannot be constructed from the supplied sides or
            diff parameters. *)
    | Busy
        (** A live source mutation cannot start because another mutation is
            running. *)
    | Stale_snapshot
        (** A source mutation was requested against content that is no longer
            the loaded snapshot. *)

  type t
  (** The type for review errors. *)

  val kind : t -> kind
  (** [kind error] is [error]'s class. *)

  val message : t -> string
  (** [message error] is a human-readable description of [error]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf error] formats [error]'s message. *)
end

(** {1:features Feature snapshots} *)

module Feature : sig
  (** Feature snapshots: the diff between a base and a tip text state.

      A feature is an inert value. Producers compute it from any source that can
      supply per-file before and after texts — a Git worktree loader, a
      mutation-ledger checkpoint, a test fixture. *)

  module File : sig
    (** One file's change within a feature. *)

    type status =
      | Added
      | Deleted
      | Modified  (** The type for file change status. *)

    (** The type for reviewable file content. *)
    type content =
      | Text of Spice_diff.Hunk.t list
          (** Line-diffable text change, as computed hunks. *)
      | Opaque of [ `Binary | `Too_large ]
          (** Content that cannot be presented as a line diff. Opaque files are
              reviewable as whole-file scopes only. *)

    type t
    (** The type for one file's change. *)

    val make :
      ?context:int ->
      ?max_edit_distance:int ->
      path:Spice_path.Rel.t ->
      before:string option ->
      after:string option ->
      unit ->
      (t, Error.t) result
    (** [make ~path ~before ~after ()] is the change of [path] from [before] to
        [after]. [None] means the file is absent on that side; the status is
        derived from side presence.

        Hunks are computed with {!Spice_diff.hunks}. [context] is the number of
        unchanged lines kept around each change region and defaults to [12], the
        review display convention. [max_edit_distance] bounds the diff search
        and defaults to [4096]; when the bound is exceeded the content is
        [Opaque `Too_large]. A present side that is not valid UTF-8 makes the
        content [Opaque `Binary].

        Errors with {!Error.Invalid_file} if both sides are [None] or a supplied
        integer is negative. *)

    val path : t -> Spice_path.Rel.t
    (** [path file] is [file]'s root-relative path. *)

    val status : t -> status
    (** [status file] is [file]'s change status. *)

    val content : t -> content
    (** [content file] is [file]'s reviewable content. *)

    val before : t -> string option
    (** [before file] is [file]'s full before text, if present. Full texts are
        kept so hosts can render wider context and anchor comments. *)

    val after : t -> string option
    (** [after file] is [file]'s full after text, if present. *)

    val digest : t -> Spice_digest.Identity.t
    (** [digest file] is a stable content identity of [file]'s (before, after)
        pair: the file review unit's identity evidence across refreshes. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] have the same path and content
        digest. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf file] formats [file] for diagnostics. *)
  end

  type t
  (** The type for feature snapshots. *)

  val v : ?title:string -> base:string -> tip:string -> File.t list -> t
  (** [v ~base ~tip files] is the feature changing [files] from [base] to [tip].

      [base] and [tip] are opaque display labels such as ["main"] or
      ["WORKTREE"]; this module resolves nothing. [files] are ordered by path;
      when several entries share a path the first one wins. *)

  val title : t -> string option
  (** [title feature] is [feature]'s display title, if any. *)

  val base : t -> string
  (** [base feature] is [feature]'s base label. *)

  val tip : t -> string
  (** [tip feature] is [feature]'s tip label. *)

  val files : t -> File.t list
  (** [files feature] is [feature]'s file changes in path order. *)

  val find_file : t -> path:Spice_path.Rel.t -> File.t option
  (** [find_file feature ~path] is the file change at [path], if any. *)

  val digest : t -> Spice_digest.Identity.t
  (** [digest feature] is a stable content identity of [feature]'s combined file
      content identities: the verdict freshness token. Labels and title do not
      contribute. *)

  val is_empty : t -> bool
  (** [is_empty feature] is [true] iff [feature] changes no files. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have equal content digests. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf feature] formats [feature] for diagnostics. *)
end

(** {1:scopes Scopes} *)

module Scope : sig
  (** Reviewable scopes within a feature.

      Scopes nest: the feature contains files, a file contains its hunks, and a
      hunk contains lines on its sides. *)

  type side = Old | New  (** The type for diff sides. *)

  (** The type for reviewable scopes. Scopes carry no invariant beyond their
      field types: a scope's validity is defined against a concrete feature by
      the review operations, so [Hunk] ranges and [Line] numbers that no feature
      realizes are constructible but reject when marked or selected. *)
  type t =
    | Feature  (** The whole-feature scope. *)
    | File of Spice_path.Rel.t  (** The whole-file scope for a path. *)
    | Hunk of {
        path : Spice_path.Rel.t;
        old_start : int;
        old_count : int;
        new_start : int;
        new_count : int;
      }  (** The scope of the hunk covering those ranges in [path]. *)
    | Line of side * Spice_path.Rel.t * int
        (** The scope of one text line: 1-based line on a side of a path's diff.
        *)

  val of_hunk : path:Spice_path.Rel.t -> Spice_diff.Hunk.t -> t
  (** [of_hunk ~path hunk] is the {!constructor-Hunk} scope for [hunk]'s ranges.
  *)

  val path : t -> Spice_path.Rel.t option
  (** [path scope] is the path [scope] addresses. [None] for [Feature]. *)

  val contains : t -> t -> bool
  (** [contains outer inner] is [true] iff [inner] falls within [outer]:
      [Feature] contains every scope, a file contains every scope with its path,
      a hunk contains itself and the line scopes within its side ranges, and a
      line contains itself. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same scope. *)

  val compare : t -> t -> int
  (** [compare a b] is a total order on scopes compatible with {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf scope] formats [scope] for diagnostics. *)
end

(** {1:marks Marks and verdicts} *)

module Mark : sig
  (** Per-scope review marks.

      A mark records that a scope was explicitly reviewed or unreviewed,
      together with the content evidence current at mark time. Marks are created
      through {!Spice_review.mark_reviewed} and {!Spice_review.mark_unreviewed},
      never directly. *)

  type state = Reviewed | Unreviewed  (** The type for mark states. *)

  type t
  (** The type for review marks. *)

  val scope : t -> Scope.t
  (** [scope mark] is the scope [mark] applies to. *)

  val state : t -> state
  (** [state mark] is [mark]'s state. *)

  val evidence : t -> Spice_digest.Identity.t
  (** [evidence mark] is the content identity of [mark]'s scope at mark time.
      Refresh and restore keep a mark only when the evidence still matches. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] mark the same scope with the same
      state and evidence. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf mark] formats [mark] for diagnostics. *)
end

module Verdict : sig
  (** Whole-feature verdicts. *)

  (** The type for verdicts. *)
  type t =
    | Pending
    | Approved of { feature : Spice_digest.Identity.t }
        (** [Approved] records the feature content identity it approved, so
            staleness is derived and visible. *)

  type freshness = [ `Pending | `Approved | `Stale ]
  (** The type for verdict freshness relative to current feature content.
      [`Stale] means the verdict approved older content. *)

  val freshness : t -> feature:Spice_digest.Identity.t -> freshness
  (** [freshness verdict ~feature] is [verdict]'s freshness against the current
      feature content digest [feature]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same verdict. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf verdict] formats [verdict] for diagnostics. *)
end

(** {1:cursors Cursors} *)

module Cursor : sig
  (** Review cursors: the currently selected review target. *)

  (** The type for cursors: the currently selected review target. *)
  type t =
    | Scope of Scope.t  (** The cursor at a scope. *)
    | Cr of int
        (** The cursor at a CR occurrence, an index into the review's CR
            occurrence list, see {!Spice_review.cr}. *)

  val feature : t
  (** [feature] is [Scope Scope.Feature], the cursor at the whole-feature scope
      and the common starting target. *)

  type move =
    | Next
    | Previous
    | Next_file
    | Previous_file
    | Next_cr
    | Previous_cr
    | First
    | Last
        (** The type for cursor movements, see {!Spice_review.move_cursor}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] select the same target. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf cursor] formats [cursor] for diagnostics. *)
end

(** {1:reviews Reviews} *)

type t
(** The type for reviews: one feature snapshot, its CR occurrence index, marks,
    a verdict, and a cursor. Values are immutable. *)

val v : feature:Feature.t -> crs:Spice_cr.Occurrence.t list -> t
(** [v ~feature ~crs] is a fresh review of [feature] with CR occurrences [crs],
    a pending verdict, no marks, and the cursor at {!Cursor.feature}.

    [crs] are indexed in the given order; producers supply them in feature file
    order, then source order. Occurrences in files the feature does not change
    are valid review items. *)

val refresh : t -> feature:Feature.t -> crs:Spice_cr.Occurrence.t list -> t
(** [refresh review ~feature ~crs] is [review] over the new snapshot with state
    carried forward conservatively:

    - a feature mark carries iff the feature digest is unchanged;
    - a file mark carries iff the same path is present with an equal content
      digest;
    - a hunk mark carries iff the new file has exactly one hunk with equal
      changed-line evidence — position may shift, content may not;
    - a line mark carries iff the same side and line number holds a line with
      equal text evidence;
    - everything else is dropped, so new and edited units are unreviewed.

    The verdict value is kept; its {{!Verdict.freshness}freshness} is derived
    against the new feature digest. The cursor is preserved when it still
    selects a valid target — CR targets re-anchor by occurrence digest, path,
    and duplicate ordinal — otherwise it moves to the nearest valid target, or
    {!Cursor.feature} when nothing remains. *)

(** {2:review_access Accessors} *)

val feature : t -> Feature.t
(** [feature review] is [review]'s feature snapshot. *)

val crs : t -> Spice_cr.Occurrence.t list
(** [crs review] is [review]'s CR occurrences in index order. *)

val cr : t -> int -> Spice_cr.Occurrence.t option
(** [cr review index] is the CR occurrence at [index], if any. *)

val marks : t -> Mark.t list
(** [marks review] is [review]'s explicit marks, in scope order. *)

val mark : t -> Scope.t -> Mark.t option
(** [mark review scope] is the explicit mark on exactly [scope], if any. *)

val effective_mark : t -> Scope.t -> Mark.t option
(** [effective_mark review scope] is the most specific explicit mark whose scope
    contains [scope], if any. A reviewed file mark covers the file's hunks; a
    later unreviewed mark on one hunk overrides it for that hunk. *)

val is_reviewed : t -> Scope.t -> bool
(** [is_reviewed review scope] is [true] iff [scope]'s effective mark state is
    {!Mark.Reviewed}. *)

val verdict : t -> Verdict.t
(** [verdict review] is [review]'s verdict. *)

val verdict_freshness : t -> Verdict.freshness
(** [verdict_freshness review] is the verdict freshness against [review]'s
    current feature digest. *)

val cursor : t -> Cursor.t
(** [cursor review] is [review]'s cursor. *)

(** {2:review_facts Derived facts} *)

val files : t -> int
(** [files review] is the number of changed files. *)

val unit_scopes : t -> Scope.t list
(** [unit_scopes review] is [review]'s review units in canonical file order: one
    hunk scope per hunk of a {!Feature.File.Text} file, and one file scope per
    {!Feature.File.Opaque} file. *)

val file_unit_scopes : t -> path:Spice_path.Rel.t -> Scope.t list option
(** [file_unit_scopes review ~path] is [Some scopes] for [path]'s review units,
    using the same rule as {!unit_scopes}, or [None] when [path] is not in the
    feature. *)

val units : t -> int
(** [units review] is the number of review units: one per hunk of a
    {!Feature.File.Text} file and one per {!Feature.File.Opaque} file. *)

val reviewed_units : t -> int
(** [reviewed_units review] is the number of units whose effective mark is
    reviewed. *)

val open_crs : t -> int
(** [open_crs review] is the number of valid, unresolved CR occurrences. *)

val progress : t -> float
(** [progress review] is [reviewed_units / units] in [0.;1.], and [1.] when
    there are no units. *)

val is_complete : t -> bool
(** [is_complete review] is [true] iff every unit is reviewed. *)

(** {2:review_transforms Transforms} *)

val mark_reviewed : t -> Scope.t -> (t, Error.t) result
(** [mark_reviewed review scope] marks [scope] reviewed with evidence computed
    from current content. Errors with {!Error.Invalid_scope} if [scope] does not
    exist in the feature. Any existing mark on [scope] and marks inside [scope]
    are replaced by the new covering mark. *)

val mark_unreviewed : t -> Scope.t -> (t, Error.t) result
(** [mark_unreviewed review scope] marks [scope] unreviewed. Errors and covering
    behavior are as for {!mark_reviewed}. *)

val clear_mark : t -> Scope.t -> t
(** [clear_mark review scope] removes the explicit mark on exactly [scope], if
    any. *)

val approve : t -> t
(** [approve review] records approval of the current feature content. *)

val set_pending : t -> t
(** [set_pending review] returns the verdict to {!Verdict.Pending}. *)

val set_cursor : t -> Cursor.t -> (t, Error.t) result
(** [set_cursor review cursor] moves the cursor. Errors with
    {!Error.Invalid_cursor} if [cursor]'s target does not exist in [review]. *)

val move_cursor : ?wrap:bool -> t -> Cursor.move -> t
(** [move_cursor review move] moves the cursor along the canonical review order:
    the feature scope first, then per file in path order the file scope, its
    hunk scopes, and its CR occurrences, then occurrences in unchanged files in
    path order. Line scopes are valid cursor targets but not movement stops.
    [wrap] defaults to [false]; when the cursor cannot move it stays put. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have equal features, occurrence lists,
    marks, verdicts, and cursors. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf review] formats [review]'s summary for diagnostics. *)

(** {1:ops CR mutations} *)

module Op : sig
  (** CR mutations a review surface requests.

      An op names one pure {!Spice_cr} edit against a worktree file. The
      surface constructs ops; a performer applies the edit, writes the file,
      and reloads the snapshot. *)

  type t =
    | Add of { path : Spice_path.Rel.t; line : int; cr : Spice_cr.t }
        (** Request {!Spice_cr.add_before_line} for [cr] before one-based
            [line] of [path]. Performers may fail when [path] has no
            conventional comment syntax, [line] is outside the current file, or
            [cr] cannot be rendered in that syntax. *)
    | Replace of { occurrence : Spice_cr.Occurrence.t; cr : Spice_cr.t }
        (** Request {!Spice_cr.replace}: rewrite [occurrence] in place with
            [cr] using the occurrence's scanned syntax and stale-source check.
        *)
    | Remove of { occurrence : Spice_cr.Occurrence.t }
        (** Request {!Spice_cr.remove}: delete [occurrence] from its source
            file, removing whole comment lines when the occurrence is alone on
            them and only the raw occurrence span otherwise. *)

  val path : t -> Spice_path.Rel.t
  (** [path op] is the worktree-relative file [op] edits. *)
end

(** {1:live Live refresh protocol} *)

module Live : sig
  (** Pure state machine for keeping a review current.

      [Live] owns debounce deadlines, request identity, stale-result rejection,
      and the source-mutation guard. It interprets nothing: the host performs
      loads and writes and feeds results back as events. Fingerprints are opaque
      equality tokens supplied by the loader; time is supplied by the caller as
      monotonic seconds. *)

  type review = t
  (** The type for reviews, see {!Spice_review.t}. *)

  module Request : sig
    (** Request identity tokens. *)

    type t
    (** The type for request tokens. Every {!action-Sleep} and {!action-Load}
        carries the token that its completion event must echo; events with stale
        tokens are ignored. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same request. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf request] formats [request] for diagnostics. *)
  end

  type load = {
    feature : Feature.t;  (** The loaded feature snapshot. *)
    crs : Spice_cr.Occurrence.t list;
        (** CR occurrences scanned from the snapshot, in feature file order then
            source order. *)
    fingerprint : string;
        (** Opaque, process-local equality token for the loaded state. Never
            persist it. *)
  }
  (** The type for loader results feeding a refresh. A loader — such as
      {!Spice_review_git} — produces this; {!step} and {!mutation_loaded}
      consume it. *)

  type t
  (** The type for live review state. Holds the authoritative review. *)

  val make : ?debounce:float -> review:review -> fingerprint:string -> unit -> t
  (** [make ~review ~fingerprint ()] is live state over [review], whose snapshot
      the loader fingerprinted as [fingerprint]. [debounce] is the settle delay
      in seconds after a filesystem change and defaults to [0.5]. *)

  val review : t -> review
  (** [review live] is the current review. *)

  val fingerprint : t -> string option
  (** [fingerprint live] is the fingerprint of the loaded snapshot, or [None]
      while recovering from a failed reload. *)

  (** The type for host events. *)
  type event =
    | Fs_changed of { now : float }
        (** The watched tree changed at monotonic time [now]. *)
    | Tick of { now : float; request : Request.t }
        (** A requested {!action-Sleep} elapsed. *)
    | Loaded of Request.t * ([ `Unchanged | `Loaded of load ], string) result
        (** A requested {!action-Load} completed. *)
    | Review_changed of review
        (** The host applied a pure state change (mark, verdict, cursor) and
            this is the new review. *)

  (** The type for host actions. *)
  type action =
    | Sleep of { request : Request.t; seconds : float }
        (** Sleep [seconds], then feed {!event-Tick} with [request]. *)
    | Load of { request : Request.t; known : string option }
        (** Run the loader's load-if-changed against fingerprint [known] — or an
            unconditional load when [known] is [None] — then feed
            {!event-Loaded} with [request]. *)
    | Replace of review
        (** The review was replaced after a refresh; re-render and persist. *)
    | Error of string
        (** A reload failed; the previous review stays visible. *)

  val step : t -> event -> t * action list
  (** [step live event] applies [event]. Stale [Tick] and [Loaded] requests are
      ignored. Change bursts extend the debounce deadline; at most one load is
      in flight; changes arriving during a load schedule another cycle when it
      completes. *)

  (** {2:mutation Source-mutation guard}

      Comment actions edit source files whose occurrence spans must anchor into
      the loaded snapshot. The guard refuses to start a mutation over stale
      content and pauses watch-driven refreshes while one runs. *)

  val mutation_started :
    t -> fingerprint:string -> (t * Request.t, Error.t) result
  (** [mutation_started live ~fingerprint] locks the protocol for a source
      mutation. Errors with {!Error.Stale_snapshot} unless [fingerprint] equals
      the loaded one, and with {!Error.Busy} if a mutation is already running.
      Pending watch requests are cancelled. *)

  val mutation_aborted : t -> Request.t -> t
  (** [mutation_aborted live request] releases the guard without a result;
      watching resumes. *)

  val mutation_loaded :
    t ->
    Request.t ->
    (load, string) result ->
    t * [ `Replaced of review | `Stale | `Failed of string ]
  (** [mutation_loaded live request result] completes the mutation [request]. On
      [Ok load] the review is refreshed and returned as [`Replaced]; feed the
      replaced review back via {!event-Review_changed}. [`Stale] means [request]
      was superseded. On [Error _] the previous review stays and the loaded
      fingerprint is cleared so the next watch cycle recovers. *)
end

(** {1:persistence Persistence} *)

module Persist : sig
  (** Durable review-state projections.

      A record captures the user-authored review state — marks with their
      evidence, the verdict, the cursor — and none of the feature content.
      Restoring applies the same evidence rules as {!Spice_review.refresh}:
      records are validated against loaded content, never trusted. *)

  type review = t
  (** The type for reviews, see {!Spice_review.t}. *)

  type t
  (** The type for durable review-state records. *)

  val of_review : review -> t
  (** [of_review review] is the durable projection of [review]. *)

  val restore : t -> review -> review
  (** [restore record review] applies [record] to a freshly loaded [review].
      Marks whose scope and evidence no longer hold are dropped; the verdict
      keeps its recorded content digest, so approval of older content shows as
      stale; the cursor is validated and falls back as {!refresh} does. Records
      written against a different base label restore nothing. *)

  val jsont : t Jsont.t
  (** [jsont] is the JSON codec for records. The encoding is versioned;
      decoding an unsupported version fails rather than misreads. *)
end
