(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Standard executable tools for coding sessions.

    This library contains concrete workspace tool implementations. It
    intentionally keeps filesystem, process, permission, and stale-check
    evidence in each tool's typed output rather than extending {!Spice_tool}.
    Provider-facing code should use the erased tools from the family
    constructors or {!default}; host and session code should prefer the typed
    modules re-exported here. OCaml Dune support is split into one module per
    model-facing tool: {!Ocaml_dune_describe} for one-shot project structure and
    {!Ocaml_dune_diagnostics} for current Dune RPC diagnostics. *)

module Anchor = Anchor
(** Anchors for edit-targeting workflows. *)

module Anchor_tracker = Anchor_tracker
(** Deterministic stateful implementation of {!Anchor.Resolver}. *)

module Receipt = Receipt
(** Live mutation evidence produced by the mutating tools. *)

module Read_file = Read_file
(** Workspace UTF-8 text reader. *)

module Write_file = Write_file
(** Workspace text writer. *)

module Search_text = Search_text
(** Workspace text search. *)

module Glob = Glob
(** Recursive workspace file discovery by path glob. *)

module Edit_file = Edit_file
(** Workspace text editor. *)

module Edit_lines = Edit_lines
(** Anchored workspace line editor. *)

module Apply_patch = Apply_patch
(** Workspace apply-patch tool. *)

module Web = Web
(** Shared concepts for the web tools. *)

module Web_fetch = Web_fetch
(** Read-only public web page fetch tool. *)

module Web_search = Web_search
(** Read-only local web search tool. *)

module Ocaml_merlin = Ocaml_merlin
(** Shared single-shot [ocamlmerlin] transport and boot-time program resolution
    for the Merlin-backed OCaml tools. The host resolves a configured invocation
    prefix to a lock-free argv once at boot via {!Ocaml_merlin.resolve_program}
    and threads the result through [?merlin_program]. *)

module Ocaml_ast_edit = Ocaml_ast_edit
(** OCaml AST edit planning and execution. *)

module Ocaml_eval = Ocaml_eval
(** Fresh-process OCaml toplevel evaluator. *)

module Ocaml_dune_describe = Ocaml_dune_describe
(** Model-facing Dune project description tool. *)

module Ocaml_dune_diagnostics = Ocaml_dune_diagnostics
(** Model-facing Dune RPC diagnostics tool. *)

module Ocaml_docs = Ocaml_docs
(** Signatures and documentation for libraries, modules, and source files. *)

module Ocaml_find_definitions = Ocaml_find_definitions
(** Model-facing OCaml definition lookup tool. *)

module Ocaml_find_references = Ocaml_find_references
(** Semantic OCaml references through Merlin occurrences. *)

module Ocaml_rename = Ocaml_rename
(** Semantic OCaml rename through Merlin occurrences. *)

module Ocaml_replace_expressions = Ocaml_replace_expressions
(** Structural search-and-replace over workspace OCaml sources. *)

module Ocaml_search_expressions = Ocaml_search_expressions
(** Syntactic structural search over workspace OCaml sources. *)

module Ocaml_type_at = Ocaml_type_at
(** Inferred OCaml type (and optional documentation) at a source position. *)

module Shell = Shell
(** Workspace shell command runner. *)

module Evidence : sig
  (** Typed evidence view over the built-in catalog.

      {!of_output} probes the typed value retained by each built-in tool's
      output projection. Mutating tools collapse to one {!Mutation} shape so
      host and product code can derive changed-file evidence without knowing
      which edit adapter produced it. *)

  type t =
    | Read_file of Read_file.Output.t
    | Search_text of Search_text.Output.t
    | Glob of Glob.Output.t
    | Mutation of { tool : string; receipt : Receipt.t }
        (** Common evidence from successful mutating tools. *)
    | Web_fetch of Web_fetch.Output.t
    | Web_search of Web_search.Output.t
    | Ocaml_eval of Ocaml_eval.Output.t
        (** Evidence from [ocaml_eval]: the evaluated fresh toplevel process. *)
    | Ocaml_dune_describe of Ocaml_dune_describe.Output.t
        (** Evidence from [ocaml_dune_describe]: the Dune project shape. *)
    | Ocaml_dune_diagnostics of Ocaml_dune_diagnostics.Output.t
        (** Evidence from [ocaml_dune_diagnostics]: the current Dune RPC
            diagnostic set and endpoint used to obtain it. *)
    | Ocaml_docs of Ocaml_docs.Output.t
        (** Evidence from [ocaml_docs]: the resolved API surface, provenance,
            and pagination state. *)
    | Ocaml_find_definitions of Ocaml_find_definitions.Output.t
        (** Evidence from [ocaml_find_definitions]: Merlin definition targets.
        *)
    | Ocaml_find_references of Ocaml_find_references.Output.t
        (** Evidence from [ocaml_find_references]: Merlin occurrence targets. *)
    | Ocaml_search_expressions of Ocaml_search_expressions.Output.t
        (** Evidence from [ocaml_search_expressions]: structural findings and
            parse-coverage evidence. *)
    | Ocaml_type_at of Ocaml_type_at.Output.t
        (** Evidence from [ocaml_type_at]: inferred type frames and optional
            documentation at a position. *)
    | Shell of Shell.Output.t

  val of_output : Spice_tool.Output.t -> t option
  (** [of_output output] is the typed evidence retained in [output], or [None]
      for outputs produced by other tools or by projections without a retained
      value. *)

  val mutation : Spice_tool.Output.t -> Receipt.t option
  (** [mutation output] is the common mutation receipt retained in [output], if
      [output] came from a successful mutating built-in tool. This is the
      preferred host path for mutation recording. *)
