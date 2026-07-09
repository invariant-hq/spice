(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Effectful provider interpreters.

    Clients are the effectful provider side of the [spice.llm] boundary. They
    interpret checked {!Request.t} values, return semantic {!Stream.t} values,
    and classify provider-boundary failures as {!Error.t}. Authentication,
    transport, retries, provider protocol translation, and provider-owned replay
    projection belong to concrete provider packages.

    Construct clients with {!make}. Use {!stream} when callers need live events
    or early tool-call progress; use {!response} when they only need the
    terminal {!Response.t}. *)

type cancellation = unit -> bool
(** The type for cooperative cancellation checks.

    The callback must be cheap. Once it returns [true], it should keep returning
    [true]. It is deliberately a plain function so [spice.llm] stays independent
    from any runtime, fiber, signal, or session representation. *)

type accepts = Model.t -> bool
(** The type for model compatibility predicates.

    The predicate should be stable for the lifetime of the client. It is checked
    before {!run} is called. *)

type run = cancelled:cancellation -> Request.t -> (Stream.t, Error.t) result
(** The type for one-request provider interpreters.

    A [run] callback receives requests accepted by the client. It reports
    startup failures by returning [Error _]. Once a stream has been returned,
    later provider failures are reported by the stream as {!Stream.Failed}. The
    stream owns any transport resources until it is closed or consumed. *)

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

val stream :
  ?cancelled:cancellation -> t -> Request.t -> (Stream.t, Error.t) result
(** [stream ?cancelled t request] starts one model request.

    [cancelled] defaults to a function returning [false]. Providers should check
    it before starting transport work and while pulling stream events where
    feasible. A cancellation observed before startup may return an error with
    kind {!Error.Cancelled}; a cancellation observed after startup may emit
    {!Stream.Failed} with an error of the same kind.

    Returns an error with kind {!Error.Invalid_request} if
    [Request.model request] is not accepted by [t]. In that case [run] is not
    called. *)

val response :
  ?cancelled:cancellation ->
  ?on_event:(Stream.Event.t -> unit) ->
  t ->
  Request.t ->
  (Response.t, Error.t) result
(** [response ?cancelled ?on_event t request] streams [request] with [t] and
    collects the terminal provider response.

    [response] returns startup errors from {!stream} directly. Once a stream has
    started, it returns the result of {!Stream.collect}. The stream is closed
    before [response] returns.

    [on_event] observes each live {!Stream.Event.t} in stream order before the
    terminal response, for callers that render streaming progress. Omitting it
    is exactly {!Stream.collect}: no event is observed and the collected
    response is unchanged, so a non-observing caller sees identical behavior. *)
