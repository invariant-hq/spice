(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The pure shell: the top-level Elm model, update, and view.

    The shell composes the surface modules ({!Banner}, {!Composer}, {!Footer},
    {!Home}) and owns the one source of screen-visibility truth — the home
    prelude before the first submit, the compact record after. It renders no
    content itself and reads no host, clock, or environment; the {!Runtime}
    supplies the {!Snapshot.t} at init and the {!Home.Brief.t} on the refresh
    tick, and interprets the effect intents. *)

(** The type for the composer's launch input. *)
type input =
  | Empty  (** The composer starts blank. *)
  | Draft of string
      (** The composer starts seeded with the text ([--draft]). *)
  | Submit of string
      (** The text is submitted as the first turn's prompt ([-p]/[--prompt]);
          the shell launches straight into the chat, past the home stage. *)

(** The type for the surface the process launches onto. *)
type launch =
  | Launch_chat  (** The home stage (or the chat, per {!input}/[session]). *)
  | Launch_review of { base_spec : string option }
      (** The review screen over the worktree diff ([spice review [BASE]]);
          closing it quits the process. *)

type startup = {
  cwd : Spice_path.Abs.t option;
  mode : Spice_protocol.Mode.t;
  session : Spice_session.Id.t option;
  input : input;
  launch : launch;
  sandbox : Spice_host.Sandbox.Mode.t option;
}
(** The startup configuration. [cwd] is the workspace root; when absent the
    runtime resolves the process working directory. [mode] is the turn mode the
    first runner is built under (the composer frame wears it from the first
    frame; the composer can switch it later). [session] is a session to resume
    at launch ([spice resume]): the runtime issues the same {!command} the
    sessions screen's resume does, so the TUI opens on the replayed transcript
    instead of the home stage. [input] seeds or submits the first draft.
    [launch] picks the launch surface. [sandbox] is the per-run sandbox-mode
    override ([--sandbox]): the runtime resolves it over the configured mode,
    and the sandbox record names its origin. The shell never reads it. *)

type t
(** The type for the shell model. *)

type msg
(** The type for shell messages. *)

(** The type for effect intents the runtime interprets. *)
type command =
  | Quit  (** Request terminal exit. *)
  | Reload_brief
      (** Ask the runtime to refresh the {!Home.Brief.t} from the host and
          dispatch it back. Emitted at init and on each prelude tick, never
          after submit. *)
  | Reload_health
      (** Ask the runtime for a one-shot Dune build-health verdict and dispatch
          it back with {!health_loaded}. Emitted on each chat tick, where the
          prelude {!Reload_brief} that otherwise carries dune health has stopped
          — it keeps the footer live and feeds the clean↔broken transition
          notices (01-transcript.md §Data notices, dune). *)
  | Start_turn of string
      (** Start a turn with the given prompt: the runtime attaches the session's
          {!Spice_host.Live} on the first one and submits the prompt. Emitted on
          every non-empty submit — the host queues a submit made while a turn is
          in flight, so the shell never blocks one. *)
  | Interrupt
      (** Interrupt the in-flight turn cooperatively. Emitted on the second esc
          of the two-stage interrupt while a turn streams. Ctrl+C never emits
          this — it is the quit chord, never an interrupt. *)
  | Interrupt_force
      (** Force a lagging interrupt: hard-cancel the in-flight step through
          {!Spice_host.Live.force_interrupt}, out of band. Emitted on a single
          esc pressed while the turn is already draining
          ([Turn.is_interrupting]), when the cooperative interrupt has not
          settled. *)
  | Load_sessions
      (** Load the quick-switch panel's rows from the host and dispatch them
          back with {!sessions_loaded}, or {!sessions_load_failed} on a store
          error. Emitted once when the panel opens (via the [/sessions]
          trigger), never refreshed while open. *)
  | Load_screen_sessions
      (** Load the browse screen's rows — every resumable session in the cwd,
          with recency groups, turn counts, and fork lineage — and dispatch them
          back with {!screen_loaded}, or {!screen_failed} on a store error.
          Emitted when the screen opens and after each rename/delete reloads. *)
  | Resume_session of Spice_session.Id.t
      (** Resume a session: the runtime loads its document, replays its durable
          events as {!live_event}s to rebuild the transcript, and attaches its
          {!Spice_host.Live} on the next continuation. Emitted on a resume pick
          (home ↵, the panel, or the screen). *)
  | Fork_session of Spice_session.Id.t
      (** Fork a session and resume into the child: the runtime forks the
          document host-side, then replays and attaches the child exactly as
          {!Resume_session}. Emitted by the screen's [f]. *)
  | Load_thread_document of Spice_session.Id.t
      (** Load a settled child's persisted document for a read-only drill-in
          (doc/plans/tui-next-threads.md §6 phase 5a): the runtime reads the
          child session by id and replays its durable events back as
          {!thread_document_loaded}, which the shell folds into the drilled
          chat. A settled child's document is complete, so a plain store read is
          race-free (a live child needs [Jobs.observe], §3.2 — deferred).
          Emitted by [↵]/click on a settled switcher row. *)
  | Rename_session of { id : Spice_session.Id.t; title : string }
      (** Persist [title] for session [id] via the host lifecycle verb, then
          reload the screen's rows ({!screen_loaded}). Emitted by the screen's
          inline rename. *)
  | Delete_session of Spice_session.Id.t
      (** Delete session [id] via the host lifecycle verb, then reload the
          screen's rows ({!screen_loaded}). Emitted by the screen's confirmed
          delete. *)
  | Load_settings
      (** Assemble the settings screen's facts from the host and dispatch them
          back with {!settings_loaded}, or {!settings_load_failed} on a host
          error. Emitted when the screen opens. *)
  | Write_config of { field : string; value : string option }
      (** Persist config [field] to the user config file ([Some] sets, [None]
          unsets), then re-assemble the facts. Emitted by the settings config
          tab's edits. *)
  | Toggle_skill of string
      (** Flip the named skill's membership in [skills.disabled] in the user
          config file, then re-assemble the facts. Emitted by the settings
          skills tab's toggle. *)
  | Load_model_panel
      (** Assemble the model panel's facts — the tool-capable visible catalog
          grouped by provider, each provider's account phase deciding the locked
          rows — and dispatch them back with {!model_facts_loaded}, or
          {!model_facts_failed} on a catalog error. Emitted when the panel opens
          (via [/model] or the settings model row). *)
  | Switch_model of {
      selector : string;
      effort : Spice_llm.Request.Options.Reasoning_effort.t option;
    }
      (** Validate [selector] through [Spice_host.Models.for_select] and persist
          it as [Field.model] with [effort] as [Field.reasoning] in the user
          config, then dispatch the confirmation back with {!model_switched}.
          Effective the next turn — the live attachment is not hot-swapped
          (mirrors old [lib/tui/runtime.ml] [save_model_selection]). Emitted by
          a model-panel pick. *)
  | Copy_text of string
      (** Copy the string to the terminal clipboard. Emitted by the settings
          status tab's session-id copy. *)
  | Load_dir of Spice_path.Rel.t
      (** Enumerate one workspace directory for the unified [@] completion and
          dispatch the classified rows back with {!dir_loaded}. The runtime
          applies the ignore set (the host default plus picker extras). Emitted
          when the mention list opens or descends into a directory. *)
  | Load_prompt_history
      (** Read the shared [history.jsonl] and dispatch its records back with
          {!prompt_history_loaded}, attributed to this process's session id.
          Emitted once at init. *)
  | Append_prompt_history of Draft.History_entry.t
      (** Persist a committed draft — submitted or discarded — to the shared
          [history.jsonl] under its cross-process lock, echoing the stored
          record back with {!prompt_history_appended}. Best-effort: a write
          failure loses one history line, never the draft. *)
  | Set_mode of Spice_protocol.Mode.t
      (** Declare the turn mode ([/plan], [/build] — 10-commands.md §Mode
          switches): the runtime builds subsequent runners under it and, when a
          session is attached, rebuilds and swaps the live runner
          ({!Spice_host.Live.set_runner}). *)
  | Reply_permission of {
      permission : Spice_session.Permission.Id.t;
      answer : Spice_permission.Policy.Review.answer;
      message : string option;
    }
      (** Resolve a blocked permission dialog: the runtime submits
          {!Spice_protocol.Command.Reply} to the attached session. Emitted when
          a permission dialog is allowed or denied. *)
  | Answer_tool of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      text : string;
    }
      (** Answer a blocked question (or an unblockable host-tool) dialog: the
          runtime submits {!Spice_protocol.Command.Answer}. *)
  | Resolve_plan of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      decision : Spice_protocol.Plan.Decision.t;
    }
      (** Resolve a blocked plan dialog: the runtime submits
          {!Spice_protocol.Command.Resolve_plan}, which applies the durable plan
          transition and answers the parked call host-side. *)
  | Run_shell of string
      (** Execute one user shell command ([!] — 03-composer.md §Shell mode)
          through {!Spice_tools.Shell} under the run's effective sandbox, off
          the session drain, and dispatch the settled block back with
          {!shell_finished}. The shell surface admits one command at a time. *)
  | Interrupt_shell
      (** Cancel the in-flight {!Run_shell}: its process group is terminated and
          the block settles interrupted. Emitted by the interrupt double-press
          while a shell command runs. *)
  | Review_command of Spice_tui_review.Effect.t
      (** Run one review-screen effect. The review sub-library
          ({!Spice_tui_review}) owns its whole asynchronous protocol — snapshot
          load, persistence write, worktree watch, debounced reload,
          source-comment mutation — and the shell forwards each effect blind;
          the runtime interprets it and dispatches the completion back as
          {!review_msg} (doc/plans/tui-next-review.md §3.3). *)
  | Load_auth_providers
      (** Ask the runtime for the passive provider facts the login / logout
          pickers render — providers, declared methods, env vars, and each
          account's phase / source / redacted fingerprint — dispatched back with
          {!auth_providers_loaded}. Emitted when [/login] / [/logout] opens the
          panel (09-auth.md). *)
  | Auth_save_api_key of {
      request : int;
      provider : Spice_llm.Provider.t;
      method_id : string;
      key : string;
    }
      (** Save an api-key credential: the runtime validates [key] at its edge
          ({!Spice_auth.Secret.api_key}), persists it, and checks it against the
          provider, dispatching the settled record back with {!auth_settled}
          under [request]. The raw [key] is the only secret crossing the seam —
          validated in the runtime, never rendered, never in the draft or
          history (09-auth §10). *)
  | Auth_browser_login of {
      request : int;
      provider : Spice_llm.Provider.t;
      method_id : string;
    }
      (** Drive an OAuth browser flow through
          {!Spice_host_builtin.Login.browser} off the Mosaic loop (it awaits a
          localhost callback up to 300 s): challenges dispatch back with
          {!auth_challenge}, the settled record with {!auth_settled}, both under
          [request]. A concurrent {!Auth_cancel} preempts the wait. tui-next
          never auto-opens the browser (09-auth §6) — {!Auth_open_url} does, on
          the panel's explicit enter. *)
  | Auth_device_login of {
      request : int;
      provider : Spice_llm.Provider.t;
      method_id : string;
    }
      (** Drive an OAuth (or provider) device-code flow through
          {!Spice_host_builtin.Login.device} off the Mosaic loop: the challenge
          dispatches back with {!auth_challenge}, the settled record with
          {!auth_settled}, both under [request]. Cancellable like
          {!Auth_browser_login}. *)
  | Auth_logout of { request : int; provider : Spice_llm.Provider.t }
      (** Remove [provider]'s stored credential through
          {!Spice_host_builtin.Login.logout} and dispatch the settled record
          (removed, or env-still-active) back with {!auth_settled} under
          [request]. *)
  | Auth_cancel of { request : int }
      (** Resolve the cancel promise of the in-flight browser / device flow
          [request], preempting its wait so it settles [Cancelled] (no secret
          written, no record). Emitted on esc from a waiting flow panel. *)
  | Auth_copy of string
      (** Copy the display-safe string (an authorization URL or a device user
          code) to the clipboard. Emitted by the flow panel's [c]. *)
  | Auth_open_url of { request : int; url : Uri.t }
      (** Launch the OS browser on [url]
          ({!Spice_host_builtin.Login.open_browser}) and dispatch
          {!auth_browser_opened} back under [request] on success, or
          {!auth_browser_open_failed} when no browser could be spawned. Emitted
          by the browser panel's explicit enter (09-auth §6). *)

(** How a submitted turn settled, as the runtime reports it to the shell. The
    document and the full {!Spice_protocol.Error.t} do not cross into the pure
    shell: only the rendering-relevant shape does. *)
type settled =
  | Finished
      (** The turn reached a terminal outcome. Its blocks already streamed
          through {!live_event}, so nothing is appended. *)
  | Waiting of Spice_protocol.Pending.t option
      (** The turn blocked awaiting a user answer. The working line flips to the
          static [⋯ Waiting for your answer]; the typed boundary, when present,
          opens the matching decision dialog ([None] for a boundary with no
          user-facing form). *)
  | Failed of { message : string }
      (** The drain failed without producing a terminal turn — a transport error
          that never reached the event stream. The shell appends a failure
          notice; this is the only failure source outside the turn reducer. *)

val brief_loaded : Home.Brief.t -> msg
(** [brief_loaded brief] is the message the runtime dispatches when a
    {!Reload_brief} completes, folding the refreshed [brief] into the model. *)

val live_event : now:float -> Spice_protocol.Event.t -> msg
(** [live_event ~now event] is the message the runtime dispatches for each
    {!Spice_host.Live} event, [now] stamped from the runtime's clock. The shell
    folds it through {!Turn.apply}. *)

val settled : now:float -> settled -> msg
(** [settled ~now result] is the message the runtime dispatches when a submitted
    turn settles, [now] stamped from the runtime's clock. *)

val health_loaded :
  now:float ->
  file:string option ->
  Spice_ocaml_dune.Rpc.Instance.Health.t ->
  msg
(** [health_loaded ~now ~file health] is the message the runtime dispatches when
    a {!Reload_health} poll completes: the build-health verdict, the failing
    file when the diagnostics name one, and the wall clock [now] the poll
    finished (the heal notice measures the outage from it). *)

val prompt_history_loaded :
  session:Spice_session.Id.t -> History.Entry.t list -> msg
(** [prompt_history_loaded ~session entries] is the message the runtime
    dispatches when {!Load_prompt_history} completes: the stored records, newest
    first, and the session id this process's records will carry — ctrl+r ranks
    that session's entries first. *)

val prompt_history_appended : History.Entry.t -> msg
(** [prompt_history_appended entry] is the message the runtime dispatches after
    an {!Append_prompt_history} persisted [entry], so the ctrl+r search sees it
    without a reload. *)

val shell_finished : Tool_block.t -> msg
(** [shell_finished block] is the message the runtime dispatches when a
    {!Run_shell} settles: the distilled result block the shell appends to the
    transcript before draining any queued prompt. *)

val dir_loaded :
  dir:Spice_path.Rel.t -> (Mention.item list, string) result -> msg
(** [dir_loaded ~dir result] is the message the runtime dispatches when a
    {!Load_dir} completes: the directory's classified rows, or the error the
    mention list renders — dropped if the list has since closed. *)

val sessions_loaded : Sessions_panel.row list -> msg
(** [sessions_loaded rows] is the message the runtime dispatches when a
    {!Load_sessions} completes, folding the quick-switch panel's [rows] into the
    surface — dropped if the panel has since closed. *)

val session_forked : parent_title:string -> msg
(** [session_forked ~parent_title] is the message the runtime dispatches once a
    {!Fork_session} has persisted the child, before the child's replay events:
    the shell appends the lineage record
    [forked to a new session · ↳ from "<parent_title>"] under the fresh banner
    (10-commands.md §/fork). [parent_title] is the parent's display title — its
    title, or its id when untitled ({!Spice_protocol.Session_summary}'s
    convention). *)

val sessions_load_failed : string -> msg
(** [sessions_load_failed message] is the message the runtime dispatches when
    {!Load_sessions} hits a store error, so the panel renders its error line
    instead of the empty state — dropped if the panel has since closed. *)

val screen_loaded : Sessions_screen.row list -> msg
(** [screen_loaded rows] is the message the runtime dispatches when
    {!Load_screen_sessions} completes, folding the browse screen's [rows] into
    the surface — dropped if the screen has since closed. *)

val screen_failed : string -> msg
(** [screen_failed message] is the message the runtime dispatches when
    {!Load_screen_sessions} hits a store error, so the screen renders its error
    line — dropped if the screen has since closed. *)

val settings_loaded : Settings_screen.facts -> msg
(** [settings_loaded facts] is the message the runtime dispatches when a
    {!Load_settings}, {!Write_config}, or {!Toggle_skill} completes, folding the
    re-assembled [facts] into the settings screen — dropped if it has since
    closed. *)

val settings_load_failed : string -> msg
(** [settings_load_failed message] is the message the runtime dispatches when
    assembling the settings facts hits a host error, so the screen renders its
    error line — dropped if it has since closed. *)

val model_facts_loaded : Model_panel.facts -> msg
(** [model_facts_loaded facts] is the message the runtime dispatches when a
    {!Load_model_panel} completes, folding the catalog [facts] into the model
    panel — dropped if it has since closed. *)

val model_facts_failed : string -> msg
(** [model_facts_failed message] is the message the runtime dispatches when
    assembling the model facts hits a catalog error, so the panel renders its
    error line — dropped if it has since closed. *)

val model_switched : string -> msg
(** [model_switched notice] is the message the runtime dispatches after a
    {!Switch_model} resolves: the confirmation naming the model and effort on
    success, or the host error on a rejected selector, shown as a footer flash.
*)

val thread_runs_loaded :
  session:Spice_session.Id.t -> Spice_protocol.Subagent_run.t list -> msg
(** [thread_runs_loaded ~session runs] is the message the runtime dispatches
    when it has loaded [session]'s child subagent runs from the artifact ledger
    (at session open or resume): the whole set replaces the model's, but only
    while [session] is still this process's attached session
    (doc/plans/tui-next-threads.md §1). *)

val thread_started : Spice_protocol.Subagent_run.t -> msg
(** [thread_started run] is the message the runtime dispatches when the registry
    mints [run] ({!Spice_host.Jobs} [Started]): the shell upserts it into the
    live set that feeds the footer's [* N agents] count. *)

val thread_asked :
  now:float -> message:string -> Spice_protocol.Subagent_run.t -> msg
(** [thread_asked ~now ~message run] is the message the runtime dispatches when
    [run] parks on a [message_parent] ask ({!Spice_host.Jobs} [Asked]): the
    shell writes the gray [› Message from @<role>: <message>] relay notice to
    the parent transcript and upserts [run]. *)

val thread_settled : now:float -> Spice_protocol.Subagent_run.t -> msg
(** [thread_settled ~now run] is the message the runtime dispatches when [run]
    reaches a caller-facing settlement ({!Spice_host.Jobs} [Settled]): the shell
    writes [run]'s settled line to the parent transcript once and upserts it,
    dropping it from the live count. *)

val thread_document_loaded :
  run:Spice_session.Id.t -> now:float -> Spice_protocol.Event.t list -> msg
(** [thread_document_loaded ~run ~now events] is the message the runtime
    dispatches when a {!Load_thread_document} completes: [events] are [run]'s
    durable session events, which the shell folds through the turn reducer into
    a read-only drilled-in chat (doc/plans/tui-next-threads.md §6 phase 5a). *)

val thread_drill_failed : run:Spice_session.Id.t -> string -> msg
(** [thread_drill_failed ~run message] is the message the runtime dispatches
    when a {!Load_thread_document} fails to read the child session: the shell
    flashes [message] and stays on the parent chat. *)

val auth_providers_loaded :
  (Auth_panel.provider_entry list, string) result -> msg
(** [auth_providers_loaded result] is the message the runtime dispatches when a
    {!Load_auth_providers} completes: the passive provider entries the pickers
    render, or the error line — folded into the auth panel, dropped if it has
    since closed. *)

val auth_challenge : request:int -> Auth_panel.challenge -> msg
(** [auth_challenge ~request challenge] is the message the runtime dispatches
    when a browser / device flow emits its display-safe [challenge] (the
    authorization URL, or the device URL + user code + expiry): the waiting
    panel shows it, when [request] matches the attempt on screen. *)

val auth_browser_opened : request:int -> msg
(** [auth_browser_opened ~request] is the message the runtime dispatches after
    an {!Auth_open_url} launched the browser: the panel's first line flips to
    "Browser opened…", when [request] matches. *)

val auth_browser_open_failed : request:int -> msg
(** [auth_browser_open_failed ~request] is the message the runtime dispatches
    when an {!Auth_open_url} could not spawn a browser: the panel surfaces a
    "Could not open a browser automatically" line under the link, when [request]
    matches. *)

val auth_settled : request:int -> Auth_panel.record -> msg
(** [auth_settled ~request record] is the message the runtime dispatches when a
    login / logout flow reaches a terminal outcome: the shell appends [record]'s
    settled line and closes the panel, when [request] matches the attempt on
    screen (a superseded or late settle is dropped). A cancelled flow produces
    no [auth_settled] — nothing happened (09-auth §8). *)

val review_msg : Spice_tui_review.msg -> msg
(** [review_msg m] wraps a review-screen completion message the runtime built (a
    snapshot load, a reload, a mutation result, a watch tick or failure) so it
    folds through the shell into {!Spice_tui_review.update}
    (doc/plans/tui-next-review.md §3.3). *)

val init :
  startup:startup ->
  snapshot:Snapshot.t ->
  reduced_motion:bool ->
  t * command list
(** [init ~startup ~snapshot ~reduced_motion] is the initial model for
    [snapshot] and its startup commands, per [startup]'s axes. Without a session
    it is the home model and a first {!Reload_brief}. With one ([spice resume])
    it is the session's chat — the same banner-headed transcript an in-app
    resume enters — and a {!Resume_session} that replays the durable events into
    it, so launch-resume and in-app resume are one path. {!Draft} seeds the
    composer; {!Submit} starts the first turn at once (the drop happens before
    the first frame; combined with a session — a pair the CLI rejects — it
    degrades to the draft seat rather than racing the replay). {!Launch_review}
    opens the review screen over whatever the other axes set up.
    [reduced_motion] holds the lockup static with no timers. *)

val update : msg -> t -> t * command list
(** [update msg t] folds [msg] into [t]. Composer activity flows through
    {!Composer.update}, whose events the shell routes: a submitted draft
    dispatches by shape — a known slash command through its {!Command.fate}
    ([/sessions] opens the quick-switch panel, [/thinking] flips whether
    reasoning renders and echoes the change; unwired fates flash an honest
    placeholder), a shell command flashes until its executor lands, and plain
    text starts a turn (the first is the drop — it swaps the prelude for the
    chat transcript, stops the brief refresh, and seeds the banner record);
    ["?"] on an empty draft toggles the shortcuts sheet. Typing freezes the
    lockup. Live events fold through {!Turn.apply} into the document; a key
    routed to an open panel folds through its surface (close on esc, the honest
    resume flash on a pick). Esc walks the ladder one rung per press — help,
    shell exit, two-stage draft clear (saved to history), two-stage interrupt;
    ctrl+c discards a non-empty draft to history in one press, shares the
    interrupt double-press mid-turn, and otherwise quits on its two-stage
    notice. *)

val view : t -> msg Mosaic.t
(** [view t] renders [t]: the home prelude, or — after the drop — the compact
    banner record over the scrolling transcript and live turn tail and the
    working line, with the shared composer and footer below. While a panel is up
    it replaces the composer region below the ▔ boundary (the stage's inset
    composer hidden in the prelude, the draft preserved), bottom-anchored under
    the same region everywhere. *)

val subscriptions : t -> msg Mosaic.Sub.t
(** [subscriptions t] are [t]'s event interests: keys (Ctrl+C, esc, ctrl+o),
    terminal resize, the 2s brief tick and the lockup frame timer while the
    prelude is live and animating, the ~0.1s turn tick while a chat turn is in
    flight, and the armed two-stage notice's expiry (quit, draft clear,
    interrupt — each on its own interval). *)
