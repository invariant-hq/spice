(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Authentication protocol interpreters for provider-declared login methods.

    [spice.auth] interprets pure authentication declarations from
    {!Spice_provider.Auth}. It constructs provider/source-free
    {!Spice_account.Secret.t} values from API keys, OAuth 2.0 browser login,
    OAuth 2.0 device login, local browser callbacks, and OpenAI ChatGPT's
    non-standard device authorization.

    The library is not a login workflow runner. It does not prompt users, open
    browsers, sleep between polls, choose UI surfaces, attach provider ids,
    mutate credential stores, or maintain pending login sessions. CLI and TUI
    callers own those workflows by composing these primitives with host account
    persistence.

    In-progress OAuth values are secret-bearing: they may contain state, PKCE
    verifiers, authorization codes, device identifiers, refresh tokens, access
    tokens, or user codes. Expose only the challenge and display fields
    documented below. *)

(** {1:errors Runtime Errors} *)

module Error : sig
  (** Structured auth runtime errors.

      Error formatters must not include credential material, request bodies,
      response bodies, authorization codes, PKCE verifiers, or device
      authorization identifiers. Variants identify recovery classes; string
      payloads are diagnostics and are not stable program inputs. *)

  type t =
    | Invalid_secret of string
        (** Invalid local credential material, such as an empty API key. *)
    | Invalid_request of string
        (** Invalid local configuration, provider declaration, callback shape,
            or request construction. *)
    | Network of string
        (** TLS or transport failure before a protocol response is available. *)
    | Protocol of string
        (** Malformed, unsupported, or otherwise unexpected provider response.
        *)
    | Rejected of string
        (** OAuth or provider rejection, including denied authorization and
            non-pending OAuth error responses. *)
    | Timeout of string
        (** A local wait or provider HTTP request exceeded its deadline. *)
    | Not_refreshable
        (** Refresh requested for non-OAuth material or OAuth material without a
            refresh token. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      The result contains no credential material, authorization codes, token
      bodies, callback URLs, PKCE verifiers, or device authorization
      identifiers. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [message e]. *)
end

(** {1:secrets Secret Constructors} *)

module Secret : sig
  (** Provider/source-free secret construction.

      The returned secrets carry no provider id or credential source. Hosts add
      those facts when they create {!Spice_account.Credential.t} values or save
      credentials. *)

  val api_key : string -> (Spice_account.Secret.t, Error.t) result
  (** [api_key key] is a provider/source-free API-key secret.

      Errors with [Invalid_secret] if [key] is empty. *)
end

(** {1:http HTTP} *)

module Http : sig
  (** Deadline-bound HTTP for authentication runtimes. *)

  type t
  (** An HTTP client whose requests share one timeout policy.

      Every request is cancelled if its complete lifecycle — connection,
      response headers, and response body — exceeds the configured timeout. *)

  val make :
    clock:_ Eio.Time.clock -> timeout_s:float -> Cohttp_eio.Client.t -> t
  (** [make ~clock ~timeout_s client] binds [client] to [clock] and a
      per-request [timeout_s].

      Raises [Invalid_argument] if [timeout_s] is not positive. *)

  val tls_client : stdenv:Eio_unix.Stdenv.base -> (t, Error.t) result
  (** [tls_client ~stdenv] is a deadline-bound TLS HTTP client using [stdenv]'s
      network capability and clock. Each complete request has a 30-second
      timeout.

      Errors with [Network] if TLS client construction fails. *)
end

(** {1:local-callback Local Callback Listener} *)

module Local_callback : sig
  (** One-shot local HTTP callback listener.

      The listener is a low-level utility for browser-based flows. It does not
      construct authorization URLs, validate OAuth state, or exchange codes. *)

  val await_once :
    stdenv:Eio_unix.Stdenv.base ->
    ?on_ready:(unit -> unit) ->
    ?accept:(Uri.t -> bool) ->
    redirect_uri:Uri.t ->
    timeout_s:float ->
    unit ->
    (Uri.t, Error.t) result
  (** [await_once ~stdenv ~redirect_uri ~timeout_s ()] binds the loopback
      address or addresses and port described by [redirect_uri], waits for the
      first accepted request whose path equals [Uri.path redirect_uri], responds
      with fixed HTML, and returns the absolute callback URI.

      [redirect_uri] must have an explicit host and port. Supported hosts are
      [localhost], [127.0.0.1], and [::1]. The optional [on_ready] callback runs
      after at least one socket is listening. Requests with other paths receive
      [404] and do not complete the wait. [accept], defaulting to accepting
      every matching request, filters path-matching callbacks: a request for
      which [accept] returns [false] receives [400] and does not complete the
      wait, so a stray or forged callback cannot consume the one-shot listener
      (see {!OAuth2_authorization_code.accepts_callback}). A second accepted
      request before the listener stops receives [400].

      Errors with [Invalid_request] for unsupported redirect URIs, [Timeout] if
      no accepted request arrives before [timeout_s], and [Network] for socket
      or server failures. Fiber cancellation is re-raised, never converted to an
      error, so callers racing the wait against a cancel signal observe the
      cancellation. *)
