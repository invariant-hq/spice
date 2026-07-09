(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Anchored workspace line editor.

    [Edit_lines] applies a batch of anchored line edits to one existing UTF-8
    text file inside a workspace. It is the flag-gated companion of
    {!Edit_file}: edits name lines through opaque anchors rendered by
    {!Read_file} and {!Search_text} instead of exact replacement text, and a
    whole batch lowers to one {!Spice_edit.rewrite}, so locking, revalidation,
    and complete-file stale rejection are identical.

    Anchors resolve through a caller-supplied {!Anchor.Resolver.t}. Batches are
    all-or-nothing: one unresolvable anchor fails the whole call and mutates
    nothing.

    The typed surface is the primary API for host/session code:

    - build or decode an {!Input.t};
    - inspect {!permissions};
    - execute with {!run};
    - update session state from typed {!Output.t};
    - project with {!Output.encode} for model-visible transcripts.

    {!tool} is the erased {!Spice_tool.t} adapter for generic provider dispatch.
*)

val name : string
(** Stable tool name, ["edit_lines"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_max_file_bytes : int
(** Default maximum complete-file size accepted by {!run}.

    The bound applies to the existing target contents and to the assembled final
    contents before mutation. It is a hard host-side ceiling, not a
    model-visible budget. *)

(** {1 Input} *)

module Input : sig
  module Range : sig
    (** Line ranges named by anchors. *)

    type t
    (** The type for a line range: a single anchored line, or an inclusive span
        between two anchors. *)

    val line : Anchor.t -> t
    (** [line anchor] is the single line named by [anchor].

        Raises [Invalid_argument] if [anchor] is empty or not valid UTF-8. *)

    val between : Anchor.t -> Anchor.t -> t
    (** [between first last] is the inclusive line range from [first] to [last].

        Raises [Invalid_argument] if [first] or [last] is empty or not valid
        UTF-8. *)
  end

  module Edit : sig
    (** Anchored edit operations. *)

    type t
    (** One anchored edit. *)

    val replace : Range.t -> text:string -> t
    (** [replace range ~text] replaces [range] with [text]. Empty [text] deletes
        the range. Non-empty [text] is split on ['\n'] into logical lines; a
        trailing ['\n'] denotes a final empty line, not merely a line
        terminator.

        Raises [Invalid_argument] if [text] is not valid UTF-8. *)

    val insert_before : Anchor.t -> text:string -> t
    (** [insert_before anchor ~text] inserts [text] before [anchor]. [text] is
        split on ['\n'] into logical lines; a trailing ['\n'] denotes a final
        empty line. Empty [text] inserts no lines.

        Raises [Invalid_argument] if [anchor] is empty or [text] is not valid
        UTF-8. *)

    val insert_after : Anchor.t -> text:string -> t
    (** [insert_after anchor ~text] inserts [text] after [anchor]. [text] is
        split on ['\n'] into logical lines; a trailing ['\n'] denotes a final
        empty line. Empty [text] inserts no lines.

        Raises [Invalid_argument] if [anchor] is empty or [text] is not valid
        UTF-8. *)

    val text : t -> string
    (** [text t] is the replacement or inserted text. *)
  end

  type t
  (** Typed anchored-edit request for one file. *)

  val make : path:string -> edits:Edit.t list -> unit -> t
  (** [make ~path ~edits ()] edits [path] with [edits].

      [path] is workspace-relative or an absolute path contained by the
      workspace. These constructors take already-typed OCaml values and check
      only programmer-local invariants; provider input is validated at the
      {!decode} boundary instead.

      Raises [Invalid_argument] if [path] is empty or [edits] is empty. *)

  val path : t -> string
  (** [path t] is the requested path string. *)

  val edits : t -> Edit.t list
  (** [edits t] are the requested edits in input order. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls.

      The model-visible fields are [path] and [edits], where each edit has [op],
      [anchor], optional [end_anchor], and [text]. [replace] requires
      [end_anchor]; use the same value as [anchor] for a single-line replace.
      [insert_before] and [insert_after] reject [end_anchor]. Unknown fields are
      rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}.

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract. *)
end

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is the modify permission request for [input].

    Planned-change evidence derives only from the decoded input: the provided
    anchor line texts stand for replaced content and the edit texts for new
    content. If the request path cannot be resolved in [workspace], the returned
    list is empty; {!run} reports the resolution failure as an invalid-input
    tool result. *)

(** {1 Output} *)

module Output : sig
  type t
  (** Typed output and edit evidence. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path that was edited or checked. *)

  val edits : t -> int
  (** [edits t] is the number of anchored edits in the applied batch. *)

  val identity : t -> Spice_digest.Identity.t
  (** [identity t] is the identity of [after_contents t]. *)

  val before_contents : t -> string
  (** [before_contents t] is the complete UTF-8 file contents observed before
      the batch was assembled.

      This is host/session evidence. {!encode} keeps model-visible output
      compact and does not echo the complete file. *)

  val after_contents : t -> string
  (** [after_contents t] is the complete UTF-8 file contents after the batch.

      For [Unchanged _] outputs this equals {!before_contents}. *)

  val receipt : t -> Receipt.t
  (** [receipt t] is the common successful mutation receipt.

      It is empty for unchanged outputs. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed outputs to model-visible tool output.

      The projection reports the path, status, edit count, and final identity.
      It does not include complete before or after contents; host/session code
      should use {!before_contents} and {!after_contents} for cache and audit
      state. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool's {!encode}. *)
end

(** {1 Execution} *)

val run :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  resolver:Anchor.Resolver.t ->
  ?max_file_bytes:int ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~fs ~workspace ~resolver input] executes a typed anchored-edit call and
    returns typed output.

    Paths are resolved through [workspace] and edited through [fs]. The target
    must be an existing regular UTF-8 text file inside the workspace. The file's
    current logical lines are reconciled into [resolver] before resolution, so
    anchors from earlier reads survive intervening edits to other lines.

    Every edit resolves before any mutation. The batch fails as a whole — a
    [`Stale] failure carrying expected-versus-provided line text and reread
    guidance — when any anchor is unknown or names a line whose text differs
    from the provided text. Malformed anchors, inverted replace ranges, and
    overlapping edits fail as invalid input. Valid batches apply bottom-up over
    the current lines; if multiple insertions target the same gap, their input
    order is preserved. Untouched lines keep their exact bytes, and inserted
    lines use the file's dominant line ending.

    The final complete contents are lowered to {!Spice_edit.rewrite} and applied
    through {!Spice_edit.apply}, so concurrent changes after assembly are
    rejected before mutation starts. After a successful apply the resolver is
    reconciled with the new lines.

    [max_file_bytes] defaults to {!default_max_file_bytes}. [cancelled] defaults
    to a function returning [false] and is checked before filesystem mutation
    begins.

    Raises [Invalid_argument] if [max_file_bytes < 0]. *)

(** {1 Adapter} *)

val tool :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  resolver:Anchor.Resolver.t ->
  ?max_file_bytes:int ->
  unit ->
  Spice_tool.t
(** [tool ~fs ~workspace ~resolver ()] is the erased {!Spice_tool.t} adapter.

    [max_file_bytes] defaults to {!default_max_file_bytes}. *)
