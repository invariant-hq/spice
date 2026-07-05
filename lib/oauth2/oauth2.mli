(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure OAuth 2.0 protocol building blocks.

    This library builds authorization URLs, parses protocol responses, and
    describes form-encoded HTTP POST requests without performing I/O. Runtime
    packages execute {!Request.t} values and feed raw responses back to the
    stored decoder.

    Construct provider-independent flows with {!Client}, {!Pkce}, {!State},
    {!Authorization}, {!Device}, {!Grant}, and {!Revocation}. Providers with
    non-standard response bodies decode them with {!Json} and report failures
    through the shared {!malformed} shape. Provider policy, account storage,
    browser handling, token refresh scheduling, and HTTP execution belong above
    this layer. *)

(** {1:random Randomness} *)

type random = int -> string
(** Cryptographic random byte supplier.

    [random n] must return exactly [n] unpredictable bytes. This library does
    not read a global random source. Callers choose the source so tests and
    runtimes can provide their own entropy. *)

(** {1:encoding Form Encoding} *)

val encode_form : (string * string) list -> string
(** [encode_form params] is [params] encoded as
    [application/x-www-form-urlencoded].

    Order and duplicate names are preserved. Spaces are encoded as [+]. Other
    non-unreserved bytes are percent-encoded with uppercase hexadecimal digits.
    Empty values are encoded as [name=]. *)

(** {1:client Clients} *)

