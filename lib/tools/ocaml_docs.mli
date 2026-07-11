(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OCaml API documentation by name or path.

    [ocaml_docs] returns a bounded, provenance-stamped view of an OCaml API — a
    package/library overview, a module signature outline with doc comments, a
    single value/type's signature, or a workspace file's outline — for anything
    in the project's module universe: its own workspace libraries and its locked
    dependencies. It is addressed by a single {!Input.query} whose syntax
    selects the form (file path, library name, module path, or focused
    identifier).

    Dependency sources are parsed as installed [.mli]/[.ml] {e source} text only
    — never [.cmt]/[.cmti], whose binary magic numbers are compiler-version-
    locked — so the output is independent of the toolchain that built the
    package, and every dependency result names the resolved version and build so
    the evidence is auditable against the project's lock.

    The path form outlines a workspace file with a compiler-parser outline and a
    Merlin fallback for mid-edit files the parser cannot handle. All four forms
    render into one {!Output.t} (single-output-shape invariant).

    The typed surface is the primary API for host/session code:

    - build or decode an {!Input.t};
    - inspect {!permissions};
    - execute with {!run};
    - update session state from typed {!Output.t};
    - project with {!Output.encode} for model-visible transcripts.

    {!tool} is the erased {!Spice_tool.t} adapter for generic provider dispatch.
*)

