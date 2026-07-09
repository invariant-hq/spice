(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The effectful session boundary: store, hooks, and standalone workflows.

    This module is the effectful host companion to the pure {!Spice_session}: it
    resolves the session store, mints new sessions, projects saved sessions for
    listing, and owns the hooks and standalone workflows the execution loop
    speaks around. The loop itself is a value — see {!Runner} — constructed from
    injected parts.

    The vocabulary a run speaks is protocol data: a client submits a
    {!Spice_protocol.Command.t}, the engine settles it into a
    {!Spice_protocol.Outcome.t} beside the saved document, renders progress as
    {!Spice_protocol.Event.t}, and reports failures as {!Spice_protocol.Error.t}
    — the one error type a workflow or a {!Runner.execute} reports; the host
    defines no second one. This module adds the host-side pieces the protocol
    does not carry:

    - {!type:hooks}, the optional side effects threaded around the loop;
    - the standalone workflows {!compact}, {!generate_title}, {!create}, and
      {!listing}, which plan no tool steps and need no {!Runner}.

    Execution itself lives in {!Runner.execute}; host-tool dispatch in
    {!Handler}; the stateful attachment in {!Live}. *)

(** {1:hooks Hooks}

    Hooks are optional side effects around the interpreter, threaded into
    {!Runner.make}. They are not session state; build values through {!no_hooks}
    and the [with_*] combinators. The surviving set is the load-bearing one:
    {!with_prepare_request} and {!with_notices} carry notice injection,
    {!with_around_tool} carries mutation evidence, {!with_after_save} carries a
    save-suffix callback, {!with_terminal_observed} and {!with_cancelled} carry
    terminal cleanup and cancellation, and {!with_observe} carries the event
    stream. *)

type request_preparation = Session_loop.request_preparation = {
  request : Spice_llm.Request.t;
  commit : unit -> unit;
  rollback : unit -> unit;
}
(** A prepared ordinary model request. [commit] runs after a response is
    accepted; [rollback] runs when preparation or the provider call fails before
    a response is accepted. *)

type hooks = Session_loop.hooks
(** The type for optional interpreter side effects. Hooks are not session state;
    build values through {!no_hooks} and the [with_*] combinators. The concrete
    representation is opaque to consumers, who cannot name it. *)

val no_hooks : hooks
(** [no_hooks] installs nothing. *)

val with_prepare_request :
  (Spice_llm.Request.t -> (request_preparation, Spice_protocol.Error.t) result) ->
  hooks ->
  hooks
(** [with_prepare_request prepare hooks] adds request preparation for ordinary
    model requests. Summary requests used by compaction do not run this hook.
    Load-bearing: {!with_notices} is built on it. *)

val with_after_save :
  (Spice_session_store.Document.t -> Spice_session.Event.t list -> unit) ->
  hooks ->
  hooks
(** [with_after_save after_save hooks] adds a callback run after each saved
    event suffix, replacing any previously installed one. *)

val after_save :
  hooks -> Spice_session_store.Document.t -> Spice_session.Event.t list -> unit
(** [after_save hooks document events] runs [hooks]'s installed save-suffix
    callback. It is the eliminator a tap chains before recording its own
    post-save state. *)

val with_around_tool :
  (observe:(Spice_protocol.Event.t -> unit) ->
  Spice_session_store.Document.t ->
  Spice_session.Tool_claim.Started.t ->
  (Spice_tool.Output.t Spice_tool.Result.t -> unit) ->
  Spice_tool.Output.t Spice_tool.Result.t ->
  unit) ->
  hooks ->
  hooks
