(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared concepts for the web tools.

    {!Url} validates and normalizes public HTTP(S) URLs, {!Domain} validates
    search domain filters, and {!Policy} is the host-selected boundary for
    enabling web access, limiting network work, and choosing a search backend.
    The conversion helpers are intentionally small text projections for
    {!Web_fetch}; they do not execute JavaScript or preserve browser state. *)

module Url : sig
  (** Normalized HTTP(S) URLs accepted by web tools. *)

  (** {1:errors Errors} *)

  (** The type for URL validation errors. *)
  type error =
    | Invalid_uri of string  (** The input could not be parsed as a URI. *)
    | Unsupported_scheme of string
        (** The scheme was not [http] or [https]. The empty string denotes a
            missing scheme. *)
    | Missing_host  (** The URI had no host component. *)
    | Userinfo_not_allowed
        (** The URI authority contained a username or password. *)
    | Fragment_not_allowed  (** The URI contained a fragment component. *)
    | Too_long of { max_length : int; actual_length : int }
        (** The trimmed input exceeded [max_length] bytes. *)
    | Private_host_not_allowed of string
        (** The host was local, private, link-local, loopback, or otherwise not
            public under the selected policy. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error ppf e] formats [e] for users. *)

  val error_message : error -> string
  (** [error_message e] is a human-readable diagnostic for [e]. The text is not
      a stable programmatic interface. *)

  (** {1:types Types} *)

  type t
  (** The type for normalized HTTP(S) URLs.

      Values have:
      - scheme [http] or [https];
      - a present lower-case host;
      - no userinfo;
      - no fragment;
      - textual form of at most {!max_length} bytes;
      - no private/local host unless constructed with
        [allow_private_network:true].

      URL validation blocks obvious private host literals and bare local names.
      {!Web_fetch.run} also rejects private resolved addresses before issuing
      fetch requests when private-network access is disabled. *)

  val max_length : int
  (** [max_length] is the maximum accepted URL input length, in bytes. *)

  val of_string : allow_private_network:bool -> string -> (t, error) result
  (** [of_string ~allow_private_network s] is [Ok url] if [s], after trimming
      ASCII whitespace, is a valid web-tool URL. It is [Error e] otherwise.

      [allow_private_network] controls whether local, loopback, link-local,
      private, and bare single-label hosts are accepted. *)

  val to_string : t -> string
  (** [to_string url] is the normalized textual URL. *)

  val uri : t -> Uri.t
  (** [uri url] is [url] as a {!Uri.t}. *)

  val scheme : t -> [ `Http | `Https ]
  (** [scheme url] is [url]'s normalized scheme. *)

  val host : t -> string
  (** [host url] is [url]'s normalized lower-case host. *)

  val port : t -> int option
  (** [port url] is the explicit port in [url], if present. *)

  val effective_port : t -> int
  (** [effective_port url] is the explicit port, or [80] for HTTP and [443] for
      HTTPS. *)

  val origin : t -> string
  (** [origin url] is [scheme]://[host]:[effective_port]. *)

  val same_fetch_authority : t -> t -> bool
  (** [same_fetch_authority a b] is [true] iff [a] and [b] have the same scheme,
      effective port, and host after ignoring one leading ["www."] label.
      {!Web_fetch} uses this predicate to decide whether a redirect may be
      followed inside the original permission boundary. *)

  val private_ipaddr : Eio.Net.Ipaddr.v4v6 -> bool
  (** [private_ipaddr addr] is [true] iff [addr] is private, loopback,
      link-local, multicast, or otherwise not suitable for a public
      private-network-disabled fetch. *)

  val jsont : t Jsont.t
  (** [jsont] encodes URLs with {!to_string} and decodes with
      [allow_private_network:false]. It is intended for public web-tool URLs;
      private-network admission remains an explicit policy decision at tool
      input boundaries. *)
end

module Domain : sig
  (** Search domain filters. *)

  val normalize : string -> (string, string) result
  (** [normalize s] is [Ok domain] if [s], after trimming and lower-casing, is a
      domain filter accepted by {!Web_search}. It is [Error message] otherwise.

      Accepted domains are ASCII host names with at least two labels. Schemes,
      ports, paths, wildcards, and empty labels are rejected. *)
end

module Policy : sig
  (** Host-selected web access policy. *)

  (** {1:types Types} *)

  (** The type for configured web-search backends. *)
  type search_backend =
    | Disabled  (** No search tool is registered and search runs fail. *)
    | Brave of { api_key : string }
        (** Brave Search API backend. [api_key] is used only for the backend
            request header and must not be rendered in diagnostics or outputs.
        *)

  type t
  (** The type for web-tool policy.

      A policy controls catalog registration, private-network admission, fetch
      redirects, response byte limits, model-visible output limits, request
      timeouts, user agent, and search backend selection. *)

  (** {1:constructors Constructors} *)

  val make :
    ?enabled:bool ->
    ?allow_private_network:bool ->
    ?upgrade_http_to_https:bool ->
    ?max_fetch_bytes:int ->
    ?max_output_chars:int ->
    ?default_timeout_ms:int ->
    ?max_timeout_ms:int ->
    ?max_redirects:int ->
    ?user_agent:string ->
    ?search_backend:search_backend ->
    unit ->
    t
  (** [make ()] is a web policy with conservative defaults:
      - [enabled = false];
      - [allow_private_network = false];
      - [upgrade_http_to_https = true];
      - [max_fetch_bytes = 5 * 1024 * 1024];
      - [max_output_chars = 100_000];
      - [default_timeout_ms = 30_000];
      - [max_timeout_ms = 120_000];
      - [max_redirects = 10];
      - [user_agent] set to Spice's default user agent;
      - [search_backend = Disabled].

      Raises [Invalid_argument] if byte or character limits are negative, if
      timeouts are non-positive, if [default_timeout_ms > max_timeout_ms], if
      [max_redirects] is negative, or if [user_agent] is empty. *)

  (** {1:queries Queries} *)

  val enabled : t -> bool
  (** [enabled t] is [true] iff web tools should be exposed by
      {!Spice_tools.web}. *)

  val allow_private_network : t -> bool
  (** [allow_private_network t] is [true] iff URL validation admits local and
      private network hosts. *)

  val upgrade_http_to_https : t -> bool
  (** [upgrade_http_to_https t] is [true] iff {!Web_fetch.run} rewrites HTTP
      request URLs to HTTPS before network I/O. *)

  val max_fetch_bytes : t -> int
  (** [max_fetch_bytes t] is the maximum number of response bytes a fetch or
      search backend response may read. *)

  val max_output_chars : t -> int
  (** [max_output_chars t] is the maximum number of characters retained in a
      model-visible fetched body or HTTP-error preview. *)

  val default_timeout_ms : t -> int
  (** [default_timeout_ms t] is the timeout used when a tool input does not
      carry an explicit timeout. *)

  val max_timeout_ms : t -> int
  (** [max_timeout_ms t] is the largest explicit timeout accepted from tool
      input. *)

  val max_redirects : t -> int
  (** [max_redirects t] is the maximum number of same-authority redirects
      {!Web_fetch.run} follows. *)

  val user_agent : t -> string
  (** [user_agent t] is sent in web-tool HTTP requests. *)

  val search_backend : t -> search_backend
  (** [search_backend t] is the configured search backend. *)

  val resolve_timeout_ms : t -> int option -> (int, string) result
  (** [resolve_timeout_ms t requested] applies [t]'s timeout policy.

      [None] resolves to {!default_timeout_ms}. [Some n] is [Ok n] when
      [0 < n <= max_timeout_ms t], and [Error message] otherwise. *)
end

(** {1:content Content projection} *)

val truncate_middle : max_chars:int -> string -> string * bool * int
(** [truncate_middle ~max_chars text] is [(content, truncated, omitted_chars)].
    [content] is [text] unchanged when it fits. Otherwise [content] contains a
    bounded prefix and suffix separated by an omission marker, [truncated] is
    [true], and [omitted_chars] is the number of dropped characters. *)

val html_to_text : string -> string
(** [html_to_text html] is a best-effort visible-text projection of [html].
    Active and metadata elements used by {!sanitize_html} are skipped. *)

val html_to_markdown : string -> string
(** [html_to_markdown html] is a best-effort Markdown projection of [html]. It
    preserves simple headings, paragraphs, line breaks, and list markers, and
    skips active and metadata elements. *)

val sanitize_html : string -> string
(** [sanitize_html html] is [html] with [script], [style], [noscript], [iframe],
    [object], [embed], [meta], and [link] blocks removed.

    This is a bounded fetch-output sanitizer, not a browser-grade HTML security
    sanitizer. *)
