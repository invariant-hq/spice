(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** A running attachment to one session.

    Live is the one genuinely stateful piece, provided once because it is where
    naive re-implementations race. It owns the current document, a single-drain
    command loop, cancellation, and event fan-out, all built on
    {!Runner.execute}. Using it is optional: the headless CLI ignores Live and
    drives {!Runner.execute} in its own loop; a TUI attaches one Live per
    session, replacing its fiber-per-command spawning, cancel-thunk table, and
    document-reload-per-action.

    A remote surface would use Live as its session object, with
    {!Spice_protocol.Command.t} and {!Spice_protocol.Event.t} as its wire
    shapes. *)

type t
(** The type for a live session attachment. *)

val attach :
  sw:Eio.Switch.t -> runner:Runner.t -> Spice_session_store.Document.t -> t
(** [attach ~sw ~runner document] attaches to [document], starting the
    single-drain command loop as a fiber on [sw].

    Live is per-session, not per-turn: it survives a
    {!Spice_protocol.Outcome.Finished} outcome so the next
    {!Spice_protocol.Command.Start} can be submitted on the same attachment. Its
    resources — the loop fiber, subscriptions — are released when [sw]
    completes; there is no implicit disposal when a turn finishes. *)

val set_runner : t -> Runner.t -> unit
(** [set_runner t runner] replaces the runner used to drain [t]'s commands.

    The replacement takes effect at the next drain start: an in-flight drain
    completes under the runner it started with. Queued commands, {!events} and
    {!on_settled} subscriptions, the held {!document}, and the cancellation
    state are all unaffected. Live taps [runner]'s hooks exactly as {!attach}
    does.

    Use this for per-turn configuration changes on a live session: a model,
    mode, or reasoning change rebuilds the run environment and swaps the runner,
    then submits the next {!Spice_protocol.Command.Start} on the same
    attachment. *)

val detach : t -> unit
(** [detach t] stops [t]'s drain loop and drops its subscriptions.

    The loop fiber exits promptly — an in-flight drain runs to completion, since
    [detach] does not cancel, but no queued or later-{!submit}ted command drains
    after it. {!events} and {!on_settled} subscriptions are cleared, so nothing
    further is delivered. The held {!document} and {!outcome} keep returning the
    last state. Use this to release a stale attachment — for instance after an
    out-of-band compaction rewrites the document under it — instead of leaving
    its loop fiber idling on [sw] until the switch completes. *)

val submit : t -> Spice_protocol.Command.t -> unit
(** [submit t command] enqueues [command] for the single drain.

    At most one command drains at a time. A {!Spice_protocol.Command.Start}
    submitted while a turn is active (running or blocked) queues until the
    active turn finishes; a continuation ({!Spice_protocol.Command.Reply},
    {!Spice_protocol.Command.Answer}, {!Spice_protocol.Command.Finish_tool})
    drains against the current blocked turn. {!Spice_protocol.Command.Interrupt}
    preempts: it flips the cancellation the runner samples so an in-flight model
    or tool step unwinds the turn to a terminal
    {!Spice_protocol.Outcome.Finished} with an [Interrupted] outcome, and it is
    processed next. When a provider surfaces the cancellation as an error
    mid-stream rather than at a step boundary, that errored drain reports
    nothing and the queued interrupt finishes the still-active turn as
    [Interrupted] instead — so an interrupt always settles as one {!on_settled}
    result. Commands already queued when the interrupt arrives are
    {b preserved}, not flushed: interrupt targets the active turn, not the
    queue, so a follow-up {!Spice_protocol.Command.Start} queued behind it still
    drains after the interrupt settles. Submitting is non-blocking and never
    runs the command on the caller's fiber.

    A submitted {!Spice_protocol.Command.Interrupt} is {b cooperative}: it only
    flips the flag the runner samples, so it settles at the next step boundary or
    [cancelled] poll. An in-flight step blocked in a wait that reaches neither —
    a stalled provider stream read, a tool that never polls its [cancelled] —
    holds the single drain fiber, and the queued interrupt cannot run until that
    {!Runner.execute} returns, so a cooperative interrupt can lag indefinitely.
    {!force_interrupt} is the escalation for that case. *)

