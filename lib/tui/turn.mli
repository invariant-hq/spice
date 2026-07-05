(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The in-flight turn (doc/plans/tui-next-transcript.md §The fold invariant).

    One reducer over {!Spice_protocol.Event.t}, one law: durable events build the
    document (settled {!Transcript.block} values), live-only events only animate
    the tail (delta buffers, running tools, the working line). A live-only event
    can never create a document block. Replay ({!Spice_protocol.Event.of_session},
    durable-only) therefore lands settled through the identical path — no replay
    flag threads through.

    The reducer is pure: it reads no clock, taking [~now] instead, so a given
    event stream and clock reproduce the same blocks and tail every time. *)

type t
(** The in-flight turn's ephemeral state. *)

val idle : t
(** [idle] is the reducer at rest: no turn in flight, empty buffers. *)

val in_flight : t -> bool
(** [in_flight t] is [true] from the moment the shell requests a turn ({!request})
    through its durable {!Spice_protocol.Event.Turn_finished} — spanning the
    pending window before {!Spice_protocol.Event.Turn_started} and the running
    turn after it. The shell gates the turn's spinner tick and the esc-interrupt
    on it, so both engage within a frame of submit rather than waiting on the
    host. *)

val todo_board : t -> Spice_protocol.Todo.t option
(** [todo_board t] is the latest todo board written during the current turn, or
    [None] before any [todo_write] (02-tools.md §Todo block, strip mirror). Each
    [todo_write] also settles an ordinary document block at its call site, so
    this is a glance accessor for a status-strip mirror — not the render path —
    and it clears when the turn settles. *)

val request : now:float -> prompt:string -> t -> t
(** [request ~now ~prompt t] marks a turn requested — submitted by the shell but
    not yet started by the host. It is ephemeral tail state, never a document
    block: {!tail} echoes [prompt] styled as its eventual settled
    {!Transcript.User} block, {!working_line} runs the elapsed clock from [now],
    and {!Spice_protocol.Event.Turn_started} replaces it with the real block
    while carrying that same clock forward (the user's clock started at submit).
    {!in_flight} is [true] from here. Built from {!idle}, so it clears any
    settled prior turn's buffers. *)

val rebase_pending : by:float -> t -> t
(** [rebase_pending ~by t] shifts a still-pending turn's ({!request}) elapsed
    clock by [by] seconds; a no-op once the turn is running. The shell applies it
    with the delta between its previous and the incoming event's timestamp, so a
    pending turn timed on the drop-relative modeled clock is carried into the
    first runtime-stamped event's wall-clock domain and the working line's
    elapsed does not jump across {!Spice_protocol.Event.Turn_started}. *)

val apply :
  now:float ->
  show_reasoning:bool ->
  Spice_protocol.Event.t ->
  t ->
  t * Transcript.block list
(** [apply ~now ~show_reasoning event t] folds [event] into [t], returning the
    updated state and the settled blocks to append to the document in transcript
    order — empty for every live-only event. [now] is monotonic seconds, the
    only clock the reducer sees; it starts the step timer whose elapsed becomes a
    reasoning block's duration.

    [show_reasoning] is [false] under [/thinking off]: the durable
    {!Spice_protocol.Event.Assistant} then emits no {!Transcript.Reasoning}
    block at all. The invariant is that hidden thinking is never added rather
    than filtered downstream — the document stays clean at the source, so replay
    reproduces it identically.

    {!Spice_protocol.Event.Turn_finished}'s [final_text] is ignored: every model
    step's durable {!Spice_protocol.Event.Assistant} is already rendered, so the
    turn's last text is on the document and reconciling [final_text] would double
    it. *)

val interrupting : t -> t
(** [interrupting t] marks the turn as draining after a cooperative interrupt.
    The shell sets this on esc — it is not an event — and the working line
    reflects it until the turn settles. *)

val is_interrupting : t -> bool
(** [is_interrupting t] is whether {!interrupting} has been set: the turn is
    draining after a cooperative interrupt. The shell reads it to gate the esc
    force rung and to pick the working line's force clause. *)

val forcing : t -> t
(** [forcing t] marks the draining turn as being force-interrupted. The shell
    sets this on the esc pressed while {!is_interrupting} holds — when it
    escalates a lagging cooperative interrupt to
    {!Spice_host.Live.force_interrupt} — and the working line reflects it until
    the turn settles. *)

val is_forcing : t -> bool
(** [is_forcing t] is whether {!forcing} has been set. *)

val waiting : t -> t
(** [waiting t] marks the turn as awaiting a user answer, so the working line
    shows [⋯ Waiting for your answer]. The shell sets this — it is not an
    event — when a drain settles {!Spice_protocol.Outcome.Waiting} on a host
    tool or question, a path in which no
    {!Spice_protocol.Event.Permission_requested} fires. *)

val tail :
  now:float ->
  spinner:int ->
  width:int ->
  show_reasoning:bool ->
  expanded:bool ->
  t ->
  _ Mosaic.t option
(** [tail ~now ~spinner ~width ~show_reasoning ~expanded t] renders the ephemeral
    live tail below the settled document: a {!request}ed prompt's optimistic echo
    (styled as its eventual settled {!Transcript.User} block), the reasoning
    ticker, the streaming assistant prose, and running tool rows. It is [None]
    when no turn streams. [spinner] indexes the animation frame
    ({!Theme.spinner_frames}).

    The tail reproduces the document's spacing law: one blank line between its
    own top-level parts (01-transcript.md §Base grammar), so it reads live
    exactly as it will once settled. The single blank between the settled
    document's last block and the tail's first part is the caller's job — it is
    added only when the document is non-empty, honouring "none before the first
    block" on the drop's pending-prompt-only screen.

    [width] is the tail's column width: the ticker word-wraps the reasoning
    buffer to it and windows on the resulting visual lines, so the newest text
    stays visible instead of a paragraph clipping at the terminal edge.

    [show_reasoning] is [false] under [/thinking off]: the reasoning ticker is
    then omitted entirely, with no placeholder.

    [expanded] is the global verbose lens (ctrl+o, 01-transcript.md §Reasoning):
    while it is [true] the reasoning ticker pins open, showing the whole wrapped
    buffer instead of its constant-height 3-line rolling window. The [∴ Thinking]
    header is unchanged. *)

val working_line : now:float -> spinner:int -> t -> _ Mosaic.t option
(** [working_line ~now ~spinner t] is the single working line
    (01-transcript.md §The working line), or [None] when no turn is in flight —
    including the pending window after {!request}, where it shows
    [Working… (Ns · esc to interrupt)] from the request time.

    One clause renders, chosen by priority: interrupting, then waiting, then
    downloading, then compacting, then the plain thinking/working state.

    - Interrupting (set by {!interrupting}) is [⠹ Interrupting… (esc again to
      force)] while the cooperative drain runs, and [⠹ Interrupting… (forcing)]
      once {!forcing} escalates it to {!Spice_host.Live.force_interrupt}. The
      hint is honest — a further esc hard-cancels the drain rather than waiting
      for a cooperative point.
    - Waiting (set by {!waiting}) is the static [⋯ Waiting for your answer]: no
      spinner, no elapsed.
    - Downloading a provider model artifact
      ({!Spice_protocol.Event.Model_artifact}) is
      [⠹ Downloading <label>… (Ns · <received> / <total> · esc to interrupt)],
      the byte clause omitted when nothing has arrived and the total omitted when
      unknown. It clears when the next model step begins.
    - Compacting ({!Spice_protocol.Event.Compaction_progress}) is
      [⠹ Compacting conversation… (Ns · ↑ <projected> tokens · esc to
      interrupt)], the input-token projection the trigger decided with.
    - Otherwise [⠹ Working… (Ns · …)] — [Thinking…] while only reasoning
      streams — with the parenthetical carrying, after the always-present
      elapsed: a [N agents] count while {!Spice_llm.Tool.Call} subagent tools
      run (02-tools.md §Subagents), then [↓ N tokens] of turn output spend once
      nonzero (01-transcript.md), then [esc to interrupt].

    Turn output spend sums the per-step {!Spice_protocol.Event.Usage_updated}
    snapshots, each durable {!Spice_protocol.Event.Assistant}'s
    {!Spice_llm.Response.usage} replacing its step's live snapshot so a settled
    step is counted once. Elapsed always shows (except the static waiting line);
    on settle the caller replaces the line with the idle footer rather than
    pushing it into scrollback. *)
