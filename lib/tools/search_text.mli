(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace text search.

    [Search_text] searches UTF-8 text files inside a workspace. It is a bounded,
    typed content-search tool, not a shell wrapper: ripgrep or another engine
    may be used by the implementation, but the public contract is
    workspace-relative evidence.

    The typed surface is the primary API for host/session code:

    - build or decode an {!Input.t};
    - inspect {!permissions};
    - execute with {!run};
    - update session state from typed {!Output.t};
    - project with {!Output.encode} for model-visible transcripts.

    {!tool} is the erased {!Spice_tool.t} adapter for generic provider dispatch.
*)

val name : string
(** Stable tool name, ["search_text"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_limit : int
(** Default maximum number of result entries returned by {!run}.

    A result entry is a matching file in {!Input.Files} and {!Input.Count} mode,
    and a matching line in {!Input.Matches} mode. Context lines do not count
    against the limit. *)

val max_limit : int
(** Maximum accepted explicit result limit. *)

val max_context_lines : int
(** Maximum accepted symmetric context line count for {!Input.Matches} mode. *)

(** {1 Input} *)

module Input : sig
  type case =
    | Sensitive
    | Insensitive
        (** Pattern case-sensitivity policy.

            [Sensitive] is the default. [Insensitive] performs case-insensitive
            regular-expression matching. *)

  type mode =
    | Files
    | Count
    | Matches
        (** Search result mode.

            [Files] returns matching file paths only and is the default. [Count]
            returns one entry per matching file with its matching-line count.
            [Matches] returns matching lines with optional surrounding context.
        *)

  type t
  (** Typed text-search request.

      [Input.t] is the host-side request type. Build values directly with
      {!make}, or decode provider JSON with {!decode}. *)

  val make :
    ?paths:string list ->
    ?glob:string ->
    ?mode:mode ->
    ?case:case ->
    ?context_lines:int ->
    ?offset:int ->
    ?limit:int ->
    string ->
    t
  (** [make pattern] searches for [pattern].

      [pattern] is a non-empty ripgrep/Rust regular expression. [paths] are
      workspace-relative or workspace-contained absolute files or directories;
      absent [paths] means the workspace root. [glob], when present, is passed
      to ripgrep as one file glob such as ["*.ml"] or ["**/*.ts"]. Ordinary
      dotfiles are included in search traversal; protected VCS metadata child
      directories are still excluded from recursive searches.

      [mode] defaults to {!Files}. [case] defaults to {!Sensitive}.
      [context_lines] is valid only with {!Matches} mode and defaults to [0].
      [offset] is the one-based first result entry to return and defaults to [1]
      at execution time. [limit] is the maximum number of result entries and
      defaults to {!default_limit} at execution time.

      Raises [Invalid_argument] if [pattern] is empty, [pattern], any path, or
      [glob] contains NUL, [paths] is explicitly empty or contains an empty
      path, [context_lines] is supplied outside {!Matches} mode, [context_lines]
      is outside \[[0];[max_context_lines]\], [offset < 1], [limit < 1], or
      [limit > max_limit].

      Regular-expression syntax is validated by the search engine when the
      request is executed. *)

  val pattern : t -> string
  (** [pattern t] is the requested ripgrep/Rust regular expression. *)

  val paths : t -> string list option
  (** [paths t] are the requested search roots, if explicit.

      [None] means the workspace root. *)

  val glob : t -> string option
  (** [glob t] is the requested file glob restriction, if any. *)

  val mode : t -> mode
  (** [mode t] is the requested result mode. *)

  val case : t -> case
  (** [case t] is the requested pattern case-sensitivity policy. *)

  val context_lines : t -> int option
  (** [context_lines t] is the requested symmetric context count, if explicit.

      It is present only for {!Matches} requests. *)

  val offset : t -> int option
  (** [offset t] is the requested one-based first result entry, if explicit. *)

  val limit : t -> int option
  (** [limit t] is the requested maximum result entry count, if explicit. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls.

      The model-visible fields are [pattern], optional [paths], optional [glob],
      optional [mode], optional [case_insensitive], optional [context_lines],
      optional [offset], and optional [limit]. Unknown fields are rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}.

      Errors with the input decoder diagnostic when [json] does not satisfy the
      input contract. *)
end

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] are the read permission requests for [input].

    One request is produced for each root that can be resolved lexically in
    [workspace]. This is permission evidence, not full validation: {!run} still
    requires every requested root to exist as a non-symlink regular file or
    directory inside [workspace]. If no requested root can be resolved, the
    returned list is empty and {!run} reports the resolution failure as an
    invalid-input tool result. *)

(** {1 Output} *)

