(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Static provider declarations.

    [spice.provider] describes providers and their known models without loading
    host runtime state. It is pure: it performs no config reads, environment
    reads, credential-store I/O, account checks, token refreshes, provider
    requests, policy evaluation, or login orchestration.

    Provider packages construct {!Model.t} values, group them with {!make}, and
    export one static declaration. Hosts compose declarations as ordinary lists,
    use the lookup functions at the end of this interface to resolve provider
    and model selectors, and interpret environment declarations against
    {!Spice_account} credentials.

    This module annotates existing [spice.llm] identities. It does not redefine
    provider namespaces, model identities, API families, clients, endpoints, or
    request options. *)

(** {1:selectors Model selectors} *)

module Selector : sig
  type t
  (** A parsed [provider/model] selector. It names a provider namespace and a
      provider-local model id; it does not assert that either is declared in any
      catalog. *)

  module Error : sig
    type t
    (** The reason a string is not a valid [provider/model] selector. *)

    val message : t -> string
    (** [message e] is a human-readable diagnostic for [e]. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf e] formats [e] for diagnostics. *)
  end

  val of_string : string -> (t, Error.t) result
  (** [of_string s] parses [s] as [provider/model].

      Leading and trailing whitespace is ignored. Errors when [s] is empty, has
      no ['/'] separator, has an empty provider or model segment, or has a
      provider segment that is not a valid provider namespace. *)

  val provider : t -> Spice_llm.Provider.t
  (** [provider t] is [t]'s provider namespace. *)

  val id : t -> string
  (** [id t] is [t]'s provider-local model id. *)
end

(** {1:auth Authentication declarations} *)

module Auth : sig
  (** Pure provider authentication declarations.

      Auth declarations describe what credential sources and login methods are
      available. They do not read environment variables, open browsers, perform
      OAuth requests, prompt users, poll, or mutate credential stores. *)

  module Env : sig
    type t
    (** Provider-local environment credential declaration.

        An env declaration states how one environment variable is interpreted as
        provider/source-free credential material. It does not read the variable,
        store its value, or carry a provider id; the owning auth declaration
        supplies that identity when a host resolves account state. *)

    val api_key : string -> t
    (** [api_key name] declares API-key material in environment variable [name].

        Raises [Invalid_argument] if [name] is not an environment variable name:
        a non-empty ASCII identifier starting with a letter or ['_'] and
        followed by letters, digits, or ['_']. *)

    val bearer : string -> t
    (** [bearer name] declares bearer-token material in environment variable
        [name].

        Raises [Invalid_argument] if [name] is not an environment variable name;
        see {!api_key}. *)

    val oauth_access_token : string -> t
    (** [oauth_access_token name] declares OAuth access-token material in
        environment variable [name].

        Raises [Invalid_argument] if [name] is not an environment variable name;
        see {!api_key}. *)

    val name : t -> string
    (** [name t] is [t]'s environment variable name. *)

    val kind : t -> Spice_account.Secret.Kind.t
    (** [kind t] is the declared credential kind produced by {!secret}. *)

    module Error : sig
      type t =
        | Invalid_secret of {
            name : string;
            kind : Spice_account.Secret.Kind.t;
            message : string;
          }
            (** The environment variable value cannot be interpreted as the
                declaration's secret kind. [message] contains no credential
                material. *)

      val message : t -> string
      (** [message e] is a human-readable diagnostic. *)

      val pp : Format.formatter -> t -> unit
      (** [pp ppf e] formats [e] for diagnostics. *)
    end

    val secret : t -> string -> (Spice_account.Secret.t, Error.t) result
    (** [secret t value] interprets [value] according to [t].

        Errors with [Error.Invalid_secret] if [value] is empty or invalid for
        [t]'s declared credential kind. The returned value is secret-bearing. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics.

        The output contains no credential material and is not stable storage
        syntax. *)
  end

  module Login : sig
    (** Provider-declared login methods. *)

    module Protocol : sig
      (** Provider login protocol declarations. *)

      type oauth2_device_code = {
        device_client : Oauth2.Client.t;
        device_endpoint : Uri.t;
        device_token_endpoint : Uri.t;
        device_scope : string list;
        device_extra : (string * string) list;
      }
      (** Standard OAuth 2.0 device-code protocol parameters. *)

      type oauth2_authorization_code = {
        authorization_client : Oauth2.Client.t;
        authorization_endpoint : Uri.t;
        authorization_token_endpoint : Uri.t;
        redirect_uri : Uri.t option;
        authorization_scope : string list;
        authorization_extra : (string * string) list;
        pkce : bool;
      }
      (** Standard OAuth 2.0 authorization-code protocol parameters. *)

      (** Provider login protocol declaration.

          Protocol values are static parameters. Hosts decide how to present and
          run a protocol; this type does not contain callbacks or effectful
          login code. *)
      type t =
        | Api_key  (** Manual API-key entry. *)
        | OAuth2_device_code of oauth2_device_code
            (** Standard OAuth 2.0 device-code flow. *)
        | OAuth2_authorization_code of oauth2_authorization_code
            (** Standard OAuth 2.0 authorization-code flow. *)
        | Provider_device_code of { provider_flow : string }
            (** A provider-specific device flow that Spice drives but that is
                not RFC 8628. [provider_flow] names the host interpreter that
                runs it, for example ["openai_chatgpt"]. The string is a seam
                between the provider declaration and the host login layer; it is
                not interpreted by this library. *)
        | External of { instructions : string option }
            (** Provider login that is completed outside Spice. [instructions],
                when present, is user-facing guidance from the provider
                declaration. *)
    end

    type t
    (** Provider-declared login method.

        Values are pure declarations. They do not carry runnable login functions
        or frontend callbacks. *)

    val make : id:string -> label:string -> Protocol.t -> t
    (** [make ~id ~label protocol] is a login method.

        Method ids are provider-local tags. They start with a lowercase ASCII
        letter and then contain lowercase letters, digits, ['-'], or ['_'].

        Raises [Invalid_argument] if [id] is not a valid method tag or [label]
        is empty. *)

    val api_key : ?id:string -> ?label:string -> unit -> t
    (** [api_key ()] declares an API-key login method.

        [id] defaults to ["api-key"] and [label] defaults to ["API key"]. Raises
        [Invalid_argument] if the supplied [id] or [label] is invalid; see
        {!make}. *)

    val oauth2_device_code :
      ?id:string ->
      ?label:string ->
      ?scope:string list ->
      ?extra:(string * string) list ->
      client:Oauth2.Client.t ->
      device_endpoint:Uri.t ->
      token_endpoint:Uri.t ->
      unit ->
      t
    (** [oauth2_device_code ...] declares a standard OAuth device-code login
        method.

        [id] defaults to ["device-code"], [label] defaults to ["Device code"],
        [scope] defaults to [[]], and [extra] defaults to [[]]. Raises
        [Invalid_argument] if the supplied [id] or [label] is invalid; see
        {!make}. *)

    val oauth2_authorization_code :
      ?id:string ->
      ?label:string ->
      ?scope:string list ->
      ?extra:(string * string) list ->
      ?redirect_uri:Uri.t ->
      ?pkce:bool ->
      client:Oauth2.Client.t ->
      authorization_endpoint:Uri.t ->
      token_endpoint:Uri.t ->
      unit ->
      t
    (** [oauth2_authorization_code ...] declares a standard OAuth browser login
        method.

        [id] defaults to ["browser"], [label] defaults to ["Browser"], [scope]
        defaults to [[]], [extra] defaults to [[]], and [pkce] defaults to
        [true]. Raises [Invalid_argument] if the supplied [id] or [label] is
        invalid; see {!make}. *)

    val id : t -> string
    (** [id t] is [t]'s provider-local method id. *)

    val label : t -> string
    (** [label t] is [t]'s user-facing method label. *)

    val protocol : t -> Protocol.t
    (** [protocol t] is [t]'s protocol declaration. *)
  end

  type t
  (** Provider authentication declarations.

      Environment and login lists preserve declaration order. Environment names
      and login ids are unique within one auth declaration. *)

  val none : t
  (** [none] declares no auth inputs or login methods. *)

  val make :
    ?required:bool -> ?env:Env.t list -> ?login:Login.t list -> unit -> t
  (** [make ?required ?env ?login ()] is an auth declaration.

      [env] and [login] default to [[]]. [required] states whether a usable
      credential is mandatory to use the provider; it defaults to [true] when
      [env] or [login] declares a method and to [false] otherwise. Declaring
      [~required:false] alongside methods describes optional authentication: a
      self-hosted provider that serves unauthenticated by default but accepts a
      credential when its deployment demands one.

      Raises [Invalid_argument] if two environment declarations use the same
      variable name, if two login methods use the same method id, or if
      [required] is [true] while no method is declared. *)

  val required : t -> bool
  (** [required t] is whether a usable credential is mandatory to use the
      provider. [false] for {!none} and for optional-auth declarations. *)

  val env : t -> Env.t list
  (** [env t] is [t]'s provider-local environment credential declarations. *)

  val logins : t -> Login.t list
  (** [logins t] is [t]'s provider-declared login methods. *)

  val login_by_id : t -> string -> Login.t option
  (** [login_by_id t id] is the login method declared as [id], if any. *)
end

(** {1:models Model metadata} *)

module Model : sig
  module Date : sig
    (** Calendar dates for provider metadata. *)

    type t
    (** The type for calendar dates.

        Dates are provider metadata, for example model release dates. They have
        no timezone or time-of-day component. *)

    val make : year:int -> month:int -> day:int -> t
    (** [make ~year ~month ~day] is the date [year]-[month]-[day].

        Raises [Invalid_argument] if [year] is outside \[[1];[9999]\] or if the
        fields do not form a valid Gregorian calendar date. *)

    val of_string : string -> t option
    (** [of_string s] parses [s] as [YYYY-MM-DD].

        The spelling must be exactly ten bytes with zero-padded month and day.
        Invalid dates decode to [None]. *)

    val to_string : t -> string
    (** [to_string t] is [t] formatted as [YYYY-MM-DD]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same date. *)

    val compare : t -> t -> int
    (** [compare a b] orders dates chronologically.

        The order is compatible with {!equal}. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as [YYYY-MM-DD]. *)
  end

  module Modality : sig
    (** Model input and output modalities. *)

    type t
    (** The type for model input and output modalities.

        Tags use the extension grammar accepted by {!extension}: a lowercase
        ASCII letter followed by lowercase letters, digits, ['-'], or ['_']. *)

    val text : t
    (** [text] is the text modality. *)

    val image : t
    (** [image] is the image modality. *)

    val audio : t
    (** [audio] is the audio modality. *)

    val video : t
    (** [video] is the video modality. *)

    val pdf : t
    (** [pdf] is the PDF document modality. *)

    val extension : string -> t
    (** [extension s] is extension modality [s].

        Raises [Invalid_argument] if [s] is not valid modality syntax or if [s]
        is reserved for a dedicated constructor. *)

    val to_string : t -> string
    (** [to_string t] is [t]'s stable diagnostic spelling. *)

    val of_string : string -> t option
    (** [of_string s] parses [s] as a modality.

        Built-in tags decode to their dedicated values. Unknown valid tags
        decode to [Some (extension s)]. Invalid tags decode to [None]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same modality. *)

    val compare : t -> t -> int
    (** [compare a b] orders modalities by stable spelling.

        The order is compatible with {!equal}. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics. *)
  end

  module Capability : sig
    (** Provider-neutral model behavior capabilities. *)

    type t
    (** The type for provider-neutral model behavior capability tags.

        Modalities are represented by {!Modality.t}, not by capabilities. Tags
        use the same extension grammar as {!Modality.extension}. *)

    val tools : t
    (** [tools] is the capability for tool calling. *)

    val reasoning : t
    (** [reasoning] is the capability for provider-visible reasoning controls.
    *)

    val json_schema : t
    (** [json_schema] is the capability for structured JSON-schema output. *)

    val extension : string -> t
    (** [extension s] is extension capability [s].

        Raises [Invalid_argument] if [s] is not valid capability syntax or if
        [s] is reserved for a dedicated constructor. *)

    val to_string : t -> string
    (** [to_string t] is [t]'s stable diagnostic spelling. *)

    val of_string : string -> t option
    (** [of_string s] parses [s] as a capability tag.

        Built-in tags decode to their dedicated values. Unknown valid tags
        decode to [Some (extension s)]. Invalid tags decode to [None]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same capability tag. *)

    val compare : t -> t -> int
    (** [compare a b] orders capabilities by stable spelling.

        The order is compatible with {!equal}. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] for diagnostics. *)
  end

  type price = private {
    input_per_million : float option;
    cached_input_per_million : float option;
    output_per_million : float option;
    cache_write_5m_per_million : float option;
    cache_write_1h_per_million : float option;
  }
  (** Token pricing for one context tier.

      Prices are expressed per million tokens. Missing fields mean unknown, not
      free. Values are constructed through {!price}, which enforces that every
      supplied rate is finite and non-negative; fields are read-only. *)

  type pricing = private { default : price; context_over : (int * price) list }
  (** Model pricing metadata.

      [default] applies when no context threshold matches. [context_over]
      contains overrides for requests whose context token count is strictly
      greater than the threshold. Values are constructed through
      {!make_pricing}, which stores [context_over] sorted by threshold with
      non-negative, unique thresholds; fields are read-only. *)

  val price :
    ?input_per_million:float ->
    ?cached_input_per_million:float ->
    ?output_per_million:float ->
    ?cache_write_5m_per_million:float ->
    ?cache_write_1h_per_million:float ->
    unit ->
    price
  (** [price ()] is token pricing for one context tier.

      Raises [Invalid_argument] if any supplied price is negative or not finite.
  *)

  val make_pricing : ?context_over:(int * price) list -> price -> pricing
  (** [make_pricing ?context_over default] is pricing metadata with default
      price [default].

      [context_over] defaults to [[]]. Entries are sorted by threshold. Raises
      [Invalid_argument] if a threshold is negative or repeated. *)

  val price_for : ?context_tokens:int -> pricing -> price
  (** [price_for ?context_tokens pricing] selects the price for
      [context_tokens].

      If [context_tokens] is omitted, [pricing.default] is returned. If several
      thresholds match, the greatest threshold wins. Raises [Invalid_argument]
      if [context_tokens] is negative. *)

  (** Static model lifecycle status.

      Runtime availability, credentials, config enablement, and policy are host
      facts, not model status. *)
  type status =
    | Stable  (** Generally available and selectable by default. *)
    | Preview  (** Available but provider-marked as preview or beta. *)
    | Deprecated
        (** Still visible for existing users or documentation, but not
            selectable by default. *)
    | Unavailable of string
        (** Known model that should not be offered for use. The reason is a
            diagnostic and must not contain secrets. *)

  type t
  (** Metadata for a known {!Spice_llm.Model.t}.

      The [spice.llm] model value is the canonical request identity. This value
      adds host-facing static metadata such as display name, limits, modalities,
      capabilities, cost, and lifecycle status. *)

  val make :
    Spice_llm.Model.t ->
    ?display_name:string ->
    ?family:string ->
    ?released_on:Date.t ->
    ?context_window:int ->
    ?max_output_tokens:int ->
    ?default_reasoning:Spice_llm.Request.Options.Reasoning_effort.t ->
    ?supported_reasoning:Spice_llm.Request.Options.Reasoning_effort.t list ->
    ?input_modalities:Modality.t list ->
    ?output_modalities:Modality.t list ->
    ?capabilities:Capability.t list ->
    ?pricing:pricing ->
    ?status:status ->
    unit ->
    t
  (** [make llm ()] is model metadata for [llm].

      [input_modalities] and [output_modalities] default to [[Modality.text]].
      [status] defaults to [Stable]. Other list arguments default to [[]].
      Modality, capability, and reasoning lists are stored in deterministic
      order after duplicate rejection. If [supported_reasoning] is non-empty,
      [default_reasoning], when supplied, must appear in it.

      Raises [Invalid_argument] if [display_name] is empty, [family] is empty,
      [context_window] or [max_output_tokens] is non-positive, modality tags
      contain duplicates, capability tags contain duplicates, or supported
      reasoning efforts contain duplicates, or if [default_reasoning] is
      supplied but is not in a non-empty [supported_reasoning] list. *)

  val llm : t -> Spice_llm.Model.t
  (** [llm t] is [t]'s canonical request model identity. *)

  val provider : t -> Spice_llm.Provider.t
  (** [provider t] is the provider namespace of {!llm}[ t]. *)

  val api : t -> Spice_llm.Model.Api.t
  (** [api t] is the provider-local API family of {!llm}[ t]. *)

  val id : t -> string
  (** [id t] is the provider-native model id of {!llm}[ t]. *)

  val selector : t -> string
  (** [selector t] is [provider t]/[id t].

      This is the canonical user-facing selector for writing host configuration
      and displaying unambiguous model identities. *)

  val display_name : t -> string option
  (** [display_name t] is [t]'s display name, if any. *)

  val family : t -> string option
  (** [family t] is [t]'s provider-supplied model family, if known. *)

  val released_on : t -> Date.t option
  (** [released_on t] is [t]'s release date, if known. *)

  val context_window : t -> int option
  (** [context_window t] is [t]'s context-window metadata, if known. *)

  val max_output_tokens : t -> int option
  (** [max_output_tokens t] is [t]'s output-token metadata, if known. *)

  val default_reasoning :
    t -> Spice_llm.Request.Options.Reasoning_effort.t option
  (** [default_reasoning t] is [t]'s default reasoning effort, if known. *)

  val supported_reasoning :
    t -> Spice_llm.Request.Options.Reasoning_effort.t list
  (** [supported_reasoning t] is [t]'s supported reasoning efforts in
      deterministic order. *)

  val input_modalities : t -> Modality.t list
  (** [input_modalities t] is [t]'s accepted input modalities in deterministic
      order. *)

  val output_modalities : t -> Modality.t list
  (** [output_modalities t] is [t]'s produced output modalities in deterministic
      order. *)

  val has_input_modality : Modality.t -> t -> bool
  (** [has_input_modality m t] is [true] iff [m] appears in {!input_modalities}
      [t]. *)

  val has_output_modality : Modality.t -> t -> bool
  (** [has_output_modality m t] is [true] iff [m] appears in
      {!output_modalities} [t]. *)

  val capabilities : t -> Capability.t list
  (** [capabilities t] is [t]'s capabilities in deterministic order. *)

  val has_capability : Capability.t -> t -> bool
  (** [has_capability c t] is [true] iff [c] appears in {!capabilities} [t]. *)

  val pricing : t -> pricing option
  (** [pricing t] is [t]'s pricing metadata. *)

  val cost : t -> Spice_llm.Usage.t -> float option
  (** [cost t usage] is the monetary cost of [usage] under [t]'s pricing, or
      [None] when [t] has no pricing metadata, or when a lane [usage] actually
      spent has no rate (an unknown rate is not billed as free).

      The price tier is chosen with {!price_for} for a context of
      [Spice_llm.Usage.input_total usage] (the request's input side: fresh input
      plus cache reads and writes), or [max_int] if that total overflows. Lanes
      bill against that tier as:

      - [input] at [input_per_million];
      - [cache_read] at [cached_input_per_million];
      - [cache_write] at [cache_write_5m_per_million] (the default 5-minute
        cache-write tier; the usage record does not distinguish TTLs);
      - [output] and [reasoning] at [output_per_million] (reasoning tokens bill
        as output).

      Each lane contributes [tokens / 1e6 *. rate]; a lane with zero tokens
      never forces [None] even if its rate is unknown. *)

  val status : t -> status
  (** [status t] is [t]'s static lifecycle status. *)

  val visible : t -> bool
  (** [visible t] is [true] iff [status t] is not [Unavailable _].

      This is a static lifecycle predicate. Host runtime listing may also
      consider config, credentials, policy, and other product state. *)

  val selectable : t -> bool
  (** [selectable t] is [true] iff [status t] is [Stable] or [Preview].

      This is static lifecycle eligibility only. Host runtime selection may also
      consider config, credentials, policy, and other product state. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1:providers Providers} *)

type t
(** Static provider declaration.

    A provider declaration is the provider-author extension value. It combines a
    {!Spice_llm.Provider.t} namespace with display metadata, environment
    credential declarations, known model metadata, and an optional default
    model.

    Provider declarations are immutable values. They do not imply that a client,
    credential, endpoint, or network transport exists. *)

val make :
  Spice_llm.Provider.t ->
  ?display_name:string ->
  ?auth:Auth.t ->
  ?default_model:Spice_llm.Model.t ->
  ?dynamic_model:(string -> Model.t option) ->
  Model.t list ->
  t
(** [make id ?display_name ?auth ?default_model ?dynamic_model models] is
    provider declaration [id].

    [auth] defaults to {!Auth.none}. [models] is preserved in declaration order.

    [dynamic_model], when present, interprets provider-local model ids that are
    not declared in [models]: a provider whose model set is owned by an external
    system (local weight files, a model daemon) synthesizes a {!Model.t} for ids
    it will interpret at request time and returns [None] for ids it will not.
    The function must be pure — no filesystem or network reads — and must return
    models whose provider is [id]; whether the id resolves to real weights is
    the provider client's runtime concern.

    Raises [Invalid_argument] if [display_name] is empty, if a model's provider
    is not [id], if two models have the same provider-local id or canonical
    {!Spice_llm.Model.t}, or if [default_model] is supplied but is not declared
    in [models] or is not {!Model.selectable}.

    Provider declarations are static. This function performs no environment
    reads, credential checks, config reads, or provider I/O. Empty model lists
    are valid. *)

val id : t -> Spice_llm.Provider.t
(** [id t] is [t]'s provider namespace. *)

val display_name : t -> string option
(** [display_name t] is [t]'s display name, if any. *)

val auth : t -> Auth.t
(** [auth t] is [t]'s pure auth declaration. *)

val dynamic_model : t -> string -> Model.t option
(** [dynamic_model t id] is the synthesized metadata for undeclared
    provider-local model id [id], when [t] declares a dynamic-model policy and
    that policy accepts [id]. Ids declared in {!models} are not consulted here;
    resolve them with {!model}. *)

val default_model : t -> Model.t option
(** [default_model t] is [t]'s default model metadata, if declared. *)

val models : t -> Model.t list
(** [models t] is [t]'s known models in declaration order. *)

val model : t -> Spice_llm.Model.t -> Model.t option
(** [model t llm] is [llm]'s metadata if [llm] is declared by [t]. *)

(** Pure indexed provider/model catalogs. *)
module Catalog : sig
  type declaration = t
  (** A provider declaration stored in a catalog. *)

  type t
  (** A validated catalog of provider declarations.

      Catalogs reject duplicate provider ids when constructed, centralizing the
      uniqueness invariant for pure provider and model lookup. *)

  (** Lookup failures for {!resolve} and {!models_for}.

      These are user-facing diagnostics. Catalog {e construction} cannot fail
      this way: its only failure is a duplicated provider, reported by
      {!of_list} as the offending provider directly. *)
  module Lookup_error : sig
    type t =
      | Invalid_selector of {
          input : string;
          message : string;
          candidates : string list;
        }
          (** [input] could not be parsed as a model selector. [candidates] are
              known selector spellings. *)
      | Unknown_provider of {
          provider : Spice_llm.Provider.t;
          known : string list;
        }
          (** [provider] is not declared. [known] contains known provider ids.
          *)
      | Unknown_model of {
          provider : Spice_llm.Provider.t;
          model : string;
          known : string list;
        }
          (** [model] is not declared by [provider]. [known] contains known
              provider-local model ids for [provider]. *)

    val message : t -> string
    (** [message e] is a human-readable diagnostic. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf e] formats [e] for diagnostics. *)
  end

  val empty : t
  (** [empty] is the empty catalog. *)

  val of_list : declaration list -> (t, Spice_llm.Provider.t) result
  (** [of_list providers] is a catalog containing [providers] in declaration
      order.

      Errors with the offending provider if [providers] contains the same
      provider id more than once. *)

  val providers : t -> declaration list
  (** [providers t] is [t]'s provider declarations in declaration order. *)

  val provider : t -> Spice_llm.Provider.t -> declaration option
  (** [provider t id] is [id]'s declaration, if declared. *)

  val models : ?include_hidden:bool -> t -> Model.t list
  (** [models t] is the model metadata declared by [t] in provider declaration
      order and model declaration order.

      If [include_hidden] is [false], the default, models for which
      {!Model.visible} is [false] are omitted. *)

  val models_for :
    ?include_hidden:bool ->
    t ->
    Spice_llm.Provider.t ->
    (Model.t list, Lookup_error.t) result
  (** [models_for t id] is the model metadata declared by provider [id].

      If [include_hidden] is [false], the default, models for which
      {!Model.visible} is [false] are omitted. Errors with
      [Lookup_error.Unknown_provider] if [id] is not declared. *)

  val resolve : t -> string -> (Model.t, Lookup_error.t) result
  (** [resolve t input] parses [input] as [provider/model] and resolves it
      against [t].

      It resolves {e declared} models only. A provider whose model set is owned
      by an external system (see {!val:dynamic_model}) declares such ids
      nowhere, so [resolve] reports [Lookup_error.Unknown_model] for them; the
      host recovers them through the provider's dynamic-model fallthrough. *)
end

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. *)