(** [with_around_tool around hooks] adds tool-scoped effects. [around] is called
    after the tool claim is saved and immediately before the executable effect
    runs; it receives the previously installed finish callback and returns the
    callback run after the tool effect and before the durable tool-finished
    event is saved. Successive combinators self-chain: [around] wraps the finish
    callback already installed. Load-bearing: mutation evidence is recorded
    through it.

    [around] takes [~observe], the run's event sink, passed by the interpreter
    at fire time — not captured when the hook is composed — so evidence emits to
    the runner's final observer whatever the hook composition order. *)

val with_observe : (Spice_protocol.Event.t -> unit) -> hooks -> hooks
(** [with_observe observe hooks] adds a timeline observer, replacing any
    previously installed one. It receives durable events after their session
    events are saved, and live-only events as they occur — the same
    {!Spice_protocol.Event.t} values a saved document projects into through
    {!Spice_protocol.Event.of_session}. *)

val observe : hooks -> Spice_protocol.Event.t -> unit
(** [observe hooks event] runs [hooks]'s installed observer on [event]. *)

val with_terminal_observed :
  (observe:(Spice_protocol.Event.t -> unit) ->
  Spice_session_store.Document.t * Spice_protocol.Outcome.t ->
  unit) ->
  hooks ->
  hooks
(** [with_terminal_observed terminal hooks] adds a callback run once when
    execution reaches a terminal outcome, receiving the same
    [(document, outcome)] pair {!Runner.execute} returns plus [~observe], the
    run's event sink, passed by the interpreter at fire time rather than
    captured at composition time. Successive combinators self-chain: the prior
    terminal callback runs before [terminal]. Load-bearing: the end-of-run
    mutation checkpoint records through it. *)

val with_cancelled : (unit -> bool) -> hooks -> hooks
(** [with_cancelled cancelled hooks] adds the cancellation signal the
    interpreter samples between effects, replacing any previously installed one.
*)

val with_notices :
  ?before_request:(unit -> unit) -> Notice_queue.t -> hooks -> hooks
(** [with_notices ?before_request queue hooks] adds request-boundary notice
    injection. [before_request] runs immediately before a batch is taken.
    Drained notices are appended to ordinary model-request preludes and
    committed only after a response is accepted; preparation or provider
    failures roll the batch back. Summary requests do not consume notices. *)

(** {1:stores Stores} *)

val store : stdenv:Eio_unix.Stdenv.base -> Host.t -> Spice_session_store.t
(** [store ~stdenv host] is the session store for [host]'s resolved
    configuration. Host configuration owns store-root resolution. *)

val store_error : Spice_session_store.Error.t -> Spice_protocol.Error.t
(** [store_error error] flattens a store error into the host's single protocol
    error: not-found, conflict, and corrupt/io storage errors keep their
    protocol shapes; wrapped pure session errors use the id carried by the store
    error, and unrepairable invariants flatten to
    {!Spice_protocol.Error.Internal}. This is the one mapping every store
    consumer shares; frontends define no second one. *)

val load :
  Spice_session_store.t ->
  Spice_session.Id.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [load store id] is {!Spice_session_store.load} with its error flattened
    through {!store_error} — the load every workflow and surface shares. *)

(** {1:birth Session birth} *)

val fresh_session_id : clock:_ Eio.Time.clock -> Spice_session.Id.t
(** [fresh_session_id ~clock] mints a session id from the clock's current time,
    process id, and a process-local counter. {!create} and {!fork} still refuse
    to replace an existing document, so a collision surfaces as an error rather
    than an overwrite. *)

val fresh_turn_id : clock:_ Eio.Time.clock -> Spice_session.Turn.Id.t
(** [fresh_turn_id ~clock] mints a turn id; see {!fresh_session_id} for the
    uniqueness contract. *)

val create :
  store:Spice_session_store.t ->
  id:Spice_session.Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Spice_session.Time.t ->
  unit ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [create ~store ~id ?title ~cwd ~created_at ()] mints a new active session
    with no semantic events and saves it, returning the created document.

    [created_at] is used for both metadata creation and update time. The write
    fails rather than replacing an existing document: a duplicate id is
    reported. Raises [Invalid_argument] if [title] is empty. *)