module Client : sig
  type auth = [ `Public | `Secret_post of string | `Secret_basic of string ]
  (** Token endpoint client authentication method.

      [`Public] sends [client_id] in the form body. [`Secret_post secret] sends
      [client_id] and [client_secret] in the form body. [`Secret_basic secret]
      sends an [Authorization] header built from the form-encoded client id and
      secret, and omits client credentials from the form body. Both secret
      variants contain client secret material. *)

  type t
  (** OAuth client identity and authentication method. *)

  val make : id:string -> ?auth:auth -> unit -> t
  (** [make ~id ?auth ()] is a client. The default [auth] is [`Public].

      [id] and secret material in [auth] are stored unchanged. Provider
      definitions are responsible for using registered client identifiers and
      the intended authentication method. *)

  val id : t -> string
  (** [id t] is [t]'s OAuth client identifier. *)
end

(** {1:errors Errors} *)

type malformed = {
  field : string option;
  message : string;
  raw : Jsont.json option;
}
(** Malformed OAuth response data.

    [field] names the offending response field when known. [raw] preserves the
    offending provider value when it is available. Values may contain provider
    response data, but not request bodies or client credentials. *)

val pp_malformed : Format.formatter -> malformed -> unit
(** [pp_malformed ppf e] formats [e] for diagnostics.

    The formatter prints the field and message only; [raw] is retained for
    structured handling and is not rendered. *)

module Param_error : sig
  type t = [ `Reserved of string ]
  (** Invalid extension parameters.

      [`Reserved name] means caller-supplied parameters tried to set a field
      owned by the OAuth builder. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      The wording is not stable enough for programmatic matching. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)
end

(** {1:json JSON Decoding} *)

module Json : sig
  (** Field accessors over a decoded {!Jsont.json} object, with
      duplicate-singleton detection, for provider-specific response parsing.

      Standard flows decode their responses through {!Token} and {!Device}.
      Providers that return non-standard bodies use these accessors so their
      decoders share the singleton and duplicate-field semantics of this
      library. Errors carry the shared {!malformed} shape. *)

  val parse : string -> (Jsont.json, malformed) result
  (** [parse body] decodes [body] as JSON. Invalid JSON is returned through the
      {!malformed} record shape. *)

  val field : string -> Jsont.json -> Jsont.json option
  (** [field name json] is the first value bound to [name] in the object [json],
      or [None] if [json] is not an object or has no such field. *)

  val required :
    string ->
    (string -> Jsont.json -> ('a, malformed) result) ->
    Jsont.json ->
    ('a, malformed) result
  (** [required name decode json] decodes the unique [name] field of [json] with
      [decode]. A missing or duplicate field is [malformed]. *)

  val optional :
    string ->
    (string -> Jsont.json -> ('a, malformed) result) ->
    Jsont.json ->
    ('a option, malformed) result
  (** [optional name decode json] is as {!required}, but an absent field or a
      JSON [null] value is [Ok None]. A duplicate field is [malformed]. *)

  val string : string -> Jsont.json -> (string, malformed) result
  (** [string field json] is [json] as a string. A non-string value is
      [malformed] with field name [field]. *)

  val int : string -> Jsont.json -> (int, malformed) result
  (** [int field json] is [json] as an integer.

      Fractional, out-of-range, and non-numeric values are [malformed] with
      field name [field]. *)

  val uri : string -> Jsont.json -> (Uri.t, malformed) result
  (** [uri field json] is [json] as a URI parsed with [Uri.of_string]. A
      non-string value is [malformed] with field name [field]. *)
end

module Error : sig
  (** Standard OAuth error responses. *)

  type t
  (** Standard OAuth error response.

      [code] is the protocol error code. [description] and [uri] are optional
      diagnostic fields from the provider and are not interpreted by this
      module. *)

  val make : code:string -> ?description:string -> ?uri:Uri.t -> unit -> t
  (** [make ~code ?description ?uri ()] is an OAuth error response.

      The fields are not validated; use this constructor for already-decoded
      provider data and tests. *)

  val code : t -> string
  (** [code t] is [t]'s OAuth error code. *)

  val description : t -> string option
  (** [description t] is [t]'s optional human-readable description. *)

  val uri : t -> Uri.t option
  (** [uri t] is [t]'s optional documentation URI. *)

  val parse_json : Jsont.json -> (t option, malformed) result
  (** [parse_json json] parses a strict OAuth error object.

      [Ok None] means [json] has no [error] field. [Ok (Some e)] means [json]
      contains a well-formed OAuth error. [Error malformed] reports malformed
      singleton error fields, including duplicate or non-string [error],
      [error_description], or [error_uri] values. Unknown fields and non-object
      JSON without [error] are ignored. *)

  val of_params :
    (string * string) list -> (t option, [ `Duplicate of string ]) result
  (** [of_params params] parses decoded OAuth error query or form parameters.

      [Ok None] means [params] has no [error] field. Duplicate singleton fields
      are reported instead of ignored. [error_uri] is parsed with
      [Uri.of_string]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)

  val to_string : t -> string
  (** [to_string t] is [Format.asprintf "%a" pp t]. *)
end

type response_error = [ `Oauth of Error.t | `Malformed of malformed ]
(** Shared success-or-error decode outcome for a protocol response body.

    [`Oauth e] is a well-formed OAuth error object. [`Malformed e] is invalid
    JSON, or JSON that does not match the expected OAuth payload. *)

(** {1:responses HTTP Responses} *)

module Response : sig
  (** Raw HTTP responses and pure OAuth response classification.

      Interpreters such as [oauth2_eio] construct {!t} values from bounded HTTP
      responses. Standard request decoders and provider-specific callers that
      use low-level transport functions should classify those responses with
      this module so OAuth error objects take precedence over generic HTTP
      failures. *)

  type t = { status : int; headers : (string * string) list; body : string }
  (** Raw HTTP response passed from an interpreter to a request decoder.

      Header names are stored as received and are not normalized by this type.
      Bodies may contain secret-bearing provider response data. *)

  type decode_error = [ response_error | `Http of t ]
  (** OAuth response decoder error.

      Extends {!response_error} with [`Http response], a non-success response
      without a recognizable OAuth error body. *)

  val is_success : t -> bool
  (** [is_success t] is [true] iff [t.status] is in the 2xx range. *)

  val content_type : t -> string option
  (** [content_type t] is [t]'s first [Content-Type] header, if present. Header
      names are compared case-insensitively. *)

  val json : t -> (Jsont.json, malformed) result
  (** [json t] parses [t.body] as JSON.

      Invalid JSON is returned through the {!malformed} record shape. *)

  val error_of_non_success : t -> decode_error
  (** [error_of_non_success t] classifies a non-success response.

      Well-formed OAuth errors are preferred over generic HTTP errors. Invalid
      JSON and JSON without an OAuth error become [`Http t]. Malformed OAuth
      error objects become [`Malformed _].

      Callers with provider-specific pending or retry statuses should handle
      those statuses before calling this function. *)

  val decode_json :
    (Jsont.json -> ('a, response_error) result) ->
    t ->
    ('a, decode_error) result
  (** [decode_json parse t] parses successful JSON responses with [parse] and
      classifies non-success responses with {!error_of_non_success}.

      [parse] runs only for successful responses. It may return [`Oauth _] when
      a successful response body itself contains a protocol-level OAuth error,
      or [`Malformed _] when the success payload has the wrong shape. *)
end

(** {1:pkce PKCE and State} *)

module Pkce : sig
  type t
  (** PKCE S256 verifier and challenge.

      [challenge] is always [BASE64URL-ENCODE(SHA256(verifier))] without
      padding. The [plain] challenge method is intentionally unsupported. *)

  val verifier : t -> string
  (** [verifier t] is [t]'s secret-bearing PKCE verifier. *)

  val challenge : t -> string
  (** [challenge t] is [t]'s public S256 code challenge. *)

  val generate : random:random -> t
  (** [generate ~random] is a fresh PKCE pair.

      The verifier is generated from 32 random bytes and encoded as unpadded
      base64url. Raises [Invalid_argument] if [random] does not return the
      requested number of bytes. *)

  val of_verifier : string -> (t, [ `Invalid_verifier of string ]) result
  (** [of_verifier verifier] validates [verifier] and derives its S256
      challenge.

      Errors with [`Invalid_verifier reason] if [verifier] is not 43 to 128
      characters long or contains characters outside RFC 7636 verifier syntax.
  *)
end

module State : sig
  (** CSRF state tokens for authorization flows. *)

  type t
  (** CSRF state token for an authorization flow.

      State is opaque to this module except for byte equality of its wire
      representation. *)

  val generate : random:random -> t
  (** [generate ~random] is a fresh state token.

      The token is generated from 16 random bytes and encoded as unpadded
      base64url. Raises [Invalid_argument] if [random] does not return the
      requested number of bytes. *)

  val of_string : string -> t
  (** [of_string s] is [s] as state without validation or normalization. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s wire representation. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s wire representation. *)
end

(** {1:tokens Token Responses} *)

module Token : sig
  type t
  (** Successful token endpoint response.

      Token responses are secret-bearing. Unknown fields are preserved for
      provider adapters and OIDC layers. Required fields are [access_token] and
      [token_type]. *)

  type parse_error = response_error
  (** Token response parse error; see {!response_error}. *)

  val access_token : t -> string
  (** [access_token t] is [t]'s secret-bearing access token. *)

  val token_type : t -> string
  (** [token_type t] is [t]'s token type. *)

  val expires_in : t -> int option
  (** [expires_in t] is [t]'s non-negative lifetime in seconds, if present.

      JSON [null] is treated as absent. *)

  val refresh_token : t -> string option
  (** [refresh_token t] is [t]'s secret-bearing refresh token, if present. *)

  val scope : t -> string list option
  (** [scope t] is [t]'s returned scope list, if present.

      The wire field is split on spaces and empty items are discarded. JSON
      [null] is treated as absent. *)

  val raw : t -> Jsont.json
  (** [raw t] is the raw secret-bearing token response. *)

  val field : string -> t -> Jsont.json option
  (** [field name t] is the first raw field named [name], if present.

      This is for provider extensions. It may expose secret-bearing fields. *)

  val field_string : string -> t -> string option
  (** [field_string name t] is the raw string field named [name], if present.
      Non-string fields are ignored. *)

  val field_int : string -> t -> int option
  (** [field_int name t] is the raw integer field named [name], if present.

      Exact JSON integers and decimal string integers are accepted. Fractional,
      out-of-range, and non-integer fields are ignored. *)

  val parse : Jsont.json -> (t, parse_error) result
  (** [parse json] parses a token endpoint JSON response.

      OAuth error objects are returned as [`Oauth _]. Malformed success
      responses, malformed OAuth error objects, duplicate singleton fields, and
      negative, fractional, non-numeric, or out-of-range [expires_in] values are
      returned as [`Malformed _]. Optional [refresh_token], [scope], and
      [expires_in] fields treat JSON [null] as absent. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats a redacted token response.

      [pp] may print non-secret metadata such as [token_type], [expires_in], and
      [scope]. It must not print access tokens, refresh tokens, ID tokens, or
      unknown provider fields. *)
end

(** {1:requests Pure HTTP Requests} *)

module Request : sig
  type +'a t
  (** Pure description of one form-encoded HTTP POST and its response decoder.

      A request value may contain credential, token, authorization code, device
      code, or client secret material in its parameters, headers, or rendered
      body. Interpreters are responsible for sending the body as
      [application/x-www-form-urlencoded]. *)

  val post_form :
    uri:Uri.t ->
    ?headers:(string * string) list ->
    params:(string * string) list ->
    decode:(Response.t -> ('a, Response.decode_error) result) ->
    unit ->
    'a t
  (** [post_form ~uri ?headers ~params ~decode ()] is a custom form POST
      request.

      [body] later renders [params] with {!encode_form}; [decode] is stored
      unchanged. This function does not validate OAuth-reserved parameters.

      Most callers should use {!Grant.request}, {!Device.request}, or
      {!Revocation.request}. *)

  val uri : _ t -> Uri.t
  (** [uri t] is [t]'s target URI. *)

  val headers : _ t -> (string * string) list
  (** [headers t] is [t]'s HTTP headers in insertion order.

      Standard builders include only headers required by client authentication;
      interpreters may add transport headers such as [Content-Type]. *)

  val body : _ t -> string
  (** [body t] is [t]'s form parameters encoded as a form body.

      Request bodies may contain credential, token, authorization code, device
      code, or client secret material. *)

  val decode : 'a t -> Response.t -> ('a, Response.decode_error) result
  (** [decode t response] decodes [response] according to [t].

      Calling [decode] performs no HTTP I/O; it only runs the decoder supplied
      when [t] was constructed. *)

  val with_header : string -> string -> 'a t -> 'a t
  (** [with_header name value t] appends HTTP header [name = value] to [t]. *)
end

(** {1:device Device Authorization} *)

module Device : sig
  type t
  (** Successful RFC 8628 device authorization response.

      [device_code] is secret-bearing. Required fields are [device_code],
      [user_code], [verification_uri], and [expires_in]. *)

  type parse_error = response_error
  (** Device authorization response parse error; see {!response_error}. *)

  val request :
    client:Client.t ->
    endpoint:Uri.t ->
    ?scope:string list ->
    ?extra:(string * string) list ->
    unit ->
    (t Request.t, Param_error.t) result
  (** [request ~client ~endpoint ?scope ?extra ()] is a device authorization
      endpoint request.

      [scope] is omitted when absent or empty, otherwise encoded as a single
      space-separated field. [extra] is for provider-specific parameters and
      must not contain [client_id], [client_secret], or [scope]. *)

  val parse : Jsont.json -> (t, parse_error) result
  (** [parse json] parses a device authorization response.

      OAuth error objects are returned as [`Oauth _]. Missing required fields,
      duplicate singleton fields, invalid URIs, non-integer numbers, and
      out-of-range integers are malformed. An absent or JSON [null] [interval]
      field uses the RFC default of five seconds. Negative [expires_in] and
      non-positive [interval] values are malformed. *)

  val device_code : t -> string
  (** [device_code t] is [t]'s secret-bearing device code. *)

  val user_code : t -> string
  (** [user_code t] is the code the user enters at the verification URI. *)

  val verification_uri : t -> Uri.t
  (** [verification_uri t] is the URI shown to the user. *)

  val verification_uri_complete : t -> Uri.t option
  (** [verification_uri_complete t] is the optional verification URI with
      [user_code] embedded by the provider.

      A JSON [null] field is treated as absent. *)

  val expires_in : t -> int
  (** [expires_in t] is [t]'s non-negative lifetime in seconds. *)

  val interval : t -> int
  (** [interval t] is [t]'s positive polling interval in seconds. *)

  val raw : t -> Jsont.json
  (** [raw t] is the raw secret-bearing device authorization response. *)

  type poll_error = [ `Authorization_pending | `Slow_down | `Other of Error.t ]
  (** Device-code polling error class.

      [`Authorization_pending] and [`Slow_down] are RFC 8628 polling control
      signals. [`Other e] preserves all other OAuth errors for the caller's
      retry and termination policy. *)

  val classify_poll_error : Error.t -> poll_error
  (** [classify_poll_error e] classifies [authorization_pending] and [slow_down]
      control errors. Other OAuth errors are preserved as [`Other e]. *)
end

(** {1:grants Token Grants} *)

module Grant : sig
  type t
  (** Token endpoint grant description.

      A grant owns its protocol parameters and rejects provider extras that
      would overwrite those fields or client authentication fields. Revocation
      is modeled separately by {!Revocation}; it is not a grant. *)

  val authorization_code :
    code:string -> redirect_uri:Uri.t -> ?pkce:Pkce.t -> unit -> t
  (** [authorization_code ~code ~redirect_uri ?pkce ()] is an authorization-code
      grant.

      [code] is secret-bearing. [redirect_uri] is serialized with
      [Uri.to_string]. [pkce], when present, contributes [code_verifier]. Prefer
      {!Authorization.grant} when the code came from an authorization redirect
      built by this library. *)

  val refresh_token : refresh_token:string -> ?scope:string list -> unit -> t
  (** [refresh_token ~refresh_token ?scope ()] is a refresh-token grant.

      [refresh_token] is secret-bearing. [scope] is omitted when absent or
      empty, otherwise encoded as a single space-separated field. *)

  val client_credentials : ?scope:string list -> unit -> t
  (** [client_credentials ?scope ()] is a client-credentials grant.

      [scope] is omitted when absent or empty, otherwise encoded as a single
      space-separated field. *)

  val device_code : Device.t -> t
  (** [device_code device] is a device-code grant for [device].

      The device code is secret-bearing and copied from [device]. *)

  val extension :
    grant_type:string ->
    params:(string * string) list ->
    (t, Param_error.t) result
  (** [extension ~grant_type ~params] is an extension grant.

      [params] supplies all grant-specific parameters except [grant_type]. It
      must not contain [grant_type], [client_id], or [client_secret]. Later
      {!with_extra} calls also reject names already present in [params], so
      extension parameter names are singleton-owned by the grant. *)

  val with_extra : (string * string) list -> t -> (t, Param_error.t) result
  (** [with_extra extra t] appends provider-specific [extra] parameters.

      [extra] must not contain fields already owned by [t] or client
      authentication fields. On success, extras are appended after existing
      grant parameters. *)

  val request : client:Client.t -> endpoint:Uri.t -> t -> Token.t Request.t
  (** [request ~client ~endpoint grant] compiles [grant] to a token endpoint
      request and applies standard client authentication.

      Client authentication parameters, when any, precede grant parameters in
      the request body. Client authentication headers, when any, are included in
      the request headers.

      The request decoder parses 2xx JSON with {!Token.parse}. Non-2xx responses
      with well-formed OAuth error bodies decode as [`Oauth _]; non-2xx
      responses without OAuth errors decode as [`Http _]. *)
end

(** {1:authorization Authorization Code Flow} *)

module Authorization : sig
  type t
  (** Authorization-code request plus local state needed to validate the
      callback and exchange the resulting code.

      Construct [t] with {!make}, open {!uri} in the user's browser, validate
      the redirect with {!callback}, then exchange the checked {!type:code}
      using {!grant}. *)

  type code
  (** Authorization code whose callback state has been checked against a
      {!type:t}.

      Values of this type carry the redirect URI and PKCE verifier captured by
      the authorization request. *)

  module Callback_error : sig
    type t =
      [ `Oauth of Error.t
      | `Missing of string
      | `Duplicate of string
      | `State_mismatch
      | `Redirect_uri_mismatch ]
    (** Authorization callback error.

        URI target and redirect query parameters are checked before callback
        fields. [`Oauth e] is returned only after callback state has been
        checked against the authorization request. [`Redirect_uri_mismatch]
        means the callback URI does not target [t]'s redirect URI, or omits
        query parameters that were part of that redirect URI. [`Missing field]
        and [`Duplicate field] report singleton callback fields such as [state],
        [code], [error], [error_description], and [error_uri]. *)
  end

  val make :
    client:Client.t ->
    endpoint:Uri.t ->
    redirect_uri:Uri.t ->
    state:State.t ->
    ?pkce:Pkce.t ->
    ?scope:string list ->
    ?extra:(string * string) list ->
    unit ->
    (t, Param_error.t) result
  (** [make ~client ~endpoint ~redirect_uri ~state ?pkce ?scope ?extra ()] is an
      authorization request.

      [state] and [pkce] are generated by the caller. [extra] is for
      provider-specific authorization parameters and must not contain
      [response_type], [client_id], [redirect_uri], [state], [scope],
      [code_challenge], or [code_challenge_method]. [endpoint] itself must not
      already contain those reserved query parameters. [redirect_uri] may
      contain provider-routing query parameters, but must not contain callback
      response fields [code], [state], [error], [error_description], or
      [error_uri].

      Non-reserved query parameters already present on [endpoint] are preserved.
      [scope] is omitted when absent or empty, otherwise encoded as a single
      space-separated field. *)

  val uri : t -> Uri.t
  (** [uri t] is the authorization URI to open in the user's browser.

      It contains the client identifier, redirect URI, state, optional scope,
      optional PKCE challenge, and provider extras. *)

  val state : t -> State.t
  (** [state t] is [t]'s expected callback state. *)

  val pkce : t -> Pkce.t option
  (** [pkce t] is [t]'s PKCE pair, if present. *)

  val redirect_uri : t -> Uri.t
  (** [redirect_uri t] is [t]'s redirect URI. *)

  val callback : t -> Uri.t -> (code, Callback_error.t) result
  (** [callback t uri] validates [uri] as the redirect callback for [t].

      [uri] must target [redirect_uri t]. If [redirect_uri t] contains query
      parameters, the callback URI must contain those exact decoded bindings;
      duplicates included. Additional callback query parameters are allowed. URI
      fragments are ignored for target comparison. The [state] parameter is
      required, must be unique, and must match [t]. OAuth callback errors are
      surfaced only after state validation succeeds. Successful callbacks
      require a unique [code] parameter and return a checked authorization code.
  *)

  val code : code -> string
  (** [code c] is the secret-bearing authorization code. *)

  val grant : code -> Grant.t
  (** [grant c] is the authorization-code grant for [c].

      The redirect URI and PKCE verifier captured by {!callback} are carried
      into the grant by construction. *)
end

(** {1:revocation Token Revocation} *)

module Revocation : sig
  type token_hint = [ `Access_token | `Refresh_token | `Other of string ]
  (** Optional RFC 7009 token type hint.

      [`Other hint] is serialized as [hint] without validation. *)

  type t
  (** Token revocation request.

      Successful revocation has status-only semantics and no token response
      body. The request owns [token] and optional [token_type_hint] parameters
      and rejects provider extras that would overwrite them or client
      authentication fields. *)

  val make : token:string -> ?hint:token_hint -> unit -> t
  (** [make ~token ?hint ()] is a revocation request.

      [token] is secret-bearing. *)

  val with_extra : (string * string) list -> t -> (t, Param_error.t) result
  (** [with_extra extra t] appends provider-specific [extra] parameters.

      [extra] must not contain [token], [token_type_hint], [client_id], or
      [client_secret]. On success, extras are appended after existing revocation
      parameters. *)

  val request : client:Client.t -> endpoint:Uri.t -> t -> unit Request.t
  (** [request ~client ~endpoint t] compiles [t] to a revocation endpoint
      request.

      The request decoder returns [Ok ()] for any 2xx response and ignores the
      response body. Non-2xx responses with well-formed OAuth error bodies
      decode as [`Oauth _]; non-2xx responses without OAuth errors decode as
      [`Http _]. *)
end
