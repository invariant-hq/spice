(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace text editor.

    [Edit_file] performs one exact text replacement in one existing UTF-8 text
    file inside a workspace. It is the small, targeted edit tool: use
    {!Write_file} to create or replace complete files, and {!Apply_patch} for
    broad structural or multi-file edits.

    The typed surface is the primary API for host/session code:

    - build or decode an {!Input.t};
    - inspect {!permissions};
    - execute with {!run};
    - update session state from typed {!Output.t};
    - project with {!Output.encode} for model-visible transcripts.

    {!tool} is the erased {!Spice_tool.t} adapter for generic provider dispatch.

    {b Staleness.} A complete-file identity is the shared freshness token across
    {!Read_file}, {!Write_file}, and {!Edit_file}: whenever one is supplied it
    is checked against the current complete-file identity before the tool acts,
    and a mismatch is reported rather than silently proceeding. Here
    [if_identity] is an optional pre-check; when it is omitted the exact
    [old_string] match is the freshness guard, and a supplied stale identity
    fails before any replacement. *)

val name : string
(** Stable tool name, ["edit_file"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_max_file_bytes : int
(** Default maximum complete-file size accepted by {!run}.

    The bound applies to the existing target contents and to the simulated final
    contents before mutation. It is a hard host-side ceiling, not a
    model-visible budget. *)

(** {1 Input} *)

module Input : sig
  type occurrence =
    | Once
    | All
        (** Replacement multiplicity. [Once] requires exactly one
            non-overlapping match; [All] replaces every non-overlapping match
            and requires at least one. *)

  type t
  (** Typed exact-replacement request.

      [Input.t] is the host-side request type. Build values directly with
      {!replace} from already-typed OCaml values, or decode provider JSON with
      {!decode}. *)

  val replace :
    path:string ->
    old_string:string ->
    new_string:string ->
    ?occurrence:occurrence ->
    ?if_identity:Spice_digest.Identity.t ->
    unit ->
    t
  (** [replace ~path ~old_string ~new_string ()] replaces exact text in [path].

      [path] is workspace-relative or an absolute path contained by the
      workspace. [old_string] must be exact current file text without line
      numbers, anchors, or diff markers. [new_string] is the replacement text
      and may be empty. [occurrence] defaults to [Once], which requires exactly
      one non-overlapping match. [All] replaces every non-overlapping match and
      requires at least one match.

      [if_identity], when supplied, requires the current complete-file identity
      to match a previous complete {!Read_file} observation before replacement
      simulation begins.

      Raises [Invalid_argument] if [path] is empty, [old_string] is empty,
      [old_string] equals [new_string], or either text argument is not valid
      UTF-8 text. These are programmer-local construction violations; provider
      input is validated at the {!decode} boundary instead. *)

  val path : t -> string
  (** [path t] is the requested path string. *)

  val old_string : t -> string
  (** [old_string t] is the exact text to replace. *)

  val new_string : t -> string
  (** [new_string t] is the replacement text. *)

  val occurrence : t -> occurrence
  (** [occurrence t] is the replacement multiplicity policy. *)

  val if_identity : t -> Spice_digest.Identity.t option
  (** [if_identity t] is the requested complete-file freshness identity, if any.
  *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls.

      The model-visible fields are [path], [old_string], [new_string], optional
      [occurrence], and optional [if_identity]. Unknown fields are rejected.
      [occurrence] is optional and decodes to [Once]. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}.

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract. *)
end

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is the modify permission request for [input].

    If the request path cannot be resolved in [workspace], the returned list is
    empty; {!run} reports the resolution failure as an invalid-input tool
    result. *)

(** {1 Output} *)

module Output : sig
  type t
  (** Typed output and edit evidence. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path that was edited or checked. *)

  val replacements : t -> int
  (** [replacements t] is the number of non-overlapping matches replaced during
      simulation.

      It is positive for successful edits, including unchanged results produced
      by line-ending or byte-order-mark normalization. *)

  val occurrence : t -> Input.occurrence
  (** [occurrence t] is the replacement policy used to produce [t]. *)

  val identity : t -> Spice_digest.Identity.t
  (** [identity t] is the identity of [after_contents t]. *)

  val before_contents : t -> string
  (** [before_contents t] is the complete UTF-8 file contents observed before
      simulation.

      This is host/session evidence. {!encode} keeps model-visible output
      compact and does not echo the complete file. *)

  val after_contents : t -> string
  (** [after_contents t] is the complete UTF-8 file contents after replacement
      simulation.

      For [Unchanged _] outputs this equals {!before_contents}. *)

  val receipt : t -> Receipt.t
  (** [receipt t] is the common successful mutation receipt.

      It is empty for unchanged outputs. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed edit outputs to model-visible tool output.

      The projection reports the path, status, replacement count, final
      identity, and freshness evidence. It does not include complete before or
      after contents; host/session code should use {!before_contents} and
      {!after_contents} for cache and audit state. *)

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
(** [run ~fs ~workspace input] executes a typed edit call and returns typed
    output.

    Paths are resolved through [workspace] and edited through [fs]. The target
    must be an existing regular UTF-8 text file inside the workspace. Missing
    files, directories, symlinks, non-regular files, binary or invalid UTF-8
    files, paths outside [workspace], files above [max_file_bytes], stale
    [if_identity] values, zero matches, and multiple matches without
    [Input.Once] return failed tool results.

    Incoming [old_string] and [new_string] are normalized to the target file's
    line-ending style before matching and replacement. A UTF-8 byte-order mark
    on the target is preserved. The final complete contents are lowered to
    {!Spice_edit.rewrite} and applied through {!Spice_edit.apply}, so concurrent
    changes after simulation are rejected before mutation starts.

    [max_file_bytes] defaults to {!default_max_file_bytes}. [cancelled] defaults
    to a function returning [false] and is checked before filesystem mutation
    begins. Once mutation starts, cancellation does not interrupt
    {!Spice_edit.apply}; this keeps edit evidence coherent.

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
