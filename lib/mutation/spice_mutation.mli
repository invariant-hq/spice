(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable host-owned workspace mutation facts.

    [Spice_mutation] defines the facts a host records about Spice-authored
    workspace mutations — {!Checkpoint}, file-level {!Change}, and {!Revert}
    facts — plus the pure combinators products use over them: {!Scope}
    selection, move-expanded endpoint netting ({!Change.net}), and revert
    planning ({!Revert.plan} and {!Revert.lower}).

    Those facts are inert data correlated with session, turn, and tool claim
    identifiers. Storage, checkpoint backends, blob resolution, and filesystem
    IO belong to host layers. Paths are workspace-relative; the workspace root
    is recorded on checkpoint facts. Live tool evidence lowered into {!Change}
    facts is [Spice_tools.Receipt], produced by tools rather than owned here.
    Images are content-addressed: rows carry identities and sizes, and the bytes
    live in a host blob store.

    [Spice_mutation] is not a session event vocabulary: facts must never be
    added to [Spice_session.Event]. It is also not a checkpoint service, revert
    engine, or ledger; it only describes and plans. *)

(** {1:images Images} *)

module Image : sig
  (** Durable file images.

      An image is the recorded state of one path at one moment. [Text] carries
      an identity and byte size; the contents live in the host blob store keyed
      by that identity. *)

  type t =
    | Missing  (** No file existed at the path. *)
    | Text of { identity : Spice_digest.Identity.t; size : int }
        (** A regular UTF-8 text file with content-addressed bytes. *)
    | Unsupported of { reason : string }
        (** A target that cannot be recorded as a text image. [reason] is a
            non-empty human-readable diagnostic. *)

  val of_target : Spice_edit.Observed.t -> t
  (** [of_target target] is the durable projection of a live read: text contents
      become an identity and size, [Other] becomes [Unsupported]. This is the
      only bridge between read-boundary states and recorded images. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same image. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps images to JSON objects. *)
end

(** {1:checkpoints Checkpoints} *)

