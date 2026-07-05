(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace UTF-8 text reader.

    [Read_file] observes one regular text file inside a workspace. Complete
    reads produce a content identity suitable for stale checks in {!Write_file}
    and {!Edit_file}; ranged or byte-capped reads produce partial evidence and,
    when possible, a structured continuation request.

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
    [if_identity] is optional and valid only for an unwindowed complete read
    (see {!Input.make}): a still-matching identity yields {!Output.Unchanged}
    instead of resending contents, and a stale identity returns current
    contents. It is kept out of the model schema unless [conditional_read] is
    set. *)

val name : string
(** Stable tool name, ["read_file"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_max_bytes : int
(** Default maximum number of selected UTF-8 bytes returned by {!run}.

    The bound limits returned contents, not necessarily the number of bytes the
    implementation observes while finding a requested line range. *)

val default_directory_limit : int
(** Default maximum number of directory entries returned by {!run} when the
    requested path is a directory and no [limit] is given. Files fall back to
    {!default_max_bytes} instead; a directory has no byte cap, so it bounds by
    entry count. *)

(** {1 Input} *)

module Range : sig
  type t = private
    | All
    | Lines of { start_line : int; max_lines : int option }
        (** Lines to read.

            [All] reads from the beginning until EOF or [max_bytes]. [Lines]
            starts at one-based [start_line] and returns at most [max_lines]
            lines when [max_lines] is present. *)

  val all : t
  (** [all] starts at the first line and reads until EOF or the byte budget. *)

  val lines : ?max_lines:int -> start_line:int -> unit -> t
  (** [lines ~start_line ?max_lines ()] reads a line range.

      [start_line] is one-based. [max_lines = None] reads from [start_line] to
      EOF or the byte budget.

      Raises [Invalid_argument] if [start_line < 1] or [max_lines < 1]. *)
end

module Input : sig
  (** The read request and its JSON tool contract. *)

  type t
  (** Typed read request.

      [Input.t] is the host-side request type. It can be built directly with
      {!make}, or decoded from provider JSON with {!decode}. *)

  val make :
    ?range:Range.t ->
    ?max_bytes:int ->
    ?if_identity:Spice_digest.Identity.t ->
    string ->
    t
  (** [make path] reads [path] in [range], bounded by [max_bytes].

      [path] is workspace-relative or an absolute path contained by the
      workspace. [range] defaults to {!Range.All}; [max_bytes] defaults to
      {!default_max_bytes} at execution time.

      [if_identity] asks for unchanged detection against a previous complete
      read. It is valid only for {!Range.All} without an explicit [max_bytes].

      Raises [Invalid_argument] if [path] is empty, [max_bytes < 0], or
      [if_identity] is combined with a ranged or explicit byte-budgeted read. *)

  val path : t -> string
  (** [path t] is the requested path string. *)

  val range : t -> Range.t
  (** [range t] is the requested read range. *)

  val max_bytes : t -> int option
  (** [max_bytes t] is the requested byte budget, if explicit. *)

  val if_identity : t -> Spice_digest.Identity.t option
  (** [if_identity t] is the requested complete-file unchanged check, if any. *)

  val contract : conditional_read:bool -> t Spice_tool.Input.t
  (** [contract ~conditional_read] is the JSON input contract for tool calls.

      If [conditional_read] is [false], [if_identity] is not part of the
      model-visible schema and is rejected by decoding as an unknown member. If
      [conditional_read] is [true], [if_identity] is accepted and decoded. *)

  val decode : conditional_read:bool -> Jsont.json -> (t, string) result
  (** [decode ~conditional_read json] decodes [json] with
      {!contract}[ ~conditional_read].

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract. *)
end

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is the read permission request for [input].

    If the request path cannot be resolved in [workspace], the returned list is
    empty; {!run} reports the resolution failure as an invalid-input tool
    result. *)

(** {1 Output} *)

module Entry : sig
  type kind =
    | Regular_file
    | Directory
    | Symlink
    | Other
        (** Directory entry kind. Child symlinks are reported as [Symlink] and
            are not followed for classification. *)

  type t = private { path : Spice_workspace.Path.t; name : string; kind : kind }
  (** A single directory child: its workspace path, basename, and kind. *)
end

module Fingerprint : sig
  type t
  (** Weak freshness evidence for repeated same-range reads.

      Fingerprints are cheap filesystem observations. They are useful for
      suppressing redundant reads, but they are not complete-file identities. *)

  val size : t -> int64
  (** [size t] is the observed file size in bytes. *)

  val mtime_ns_approx : t -> int64 option
  (** [mtime_ns_approx t] is the observed modification time normalized to
      nanoseconds when available.

      The value is approximate because some filesystems and Eio backends expose
      modification time as a floating-point timestamp. *)
end

module Output : sig
  (** Read output and its model-visible projection. *)

  type line_count =
    | Exact of int
    | Lower_bound of int
    | Unknown
        (** Total-line count precision.

            [Exact n] means EOF was reached. [Lower_bound n] means at least [n]
            logical lines were observed before the range or byte bound stopped
            the read. [Unknown] is reserved for backends that cannot count
            reliably. *)

  type partial_reason =
    | Ranged
    | Byte_capped
    | Ranged_and_byte_capped
        (** Why the observation is not a complete-file observation. *)

  type partial = { reason : partial_reason; next : Input.t option }
  (** Structured continuation evidence for partial reads.

      [next] is present only when the same range shape can make progress. Byte
      caps without a line-range continuation have [next = None]. *)

  type status =
    | Complete of Spice_digest.Identity.t
    | Partial of partial
        (** File coverage status for reads that returned contents.

            [Unchanged] is not a coverage status because unchanged conditional
            reads do not carry contents. It is represented as a separate
            {!type:t} case. *)

  type read = private {
    read_path : Spice_workspace.Path.t;
    contents : string;
    start_line : int;
    returned_lines : int;
    total_lines : line_count;
    status : status;
    read_fingerprint : Fingerprint.t option;
  }
  (** Read evidence for a file observation that returned contents.

      [contents] is exact returned UTF-8 text after byte-cap repair. Text
      rendering may truncate long display lines, but this field is not
      display-truncated. *)

  type unchanged = private {
    unchanged_path : Spice_workspace.Path.t;
    identity : Spice_digest.Identity.t;
    unchanged_fingerprint : Fingerprint.t option;
  }
  (** Conditional-read evidence for an unchanged complete file. *)

  type listing = private {
    listing_path : Spice_workspace.Path.t;
    entries : Entry.t list;
    listing_offset : int;  (** effective one-based first entry *)
    listing_limit : int;  (** effective entry-count budget *)
    total_entries : int;  (** exact count after VCS filtering *)
    listing_complete : bool;  (** false iff a filtered entry is unreturned *)
    listing_next : Input.t option;  (** progress-making continuation, if any *)
  }
  (** Directory observation evidence. [entries] is the sorted, VCS-filtered,
      paged window; [List.length entries] is the returned count. [listing_next]
      is [Some] only when the page is incomplete and repeating would make
      progress. A listing carries no identity or fingerprint. *)

  type t =
    | Read of read
    | Unchanged of unchanged
    | Listing of listing
        (** Typed output and read evidence.

            [Unchanged] does not carry [contents], so callers cannot confuse an
            unchanged conditional read with an empty file. [Listing] is a paged
            directory observation carrying entry evidence instead of contents.
        *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path that was observed (the file for a
      [Read]/[Unchanged], the directory for a [Listing]). *)

  val identity : t -> Spice_digest.Identity.t option
  (** [identity t] is the complete-file identity for complete and unchanged
      reads, and [None] for partial reads and directory listings. *)

  val fingerprint : t -> Fingerprint.t option
  (** [fingerprint t] is weak same-file freshness evidence for file reads when
      the backend reported it, and [None] for directory listings. *)

  type render
  (** Model-visible text rendering policy. *)

  val numbered : render
  (** [numbered] prefixes each returned line with its line number. *)

  val anchored : ?source:Anchor.Source.t -> unit -> render
  (** [anchored ?source ()] prefixes each returned line with its line number and
      an edit-targeting anchor.

      [source] defaults to {!Anchor.Source.deterministic}. *)

  val encode : ?render:render -> t Spice_tool.Output.encoder
  (** [encode ?render] projects typed read outputs to model-visible tool output.

      For [Read _], the JSON projection preserves [contents] exactly. For
      [Unchanged _], it reports identity evidence without a synthetic empty
      [contents] field. For [Listing _], the JSON projection is a
      ["kind":"listing"] object carrying entries, counts, status, and the [next]
      continuation, and the text projection is a one-entry-per-line block with
      kind suffixes and a [next:] continuation hint. The text projection for
      [Read _] is a compact display format with line numbers, partial-read
      continuation hints, optional edit anchors, and bounded per-line display so
      pathological long lines do not dominate the transcript.

      [render] governs file line rendering only; it is ignored for listings.
      [render] defaults to {!numbered}. Stateful sessions can supply their own
      anchor source with {!anchored} without changing read-file semantics. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool's {!encode}.

      Outputs restored from durable session JSON are decoded from their
      structured projection when the in-memory typed witness is no longer
      present. *)
end

(** {1 Execution} *)

val run :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~fs ~workspace input] executes a typed read call and returns typed
    output.

    Paths are resolved through [workspace] and stat'd once following symlinks. A
    regular-file target returns {!Output.Read}/{!Output.Unchanged}; a directory
    target returns a paged {!Output.Listing}. Non-regular special files (fifos,
    sockets, devices), symlinks that resolve outside [workspace], likely binary
    files, invalid UTF-8 text, and paths outside [workspace] return failed tool
    results. Missing paths may include same-directory spelling suggestions in
    the diagnostic. Symlinks whose resolved target remains inside the workspace
    are followed for both files and directories. Successful complete reads carry
    [identity]; ranged or byte-capped reads and directory listings do not.
    Conditional reads return {!Output.Unchanged} only when [if_identity] matches
    the newly observed complete-file identity; stale identities still return
    current contents. [if_identity] on a directory target is rejected;
    [max_bytes] is ignored for directory targets.

    [cancelled] defaults to a function returning [false] and is polled while
    reading. *)

(** {1 Adapter} *)

val tool :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?conditional_read:bool ->
  ?render:Output.render ->
  unit ->
  Spice_tool.t
(** [tool ~fs ~workspace ()] is the erased {!Spice_tool.t} adapter.

    [conditional_read] defaults to [false] and is passed to {!Input.contract}.
    [render] defaults to {!Output.numbered}. *)