end

(** {1:oauth2 OAuth 2.0 Authorization Code} *)

module OAuth2_authorization_code : sig
  (** OAuth 2.0 authorization-code protocol primitives.

      Compose a browser login by calling {!start}, opening or displaying
      {!authorization_uri}, collecting a local browser callback with
      {!Local_callback.await_once} or another listener bound to {!redirect_uri},
      and passing that callback URI to {!complete_secret}. *)

  type t
  (** Started authorization-code state.

      Values contain the provider declaration, state, and optional PKCE
      material. Treat the whole value as secret until completed or discarded.
      Callers may display {!authorization_uri} and must pass {!redirect_uri} to
      the callback listener. *)

  (** Post-exchange token interpretation selected by {!complete_secret}.

      The provider-to-profile mapping lives in the caller, not in the OAuth
      declaration; browser callers select [Openai_chatgpt] for OpenAI and
      [Generic] otherwise. *)
  type token_profile =
    | Generic  (** Interpret the token response as a generic OAuth secret. *)
    | Openai_chatgpt
        (** Interpret the token response as an OpenAI ChatGPT secret, extracting
            account ids from ID-token or access-token claims. *)

  val start :
    random:Oauth2.random ->
    Spice_provider.Auth.Login.Protocol.oauth2_authorization_code ->
    (t, Error.t) result
  (** [start ~random spec] is a browser authorization request for [spec].

      The function performs no I/O. [spec.redirect_uri] must be present because
      this library does not choose callback addresses.

      Errors with [Invalid_request] if [spec.redirect_uri] is absent, [random]
      cannot produce valid state or PKCE material, or [spec.extra] contains a
      reserved OAuth authorization parameter. *)

  val authorization_uri : t -> Uri.t
  (** [authorization_uri t] is the provider authorization URI to display or open
      for the user. *)

  val redirect_uri : t -> Uri.t
  (** [redirect_uri t] is the local redirect URI that the callback listener must
      bind. *)

  val accepts_callback : t -> Uri.t -> bool
  (** [accepts_callback t callback] is [true] iff [callback] belongs to [t]'s
      authorization request: its state and shape validate, or it is a
      state-matched provider denial. Callback listeners use it — typically as
      {!Local_callback.await_once}'s [accept] — to ignore stray or forged
      callbacks without completing the wait.

      The function is pure and validates only; an accepted callback must still
      be passed to {!complete} or {!complete_secret}, which repeats the
      validation before the token exchange. *)

  val complete :
    http:Http.t ->
    sw:Eio.Switch.t ->
    t ->
    callback:Uri.t ->
    (Oauth2.Token.t, Error.t) result
  (** [complete ~http ~sw t ~callback] verifies [callback] against [t] and
      exchanges the authorization code at [t]'s token endpoint.

      The function performs the token exchange HTTP request. It does not stop
      callback listeners, open browsers, sleep, or store credentials. OAuth
      denial in the checked callback errors with [Rejected]. Missing,
      duplicated, state-mismatched, or redirect-mismatched callback fields error
      with [Invalid_request]. Token exchange failures use [Network], [Protocol],
      [Rejected], [Timeout], or [Invalid_request].

      Prefer {!complete_secret}, which folds in token normalization and returns
      a {!Spice_account.Secret.t} directly. *)

  val complete_secret :
    http:Http.t ->
    sw:Eio.Switch.t ->
    t ->
    callback:Uri.t ->
    now:Spice_account.timestamp ->
    profile:token_profile ->
    (Spice_account.Secret.t, Error.t) result
  (** [complete_secret ~http ~sw t ~callback ~now ~profile] runs {!complete} and
      normalizes the token response into a secret according to [profile]:
      [Generic] copies the access and refresh tokens with a computed expiry;
      [Openai_chatgpt] additionally extracts an account id from ID-token or
      access-token JWT claims. Both profiles require a Bearer token response.

      The function performs the token exchange HTTP request and does not listen
      for callbacks, open browsers, sleep, or store credentials. Error behavior
      is that of {!complete}, plus [Protocol] for invalid token material. *)
