(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The standard coding-session tool catalog.

    [Toolset] is the single home for the tools a coding turn can call: the
    built-in file/search/edit/OCaml/shell catalog, the web catalog, and the
    skill tools, assembled from a loaded {!Host}. It is a pure eliminator — its
    result is the {!Spice_tool.t} list a run drives — with no state of its own.

    {!Run.start} builds this catalog for the standard run; it stays public
    because [spice debug tools] builds it standalone, without a {!Run.t}, to
    render an honest tool snapshot.

    Web policy construction — reading the configured search backend and its
    process-environment credential — is internal; callers supply only the HTTPS
    transport. The returned list is sandbox-filtered (a read-only run never
    constructs mutating tools) but not mode-filtered: apply
    {!Spice_protocol.Contract.filter_tools} to impose a run's read-only
    contract. *)

(** {1:editor Editor family} *)

(** Why {!editor_decision} chose an editor family. *)
type editor_reason =
  | Override  (** [tools.editor] forced the family. *)
  | Capability
      (** [auto] resolved from the model's [apply-patch] capability. *)
  | Default_no_model
      (** [auto] with no resolvable model; fell back to string-replace. *)

val editor_reason_to_string : editor_reason -> string
(** [editor_reason_to_string reason] is [reason]'s stable spelling:
    ["override"], ["capability"], or ["default(no-model)"]. *)

val editor_decision :
  Host.t ->
  Spice_provider.Model.t option ->
  Spice_tools.Editor.t * editor_reason
(** [editor_decision host model] is the file-mutation editor family [host]
    selects for [model], with the reason it was chosen.

    The [tools.editor] config override wins; otherwise ([auto]) the choice reads
    [model]'s [apply-patch] capability, defaulting to
    {!Spice_tools.Editor.String_replace} when [model] is [None]. {!make} uses it
    with the run's model; [spice debug tools] uses it directly to render an
    editor-family header. *)

(** {1:catalog Catalog} *)

val make :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  Host.t ->
  ?model:Spice_provider.Model.t ->
  workspace:Spice_workspace.t ->
  sandbox:Sandbox.Effective.t ->
  skills:Skills.t ->
  cwd:Eio.Fs.dir_ty Eio.Path.t ->
  http:Cohttp_eio.Client.t ->
  fetch_https:Spice_tools.Web_fetch.https ->
  anchors_seed:string ->
  ?dune:Spice_ocaml_dune.Rpc.Instance.t ->
  ?project_source:Spice_ocaml_dune.Project_source.t ->
  ?merlin_program:string list ->
  unit ->
  Spice_tool.t list
(** [make ~sw ~stdenv host ~workspace ~sandbox ~skills ~cwd ~http ~fetch_https
     ~anchors_seed ()] is the standard tool catalog for a run over [host].

    [model] selects the file-mutation editor family via {!editor_decision}.
    Absent — the [spice debug tools] snapshot with no resolvable model — the
    string-replace family is used.

    The catalog is {!Spice_tools.default} (filesystem, search, edits, OCaml, and
    shell, with [mutating] set from {!Sandbox.mutating_tools} so a read-only
    sandbox omits mutating tools) followed by {!Spice_tools.web} under the
    host's resolved web policy, followed by {!Skills.tools}. [cwd] is the run
    directory Eio path (see {!Context.eio_cwd}); [http] and [fetch_https] are
    the HTTPS transport the host does not own — the TLS stack lives in the
    binary package, not this library.

    Anchored edits are gated on [Config.Tools.anchored_edits]: when enabled, one
    ephemeral {!Spice_tools.Anchor_tracker} resolver is created, seeded from
    [anchors_seed] (the session id, so scripted transcripts are stable). With
    the flag off the catalog is byte-identical to an unanchored run.

    [dune] is the shared workspace Dune RPC instance backing the OCaml Dune
    tools; it should be the same instance the notice producers watch, so tool
    calls and watcher events observe one endpoint. When absent, a fresh
    non-watching instance is created for the catalog. [project_source] and
    [merlin_program] are the boot-captured project-shape source and the resolved
    lock-free [ocamlmerlin] argv; they let the OCaml Dune and Merlin tools
    coexist with a build-watch lock, and fall back to a one-shot [dune describe]
    and a plain [ocamlmerlin] invocation when absent.

    The result is not mode-filtered; compose it with
    {!Spice_protocol.Contract.filter_tools}. *)
