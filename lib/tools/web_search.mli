(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Read-only local web search tool.

    [web_search] sends a query to the host-configured search backend and returns
    structured result metadata: title, public URL, snippet, source, and optional
    published date. It is the discovery counterpart to {!Web_fetch}: use search
    to find candidate sources, then fetch a specific URL when exact page content
    matters.

    Search is provider-independent at the Spice tool boundary. The V1 backend is
    selected by {!Web.Policy.search_backend}; credentials remain policy data and
    are not exposed in tool output. *)

val name : string
(** [name] is ["web_search"]. *)

val description : string
(** [description] is the model-facing tool description. *)

module Input : sig
  (** Tool input. *)

  (** {1:types Types} *)

  (** The type for recency preference. The backend may approximate or ignore it.
  *)
  type freshness =
    | Anytime  (** No recency preference. *)
    | Day  (** Prefer results from the last day. *)
    | Week  (** Prefer results from the last week. *)
    | Month  (** Prefer results from the last month. *)
    | Year  (** Prefer results from the last year. *)

  type t
  (** The type for decoded search input. *)

  (** {1:constructors Constructors} *)

  val make :
    ?limit:int ->
    ?allowed_domains:string list ->
    ?blocked_domains:string list ->
    ?freshness:freshness ->
    string ->
    t
  (** [make ?limit ?allowed_domains ?blocked_domains ?freshness query] is search
      input for [query].

      Defaults are [limit = 5], empty domain filters, and [freshness = Anytime].
      Domain filters are normalized with {!Web.Domain.normalize}.

      Raises [Invalid_argument] if [query] is empty after trimming, longer than
      500 bytes, or contains NUL; if [limit] is outside \[[1];[20]\]; or if any
      domain filter is invalid. *)

  (** {1:queries Queries} *)

  val query : t -> string
  (** [query t] is the trimmed query string. The tool does not rewrite it. *)

  val limit : t -> int
  (** [limit t] is the maximum number of results requested from the backend. *)

  val allowed_domains : t -> string list
  (** [allowed_domains t] is the normalized allow-list. When non-empty, returned
      URLs must be on one of these domains or their subdomains. *)

  val blocked_domains : t -> string list
  (** [blocked_domains t] is the normalized deny-list. Returned URLs on these
      domains or their subdomains are omitted. *)

  val freshness : t -> freshness
  (** [freshness t] is the requested recency preference. *)

  (** {1:tool_contract Tool contract} *)

  val contract : t Spice_tool.Input.t
  (** [contract] decodes the JSON object accepted by the model-facing tool.

      Required field:
      - ["query"], a string.

      Optional fields:
      - ["limit"], an integer in \[[1];[20]\], defaulting to [5];
      - ["allowed_domains"] and ["blocked_domains"], arrays of domain names;
      - ["freshness"], one of ["anytime"], ["day"], ["week"], ["month"], or
        ["year"], defaulting to ["anytime"]. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] is [Ok input] if [json] satisfies {!contract}, and
      [Error message] otherwise. Constructor exceptions are reported as decode
      errors. *)
end

val permissions :
  policy:Web.Policy.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~policy input] is the network permission request needed for the
    configured search backend.

    If web tools are disabled, if the query is empty, or if
    {!Web.Policy.search_backend} is {!Web.Policy.Disabled}, the list is empty.
    Otherwise the list contains one request from source {!name} with a network
    access for the backend endpoint. Domain filters are result constraints, not
    separate network permissions. *)

module Output : sig
  (** Typed search output retained in {!Spice_tool.Output}. *)

  (** {1:types Types} *)

  (** The type for the backend that produced the output. *)
  type backend = Brave  (** Brave Search API backend. *)

  type result = {
    title : string;  (** Search result title. *)
    url : Web.Url.t;  (** Public result URL accepted by {!Web.Url.of_string}. *)
    snippet : string;
        (** Backend-provided result snippet with simple HTML removed. *)
    published : string option;
        (** Backend-provided recency or publication string, if any. *)
    source : string option;
        (** Backend-provided source name, or the URL host when available. *)
  }
  (** The type for one search result. *)

  type t
  (** The type for complete typed search evidence. *)

  (** {1:queries Queries} *)

  val query : t -> string
  (** [query t] is the executed query. *)

  val backend : t -> backend
  (** [backend t] is the backend that produced [t]. *)

  val results : t -> result list
  (** [results t] are the returned results after URL validation and domain
      filtering. The list length is at most the requested limit. *)

  val duration_ms : t -> int
  (** [duration_ms t] is the elapsed tool-run duration in milliseconds. *)

  (** {1:encoding Encoding} *)

  val encode : t Spice_tool.Output.encoder
  (** [encode t] is the erased tool output for [t].

      The text projection lists result titles, URLs, snippets, and optional
      metadata. The JSON projection contains query, backend, duration, and
      result records. Raw provider payloads and credentials are never included.
  *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is [Some t] if [output] was produced by {!encode},
      and [None] otherwise. *)
end

val run :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  http:Cohttp_eio.Client.t ->
  policy:Web.Policy.t ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sw ~mono_clock ~http ~policy input] executes [input] with the
    configured search backend.

    If [cancelled ()] is [true] before work starts, the result is interrupted.
    If web tools are disabled, the result fails with [`Permission_denied]. If
    search is disabled, the result fails with [`Unavailable].

    The Brave backend performs a credentialed backend request using the API key
    in policy, applies recency when supported, validates result URLs as public
    web URLs, applies domain filters, and completes successfully with zero or
    more results. Backend HTTP errors, oversized backend responses, malformed
    JSON, transport errors, and timeouts fail. *)

val tool :
  sw:Eio.Switch.t ->
  mono_clock:_ Eio.Time.Mono.t ->
  http:Cohttp_eio.Client.t ->
  policy:Web.Policy.t ->
  unit ->
  Spice_tool.t
(** [tool ~sw ~mono_clock ~http ~policy ()] is the erased model-facing
    {!Spice_tool.t} backed by {!run}, {!Input.contract}, {!permissions}, and
    {!Output.encode}. *)
