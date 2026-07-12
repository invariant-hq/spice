(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Syntactic structural search over workspace OCaml sources.

    [Ocaml_search_expressions] matches an OCaml expression pattern against the
    parse trees of workspace [.ml] files through {!Spice_ocaml_grep}. Matching
    is syntactic — identifiers are compared as written, not as resolved — and
    needs no build artifacts: sources are parsed directly, so the tool works on
    unbuilt and mid-refactor code. Files that cannot be parsed are reported as
    skipped coverage evidence, never silently dropped. *)

val name : string
(** Stable tool name, ["ocaml_search_expressions"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_limit : int
(** Default maximum number of findings returned by {!run}. *)

val max_limit : int
(** Maximum accepted explicit finding limit. *)

val max_source_bytes : int
(** Maximum size of a source file searched by {!run}. Larger files are skipped
    and reported. *)

(** {1 Input} *)

module Input : sig
  type t
  (** Typed structural-search request. *)

  val make : ?paths:string list -> ?offset:int -> ?limit:int -> string -> t
  (** [make pattern] searches for the OCaml expression pattern [pattern].

      [pattern] is one complete, non-empty OCaml expression in
      {!Spice_ocaml_grep.Pattern} syntax; wildcards replace expressions but do
      not relax the surrounding OCaml grammar. It is parsed and validated at
      execution time. [paths] are workspace-relative or workspace-contained
      absolute files or directories; absent [paths] means the workspace root.
      [offset] is the one-based first finding to return and defaults to [1] at
      execution time. [limit] is the maximum number of findings and defaults to
      {!default_limit} at execution time.

      Raises [Invalid_argument] if [pattern] is empty or contains NUL, any path
      is empty or contains NUL, [paths] is explicitly empty, [offset < 1],
      [limit < 1], or [limit > max_limit]. *)

  val pattern : t -> string
  (** [pattern t] is the requested expression pattern. *)

  val paths : t -> string list option
  (** [paths t] are the requested search roots, or [None] for the workspace
      root. *)

  val offset : t -> int option
  (** [offset t] is the requested one-based first finding, if given. *)

  val limit : t -> int option
  (** [limit t] is the requested maximum number of findings, if given. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls. Unknown fields are
      rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}. *)
end

(** {1 Output} *)

module Output : sig
  type partial_reason =
    | Limit  (** Why a page is partial: the finding limit. *)

  type status =
    | Complete
    | Partial of partial_reason
        (** Page coverage status for the finding stream. *)

  type skipped_reason =
    | Binary
    | Invalid_utf8
    | Too_large
    | Syntax_error of string
    | Read_error of string
        (** Why a candidate [.ml] file contributed no findings.

            [Syntax_error] carries the parser diagnostic: structural search
            cannot see into a file that does not parse. [Read_error] carries a
            filesystem diagnostic for files that disappeared or became
            unreadable between enumeration and reading. *)

  type skipped = private {
    skipped_path : Spice_workspace.Path.t;
    reason : skipped_reason;
  }
  (** One candidate file that was not searched and why. *)

  type line = private {
    number : int;
    text : string;
    truncated : bool;
    anchor : Anchor.t option;
  }
  (** One source line of a finding. [number] is one-based. [text] is valid UTF-8
      and may be a bounded prefix of the source line when [truncated] is [true].
  *)

  type finding = private {
    location : Spice_ocaml.Location.t;
    lines : line list;
  }
  (** One structural match: its precise location and the full source lines it
      spans. [lines] is non-empty. *)

  type t
  (** Typed structural-search observation. *)

  val pattern : t -> string
  (** [pattern t] is the searched expression pattern. *)

  val roots : t -> Spice_workspace.Path.t list
  (** [roots t] are the resolved workspace roots that were searched. *)

  val offset : t -> int
  (** [offset t] is the effective one-based first finding of the page. *)

  val limit : t -> int
  (** [limit t] is the effective maximum number of findings per page. *)

  val returned_results : t -> int
  (** [returned_results t] is the number of findings in {!findings}. *)

  val total_results : t -> int
  (** [total_results t] is the number of matches across all searched files,
      before pagination. *)

  val findings : t -> finding list
  (** [findings t] is the returned page of findings, ordered by
      workspace-relative path, then by source range. *)

  val status : t -> status
  (** [status t] is the page coverage status. *)

  val next : t -> Input.t option
  (** [next t] is the input for the next page. It is [Some] iff {!status} is
      [Partial]. *)

  val has_more : t -> bool
  (** [has_more t] is [true] iff {!status} is [Partial]. *)

  val skipped : t -> skipped list
  (** [skipped t] are the candidate files that contributed no findings, with the
      reason each was skipped. *)

  val searched_files : t -> int
  (** [searched_files t] is the number of files that were parsed and searched.
      Together with {!skipped} this is the coverage evidence: candidates =
      searched + skipped. *)

  type render
  (** The type for model-visible rendering modes. *)

  val plain : render
  (** [plain] renders findings without line anchors. *)

  val anchored : ?source:Anchor.Source.t -> unit -> render
  (** [anchored ?source ()] renders findings with line anchors from [source].
      [source] defaults to {!Anchor.Source.deterministic}. *)

  val encode : ?render:render -> t Spice_tool.Output.encoder
  (** [encode ?render] projects typed search outputs to model-visible tool
      output. [render] defaults to {!plain}. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool. *)
end

(** {1 Execution} *)

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] are the read permission requests for [input],
    one per lexically resolvable requested root. *)

val run :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?anchors:Anchor.Source.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace input] parses the pattern, enumerates [.ml] files under
    the requested roots (recursively for directories, honoring standard ignore
    files and excluding VCS metadata), parses each source, and collects
    structural matches.

    Requested roots must be existing non-symlink regular files or directories
    inside the workspace. Binary, non-UTF-8, oversized, and unparseable files
    are reported in {!Output.skipped}. Findings are ordered by
    workspace-relative path, then by source range. [anchors] defaults to
    {!Anchor.Source.deterministic}. [cancelled] defaults to a function returning
    [false] and is checked between files. *)

(** {1 Adapter} *)

val tool :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?render:Output.render ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ()] is the erased {!Spice_tool.t} adapter. [render]
    defaults to {!Output.plain}. *)