val name : string
(** Stable tool name, ["ocaml_docs"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_limit : int
(** Default maximum number of outline items returned by {!run}. *)

val max_limit : int
(** Maximum accepted explicit item limit. *)

val max_doc_bytes : int
(** Maximum retained byte length of a single doc comment before truncation. *)

val default_max_source_bytes : int
(** Default maximum size of a resolved source file accepted by {!run}. *)

val max_source_bytes : int
(** Maximum accepted explicit source-file size. *)

(** {1 Input} *)

module Input : sig
  type scope =
    | Workspace
    | Deps
    | Any
        (** Name-form resolution universe.

            [Any] (the default) resolves against both local libraries and
            dependencies and reports an ambiguity when a name matches both.
            [Workspace] restricts to local libraries, [Deps] to dependencies.
            Ignored for path-form queries. *)

  type t
  (** Typed documentation request.

      Build values with {!make} or decode provider JSON with {!decode}. *)

  val make :
    ?scope:scope ->
    ?package:string ->
    ?depth:int ->
    ?offset:int ->
    ?limit:int ->
    ?max_source_bytes:int ->
    string ->
    t
  (** [make query] requests documentation for [query].

      [query] is a workspace file path (contains ['/'] or ends in [.ml]/[.mli]),
      a findlib/local library name (lowercase, dot-separated, such as ["eio"] or
      ["spice_permission"]), a capitalized module path (["Eio.Path"]), or a
      qualified identifier (["Eio.Path.load"]). The form is selected by
      [query]'s syntax.

      [scope] defaults to {!Any}. [package] forces the containing findlib
      library for a capitalized [query] whose root module does not match its
      library name; when absent the library is inferred from the first module
      segment. [depth] is the inline nested-module expansion depth and defaults
      to [0]. [offset] is the one-based first preorder item to return and
      defaults to [1]. [limit] defaults to {!default_limit}. The resolved source
      file must be no larger than [max_source_bytes], which defaults to
      {!default_max_source_bytes}.

      Raises [Invalid_argument] if [query] is empty or contains NUL, [package]
      is empty or contains NUL, [depth < 0], [offset < 1], [limit < 1],
      [limit > max_limit], [max_source_bytes < 1], or [max_source_bytes] is
      greater than {!max_source_bytes}. *)

  val query : t -> string
  (** [query t] is the requested lookup string. *)

  val scope : t -> scope
  (** [scope t] is the requested resolution universe. *)

  val package : t -> string option
  (** [package t] is the requested findlib library hint, if explicit. *)

  val depth : t -> int option
  (** [depth t] is the requested inline expansion depth, if explicit. *)

  val offset : t -> int option
  (** [offset t] is the requested one-based first item, if explicit. *)

  val limit : t -> int option
  (** [limit t] is the requested maximum item count, if explicit. *)

  val max_source_bytes : t -> int option
  (** [max_source_bytes t] is the requested maximum source-file size, if
      explicit. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}. *)
end

val permissions :
  ?opam_switch_prefix:string ->
  workspace:Spice_workspace.t ->
  Input.t ->
  Spice_permission.Request.t list
(** [permissions ~workspace input] is the set of workspace, package metadata,
    and installed-library reads the documentation operation needs.

    For a path-form query it is the workspace file read. For a name-form query
    on a dune-package project it requests the project-root and
    [_build/_private/default/.pkg] reads used by universe resolution.

    For a name-form query on an opam project it additionally requests a read of
    the switch library root, which lies **outside** the workspace. [permissions]
    is pure and cannot run [ocamlfind] to learn the
    exact [lib/<pkg>] directory, so the honest, visible request names the whole
    switch library root [<prefix>/lib] via [Access.path_scope ~op:`Read] over
    [Path_scope.outside_workspace] ([access.mli:90,175]); [opam_switch_prefix]
    defaults to [$OPAM_SWITCH_PREFIX], which is available in the environment
    without a subprocess, so the coarse request is still a real directory the
    user can judge. {!run} tightens this at read time: it validates the resolved
    file is under the [ocamlfind]-reported [lib/<pkg>] directory before reading
    (§5). This is spice's first out-of-workspace reader; see §5 for why it is
    now justified and how the read seam is bounded. *)

(** {1 Output} *)

module Item : sig
  (** A flattened signature declaration in preorder. *)

  type kind =
    | Value
    | Type
    | Module
    | Module_type
    | Exception
    | Class
    | Class_type  (** Declaration kind. *)

  type t = private {
    kind : kind;
    name : string;
    path : string list;
    depth : int;
    signature : string;
    typ : string option;
    deprecated : bool;
    child_count : int option;
    doc : string option;
    doc_truncated : bool;
  }
  (** A declaration from the resolved file/module.

      [path] is the qualified declaration path from the resolved root. [depth]
      is [List.length path - 1]. [signature] is the declaration's source-text
      span: usually one line for a [val], but as many lines as the source uses
      for a multi-line record, variant, or GADT [type], and a collapsed
      [sig … end] header for a nested module. [typ] is Merlin's inferred type
      when the path-form Merlin backend supplied it, and [None] for the
      parser-only dependency backends; [deprecated] is likewise Merlin-supplied.
      [child_count] is the number of direct members of a collapsed module and
      [None] otherwise. [doc] is the attached odoc comment, passed through
      verbatim and byte-capped to {!max_doc_bytes} with [doc_truncated] set when
      capped. *)

  val kind_to_string : kind -> string
  (** [kind_to_string k] is the provider-facing name for [k]. *)
end

module Output : sig
  (** Typed output and its model-visible projection. *)

  type level =
    | File_outline
    | Library_overview
    | Module_outline
    | Item_focus  (** Resolved query granularity. *)

  type dep_install =
    | Pkg_build of { build_hash : string; ambiguous_builds : bool }
        (** A dune-package build under [_build/…/.pkg]. [ambiguous_builds] is
            [true] when several builds were present and the newest was chosen.
        *)
    | Opam_switch of { prefix : string }
        (** A classic opam-switch install; [prefix] is the switch prefix whose
            [lib/] the source was read from. *)

  (** Where the resolved source came from — the provenance stamp. *)
  type origin =
    | Workspace_file  (** A path-form outline of an in-tree file. *)
    | Workspace_library
        (** A local library resolved from [dune describe] local components;
            in-tree source, no build hash. *)
    | Dependency of {
        package : string;
        version : string;
        install : dep_install;
      }
        (** A dependency the build links, resolved to its [.pkg] build (dune
            package projects) or its opam-switch install (opam projects). *)

  type total = Exact of int | Unknown  (** Total item-count precision. *)

  type status =
    | Complete
    | Partial of { next : Input.t }
        (** Page coverage for the preorder item stream. *)

  type t = private {
    level : level;
    origin : origin;
    library : string option;
    source_path : string;
    interface_available : bool;
    synopsis : string option;
    modules : string list;
    sublibraries : string list;
    items : Item.t list;
    offset : int;
    total : total;
    status : status;
    describe_freshness : Spice_ocaml_dune.Project_source.Freshness.t option;
  }
  (** Typed output retained by completed tool calls.

      [origin] is the provenance stamp (§2.3). [library] is the resolved library
      name for name-form queries and [None] for a path-form outline.
      [source_path] is the resolved source that was parsed.
      [interface_available] is [false] when only a [.ml] was available.
      [synopsis] and [sublibraries] are populated for {!Library_overview}
      (dependencies); [modules] is the top-level module list for an overview or
      the enclosing module's member names for an unknown-identifier recovery.
      [items] are the returned outline declarations in preorder.
      [describe_freshness] is the build-lock freshness evidence for a
      describe-backed name form resolved through a
      {!Spice_ocaml_dune.Project_source.t}, and [None] for the path form and for
      direct-describe (no source) callers — the shape is orthogonal to
      [origin]'s source-location provenance. *)

  val level : t -> level
  val origin : t -> origin
  val library : t -> string option
  val source_path : t -> string
  val interface_available : t -> bool
  val synopsis : t -> string option
  val modules : t -> string list
  val sublibraries : t -> string list
  val items : t -> Item.t list
  val offset : t -> int
  val total : t -> total
  val status : t -> status

  val describe_freshness :
    t -> Spice_ocaml_dune.Project_source.Freshness.t option
  (** [describe_freshness t] is the freshness evidence for a describe-backed
      result served through a {!Spice_ocaml_dune.Project_source.t}, and [None]
      for the path form and direct-describe callers. *)

  val provenance : t -> string
  (** [provenance t] is the one-line provenance string for [origin t]:
      ["workspace file <path>"], ["workspace library <name>"],
      ["<pkg>@<version> (build <hash>)"] for a [.pkg] dependency, or
      ["<pkg>@<version> (opam switch <prefix>)"] for a switch dependency. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode output] projects typed output to model-visible text and JSON. The
      text form leads with {!provenance}. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool's {!encode}. *)
end

(** {1 Execution} *)

val run :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  ?ocamlfind_program:string ->
  ?opam_switch_prefix:string ->
  ?project_source:Spice_ocaml_dune.Project_source.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  fs:_ Eio.Path.t ->
  cwd:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~program ~process_mgr ~clock ~fs ~cwd ~workspace input] resolves
    [input]'s query and returns a bounded, provenance-stamped outline.

    [program] is the Merlin invocation {e prefix} (default [["ocamlmerlin"]]); a
    dune-toolchain project boot-resolves it to a lock-free binary path (see
    {!Ocaml_merlin.resolve_program}).

    With [project_source] the name-form describe is resolved fresh-or-snapshot
    with build-lock awareness (see {!Spice_ocaml_dune.Project_source}); the
    output carries {!Output.describe_freshness} evidence, and a
    lock-held-with-no-snapshot state fails as [`Unavailable] naming the watch.
    Without it the name-form describe runs directly, byte-identical to prior
    behaviour. The path form never consults [project_source].

    A path-form query outlines the workspace file with Merlin (invocation prefix
    [program], default [["ocamlmerlin"]]) and a parser fallback. A name-form
    query resolves the library through [dune describe workspace] (local and
    external components); a local library reads its in-tree [units]. A
    dependency resolves by project flavor: a dune-package project reads its
    [.pkg] build — pinned to the locked hash when describe reports the build
    path, else the newest-mtime [.pkg] scan — and an opam project reads its
    switch [lib/<pkg>] directory located by [ocamlfind] ([ocamlfind_program],
    default ["ocamlfind"]) under [opam_switch_prefix] (default
    [$OPAM_SWITCH_PREFIX]). The switch read is the out-of-workspace read seam
    (§5): the resolved file is validated to be under the [ocamlfind]-reported
    [lib/<pkg>] directory, symlinks are not followed, and the same size/UTF-8
    caps as in-workspace reads apply. [process_mgr]/[clock]/[cwd] run the
    describe/[ocamlfind] resolvers.

    Ambiguous names, unknown libraries, non-dependencies, unknown module paths,
    unknown identifiers,
    out-of-workspace/missing/oversized/non-UTF-8/unparseable sources return
    failed tool results with recovery hints (candidate provenance, close-match
    names, the library's module list, or the enclosing module's members). Only
    [.mli]/[.ml] source is read; [.cmt]/[.cmti] are never opened. *)

val tool :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  ?ocamlfind_program:string ->
  ?opam_switch_prefix:string ->
  ?project_source:Spice_ocaml_dune.Project_source.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  fs:_ Eio.Path.t ->
  cwd:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t
(** [tool …] is the erased model-facing tool for {!run}. *)