val force_interrupt : ?reason:string -> t -> unit
(** [force_interrupt t] hard-cancels the in-flight step and settles the active
    turn as [Interrupted] promptly, without waiting for a cooperative drain
    point.

    Where a submitted {!Spice_protocol.Command.Interrupt} only flips the sampled
    flag, [force_interrupt] additionally cancels the cancellation scope the
    current drain runs under: a provider stream blocked in an {!Eio} flow read
    unwinds through structured cancellation, and — because a
    [run_in_systhread] tool wait is uncancellable — the same flag it raises wakes
    a [cancelled]-polling tool so that wait completes too. The unwound drain
    reports nothing; the still-active turn is then finished from the last durable
    document with synthesized interrupted results for every open call, settling
    the {b exactly one} {!on_settled} result a cooperative interrupt would have —
    delivered now rather than at a safe point. Queued commands are {b preserved}
    exactly as a submitted interrupt preserves them.

    Force is Live-only and out of band: it is not a {!Spice_protocol.Command.t},
    because it preempts an in-flight fiber rather than enqueuing work — there is
    no wire form. It is non-blocking and cannot itself hang: it schedules the
    cancellation and returns on the caller's fiber without awaiting the unwind,
    and the flag it raises guarantees even an uncancellable systhread wait exits.
    With no drain in flight it degrades to a cooperative interrupt (flag plus a
    queued {!Spice_protocol.Command.Interrupt}); with no active turn at all it is
    a no-op. [reason] labels the synthesized [Interrupted] outcome. *)

val amend :
  t ->
  (Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result) ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [amend t edit] runs [edit] against [t]'s current in-memory document on the
    single drain fiber, serialized with turn appends, and adopts [edit]'s result
    as the new document.

    Use it for metadata writes — a title or rename — that must not interleave
    with an in-flight turn's saves: routing the store write through the sole
    intra-process writer keeps the on-disk revision equal to [t]'s, so the
    write's own conflict check cannot lose an update to a concurrent drain save.
    [edit] must not block on the model — do the model call first (see
    {!Session.title_for}) — because it holds the drain while it runs.

    Blocks the caller until the drain runs the job, then returns [edit]'s
    result: [Ok document] with the adopted document, or [Error _] (in which case
    the held {!document} is unchanged). A blocking call, unlike the
    fire-and-forget {!submit}; a job queued while a turn is in flight runs once
    that turn blocks or finishes, never during it. On a detached attachment it
    is {!Spice_protocol.Error.Internal} at once, since no drain remains to run
    it. *)

val write :
  ?live:t ->
  store:Spice_session_store.t ->
  session:Spice_session.Id.t ->
  f:
    (Spice_session_store.Document.t ->
    (Spice_session_store.Document.t, Spice_protocol.Error.t) result) ->
  unit ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [write ?live ~store ~session ~f ()] runs the saving edit [f] against
    [session]'s document: through {!amend} when [live] is that session's
    attachment (serialized with in-flight turn saves), else against a fresh
    load from [store]. The single home of the attached-or-direct write duality
    — a surface holding an optional attachment does not branch on it. [f]
    performs the store save itself, exactly as {!amend} requires. *)

val events : t -> (Spice_protocol.Event.t -> unit) -> unit
(** [events t handler] subscribes [handler] to [t]'s event stream.

    Every {!Spice_protocol.Event.t} the drain produces — durable after its save,
    live-only as it occurs — is delivered to each subscriber synchronously on
    the drain fiber, in order. Live taps the runner's observer to obtain them;
    an observer the consumer installed on the same runner still fires, so
    headless rendering and Live subscribers coexist. A subscriber that raises
    does not abort the drain loop or starve other subscribers: the exception is
    isolated to that delivery. Subscriptions last until [sw] completes.

    The event stream carries only renderable facts; execution failures are not
    events. They reach the surface through {!on_settled} (push) and {!outcome}
    (pull). *)

val on_settled :
  t ->
  (( Spice_session_store.Document.t * Spice_protocol.Outcome.t,
     Spice_protocol.Error.t )
   result ->
  unit) ->
  unit
(** [on_settled t handler] subscribes [handler] to each completed drain.

    When a submitted command's drain settles, its full {!Runner.execute} result
    — [Ok (document, outcome)] (blocked or finished) or [Error _] — is delivered
    to each subscriber, once per settled command, on the drain fiber. This is
    the completion signal: it is how the surface learns a drain finished so it
    can inspect the blocked outcome and prompt, and how a
    {!Spice_protocol.Error.Provider} or storage failure reaches the surface to
    be rendered and to reset its run state. Keeping {!Spice_protocol.Error.t}
    off the event stream keeps it a pure rendering vocabulary. Subscriber
    exceptions are isolated as in {!events}. Each delivered result is the drain's
    settled outcome — [Ok (document, outcome)] for a successful blocked or
    finished drain, [Error _] for a failed one. Surfaces match a blocked
    outcome's classified call to render permission and host-tool prompts, and
    render [Error _] as a run failure. An errored drain does not flush the queue:
    subsequent commands drain normally and fail on their own terms if the session
    state no longer supports them (e.g. a continuation whose boundary is gone
    returns its own {!Spice_protocol.Error.t}). *)

val document : t -> Spice_session_store.Document.t
(** [document t] is the latest saved document — the current attachment state,
    without a store reload. A drain that ends in [Error _] does not advance it:
    it stays at the last state durably saved before the failure. *)