module Output : sig
  type total =
    | Exact of int
    | Lower_bound of int
    | Unknown
        (** Total count precision.

            {!total_results} counts matching files for {!Input.Files} and
            {!Input.Count}, and matching lines for {!Input.Matches}. Count-mode
            outputs also expose total matching lines through
            {!type:count_result}. *)

  type partial_reason =
    | Limit
        (** Why an observation is not complete.

            [Limit] means more result entries are available after the returned
            page. *)

  type status =
    | Complete
    | Partial of partial_reason
        (** Search coverage status.

            [Complete] means the search reached the end of the filtered result
            set. [Partial _] means the observation is usable but incomplete. Use
            {!next} for a structured continuation request when one exists. *)

  type count = private {
    count_path : Spice_workspace.Path.t;
    matching_lines : int;
  }
  (** Per-file matching-line count evidence. *)

  type line_kind =
    | Match
    | Context  (** Line role in a {!Input.Matches} result. *)

  type skipped_reason =
    | Binary
    | Invalid_utf8
        (** Why a matching file was skipped.

            Search skips files whose matching evidence cannot be represented as
            bounded UTF-8 text. *)

  type skipped = private {
    skipped_path : Spice_workspace.Path.t;
    reason : skipped_reason;
  }
  (** File skipped while collecting search evidence.

      Skipped files do not contribute entries to {!result} or {!total_results}.
  *)

  type line = private {
    number : int;
    text : string;
    kind : line_kind;
    truncated : bool;
    anchor : Anchor.t option;
  }
  (** Returned line evidence.

      [number] is one-based. [text] is valid UTF-8 and may be a bounded prefix
      of the source line when [truncated] is [true]. [anchor], when present, is
      edit-targeting evidence from the configured {!Anchor.Source.t}. *)

  type span = private { span_path : Spice_workspace.Path.t; lines : line list }
  (** Contiguous returned lines from one file.

      A span contains at least one [Match] line. Context lines may be present
      before or after the matching lines when requested by
      {!Input.context_lines}. *)

  type count_result = private {
    files : count list;
    total_matching_lines : total;
  }
  (** Count-mode search evidence.

      [files] are the returned matching-file entries for the current result
      page. [total_matching_lines] is the total matching-line precision across
      all searched files, not just the returned page. *)

  type result =
    | Files of Spice_workspace.Path.t list
    | Count of count_result
    | Matches of span list
        (** Mode-specific search evidence.

            All paths are resolved workspace paths. Model-visible rendering uses
            workspace-relative path text. *)

  type t
  (** Typed text-search observation. *)

  val pattern : t -> string
  (** [pattern t] is the searched ripgrep/Rust regular expression. *)

  val roots : t -> Spice_workspace.Path.t list
  (** [roots t] are the resolved search roots. *)

  val glob : t -> string option
  (** [glob t] is the file glob restriction used for the search, if any. *)

  val mode : t -> Input.mode
  (** [mode t] is the result mode used for the search. *)

  val case : t -> Input.case
  (** [case t] is the pattern case-sensitivity policy used for the search. *)

  val context_lines : t -> int
  (** [context_lines t] is the effective symmetric context count.

      It is [0] unless {!mode}[ t] is {!Input.Matches}. *)

  val offset : t -> int
  (** [offset t] is the effective one-based first result entry. *)

  val limit : t -> int
  (** [limit t] is the effective maximum result entry count. *)

  val returned_results : t -> int
  (** [returned_results t] is the number of returned result entries.

      Context lines do not count as result entries. *)

  val total_results : t -> total
  (** [total_results t] is the total result count precision for [t]. *)

  val result : t -> result
  (** [result t] is the mode-specific search evidence. *)

  val status : t -> status
  (** [status t] is the search coverage status. *)

  val next : t -> Input.t option
  (** [next t] is the structured continuation request, if one exists.

      [next t] is [Some input] only when a continuation can make progress with
      the same pattern, roots, glob, mode, case policy, context, and limit. It
      is [None] for complete outputs and for partial outputs that stopped
      because no reliable continuation can be formed. *)

  val has_more : t -> bool
  (** [has_more t] is [true] iff {!status}[ t] is [Partial _]. *)

  val skipped : t -> skipped list
  (** [skipped t] are files that ripgrep reported as matching but whose match
      evidence was binary or invalid UTF-8 and therefore omitted from {!result}.
  *)

  type render
  (** Model-visible text rendering policy. *)

  val plain : render
  (** [plain] renders paths, counts, and line numbers. *)

  val anchored : ?source:Anchor.Source.t -> unit -> render
  (** [anchored ?source ()] renders line anchors in {!Input.Matches} output.

      [source] defaults to {!Anchor.Source.deterministic}. *)

  val encode : ?render:render -> t Spice_tool.Output.encoder
  (** [encode ?render] projects typed search outputs to model-visible tool
      output.

      The JSON projection preserves the structured result, counts, total counts,
      status, and continuation evidence. The text projection is compact: file
      paths for {!Input.Files}, path/count rows for {!Input.Count}, and grouped
      line-numbered spans for {!Input.Matches}. Long returned lines may be
      display-truncated independently of the typed [line.text] value; the
      [line.truncated] flag records typed truncation caused by the per-line
      evidence bound.

      [render] defaults to {!plain}. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool's {!encode}. *)
end

(** {1 Execution} *)

val run :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?anchors:Anchor.Source.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~fs ~workspace input] executes a typed text-search call and returns
    typed output.

    Paths are resolved through [workspace] and observed through [fs]. Requested
    roots must be existing non-symlink regular files or directories inside the
    workspace. The implementation requires [rg] in [PATH], invokes it with an
    argument vector rather than through a shell, and disables user ripgrep
    config for deterministic tool semantics. Standard ripgrep ignore files are
    honored without requiring a Git repository. Protected VCS metadata child
    directories such as [.git], [.svn], [.hg], [.bzr], [.jj], and [.sl] are
    excluded from recursive search results. Ordinary dotfiles are searchable
    unless ignored. Files that cannot be safely treated as bounded line-oriented
    UTF-8 text are skipped by search rather than reported as failed reads.

    Results are ordered deterministically by workspace-relative path, then by
    line number for {!Input.Matches}. [anchors] defaults to
    {!Anchor.Source.deterministic}; future session-owned sources can reconcile
    anchors across edits without changing this tool. [cancelled] defaults to a
    function returning [false] and is checked before filesystem work begins and
    while collecting results. *)

(** {1 Adapter} *)

val tool :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?render:Output.render ->
  unit ->
  Spice_tool.t
(** [tool ~fs ~workspace ()] is the erased {!Spice_tool.t} adapter.

    [render] defaults to {!Output.plain}. *)