end

val mutating_tool : string -> bool
(** [mutating_tool name] is [true] iff the built-in tool [name] may mutate the
    workspace. *)

val web :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  net:_ Eio.Net.t ->
  fetch_https:Web_fetch.https ->
  http:Cohttp_eio.Client.t ->
  policy:Web.Policy.t ->
  unit ->
  Spice_tool.t list
(** [web ~sw ~mono_clock ~net ~fetch_https ~http ~policy ()] is the web-tool
    catalog selected by [policy].

    When [policy] is disabled, the catalog is empty. Enabled policies include
    {!Web_fetch}, which resolves and validates each request host before calling
    [fetch_https] for HTTPS connections. Policies with a non-disabled search
    backend also include {!Web_search}, backed by [http]. This keeps the default
    coding catalog network-neutral while giving hosts a precise opt-in web
    surface. *)

module Editor : sig
  (** Which file-mutation surface a model receives.

      [Apply_patch] ships the unified {!Apply_patch} tool alone — it creates,
      edits, deletes, and moves. [String_replace] ships {!Write_file} for
      creation and {!Edit_file} for in-place edits, and no move or delete tool.
      The two are exclusive: a model never receives both surfaces. The host
      decides the family from the model and config and passes it as a typed
      value; this library never learns the model. *)

  type t =
    | Apply_patch
        (** {!Apply_patch} alone; no {!Write_file}, no {!Edit_file}. *)
    | String_replace  (** {!Write_file} + {!Edit_file}; no {!Apply_patch}. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable spelling: ["apply-patch"] or
      ["string-replace"]. *)

  val of_string : string -> t option
  (** [of_string s] parses ["apply-patch"] and ["string-replace"]; any other
      string is [None]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same editor family. *)
end

val files :
  ?anchors:Anchor.Resolver.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t list
(** [files ~fs ~workspace ()] is the read-side file catalog: {!Read_file}, which
    also lists directory targets, so no separate directory lister is needed.
    File mutation belongs to {!edits}, whose editor family owns {!Write_file}.

    When [anchors] is supplied, {!Read_file} renders anchors from the resolver's
    source. *)

