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
