(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Recursive workspace file discovery by path glob.

    [Glob] finds regular files in a workspace by matching workspace-relative
    paths with a ripgrep glob pattern. It is a recursive discovery tool, not an
    exact directory lister and not a content-search tool: use {!Read_file} for
    immediate directory inspection and {!Search_text} for text search.

    The typed surface is the primary API for host/session code:

    - build or decode an {!Input.t};
    - inspect {!permissions};
    - execute with {!run};
    - update session state from typed {!Output.t};
    - project with {!Output.encode} for model-visible transcripts.

    {!tool} is the erased {!Spice_tool.t} adapter for generic provider dispatch.
*)

val name : string
(** Stable tool name, ["glob"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_limit : int
(** Default maximum number of file paths returned by {!run}. *)

val max_limit : int
(** Maximum accepted explicit result limit. *)

(** {1 Input} *)

module Input : sig
  type sort =
    | Path
    | Modified
        (** Result ordering policy.

            [Path] is deterministic workspace-relative path order and is the
            default. [Modified] sorts by descending observed modification time,
            with workspace-relative path as the stable tie-breaker. *)

  type t
  (** Typed glob request.

      [Input.t] is the host-side request type. Build values directly with
      {!make}, or decode provider JSON with {!decode}. *)

  val make :
    ?path:string -> ?offset:int -> ?limit:int -> ?sort:sort -> string -> t
  (** [make pattern] finds files matching [pattern].

      [pattern] is a non-empty ripgrep glob pattern such as ["**/*.ml"] or
      ["**/*.{ts,tsx}"]. [path], when present, is a workspace-relative or
      workspace-contained absolute directory root. Absent [path] means the
      workspace root. [offset] is the one-based first file to return and
      defaults to [1] at execution time. [limit] is the maximum number of file
      paths to return and defaults to {!default_limit} at execution time. [sort]
      defaults to {!Path}.

      Raises [Invalid_argument] if [pattern] is empty, [pattern] or [path]
      contains NUL, [path] is explicitly empty, [offset < 1], [limit < 1], or
      [limit > max_limit].

      Glob syntax and ignore-file effects are validated by the discovery engine
      when the request is executed. *)

  val pattern : t -> string
  (** [pattern t] is the requested ripgrep glob pattern. *)

  val path : t -> string option
  (** [path t] is the requested search root, if explicit.

      [None] means the workspace root. *)

  val offset : t -> int option
  (** [offset t] is the requested one-based first file, if explicit. *)

  val limit : t -> int option
  (** [limit t] is the requested maximum returned file count, if explicit. *)

  val sort : t -> sort
  (** [sort t] is the requested result ordering policy. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls.

      The model-visible fields are [pattern], optional [path], optional
      [offset], optional [limit], and optional [sort]. [sort] accepts ["path"]
      and ["modified"]. Unknown fields are rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}.

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract. *)
end

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is the read permission request for the
    requested discovery root.

    If the requested root cannot be resolved in [workspace], the returned list
    is empty; {!run} reports the resolution failure as an invalid-input tool
    result. The pattern is not filesystem authority. It is evidence for the
    prompt and transcript; discovery authority comes from the resolved root. *)

(** {1 Output} *)

module Output : sig
  type partial_reason =
    | Limit
        (** Why an observation is not complete.

            [Limit] means more matching files are available after the returned
            page. *)

  type status =
    | Complete
    | Partial of partial_reason
        (** Discovery coverage status.

            [Complete] means discovery reached the end of the filtered result
            set. [Partial _] means the observation is usable but incomplete. Use
            {!next} for a structured continuation request when one exists. *)

  type t
  (** Typed glob observation. *)

  val pattern : t -> string
  (** [pattern t] is the ripgrep glob pattern used for discovery. *)

  val root : t -> Spice_workspace.Path.t
  (** [root t] is the resolved workspace directory root that was searched. *)

  val sort : t -> Input.sort
  (** [sort t] is the effective result ordering policy. *)

  val files : t -> Spice_workspace.Path.t list
  (** [files t] are the returned matching regular-file paths.

      Paths are resolved workspace paths. Model-visible rendering uses
      workspace-relative path text. *)

  val offset : t -> int
  (** [offset t] is the effective one-based first file. *)

  val limit : t -> int
  (** [limit t] is the effective maximum returned file count. *)

  val returned_files : t -> int
  (** [returned_files t] is the number of paths in {!files}[ t]. *)

  val total_files : t -> int
  (** [total_files t] is the exact number of matching files after discovery
      filtering. *)

  val status : t -> status
  (** [status t] is the discovery coverage status. *)

  val next : t -> Input.t option
  (** [next t] is the structured continuation request, if one exists.

      [next t] is [Some input] only when {!status}[ t] is [Partial _] and the
      continuation can make progress with the same pattern, root, sort, and
      limit. It is [None] for complete outputs. *)

  val has_more : t -> bool
  (** [has_more t] is [true] iff {!status}[ t] is [Partial _]. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed glob outputs to model-visible tool output.

      The JSON projection preserves the pattern, root, sort, files, counts,
      status, and structured continuation evidence. The text projection is a
      compact path-per-line listing with a copy-pasteable continuation hint
      using the input schema fields [pattern], [path], [offset], [limit], and
      [sort] when available. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool's {!encode}. *)
end

(** {1 Execution} *)

val run :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace input] executes a typed glob call and returns typed
    output.

    Paths are resolved through [workspace] and observed through [fs]. The
    requested root must be an existing non-symlink directory inside the
    workspace. File roots, symlink roots, missing paths, paths outside
    [workspace], invalid glob patterns, missing [rg], process failures, and
    filesystem observation errors return failed tool results.

    Recursive discovery uses the same policy as {!Search_text}: user ripgrep
    config is disabled, standard ripgrep ignore files are honored without
    requiring a Git repository, ordinary dotfiles are included unless ignored,
    and protected VCS metadata child directories such as [.git], [.svn], [.hg],
    [.bzr], [.jj], and [.sl] are excluded. No broad dependency or build
    directory ignores are added by default.

    [cancelled] defaults to a function returning [false] and is checked before
    filesystem work begins and while collecting results. *)

(** {1 Adapter} *)

val tool :
  sandbox:Spice_sandbox.t ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ()] is the erased {!Spice_tool.t} adapter. *)
