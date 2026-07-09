(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host configuration loading and file editing.

    Configuration has a pure runtime form and an editable file form. Three
    values carry these forms; all three are built from the same declared
    {{!Field}fields}:

    - {!type:t} is the effective runtime configuration read by host services.
    - {!Patch.t} is one caller-supplied runtime override.
    - {!Config_file.doc} is the editable representation of one config file.

    Resolve runtime configuration with {!load}. Inspect or edit config files
    with {!Config_file}. File edits operate on file docs rather than effective
    configurations, so transient environment and command-line values are not
    accidentally persisted.

    {2 Fields}

    A {{!Field.t}[field]} is a typed handle for one supported configuration
    setting. Its type parameter is the setting's domain value: [Field.model] is
    a [string Field.t] and [Field.permission_mode] is a
    [Permission.Preset.t Field.t]. Fields drive string-addressed editing, typed
    effective reads ({!find}), effective-value inspection, and provenance.
    Grouped typed reads over an effective configuration live in the product-area
    view modules ({!Models}, {!Runtime}, {!Permissions}, and the rest).

    {2 Safety}

    Project-owned config loads unconditionally and is safe by construction:
    {!load} reduces the workspace layers to the shared-key allowlist, strips
    their [permission.rules], and clamps budget keys, reporting every drop via
    {!warnings}. Unknown config-file fields are preserved by edits but are not
    part of the runtime API. *)

(** {1:errors Errors} *)

module Error : sig
  type t
  (** The type for recoverable configuration errors.

      Errors cover path discovery, filesystem I/O, JSON decoding, invalid JSON
      shapes for supported fields, invalid typed values, and invalid config
      keys. Error messages never contain credential material. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic.

      Messages are intended for users and tests, not for stable storage. *)

  val hints : t -> string list
  (** [hints e] are actionable suggestions for [e], produced where the candidate
      knowledge lives, for example close config-key spellings. Hints are
      rendered by host diagnostics; they are not part of {!message}. *)

  val diagnostic : t -> Spice_diagnostic.t
  (** [diagnostic e] is [e] as a renderable boundary diagnostic. Multi-line
      decoder traces are rendered as diagnostic context under a single-line
      primary message. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e]'s message for diagnostics. *)
end

(** {1:origins Configuration origins} *)

