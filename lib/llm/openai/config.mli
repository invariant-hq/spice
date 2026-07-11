(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OpenAI client configuration.

    Configuration values are inert. They do not read process environment
    variables, open network resources, or validate credentials. The provider
    adapter consumes them when {!Spice_llm_openai.client} starts requests.

    Construct values with {!make}; pass them to {!Spice_llm_openai.client}.
    Omitted fields use the adapter defaults at request time. *)

(** {1:types Types} *)

type t
(** The type for OpenAI HTTP configuration. *)

(** {1:constructors Constructors} *)

val default : t
(** [default] is [make ()]. *)

val make :
  ?base_url:string ->
  ?organization:string ->
  ?project:string ->
  ?headers:(string * string) list ->
  ?timeout_s:float ->
  ?max_retries:int ->
  unit ->
  t
(** [make ()] is checked OpenAI HTTP configuration.

    - [base_url] is the API root, without the endpoint path. Trailing slashes
      are ignored.
    - [organization] is sent as the [OpenAI-Organization] account-scoping header
      when present.
    - [project] is sent as the [OpenAI-Project] account-scoping header when
      present.
    - [headers] are extra request headers, sent as supplied on every request.
      They let one adapter serve OpenAI-compatible routes that need
      route-specific headers, such as the ChatGPT backend's account-scoping
      header. Defaults to [[]].
    - [timeout_s] is the whole logical-request deadline, covering retries,
      backoff, and streamed response consumption. It defaults to 600 seconds.
    - [max_retries] is the number of retry attempts after the initial request
      when present.

    Raises [Invalid_argument] if an optional string is empty, an optional string
    contains a newline, a header name is empty, a header name or value contains
    a newline, [base_url] contains only slashes, [timeout_s] is not positive and
    finite, or [max_retries] is negative. The constructor does not validate that
    [base_url] is an absolute URI or that the account-scoping headers identify
    existing OpenAI resources. *)

(** {1:queries Queries} *)

val base_url : t -> string option
(** [base_url t] is the normalized configured API root, if any. *)

val organization : t -> string option
(** [organization t] is the OpenAI organization header value, if any. *)

val project : t -> string option
(** [project t] is the OpenAI project header value, if any. *)

val headers : t -> (string * string) list
(** [headers t] are the extra request headers, in supplied order. *)

val timeout_s : t -> float
(** [timeout_s t] is the whole logical-request deadline in seconds. *)

val max_retries : t -> int option
(** [max_retries t] is the retry count after the initial attempt, if any. *)
