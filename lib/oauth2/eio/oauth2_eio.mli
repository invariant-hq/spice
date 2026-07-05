(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Eio transport for pure OAuth 2.0 requests.

    The {!Oauth2} library constructs protocol values and form-encoded
    {!Oauth2.Request.t} descriptions without performing I/O. This module is the
    Eio boundary: it sends those descriptions with Cohttp, bounds response
    bodies, maps transport failures into structured errors, and provides HTTPS
    client construction.

    The usual path is to build a {!Oauth2.Client.t} and a protocol value with
    {!Oauth2.Grant}, {!Oauth2.Device}, or {!Oauth2.Revocation}, create a client
    with {!make_tls_client} or {!make_client}, then call {!send}. Use {!post}
    for provider-specific endpoints that are not represented by
    {!Oauth2.Request.t}. *)

(** {1:errors Responses and Errors} *)

type response = Oauth2.Response.t
(** Raw HTTP response metadata and bounded body.

    Values may contain provider diagnostics. They may also contain
    secret-bearing OAuth response data when returned from low-level functions.
*)

module Error : sig
  type transport = [ `Network of string ]
  (** Transport failure before OAuth decoding.

      [`Network message] covers connection failures, Cohttp/Eio exceptions other
      than cancellation, response-body read failures, and invalid response body
      limits. It does not cover pure OAuth request construction errors. Eio
      cancellation is re-raised by request functions instead of being converted
      to this type. *)

  type t = [ Oauth2.Response.decode_error | `Transport of transport ]
  (** OAuth request execution error.

      Extends {!Oauth2.Response.decode_error} with [`Transport _], introduced by
      this module when HTTP execution fails before any OAuth response is
      decoded. The [`Oauth _], [`Malformed _], and [`Http _] cases are pure
      response-decoder errors from {!Oauth2.Response}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics.

      The formatter does not print HTTP response bodies, tokens, or request
      bodies. *)

  val pp_transport : Format.formatter -> transport -> unit
  (** [pp_transport ppf e] formats a raw transport error. *)
end

(** {1:execution Request Execution} *)

val post :
  Cohttp_eio.Client.t ->
  sw:Eio.Switch.t ->
  ?max_response_body_size:int ->
  uri:Uri.t ->
  ?headers:(string * string) list ->
  body:string ->
  unit ->
  (response, Error.transport) result
(** [post http ~sw ?max_response_body_size ~uri ?headers ~body ()] sends one raw
    HTTP POST and returns the raw response.

    [body] is sent unchanged. The [Content-Type] header is set to
    [application/x-www-form-urlencoded] unless [headers] already contains a
    [content-type] header, compared case-insensitively.

    [max_response_body_size] is an inclusive byte limit applied while reading
    the response body; the default is 1 MiB. A negative limit returns
    [Error (`Network _)] before sending a request. A response larger than the
    limit returns [Error (`Network _)] after the response body read fails.

    [sw] must be live when the request starts. Eio cancellation is re-raised.
    Other exceptions from the client or network are returned as
    [Error (`Network _)]. Per-request resources are released before [post]
    returns. *)

val send :
  Cohttp_eio.Client.t ->
  sw:Eio.Switch.t ->
  ?max_response_body_size:int ->
  'a Oauth2.Request.t ->
  ('a, Error.t) result
(** [send http ~sw ?max_response_body_size request] sends [request] and decodes
    its response.

    The URI, headers, and body come from {!Oauth2.Request.uri},
    {!Oauth2.Request.headers}, and {!Oauth2.Request.body}. Transport failures
    from {!post} become [`Transport _]. Decoder failures from
    {!Oauth2.Request.decode} are preserved as [`Oauth _], [`Malformed _], or
    [`Http _]. Eio cancellation is re-raised as in {!post}.

    This function does not validate or rewrite request parameters. Build
    requests with {!Oauth2.Grant.request}, {!Oauth2.Device.request}, or
    {!Oauth2.Revocation.request} when the standard reserved-parameter checks are
    required. *)

(** {1:https HTTPS Clients} *)

type https
(** HTTPS connector for {!make_client}.

    A value wraps the TLS configuration used when Cohttp opens [https://] URIs.
    It does not own the Eio network environment or request switches. *)

val make_https : unit -> (https, [ `Tls_error of string ]) result
(** [make_https ()] builds an HTTPS connector using the system CA bundle.

    The connector initializes the default Mirage crypto RNG before TLS use and
    constructs a client TLS configuration with CA authentication. Each HTTPS
    request validates the endpoint against the URI host, using DNS-name
    verification for host names and IP verification for IP literals.

    Errors with [`Tls_error message] if the CA authenticator or default TLS
    configuration cannot be constructed. The connector rejects an [https://] URI
    with no host, or with a host that cannot be interpreted as a DNS name or IP
    literal; when used through {!post} or {!send}, that rejection is reported as
    a transport error. Endpoint identity verification is not silently disabled.
*)

val make_client : ?https:https -> _ Eio.Net.t -> Cohttp_eio.Client.t
(** [make_client ?https net] builds a Cohttp Eio client.

    [net] is used for connections made by later requests and is not owned by the
    returned value. Without [https], [https://] URIs are unsupported by the
    client. *)

val make_tls_client :
  _ Eio.Net.t -> (Cohttp_eio.Client.t, [ `Tls_error of string ]) result
(** [make_tls_client net] is [make_client ~https net] with [https] from
    {!make_https}.

    Errors are the TLS setup errors from {!make_https}. The returned client has
    the same network ownership and request-time URI validation behavior as
    {!make_client} and {!make_https}. *)