module Source : sig
  (** Configuration value sources.

      [User], [Project], [Project_local], and [Extra_file] identify file layers.
      [Env] identifies one process-environment variable. [Override] identifies
      caller-supplied runtime layers. [Default] identifies built-in or
      platform-derived values such as [permission.mode] and [shell]. *)

  type t =
    | User of { path : Spice_path.Abs.t }  (** A user config file at [path]. *)
    | Project of { path : Spice_path.Abs.t }
        (** A shared project config file at [path]. *)
    | Project_local of { path : Spice_path.Abs.t }
        (** A gitignored project-local config file at [path]. *)
    | Extra_file of { path : Spice_path.Abs.t }
        (** An extra config file at [path], selected explicitly or by
            [SPICE_CONFIG]. *)
    | Env of { name : string }
        (** A process-environment override named [name]. *)
    | Override  (** A caller-supplied runtime override layer. *)
    | Default of { reason : string }
        (** A built-in or platform-derived default with diagnostic [reason]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val kind_string : t -> string
  (** [kind_string t] is the stable short source kind used in user-facing
      provenance: ["user"], ["project"], ["project-local"], ["extra"], ["env"],
      ["override"], or ["preset"]. *)

  val jsont : t Jsont.t
  (** [jsont] maps sources to credential-free diagnostic JSON.

      The codec is intended for diagnostics, not for config-file storage. *)
end

module Origin : sig
  (** Provenance of one effective config value. *)

  type t
  (** The type for effective value provenance.

      Provenance records the highest-precedence configured source and the
      lower-precedence configured sources that it shadowed. *)

  val source : t -> Source.t
  (** [source t] is the winning source for the effective value. *)

  val shadowed : t -> Source.t list
  (** [shadowed t] are lower-precedence sources that also configured the value,
      ordered from nearest shadowed source to lowest precedence. Built-in
      defaults are never shadowed values. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps origins to credential-free diagnostic JSON. *)
end

(** {1:fields Config fields} *)

type t
(** The type for resolved effective host configuration.

    Values of this type are snapshots. They do not update automatically if files
    or environment variables change. *)

module Field : sig
  (** Supported config fields.

      A field is a typed handle for one supported setting. The type parameter is
      the setting's domain value: [Field.run_max_steps] is an [int Field.t] and
      [Field.reasoning] is a
      [Spice_llm.Request.Options.Reasoning_effort.t Field.t]. Fields are the
      boundary for string-addressed config editing, typed effective reads
      ({!Config.find}), effective value inspection, and explanations.

      Two closed-vocabulary fields, [tools.editor] and [web.search_backend], are
      [string Field.t]: their codecs accept only a fixed set of spellings, but
      the domain value stays a validated string with no dedicated type. *)

  type 'a t
  (** The type for one supported config field reading a domain value of type
      ['a]. *)

  type any =
    | Any : 'a t -> any
        (** The type for a field of unknown domain type. Generic surfaces that
            enumerate or parse fields — {!all}, {!of_string}, {!Config.origins}
            — work with [any] and recover the domain type by pattern-matching.
        *)

  val model : string t
  (** [model] is the [model] field. *)

  val small_model : string t
  (** [small_model] is the [small_model] field. *)

  val reasoning : Spice_llm.Request.Options.Reasoning_effort.t t
  (** [reasoning] is the [reasoning] field. *)

  val tui_thinking : bool t
  (** [tui_thinking] is the [tui.thinking] field. *)

  val provider_base_url : Spice_llm.Provider.t -> string t
  (** [provider_base_url provider] is the [providers.<provider>.base_url] field.
  *)

  val run_max_steps : int t
  (** [run_max_steps] is the [run.max_steps] field. *)

  val run_subagent_max_concurrent : int t
  (** [run_subagent_max_concurrent] is the [run.subagent_max_concurrent] field:
      the cap on concurrently running subagent children over a session tree.
      Defaults to [4]; it is also the provider fan-out bound
      (doc/plans/subagent-tui.md §8.3). *)

  val run_subagent_max_depth : int t
  (** [run_subagent_max_depth] is the [run.subagent_max_depth] field: the
      deepest child a spawn may create; root children are depth [1]. Defaults to
      [2]. *)

  val run_subagent_max_exchanges : int t
  (** [run_subagent_max_exchanges] is the [run.subagent_max_exchanges] field:
      the per-run cap on parent<->child message exchanges (messages sent plus
      asks parked). Model-origin sends over the cap fail; asks over the cap park
      with the cap as blocker; user-origin sends are exempt. Defaults to [8]. *)

  val run_subagent_wake : bool t
  (** [run_subagent_wake] is the [run.subagent_wake] field: whether a subagent
      settling while the session is idle starts a continuation turn so the model
      sees the result immediately (doc/plans/subagent-tui.md §8.4). Defaults to
      [true]; when off, results wait for the next user message. *)

  val permission_mode : Permission.Preset.t t
  (** [permission_mode] is the [permission.mode] field.

      [SPICE_PERMISSION_MODE] accepts every preset except [bypass]: the
      environment is the one channel a parent process can set invisibly, which
      is the wrong property for the dangerous preset. The CLI flag and config
      files may still select [bypass]. *)

  val permission_unattended : Permission.Unattended.t t
  (** [permission_unattended] is the [permission.unattended] field. *)

  val sandbox_mode : Sandbox.Mode.t t
  (** [sandbox_mode] is the [sandbox.mode] field. *)

  val sandbox_require : Sandbox.Require.t t
  (** [sandbox_require] is the [sandbox.require] field. *)

  val sandbox_writable_roots : string list t
  (** [sandbox_writable_roots] is the [sandbox.writable_roots] field. *)

  val sandbox_network : Sandbox.Network.t t
  (** [sandbox_network] is the [sandbox.network] field. *)

  val sandbox_toolchain_caches : bool t
  (** [sandbox_toolchain_caches] is the [sandbox.toolchain_caches] field. *)

  val shell : string t
  (** [shell] is the [shell] field. *)

  val compaction_auto : bool t
  (** [compaction_auto] is the [compaction.auto] field. *)

  val notices_fswatch : bool t
  (** [notices_fswatch] is the [notices.fswatch] field. *)

  val notices_cr_comments : bool t
  (** [notices_cr_comments] is the [notices.cr_comments] field. *)

  val notices_dune_diagnostics : bool t
  (** [notices_dune_diagnostics] is the [notices.dune_diagnostics] field. *)

  val notices_dune_build : bool t
  (** [notices_dune_build] is the [notices.dune_build] field. *)

  val workspace_tooling : string t
  (** [workspace_tooling] is the [workspace.tooling] field: [auto], [on], or
      [off]. *)

  val instructions_global : bool t
  (** [instructions_global] is the [instructions.global] field. *)

  val instructions_project : bool t
  (** [instructions_project] is the [instructions.project] field. *)

  val instructions_claude_md : bool t
  (** [instructions_claude_md] is the [instructions.claude_md] field. *)

  val instructions_project_max_bytes : int t
  (** [instructions_project_max_bytes] is the [instructions.project_max_bytes]
      field. *)

  val skills_enabled : bool t
  (** [skills_enabled] is the [skills.enabled] field. *)

  val skills_builtin : bool t
  (** [skills_builtin] is the [skills.builtin] field. *)

  val skills_project : bool t
  (** [skills_project] is the [skills.project] field. *)

  val skills_compat : bool t
  (** [skills_compat] is the [skills.compat] field. *)

  val skills_disabled : string list t
  (** [skills_disabled] is the [skills.disabled] field: skill names excluded
      from the catalog and its budget. Unknown names are inert but preserved.
      See {!Config.Skills.disabled}. *)

  val skills_paths : string list t
  (** [skills_paths] is the [skills.paths] field. *)

  val skills_catalog_max_bytes : int t
  (** [skills_catalog_max_bytes] is the [skills.catalog_max_bytes] field. *)

  val tools_anchored_edits : bool t
  (** [tools_anchored_edits] is the [tools.anchored_edits] field. *)

  val tools_editor : string t
  (** [tools_editor] is the [tools.editor] field, an enum spelled ["auto"],
      ["apply-patch"], or ["string-replace"]. *)

  val ocaml_merlin_program : string list t
  (** [ocaml_merlin_program] is the [ocaml.merlin_program] field, a non-empty
      argv prefix of non-empty tokens. *)

  val web_enabled : bool t
  (** [web_enabled] is the [web.enabled] field. *)

  val web_allow_private_network : bool t
  (** [web_allow_private_network] is the [web.allow_private_network] field. *)

  val web_search_backend : string t
  (** [web_search_backend] is the [web.search_backend] field, an enum spelled
      ["disabled"] or ["brave"]. *)

  val web_fetch_max_bytes : int t
  (** [web_fetch_max_bytes] is the [web.fetch_max_bytes] field. *)

  val web_output_max_chars : int t
  (** [web_output_max_chars] is the [web.output_max_chars] field. *)

  val web_timeout_ms : int t
  (** [web_timeout_ms] is the [web.timeout_ms] field. *)

  val web_max_timeout_ms : int t
  (** [web_max_timeout_ms] is the [web.max_timeout_ms] field. *)

  val of_string : string -> (any, Error.t) result
  (** [of_string s] parses a supported config-file field. *)

  val name : 'a t -> string
  (** [name field] is [field]'s stable config-file spelling. *)

  val equal : 'a t -> 'b t -> bool
  (** [equal a b] is [true] iff [a] and [b] name the same field. *)

  val all : unit -> any list
  (** [all ()] is the finite list of non-provider-family fields in stable order.

      Provider base URL keys are a family and are parsed by {!of_string}; they
      are not enumerable without a provider id. *)

  val values : 'a t -> string list option
  (** [values field] is the finite set of spellings [field] accepts when its
      parser recognizes only a closed vocabulary, in presentation order, and
      [None] when [field] parses an open shape (free strings, model selectors,
      shells, paths, integers, and free lists) whose values are not enumerable.

      The closed-vocabulary fields are the enums — [reasoning],
      [permission.mode] (durable channels omit [bypass], so it is not offered),
      [permission.unattended], the [sandbox.*] modes, [tools.editor], and
      [web.search_backend] — and the booleans, whose values are
      [["true"; "false"]]. The list is exactly the vocabulary the field's
      {!Patch.set}, {!Config_file.set}, and file decoder accept, so a value
      drawn from it always validates. *)
end

(** {1:patches Runtime patches} *)

module Patch : sig
  type t
  (** The type for a partial runtime configuration patch.

      Fields absent from a layer do not affect lower-precedence values during
      resolution. Runtime callers use patches for command-line overrides and
      other explicit, in-process inputs. Config-file editing code should use
      {!Config_file.doc}. *)

  val empty : t
  (** [empty] contains no configured fields. *)

  val is_empty : t -> bool
  (** [is_empty t] is [true] iff [t] contains no configured fields. *)

  val set : 'a Field.t -> string option -> t -> (t, Error.t) result
  (** [set field value t] is [t] with [field] replaced by [value].

      [Some raw] parses [raw] as a textual scalar according to [field]. String
      fields use [raw] directly; JSON syntax is not interpreted here, except for
      [skills.paths] and [ocaml.merlin_program], whose textual spelling is a
      JSON array of non-empty strings ([ocaml.merlin_program] must be
      non-empty). [None] removes the field. Model references must have
      [provider/model] syntax. Provider base URLs and shell programs must not be
      empty. [run.max_steps], [instructions.project_max_bytes], and
      [skills.catalog_max_bytes] must be positive and within JSON's exact
      integer range. Boolean fields accept exactly [true] or [false]. *)

  val get : 'a Field.t -> t -> string option
  (** [get field t] is [field]'s textual value in [t], if configured. *)
end

(** {1:config_files Config files} *)

module Config_file : sig
  type paths
  (** Discovered host configuration file paths.

      A value of this type is pure path metadata. File operations take an
      explicit [stdenv] argument. *)

  type doc
  (** Editable contents of one host configuration file.

      A document holds the supported fields decoded from one file. Unknown
      fields from the source file are not exposed through this type; they are
      preserved in place by {!edit}. *)

  type kind =
    | User  (** User-scoped config, normally under the user config home. *)
    | Project  (** Shared workspace config, normally [.spice/config.json]. *)
    | Project_local
        (** Gitignored workspace config, normally [.spice/config.local.json]. *)

  val empty : doc
  (** [empty] is an empty config-file document. *)

  val path : paths -> kind -> Spice_path.Abs.t
  (** [path paths kind] is [kind]'s discovered path. *)

  val user : paths -> Spice_path.Abs.t
  (** [user paths] is the user config path. *)

  val project : paths -> Spice_path.Abs.t
  (** [project paths] is the shared project config path. *)

  val project_local : paths -> Spice_path.Abs.t
  (** [project_local paths] is the project-local config path. *)

  val discover :
    stdenv:Eio_unix.Stdenv.base ->
    ?process_env:Env.t ->
    ?cwd:string ->
    unit ->
    (paths, Error.t) result
  (** [discover ~stdenv ()] discovers config file paths without loading or
      validating any config source. *)

  val load_path : stdenv:Eio_unix.Stdenv.base -> string -> (doc, Error.t) result
  (** [load_path ~stdenv path] loads [path] as a config-file document.

      A missing file is {!empty}. Unknown fields are ignored by document
      loading. *)

  val validate_path :
    stdenv:Eio_unix.Stdenv.base -> ?strict:bool -> string -> Error.t list
  (** [validate_path ~stdenv ?strict path] validates [path] as a config file.

      Default validation reports only supported fields with invalid shapes or
      values. Strict validation additionally reports every unknown field, in
      file order. *)

  val load :
    stdenv:Eio_unix.Stdenv.base -> paths -> kind -> (doc, Error.t) result
  (** [load ~stdenv paths kind] loads [kind] as a config-file document.

      Loading {!Project} or {!Project_local} directly only reads the file; it
      does not apply the workspace-layer filtering that resolved configuration
      loading applies. *)

  val field_allowed : kind -> 'a Field.t -> bool
  (** [field_allowed kind field] is [true] iff [field] may be written to [kind].
      Both workspace files ({!Project} and {!Project_local}) accept only the
      shared allowlist of fields that are safe against a hostile repository;
      user config accepts every supported field. *)

  val field_names : kind -> string list
  (** [field_names kind] are the non-provider-family field spellings accepted by
      [kind], in stable order. Provider base URL fields are parsed by
      {!Field.of_string} and are not enumerable without a provider id. *)

  val get : 'a Field.t -> doc -> string option
  (** [get field doc] is [field]'s textual value in [doc], if configured. *)

  val set : 'a Field.t -> string option -> doc -> (doc, Error.t) result
  (** [set field value doc] returns [doc] with [field] replaced by [value].

      [None] removes the field. [Some raw] parses [raw] with [field]'s textual
      parser. *)

  val json : 'a Field.t -> doc -> Jsont.json
  (** [json field doc] is [field]'s JSON scalar value in [doc], or JSON [null]
      if it is absent. *)

  val permission_rules : doc -> Spice_permission.Policy.Rule.t list
  (** [permission_rules doc] are [doc]'s durable permission rules in file order.

      The config wire form is a bare, unversioned JSON array of
      {!Spice_permission.Policy.Rule.jsont} values. It is distinct from the
      versioned {!Spice_permission.Policy.jsont} codec. A rule schema change is
      therefore a breaking config change: unsupported shapes fail when the
      config is loaded rather than being migrated implicitly. *)

  val set_permission_rules : Spice_permission.Policy.Rule.t list -> doc -> doc
  (** [set_permission_rules rules doc] replaces [doc]'s durable permission
      rules. An empty list removes the field. *)

  val edit :
    stdenv:Eio_unix.Stdenv.base ->
    paths ->
    kind ->
    f:(doc -> (doc, Error.t) result) ->
    (unit, Error.t) result
  (** [edit ~stdenv paths kind ~f] updates [kind] by applying [f] to the
      supported fields loaded from the file.

      Unknown fields are preserved with their values and nesting, supported
      empty containers are removed, and parent directories are created as
      needed. Editing writes nothing when [f] leaves the supported fields
      unchanged. Updating {!Project_local} also records the local config
      filename in the adjacent [.gitignore] when possible. *)

  val ensure :
    stdenv:Eio_unix.Stdenv.base -> paths -> kind -> (unit, Error.t) result
  (** [ensure ~stdenv paths kind] creates [kind] as an empty config file if it
      is missing. Existing files are left unchanged. *)

  val add_permission_rule :
    stdenv:Eio_unix.Stdenv.base ->
    paths ->
    kind ->
    Spice_permission.Policy.Rule.t ->
    (unit, Error.t) result
  (** [add_permission_rule ~stdenv paths kind rule] appends [rule] to [kind]'s
      durable [permission.rules], preserving unknown fields and creating the
      file and (for {!Project_local}) its [.gitignore] entry as needed.
      Appending a rule already present by content is a no-op that writes
      nothing.

      Writing is not the same as loading. A rule appended to {!Project} or
      {!Project_local} lands in the file but is still stripped when resolved
      configuration loads (the {!Warning} carrying [Ignored_project_rules]),
      because durable rules are authority a repository must not inject; only
      {!User} rules become effective policy. This is the persistence half of a
      reviewer's "always allow" answer, whose in-session effect is carried by
      the run posture, not the file. *)
end

module Warning : sig
  (** Non-fatal configuration warnings.

      A warning is a structured fact about a dropped or degraded workspace
      config input — it is not an origin for any effective value. Warnings are
      intended for CLI support output and host diagnostics. *)

  type t
  (** A non-fatal configuration warning.

      Warnings explain host-visible config inputs that did not take effect, such
      as workspace config keys outside the shared allowlist, stripped workspace
      [permission.rules], clamped budget keys, and invalid workspace config
      files. *)

  val message : t -> string
  (** [message t] is a concise human-readable message. *)

  val source : t -> Source.t
  (** [source t] is the config source the warning is about. *)

  val field : t -> Field.any option
  (** [field t] is the config field the warning is about, when applicable. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for text diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps warnings to the stable support JSON shape. *)
end

(** {1:configs Effective configurations} *)

val load :
  stdenv:Eio_unix.Stdenv.base ->
  ?process_env:Env.t ->
  ?cwd:string ->
  ?extra_config_file:string ->
  ?data_home:string ->
  ?overrides:Patch.t list ->
  unit ->
  (t, Error.t) result
(** [load ~stdenv ()] resolves the effective host configuration.

    Resolution merges the following layers in increasing precedence:

    - user config;
    - project config;
    - project-local config;
    - [extra_config_file], or [SPICE_CONFIG] if the argument is absent;
    - process-environment settings;
    - [overrides].

    The two workspace layers (project and project-local config) are repository
    content and load unconditionally, made safe by construction rather than
    gated on consent: both are reduced to the shared-key allowlist,
    [permission.rules] never load from the workspace, budget keys such as
    [run.max_steps] may tighten but not widen the value the non-workspace layers
    resolve to, files are byte-capped before parsing, and an unreadable or
    invalid workspace file degrades to an empty layer. Every dropped or degraded
    workspace input is reported by {!warnings}; none of them fail the load.

    The recognized environment settings are [SPICE_MODEL], [SPICE_SMALL_MODEL],
    [SPICE_REASONING], [SPICE_MAX_STEPS], [SPICE_PERMISSION_MODE] (which rejects
    [bypass]), [SPICE_PERMISSION_UNATTENDED], [SPICE_SANDBOX_MODE],
    [SPICE_SANDBOX_REQUIRE], [SPICE_SHELL], [SPICE_OPENAI_BASE_URL],
    [SPICE_ANTHROPIC_BASE_URL], [SPICE_OLLAMA_BASE_URL], [SPICE_CONFIG], and
    config-home variables used to find user config and the credential store.
    Empty environment settings are ignored.

    [cwd] defaults to the Eio current working directory and must name an
    existing directory. [data_home] defaults to the global user data directory
    resolved by {!User_dirs.data_home}. [extra_config_file] takes precedence
    over [SPICE_CONFIG]. When [process_env] is absent, environment variables are
    read from a snapshot of the current process environment. *)

val cwd : t -> Spice_path.Abs.t
(** [cwd t] is [t]'s resolved working directory.

    The directory existed when [t] was loaded. *)

val project_root : t -> Spice_path.Abs.t
(** [project_root t] is the nearest ancestor of {!cwd} containing a [.git]
    marker, or {!cwd} when no marker exists. Project config and skills resolve
    from this root. *)

val data_home : t -> Spice_path.Abs.t
(** [data_home t] is [t]'s durable global data root.

    Loading config does not create the directory. *)

val state_home : t -> Spice_path.Abs.t
(** [state_home t] is [t]'s machine-local state root.

    Loading config does not create the directory. *)

val auth_store_path : t -> Spice_path.Abs.t
(** [auth_store_path t] is [t]'s user-scoped credential store path.

    The path is derived from config-home environment, not from {!data_home}.
    Loading config does not read or create the credential store. *)

val process_env : t -> Env.t
(** [process_env t] is the process environment snapshot used to resolve [t]. *)

val files : t -> Config_file.paths
(** [files t] is the discovered config file set for [t]. *)

val sandbox_protected_roots : t -> Spice_path.Abs.t list
(** [sandbox_protected_roots t] are host authority roots that workspace-write
    sandboxes must keep read-only even when they sit beneath a writable root:
    the user config/auth directory, the project config directory, {!data_home},
    and {!state_home}. *)

module Models : sig
  (** Model-related configuration.

      This is the read path for configured model selectors and provider endpoint
      overrides. Model selection rules live in the host model resolver; this
      module only reports what static configuration contributed. *)

  type t
  (** The model configuration view of an effective {!Config.t}. *)

  val main : t -> string option
  (** [main t] is the configured main model selector, if any. *)

  val main_with_origin : t -> (string * Origin.t option) option
  (** [main_with_origin t] is [Some (selector, origin)] when {!main} is
      configured: [selector] is that value and [origin] is its resolution origin
      when one was recorded, [None] otherwise. It is [None] iff {!main} is
      [None]. This pairs the selector with its origin in one read so callers do
      not have to reconcile {!main} and {!Config.origin} separately. *)

  val small : t -> string option
  (** [small t] is the configured small-model selector, if any. *)

  val reasoning : t -> Spice_llm.Request.Options.Reasoning_effort.t option
  (** [reasoning t] is the configured reasoning effort, if any. *)

  val provider_base_url : t -> provider:Spice_llm.Provider.t -> string option
  (** [provider_base_url t ~provider] is [provider]'s configured API base URL
      override, if any. *)

  val provider_base_urls : t -> (Spice_llm.Provider.t * string) list
  (** [provider_base_urls t] are configured provider API base URL overrides in
      provider order. *)
end

module Runtime : sig
  (** General runtime configuration that is not owned by a narrower product
      area. *)

  type t
  (** The runtime configuration view of an effective {!Config.t}. *)

  val max_steps : t -> int option
  (** [max_steps t] is the configured run step limit, if any. *)

  val subagent_max_concurrent : t -> int
  (** [subagent_max_concurrent t] is the concurrent subagent-run cap. *)

  val subagent_max_depth : t -> int
  (** [subagent_max_depth t] is the subagent nesting depth cap. *)

  val subagent_wake : t -> bool
  (** [subagent_wake t] is whether idle-parent settle wakes are enabled. *)

  val subagent_max_exchanges : t -> int
  (** [subagent_max_exchanges t] is the per-run message exchange cap. *)

  val shell : t -> string
  (** [shell t] is the configured shell executable used for shell commands. *)

  val compaction_auto : t -> bool
  (** [compaction_auto t] is [true] iff automatic context compaction is enabled.
  *)
end

module Tui : sig
  (** TUI presentation preferences. *)

  type t
  (** The TUI configuration view of an effective {!Config.t}. *)

  val thinking : t -> bool
  (** [thinking t] is [true] iff the TUI shows reasoning summaries. *)
end

module Permissions : sig
  (** Permission configuration.

      This module exposes durable configuration facts. Run-specific permission
      policy construction, including CLI overrides, lives in
      {!Config.permission_posture}. *)

  type t
  (** The permission configuration view of an effective {!Config.t}. *)

  val mode : t -> Permission.Preset.t
  (** [mode t] is the configured permission preset or its default. *)

  val unattended : t -> Permission.Unattended.t
  (** [unattended t] is the configured policy for permission reviews in
      unattended runs. *)

  val rules : t -> (Source.t * Spice_permission.Policy.Rule.t list) list
  (** [rules t] are durable permission-rule groups paired with their config
      source, ordered by effective policy precedence. *)
end

module Sandbox : sig
  (** Sandbox configuration.

      Sandbox resolution also needs workspace and backend facts. Use the host
      sandbox resolver or the normal run assembly path for the effective run
      posture. This module only reports static config values. *)

  type t
  (** The sandbox configuration view of an effective {!Config.t}. *)

  val mode : t -> Sandbox.Mode.t option
  (** [mode t] is the configured sandbox mode, if any. *)

  val require : t -> Sandbox.Require.t
  (** [require t] is the configured sandbox enforcement requirement. *)

  val writable_roots : t -> string list
  (** [writable_roots t] are the configured extra writable roots for
      workspace-write, as raw path spellings: absolute, [~], or [~/...]. The
      host sandbox resolver tilde-expands and canonicalizes them. *)

  val network : t -> Sandbox.Network.t
  (** [network t] is the configured outbound-network capability for confined
      runs. Defaults to {!Sandbox.Network.Restricted}. *)

  val toolchain_caches : t -> bool
  (** [toolchain_caches t] is whether curated per-toolchain cache roots (for
      example dune's) are added to workspace-write writable roots. Defaults to
      [true]. *)
end

module Instructions : sig
  (** Instruction-source configuration. *)

  type t
  (** The instruction configuration view of an effective {!Config.t}. *)

  val global : t -> bool
  (** [global t] is [true] iff user-global instructions are enabled. *)

  val project : t -> bool
  (** [project t] is [true] iff project instructions are enabled. *)

  val claude_md : t -> bool
  (** [claude_md t] is [true] iff Claude-compatible instruction files are read.
  *)

  val project_max_bytes : t -> int
  (** [project_max_bytes t] is the byte budget for project instruction content.
  *)
end

module Notices : sig
  (** Notice-source configuration for long-running sessions. *)

  type t
  (** The notice configuration view of an effective {!Config.t}. *)

  val fswatch : t -> bool
  (** [fswatch t] is [true] iff filesystem change notices are enabled. *)

  val cr_comments : t -> bool
  (** [cr_comments t] is [true] iff code-review comment notices are enabled. *)

  val dune_diagnostics : t -> bool
  (** [dune_diagnostics t] is [true] iff Dune diagnostics notices are enabled.
  *)

  val dune_build : t -> bool
  (** [dune_build t] is [true] iff Dune build notices are enabled. *)
end

module Workspace : sig
  (** Workspace OCaml/Dune tooling configuration. *)

  type t
  (** The workspace-tooling view of an effective {!Config.t}. *)

  val tooling : t -> string
  (** [tooling t] is the [workspace.tooling] mode: [auto], [on], or [off]. It
      gates the workspace's OCaml/Dune integration as a whole — the boot
      [dune describe] shape capture, the [dune build --watch] diagnostics and
      build-health instance, the filesystem watcher, and Merlin program
      resolution. [off] disables them for CI, headless, and non-interactive test
      runs, leaving a truthful degraded footer and no background workspace
      processes. *)

  val tooling_engaged : t -> root:string -> bool
  (** [tooling_engaged t ~root] resolves {!tooling} to whether the workspace
      tooling runs for the workspace rooted at [root]: [on] forces it on, [off]
      forces it off, and [auto] engages it only when [root] holds a
      [dune-project] or [dune-workspace] file. It is resolved against the
      filesystem on each call, so a directory that gains or loses a Dune marker
      between launches is read afresh. *)
end

module Skills : sig
  (** Skill discovery configuration. *)

  type t
  (** The skill configuration view of an effective {!Config.t}. *)

  val enabled : t -> bool
  (** [enabled t] is [true] iff skill discovery is enabled. *)

  val builtin : t -> bool
  (** [builtin t] is [true] iff bundled skills are enabled. *)

  val project : t -> bool
  (** [project t] is [true] iff project skills are enabled. *)

  val compat : t -> bool
  (** [compat t] is [true] iff compatibility skill locations are enabled. *)

  val disabled : t -> string list
  (** [disabled t] are the skill names excluded from discovery by config.

      A discovered skill whose name is listed is reported with a config-disabled
      status and is excluded from the catalog and its budget, whatever root it
      was found in. Names matching no discovered skill are inert. This is
      per-skill enablement layered over the group toggles ({!enabled},
      {!builtin}, {!project}, {!compat}). *)

  val paths : t -> string list
  (** [paths t] are additional configured skill search roots. *)

  val catalog_max_bytes : t -> int
  (** [catalog_max_bytes t] is the byte budget for rendered skill catalog text.
  *)
end

module Tools : sig
  (** Tool-specific configuration. *)

  type t
  (** The tool configuration view of an effective {!Config.t}. *)

  val anchored_edits : t -> bool
  (** [anchored_edits t] is [true] iff edit tools should use anchored edit
      semantics. *)

  val editor : t -> string
  (** [editor t] is the configured file-mutation editor family spelling:
      ["auto"] (default), ["apply-patch"], or ["string-replace"]. ["auto"] lets
      the host pick the family from the model's capabilities; the other two
      force it. *)
end

module Ocaml : sig
  (** OCaml tooling configuration. *)

  type t
  (** The OCaml configuration view of an effective {!Config.t}. *)

  val merlin_program : t -> string list
  (** [merlin_program t] is the configured [ocamlmerlin] invocation prefix,
      defaulting to [["ocamlmerlin"]]. The host resolves it to a lock-free argv
      once at boot. *)
end

module Web : sig
  (** Web-tool configuration.

      This module reports static settings. Runtime policy construction,
      including credential checks for the selected search backend, is internal
      to the tool-catalog assembly. *)

  type t
  (** The web configuration view of an effective {!Config.t}. *)

  val enabled : t -> bool
  (** [enabled t] is [true] iff web tools are enabled. *)

  val allow_private_network : t -> bool
  (** [allow_private_network t] is [true] iff web fetches may reach private
      network addresses. *)

  val search_backend : t -> string
  (** [search_backend t] is the configured web search backend spelling. *)

  val fetch_max_bytes : t -> int
  (** [fetch_max_bytes t] is the maximum response body size fetched by web
      tools, in bytes. *)

  val output_max_chars : t -> int
  (** [output_max_chars t] is the maximum text output returned to the model, in
      characters. *)

  val timeout_ms : t -> int
  (** [timeout_ms t] is the default web request timeout in milliseconds. *)

  val max_timeout_ms : t -> int
  (** [max_timeout_ms t] is the maximum caller-selectable web request timeout in
      milliseconds. *)
end

val models : t -> Models.t
(** [models t] is [t]'s model configuration view. *)

val runtime : t -> Runtime.t
(** [runtime t] is [t]'s general runtime configuration view. *)

val tui : t -> Tui.t
(** [tui t] is [t]'s TUI presentation configuration view. *)

val permissions : t -> Permissions.t
(** [permissions t] is [t]'s permission configuration view. *)

val permission_posture :
  ?preset:Permission.Preset.t -> t -> Source.t Permission.Run.t
(** [permission_posture ?preset t] is the effective permission posture for one
    model/tool run over [t].

    [preset] overrides the configured permission preset when present. Durable
    rules come from {!Permissions.rules} in descending precedence, and the
    active preset is appended as the default source. This is the run-specific
    construction over the durable facts {!Permissions} reports. *)

val sandbox : t -> Sandbox.t
(** [sandbox t] is [t]'s sandbox configuration view. *)

val instructions : t -> Instructions.t
(** [instructions t] is [t]'s instruction configuration view. *)

val notices : t -> Notices.t
(** [notices t] is [t]'s notice configuration view. *)

val workspace : t -> Workspace.t
(** [workspace t] is [t]'s workspace-tooling configuration view. *)

val skills : t -> Skills.t
(** [skills t] is [t]'s skill configuration view. *)

val tools : t -> Tools.t
(** [tools t] is [t]'s tool configuration view. *)

val ocaml : t -> Ocaml.t
(** [ocaml t] is [t]'s OCaml tooling configuration view. *)

val web : t -> Web.t
(** [web t] is [t]'s web configuration view. *)

val find : 'a Field.t -> t -> 'a option
(** [find field t] is [field]'s configured domain value in [t], if it was set by
    any layer. Built-in defaults are not applied: [find Field.tui_thinking t] is
    [None] for an unconfigured [tui.thinking] even though its effective value is
    [true]. Use the view modules — for example {!Tui.thinking} — for reads that
    resolve defaults, or {!get} for the effective textual value. *)

val origin : 'a Field.t -> t -> Origin.t option
(** [origin field t] is [field]'s effective provenance, if [field] has an
    effective value. Resolved defaults such as [permission.mode] and [shell]
    have default origins. *)

val origins : t -> (Field.any * Origin.t) list
(** [origins t] are all effective value origins, ordered by config-key spelling.
*)

val get : 'a Field.t -> t -> string option
(** [get field t] is the effective textual config value named by [field], if it
    is configured.

    Resolved defaults, such as [permission.mode] and [shell], are returned as
    values. *)

val json : 'a Field.t -> t -> Jsont.json
(** [json field t] is [field]'s effective JSON scalar value, or JSON [null] if
    it is absent. Resolved defaults render as values. *)

val warnings : t -> Warning.t list
(** [warnings t] are non-fatal config warnings for [t].

    Warnings report workspace config inputs dropped at load: invalid or
    oversized workspace files, keys outside the shared allowlist, stripped
    [permission.rules], and budget keys that tried to widen the non-workspace
    effective value. The result is ordered for stable support output and derives
    entirely from load-time facts. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats a compact diagnostic view of [t].

    The output is not stable storage syntax. *)
