(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host account state.

    [Account] owns the host's account state: passive credential resolution, the
    user credential store, and on-demand provider checks. It interprets explicit
    process credentials, provider-declared environment credentials, and an
    explicit user credential store into {!Spice_account} values.

    Checked readiness is ephemeral: it is produced by login validation,
    [status --refresh], and run-time refresh, and reported to the caller without
    being persisted. Passive inspection reports credential presence only, like
    the reference agents; the provider is the only authority on validity, so
    Spice never caches a claim about it.

    Login orchestration stays outside this module: browser handoff, device-code
    polling, and user prompting are CLI workflows composed from [Spice_auth]
    primitives and the storage functions here.

    {b Secrets.} A value of {!t} and the credentials it resolves carry secret
    material. Error messages never do. *)

type t
(** Secret-bearing account-resolution snapshot.

    A value combines a loaded host with explicit credential sources. It is
    separate from host loading so callers can choose when secret-bearing
    environment and store state is read. *)

(** {1:errors Errors} *)

module Error : sig
  (** Recoverable account errors.

      Error messages never contain credential material. *)

  type t =
    | Unknown_provider of Spice_llm.Provider.t
        (** The requested provider is not registered in the host. *)
    | Env of {
        provider : Spice_llm.Provider.t;
        name : string;
        message : string;
      }
        (** A non-empty provider-declared environment variable could not be
            decoded as a secret. *)
    | Store of string
        (** The credential store could not be loaded, decoded, locked, encoded,
            or saved. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic. Messages are intended for
      users and tests, not stable storage, and contain no credential material.
  *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)

  val to_host : Host.t -> t -> Host.Error.t
  (** [to_host host e] is [e] as a host assembly error.

      Host workflows that report {!Host.Error.t} values project account
      resolution failures through this one function, so a single mapping decides
      how credential-store, environment, and unknown-provider failures appear as
      host errors. *)
end

(** {1:stored-credentials Stored credentials} *)

module Store : sig
  (** The user credential store: the persisted secret layer that {!load}
      snapshots. Mutations serialize on a filesystem lock and write atomically.
  *)

  val save :
    stdenv:Eio_unix.Stdenv.base ->
    host:Host.t ->
    provider:Spice_llm.Provider.t ->
    ?name:Spice_account.Credential.Name.t ->
    Spice_account.Secret.t ->
    (unit, Error.t) result
  (** [save ~stdenv ~host ~provider ?name secret] stores [secret] for [provider]
      under [name], replacing any existing stored secret for that pair.

      [name] defaults to {!Spice_account.Credential.Name.default}. The store is
      loaded, edited, and saved under a filesystem lock; the parent directory is
      created when needed, and the write uses a temporary file and rename.

      Errors with {!Error.Unknown_provider} if [provider] is not registered, or
      {!Error.Store} if a store file cannot be loaded, decoded, locked, encoded,
      or saved. *)

  val remove :
    stdenv:Eio_unix.Stdenv.base ->
    host:Host.t ->
    provider:Spice_llm.Provider.t ->
    ?name:Spice_account.Credential.Name.t ->
    unit ->
    (unit, Error.t) result
  (** [remove ~stdenv ~host ~provider ?name ()] removes the stored credential
      for [provider] under [name]. A missing credential is left missing.

      [name] defaults to {!Spice_account.Credential.Name.default}. The store is
      loaded, edited, and saved under a filesystem lock; the parent directory is
      created when needed, and the write uses a temporary file and rename.

      Errors with {!Error.Unknown_provider} if [provider] is not registered, or
      {!Error.Store} if a store file cannot be loaded, decoded, locked, encoded,
      or saved. *)
end

(** {1:endpoints Provider endpoints} *)

val provider_auth_base_url :
  Host.t -> provider:Spice_llm.Provider.t -> string option
(** [provider_auth_base_url host ~provider] is [provider]'s auth endpoint root
    override, if set.

    The override is read from [SPICE_<PROVIDER>_AUTH_BASE_URL] in the host
    configuration's process-environment snapshot, with non-alphanumeric provider
    id characters mapped to [_]. Empty values are ignored. *)

(** {1:resolving Resolving} *)

val load :
  stdenv:Eio_unix.Stdenv.base ->
  ?process:Spice_account.Credential.t list ->
  Host.t ->
  (t, Error.t) result
(** [load ~stdenv host] loads credential sources for [host] and returns an
    account-resolution snapshot.

    [process] overrides process credentials for this snapshot. A missing store
    is empty. Errors with {!Error.Store} if the store cannot be loaded or
    decoded. *)

