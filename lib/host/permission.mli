(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Product permission posture.

    This module owns the product-layer permission vocabulary above the pure
    {!Spice_permission} core: named posture presets, the unattended reply
    policy, content-derived rule identity, and the provenance-carrying rule
    table that assembles the effective policy.

    Every value here is pure. Config storage lives in {!Config}, prompt
    lifecycle and rendering live in the CLI and TUI surfaces, and policy
    evaluation stays in {!Spice_permission.Policy}.

    A {!Preset} is a permission {e preset}, not a turn mode: the durable
    [permission.mode] config key spells a preset, while the turn mode
    (Build/Plan/Review) is a separate concept. *)

(** {1:presets Permission presets} *)

module Preset : sig
  (** Named permission postures.

      A preset is the durable vocabulary for a user's permission posture — a
      configuration value, not a policy. Storage lives in host config and
      enforcement lives wherever protected operations execute. A preset denotes
      a baseline list of rules; see {!rules}. *)

  type t = Default | Accept_edits | Plan | Bypass

  val all : t list
  (** [all] are the presets in declaration order. Spelling enumerations for
      diagnostics derive from [all] and {!to_string}. *)

  val of_string : string -> t option
  (** [of_string s] is the preset with stable spelling [s] — one of [default],
      [accept-edits], [plan], or [bypass] — and [None] for any other spelling.
      Error wording belongs to the configuration boundary that parses user
      input. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable spelling; see {!of_string}. *)

  val rules : t -> Spice_permission.Policy.Rule.t list
  (** [rules t] are [t]'s baseline policy rules in evaluation order.

      Presets denote rule lists, not policies: {!Run.make} rows them after the
      durable rules so explicit configuration always decides first, and
      {!Run.policy} bridges to a pure policy. [Default] allows workspace reads.
      [Accept_edits] additionally allows workspace creates, modifies, and
      deletes. [Plan] allows workspace reads and denies workspace creates,
      modifies, deletes, and {e commands} — the command denial steers headless
      planning toward the read-only tools instead of parking the session on a
      review. [Bypass] is a single allow-all rule.

      Permission rules decide whether protected operations are allowed,
      reviewed, or denied; they are not sandboxes and grant no runtime
      capabilities. *)

  val sandbox_backed_rules : t -> Spice_permission.Policy.Rule.t list
  (** [sandbox_backed_rules t] are the extra rules [t] gains when the run's
      sandbox enforces workspace-write confinement, appended after {!rules} by
      {!Run.with_sandbox_backing}.

      An enforcing workspace-write sandbox backs native workspace mutation, so
      [Default] gains workspace creates, modifies, and deletes. [Default] and
      [Accept_edits] also review destructive commands before allowing only
      command facts whose execution route is proven sandboxed. [Plan] and
      [Bypass] gain no rules. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same preset. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats {!to_string} [t]. *)
end

(** {1:unattended Unattended reply policy} *)