val fork :
  store:Spice_session_store.t ->
  clock:_ Eio.Time.clock ->
  ?id:Spice_session.Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [fork ~store ~clock ?id ?title ~cwd document] mints and saves a child
    session forked from [document]'s session, returning the created child
    document. [created_at] is the clock's current time.

    With an explicit [id], one write is attempted and a duplicate id is the
    caller's error. Without one, ids come from {!fresh_session_id} and a
    same-process id collision retries with a fresh mint (bounded, then
    {!Spice_protocol.Error.Internal}). [title] is the child's title verbatim —
    fork does not inherit the parent's title; a caller wanting inheritance
    passes it. Raises [Invalid_argument] if [title] is empty. *)

(** {1:rewind Rewind} *)

val rewind :
  store:Spice_session_store.t ->
  id:Spice_session.Id.t ->
  ?title:string ->
  cwd:Spice_path.Abs.t ->
  created_at:Spice_session.Time.t ->
  Spice_session.Anchor.t ->
  Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [rewind ~store ~id ?title ~cwd ~created_at anchor document] mints and saves
    a child session whose event log is [document]'s prefix up to [anchor],
    returning the created child document.

    Rewind is fork-shaped and transcript-only. The child is a fresh session —
    {!Spice_session.rewind} at the turn-granular [anchor] — carrying its own
    metadata ([id], [title], [cwd], [created_at]) and
    {!Spice_session.Metadata.Forked_from} lineage into [document]. The parent
    document and its ledger stay immutable, and the workspace is untouched: a
    paired filesystem revert is a separate concern this workflow does not carry.
    Anchoring is turn-granular; rewinding to a boundary {e before} a compaction
    drops the compaction with everything after it and revives the pre-compaction
    transcript by construction. The write fails rather than replacing an
    existing document, so a duplicate [id] is {!Spice_protocol.Error.Conflict}
    or an internal store error.

    The parent must be idle: an active turn is
    {!Spice_protocol.Error.Active_turn_exists} and a deleted parent is
    {!Spice_protocol.Error.Deleted}, exactly as {!create} and {!compact}
    require; the guard is on the {e parent}, so a [Before] anchor that would
    itself drop the active turn is still refused. An [anchor] naming a turn
    absent from [document], or an {!Spice_session.Anchor.After} anchor on an
    unfinished turn, flattens to {!Spice_protocol.Error.Internal} as an
    unrepairable invariant; callers preview the drop with
    {!Spice_session.dropped_turns} first to surface those as recoverable input
    errors before rewinding. Raises [Invalid_argument] if [title] is empty. *)

(** {1:listing Listing}

    A saved session projects into a presentation-neutral
    {!Spice_protocol.Session_summary.t} row that surfaces render, filter, or
    serialize without parsing display strings. *)

type listing = {
  rows : Spice_protocol.Session_summary.t list;
  warnings : string list;
}
(** The type for a saved-session listing. [warnings] contains bounded,
    user-facing diagnostics for store entries that could not be summarized. *)

val of_document :
  Spice_session_store.Document.t -> Spice_protocol.Session_summary.t
(** [of_document document] is the typed list projection for [document]. The
    returned {!Spice_protocol.Session_summary.revision} field is [Some] the
    document revision. *)

val corrupt_warning : Spice_session_store.Corrupt.t -> string
(** [corrupt_warning corrupt] is the bounded, user-facing diagnostic for a store
    entry that could not be summarized: its path and the first line of its
    decode or validation message. *)

val listing :
  documents:Spice_session_store.Document.t list ->
  corrupt:Spice_session_store.Corrupt.t list ->
  listing
(** [listing ~documents ~corrupt] assembles a saved-session listing: [rows] are
    the {!of_document} projections of [documents], and [warnings] are one
    {!corrupt_warning} per entry in [corrupt]. *)

val newest_in_cwd :
  Spice_session_store.t ->
  cwd:Spice_path.Abs.t ->
  ( Spice_protocol.Session_summary.t option * Spice_session_store.Corrupt.t list,
    Spice_protocol.Error.t )
  result
