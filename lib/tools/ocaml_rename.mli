(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Semantic rename of an OCaml binding through Merlin occurrences.

    [ocaml_rename] resolves the entity at a source position with
    [ocamlmerlin occurrences -scope renaming], verifies every occurrence range
    against the current source, and lowers the whole set to one atomic
    multi-file {!Spice_edit.t}. Like {!Ocaml_find_references} it has no textual
    fallback: when Merlin cannot resolve the entity, the index looks stale, or a
    range no longer holds the old name, the tool refuses rather than produce a
    partial or shadowing-prone rename. Merlin's CLI does not expose index
    freshness for renaming scope, so results carry an [Unknown] index status. *)

val name : string
(** Stable tool name, ["ocaml_rename"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_program : string list
(** Default Merlin invocation prefix, [["ocamlmerlin"]]. The invocation is a
    prefix, not a bare program name, so a toolchain that exposes Merlin only via
    [dune tools exec ocamlmerlin --] is supported (see {!Ocaml_merlin}). *)

val default_max_occurrences : int
(** Default upper bound on occurrences a single rename may rewrite. Must be
    [<= Ocaml_find_references.max_limit] (1000): the bound is passed through as
    the internal find-references [limit], which raises above [max_limit]. *)

val default_max_bytes : int
(** Default maximum size of any single edited file. *)

module Input : sig
  (** Typed rename requests over a source position.

      The query is position-based for the same reason as
      {!Ocaml_find_references.Input}: a bare name is ambiguous under shadowing,
      opened modules, labels, and generated code. *)

  type t

  val make :
    path:string ->
    line:int ->
    column:int ->
    new_name:string ->
    ?dry_run:bool ->
    ?max_occurrences:int ->
    unit ->
    t
  (** [make ~path ~line ~column ~new_name ()] renames the entity at
      [line]:[column] in [path] to [new_name].

      [path] is workspace-relative or a workspace-contained absolute path.
      [line] is 1-based and [column] is a 0-based byte column. [dry_run]
      defaults to [false] and applies the rename; [true] plans it without
      writing. [max_occurrences] defaults to {!default_max_occurrences}.

      Raises [Invalid_argument] if [path] or [new_name] is empty, [line < 1],
      [column < 0], or [max_occurrences] is outside
      [1 .. Ocaml_find_references .max_limit] (the internal find-references
      [limit] ceiling; a larger value would otherwise raise mid-run). New-name
      lexical validation happens in {!run}, against the entity actually under
      the cursor. *)

  val path : t -> string
  val position : t -> Spice_ocaml.Position.t
  val new_name : t -> string
  val dry_run : t -> bool
  val max_occurrences : t -> int

  val contract : t Spice_tool.Input.t
  (** JSON input contract. Unknown fields are rejected. *)

  val decode : Jsont.json -> (t, string) result
end

module Target : sig
  (** Per-file rename evidence: the file and what changes in it. *)

  type t

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path of the edited file. *)

  val occurrences : t -> int
  (** [occurrences t] is the number of ranges rewritten in [path]. *)

  val before_identity : t -> Spice_digest.Identity.t
  (** [before_identity t] is the identity of [path] observed during planning. *)

  val after_identity : t -> Spice_digest.Identity.t
  (** [after_identity t] is the identity of the renamed [path]. For a dry run
      this is the identity the rewrite would produce. *)

  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Plan : sig
  (** A validated, not-yet-written rename over one or more files. *)

  type t

  val old_name : t -> string
  (** [old_name t] is the identifier as it appears in the source. *)

  val new_name : t -> string
  (** [new_name t] is the replacement identifier. *)

  val targets : t -> Target.t list
  (** [targets t] is one entry per edited file, sorted by path. *)

  val total_occurrences : t -> int
  (** [total_occurrences t] is the sum of {!Target.occurrences} over all files.
  *)

  val edit : t -> Spice_edit.t
  (** [edit t] is the combined stale-safe multi-file rewrite plan. *)
end

module Output : sig
  (** Typed rename output and its model-visible projection. *)

  type index_status =
    | Unknown
        (** Renaming scope never exposes index freshness; always [Unknown]. *)

  type t

  val query : t -> Input.t
  (** [query t] is the request that produced [t]. *)

  val plan : t -> Plan.t
  (** [plan t] is the validated rename that was reported or applied. *)

  val applied : t -> bool
  (** [applied t] is [true] iff files were written ([dry_run] was [false]). *)

  val receipt : t -> Receipt.t
  (** [receipt t] is the successful mutation receipt over every rewritten file,
      built with {!Receipt.make} from the combined {!Spice_edit.Result.t}. It is
      {!Receipt.empty} for a dry run. A mid-commit IO fault does not produce an
      {!Output.t} at all (the call fails); no partial receipt can be
      constructed, because a failed {!Spice_edit.apply} yields
      {!Spice_edit.Apply_error.t}, which has no conversion to
      {!Spice_edit.Result.t}. *)

  val index_status : t -> index_status
  (** [index_status t] is the freshness precision, always [Unknown]. *)

  val backend : t -> string
  (** [backend t] is the resolver backend name, ["ocamlmerlin"]. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed output to compact model-visible text and JSON: old
      and new names, per-file occurrence counts, final identities, applied flag,
      and index status. It does not echo full file contents. *)

  val of_tool_output : Spice_tool.Output.t -> t option
end

val permissions :
  workspace:Spice_workspace.t ->
  Input.t ->
  Spice_permission.Request.t list
(** [permissions ~workspace input] are the permissions required to run [input].

    The preliminary plan requires workspace-root and source-file reads. Exact
    per-file modify facts are derived from the prepared plan before mutation.
    Returns [[]] if [input]'s source path cannot be resolved. *)

val run :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  Spice_tool.Context.t ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace ctx input] resolves occurrences with
    {!Ocaml_find_references.run} at renaming scope, validates [new_name] against
    the entity under the cursor, verifies every occurrence range still holds the
    old name, plans a single multi-file {!Spice_edit.t}, and (unless [dry_run])
    applies it atomically through {!Spice_edit.apply}.

    Fails as [`Unavailable] when Merlin cannot start, [`Not_found] when the
    source file cannot be read (re-mapped from {!Ocaml_find_references}, which
    never returns [`Invalid_input]), [`Invalid_input] for an empty occurrence
    set (a {e completed} find-references result the tool re-classifies), an
    invalid new name, or a site the local parse cannot corroborate, [`Stale]
    when the index is stale or a range no longer holds the old name or a file
    changed since planning, and [`Failed] when the occurrence count exceeds the
    cap or an IO fault leaves a partial write (no receipt in that case).
    Interrupted if [ctx] is cancelled. [program] defaults to {!default_program}.
*)

val tool :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ()] is the erased model-facing tool for {!run}. *)