val search :
  ?anchors:Anchor.Resolver.t ->
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t list
(** [search ~sandbox ~fs ~workspace ()] is the workspace search catalog: {!Search_text}
    and {!Glob}, in that order.

    When [anchors] is supplied, {!Search_text} renders anchors from the
    resolver's source. *)

val edits :
  ?mutating:bool ->
  ?anchors:Anchor.Resolver.t ->
  editor:Editor.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t list
(** [edits ~editor ~fs ~workspace ()] is the workspace mutation catalog: the
    selected editor family, {!Ocaml_ast_edit}, and optional {!Edit_lines}, in
    default catalog order.

    [mutating] defaults to [true]. When [false], the catalog is empty.

    [editor] selects the whole general mutation surface, so a mismatched family
    pairing is unrepresentable: {!Editor.String_replace} ships {!Write_file} and
    {!Edit_file}; {!Editor.Apply_patch} ships {!Apply_patch} alone (its patch
    tool creates, edits, moves, and deletes files). {!Ocaml_ast_edit} is not
    part of either family and always follows. When [anchors] is supplied,
    {!Edit_lines} joins the mutating catalog after {!Ocaml_ast_edit},
    independent of [editor]; otherwise it is omitted. *)

val ocaml :
  ?mutating:bool ->
  ?project_source:Spice_ocaml_dune.Project_source.t ->
  ?merlin_program:string list ->
  ?watch:(unit -> string option) ->
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:_ Eio.Path.t ->
  dune:Spice_ocaml_dune.Rpc.Instance.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t list
(** [ocaml ~sandbox ~fs ~process_mgr ~clock ~cwd ~dune ~workspace ()] is the OCaml
    support catalog: optional {!Ocaml_eval}, optional {!Ocaml_rename} and
    {!Ocaml_replace_expressions}, {!Ocaml_dune_describe},
    {!Ocaml_dune_diagnostics}, {!Ocaml_docs}, {!Ocaml_find_definitions},
    {!Ocaml_find_references}, {!Ocaml_search_expressions}, and {!Ocaml_type_at},
    in that order.

    [mutating] defaults to [true]. When [false], {!Ocaml_eval}, {!Ocaml_rename},
    and {!Ocaml_replace_expressions} are omitted because they execute or mutate.
    Structural OCaml editing belongs to {!edits} so {!default} can preserve the
    historical tool order.

    [project_source] supplies a boot-captured Dune project description to
    {!Ocaml_dune_describe} and {!Ocaml_docs}, so those tools do not run a
    one-shot [dune describe] under the session's build-watch lock; absent, they
    fall back to today's behavior. [merlin_program] is the resolved lock-free
    [ocamlmerlin] invocation prefix threaded to the Merlin-backed tools
    ({!Ocaml_type_at}, {!Ocaml_rename}, {!Ocaml_find_definitions},
    {!Ocaml_find_references}, {!Ocaml_docs}); absent, they default to
    [["ocamlmerlin"]]. [watch] supplies {!Ocaml_eval} the session's
    watched-build diagnostics probe; absent, it evaluates without one. *)

val shell :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  config:Shell.Config.t ->
  unit ->
  Spice_tool.t list
(** [shell ~fs ~workspace ~config ()] is the shell execution catalog containing
    {!Shell}. *)

val default :
  ?mutating:bool ->
  ?project_source:Spice_ocaml_dune.Project_source.t ->
  ?merlin_program:string list ->
  ?watch:(unit -> string option) ->
  ?anchors:Anchor.Resolver.t ->
  editor:Editor.t ->
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  process_mgr:_ Eio.Process.mgr ->
  clock:_ Eio.Time.clock ->
  cwd:_ Eio.Path.t ->
  dune:Spice_ocaml_dune.Rpc.Instance.t ->
  workspace:Spice_workspace.t ->
  shell:Shell.Config.t ->
  unit ->
  Spice_tool.t list
(** [default ~sandbox ~fs ~process_mgr ~clock ~cwd ~dune ~workspace ~shell ()] is the
    standard coding-session tool catalog.

    The catalog contains file reads (including directory listings), writes, text
    search, globbing, exact edits, patch application, structural OCaml AST
    edits, OCaml eval, OCaml API docs, OCaml Dune inspection, Merlin
    definition/reference lookup, and shell execution in that order. [shell] is
    the host-selected shell execution policy. Filesystem tools derive their
    authority from [fs] and [workspace]. [process_mgr], [clock], and [cwd] back
    the bounded one-shot {!Ocaml_dune_describe} tool. [cwd] also supplies the
    process directory for Merlin-backed lookups. [dune] backs
    {!Ocaml_dune_diagnostics} and should be the same workspace-level
    {!Spice_ocaml_dune.Rpc.Instance.t} used by host Dune diagnostic watchers.

    This is a compatibility/convenience wrapper over
    [files @ search @ edits @ ocaml @ shell]. Prefer the family constructors
    when assembling a custom catalog.

    [mutating] defaults to [true]. When [false], the catalog omits tools that
    mutate the workspace or execute arbitrary user code ({!Write_file},
    {!Edit_file}, {!Apply_patch}, {!Ocaml_ast_edit}, {!Edit_lines}, and
    {!Ocaml_eval}): a read-only run never constructs what it must not call.

    [editor] is threaded to {!edits} and selects the whole general mutation
    surface (see {!edits}). [project_source], [merlin_program], and [watch] are
    threaded to {!ocaml}; all absent means today's behavior.

    [anchors] defaults to [None], today's catalog exactly. When supplied,
    {!Read_file} and {!Search_text} render anchors from the resolver's source
    and, in mutating catalogs, {!Edit_lines} joins the catalog after
    {!Ocaml_ast_edit}. *)
