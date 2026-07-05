(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Successful live mutation evidence.

    A receipt is the common successful mutation shape for mutating tools that
    lower to {!Spice_edit}. It records what was actually applied and optional
    semantic grouping supplied by the tool adapter.

    A receipt is live tool evidence, not a durable fact: it is never persisted,
    carries no session/turn/id, and is keyed on absolute workspace paths. Tools
    produce it; the host lowers it to durable [Spice_mutation.Change] facts, and
    products render it — all through the single {!changes} eliminator. *)

module Logical_change : sig
  (** Tool-level semantic change grouping.

      [Move] is semantic metadata for products and history. The underlying edit
      result still records concrete filesystem changes, usually
      delete-plus-create. *)

  type kind =
    | Create
    | Modify
    | Delete
    | Move of { from : Spice_workspace.Path.t }
        (** Semantic change kind. [Move] records a source path while the applied
            edit evidence may still contain separate delete/create entries. *)

  type t = {
    path : Spice_workspace.Path.t;
        (** Output path for this semantic change. For [Move], this is the
            destination. *)
    kind : kind;  (** Tool-level semantic grouping for [path]. *)
    diff : string option;
        (** Display diff for this semantic change, if the tool produced one.
            Diffs are evidence for humans and products, not replay formats. *)
  }
  (** The type for one semantic mutation described by a successful tool. *)

  val source_path : t -> Spice_workspace.Path.t option
  (** [source_path t] is the source path for [Move] changes and [None] for
      create, modify, and delete changes. *)
end

type t
(** The type for successful mutation evidence retained by tools. *)

type op =
  | Create
  | Modify
  | Delete
  | Move of { from : Spice_workspace.Path.t }
      (** Display operation for one applied change. [Move] carries an absolute
          workspace source path; raw edit entries never produce [Move]. *)

type change = {
  path : Spice_workspace.Path.t;
      (** The path this change applied to. For [Move], the destination. *)
  op : op;  (** The display operation. *)
  before : Spice_edit.Observed.t;
      (** The path's observed state before the change. For a logical change it
          is the applied result entry looked up by path ([Missing] when absent);
          for a raw edit entry it is the entry's before state. *)
  after : Spice_edit.Observed.t;
      (** The path's observed state after the change, looked up as {!before}. *)
  diff : string option;
      (** The tool-supplied display diff for a logical change, or [None] for a
          raw edit entry. Consumers needing line counts for a raw entry
          recompute them from {!before} and {!after}. *)
}
(** One normalized applied change: the reconciliation of raw edit entries with
    the tool's optional semantic grouping that every receipt consumer needs. *)

val make : ?logical_changes:Logical_change.t list -> Spice_edit.Result.t -> t
(** [make ?logical_changes result] is a mutation receipt for [result].

    [logical_changes] defaults to [[]] and should be supplied only when a tool
    has a semantic grouping that differs from raw edit entries, such as patch
    moves. *)

val empty : t
(** [empty] is the receipt for a successful no-op mutation. *)

val is_empty : t -> bool
(** [is_empty t] is [true] iff [t] contains no applied edit entries. *)

val changes : t -> change list
(** [changes t] is the normalized applied changes of [t] in mutation order.

    When [t] carries logical changes, each yields one {!type-change}: [before]
    and [after] are the applied result entries looked up by path ([Missing] when
    a path has no entry) and [diff] is the tool-supplied diff. Otherwise each
    raw edit entry yields one {!type-change} with its before/after states and no
    diff. This is the single reconciliation every consumer shares. *)

val paths : t -> Spice_workspace.Path.t list
(** [paths t] are the concrete revalidated target paths applied by [t], in
    mutation order. *)
