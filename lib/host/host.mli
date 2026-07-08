(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Loaded host values.

    A host combines effective configuration with a deterministic list of static
    provider declarations. Host workflows interpret those values for application
    and CLI tasks without redefining provider or model identities.

    Host loading is non-secret. Credential stores, provider clients, network
    checks, and instruction file contents are handled by adjacent workflows. *)

(** {1:errors Errors} *)

module Error : sig
  (** Recoverable host assembly errors.

      This is the single error type for the host assembly chain: loading the
      host, resolving models, resolving credentials, building provider clients,
      resolving the workspace, and building the instruction prelude all error
      with values of this type. Constructors are grouped by what the user must
      do to recover, not by which library detected the failure; inner errors are
      carried as data for diagnostics only.

      Error messages never contain credential material. *)

  type t =
    | Config of Config.Error.t
        (** Effective configuration loading failed. Recovery: fix the config
            file, environment variable, or override named by the inner error. *)
    | Duplicate_provider of Spice_llm.Provider.t
        (** The provider list contains the same provider id more than once.
            Recovery: fix the host's provider registration. *)
    | Unknown_provider of {
        provider : Spice_llm.Provider.t;
        field : Config.Field.any option;
        known : string list;
      }
        (** A referenced provider is not registered in the host. [field] is the
            config field that named it, if the reference came from
            configuration. [known] are the registered provider ids, for hints.
            Recovery: fix the provider reference or register the provider. *)
    | Unknown_model of {
        provider : Spice_llm.Provider.t;
        model : string;
        field : Config.Field.any option;
        known : string list;
      }
        (** A registered provider does not declare the referenced model. [field]
            is the config field that named it, if the reference came from
            configuration. [known] are the provider's declared model ids, for
            hints. Recovery: fix the model reference. *)
    | Invalid_selector of {
        input : string;
        message : string;
        candidates : string list;
      }
        (** User-supplied model text is not a valid [provider/model] selector.
            [candidates] are canonical selectors whose model id matches [input],
            for hints; a bare model id resolves to its provider this way.
            Recovery: spell the model as [provider/model]. *)
    | Not_selectable of {
        selector : string;
        status : Spice_provider.Model.status;
        field : Config.Field.any option;
      }
        (** The referenced model is declared but its lifecycle status is not
            selectable. [field] is the config field that named it, if the
            reference came from configuration. Recovery: select a selectable
            model or clear the configured one. *)
    | Missing_capability of {
        selector : string;
        capability : Spice_provider.Model.Capability.t;
        alternative : string option;
      }
        (** The model lacks a capability the requested run needs. [alternative]
            is a selectable same-provider canonical selector, for hints, when
            one exists. Recovery: pick a model with the capability. *)
    | Unsupported_reasoning of {
        selector : string;
        effort : Spice_llm.Request.Options.Reasoning_effort.t;
        supported : Spice_llm.Request.Options.Reasoning_effort.t list;
      }
        (** The explicitly requested reasoning effort is not in the model's
            supported efforts. Recovery: request a supported effort or drop the
            request. *)
    | No_model
        (** No selectable model exists for the requested workflow. Recovery:
            register a provider with selectable models or configure one. *)
    | Missing_credential of Spice_llm.Provider.t
        (** No credential resolved for the provider. Recovery: log in or supply
            a credential. *)
    | Blocked_credential of {
        provider : Spice_llm.Provider.t;
        problems : Spice_account.Problem.t list;
      }
        (** The provider permanently rejected the credential's refresh during
            this assembly; the run is certainly doomed until the user acts.
            Recovery: run [spice auth status PROVIDER] and the repair command it
            names, typically a login. *)
    | Unsupported_credential of {
        provider : Spice_llm.Provider.t;
        kind : Spice_account.Secret.Kind.t;
      }
        (** The resolved credential kind cannot be used by the provider's
            adapter. Recovery: log in with a supported credential kind. *)
    | Credentials of {
        provider : Spice_llm.Provider.t option;
        message : string;
      }
        (** A credential source failed: an environment value could not be
            decoded, or the credential store could not be read. Recovery: fix
            the credential source. The message contains no credential material.
        *)
    | No_adapter of Spice_llm.Provider.t
        (** No registered adapter covers the provider. Recovery: fix the host
            provider registration. *)
    | Client of { provider : Spice_llm.Provider.t; message : string }
        (** An adapter failed to construct a provider client. Recovery depends
            on [message]; the failure is local construction, not a provider
            response. *)
    | Instructions of Spice_llm.Request.Error.t
        (** Host-generated prelude messages did not satisfy request-prelude
            invariants. Workspace context projection cannot produce this; it
            remains for workflow-mode prelude extension. Recovery: report the
            programmer error. *)
    | Workspace of { cwd : string; message : string }
        (** The configured working directory could not be resolved as a
            workspace root. Recovery: fix the working directory. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic.

      Messages are intended for users and tests, not stable storage. They never
      contain credential material. *)

  val diagnostic : t -> Spice_diagnostic.t
  (** [diagnostic e] is [e] rendered as a host diagnostic.

      The diagnostic message is {!message}. Errors that carry candidate
      knowledge, such as {!constructor:Unknown_model} and {!constructor:Config}
      key errors, contribute ["did you mean ...?"] hints. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e]'s message for diagnostics. *)
end

(** {1:runtime-providers Runtime providers} *)

module Adapter : sig
  (** Effectful capabilities for one provider package: building clients,
      checking, refreshing, or revoking credentials, and managing provider-owned
      local artifacts. *)

  type build =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    ?base_url:string ->
    Spice_account.Credential.t option ->
    (Spice_llm.Client.t, Error.t) result
  (** The type for client-building functions.

      Adapter functions are effectful provider capabilities. They do not carry a
      provider id; the enclosing {!Provider.t} registration supplies the
      provider namespace. [None] means no credential resolved; the adapter
      decides whether that is {!Error.Missing_credential} (mandatory auth) or a
      bare client (optional auth, no-auth). *)

  type observation = {
    problems : Spice_account.Problem.t list;
    profile : Spice_account.Profile.t option;
    org : Spice_account.Org.t option;
    models : string list option;
  }
  (** Credential-free facts observed by a provider check. *)

  type check =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    ?base_url:string ->
    Spice_account.Credential.t ->
    (observation, Error.t) result
  (** The type for credential-check functions. A check validates a credential
      against the provider and returns credential-free {!observation}s. *)

  type refresh =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    now:Spice_account.timestamp ->
    ?auth_base_url:string ->
    Spice_account.Secret.t ->
    (Spice_account.Secret.t, Spice_account.Problem.t) result
  (** The type for secret-refresh functions. A refresh renews an expiring secret
      as of [now], producing a renewed secret or the problem that blocks it. *)

  type revoke =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    ?auth_base_url:string ->
    Spice_account.Secret.t ->
    (unit, Spice_account.Problem.t) result
  (** The type for secret-revocation functions. A revoke invalidates a secret at
      the provider. *)

  type artifact_prepare =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    cancelled:(unit -> bool) ->
    observe:(Spice_protocol.Model_artifact.progress -> unit) ->
    Spice_provider.Model.t ->
    (unit, Spice_llm.Error.t) result
  (** The type for local model-artifact preparation functions.

      [artifact_prepare ~sw ~stdenv ~cancelled ~observe model] ensures that
      local artifacts required by [model] are ready before the first provider
      stream. [observe] receives provider-neutral progress updates suitable for
      interactive surfaces. Errors are provider-boundary LLM errors because
      preparation is part of serving the first model request. *)

  type artifact_download =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    force:bool ->
    observe:(Spice_protocol.Model_artifact.progress -> unit) ->
    Spice_provider.Model.t ->
    Spice_protocol.Model_artifact.download_outcome
  (** The type for explicit model-artifact download functions.

      [download ~sw ~stdenv ~force ~observe model] resolves [model]'s artifact
      status and, when the artifact is missing, fetches and installs it,
      reporting progress through [observe]. [force] overrides a provider guard
      such as a memory-budget refusal. Unlike {!artifact_prepare}, which serves
      the first model request, this is the user-driven [spice models download]
      path and returns a provider-neutral
      {!Spice_protocol.Model_artifact.download_outcome} rather than failing the
      run. *)

  type model_artifact = {
    status :
      Spice_provider.Model.t -> Spice_protocol.Model_artifact.status option;
    prepare : artifact_prepare;
    download : artifact_download;
  }
  (** Optional adapter capability for provider-owned local artifacts.

      Registering this capability means the adapter can report passive artifact
      status, prepare missing artifacts before use, and service an explicit
      force-able download. Providers with no local artifact lifecycle leave the
      whole capability absent. *)

  type t
  (** Effectful capabilities for one provider package. *)

  val make :
    build:build ->
    ?check:check ->
    ?refresh:refresh ->
    ?revoke:revoke ->
    ?model_artifact:model_artifact ->
    unit ->
    t
  (** [make ~build ()] is an adapter with the given capabilities. Only [build]
      is required; providers register the optional capabilities they support. *)

  val build :
    t ->
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    ?base_url:string ->
    Spice_account.Credential.t option ->
    (Spice_llm.Client.t, Error.t) result
  (** [build t ~sw ~stdenv ?base_url credential] builds a provider client with
      [t]'s {!type:build} capability. [base_url] overrides the adapter's default
      endpoint. [credential] is [None] when no credential resolved; see
      {!type:build} for how adapters answer it. *)

  val check : t -> check option
  (** [check t] is [t]'s credential-check capability, if any. *)

  val refresh : t -> refresh option
  (** [refresh t] is [t]'s secret-refresh capability, if any. *)

  val revoke : t -> revoke option
  (** [revoke t] is [t]'s secret-revocation capability, if any. *)

  val model_artifact : t -> model_artifact option
  (** [model_artifact t] is [t]'s local model-artifact capability, if any. *)
end

module Provider : sig
  (** A provider registration: a static declaration paired with an optional
      runtime adapter. *)

  type t
  (** Host registration for one provider package.

      The declaration remains pure {!Spice_provider.t} data. The optional
      adapter is the host-side interpreter for building clients and checking or
      refreshing credentials. *)

  val make : Spice_provider.t -> ?adapter:Adapter.t -> unit -> t
  (** [make declaration ?adapter ()] registers [declaration] with an optional
      runtime [adapter]. *)

  val declaration : t -> Spice_provider.t
  (** [declaration t] is [t]'s static provider declaration. *)

  val adapter : t -> Adapter.t option
  (** [adapter t] is [t]'s runtime adapter, if any. *)
end

module Provider_registry : sig
  (** The ordered set of provider registrations known to a host. *)

  type t
  (** Validated host provider registry.

      A registry is the ordered set of provider declarations known to the host,
      with optional runtime adapters for provider packages that can build
      clients, check credentials, refresh OAuth secrets, or revoke secrets. *)

  val make : Provider.t list -> (t, Error.t) result
  (** [make providers] is a provider registry preserving [providers] order.

      Errors with {!constructor:Error.Duplicate_provider} if two entries declare
      the same provider id. *)

  val entries : t -> Provider.t list
  (** [entries t] are [t]'s runtime provider registrations in order. *)

  val providers : t -> Spice_provider.t list
  (** [providers t] are [t]'s static declarations in registration order. *)

  val catalog : t -> Spice_provider.Catalog.t
  (** [catalog t] is [t]'s pure provider/model catalog. *)

  val provider : t -> Spice_llm.Provider.t -> Spice_provider.t option
  (** [provider t id] is [id]'s static declaration, if registered. *)

  val adapter : t -> Spice_llm.Provider.t -> Adapter.t option
  (** [adapter t id] is [id]'s runtime adapter, if registered. *)

  val provider_ids : t -> string list
  (** [provider_ids t] are [t]'s registered provider ids in order. *)
end

(** {1:host Host} *)

type t
(** Loaded host.

    Values are non-secret. They are immutable snapshots: later config-file,
    environment, or provider declaration changes do not affect an existing
    value. *)

val make :
  config:Config.t -> registry:Provider_registry.t -> unit -> (t, Error.t) result
(** [make ~config ~registry ()] is a host.

    [registry] supplies static provider declarations and any runtime adapters
    registered for those providers. *)

val load :
  stdenv:Eio_unix.Stdenv.base ->
  registry:Provider_registry.t ->
  ?cwd:string ->
  ?config:Config.t ->
  unit ->
  (t, Error.t) result
(** [load ~stdenv ~registry ()] is a host for [registry].

    If [config] is absent, {!Config.load} resolves the effective host
    configuration using its defaults; [cwd], when present, overrides the working
    directory it resolves against. [cwd] is unused when [config] is supplied. *)

val config : t -> Config.t
(** [config t] is [t]'s effective host configuration. *)

val providers : t -> Spice_provider.t list
(** [providers t] is [t]'s provider declarations in registration order. *)

val catalog : t -> Spice_provider.Catalog.t
(** [catalog t] is [t]'s pure provider/model catalog. *)

val registry : t -> Provider_registry.t
(** [registry t] is [t]'s provider registry. *)

val runtime_providers : t -> Provider.t list
(** [runtime_providers t] is [t]'s host provider registrations in registration
    order. *)

val provider : t -> Spice_llm.Provider.t -> Spice_provider.t option
(** [provider t id] is [id]'s provider declaration, if registered. *)

val adapter : t -> Spice_llm.Provider.t -> Adapter.t option
(** [adapter t id] is [id]'s host adapter, if registered. *)

val require_provider :
  t ->
  Spice_llm.Provider.t ->
  (Spice_provider.t, [ `Unknown_provider of Spice_llm.Provider.t ]) result
(** [require_provider t id] is [id]'s provider declaration.

    Errors with [`Unknown_provider id] if [id] is not registered. The narrow
    error lets a caller lift the failure into a full
    {!constructor:Error.Unknown_provider} with its own [field] and [known] hint
    context. *)

val provider_ids : t -> string list
(** [provider_ids t] are [t]'s registered provider ids in registration order.

    This is the candidate list carried by {!constructor:Error.Unknown_provider}
    for hints. *)