module Unattended : sig
  (** What a headless run does when a permission review is needed.

      [Block] parks the session as a resumable waiting and the run exits with
      the blocked exit code. [Deny] resolves the review immediately as a denial
      with stable model-visible feedback and lets the run continue; such denials
      carry [`Unattended] provenance (see
      {!Spice_session.Permission.Resolved.via}) and can never allow, grant, or
      write rules. *)

  type t = Block | Deny

  val all : t list
  (** [all] are the policies in declaration order. *)

  val of_string : string -> t option
  (** [of_string s] is the policy with stable spelling [s] — [block] or [deny] —
      and [None] for any other spelling. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable spelling; see {!of_string}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same policy. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats {!to_string} [t]. *)
end

(** {1:rule_identity Rule identity} *)

val rule_id : Spice_permission.Policy.Rule.t -> string
(** [rule_id rule] is [rule]'s content-derived product identity: a truncated
    SHA-256 digest of {!Spice_permission.Policy.Rule.stable_text} with domain
    separation.

    Ids are a pure function of the rule, so they are stable across config-file
    reordering and are never stored. They are stable only for the current rule
    schema. Rules whose matchers avoid machine-derived data (the relative path
    scopes) have machine-independent ids. *)

(** {1:web_docs Read-only documentation allowlist} *)

val web_docs_allowlist : string list
(** [web_docs_allowlist] is the curated set of documentation hosts a [web_fetch]
    may read without review. These are well-known read-only reference sites, so
    fetching them is low risk and the constant re-prompting a fresh posture
    would otherwise force adds friction without safety.

    The allowlist is a {e permission} credit only:
    {!Run.with_web_docs_allowlist} turns it into allow rules for the effective
    policy, so a durable [deny] rule still overrides it and every other host
    still prompts. It never widens the sandbox network policy — a shell command
    reaching one of these hosts is a command access the sandbox still confines,
    not a matched network access. *)

(** {1:run Run permission posture} *)

module Run : sig
  (** Effective permission posture for one model/tool run.

      A run posture pairs the selected preset with the evaluation-ordered rule
      table that decides protected operations. Holding these facts in one value
      is what keeps the executable policy, the blocked-output provenance, the
      permission prompts, and the model-visible denial wording in agreement:
      every surface reads this value instead of reconstructing the table. *)

  type 'src t
  (** The type for an effective run posture whose rule rows carry source
      annotations of type ['src]. *)

  type 'src row = private {
    id : string;  (** {!rule_id} of [rule]. *)
    source : 'src;  (** Caller-supplied provenance annotation. *)
    rule : Spice_permission.Policy.Rule.t;  (** The annotated rule. *)
  }
  (** The type for one evaluation-ordered rule with its identity and provenance.
  *)

  val make :
    preset:'src * Preset.t ->
    durable:('src * Spice_permission.Policy.Rule.t list) list ->
    unit ->
    'src t
  (** [make ~preset ~durable ()] is a run posture whose rows are the [durable]
      layers in descending precedence followed by the selected preset's rules
      ({!Preset.rules}). Each durable layer and the preset carry a provenance
      annotation, propagated to every row it contributes.

      Raises [Invalid_argument] if a single [durable] layer names the same rule
      twice (equal {!rule_id}). Callers own user-input validation; the raise
      guards the programmer contract that layers arrive deduplicated. *)

  val with_sandbox_backing : sandbox_backed:bool -> 'src t -> 'src t
  (** [with_sandbox_backing ~sandbox_backed t] is [t] extended with its preset's
      {!Preset.sandbox_backed_rules} when [sandbox_backed] is [true], and [t]
      unchanged otherwise.

      The added rows carry the preset's provenance and evaluate after every
      existing row, so durable configuration and the preset's own rules still
      decide first. Run assembly derives [sandbox_backed] from the resolved
      sandbox — {!Spice_host.Sandbox.enforces_workspace_write} — so it is [true]
      only for an enforcing workspace-write sandbox. Direct command accesses
      remain reviewable unless another explicit rule decides them. *)

  val with_session_rules :
    Spice_permission.Policy.Rule.t list -> 'src t -> 'src t
  (** [with_session_rules rules t] is [t] with [rules] prepended as its
      highest-precedence rows, deciding before every durable, preset, and
      sandbox-backed row.

      These are a reviewer's in-session "always allow" grants: a session-scoped
      family rule takes effect for the rest of the run — including within the
      turn that installed it, because {!Run.make}'s policy is rebuilt from the
      posture each turn — without waiting for a durable config write to load.
      The rows borrow the preset's provenance, so {!find} and {!denial_message}
      read them as preset rows; since "always allow" only installs allow rules,
      they never decide a denial. Rules already present by content (equal
      {!rule_id}) are skipped, so re-installing the same rule is idempotent. *)

  val with_web_docs_allowlist : 'src t -> 'src t
  (** [with_web_docs_allowlist t] is [t] extended with an allow row per
      {!web_docs_allowlist} host, appended after every existing row so a durable
      [deny] of one of those hosts still decides first.

      Run assembly applies it to every posture: reading documentation is
      read-only regardless of the edit/command posture, so the credit does not
      depend on the sandbox or the preset. The rows carry the preset's
      provenance and match only network accesses, so they auto-allow an
      in-process [web_fetch] to a listed host while leaving shell commands —
      which the sandbox confines — untouched. *)

  val preset : 'src t -> Preset.t
  (** [preset t] is the selected permission preset. *)

  val rows : 'src t -> 'src row list
  (** [rows t] are [t]'s rows in evaluation order. *)

  val find : 'src t -> Spice_permission.Policy.Rule.t -> 'src row option
  (** [find t rule] is the first row whose rule equals [rule], or [None] if no
      row holds [rule]. Since row order is evaluation order, this is the row
      that decided [rule]; use it to label {!Spice_permission.Policy.explain}
      results with identity and provenance. *)

  val policy : 'src t -> Spice_permission.Policy.t
  (** [policy t] is the pure permission policy that decides protected operations
      under [t]. *)

  val denial_message :
    source:('src -> string) ->
    'src t ->
    Spice_permission.Policy.Denial.t ->
    string
  (** [denial_message ~source t denial] is the model-visible tool-result text
      for an unrecoverable policy denial decided under [t]. [source] renders the
      provenance annotation of the deciding row.

      A denial under the [Plan] preset caused by its command-deny rule yields
      steering text pointing the model at the read-only tools. Any other denial
      names the deciding rule's identity and rendered source, falling back to a
      bare policy-denial message when no row holds the deciding rule. *)
end
