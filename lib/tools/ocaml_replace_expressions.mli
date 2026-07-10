(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Structural search-and-replace over workspace OCaml sources.

    [Ocaml_replace_expressions] matches an OCaml expression pattern against the
    parse trees of workspace [.ml] files through {!Spice_ocaml_grep}, then
    rewrites every match using a template that reuses the pattern's
    metavariables. Each [__N] hole in the template is filled with the exact
    source bytes that metavariable matched at that site, so comments and
    formatting inside captured fragments are preserved. Replacements are
    parenthesized as needed and every rewritten site is re-parsed and checked to
    strip-equal the template with its fragments substituted, so a file is never
    written unless its rewrite reparses and means what the template says. Files
    that cannot be read, parsed, or safely rewritten are reported as skipped
    coverage evidence, never silently dropped. *)

val name : string
(** Stable tool name, ["ocaml_replace_expressions"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_max_sites : int
(** Default upper bound on rewritten sites across all files. *)

val max_max_sites : int
(** Largest accepted explicit [max_sites]. *)

val max_source_bytes : int
(** Maximum size of a source file considered by {!run}. Larger files are skipped
    and reported. *)

(** {1 Input} *)

module Input : sig
  type t
  (** Typed structural rewrite request. *)

  val make :
    ?paths:string list ->
    ?max_sites:int ->
    ?dry_run:bool ->
    pattern:string ->
    template:string ->
    unit ->
    t
  (** [make ~pattern ~template ()] rewrites every match of [pattern] using
      [template]. (The trailing [unit] keeps the leading optional arguments
      erasable; the design note's signature omits it.)

      [pattern] is non-empty {!Spice_ocaml_grep.Pattern} syntax. [template] is a
      non-empty OCaml expression whose metavariable holes are a subset of
      [pattern]'s; both are parsed and validated at execution time. [paths] are
      workspace-relative or workspace-contained files or directories; absent
      [paths] means the workspace root. [max_sites] bounds the total rewritten
      sites and defaults to {!default_max_sites}. [dry_run] defaults to [false]
      (the tool applies in one call; see the design note §2.9); when [true],
      {!run} validates and renders but writes nothing.

      Raises [Invalid_argument] if [pattern] or [template] is empty or contains
      NUL, any path is empty or contains NUL, [paths] is explicitly empty, or
      [max_sites] is outside [1 .. max_max_sites]. Pattern/template
      well-formedness beyond emptiness — including the rejection of templates
      that introduce a binder scoping over a hole, which risks variable capture
      — is validated in {!run}. *)

  val pattern : t -> string
  (** [pattern t] is the requested expression pattern. *)

  val template : t -> string
  (** [template t] is the requested replacement template. *)

  val paths : t -> string list option
  (** [paths t] are the requested roots, or [None] for the workspace root. *)

  val max_sites : t -> int option
  (** [max_sites t] is the requested site bound, if given. *)

  val dry_run : t -> bool
  (** [dry_run t] is [true] iff [t] requests a non-writing preview. Defaults to
      [false] when the field is absent (the tool applies in one call). *)

  val contract : t Spice_tool.Input.t
  (** JSON input contract for tool calls. Unknown fields are rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}. *)
end

(** {1 Output} *)

module Output : sig
  type skipped_reason =
    | Binary
    | Invalid_utf8
    | Too_large
    | Syntax_error of string
    | Read_error of string
    | Unrenderable of string
    | Rewrite_unparsable of string
        (** Why a candidate [.ml] file contributed no rewrite.

            [Syntax_error] is the current file failing to parse. [Unrenderable]
            is a site whose replacement could not be parenthesized to the
            template's structure — internal precedence capture, outer capture or
            boundary re-association that widening did not repair, or an
            adjacency that forms a comment token. [Rewrite_unparsable] is the
            spliced file failing to reparse. Each carries a diagnostic. *)

  type skipped = private {
    skipped_path : Spice_workspace.Path.t;
    reason : skipped_reason;
  }
  (** One candidate file that was not rewritten and why. *)

  type site = private {
    location : Spice_ocaml.Location.t;  (** The matched expression's range. *)
    before : string;  (** Original matched source (bounded, valid UTF-8). *)
    after : string;  (** Rendered replacement (bounded, valid UTF-8). *)
  }
  (** One rewritten expression: where it was and how it changed. *)

  type file = private {
    file_path : Spice_workspace.Path.t;
    sites : site list;  (** Non-empty, ordered by source range. *)
    diff : string;  (** Unified diff for this file, for humans and history. *)
  }
  (** One file that was (or, under {!Input.dry_run}, would be) rewritten. *)

  type status =
    | Applied  (** Files were written; {!receipt} is non-empty. *)
    | Previewed  (** [dry_run] was set; nothing was written. *)

  type t
  (** Typed rewrite observation. *)

  val pattern : t -> string
  val template : t -> string
  val roots : t -> Spice_workspace.Path.t list
  val status : t -> status

  val files : t -> file list
  (** [files t] are the rewritten (or previewed) files, ordered by path. *)

  val total_sites : t -> int
  (** [total_sites t] is the number of rewritten sites across {!files}. *)

  val searched_files : t -> int
  (** [searched_files t] is the number of files parsed and searched. Coverage
      evidence: candidates = searched + skipped. *)

  val skipped : t -> skipped list
  (** [skipped t] are candidate files that were not rewritten, with reasons. *)

  val receipt : t -> Receipt.t
  (** [receipt t] is the successful mutation receipt: one logical [Modify] per
      written file, each carrying that file's diff. Empty when {!status} is
      [Previewed] or no file changed. *)

  val final_identities :
    t -> (Spice_workspace.Path.t * Spice_digest.Identity.t) list
  (** [final_identities t] are the post-write content identities of files that
      were written, for cache and freshness state. Empty under [dry_run]. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed output to compact model-visible text and JSON.
      Per-site before/after excerpts are bounded in count and line length; full
      file contents are not echoed. *)

  val of_tool_output : Spice_tool.Output.t -> t option
end

(** {1 Execution} *)

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is one [Read] request per resolvable root
    when [Input.dry_run input] is [true], and one [Modify] request per
    resolvable root otherwise. *)

val run :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?max_bytes:int ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace input] parses and validates [pattern] and [template],
    enumerates [.ml] files under the requested roots (as
    {!Ocaml_search_expressions.run} does), and for each file matches [pattern],
    renders [template] per site, splices bottom-up, reparses, and verifies each
    site strip-equals the template with its fragments substituted.

    The template is rejected up front (whole call, [`Invalid_input]) when it is
    not a single expression, uses pattern-only vocabulary ([__], [PRESENT],
    [MISSING]), references a metavariable absent from the pattern, or introduces
    a binder whose scope contains a hole (variable-capture guard; see the design
    note §2.4a). If the total match count exceeds [Input.max_sites], the call
    fails with the count and writes nothing. A file that cannot be read, parsed,
    rendered, or reparsed is reported in {!Output.skipped}; the other files
    still proceed. Unless [Input.dry_run] is set (it defaults to [false]), the
    validated per-file rewrites are combined into one {!Spice_edit.t} and
    applied under a write lock, so files changed on disk since reading are
    rejected as conflicts. [max_bytes] is the apply-time {!Spice_edit} read cap;
    the search-phase read that skips oversized sources is bounded by
    {!max_source_bytes}. [cancelled] is checked between files. *)

(** {1 Adapter} *)

val tool :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ()] is the erased {!Spice_tool.t} adapter. *)
