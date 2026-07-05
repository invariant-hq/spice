(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Request-scoped workspace context.

    A context is a snapshot of everything the host will tell the model about the
    workspace, together with the facts of where every byte came from and why
    anything was left out. One {!load} reads the filesystem; every other
    operation is a pure view of the snapshot, so [context show],
    [context prompt], execution preludes, and JSON output cannot disagree.

    Requested policy — enablement, compatibility, the byte budget — lives on
    {!Config} with its origins. The snapshot carries only discovered and built
    facts. Snapshots are never persisted: every request recomputes from disk. *)

(** {1:sources Sources} *)

module Source : sig
  (** Instruction sources and their statuses. *)

  type kind =
    | Global  (** [AGENTS.md] in the user config directory. *)
    | Project  (** [AGENTS.md] under the workspace root. *)
    | Local_override  (** [AGENTS.override.md] under the workspace root. *)
    | Compatibility  (** [CLAUDE.md] under the workspace root. *)

  type content = {
    bytes : int;  (** Size of the original file bytes. *)
    digest : string;  (** Digest of the original file bytes. *)
    included_bytes : int;  (** Size of the projected text. *)
    included_digest : string;  (** Digest of the projected text. *)
    omitted_bytes : int;  (** Bytes omitted by the budget; [0] if none. *)
    utf8_repaired : bool;  (** Invalid UTF-8 was replaced with U+FFFD. *)
  }
  (** The type for read facts. Only read sources have content facts. *)

  type status =
    | Active of content  (** The source contributes projected text. *)
    | Shadowed of { by : Spice_path.Abs.t }
        (** A higher-precedence candidate in the same directory won. *)
    | Disabled of [ `Instructions | `Project_instructions | `Compatibility ]
        (** Enablement excluded the source before any content read. *)
    | Not_activated
        (** A nested [AGENTS.md] below the run cwd; reported by the {!load}
            [nested_scan] audit only, never read or projected. *)
    | Skipped of
        [ `Not_file
        | `Outside_workspace
        | `Unreadable of string
        | `Empty
        | `Budget_exhausted ]
        (** Observation or projection excluded the source. *)

  type t
  (** The type for discovered instruction sources. A source's identity is its
      normalized lexical absolute path; no path is ever canonicalized. *)

  val path : t -> Spice_path.Abs.t
  (** [path source] is [source]'s normalized absolute path. *)

  val display_path : t -> string
  (** [display_path source] is [source]'s display text: root-relative for
      project-side sources, absolute for global sources. *)

  val kind : t -> kind
  (** [kind source] is [source]'s kind. *)

  val status : t -> status
  (** [status source] is what happened to [source]. *)

  val kind_string : kind -> string
  (** [kind_string kind] is the stable kind spelling: ["global"], ["project"],
      ["local_override"], or ["compatibility"]. *)

  val state_string : status -> string
  (** [state_string status] is the stable state spelling: ["active"],
      ["shadowed"], ["disabled"], ["not_activated"], or ["skipped"]. *)

  val reason_string : status -> string option
  (** [reason_string status] is the stable reason spelling for inactive
      statuses, for example ["shadowed_by_agents"] or
      ["compatibility_disabled"]; it is [None] for {!constructor:Active}. *)

  val to_json : t -> Jsont.json
  (** [to_json source] is [source] as a JSON object with [path], [display_path],
      [kind], [state], [reason], and content facts when {!constructor:Active}.

      This mirrors the candidate/status vocabulary of {!Skills.Skill}: a third
      discovery surface should copy this shape rather than reinvent it. *)
end

(** {1:loading Loading} *)

type t
(** The type for loaded workspace context.

    Values are snapshots. Later file changes do not affect an existing value. *)

val load :
  stdenv:Eio_unix.Stdenv.base ->
  ?nested_scan:bool ->
  Config.t ->
  (t, Host.Error.t) result
(** [load ~stdenv config] reads the filesystem once and snapshots the workspace
    context for [config].

    The workspace root is the nearest ancestor of [Config.cwd] containing
    [.git]; without one, only the cwd is considered. Each directory from the
    root down to the cwd contributes at most one active instruction file, chosen
    from [AGENTS.override.md], then [AGENTS.md], then [CLAUDE.md], by {!Config}
    enablement. Candidates are observed through workspace-contained filesystem
    checks: a symlinked candidate is followed and must resolve inside the root.
    Project instruction text is read only for active candidates and only when
    project instructions are enabled, against the configured byte budget. Global
    instructions come from [AGENTS.md] in the user config directory and are not
    budgeted.

    [nested_scan] (default [false]) additionally records [AGENTS.md] files in
    directories strictly below the cwd as {!Source.Not_activated} audit sources.
    The scan never reads file contents and never affects the projection; it
    skips VCS metadata directories, does not follow directory symlinks, and
    stops at a fixed visited-directory cap, recording
    {!nested_scan}[ = `Capped].

    Content-level problems are never errors; they are source statuses. The only
    error is {!Host.Error.Workspace}, when [Config.cwd] cannot be resolved as
    portable absolute path syntax. *)

(** {1:facts Discovered facts} *)

val cwd : t -> Spice_path.Abs.t
(** [cwd t] is the resolved run directory: [Config.cwd] made absolute lexically
    against the process working directory when it was relative. Symlinks are not
    resolved; the configured spelling is preserved when already absolute. *)

val eio_cwd :
  stdenv:Eio_unix.Stdenv.base ->
  ?override:Spice_path.Abs.t ->
  t ->
  Eio.Fs.dir_ty Eio.Path.t
(** [eio_cwd ~stdenv t] is [t]'s {!cwd} as an Eio path for filesystem-bearing
    tools and the Dune build watcher.

    When {!cwd} lies within the process working directory it is reached through
    the process-restricted [Eio.Stdenv.cwd] capability; otherwise it falls back
    to the unrestricted [Eio.Stdenv.fs] rooted at [override] (when supplied,
    e.g. a [--cwd] override) or at the absolute {!cwd}. Symlinks are not
    resolved. *)

val root : t -> Spice_path.Abs.t
(** [root t] is the selected workspace root. *)

val root_marker : t -> string option
(** [root_marker t] is [Some ".git"] when the root was selected by a marker and
    [None] when discovery fell back to the cwd. *)

val budget_used : t -> int
(** [budget_used t] is the number of original project instruction bytes consumed
    from the configured budget. *)

val nested_scan : t -> [ `Off | `Complete | `Capped ]
(** [nested_scan t] is the nested-scan outcome: [`Off] when not requested,
    [`Complete] when the walk finished, [`Capped] when it stopped at the
    visited-directory cap. *)

val sources : t -> Source.t list
(** [sources t] are the discovered sources in deterministic order: global, then
    per directory from root to cwd in candidate precedence order, then
    nested-scan results in lexicographic order. *)

(** {1:projection Projection} *)

val projection_messages : t -> Spice_llm.Message.t list
(** [projection_messages t] are the exact model-visible context messages for the
    next normal request, in provider order. The list contains only prelude
    messages accepted by {!Spice_llm.Request.Prelude.make}. *)

val projection_texts : t -> string list
(** [projection_texts t] are the texts of {!projection_messages} in provider
    order. *)

val projection_json : t -> Jsont.json list
(** [projection_json t] is the model-visible context projection as JSON objects
    with [role], [sources], and [text]. This is for debug and inspection output;
    execution should use {!to_prelude}. *)

val rendered_digest : t -> string
(** [rendered_digest t] is the projection identity: a digest over a
    length-prefixed encoding of each projection message's role and text, spelled
    [sha256:<hex>]. Two contexts project the same bytes exactly when their
    rendered digests are equal.

    The length prefix makes the encoding injective over the (role, text)
    fragment sequence, so digest equality implies byte equality: it must not be
    reduced to plain concatenation, which would confuse fragment boundaries
    (["ab"] then ["c"] versus ["a"] then ["bc"]).

    The identity intentionally covers the resolved run directory, which is
    model-visible in the workspace and instruction fragments: it is a
    per-location, per-session projection identity, not a portable content hash.
    Two checkouts of the same files under different absolute paths therefore
    differ. *)

val to_prelude : t -> Spice_llm.Request.Prelude.t
(** [to_prelude t] is {!projection_messages} as a checked request prelude.

    This cannot fail: projection messages are exactly the message kinds the
    prelude accepts. *)

val extend_prelude :
  t ->
  Spice_llm.Message.t list ->
  (Spice_llm.Request.Prelude.t, Spice_llm.Request.Error.t) result
(** [extend_prelude t messages] is [t]'s request prelude followed by [messages].

    Use this when a run mode, child-session role, or other product concept has
    model-visible instructions that should travel with the loaded workspace
    context. Errors with {!Spice_llm.Request.Error.Invalid_prelude_message} if
    [messages] contains a transcript-only message kind. *)

(** {1:warnings Warnings} *)

val warnings : t -> string list
(** [warnings t] are human-readable diagnostics derived from {!sources} and
    {!nested_scan}: unreadable candidates, UTF-8 repairs, budget truncation and
    exhaustion, and a capped nested scan. Warnings never change exit codes and
    are not separate state. *)