val credential :
  t ->
  ?name:Spice_account.Credential.Name.t ->
  Spice_llm.Provider.t ->
  (Spice_account.Credential.t option, Error.t) result
(** [credential t ?name provider] is [provider]'s resolved credential, if any.

    Resolution checks explicit process credentials, then non-empty environment
    variables declared by [provider], then the stored credential [name]. The
    first credential whose provider matches wins, so process credentials shadow
    environment and store credentials. [name] defaults to
    {!Spice_account.Credential.Name.default}. Errors with
    {!Error.Unknown_provider} if [provider] is not registered, or {!Error.Env}
    if an environment value cannot be decoded.

    {b Warning.} The returned credential may contain secret material. *)

val status :
  t ->
  ?name:Spice_account.Credential.Name.t ->
  Spice_llm.Provider.t ->
  (Spice_account.t, Error.t) result
(** [status t ?name provider] is [provider]'s credential-free passive account
    status.

    The function performs no provider I/O and no credential refresh. A missing
    credential is reported as missing; a resolved credential is reported as
    present without checking whether the provider will accept it. *)

val connected :
  t -> Spice_llm.Provider.t -> bool
(** [connected t provider] is whether a credential resolved for [provider] in
    [t]'s snapshot: passive {!status} phase [`Ready], [`Degraded], or
    [`Unchecked]. [`Missing], [`Blocked], and resolution failures read as
    [false] — connectivity feeds preferences (default-model choice, login
    nudges, panel locks); it never gates a client build. *)

val connectivity :
  stdenv:Eio_unix.Stdenv.base ->
  ?process:Spice_account.Credential.t list ->
  Host.t ->
  Spice_llm.Provider.t ->
  bool
(** [connectivity ~stdenv host] is {!connected} over a freshly loaded snapshot,
    the one-line way to supply {!Models.choose}'s [connected] argument. A
    snapshot load failure reads as nothing connected, so a broken store
    degrades the choice to registry order rather than failing it. *)

val names :
  t ->
  Spice_llm.Provider.t ->
  (Spice_account.Credential.Name.t list, Error.t) result
(** [names t provider] is [provider]'s stored credential names in [t]'s store
    snapshot, in store-defined order.

    Reading the snapshot rather than the store file means names and resolved
    credentials describe the same point in time. Errors with
    {!Error.Unknown_provider} if [provider] is not registered. *)

(** {1:checking Checking and refreshing}

    These workflows mint host-shaped failures — an adapter check error, a
    blocked credential — that have no {!Error.t} equivalent, so they error with
    {!Host.Error.t} rather than {!Error.t}. *)

val check :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  now:Spice_account.timestamp ->
  ?name:Spice_account.Credential.Name.t ->
  t ->
  Spice_llm.Provider.t ->
  (Spice_account.t, Host.Error.t) result
(** [check ~sw ~stdenv ~now t provider] validates [provider]'s resolved
    credential with one provider request and returns the resulting view. Nothing
    is persisted: the result is this command's to report.

    A missing credential returns the missing account's view without checking. A
    provider whose registered adapter has no check capability returns the
    resolved credential's view explicitly unchecked, never a fake problem. [now]
    is the timestamp reported as the account's checked time.

    Errors are host assembly errors; an adapter check may error for local
    misuse. The returned view and any error contain no secret material. *)

val refresh :
  sw:Eio.Switch.t ->
  stdenv:Eio_unix.Stdenv.base ->
  now:Spice_account.timestamp ->
  ?force:bool ->
  ?name:Spice_account.Credential.Name.t ->
  t ->
  Spice_llm.Provider.t ->
  (Spice_account.Credential.t option, Host.Error.t) result
(** [refresh ~sw ~stdenv ~now t provider] is the concurrency-safe OAuth refresh
    transaction for [provider]'s stored credential.

    Under the credential store lock it reloads the stored credential — another
    process may have refreshed it already — and returns [Ok None] without a
    provider request when there is no stored credential, the credential has no
    refresh token, the registered adapter has no refresh capability, or the
    credential is not within 300 seconds of expiry. [force] skips the expiry
    test; the reload-first rule still applies, so concurrent processes cannot
    spend the same rotated refresh token.

    A successful provider refresh persists the rotated secret atomically and
    returns the replacement credential. A permanent refresh rejection errors
    with {!Host.Error.Blocked_credential} carrying
    {!Spice_account.Problem.Refresh_failed}: the run that discovered the dead
    refresh token fails immediately with the repair guidance, and nothing is
    cached — the next run learns the same truth live. Transient failures change
    nothing and return [Ok None].

    The provider token endpoint honors the auth endpoint override reported by
    {!provider_auth_base_url}. *)