module Checkpoint : sig
  (** Durable workspace snapshot facts.

      A checkpoint records that a backend captured (or failed to capture) the
      workspace root at a host-chosen boundary. The [reference] inside
      {!type-status} is an opaque backend value, such as a private git tree
      hash. *)

  module Id : sig
    type t
    (** The type for stable checkpoint identifiers.

        Invariant: an identifier's stable textual form is non-empty. *)

    val of_string : string -> t
    (** [of_string s] is [s] as a checkpoint id.

        Raises [Invalid_argument] if [s] is empty. *)

    val to_string : t -> string
    (** [to_string id] is [id]'s stable string representation. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same id. *)

    val compare : t -> t -> int
    (** [compare a b] orders ids by their stable string representations. *)

    val pp : Format.formatter -> t -> unit
    (** [pp] formats an id for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps ids to JSON strings, validating non-emptiness. *)
  end

  type reason =
    | Before_mutation
        (** Lazy capture before the first potentially mutating tool of a run. *)
    | Run_end
        (** Capture when a turn that ran shell finishes; bounds shell
            attribution to the run window. *)
    | Before_revert  (** Capture before applying a revert. *)
    | Manual  (** Host- or user-requested capture. *)

  type status =
    | Available of { backend : string; reference : string; excluded : int }
        (** The snapshot exists. [backend] names the implementation and
            [reference] is its opaque snapshot reference. [excluded] is reserved
            for the count of workspace files left out of the snapshot (ignored
            or oversized); no current backend computes it, so it is always [0].
        *)
    | Degraded of { backend : string; message : string }
        (** A backend was present but capture failed. [message] is a non-empty
            human-readable diagnostic. *)

  type t
  (** The type for checkpoint facts. *)

  val make :
    id:Id.t ->
    session:Spice_session.Id.t ->
    turn:Spice_session.Turn.Id.t ->
    root:string ->
    reason:reason ->
    status:status ->
    t
  (** [make ~id ~session ~turn ~root ~reason ~status] is a checkpoint fact.

      [root] is the captured workspace root as an absolute path string; it is
      display and audit data, not a path authority. *)

  val derive_id :
    session:Spice_session.Id.t ->
    turn:Spice_session.Turn.Id.t ->
    reason:reason ->
    Id.t
  (** [derive_id ~session ~turn ~reason] is the deterministic id for the
      checkpoint captured for [reason] in [turn]. [Before_mutation] and
      [Run_end] occur at most once per turn; deriving two ids for the same
      triple yields the same id. *)

  val id : t -> Id.t
  (** [id t] is [t]'s checkpoint id. *)

  val session : t -> Spice_session.Id.t
  (** [session t] is the session [t] belongs to. *)

  val turn : t -> Spice_session.Turn.Id.t
  (** [turn t] is the turn [t] was captured in. *)

  val root : t -> string
  (** [root t] is [t]'s captured workspace root as an absolute path string. *)

  val reason : t -> reason
  (** [reason t] is why [t] was captured. *)

  val status : t -> status
  (** [status t] is [t]'s capture status. *)

  val available_id : t -> Id.t option
  (** [available_id t] is [Some (id t)] if [t]'s status is {!Available} and
      [None] if it is {!Degraded}. A degraded checkpoint captured no snapshot,
      so it cannot serve as a revert base or be named by a later change fact. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same fact. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps checkpoint facts to JSON objects. *)
end

(** {1:revert_ids Revert identifiers} *)

module Revert_id : sig
  type t
  (** The type for stable revert identifiers.

      Defined before {!Change} because change rows written by a revert name the
      revert as their source. *)

  val of_string : string -> t
  (** [of_string s] is [s] as a revert id.

      Raises [Invalid_argument] if [s] is empty. *)

  val to_string : t -> string
  (** [to_string id] is [id]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representations. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf id] formats [id] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps ids to JSON strings, validating non-emptiness. *)
end

(** {1:changes Changes} *)

module Change : sig
  (** Durable file-level mutation facts.

      A change records one applied mutation, usually derived from typed tool
      evidence. It is distinct from a [Spice_edit] plan, which is a planned
      edit: a mutation fact describes what happened, with content-addressed
      before/after images. *)

  module Id : sig
    type t
    (** The type for stable change identifiers. *)

    val of_string : string -> t
    (** [of_string s] is [s] as a change id.

        Raises [Invalid_argument] if [s] is empty. *)

    val to_string : t -> string
    (** [to_string id] is [id]'s stable string representation. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same id. *)

    val compare : t -> t -> int
    (** [compare a b] orders ids by their stable string representations. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf id] formats [id] for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps ids to JSON strings, validating non-emptiness. *)
  end

  type op =
    | Create
    | Modify
    | Delete
    | Move of { from : Spice_path.Rel.t }
        (** Semantic operation. [Move] preserves the source path even when the
            mutation lowered to delete-plus-create. *)

  type source =
    | Tool of {
        execution : Spice_session.Tool_claim.Id.t;
        call_id : string;
        tool : string;
      }  (** Derived from typed tool evidence. *)
    | Revert of Revert_id.t  (** Written by a revert application. *)

  type revertability =
    | Revertable
    | Not_revertable of string
        (** [Not_revertable reason] carries a non-empty human-readable degraded
            reason (oversized, non-text). *)

  type t
  (** The type for change facts. *)

  val make :
    ?checkpoint:Checkpoint.Id.t ->
    id:Id.t ->
    session:Spice_session.Id.t ->
    turn:Spice_session.Turn.Id.t ->
    source:source ->
    path:Spice_path.Rel.t ->
    op:op ->
    before:Image.t ->
    after:Image.t ->
    additions:int ->
    deletions:int ->
    revertability:revertability ->
    unit ->
    t
  (** [make ~id ~session ~turn ~source ~path ~op ~before ~after ~additions
       ~deletions ~revertability ()] is a change fact.

      For [Move], [before] is the source file's image and [after] is the
      destination file's image. [additions] and [deletions] are line counts
      computed at recording time, while the typed evidence still holds both
      texts in memory. [checkpoint], when present, names the run checkpoint that
      preceded this change.

      Raises [Invalid_argument] if [additions] or [deletions] is negative. *)

  val derive_id :
    execution:Spice_session.Tool_claim.Id.t ->
    path:Spice_path.Rel.t ->
    index:int ->
    Id.t
  (** [derive_id ~execution ~path ~index] is the deterministic id for the
      [index]-th change row recorded for [path] by [execution]. *)

  val id : t -> Id.t
  (** [id t] is [t]'s change id. *)

  val session : t -> Spice_session.Id.t
  (** [session t] is the session [t] belongs to. *)

  val turn : t -> Spice_session.Turn.Id.t
  (** [turn t] is the turn [t] was recorded in. *)

  val source : t -> source
  (** [source t] is what recorded [t]: typed tool evidence or a revert. *)

  val path : t -> Spice_path.Rel.t
  (** [path t] is the path [t] mutated. For [Move] it is the destination. *)

  val op : t -> op
  (** [op t] is [t]'s semantic operation. *)

  val before : t -> Image.t
  (** [before t] is the path's image before [t]. For [Move] it is the source
      file's image. *)

  val after : t -> Image.t
  (** [after t] is the path's image after [t]. For [Move] it is the destination
      file's image. *)

  val additions : t -> int
  (** [additions t] is [t]'s recorded added line count. *)

  val deletions : t -> int
  (** [deletions t] is [t]'s recorded deleted line count. *)

  val checkpoint : t -> Checkpoint.Id.t option
  (** [checkpoint t] is the run checkpoint that preceded [t], if any. *)

  val revertability : t -> revertability
  (** [revertability t] is whether [t] can be reverted. *)

  type totals = { files : int; total_additions : int; total_deletions : int }
  (** Aggregate counts over change rows. *)

  val totals : t list -> totals
  (** [totals changes] sums recorded row counts: [files] counts distinct row
      paths and [additions]/[deletions] sum the recorded line counts. Used for
      run-cumulative trailers; netted display stats are recomputed from blobs at
      render time. *)

  (** Netted per-path endpoints. *)
  module Net : sig
    type entry = private {
      path : Spice_path.Rel.t;
      before : Image.t;  (** First observed image for [path]. *)
      after : Image.t;  (** Last observed image for [path]. *)
      contiguous : bool;
          (** [false] iff some delta's before did not match the previous delta's
              after: evidence of unrecorded interleaved mutation. Display
              honesty only; revert safety comes from plan-time identity checks.
          *)
      sources : Id.t list;  (** Contributing change rows in observation order. *)
    }

    type t = entry list
    (** Entries in first-seen path order. *)
  end

  val net : t list -> Net.t
  (** [net changes] is the move-expanded endpoint netting of [changes] in list
      order. Each row expands to per-path deltas — [Create p] to
      [(p, Missing, after)]; [Modify p] to [(p, before, after)]; [Delete p] to
      [(p, before, Missing)]; [Move {from} p] to [(from, before, Missing)] and
      [(p, Missing, after)] — then deltas are grouped by path in first-seen
      order and folded to endpoints: net before is the first delta's before, net
      after is the last delta's after. Paths whose endpoint images are equal are
      dropped.

      Netting is total: surprising sequences (create-then-move,
      move-then-recreate-source, move chains) cannot fail because moves are
      expanded before folding. Move pairing is a display concern; revert never
      depends on it. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same fact. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps change facts to JSON objects. *)
end

(** {1:scopes Scopes} *)

module Scope : sig
  (** Product selections over recorded change facts. *)

  type t =
    | Session  (** Every change in the session ledger. *)
    | Turn of Spice_session.Turn.Id.t  (** Changes recorded by one turn. *)
    | Turns of Spice_session.Turn.Id.t list
        (** Changes recorded by any turn in the set, in ledger order. Selects
            the rows attributable to a group of turns — for instance the turns a
            rewind drops (see {!Spice_session.dropped_turns}) — so a rewind's
            paired filesystem revert can plan over exactly those rows and record
            the reverted turns precisely. [Turns []] selects nothing. *)
    | Change of Change.Id.t  (** One change row. *)
    | Path of Spice_path.Rel.t
        (** Changes that touched one path, including moves whose source is that
            path. *)

  val select : t -> Change.t list -> Change.t list
  (** [select t changes] is the subsequence of [changes] in [t], preserving
      order. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same scope. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps scopes to JSON objects. *)
end

(** {1:reverts Reverts} *)

module Revert : sig
  (** Revert planning and durable revert facts.

      Planning is pure and conservative: it nets the scoped changes, reads the
      current state of every netted path exactly once, and refuses to plan over
      anything it cannot prove. Lowering produces a single [Spice_edit.t] whose
      preconditions are the texts read at plan time, so [Spice_edit.apply]
      re-rejects races at write time. *)

  type stale = {
    stale_path : Spice_path.Rel.t;
    expected : Image.t;  (** The net after image revert requires. *)
    actual : Image.t;  (** The image observed at plan time. *)
  }
  (** A path whose current state no longer matches the recorded outcome. *)

  type refusal = { refusal_path : Spice_path.Rel.t; reason : string }
  (** A path revert refuses to touch. [reason] is non-empty. *)

  type problem = Stale of stale | Refused of refusal

  type ready = private {
    ready_path : Spice_path.Rel.t;
    current : string option;
        (** The exact present text read at plan time; [None] when the path is
            currently missing. Used as the [Spice_edit] precondition. *)
    restore : Image.t;  (** The net before image to restore. *)
    sources : Change.Id.t list;  (** Change rows this path revert covers. *)
  }
  (** One plannable path revert. *)

  type plan = private { ready : ready list; problems : problem list }
  (** The type for revert plans. A plan never mutates anything. *)

  val plan :
    read:(Spice_path.Rel.t -> Spice_edit.Observed.t) ->
    scope:Scope.t ->
    Change.t list ->
    plan
  (** [plan ~read ~scope changes] selects and nets [changes] under [scope],
      reads each netted path once with [read], and compares [Image.of_target] of
      the current state against the net after image. Matching paths are ready;
      mismatches are {!Stale}; [Unsupported] images on either side are
      {!Refused}. [read] is a function, not an IO record; callers supply a
      workspace reader. *)

  val lower :
    plan ->
    resolve:(Spice_path.Rel.t -> (Spice_workspace.Path.t, string) result) ->
    blob:(Spice_digest.Identity.t -> string option) ->
    (Spice_edit.t, problem list) result
  (** [lower plan ~resolve ~blob] is the all-or-nothing edit plan for [plan].

      Any plan problem refuses the whole lowering. [resolve] maps recorded
      workspace-relative paths into the caller's workspace; [blob] resolves net
      before images from the host blob store. A resolution failure and a missing
      or corrupt blob each refuse the whole revert because evidence is
      incomplete. A ready path whose images are (text, text) lowers to a rewrite
      back to the net before text; (missing, text) — the run created the file —
      lowers to a delete; (text, missing) — the run deleted it — lowers to a
      create. *)

  type applied = {
    applied_path : Spice_path.Rel.t;
    applied_sources : Change.Id.t list;
  }
  (** One applied path of a revert: [applied_path] was restored, covering the
      change rows in [applied_sources]. Reverts are all-or-nothing ({!lower}),
      so a persisted revert only records applied paths; plan-time problems
      ({!Stale}, {!Refused}) are reported to the caller and never durable. *)

  type t
  (** The type for durable revert facts. *)

  val make :
    ?pre_revert:Checkpoint.Id.t ->
    id:Revert_id.t ->
    session:Spice_session.Id.t ->
    scope:Scope.t ->
    applied:applied list ->
    unit ->
    t
  (** [make ~id ~session ~scope ~applied ()] is a revert fact recording the
      paths a successful revert restored. [pre_revert] names the checkpoint
      captured before applying, when a backend was available. *)

  val derive_id :
    session:Spice_session.Id.t -> scope:Scope.t -> ordinal:int -> Revert_id.t
  (** [derive_id ~session ~scope ~ordinal] is the deterministic id for the
      [ordinal]-th revert of [scope] in [session]. *)

  val id : t -> Revert_id.t
  (** [id t] is [t]'s revert id. *)

  val session : t -> Spice_session.Id.t
  (** [session t] is the session [t] belongs to. *)

  val scope : t -> Scope.t
  (** [scope t] is the scope [t] reverted. *)

  val pre_revert : t -> Checkpoint.Id.t option
  (** [pre_revert t] is the checkpoint captured before applying [t], if a
      backend was available. *)

  val applied : t -> applied list
  (** [applied t] is the paths [t] restored, in application order. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same fact. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps revert facts to JSON objects. *)
end

(** {1:records Ledger records} *)

module Record : sig
  (** One ledger line. Hosts append records in observation order and read them
      back as a list. *)

  type t =
    | Checkpoint of Checkpoint.t
    | Change of Change.t
    | Revert of Revert.t

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same record. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps records to JSON objects with a [type] discriminator. *)
end

val changes : Record.t list -> Change.t list
(** [changes records] is the change facts in [records], in order. *)

val checkpoints : Record.t list -> Checkpoint.t list
(** [checkpoints records] is the checkpoint facts in [records], in order. *)

val find_checkpoint : Record.t list -> Checkpoint.Id.t -> Checkpoint.t option
(** [find_checkpoint records id] is the checkpoint fact in [records] whose id is
    [id], or [None] if no checkpoint in [records] has that id. *)

val reverts : Record.t list -> Revert.t list
(** [reverts records] is the revert facts in [records], in order. *)
