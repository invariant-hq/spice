(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace apply-patch tool.

    [Apply_patch] applies Codex-style patch documents to UTF-8 text files inside
    a workspace. It is the host-tool bridge from the model-facing {!Spice_patch}
    document format to stale-safe {!Spice_edit} plans.

    The typed surface is the primary API for host/session code:

    - build or decode an {!Input.t};
    - inspect {!permissions}, which conservatively derives access from parsed
      patch operations;
    - execute with {!run};
    - update session state from typed {!Output.t};
    - project with {!Output.encode} for model-visible transcripts.

    {!tool} is the erased {!Spice_tool.t} adapter for generic provider dispatch.

    The model-facing contract accepts one JSON field, [patch], containing the
    complete patch document. Freeform grammar tools and shell heredoc
    interception belong above this module. *)

val name : string
(** Stable tool name, ["apply_patch"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_max_file_bytes : int
(** Default maximum complete-file size accepted while planning and applying.

    The bound applies to every existing target that must be read completely to
    lower the patch to a stale-safe edit plan. It is a hard host-side ceiling,
    not a model-visible budget. *)

(** {1 Input} *)

module Input : sig
  type t
  (** Typed apply-patch request.

      [Input.t] is the host-side request type. Build values directly with
      {!make}, or decode provider JSON with {!decode}. The patch text is parsed
      during construction, so parsed operations are available without a
      filesystem. *)

  val make : patch:string -> (t, string) result
  (** [make ~patch] parses [patch] as a {!Spice_patch} document.

      [patch] must start with [*** Begin Patch], end with [*** End Patch], and
      contain at least one operation. Paths are parsed by {!Spice_patch} as
      paths relative to the workspace root; absolute paths and paths escaping
      that root are rejected by the parser.

      Returns [Error message] with a human-readable parse or validation
      diagnostic if [patch] is invalid. *)

  val patch : t -> string
  (** [patch t] is the original patch document. *)

  val operations : t -> Spice_patch.Operation.t list
  (** [operations t] are the parsed patch operations in document order. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls.

      The model-visible field is [patch]. Unknown fields are rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}.

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract, or with the patch parser diagnostic when [patch] is not a
      valid apply-patch document. *)
end

(** {1 Permissions} *)

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is the edit permission request for [input].

    Permission planning is syntactic and does not inspect the filesystem. Add
    and move destinations are included in the permission scope. *)

(** {1 Output} *)

module Output : sig
  type kind =
    | Create
    | Modify
    | Delete
    | Move of { from : Spice_workspace.Path.t }
        (** Semantic patch operation kind.

            [Move { from }] records an update hunk with [*** Move to: ...]. The
            entry path is the move destination. *)

  type entry
  (** Typed evidence for one semantic patch effect.

      Entries are ordered by the patch document and use resolved workspace
      paths. A moved update is represented by one [Move] entry, while the
      underlying {!Spice_edit.Result.t} still records the concrete create/delete
      mutations used to perform it. *)

  val path : entry -> Spice_workspace.Path.t
  (** [path e] is the changed output path.

      For [Delete], this is the deleted path. For [Move _], this is the move
      destination. *)

  val kind : entry -> kind
  (** [kind e] is [e]'s semantic patch operation kind. *)

  val source_path : entry -> Spice_workspace.Path.t option
  (** [source_path e] is the source path for moved entries and [None] otherwise.
  *)

  val entry_diff : entry -> string
  (** [entry_diff e] is the deterministic display diff for [e].

      Display diffs are evidence, not replay formats. *)

  type t
  (** Typed output and applied edit evidence. *)

  val entries : t -> entry list
  (** [entries t] are the semantic patch effects in patch order. *)

  val paths : t -> Spice_workspace.Path.t list
  (** [paths t] are the changed output paths in {!entries} order. *)

  val diff : t -> string
  (** [diff t] is the deterministic complete display diff for [t].

      The value is the concatenation of per-entry display diffs. It is evidence,
      not a replay format. *)

  val receipt : t -> Receipt.t
  (** [receipt t] is the common successful mutation receipt.

      Patch move entries are preserved as logical-change metadata. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed apply-patch outputs to model-visible tool output.

      The text projection is compact and reports only changed paths:

      {v
      Success. Updated the following files:
      create src/new.ml
      modify lib/foo.ml
      delete old.txt
      move old/name.ml -> new/name.ml
      v}

      The JSON projection preserves structured entries, created directories, and
      the full diff. It does not echo complete edited file contents;
      host/session code should use {!receipt} for audit and cache updates. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool's {!encode}. *)
end

(** {1 Execution} *)

val run :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?max_file_bytes:int ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~fs ~workspace input] plans and applies [input].

    [run] uses the already-decoded operations, resolves every source and
    destination through [workspace], reads every existing target completely
    through [fs], applies updates with {!Spice_patch.Update.apply}, lowers the
    result to one {!Spice_edit.t}, creates missing parent directories for add
    and move destinations, and applies the plan with {!Spice_edit.apply}.

    Successful runs are fully planned before mutation starts. Add destinations
    and move destinations must be missing. Update and delete sources must be
    existing regular UTF-8 text files. Directories, symlinks, binary files,
    invalid UTF-8 files, duplicate output targets, ambiguous source/output path
    conflicts, missing update context, paths outside [workspace], and files
    above [max_file_bytes] return failed tool results.

    [max_file_bytes] defaults to {!default_max_file_bytes}. [cancelled] defaults
    to a function returning [false] and is checked before planning, before
    creating parent directories, and before edit application. Once file mutation
    starts, [run] lets {!Spice_edit.apply} finish so returned evidence remains
    coherent.

    Raises [Invalid_argument] if [max_file_bytes < 0]. *)

(** {1 Adapter} *)

val tool :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?max_file_bytes:int ->
  unit ->
  Spice_tool.t
(** [tool ~fs ~workspace ()] is the erased {!Spice_tool.t} adapter.

    [max_file_bytes] defaults to {!default_max_file_bytes}. *)
