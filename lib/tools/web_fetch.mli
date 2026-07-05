(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Read-only public web page fetch tool.

    [web_fetch] retrieves one public HTTP(S) URL, returns bounded textual page
    content, and records typed metadata about the request, redirects, status,
    content type, size, duration, and truncation. It is for unauthenticated
    public pages; authenticated services such as Google Docs, Jira, Confluence,
    private GitHub resources, and cloud consoles should use dedicated tools or
    plugin integrations instead.

    HTML is converted to Markdown by default. Cross-authority redirects are
    reported as observations rather than followed automatically. *)

val name : string
(** [name] is ["web_fetch"]. *)

val description : string
(** [description] is the model-facing tool description. *)

module Input : sig
  (** Tool input. *)

  (** {1:types Types} *)

  (** The type for requested output format. *)
  type format =
    | Markdown  (** Return Markdown; HTML responses are converted. *)
    | Text  (** Return visible text; HTML markup is stripped. *)
    | Html  (** Return sanitized HTML for HTML responses. *)

  type t
  (** The type for decoded fetch input. *)

  (** {1:constructors Constructors} *)

  val make : ?format:format -> ?timeout_ms:int -> string -> t
  (** [make ?format ?timeout_ms url] is fetch input for [url].

      [format] defaults to [Markdown]. [timeout_ms] is an optional request
      timeout in milliseconds; it is validated against
      {!Web.Policy.resolve_timeout_ms} when the tool runs.

      Raises [Invalid_argument] if [url] is empty, if [url] contains NUL, or if
      [timeout_ms] is non-positive. URL syntax and network policy are validated
      by {!run}, not by [make]. *)

  (** {1:queries Queries} *)

  val url : t -> string
  (** [url t] is the input URL string before web-tool normalization. *)

  val format : t -> format
  (** [format t] is the requested output format. *)

  val timeout_ms : t -> int option
  (** [timeout_ms t] is the explicit timeout, if any. *)

  (** {1:tool_contract Tool contract} *)

  val contract : t Spice_tool.Input.t
  (** [contract] decodes the JSON object accepted by the model-facing tool.

      Required field:
      - ["url"], a string.

      Optional fields:
      - ["format"], one of ["markdown"], ["text"], or ["html"], defaulting to
        ["markdown"];
      - ["timeout_ms"], a positive integer. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] is [Ok input] if [json] satisfies {!contract}, and
      [Error message] otherwise. Constructor exceptions are reported as decode
      errors. *)
end

val permissions :
  policy:Web.Policy.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~policy input] is the network permission request needed before
    running [input].

    If [policy] is disabled, or if [Input.url input] is not a valid URL under
    [policy], the list is empty. Otherwise the list contains one request from
    source {!name} with a network access for the normalized fetch URL's
    protocol, host, and effective port. When {!Web.Policy.upgrade_http_to_https}
    is [true], this is the upgraded HTTPS authority. Redirect targets are not
    pre-declared; cross-authority redirects complete with {!Output.Redirected}
    rather than causing another network access in the same call. *)

module Output : sig
  (** Typed fetch output retained in {!Spice_tool.Output}. *)

  (** {1:types Types} *)

  type format = Input.format
  (** The type for the format used to project the response body. *)

  type body = {
    content : string;
        (** The returned body or preview after conversion and output limiting.
        *)
    truncated : bool;
        (** [true] iff [content] is a bounded prefix/suffix projection. *)
    omitted_chars : int;  (** The number of characters omitted from [content]. *)
  }
  (** The type for fetched textual content. *)

  (** The type for observed fetch status. *)
  type status =
    | Fetched of { code : int; code_text : string; body : body }
        (** A successful 2xx response with returned body. *)
    | Redirected of { code : int; from_url : Web.Url.t; to_url : Web.Url.t }
        (** A redirect to another fetch authority. The target was not fetched.
        *)
    | Http_error of { code : int; code_text : string; preview : body option }
        (** A non-2xx HTTP response, or a fetch failure represented as status
            metadata. [preview] is present only when a bounded textual response
            body was available. *)

  type t
  (** The type for complete typed fetch evidence. *)

  (** {1:queries Queries} *)

  val requested_url : t -> Web.Url.t
  (** [requested_url t] is the normalized URL provided by the model. *)

  val effective_url : t -> Web.Url.t
  (** [effective_url t] is the URL actually requested after HTTP-to-HTTPS
      upgrade and same-authority redirects. *)

  val content_type : t -> string option
  (** [content_type t] is the response [Content-Type] header, if any. *)

  val format : t -> format
  (** [format t] is the output format used for body conversion. *)

  val bytes_read : t -> int
  (** [bytes_read t] is the number of response bytes read for the final response
      body. It is [0] when no body was returned. *)

  val duration_ms : t -> int
  (** [duration_ms t] is the elapsed tool-run duration in milliseconds. *)

  val status : t -> status
  (** [status t] is the observed fetch status. *)

  (** {1:encoding Encoding} *)

  val encode : t Spice_tool.Output.encoder
  (** [encode t] is the erased tool output for [t].

      The text projection contains the fetched body, redirect instruction, or
      HTTP-error preview. The JSON projection contains request URLs, content
      type, format, byte count, duration, status, and truncation facts. Request
      headers, credentials, and backend secrets are never included. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is [Some t] if [output] was produced by {!encode},
      and [None] otherwise. *)
end

type https =
  Uri.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r
(** The type for host-supplied HTTPS wrappers.

    [https uri raw] wraps [raw] with TLS for [uri]'s original host and exposes
    the common two-way/close Eio flow capabilities used by Cohttp. The host owns
    certificate roots and TLS configuration; {!run} owns URL validation, DNS
    resolution, address policy, and TCP connection. *)

val run :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  net:_ Eio.Net.t ->
  https:https ->
  policy:Web.Policy.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sw ~mono_clock ~net ~https ~policy input] executes [input].

    If [cancelled ()] is [true] before work starts, the result is interrupted.
    If [policy] is disabled, the result fails with [`Permission_denied]. Invalid
    URLs and invalid timeouts fail with [`Invalid_input].

    The fetch performs a credential-free [GET] with the policy user agent,
    format-specific [Accept], and [Accept-Language: en-US,en;q=0.9]. HTTP URLs
    are upgraded to HTTPS when {!Web.Policy.upgrade_http_to_https} is [true].
    When private-network access is disabled, [net] is used to resolve each URL
    immediately before request I/O. Any private, loopback, link-local,
    multicast, or otherwise non-public resolved address fails with
    [`Permission_denied], and the request connects to the same vetted socket
    address. HTTPS connections are wrapped with [https] after the TCP connect.
    Same-authority redirects are followed up to {!Web.Policy.max_redirects};
    cross-authority redirects complete with {!Output.Redirected}. Responses
    exceeding {!Web.Policy.max_fetch_bytes}, non-textual MIME types, invalid
    UTF-8, transport errors, and timeouts fail. Non-2xx HTTP responses fail with
    typed output when a response was observed.

    Successful 2xx fetches and cross-authority redirect observations complete
    with typed output. *)

val tool :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  net:_ Eio.Net.t ->
  https:https ->
  policy:Web.Policy.t ->
  unit ->
  Spice_tool.t
(** [tool ~sw ~mono_clock ~net ~https ~policy ()] is the erased model-facing
    {!Spice_tool.t} backed by {!run}, {!Input.contract}, {!permissions}, and
    {!Output.encode}. *)
