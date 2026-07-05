(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace text writer.

    [Write_file] writes complete UTF-8 text files inside a workspace. It has the
    same two-surface shape as {!Read_file}: host/session code uses typed
    {!Input.t} and {!Output.t} values, while {!tool} exposes the erased
    {!Spice_tool.t} adapter for provider dispatch.

    The model-facing contract is intentionally strict:

    - without [if_identity], the target must be missing and is created, creating
      missing parent directories inside the workspace as needed;
    - with [if_identity], the target must be an existing complete UTF-8 text
      file whose identity still matches, and is replaced atomically;
    - unchanged replacements succeed without producing edit evidence.

    Small textual edits, patch application, deletion, moves, and unchecked
    overwrites belong in separate tools.

    {b Staleness.} A complete-file identity is the shared freshness token across
    {!Read_file}, {!Write_file}, and {!Edit_file}: whenever one is supplied it
    is checked against the current complete-file identity before the tool acts,
    and a mismatch is reported rather than silently proceeding. Here the
    identity is folded into the mandatory [precondition]: a replace requires a
    matching [if_identity] and there is deliberately no unchecked-overwrite
    form. *)

val name : string
(** Stable tool name, ["write_file"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_max_file_bytes : int
(** Default maximum complete-file size accepted by {!run}.

    The bound applies to the supplied final contents and to existing targets
    that must be read to validate a replacement. It is a hard host-side ceiling,
    not a model-visible budget. *)

(** {1 Input} *)

module Input : sig
  type precondition =
    | Missing
    | Identity of Spice_digest.Identity.t
        (** Required target state before setting final contents. *)

  type t
  (** Typed write request.

      [Input.t] is the host-side request type. Build values with {!make}, or
      decode provider JSON with {!decode}. *)

  val make : path:string -> precondition:precondition -> contents:string -> t
  (** [make ~path ~precondition ~contents] sets [path] to complete UTF-8
      [contents] when [precondition] still holds.

      [path] is workspace-relative or an absolute path contained by the
      workspace. [contents] is the exact intended complete UTF-8 file contents.

      Raises [Invalid_argument] if [path] is empty or [contents] is not valid
      UTF-8 text. *)

  val path : t -> string
  (** [path t] is the requested path string. *)

  val contents : t -> string
  (** [contents t] is the requested complete UTF-8 file contents. *)

  val precondition : t -> precondition
  (** [precondition t] is the required target state before writing. *)

  val if_identity : t -> Spice_digest.Identity.t option
  (** [if_identity t] is the replacement identity, if any. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls.

      The model-visible fields are [path], [contents], and optional
      [if_identity]. Unknown fields are rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}.

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract. *)
end

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is the write permission request for [input].

    [Input.Missing] requests create access. [Input.Identity _] requests modify
    access. If the request path cannot be resolved in [workspace], the returned
    list is empty; {!run} reports the resolution failure as an invalid-input
    tool result. *)

(** {1 Output} *)

module Output : sig
  type t
  (** Typed output and write evidence. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path that was written or checked. *)

  val contents : t -> string
  (** [contents t] is the final complete UTF-8 file contents.

      This is host/session evidence. {!encode} keeps model-visible output
      compact and does not echo the file contents. *)

  val identity : t -> Spice_digest.Identity.t
  (** [identity t] is the identity of {!contents}. *)

  val receipt : t -> Receipt.t
  (** [receipt t] is the common successful mutation receipt.

      It is empty for unchanged replacements. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed write outputs to model-visible tool output.

      The projection reports the operation, path, final identity, stale check
      result, and created parent directories when relevant. It does not include
      complete file contents; host/session code should use {!contents} for cache
      updates. *)

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
(** [run ~fs ~workspace input] executes a typed write call and returns typed
    output.

    Paths are resolved through [workspace] and written through [fs]. Create
    operations create missing parent directories under the workspace as needed.
    Directories, non-regular files, symlinks, binary or invalid UTF-8 existing
    targets, stale identities, paths outside [workspace], and files above
    [max_file_bytes] return failed tool results.

    [max_file_bytes] defaults to {!default_max_file_bytes}. Parent directories
    created for a failed create are rolled back when the file creation itself
    fails. [cancelled] defaults to a function returning [false] and is checked
    before filesystem work begins.

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
