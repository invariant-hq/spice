(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Effectful provider interpreters.

    Clients are the effectful provider side of the [spice.llm] boundary. They
    interpret checked {!Request.t} values, emit semantic {!Stream.Event.t}
    values while producing a terminal {!Response.t}, and classify
    provider-boundary failures as {!Error.t}. Authentication, transport,
    retries, provider protocol translation, and provider-owned replay projection
    belong to concrete provider packages.

    Construct clients with {!make} and consume them with {!response}. A client
    never hands transport ownership to its caller: concrete providers consume
    their protocol stream before the request returns. *)

type cancellation = unit -> bool
(** The type for cooperative cancellation checks.

    The callback must be cheap. Once it returns [true], it should keep returning
    [true]. It is deliberately a plain function so [spice.llm] stays independent
    from any runtime, fiber, signal, or session representation. *)

type accepts = Model.t -> bool
(** The type for model compatibility predicates.

    The predicate should be stable for the lifetime of the client. It is checked
    before {!run} is called. *)

type run =
  cancelled:cancellation ->
  on_event:(Stream.Event.t -> unit) ->
  Request.t ->
  (Response.t, Error.t) result
(** The type for one-request provider interpreters.

    A [run] callback receives requests accepted by the client, calls [on_event]
    for live semantic events in order, and returns the terminal response. It
    must consume and close its provider stream before returning. Provider
    failures remain structured by {!Error.phase}: {!Error.Startup} precedes
    event delivery and {!Error.Stream} follows stream handoff. *)

type t
(** The type for provider clients. *)

val make : provider:Provider.t -> ?accepts:accepts -> run:run -> unit -> t
(** [make ~provider ?accepts ~run ()] is a provider client backed by [run].

    [accepts] defaults to accepting models whose provider is [provider]. A
    custom predicate may further restrict accepted APIs or model ids. *)

val provider : t -> Provider.t
(** [provider t] is the provider interpreted by [t]. *)

val accepts : t -> Model.t -> bool
(** [accepts t model] is [true] iff [t] can interpret [model]. *)

val response :
  ?cancelled:cancellation ->
  ?on_event:(Stream.Event.t -> unit) ->
  t ->
  Request.t ->
  (Response.t, Error.t) result
(** [response ?cancelled ?on_event t request] interprets [request] with [t] and
    returns the terminal provider response.

    [cancelled] defaults to a function returning [false]. Providers should check
    it before starting transport work and while pulling events where feasible.
    Errors distinguish startup from post-handoff failures with {!Error.phase}.

    [on_event] observes each live {!Stream.Event.t} in stream order before the
    terminal response, for callers that render streaming progress. Omitting it
    observes no events and does not change the response.

    Returns an error with kind {!Error.Invalid_request} if
    [Request.model request] is not accepted by [t]. In that case [run] is not
    called. Provider transport resources are released before [response] returns,
    including when [on_event] raises. *)
