(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Credential candidates and credential-free account readiness.

    [spice.account] defines the pure account vocabulary shared by hosts,
    provider adapters, status surfaces, and session diagnostics.

    The interface separates secret-bearing values from account status:

    - {!Secret.t}, {!Credential.t}, and {!Store.t} may contain secret material.
    - {!type:t} contains credential-free account facts.

    Credential-free values may still contain privacy-sensitive metadata such as
    email addresses, organization names, environment variable names, and stored
    credential names. Hosts decide which logging, diagnostics, or session
    surfaces may store them.

    The library performs no I/O. It does not read environment variables, open
    credential stores, use keychains, run OAuth flows, refresh tokens, validate
    accounts, construct provider clients, or discover model catalogs. Hosts and
    provider packages own those effects and lower their observations into this
    vocabulary. *)

type timestamp = int64
(** Unix timestamp in seconds.

    Constructors that accept timestamps reject negative values. The type does
    not encode a clock source; callers decide whether a timestamp comes from a
    provider response, local wall clock, or persisted observation. *)

(** {1:secrets Secrets} *)

module Secret : sig
  type t
  (** Provider- and source-free secret credential payload.

      Secret values are the result of API-key entry, OAuth flows, token refresh,
      environment decoding, and credential-store loading. They deliberately do
      not carry provider identity or provenance; the host/account interpreter
      attaches those at the credential boundary. *)

  module Kind : sig
    (** Credential kind without credential material. *)
    type t =
      | Api_key  (** API-key credential material. *)
      | Bearer  (** Bearer-token credential material. *)
      | OAuth  (** OAuth access-token credential material. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same credential kind. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics.

        The output contains no credential material and is not stable storage
        syntax. *)
  end

  val api_key : string -> t
  (** [api_key key] is an API-key secret.

      Raises [Invalid_argument] if [key] is empty. *)

  val bearer : string -> t
  (** [bearer token] is a bearer-token secret.

      Raises [Invalid_argument] if [token] is empty. *)

  val oauth :
    access_token:string ->
    ?refresh_token:string ->
    ?expires_at:timestamp ->
    ?account_id:string ->
    unit ->
    t
  (** [oauth ~access_token ()] is an OAuth token secret.

      [expires_at], if present, is the absolute expiration timestamp in Unix
      seconds. [account_id], if present, is provider-specific credential
      metadata and is not used as a {!Profile.t}.

      Raises [Invalid_argument] if [access_token], [refresh_token], or
      [account_id] is empty, or if [expires_at] is negative. *)

  val kind : t -> Kind.t
  (** [kind t] is [t]'s credential kind without secret material. *)

  val fingerprint : t -> string option
  (** [fingerprint t] is a short redacted identifier for [t], if one can be
      derived safely.

      API-key and bearer fingerprints are the last 4 characters of the material;
      material shorter than 8 characters has no fingerprint, since no suffix
      would avoid disclosing most of the secret. OAuth fingerprints are the
      credential account id when present, which is stable across token refresh,
      and otherwise the last 4 characters of the access token under the same
      length rule.

      Fingerprints identify which credential is in use and detect credential
      changes behind persisted readiness; credentials without a fingerprint
      never match persisted readiness. Fingerprints are safe to show in output:
      they contain at most 4 characters of secret material. *)

  val expires_at : t -> timestamp option
  (** [expires_at t] is [t]'s expiry for OAuth secrets that declare one, and
      [None] otherwise.

      Expiry is credential-free metadata: hosts use it to decide when a refresh
      is needed without exposing token material. *)

  val has_refresh_token : t -> bool
  (** [has_refresh_token t] is [true] iff [t] is an OAuth secret carrying a
      refresh token.

      Credential-free: reveals no secret material. Hosts use it with
      {!expires_at} to schedule refreshes without exposing token material. *)

  val expose :
    t ->
    api_key:(key:string -> 'a) ->
    bearer:(token:string -> 'a) ->
    oauth:
      (access_token:string ->
      refresh_token:string option ->
      expires_at:timestamp option ->
      account_id:string option ->
      'a) ->
    'a
  (** [expose t ~api_key ~bearer ~oauth] applies the matching callback to [t]'s
      secret-bearing payload.

      {b Warning.} This is the deliberate escape hatch for provider adapters,
      auth-flow interpreters, and credential persistence. The supplied callbacks
      must not write secret material to logs, diagnostics, model-visible state,
      or credential-free session metadata. *)
end

(** {1:credentials Credentials} *)

module Credential : sig
  module Name : sig
    (** Provider-local names for saved credentials. *)

    type t
    (** Provider-local name for a saved credential.

        Names select saved secrets within a provider namespace. They are not
        provider account ids and they do not imply which credential is active
        for a run. Host config or runtime choice decides which name to read. *)

    val default : t
    (** [default] is the conventional name used when no name is configured. *)

    val make : string -> t
    (** [make s] is credential name [s].

        [s] must be non-empty and contain only ASCII letters, digits, [_], [-],
        and [.]. Raises [Invalid_argument] otherwise. *)

    val to_string : t -> string
    (** [to_string t] is [t]'s stable storage spelling. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same credential name. *)

    val compare : t -> t -> int
    (** [compare a b] orders credential names by storage spelling. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics. *)
  end

  module Source : sig
    (** Credential provenance.

        [Process] credentials were supplied directly by the host process.
        [Env name] credentials came from shell-compatible environment variable
        [name]. [Store name] credentials came from a provider-local stored
        credential name. Stored credential names are not secret, but they may
        still be privacy-sensitive display or routing metadata. *)
    type t = private Process | Env of string | Store of Name.t

    val process : t
    (** [process] is process-local credential provenance. *)

    val env : string -> t
    (** [env name] is environment-variable credential provenance.

        [name] must be non-empty shell-compatible environment-variable syntax:
        an ASCII letter or [_] followed by ASCII letters, digits, or [_]. Raises
        [Invalid_argument] otherwise. *)

    val store : ?name:Name.t -> unit -> t
    (** [store ?name ()] is stored credential provenance.

        [name] defaults to {!Name.default}. *)

    val tag : t -> [ `Process | `Env | `Store ]
    (** [tag t] is [t]'s provenance kind without its name. *)

    val name : t -> string option
    (** [name t] is the environment variable name for [Env], the credential
        name's storage spelling for [Store], and [None] for [Process]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same credential source. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics.

        The output contains no credential material and is not stable storage
        syntax. *)
  end

  type t
  (** One provider credential candidate.

      Credential values may contain secret material. They must not be written to
      logs, session events, model-visible conversation state, or diagnostics.
      Use {!type:Spice_account.t} for credential-free account facts.

      Credentials are abstract so callers cannot accidentally inspect secret
      fields. Provider adapters that must attach credentials to requests use
      {!secret} and {!Secret.expose}. *)

  val make : provider:Spice_llm.Provider.t -> source:Source.t -> Secret.t -> t
  (** [make ~provider ~source secret] routes [secret] to [provider] with
      provenance [source].

      The function does not validate [secret] with the provider and performs no
      I/O. Provider adapters decide whether the secret kind is supported. *)

  val provider : t -> Spice_llm.Provider.t
  (** [provider t] is [t]'s provider route. *)

  val source : t -> Source.t
  (** [source t] is [t]'s credential provenance. *)

  val kind : t -> Secret.Kind.t
  (** [kind t] is [t]'s credential kind without credential material. *)

  val fingerprint : t -> string option
  (** [fingerprint t] is {!Secret.fingerprint} of [t]'s secret. *)

  val secret : t -> Secret.t
  (** [secret t] is [t]'s provider/source-free secret payload.

      {b Warning.} The returned value is secret-bearing. Prefer {!Secret.kind}
      unless the caller explicitly needs to persist or use the secret. Use
      {!Secret.expose} to inspect the payload. *)
end

val resolve : Credential.t list -> Spice_llm.Provider.t -> Credential.t option
(** [resolve credentials provider] is the first credential in [credentials]
    whose provider is [provider], if any.

    Resolution is pure and performs no I/O. Hosts express credential precedence
    by list order. *)

(** {1:stores Stores} *)

module Store : sig
  type t
  (** A user-scoped credential-store snapshot.

      A store is inert provider/name-indexed data. It answers which secret is
      saved under a provider credential name. It does not choose which name a
      run should use, and it has no active-account or active-name invariant.

      The store provides no filesystem, keychain, locking, migration, or
      encryption behavior. Hosts own how snapshots are loaded and saved. *)

  val empty : t
  (** [empty] contains no stored credentials. *)

  val of_list : (Spice_llm.Provider.t * Credential.Name.t * Secret.t) list -> t
  (** [of_list bindings] is a store snapshot containing [bindings].

      Raises [Invalid_argument] if a provider/name pair appears more than once.
  *)

  val names : t -> provider:Spice_llm.Provider.t -> Credential.Name.t list
  (** [names t ~provider] is [provider]'s saved credential names in
      deterministic {!Credential.Name.compare} order. *)

  val secret :
    t ->
    provider:Spice_llm.Provider.t ->
    ?name:Credential.Name.t ->
    unit ->
    Secret.t option
  (** [secret t ~provider ?name ()] is the stored secret for [provider]/[name],
      if present. [name] defaults to {!Credential.Name.default}. *)

  val credential :
    t ->
    provider:Spice_llm.Provider.t ->
    ?name:Credential.Name.t ->
    unit ->
    Credential.t option
  (** [credential t ~provider ?name ()] is the stored credential for
      [provider]/[name], if present.

      [name] defaults to {!Credential.Name.default}. Returned credentials use
      {!Credential.Source.store} with the selected name as their provenance. *)

  val bindings :
    ?provider:Spice_llm.Provider.t ->
    t ->
    (Spice_llm.Provider.t * Credential.Name.t * Secret.t) list
  (** [bindings ?provider t] is [t]'s stored provider/name/secret bindings in
      deterministic provider/name order. If [provider] is supplied, only
      bindings for that provider are returned.

      {b Warning.} The returned list contains secret material. It is intended
      for persistence and trusted store editing, not diagnostics. *)

  val set :
    provider:Spice_llm.Provider.t ->
    ?name:Credential.Name.t ->
    Secret.t ->
    t ->
    t
  (** [set ~provider ?name secret t] stores [secret] under [provider]/[name],
      replacing any existing secret for that provider/name pair. [name] defaults
      to {!Credential.Name.default}. The returned store preserves deterministic
      provider/name ordering. *)

  val remove :
    t -> provider:Spice_llm.Provider.t -> ?name:Credential.Name.t -> unit -> t
  (** [remove t ~provider ?name ()] is [t] without [provider]/[name]. [name]
      defaults to {!Credential.Name.default}. Removing an absent binding leaves
      the store unchanged. *)

  val jsont : t Jsont.t
  (** [jsont] maps store snapshots to JSON, including secret credential
      material.

      {b Warning.} This codec is persistence syntax for trusted storage, not
      diagnostic output.

      The decoder accepts only version [1]. It rejects unknown fields, duplicate
      provider or name fields, invalid provider ids, invalid names, malformed
      secrets, and obsolete formats. *)
end

(** {1:subjects Profiles and organizations} *)

module Profile : sig
  type t = private {
    id : string option;
    email : string option;
    name : string option;
  }
  (** Credential-free provider account profile.

      Profiles identify the signed-in account independently of credentials and
      organization selection. They contain no credential material, but may still
      be privacy-sensitive. Hosts decide which logs, diagnostics, or session
      metadata may include them. *)

  val make : ?id:string -> ?email:string -> ?name:string -> unit -> t
  (** [make ()] is a provider account profile.

      Raises [Invalid_argument] if all fields are omitted or if a provided
      string field is empty. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same profile. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics.

      The output contains no credential material and is not stable storage
      syntax. *)
end

module Org : sig
  (** Credential-free organization and workspace selection. *)

  type t = private { id : string; name : string option }
  (** Credential-free organization or workspace selection.

      Organizations are the account scope selected for provider and console
      operations. Account discovery, organization listing, and switching are
      host effects; {!Org.t} is only the credential-free selected scope observed
      for an account. *)

  val make : id:string -> ?name:string -> unit -> t
  (** [make ~id ()] is an organization selection.

      Raises [Invalid_argument] if [id] or [name] is empty. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same organization. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics.

      The output contains no credential material and is not stable storage
      syntax. *)
end

(** {1:problems Problems} *)

module Problem : sig
  type label
  (** Checked label for an unknown provider-neutral account problem. *)

  (** Provider-neutral account readiness problem.

      [Other label] is for stable labels not yet represented by a dedicated
      constructor. Use {!other} to construct unknown labels.

      Problems are account facts, not UI actions. Login prompts, refresh
      buttons, retry labels, and administrator guidance belong to product
      surfaces that interpret these facts. *)
  type t =
    | Invalid_credential  (** Credential is malformed or rejected. *)
    | Expired_credential  (** Credential has expired. *)
    | Refresh_failed  (** Credential refresh failed. *)
    | Revoked  (** Credential was revoked. *)
    | Wrong_account  (** Credential resolves to the wrong provider account. *)
    | Wrong_organization  (** Credential resolves to the wrong organization. *)
    | Rate_limited  (** Account or credential is rate limited. *)
    | Quota_exceeded  (** Account or credential has exhausted quota. *)
    | Network  (** Account check failed due to network availability. *)
    | Unsupported  (** Provider cannot perform the requested account check. *)
    | Other of label  (** Unknown provider-neutral problem label. *)

  val other : string -> t
  (** [other label] is an account problem with unknown provider-neutral label
      [label].

      [label] must start with an ASCII lowercase letter and then contain only
      ASCII lowercase letters, digits, and [_]. Labels reserved by dedicated
      constructors are rejected. Raises [Invalid_argument] otherwise. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable storage spelling. *)

  val of_string : string -> t option
  (** [of_string s] decodes stable storage spelling [s].

      Unknown valid, non-reserved spellings decode to [Some (Other label)].
      Invalid spellings decode to [None]. *)

  val fatal : t -> bool
  (** [fatal t] is [true] iff only user action can fix [t]: exactly
      [Invalid_credential], [Expired_credential], [Refresh_failed], [Revoked],
      [Wrong_account], and [Wrong_organization].

      Fatal problems make new runs certainly doomed until the user acts, so they
      are the only problems that may block a run; see {!phase}. Problems that
      self-heal ([Network], [Rate_limited], [Quota_exceeded]) and problems of
      unknown nature ([Unsupported], [Other]) are not fatal. *)

  val transient : t -> bool
  (** [transient t] is [true] iff [t] self-heals within seconds to minutes:
      exactly [Network] and [Rate_limited].

      Transient problems are observations too short-lived to persist; hosts
      report them without replacing previously durable readiness. *)

  val compare : t -> t -> int
  (** [compare a b] orders problems by stable storage label.

      The order is compatible with {!equal}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same problem. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics.

      The output contains no credential material and is not stable storage
      syntax. *)
end

(** {1:accounts Accounts} *)

module State : sig
  (** Credential-resolution state for one provider route.

      [t] is a small view of whether account facts are missing, merely present,
      or checked. It is independent of {!phase}, which derives product readiness
      from checked problems. *)
  type t =
    | Missing  (** No credential resolved for the provider route. *)
    | Present  (** A credential resolved, but no account check completed. *)
    | Checked  (** A host or provider account observation completed. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable diagnostic spelling. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s stable diagnostic spelling. *)
end

type t
(** Credential-free account facts for one provider route.

    Account values never retain API keys, bearer tokens, OAuth access tokens,
    refresh tokens, authorization codes, callback URLs, PKCE verifiers, or
    device codes. Constructors that accept {!Credential.t} immediately project
    the supplied secret-bearing credential to credential-free account facts.

    A [State.Missing] account has no resolved credential facts and no checked
    facts. A [State.Present] account has scalar credential facts such as
    {!source}, {!credential_kind}, and {!fingerprint}, but no checked facts. A
    [State.Checked] account has those scalar credential facts, normalized
    problems, and any optional checked facts supplied by the host. *)

type phase = [ `Missing | `Unchecked | `Ready | `Degraded | `Blocked ]
(** Derived route readiness phase for product surfaces. *)

val phase_to_string : phase -> string
(** [phase_to_string t] is [t]'s stable diagnostic spelling. *)

val pp_phase : Format.formatter -> phase -> unit
(** [pp_phase ppf t] formats [t]'s stable diagnostic spelling. *)

val missing : provider:Spice_llm.Provider.t -> t
(** [missing ~provider] is account status for a provider route with no resolved
    credential.

    [source], [credential_kind], [checked_at], [profile], and [org] are [None];
    [problems] is [[]]. *)

val present : Credential.t -> t
(** [present credential] is account status for a resolved credential that has
    not been checked.

    [present credential] keeps the provider, source, and credential kind, but
    does not retain [credential]'s secret material. [checked_at], [profile], and
    [org] are [None]; [problems] is [[]]. *)

val checked :
  Credential.t ->
  ?at:timestamp ->
  ?profile:Profile.t ->
  ?org:Org.t ->
  ?problems:Problem.t list ->
  ?models:string list ->
  unit ->
  t
(** [checked credential ?at ?profile ?org ?problems ?models ()] is account
    status for a resolved credential after host or provider observation.

    [problems] defaults to [[]]. An empty list means the route was checked and
    no account problem was observed. Non-empty [problems] are provider-neutral
    facts about why the route may be degraded or unusable. Problems are
    deduplicated and stored in {!Problem.compare} order.

    [profile], if present, is the credential-free provider account. [org], if
    present, is the selected organization or workspace scope. [at], if present,
    is the Unix timestamp in seconds for the observation. [models], if present,
    is the set of provider-visible model ids revealed by the check.

    [checked] keeps the provider, source, and credential kind, but does not
    retain [credential]'s secret material. Models are deduplicated and stored in
    [String.compare] order.

    Raises [Invalid_argument] if [at] is negative. *)

val provider : t -> Spice_llm.Provider.t
(** [provider t] is [t]'s provider route. *)

val state : t -> State.t
(** [state t] is [t]'s credential-resolution state. *)

val phase : t -> phase
(** [phase t] is [t]'s derived readiness phase.

    [State.Missing] is [`Missing] and [State.Present] is [`Unchecked].
    [State.Checked] is [`Ready] without problems, [`Blocked] when any problem is
    {!Problem.fatal}, and [`Degraded] otherwise. *)

val source : t -> Credential.Source.t option
(** [source t] is the resolved credential source for [State.Present] and
    [State.Checked] accounts, and [None] for [State.Missing] accounts. *)

val credential_kind : t -> Secret.Kind.t option
(** [credential_kind t] is the resolved credential kind for [State.Present] and
    [State.Checked] accounts, and [None] for [State.Missing] accounts. *)

val fingerprint : t -> string option
(** [fingerprint t] is the resolved credential fingerprint, if one can be
    derived safely, and [None] otherwise.

    [fingerprint t] is always [None] for [State.Missing] accounts. *)

val checked_at : t -> timestamp option
(** [checked_at t] is the observation timestamp for checked accounts, if
    recorded, and [None] for missing or unchecked-present accounts. *)

val profile : t -> Profile.t option
(** [profile t] is the credential-free provider account profile observed by an
    account check, if any, and [None] for missing or unchecked-present accounts.
*)

val org : t -> Org.t option
(** [org t] is the credential-free organization or workspace scope observed by
    an account check, if any, and [None] for missing or unchecked-present
    accounts. *)

val problems : t -> Problem.t list
(** [problems t] is the sorted, duplicate-free list of checked account problems.

    [problems t] is [[]] for missing and unchecked-present accounts. *)

val models : t -> string list option
(** [models t] are provider-visible model ids revealed by a check, if any. *)

val model_available : t -> string -> [ `Available | `Unavailable | `Unknown ]
(** [model_available t model] is whether the check revealed [model] as visible
    to the account. [`Unknown] means the route was not checked or the check did
    not reveal model entitlement. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same provider, status,
    credential summary, checked facts, and normalized problems. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics.

    The output contains no credential material and is not stable storage syntax.
*)

val jsont : t Jsont.t
(** [jsont] maps account status values to credential-free JSON.

    The codec uses versioned storage syntax. Encoded values contain no
    credential material. They may contain privacy-sensitive profile,
    organization, and credential-source metadata, so hosts still decide which
    logging or session surfaces may store them.

    The decoder accepts only version [1]. It rejects unknown fields, unknown
    statuses, invalid providers, invalid credential sources or kinds, malformed
    profiles or organizations, invalid problem labels, missing credential facts
    for [present] or [checked] statuses, and checked-only facts on [missing] or
    [present] statuses. Problems decoded from JSON are normalized with the same
    duplicate-removal and ordering rules as {!checked}. *)
