(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Request-scoped skill snapshot.

    A snapshot is everything the host discovered about skills for one request:
    every candidate across every root, why any candidate was shadowed, disabled,
    or invalid, and the budgeted catalog the model will see. One {!load} reads
    the filesystem; every other operation is a pure view, so [skills list], the
    [skill] tool, [--skill] injection, and JSON output cannot disagree within a
    request. Snapshots are never persisted: every request recomputes from disk.

    Requested policy — enablement, the catalog budget, extra roots — lives on
    {!Config} with its origins. The snapshot carries only discovered and built
    facts. Skill text is guidance with the same authority as project
    instructions; nothing here changes tools, permissions, or modes.

    {!Context} mirrors this candidate / status / snapshot shape by convention;
    the two are not unified because their status cases genuinely differ. *)

(** {1:skills Skills} *)

module Skill : sig
  (** Discovered skill candidates and their statuses. *)

  module Name : sig
    (** Skill identities.

        A name is the candidate's directory name (builtin: its file stem):
        lowercase ASCII letters, digits, and hyphens, starting with a letter or
        digit, at most 64 bytes. *)

    type t
    (** The type for skill names. *)

    val of_string : string -> (t, string) result
    (** [of_string s] is [s] as a skill name, or a human-readable reason. *)

    val to_string : t -> string
    (** [to_string t] is [t]'s name text. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same name. *)

    val compare : t -> t -> int
    (** [compare a b] is a total order on names, by name text. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t]'s name text. *)
  end

  (** The type for the root a candidate was discovered in. *)
  type kind =
    | Project  (** [.spice/skills] under the workspace root. *)
    | Compat_agents  (** [.agents/skills] under the workspace root. *)
    | Compat_claude  (** [.claude/skills] under the workspace root. *)
    | User  (** [skills] in the user config directory. *)
    | Path  (** A [skills.paths] root, in configuration order. *)
    | Builtin  (** Compiled into the binary. *)

  type content = {
    description : string;
    display_name : string option;
        (** Frontmatter [name], when it differs from the identity. *)
    text : string;
        (** The raw skill file contents, including frontmatter: provenance for
            [skills show] and the identity source for [bytes] and [digest]. *)
    body : string;
        (** The frontmatter-stripped guidance the tool serves to the model. *)
    bytes : int;
    digest : string;  (** [sha256:<hex>] over [text]. *)
    resources : string list;
        (** Sibling regular files, sorted; always [[]] for builtins. *)
    ignored_keys : string list;
        (** Frontmatter keys Spice does not read, for migration warnings. *)
  }
  (** The type for read facts. Only active skills have content. *)

  type invalid =
    [ `Description_missing
    | `Description_too_long
    | `Invalid_frontmatter of string
    | `Unreadable of string ]
  (** The type for reasons a candidate is not a loadable skill. *)

  (** The type for a candidate's discovery outcome. *)
  type status =
    | Active of content  (** The skill is cataloged and loadable. *)
    | Shadowed of { by : string }
        (** A same-name skill from a higher-precedence root won; [by] is the
            winner's origin. *)
    | Disabled of [ `Project_skills | `Compat | `Builtin | `Config ]
        (** Enablement excluded the candidate. A group toggle
            ([`Project_skills], [`Compat], [`Builtin]) excludes it before any
            content read; [`Config] is a per-skill exclusion by
            [skills.disabled] and applies to every candidate of the name,
            whatever root it was found in. *)
    | Invalid of invalid  (** The candidate is not a loadable skill. *)

  type t
  (** The type for discovered skill candidates. Identity is the {!Name.t}; only
      one candidate per name is ever {!Active}. *)

  val name : t -> Name.t
  (** [name t] is [t]'s identity. *)

  val kind : t -> kind
  (** [kind t] is the root [t] was discovered in. *)

  val status : t -> status
  (** [status t] is [t]'s discovery outcome. *)

  val origin : t -> string
  (** [origin skill] is the display origin: a path for filesystem skills, or the
      builtin origin label. *)

  val kind_string : kind -> string
  (** [kind_string kind] is [kind]'s stable JSON tag, for example ["project"] or
      ["builtin"]. *)

  val state_string : status -> string
  (** [state_string status] is [status]'s stable state tag: ["active"],
      ["shadowed"], ["disabled"], or ["invalid"]. *)

  val reason_string : status -> string option
  (** [reason_string status] is a stable machine-readable reason tag for a
      non-active [status], and [None] for {!Active}. *)

  val context_cost : t -> int option
  (** [context_cost t] estimates, in tokens, what activating [t] adds to a
      request context: [Some n] for an {!Active} skill whose guidance the model
      would load, [None] otherwise (a disabled, shadowed, or invalid candidate
      contributes nothing).

      The estimate is [ceil (bytes / 4)] over the frontmatter-stripped guidance
      body — the text the skill tool actually serves — using the rule-of-thumb
      of roughly four UTF-8 bytes per token for prose. It is an estimate, not a
      tokenizer count, and is the single per-skill cost source shared with
      {!Catalog.context_cost}. *)

  val to_json : t -> Jsont.json
  (** [to_json t] is [t] as diagnostic JSON for [skills list] and JSON output.
      Active skills additionally carry their content facts. *)
end

(** {1:catalog Catalog} *)

module Catalog : sig
  (** The rendered model-visible skill listing.

      One derived artifact with one identity: the digest of its text. *)

  type t
  (** The type for rendered catalogs. *)

  val text : t -> string
  (** [text catalog] is the budgeted listing, [""] when no skill is active. *)

  val bytes : t -> int
  (** [bytes catalog] is the byte length of {!text}. *)

  val context_cost : t -> int
  (** [context_cost catalog] estimates, in tokens, the always-present cost of
      the rendered catalog: [ceil (bytes / 4)] over {!text}, the same
      bytes-per-token heuristic as {!Skill.context_cost}. This is the model's
      standing skills-discovery budget, independent of which skills are later
      loaded. *)

  val digest : t -> string
  (** [digest catalog] is [sha256:<hex>] over {!text}. *)

  val trimmed : t -> Skill.Name.t list
  (** [trimmed catalog] are skills whose descriptions were cut to fit the
      budget, each ending with a visible ellipsis in {!text}. *)

  val names_only : t -> bool
  (** [names_only catalog] is [true] when even untrimmed names exceeded the
      budget and non-builtin descriptions were dropped entirely. *)

  val to_json : t -> Jsont.json
  (** [to_json catalog] is [catalog]'s summary as diagnostic JSON: its byte
      count, digest, trimmed names, and {!names_only} flag. *)
end

(** {1:loading Loading} *)

type t
(** The type for loaded skill snapshots. *)

val load :
  stdenv:Eio_unix.Stdenv.base ->
  builtins:(string * string) list ->
  ?builtin_origin:string ->
  Config.t ->
  t
(** [load ~stdenv ~builtins config] reads every skill root once.

    Roots in precedence and catalog order: [.spice/skills], [.agents/skills],
    and [.claude/skills] under the workspace root (the nearest ancestor of
    [Config.cwd] containing [.git], else the cwd), [skills] in the user config
    directory, each [skills.paths] entry (a relative entry resolves against
    [Config.cwd], not the process working directory), then [builtins] —
    [(name, raw contents)] pairs, typically [Spice_prompts.Skills.all], labeled
    with [builtin_origin] (default ["builtin"]). Filesystem roots contribute
    their immediate subdirectories containing [SKILL.md]; other entries are
    ignored. Candidates are observed with the same follow-and-contain symlink
    policy as tools; content problems are statuses, never errors. The first
    active candidate per name wins; invalid or disabled candidates never shadow.

    Loading is total: every filesystem problem becomes a candidate status or an
    ignored entry, so discovery never fails. When
    [Config.Skills.enabled (Config.skills config)] is false, nothing is read and
    the snapshot is empty. *)

val enabled : t -> bool
(** [enabled t] is whether the skills surface exists for this run. *)

val skills : t -> Skill.t list
(** [skills t] are all discovered candidates in precedence order. *)

val find_active : t -> Skill.Name.t -> (Skill.t * Skill.content) option
(** [find_active t name] is the active skill called [name], with its content. *)

val catalog : t -> Catalog.t
(** [catalog t] is the rendered listing under
    [Config.Skills.catalog_max_bytes (Config.skills config)]. Builtin
    descriptions never trim; names are never dropped. *)

(** {1:model Model surface} *)

val tool_name : string
(** [tool_name] is the model-visible skill tool's name, ["skill"]. *)

val tools : stdenv:Eio_unix.Stdenv.base -> t -> Spice_tool.t list
(** [tools ~stdenv t] is the model-visible skill tool catalog for [t].

    It is [[]] when the skill surface is disabled or no skill is active, and a
    singleton [skill] tool otherwise, so run-tool catalog assembly can append it
    without branching on skill-tool presence.

    The tool description carries fixed usage text plus {!catalog} text. The tool
    serves skill text from the snapshot and reads resource files at call time
    through a workspace rooted at the skill directory, capped with a visible
    truncation marker. It is read-only and declares no permission requests. *)

val injections : t -> names:string list -> (string list, string) result
(** [injections t ~names] are the [--skill] forced-injection texts, in [names]
    order, for the caller to place as user content blocks ahead of the prompt in
    the turn's durable user message.

    Errors with a human-readable message on an unknown, inactive, or invalid
    name, before any model call. *)

(** {1:warnings Warnings} *)

val warnings : t -> string list
(** [warnings t] are human-readable diagnostics derived from {!skills} and
    {!catalog}: invalid candidates, ignored frontmatter keys, and catalog
    trimming. Warnings never change exit codes. *)