(** [newest_in_cwd store ~cwd] is the most recently updated resumable session
    whose {!Spice_protocol.Session_summary.cwd} equals [cwd], projected with
    {!of_document}, together with the corrupt store entries seen while scanning.

    "Resumable" is the set [spice resume] resolves: the store's non-archived,
    non-deleted sessions, ordered newest {!Spice_session.Metadata.updated_at}
    first. This is the query behind bare [spice resume], [--last], and the home
    brief's session line, so they agree. [Ok (None, _)] means no session lives
    in [cwd].

    {b Subagents.} A subagent's session is an ordinary store session; this query
    does not exclude it, exactly as [spice resume] does not. Distinguishing one
    would need the subagent run records beside the store — a heavier scan than a
    glance affords, and a divergence from resume. *)

val recent_in_cwd :
  Spice_session_store.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  cwd:Spice_path.Abs.t ->
  limit:int ->
  ( Spice_protocol.Session_summary.t list * Spice_session_store.Corrupt.t list,
    Spice_protocol.Error.t )
  result
(** [recent_in_cwd store ~fs ~cwd ~limit] is up to [limit] {b top-level}
    resumable sessions whose {!Spice_protocol.Session_summary.cwd} equals [cwd],
    projected with {!of_document} and ordered newest
    {!Spice_session.Metadata.updated_at} first — for the home's recents column
    (12-home.md §The recents list). Subagent child sessions are excluded (a
    single filename-only membership scan through [fs], as the session picker
    hides them) before the limit applies; this is the deliberate difference from
    {!newest_in_cwd}, which resolves [spice resume] and so does not exclude
    them. Corrupt entries seen while scanning are returned alongside and do not
    count against [limit]. *)

(** {1:threads Session threads}

    A session's family: the fork lineage recorded in
    {!Spice_session.Metadata.Forked_from} joined with the subagent runs recorded
    beside the store, rooted at the current session's oldest reachable ancestor.
*)

module Threads : sig
  (** The type for how an entry joined its family. *)
  type source =
    | Main  (** The family root. *)
    | Fork of { parent : Spice_session.Id.t }
    | Subagent of {
        parent : Spice_session.Id.t;
        role : Spice_protocol.Subagent.Role.t;
        status : Spice_protocol.Subagent_run.Status.t;
      }
        (** A child spawned as a subagent run under [parent], with the run's
            recorded role and last observed status. *)

  type entry = { summary : Spice_protocol.Session_summary.t; source : source }
  (** The type for one family member, in depth-first order from the root: each
      entry is followed by its children, siblings ordered by creation time then
      id. *)

  val of_store :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    store:Spice_session_store.t ->
    current:Spice_session.Id.t ->
    (entry list * string list, Spice_protocol.Error.t) result
  (** [of_store ~fs ~store ~current] is [current]'s session family and the
      listing warnings gathered building it (corrupt store entries, unreadable
      subagent records). Only relations whose both ends have a summary are
      linked; lineage cycles are cut at the revisit. A [current] with no saved
      summary is [Ok ([], warnings)] — the caller decides how to report it.
      Errors are store listing failures only. *)
end

(** {1:standalone Standalone workflows}

    {!compact} and {!generate_title} plan no tool steps, so they take the store
    and summary client directly and need no {!Runner}. *)

val compact :
  store:Spice_session_store.t ->
  client:Spice_llm.Client.t ->
  ?policy:Compactor.Policy.t ->
  ?observe:(Spice_protocol.Event.t -> unit) ->
  ?after_save:
    (Spice_session_store.Document.t -> Spice_session.Event.t list -> unit) ->
  Spice_session_store.Document.t ->
  (Compactor.result, Spice_protocol.Error.t) result
