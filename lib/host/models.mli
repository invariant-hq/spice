(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Host model selection.

    This module interprets a {!Host.t}'s effective configuration and static
    provider declarations to answer product-level model questions: which model
    fills a role, what a user-supplied selector resolves to, and whether a
    chosen model meets a coding run's static requirements. Selected models are
    {!Spice_provider.Model.t} values; host does not wrap or redefine provider
    model metadata.

    {b Purity.} Every function is pure. None performs I/O, credential
    resolution, permission evaluation, client construction, or provider network
    requests. Each takes the narrowest value that determines its result: catalog
    lookups take the static provider list, config-dependent role resolution
    takes a {!Host.t}, and the run gate takes the explained choice. Errors are
    {!Host.Error.t} values, so model workflows render through the same
    diagnostics as the rest of the host assembly chain. *)

(** {1:model_choice Model choices} *)

module Model_choice : sig
  (** An explained model choice: a selected model paired with the {!Reason.t}
      that explains why it won. *)

  type role =
    | Main
    | Small
        (** Host model roles.

            [Main] is the conversation model used for coding turns. [Small] is
            the auxiliary same-provider model used for cheaper host tasks when
            one is available, with deterministic fallback to [Main]. *)

  type t
  (** The type for an explained model choice. *)

  val model : t -> Spice_provider.Model.t
  (** [model t] is the selected provider model. *)

  val reason : t -> Reason.t
  (** [reason t] explains why {!model} was selected. *)

  val require :
    ?reasoning_effort:Spice_llm.Request.Options.Reasoning_effort.t ->
    Spice_provider.Catalog.t ->
    t ->
    (unit, Host.Error.t) result
  (** [require ?reasoning_effort catalog t] checks [t] against the static
      requirements of a coding run.

      The gate is pure: it performs no credential or provider network checks. It
      requires selectability, tool support, and, when [reasoning_effort] is
      supplied, that the model supports that effort. [catalog] is used only to
      compute a diagnostic alternative for a missing capability.

      Errors with {!Host.Error.Not_selectable} if the model's lifecycle status
      is not selectable, {!Host.Error.Missing_capability} if it lacks tool
      support, or {!Host.Error.Unsupported_reasoning} if the requested effort is
      unsupported. *)
end

(** {1:roles Role resolution} *)

val choose :
  Host.t -> Model_choice.role -> (Model_choice.t, Host.Error.t) result
(** [choose host role] is [host]'s model for [role], explained.

    The main model is the configured selector, else the first provider default,
    else the first selectable model; when none exists it errors with
    {!Host.Error.No_model}. The small model is the configured selector, else the
    cheapest selectable same-provider text model, else a fallback to the main
    model. A configured selector resolves through the same rules as {!resolve},
    so a configured but unresolvable selector surfaces its resolution error. *)

(** {1:resolving Resolving user input} *)

val resolve :
  Spice_provider.Catalog.t -> string -> (Model_choice.t, Host.Error.t) result
(** [resolve catalog input] resolves user-supplied selector text.

    [input] must spell a canonical [provider/model] selector. The returned
    choice has an explicit reason. Resolution is not eligibility: hidden and
    non-selectable models resolve so callers can explain their status.

    Undeclared model ids resolve through the provider's declared
    {!Spice_provider.dynamic_model} policy, so explicit weight paths such as
    ["local//tmp/model.gguf"] and daemon-owned ids such as
    ["ollama/qwen3-coder:30b"] are selectable when their provider declares them.
    Resolution stays pure: whether the id names real weights is checked by the
    provider at request time, not here.

    Errors with {!Host.Error.Invalid_selector} if [input] is not selector
    syntax; the error carries canonical selectors whose model id matches [input]
    exactly or nearly, so a bare id such as ["gpt-5.5"] hints
    ["openai/gpt-5.5"]. Errors with {!Host.Error.Unknown_provider} or
    {!Host.Error.Unknown_model}, with candidate ids for hints, if the selector
    does not resolve. *)

val for_select :
  Spice_provider.Catalog.t ->
  string ->
  (Spice_provider.Model.t, Host.Error.t) result
(** [for_select catalog input] validates [input] for persisting as a model
    selection and returns the model to persist.

    This is {!resolve} followed by the selectability check, and it is the single
    validation path shared by [spice models select] and
    [spice config set model]/[small_model]. Errors as {!resolve} does, or with
    {!Host.Error.Not_selectable} if the resolved model's lifecycle status is not
    selectable. *)