end

(** {1:openai OpenAI} *)

module Openai_chatgpt : sig
  (** OpenAI ChatGPT-specific auth primitives.

      OpenAI browser login composes the generic OAuth 2.0 authorization-code
      protocol with OpenAI token normalization through
      {!OAuth2_authorization_code.complete_secret}. OpenAI tokens may carry
      account ids in ID-token or access-token claims and refresh with OpenAI's
      token endpoint.

      OpenAI device login uses {!Device_code.start_openai_chatgpt}: it is not
      RFC 8628 OAuth device-code, but a provider-specific flow against
      [/api/accounts/deviceauth/*] and [/oauth/token]. *)

  module Config : sig
    type t
    (** OpenAI ChatGPT auth configuration.

        Values are inert endpoint configuration. They contain no credentials or
        pending authorization state. *)

    val default : t
    (** [default] is the standard OpenAI ChatGPT auth configuration. *)

    val make :
      ?issuer:Uri.t ->
      ?client_id:string ->
      ?expires_in:int ->
      ?poll_interval:int ->
      unit ->
      (t, Error.t) result
    (** [make ?issuer ?client_id ?expires_in ?poll_interval ()] is OpenAI
        ChatGPT auth configuration.

        [issuer] is the OpenAI Auth issuer root. It must be an absolute [http]
        or [https] URI with a host and without query or fragment. If [issuer]
        has a path, derived endpoints append their suffixes under that path.
        [client_id] must be non-empty. [expires_in] and [poll_interval] are the
        device-code fallbacks used when the user-code response omits them; they
        must be non-negative, and zero makes the corresponding deadline or delay
        immediate.

        Defaults:
        - [issuer] defaults to [https://auth.openai.com].
        - [client_id] defaults to [app_EMoamEEZ73f0CkXaXp7hrann].
        - [expires_in] defaults to [900].
        - [poll_interval] defaults to [5].

        Errors with [Invalid_request] if any supplied value is invalid. *)
  end

  val refresh :
    http:Http.t ->
    sw:Eio.Switch.t ->
    now:Spice_account.timestamp ->
    Config.t ->
    Spice_account.Secret.t ->
    (Spice_account.Secret.t, Error.t) result
  (** [refresh ~http ~sw ~now config secret] refreshes [secret] with OpenAI's
      OAuth token endpoint.

      [secret] must be an OAuth secret with a refresh token. Successful refresh
      returns a provider/source-free replacement secret. If the response omits a
      refresh token, the current refresh token is preserved. If the response
      omits an access token, the current access token is preserved. If a new
      access token is returned without [expires_in], the replacement has no
      expiry; otherwise the previous expiry is preserved when no new access
      token is returned. Account id is updated only when a returned ID token
      contains a supported account claim.

      The function performs one JSON POST and does not persist the returned
      secret. Errors with [Not_refreshable] if [secret] has no refresh token or
      is not an OAuth secret. Provider and transport failures use [Network],
      [Protocol], [Rejected], or [Timeout]. *)

  val revoke :
    http:Http.t ->
    sw:Eio.Switch.t ->
    Config.t ->
    Spice_account.Secret.t ->
    (unit, Error.t) result
  (** [revoke ~http ~sw config secret] revokes [secret] at OpenAI's OAuth
      revocation endpoint.

      The refresh token is revoked when present, otherwise the access token,
      with the matching [token_type_hint]. The function performs one JSON POST
      and does not remove stored credentials; callers own local removal.

      Errors with [Not_refreshable] if [secret] is not an OAuth secret. Provider
      and transport failures use [Network], [Protocol], [Rejected], or
      [Timeout]. *)
end

(** {1:device-code Device Code} *)

module Device_code : sig
  (** Device-authorization state for standard OAuth 2.0 device-code and
      provider-specific device flows alike.

      Compose a device-code login by calling {!start_oauth2} or
      {!start_openai_chatgpt}, displaying {!challenge}, sleeping for
      {!next_poll_delay_s}, and repeatedly calling {!poll} until it returns
      [Authorized], [Expired], [Rejected], or an error. *)

  type t
  (** Device-authorization state.

      Values contain secret-bearing device authorization material. They are
      abstract so callers can display only the challenge fields and pass the
      value back to {!poll}. The value closes over its transport, so {!poll}
      needs no protocol declaration or configuration. *)

  type challenge = {
    verification_uri : Uri.t;
    verification_uri_complete : Uri.t option;
        (** [None] for flows without a pre-filled verification URI, such as
            OpenAI ChatGPT. *)
    user_code : string;
  }
  (** User-facing device-code challenge.

      [verification_uri] and [verification_uri_complete] are display URIs.
      [user_code] is short-lived authorization material intended to be shown to
      the user and not logged. *)

  type poll =
    | Authorized of Spice_account.Secret.t
        (** Authorization completed and produced an OAuth secret. *)
    | Pending of t
        (** Authorization is still pending. The returned state has an updated
            polling schedule. *)
    | Expired of t
        (** Authorization is expired locally or the provider reported an expired
            device code. *)
    | Rejected of Error.t
        (** Authorization was denied or failed with a non-pending OAuth error.
        *)

  val start_oauth2 :
    http:Http.t ->
    sw:Eio.Switch.t ->
    now:Spice_account.timestamp ->
    Spice_provider.Auth.Login.Protocol.oauth2_device_code ->
    (t, Error.t) result
  (** [start_oauth2 ~http ~sw ~now spec] requests a standard OAuth 2.0 device
      code.

      The returned value contains the challenge, expiry, and first polling time.
      The function performs one HTTP request and does not display UI, open a
      browser, sleep, or store credentials. Errors use [Network], [Protocol],
      [Rejected], [Timeout], or [Invalid_request] according to the OAuth
      transport result. *)

  val start_openai_chatgpt :
    http:Http.t ->
    sw:Eio.Switch.t ->
    now:Spice_account.timestamp ->
    Openai_chatgpt.Config.t ->
    (t, Error.t) result
  (** [start_openai_chatgpt ~http ~sw ~now config] requests an OpenAI device
      user code.

      The returned value contains the verification URI, user code, expiry, and
      first polling time; [challenge.verification_uri_complete] is [None]. The
      function performs one HTTP request and does not display UI, open a
      browser, sleep, or store credentials. The response may spell the user code
      as either [user_code] or [usercode]. Missing [expires_in] and [interval]
      fields fall back to [config]. Request deadlines error with [Timeout]. *)

  val poll :
    http:Http.t ->
    sw:Eio.Switch.t ->
    now:Spice_account.timestamp ->
    t ->
    (poll, Error.t) result
  (** [poll ~http ~sw ~now t] performs one device-authorization poll for [t].

      The function performs no sleeping and does not mutate [t]. If [now] is at
      or after {!expires_at}[ t], the result is [Ok (Expired t)] and no HTTP
      request is made. Provider-reported expiry returns [Expired]. Pending
      authorization returns [Pending] with an advanced polling schedule; the
      standard OAuth [slow_down] response also increases the interval. Other
      non-pending rejections return [Ok (Rejected _)]. Transport and malformed
      responses return [Error _], as does [Timeout] when a complete request
      exceeds [http]'s deadline. Successful authorization returns [Authorized].

      For the OpenAI transport, [poll] may perform a second HTTP request to
      exchange the returned authorization code at the OAuth token endpoint. *)

  val challenge : t -> challenge
  (** [challenge t] is the user-facing device-code challenge. *)

  val expires_at : t -> Spice_account.timestamp
  (** [expires_at t] is the Unix timestamp in seconds at which [t] expires. *)

  val expires_in : t -> int
  (** [expires_in t] is [t]'s lifetime in seconds from the original
      authorization response. It seeds the surface's challenge countdown. *)

  val next_poll_delay_s : now:Spice_account.timestamp -> t -> int
  (** [next_poll_delay_s ~now t] is the non-negative delay in seconds until [t]
      may be polled again.

      The result is [0] when [now] is at or after the next poll time, and is
      capped at [max_int]. *)
end