(** [compact ~store ~client document] summarizes the request-ready replay
    transcript in [document], installs a durable [user_requested] compaction,
    saves it, and returns the installed compaction. [observe] receives
    {!Spice_protocol.Event.t}s (compaction progress and the installed
    {!Spice_protocol.Event.Compaction}).

    The session must be active, not archived or deleted, and have no active turn
    ({!Error.Active_turn_exists} otherwise). A missing summary model is
    {!Error.No_compaction_model}; a non-request-ready transcript is
    {!Error.Transcript_not_ready}; an empty summary is
    {!Error.Empty_compaction_summary}. Overflowing summary requests drop the
    oldest input and retry a bounded number of times. *)

module Title : sig
  (** Pure halves of generated session titles. *)

  val instruction : prompt:string -> string
  (** [instruction ~prompt] is the title-model instruction for a session whose
      first user prompt is [prompt]. *)

  val normalize : string -> string option
  (** [normalize raw] is the saved title derived from a raw model reply: one
      whitespace-collapsed trimmed line, truncated to 60 bytes. [None] when
      nothing remains. *)
end

val title_for :
  client:Spice_llm.Client.t ->
  ?cancelled:(unit -> bool) ->
  model:Spice_llm.Model.t ->
  Spice_session_store.Document.t ->
  (string option, Spice_protocol.Error.t) result
(** [title_for ~client ~model document] is the title generated from [document]'s
    first user prompt via a model call, normalized with {!Title.normalize}. It
    is [Ok None] when [document] already has a title, contains no user prompt,
    or the model yields an empty title. It performs no store write — this is the
    slow, model-calling half; persist its result with {!save_title}, routing an
    attached session's write through {!Live.amend} so it serializes with the
    drain. [cancelled] is sampled by the client and defaults to never cancelled.
*)

val save_title :
  store:Spice_session_store.t ->
  title:string ->
  Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [save_title ~store ~title document] sets [title] on [document] and saves it,
    returning the saved document. [title] must be non-empty. Pair it with
    {!title_for}. *)

(** {1:lifecycle Lifecycle}

    Delete, archive, and restore are pure {!Spice_session} lifecycle mutations;
    these verbs pair each with the store save the caller would otherwise repeat,
    exactly as {!save_title} does for a title write. They are the non-attached
    path: an attached session must route its mutation through {!Live.write} so
    it serializes with the drain and cannot lose the on-disk revision to a
    concurrent turn save. *)

val delete :
  store:Spice_session_store.t ->
  Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [delete ~store document] marks [document]'s session deleted (a tombstone —
    the store keeps the entry, hidden from ordinary listings) and saves it,
    returning the saved document. Deleting a deleted session is idempotent. An
    active turn refuses with {!Spice_protocol.Error.Active_turn_exists}; the
    session need not be idle otherwise, and an archived session may be deleted.
*)

val archive :
  store:Spice_session_store.t ->
  Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [archive ~store document] marks [document]'s session archived and saves it,
    returning the saved document. Archiving an archived session is idempotent.
    An active turn refuses with {!Spice_protocol.Error.Active_turn_exists}; a
    deleted session refuses with {!Spice_protocol.Error.Deleted}. *)

val restore :
  store:Spice_session_store.t ->
  Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [restore ~store document] marks [document]'s session active again and saves
    it, returning the saved document. Restoring an active session is idempotent;
    a deleted session refuses with {!Spice_protocol.Error.Deleted}. *)

val generate_title :
  store:Spice_session_store.t ->
  client:Spice_llm.Client.t ->
  ?cancelled:(unit -> bool) ->
  model:Spice_llm.Model.t ->
  Spice_session_store.Document.t ->
  (Spice_session_store.Document.t, Spice_protocol.Error.t) result
(** [generate_title ~store ~client ~model document] generates and saves a title
    for [document] when it has no title and contains a first user prompt,
    normalizing with {!Title.normalize} — {!title_for} then {!save_title} in one
    call. A document that already has a title, has no user prompt, or yields an
    empty title is returned unchanged. [cancelled] is sampled by the client and
    defaults to never cancelled. This is the non-attached path; an attached
    session must split the halves so the save goes through {!Live.amend}. *)
