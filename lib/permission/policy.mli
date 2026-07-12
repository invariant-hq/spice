(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Permission policy evaluation.

    A policy decides whether permission requests may proceed, need reviewer
    input, or are denied. Policies are pure values: deciding a request does not
    run operations, prompt users, mutate state, or write audit records.

    The rule language matches trusted {!Access.t} facts. Product presets, config
    loading, prompt lifecycle state, shell parsing, and platform-specific
    normalization are separate concerns.

    Evaluation is ordered and conservative. The first matching rule decides an
    access, rules are checked before runtime grants, denied accesses stop the
    request, and unmatched ungranted accesses require review. Grouped requests
    proceed only when every normalized access is allowed.

    Rule constructors raise [Invalid_argument] when their arguments cannot
    satisfy the documented invariants. The JSON codec reports the same invalid
    states as decode errors. *)

(** {1:policies Policies} *)

type t
(** The type for permission policies.

    A policy contains ordered rules only. Runtime grants are supplied separately
    to {!decide} and are not part of policy equality or JSON. *)

module Match : sig
  (** Access matchers for policy rules. *)

  type t
  (** The type for access matchers.

      Matchers are validated descriptions of access facts. Network matchers
      assume the host has already canonicalized hosts, protocols, and ports for
      the target platform.

      Matching uses exact OCaml value and string equality after this host
      normalization. Matchers are inert policy data and do not authorize
      operations until a rule containing them is evaluated by {!decide}. *)

  val any : t
  (** [any] matches every access. *)

  val kind : Access.kind -> t
  (** [kind k] matches accesses whose {!Access.kind} is [k]. *)

  val exact : Access.t -> t
  (** [exact access] matches [access] exactly. *)

  module Path : sig
    (** Matchers for classified path scopes. *)

    type t
    (** The type for path scope matchers. *)

    val exact : Spice_workspace.Path.t -> t
    (** [exact path] matches path accesses whose scope is exactly [path]. *)

    val exact_key :
      root_key:Spice_workspace.Root.Key.t -> relative:Spice_path.Rel.t -> t
    (** [exact_key ~root_key ~relative] matches path accesses in workspace
        [root_key] whose root-relative path is exactly [relative]. *)

    val under : Spice_workspace.Path.t -> t
    (** [under path] matches path accesses at or under [path]'s workspace
        subtree. *)

    val under_key :
      root_key:Spice_workspace.Root.Key.t -> relative:Spice_path.Rel.t -> t
    (** [under_key ~root_key ~relative] matches path accesses in workspace
        [root_key] at or under [relative]. *)

    val exact_relative : Spice_path.Rel.t -> t
    (** [exact_relative relative] matches workspace path accesses whose
        root-relative path is exactly [relative], in any workspace root. *)

    val under_relative : Spice_path.Rel.t -> t
    (** [under_relative relative] matches workspace path accesses at or under
        [relative], in any workspace root. *)

    val workspace : t
    (** [workspace] matches every path access proven inside a workspace. *)

    val outside_workspace : t
    (** [outside_workspace] matches every path access proven outside the
        workspace. *)

    val unknown : t
    (** [unknown] matches every path access whose workspace relation is unknown.
    *)
  end

  val path : ?op:Access.path_op -> Path.t -> t
  (** [path ?op scope] matches path accesses whose scope matches [scope],
      restricted by [op] when provided. *)

  module Command : sig
    (** Matchers for command facts. *)

    type t
    (** The type for command fact matchers. *)

    val any : t
    (** [any] matches every command access. *)

    val destructive : t
    (** [destructive] matches command accesses that can irreversibly delete or
        overwrite data the model never named, or escalate out of confinement —
        currently recursive or forced [rm], [git push --force],
        [git reset --hard], [git clean --force], [dd], [shred], [mkfs],
        [sudo]/[doas], and opaque dynamic shell evaluation.

        Placed as a {!Rule.review} rule before a broad command {!Rule.allow},
        this keeps such commands reviewable even under a posture that otherwise
        allows commands, because a sandbox bounds where a command writes but not
        whether the loss is recoverable. The classifier reads the already-parsed
        argv structurally, recursively inspects standard shell and pass-through
        wrappers, and falls back to a lenient token scan for shell text.
        Command substitutions and dynamic evaluation review conservatively;
        the classifier deliberately over-flags rather than miss a form hidden
        by shell syntax. It is host command-safety policy, not a proof: a match
        is worth review, and a non-match is not a guarantee of safety. *)

    val execution : Access.Command.execution -> t
    (** [execution route] matches command accesses whose host-produced
        execution fact is [route]. *)

    val exact : Access.Command.t -> t
    (** [exact command] matches command accesses equal to [command]. *)

    val argv_prefix :
      execution:Access.Command.execution ->
      cwd:Path.t ->
      program:string ->
      args:string list ->
      unit ->
      t
    (** [argv_prefix ~execution ~cwd ~program ~args ()] matches [Argv] command
        accesses through [execution] whose working directory matches [cwd],
        whose program is [program], and whose arguments start with [args].
        Shell and code commands never match.

        Raises [Invalid_argument] if [program] is empty. *)
  end

  val command : Command.t -> t
  (** [command pattern] matches command accesses whose command fact matches
      [pattern]. *)

  val network_host :
    ?protocol:Access.network_protocol -> ?port:int -> host:string -> unit -> t
  (** [network_host ?protocol ?port ~host ()] matches network accesses to
      [host], restricted by [protocol] and [port] when provided.

      [host], [protocol], and [port] are matched exactly. The matcher does not
      case-fold host names, resolve DNS aliases, canonicalize IP literals, or
      infer default ports. If [port] is provided, only accesses with the same
      explicit port match; an access with [port = None] does not imply a
      protocol default.

      Raises [Invalid_argument] if [host] is empty, if [protocol] is
      [`Other ""], or if [port] is outside \[[1];[65535]\]. *)

  val custom : ?subject:string -> string -> t
  (** [custom ?subject name] matches caller-defined accesses with [name],
      restricted by [subject] when provided.

      Raises [Invalid_argument] if [name] or [subject] is empty when present. *)

  val matches : t -> Access.t -> bool
  (** [matches m access] is [true] iff [m] accepts [access]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf m] formats matcher [m] for diagnostics. The output is not stable
      storage syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps matchers to tagged JSON objects.

      Unknown object members and constructor-invalid matcher states are decoding
      errors. *)
end

module Rule : sig
  (** Policy rules. *)

  type action =
    | Allow
    | Review
    | Deny  (** The type for the action a matching rule applies. *)

  type t
  (** The type for policy rules. *)

  val make : action -> Match.t -> t
  (** [make action matcher] is a rule applying [action] to accesses matched by
      [matcher]. *)

  val allow : Match.t -> t
  (** [allow m] allows accesses matched by [m]. *)

  val review : Match.t -> t
  (** [review m] asks for reviewer input for accesses matched by [m]. *)

  val deny : Match.t -> t
  (** [deny m] denies accesses matched by [m]. *)

  val always_review : t
  (** [always_review] asks for reviewer input for every access before runtime
      grants are consulted.

      Since rule evaluation happens before grants, this deliberately makes
      session grants ineffective while the rule is present. *)

  val deny_all : t
  (** [deny_all] denies every access. *)

  val allow_all_dangerously : t
  (** [allow_all_dangerously] allows every access.

      This is intentionally explicit because it disables permission review for
      accesses not denied or reviewed by earlier rules. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same rule. *)

  val action : t -> action
  (** [action rule] is the action applied when [rule] matches. *)

  val matcher : t -> Match.t
  (** [matcher rule] is the matcher evaluated by [rule]. *)

  val stable_text : t -> string
  (** [stable_text rule] is a canonical textual representation of [rule]'s
      action and matcher suitable as digest input.

      The format is internal but stable for the current rule schema, mirroring
      {!Access.stable_text}. It is not intended for display, user input, or
      decoding. Layers above the core derive product rule identities by
      digesting this text instead of storing id fields. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats a rule for diagnostics. The output is not stable storage
      syntax. *)

  val jsont : t Jsont.t
  (** [jsont] maps rules to JSON objects.

      Unknown object members and constructor-invalid matcher states are decoding
      errors. *)
end

(** {1:constructing Constructing policies} *)

val default : t
(** [default] has no rules. Runtime grants apply; accesses without a matching
    grant ask for reviewer input.

    This is not the same as a {!Rule.always_review} rule: runtime grants still
    allow exact repeated accesses. *)

val make : Rule.t list -> t
(** [make rules] is a policy with ordered [rules].

    When several rules match an access, the first matching rule wins. Accesses
    matched by no rule ask for reviewer input. *)

module Denial : sig
  (** Denied accesses. *)

  type t
  (** The type for an access denied by a policy rule.

      Denials retain the original request, the first denied access in normalized
      request order, and the rule that denied it. *)

  val request : t -> Request.t
  (** [request d] is the request that contained the denied access. *)

  val access : t -> Access.t
  (** [access d] is the denied access. *)

  val rule : t -> Rule.t
  (** [rule d] is the rule that denied {!access} [d]. *)
end

(** {1:grants Runtime grants} *)

module Grants : sig
  (** Runtime exact grants.

      Grants are session state, not durable policy. They are created from
      reviewed accesses and store exact {!Access.t} values. A grant never
      broadens to access class, path prefix, command family, or network host. *)

  type t
  (** The type for runtime grants. *)

  val empty : t
  (** [empty] contains no grants. *)

  val allows : t -> Access.t -> bool
  (** [allows g a] is [true] iff [g] contains an exact grant for [a]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] contain the same grants. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats grants for diagnostics. The output is not stable storage
      syntax. *)
end

(** {1:reviews Reviews} *)

module Review : sig
  (** Pending reviewer decisions produced by policy evaluation. *)

  type reason = Unmatched | By_rule of Rule.t
  (** The captured reason an access needs review. [Unmatched] means no rule or
      exact grant decided it. [By_rule rule] retains the first matching review
      rule; callers must not recompute this history against a later policy. *)

  type t
  (** The type for a non-empty subset of request accesses needing reviewer
      input. *)

  type restore_error =
    | Empty_accesses
    | Access_not_in_request of Access.t
        (** Why a durable review could not be reconstructed. *)

  val restore :
    Request.t -> (Access.t * reason) list -> (t, restore_error) result
  (** [restore request reasons] reconstructs a review from durable session
      state. [Ok review] contains the subset of [request]'s normalized accesses
      selected by [reasons], with their captured reasons, in request order.
      [Error Empty_accesses] means [reasons] is empty; [Error
      (Access_not_in_request access)] means [access] is not present in [request].

      Normal callers get reviews from {!decide}. *)

  val request : t -> Request.t
  (** [request review] is the request covered by [review]. *)

  val accesses : t -> Access.t list
  (** [accesses review] is the non-empty normalized access list covered by
      [review], in request order. *)

  val access_set : t -> Access.Set.t
  (** [access_set review] is the exact set of access identities covered by
      [review]. *)

  val reasons : t -> (Access.t * reason) list
  (** [reasons review] is the non-empty normalized access and captured-reason
      list covered by [review], in request order. *)

  val items : t -> Request.Item.t list
  (** [items review] is every request item whose access is covered by [review],
      in original request item order. Duplicate access identities are preserved.
  *)

  val changes : t -> Request.Change.t list
  (** [changes review] is the planned-change metadata attached to {!items},
      omitting items without change metadata. *)

  type scope = Once | Session  (** The scope of a reviewer approval. *)
  type answer = Allow of scope | Deny  (** Reviewer answer to a review. *)

  type resolved =
    | Proceed of Grants.t
    | Rejected  (** The result of applying a reviewer answer. *)

  val resolve : grants:Grants.t -> t -> answer -> resolved
  (** [resolve ~grants review answer] applies [answer] to [review]. *)

  val grant : t -> scope -> Grants.t -> Grants.t
  (** [grant review scope grants] extends [grants] with [review]'s accesses for
      an allow answer of [scope]: [Session] adds them and [Once] leaves [grants]
      unchanged. A [Session] allow of a non-{!Request.grantable} request also
      leaves [grants] unchanged, capping that approval at a single use. It is
      the allow half of {!resolve}, total by construction, for callers that
      already know the answer is an allow. *)
end

(** {1:decisions Decisions} *)

module Decision : sig
  (** Policy decisions. *)

  type t =
    | Allowed
    | Review of Review.t
    | Denied of Denial.t * Denial.t list
        (** The type for policy decisions. [Denied (first, rest)] contains every
            denied access in normalized request order. *)
end

(** {1:evaluating Evaluating policies} *)

(** The type for single-access policy explanations.

    Explanations are evaluation provenance for audit, debugging, and policy
    tests. They do not contain UI text, denial messages, prompt identifiers, or
    reviewer feedback. *)
type explanation =
  | Allowed_by_rule of Rule.t
      (** The access was allowed by the first matching allow rule. *)
  | Allowed_by_grant  (** The access was allowed by an exact session grant. *)
  | Needs_review  (** The access matched no rule and no grant. *)
  | Needs_review_by_rule of Rule.t
      (** The access needs review because of the first matching review rule. *)
  | Denied_by_rule of Rule.t
      (** The access was denied by the first matching deny rule. *)

val decide : ?grants:Grants.t -> t -> Request.t -> Decision.t
(** [decide ?grants p r] is [r]'s policy decision under [p] and [grants].

    [grants] defaults to {!Grants.empty}. Rules are evaluated before grants: if
    a rule matches an access, its action decides that access. If no rule matches
    an access, an exact grant allows it. Accesses matched by no rule and no
    grant need reviewer input.

    Requests are evaluated in {!Request.normalized_accesses} order, preserving
    the first occurrence of exact duplicate access facts. If any access is
    denied, [Decision.Denied] is returned with all denied accesses in that
    order. Otherwise, if at least one access needs reviewer input,
    [Decision.Review] is returned and {!Review.accesses} contains only the
    accesses that need review. Otherwise [Decision.Allowed] is returned. *)

val explain : ?grants:Grants.t -> t -> Access.t -> explanation
(** [explain ?grants p a] is the policy provenance for [a] under [p] and
    [grants].

    Rules are evaluated before grants: the first matching rule explains the
    result even if [grants] would allow [a]. [grants] defaults to
    {!Grants.empty}. *)

(** {1:predicates Predicates and comparisons} *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] contain the same policy state. *)

(** {1:fmt Formatting} *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a policy for diagnostics. The output is not stable storage
    syntax. *)

(** {1:json JSON} *)

val jsont : t Jsont.t
(** [jsont] maps policies to versioned JSON objects.

    Runtime {!Grants.t} values are intentionally not encoded. Unknown object
    members and constructor-invalid rule states are decoding errors. *)
