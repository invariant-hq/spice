(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Semantic OCaml references through Merlin occurrences.

    [ocaml_find_references] asks Merlin for identity-based occurrences of the
    OCaml entity at a source position. It intentionally has no textual grep
    fallback: when Merlin cannot resolve the entity or its project index is
    unavailable, the tool reports that condition instead of returning
    shadowing-prone text matches. Merlin's CLI does not expose index freshness
    for project and renaming scopes, so those results carry
    {!Output.index_status} [Unknown]. *)

val name : string
(** Stable tool name, ["ocaml_find_references"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_limit : int
(** Default maximum number of references returned by {!run}. *)

val max_limit : int
(** Maximum accepted explicit reference limit. *)

val default_program : string list
(** Default Merlin invocation prefix, [["ocamlmerlin"]]. *)

module Scope : sig
  (** Merlin occurrence search scopes. *)

  type t =
    | Buffer
    | Project
    | Renaming
        (** The type for occurrence scopes. [Buffer] searches the current file
            only; [Project] and [Renaming] consult Merlin/Dune project
            occurrence indexes. *)

  val to_string : t -> string
  (** [to_string t] is the Merlin scope name for [t], one of ["buffer"],
      ["project"], or ["renaming"]. *)

  val of_string : string -> t option
  (** [of_string s] is [Some t] if [s] is a scope name and [None] otherwise. *)

  val compare : t -> t -> int
  (** [compare a b] is a total order on scopes. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same scope. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

module Input : sig
  (** Typed find-references requests over a source position. *)

  type t
  (** Typed find-references request.

      The query is deliberately position-based. A bare name is ambiguous in
      OCaml because of shadowing, opened modules, labels, constructors, and
      generated code; callers that only have a name should first locate a
      concrete file position. *)

  val make :
    ?scope:Scope.t ->
    ?include_stale:bool ->
    ?offset:int ->
    ?limit:int ->
    path:string ->
    line:int ->
    column:int ->
    unit ->
    t
  (** [make ~path ~line ~column ()] searches references to the entity at
      [line]:[column] in [path].

      [path] is workspace-relative or a workspace-contained absolute path.
      [line] is 1-based and [column] is a 0-based byte column. [scope] defaults
      to {!Scope.Project}. [include_stale] defaults to [false]. [offset] is the
      1-based index of the first returned reference within the fresh result set
      and defaults to [1]. [limit] defaults to {!default_limit}.

      Raises [Invalid_argument] if [path] is empty, [line < 1], [column < 0],
      [offset < 1], [limit < 1], or [limit > max_limit]. *)

  val path : t -> string
  (** [path t] is the requested source-file path string. *)

  val position : t -> Spice_ocaml.Position.t
  (** [position t] is the cursor position of the query. *)

  val scope : t -> Scope.t
  (** [scope t] is the requested occurrence scope. *)

  val include_stale : t -> bool
  (** [include_stale t] is [true] when stale occurrences are kept in the result.
  *)

  val offset : t -> int option
  (** [offset t] is the requested 1-based start index, if any. [None] means the
      first page. *)

  val limit : t -> int
  (** [limit t] is the maximum number of references to return. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls. Unknown fields are
      rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}. *)
end

module Reference : sig
  (** Individual reference occurrences. *)

  type t
  (** The type for a single occurrence: a source location with a staleness flag.
  *)

  val make : location:Spice_ocaml.Location.t -> stale:bool -> t
  (** [make ~location ~stale] is a reference at [location]. [stale] is [true]
      when Merlin flagged the occurrence as coming from an out-of-date index. *)

  val location : t -> Spice_ocaml.Location.t
  (** [location t] is the source location of the occurrence. *)

  val stale : t -> bool
  (** [stale t] is [true] iff Merlin reported the occurrence as stale. *)

  val compare : t -> t -> int
  (** [compare a b] is a total order on references, by location then staleness.
  *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are equal. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

module Output : sig
  (** Typed find-references output and its model-visible projection. *)

  type index_status =
    | Not_applicable
    | Unknown
        (** Occurrence-index freshness precision. [Not_applicable] is reported
            for buffer-scope queries that consult no project index; [Unknown] is
            reported for project and renaming scopes because Merlin's CLI does
            not expose index freshness. *)

  type status =
    | Complete
    | Partial
        (** Completion of the paged reference window. [Partial] means more
            references remain in the fresh result set beyond this page; the
            continuation request is {!next}. *)

  type t
  (** Typed find-references evidence retained by completed tool calls. *)

  val query : t -> Input.t
  (** [query t] is the request that produced [t]. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path that was searched. *)

  val references : t -> Reference.t list
  (** [references t] are the returned occurrences for this page, sorted by
      location, after stale filtering and [offset]/[limit] windowing. *)

  val returned_count : t -> int
  (** [returned_count t] is the number of references in {!references}. *)

  val total_count : t -> int
  (** [total_count t] is the number of occurrences Merlin reported before stale
      filtering and windowing. *)

  val stale_skipped : t -> int
  (** [stale_skipped t] is the number of stale occurrences dropped when
      [include_stale] is [false]. *)

  val offset : t -> int
  (** [offset t] is the 1-based index of this page's first reference within the
      fresh result set. *)

  val status : t -> status
  (** [status t] is {!Complete} when this page reached the end of the fresh
      result set and {!Partial} otherwise. *)

  val next : t -> Input.t option
  (** [next t] is the continuation request that resumes after this page, or
      [None] when {!status} is {!Complete}. *)

  val has_more : t -> bool
  (** [has_more t] is [true] iff {!status} is {!Partial}. *)

  val index_status : t -> index_status
  (** [index_status t] is the freshness precision for [t]'s scope. *)

  val backend : t -> string
  (** [backend t] is the resolver backend name, ["ocamlmerlin"]. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool. *)
end

val permissions :
  ?program:string list ->
  workspace:Spice_workspace.t ->
  Input.t ->
  Spice_permission.Request.t list
(** [permissions ~workspace input] are the workspace-root read, source-file
    read, and Merlin execution permissions required to run [input]. [program] is
    the [ocamlmerlin] invocation prefix and defaults to {!default_program}.
    Returns [[]] if [input]'s path cannot be resolved. *)

val run :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  Spice_tool.Context.t ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace ctx input] reads [input]'s source file, runs
    [ocamlmerlin occurrences] from the workspace root with that source on
    standard input, and returns the matching references.

    Stale occurrences are dropped unless [include_stale] is set, results are
    sorted, and the [offset]/[limit] window is returned as a page with a
    {!Output.next} continuation when more remain. Typed output records the
    pre-filter total. The result is interrupted if [ctx] is cancelled, failed as
    [`Not_found] when the source cannot be read, failed as [`Unavailable] when
    Merlin cannot be started, and failed as [`Failed] for malformed Merlin
    output or other command failures. [program] defaults to {!default_program}.
*)

val tool :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ()] is the erased model-facing tool for {!run}. *)
