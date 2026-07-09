(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

type input = Empty | Draft of string | Submit of string
type launch = Launch_chat | Launch_review of { base_spec : string option }

type startup = {
  cwd : Spice_path.Abs.t option;
  mode : Spice_protocol.Mode.t;
  session : Spice_session.Id.t option;
  input : input;
  launch : launch;
  sandbox : Spice_host.Sandbox.Mode.t option;
}

(* [startup]'s mode, projected here while the label is unambiguous — the model
   record below takes the [mode] label over. *)
let startup_mode startup = startup.mode

(* The in-flight chat: the settled transcript document, the reducer state for the
   live turn tail, the ctrl+o lens, and the animation clock. [now] is the modeled
   time — seeded and corrected by each runtime-stamped event and advanced by the
   turn tick between them — so the view reads no clock of its own. *)
(* The last DEFINITE Dune build verdict the chat's transition law tracks
   (01-transcript.md §Data notices, dune). [Build_unknown] is "no verdict yet" —
   the seed when the home brief was disconnected, and where a Disconnected or
   Unknown live poll leaves it: neither fires a notice nor resets the baseline,
   so an RPC connection that blips as a turn spawns and drops its watch cannot
   flap the build state. *)
type build_state = Build_unknown | Build_clean | Build_broken of int

type chat = {
  transcript : Transcript.t;
  turn : Turn.t;
  (* The latest todo board written this chat, RETAINED across turn settles
     (02-tools.md §Todo block, revised 2026-07-08): a board with an open item
     stays the strip/pane tenant between turns so detached cross-turn work stays
     visible. [Turn.todo_board] clears on settle by design; this holds the last
     board. The next [todo_write] replaces it; a fresh chat (drop / resume /
     clear) drops it. Rendered only while an item is non-terminal — see
     [active_board]. *)
  board : Spice_protocol.Todo.t option;
  expanded : bool;
  spinner : int;
  now : float;
  (* The transcript's scroll state (01-transcript.md §Seam replay, scroll,
     spacing). [scroll] is the settled vertical offset the scrollport last
     reported; [reveal] is a pending serial-keyed one-shot paging/wheel jump —
     the serial makes an equal offset re-honor, since the scrollport ignores a
     reused reveal key. Sticky-bottom follow lives in the scrollport itself. *)
  scroll : int;
  reveal : (int * int) option;
  (* Live Dune build health, watched during chat (the brief tick that feeds the
     footer stops at the drop, so without this the footer would freeze and no
     transition could be seen). [health] is the last poll's raw verdict, seeded
     from the home brief at the drop so the footer never blanks across the jump;
     [build] is the definite clean/broken baseline the transition law compares
     against; [broken_since] is the wall-clock start of the current outage, for
     the heal notice's outage fact — stamped on the observed break, or lazily on
     the first live confirmation when the chat opened already broken. *)
  health : Spice_ocaml_dune.Rpc.Instance.Health.t;
  build : build_state;
  broken_since : float option;
}

(* The one source of screen-visibility truth (doc/plans/tui-next.md): the live
   home stage, or the chat transcript after the drop. *)
type phase = Prelude | Chat of chat

(* The second axis of visibility, orthogonal to [phase]
   (doc/plans/tui-next-surfaces.md §The three forms): [surface] alone decides
   what renders below the transcript and where keys go. [Conversing] leaves the
   composer with the keyboard; a [Panel] replaces the composer region below the
   ▔ boundary and owns every key beneath it (a panel is modal); a [Screen] owns
   the whole region and returns to the prior view on esc. Only the session
   quick-switch panel and the sessions browse screen exist this iteration; other
   surfaces land with their tasks. *)
type surface = Conversing | Panel of panel | Screen of screen

and panel =
  | Session_switch of Sessions_panel.t
  | Model of model_panel
  | Dialog of Dialog.t
      (** A decision dialog (permission, plan, question). It is a panel that
          parks the working line and, on deny/adjust/custom-answer, borrows the
          composer (see {!borrow}) (03-ia §Dialogs). *)
  | Auth of Auth_panel.t
      (** The provider login / logout drill-down (09-auth.md): a staged panel
          (provider pick, method pick, masked api-key entry, browser / device
          flow, working line) opened by [/login] / [/logout]. The masked api-key
          buffer lives inside the surface, never in the composer draft — a
          secret must never enter a buffer with history (09-auth §10 rule 1). *)

(* The model panel remembers where it was opened from so esc returns there: the
   [/model] command opens it over the chat (esc restores the composer), the
   settings config Model row opens it over the settings screen (esc restores that
   screen unchanged — 03-ia §Settings, the one managed row). *)
and model_panel = { panel_state : Model_panel.t; return : model_return }
and model_return = To_chat | To_settings of Settings_screen.t

and screen =
  | Sessions of Sessions_screen.t
  | Settings of Settings_screen.t
  | Review of Spice_tui_review.t

(* The armed two-stage affordances (00-overview.md §Interaction conventions): a
   destructive double-press prints its "press again" footer notice on the first
   press and fires on the second within the window. At most one is armed —
   arming one replaces the rest, and any composer activity disarms. *)
type armed = Quit_armed | Clear_armed | Interrupt_armed

(* The completion axis (03-ia-screens-overlays.md §The three forms): the list
   growing from the composer, rendered above its top rule. At most one is up;
   the draft keeps the keyboard and its text IS the filter (§The filter law) —
   the shell only routes the list keys ({!Composer.List_key}) and intercepts ↵
   while one is open. Ctrl+r borrows the whole draft as its query, so the
   search carries the draft it displaced, restored on esc. *)
type completion =
  | No_completion
  | Commands of Palette.t
  | Mention of Mention.t
  | History_search of {
      search : History.Search.t;
      saved : Draft.History_entry.t;
    }

(* The composer borrow (doc/plans/tui-next-surfaces.md §The composer borrow): a
   dialog's deny/adjust/custom-answer option returns the user to the real
   composer with a scoped [placeholder]; submit resolves the pending dialog
   instead of starting a turn, and esc restores [saved_draft] and re-opens the
   option list. The dialog itself is still in [surface] while borrowed. *)
type borrow =
  | Free
  | For_answer of { placeholder : string; saved_draft : string }

type t = {
  snapshot : Snapshot.t;
  brief : Home.Brief.t option;
  notice : string list;
  composer : Composer.t;
  help : bool;
  motion : Home.Motion.t;
  frame_accum : float;
  flash : string option;
  phase : phase;
  surface : surface;
  completion : completion;
  (* Prompt history as loaded/appended on disk, newest first, with the session
     the runtime attributed the load to — the ctrl+r search ranks the current
     session's records first (History.Search.make). The composer's arrow-walk
     copy is fed separately via [Composer.with_history]. *)
  prompt_history : History.Entry.t list;
  session_id : Spice_session.Id.t option;
  (* Whether the attached session's document exists on disk. [session_id] alone
     cannot say: on the fresh path it is the pre-minted seed adopted from
     {!Prompt_history_loaded}, and the document is only written when the first
     turn attaches. Live events flow exclusively from an attached session (a
     first turn, or a resume/fork replay), so the first one — or the
     {!Thread_runs_loaded} a session entry dispatches — proves the document.
     Session-mutating commands ([/fork]) gate on it. Never reset: entry into
     another session re-attaches, and its replay re-proves. *)
  attached : bool;
  (* Prompts submitted while a turn is in flight, oldest first; drained one per
     settle (finished or interrupted) and editable via [↑] on an empty composer
     (01-transcript.md §The status strip, revised 2026-07-08). *)
  queued : string list;
  (* The declared turn mode (10-commands.md §Mode switches): the composer frame
     wears it; /plan and /build set it for the next turn. *)
  mode : Spice_protocol.Mode.t;
  (* The approval posture the shift+tab pill reads (04-header-footer.md §4). A
     TUI-local gate this iteration — it reaches the host when the dialogs wave
     lands auto-answering (doc/plans/tui-next-composer.md §Host seams). *)
  posture : Footer.posture;
  (* Whether the composer is borrowed to collect a dialog's feedback answer
     ([For_answer] while a deny/adjust/custom-answer composer is open). *)
  borrow : borrow;
  (* The one in-flight user shell command ([Some] while running): its header
     renders pinned above the composer, its result settles as a transcript
     block, and further shell submits are refused meanwhile. *)
  shell : string option;
  cols : int;
  rows : int;
  (* Whether the wide-terminal side panel region is open
     (doc/plans/tui-next-side-panel.md): a pure function of width with the
     110/108 hysteresis, recomputed in [Resized] via [Pane.presence]. Stored, not
     re-derived, so the dead band has its previous value; the pane's content
     varies with the turn, this bool does not. *)
  pane_open : bool;
  armed : armed option;
  (* Whether reasoning renders, flipped by /thinking (01-transcript.md
     §Reasoning). A session-scoped preference, not a per-turn contract: it
     survives across turns, so it lives on the shell model rather than the chat
     record. The reducer honors it at APPEND time — [Turn.apply] never adds the
     reasoning block and [Turn.tail] omits the ticker while off — so it governs
     only blocks added while off; reasoning already in the document stays put
     (the document is history). While off the host still records reasoning in
     the session; only the on-screen rendering stops. *)
  show_reasoning : bool;
  (* The child subagent runs of the attached session (doc/plans/tui-next-threads.md
     §1): the ledger records the registry pushes through the [Thread_*] events,
     upserted by child id. They feed the footer's [* N agents] count and the
     below-footer switcher strip. Empty until the first spawn, refilled from
     artifacts on a resume ([Thread_runs_loaded]). *)
  thread_runs : Spice_protocol.Subagent_run.t list;
  (* The threads-strip focus (doc/plans/tui-next-threads.md §2.2, §2.6): [None] is
     the unfocused 3-row glance the composer owns; [Some i] is the focused browse
     stepped into by [↓] on an empty draft, [i] the selected row (0 = [main]).
     While focused, [↑/↓] walk the whole windowed tree and [esc]/[←] release;
     [↵] (or a click) drills into a SETTLED child read-only (§2.3 phase a), the
     hint gated on the selected row's openability. Cleared when the runs reload
     past its range. *)
  strip_focus : int option;
  (* The switcher row the mouse is over (fix 5), the absolute row index in the
     rendered list, or [None] when the pointer is elsewhere. Drives the hover
     highlight only — selection ([strip_focus]) and drill-in are the click's job.
     Purely cosmetic, so it is never gated on focus or phase. *)
  strip_hover : int option;
  (* A drilled-in thread, read-only (doc/plans/tui-next-threads.md §2.3, §6 phase
     5a): [Some (run, chat)] re-points the shell at child [run]'s replayed
     conversation — its persisted document folded through the same turn reducer as
     a resume, rendered under a thread banner with a way-home footer, [esc]
     returning to [None] (the parent chat). Only settled children drill in for now
     (a live child needs the [Jobs.observe] snapshot, §3.2 — deferred); composing
     into a thread is likewise deferred, so the view is read-only. Mutually
     exclusive with [strip_focus] — engaging the browse clears a drill and vice
     versa. *)
  drill : (Spice_session.Id.t * chat) option;
  (* The monotonic id auth flows tag async attempts with, so a superseded
     browser / device attempt's late challenge / settle is dropped: a re-entered
     flow reuses the same stage, which "surface still open?" cannot tell apart,
     and these flows carry no durable host id. Shell-owned and minted here so the
     next surface needing ephemeral request correlation reuses it; dialogs
     deliberately do NOT — they correlate by the durable ids in
     [Spice_protocol.Pending.t] (doc/plans/tui-next-auth.md §Appendix Q5). *)
  next_request : int;
  (* Whether the process was launched onto the review screen ([spice review]):
     closing that screen quits instead of stranding the user on a home stage
     they never asked for. Cleared by [Task_spice], which deliberately enters
     the chat. *)
  review_launch : bool;
}

type settled =
  | Finished
  | Waiting of Spice_protocol.Pending.t option
  | Failed of { message : string }

type msg =
  | Composer_msg of Composer.msg
  | Brief_tick
  | Brief_loaded of Home.Brief.t
  | Frame_tick of float
  | Flash_expired
  | Resized of { cols : int; rows : int }
  | Ctrl_c
  | Armed_expired
  | Live_event of { event : Spice_protocol.Event.t; now : float }
  | Settled of { result : settled; now : float }
  | Turn_tick
  (* Live Dune health during chat (the prelude brief tick that feeds the footer
     stops at the drop). [Health_tick] fires the poll; [Health_loaded] carries
     the verdict, the failing file when Dune's diagnostics name one, and the wall
     clock the poll completed — the transition law reads it for the outage. *)
  | Health_tick
  | Health_loaded of {
      health : Spice_ocaml_dune.Rpc.Instance.Health.t;
      file : string option;
      now : float;
    }
  | Toggle_expanded
  | Escape
  | Session_forked of { parent_title : string }
  | Compaction_failed of string
  | Sessions_loaded of Sessions_panel.row list
  | Sessions_load_failed of string
  | Panel_msg of Sessions_panel.msg
  | Screen_msg of Sessions_screen.msg
  | Screen_loaded of Sessions_screen.row list
  | Screen_failed of string
  | Settings_msg of Settings_screen.msg
  | Settings_loaded of Settings_screen.facts
  | Settings_load_failed of string
  (* A key routed to the review screen, and the runtime's async folds for its
     self-contained effect protocol (doc/plans/tui-next-review.md §3.3). *)
  | Review_msg of Spice_tui_review.msg
  | Model_panel_msg of Model_panel.msg
  | Model_facts_loaded of Model_panel.facts
  | Model_facts_failed of string
  | Model_switched of string
  | Snapshot_refreshed of Snapshot.t
  | Dir_loaded of {
      dir : Spice_path.Rel.t;
      result : (Mention.item list, string) result;
    }
  | Prompt_history_loaded of {
      session : Spice_session.Id.t;
      entries : History.Entry.t list;
    }
  | Prompt_history_appended of History.Entry.t
  | Ctrl_r
  | Shift_tab
  (* A key routed to an open decision dialog while it owns the keyboard, and the
     esc that steps back from a borrowed feedback composer to the dialog. *)
  | Dialog_key of Matrix.Input.Key.event
  | Cancel_borrow
  | Shell_finished of Tool_block.t
  (* Transcript scroll (01-transcript.md §Seam replay, scroll, spacing): the
     scrollport reports its settled offset, PageUp/Down page, and the wheel —
     routed from anywhere in the app — nudges the offset a few lines. *)
  | Transcript_scrolled of int
  | Transcript_paged of [ `Up | `Down ]
  | Transcript_wheeled of [ `Up | `Down ] * int
  (* Subagent-thread registry events, dispatched by the runtime's [Jobs.subscribe]
     adapter (doc/plans/tui-next-threads.md §1, §4.3). [Thread_runs_loaded] seeds
     the whole set from the artifact ledger at session open / resume; the rest
     upsert one run's latest record by child id. [Thread_started] is the mint,
     [Thread_settled] the terminal transition (which also writes the settled
     notice to the parent transcript), [Thread_asked] a [message_parent] ask
     (which writes the gray relay notice). Escalation ([Blocked]), resume, and
     the per-event progress ticker land with the surfaces that render them. *)
  | Thread_runs_loaded of {
      session : Spice_session.Id.t;
      runs : Spice_protocol.Subagent_run.t list;
    }
  | Thread_started of Spice_protocol.Subagent_run.t
  | Thread_asked of {
      run : Spice_protocol.Subagent_run.t;
      message : string;
      now : float;
    }
  | Thread_settled of { run : Spice_protocol.Subagent_run.t; now : float }
  (* Read-only drill-in (doc/plans/tui-next-threads.md §2.3, §6 phase 5a).
     [Thread_strip_clicked] is a mouse click on switcher row [i] (absolute index
     in the row list) — it selects the row and, if it is a settled child, drills
     in (the same action as [↵]); [Thread_strip_hovered] tracks the mouse for the
     row highlight. Drill-in asks the runtime to load the child's document
     ([Load_thread_document]); [Thread_document_loaded] carries the child's durable
     events back, folded into the drilled [chat]; [Thread_drill_failed] reports a
     load error as a flash. The [esc] home is the [Escape] rung, not a message. *)
  | Thread_strip_clicked of int
  | Thread_strip_hovered of int option
  | Thread_document_loaded of {
      run : Spice_session.Id.t;
      events : Spice_protocol.Event.t list;
      now : float;
    }
  | Thread_drill_failed of { run : Spice_session.Id.t; message : string }
  (* Provider login / logout (09-auth.md, doc/plans/tui-next-auth.md). A key
     routed to the auth panel ([Auth_panel_msg]); the runtime's async folds
     (providers loaded, a protocol challenge, the browser opened, the settled
     record); the one-second flow tick; and a paste routed to the masked buffer
     while the api-key stage owns the region. Each async fold is guarded by the
     request id (or "surface still open?") and dropped when stale. *)
  | Auth_panel_msg of Auth_panel.msg
  | Auth_providers_loaded of (Auth_panel.provider_entry list, string) result
  | Auth_challenge of { request : int; challenge : Auth_panel.challenge }
  | Auth_browser_opened of { request : int }
  | Auth_browser_open_failed of { request : int }
  | Auth_settled of { request : int; record : Auth_panel.record }
  | Auth_tick
  | Auth_paste of string

type command =
  | Quit
  | Reload_brief
  | Reload_health
  | Start_turn of string
  | Interrupt
  | Interrupt_force
  | Load_sessions
  | Load_screen_sessions
  | Resume_session of Spice_session.Id.t
  | Fork_session of Spice_session.Id.t
  | Clear_session
  | Compact_session of Spice_session.Id.t
  (* Load a settled child's persisted document for a read-only drill-in
     (doc/plans/tui-next-threads.md §6 phase 5a): the runtime replays its durable
     events back as [Thread_document_loaded], folded into the drilled chat. *)
  | Load_thread_document of Spice_session.Id.t
  | Rename_session of { id : Spice_session.Id.t; title : string }
  | Delete_session of Spice_session.Id.t
  | Load_settings
  | Write_config of { field : string; value : string option }
  | Toggle_skill of string
  | Load_model_panel
  | Switch_model of {
      selector : string;
      effort : Spice_llm.Request.Options.Reasoning_effort.t option;
    }
  | Copy_text of string
  | Load_dir of Spice_path.Rel.t
  | Load_prompt_history
  | Append_prompt_history of Draft.History_entry.t
  | Set_mode of Spice_protocol.Mode.t
  (* Resolve a blocked decision dialog by submitting its continuation command to
     the attached session (doc/plans/tui-next-dialog-seam.md). *)
  | Reply_permission of {
      permission : Spice_session.Permission.Id.t;
      answer : Spice_permission.Policy.Review.answer;
      message : string option;
    }
  | Answer_tool of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      text : string;
    }
  | Resolve_plan of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      decision : Spice_protocol.Plan.Decision.t;
    }
  | Run_shell of string
  | Interrupt_shell
  (* Run one review-screen effect. The review sub-library owns its whole async
     protocol (snapshot load, persistence, worktree watch, debounced reload,
     source mutation); the shell forwards each effect blind and the runtime
     interprets it, dispatching completions back as {!Review_msg}
     (doc/plans/tui-next-review.md §3.3, Appendix A). *)
  | Review_command of Spice_tui_review.Effect.t
  (* Provider login / logout (09-auth.md). [Load_auth_providers] asks the
     runtime for the passive provider facts the pickers render. The [Auth_*]
     flow commands compose [Spice_host_builtin.Login]; each carries the [request]
     the runtime dispatches its result back under. The raw api-key crosses only
     as [Auth_save_api_key]'s payload — validated in the runtime, never rendered,
     never in the draft or history (09-auth §10). *)
  | Load_auth_providers
  | Auth_save_api_key of {
      request : int;
      provider : Spice_llm.Provider.t;
      method_id : string;
      key : string;
    }
  | Auth_browser_login of {
      request : int;
      provider : Spice_llm.Provider.t;
      method_id : string;
    }
  | Auth_device_login of {
      request : int;
      provider : Spice_llm.Provider.t;
      method_id : string;
    }
  | Auth_logout of { request : int; provider : Spice_llm.Provider.t }
  | Auth_cancel of { request : int }
  | Auth_copy of string
  | Auth_open_url of { request : int; url : Uri.t }

let brief_loaded brief = Brief_loaded brief
let shell_finished block = Shell_finished block
let dir_loaded ~dir result = Dir_loaded { dir; result }

let prompt_history_loaded ~session entries =
  Prompt_history_loaded { session; entries }

let prompt_history_appended entry = Prompt_history_appended entry
let live_event ~now event = Live_event { event; now }
let settled ~now result = Settled { result; now }
let health_loaded ~now ~file health = Health_loaded { health; file; now }
let sessions_loaded rows = Sessions_loaded rows
let session_forked ~parent_title = Session_forked { parent_title }
let compaction_failed message = Compaction_failed message
let sessions_load_failed message = Sessions_load_failed message
let screen_loaded rows = Screen_loaded rows
let screen_failed message = Screen_failed message
let settings_loaded facts = Settings_loaded facts
let settings_load_failed message = Settings_load_failed message
let model_facts_loaded facts = Model_facts_loaded facts
let model_facts_failed message = Model_facts_failed message
let model_switched notice = Model_switched notice
let snapshot_refreshed snapshot = Snapshot_refreshed snapshot
let thread_runs_loaded ~session runs = Thread_runs_loaded { session; runs }
let thread_started run = Thread_started run
let thread_asked ~now ~message run = Thread_asked { run; message; now }
let thread_settled ~now run = Thread_settled { run; now }

let thread_document_loaded ~run ~now events =
  Thread_document_loaded { run; events; now }

let thread_drill_failed ~run message = Thread_drill_failed { run; message }
let auth_providers_loaded result = Auth_providers_loaded result
let auth_challenge ~request challenge = Auth_challenge { request; challenge }
let auth_browser_opened ~request = Auth_browser_opened { request }
let auth_browser_open_failed ~request = Auth_browser_open_failed { request }
let auth_settled ~request record = Auth_settled { request; record }
let review_msg m = Review_msg m
let ctrl_c_exit_notice = "Press Ctrl+C again to exit"
let esc_clear_notice = "Esc again to clear"
let interrupt_notice = "Press Esc again to interrupt"
let shell_wait_flash = "shell commands wait for the turn to finish"
let shell_busy_flash = "a shell command is already running"
let shell_empty_flash = "shell command must not be empty"

(* The subscription clock carries no absolute time (Mosaic.Sub), so the turn tick
   advances the modeled [now] by a fixed step at its own cadence; runtime-stamped
   events reset it to the true time, bounding any drift. It is also the spinner's
   frame cadence — one advance per tick. *)
let turn_tick_interval = 0.1

(* The one-second cadence a browser / device auth flow advances its elapsed
   counter and device countdown on (09-auth §6, §7); only the spinner cell
   animates, so the copyable url / code rows never reflow. *)
let auth_tick_interval = 1.0

(* The pour advances one frame per this many seconds. The frame timer is driven
   by {!Mosaic.Sub.on_tick} and each tick's delta is capped at one interval, so a
   stall (a blocking first brief load) cannot bank time and burn several frames
   at once when the render loop resumes — the pour always plays every frame
   (08-brand.md §Motion). *)
let frame_interval = 0.13

(* The three recurring timers must use distinct intervals. Mosaic preserves an
   [every]-sub's accumulated elapsed time across re-collection by matching on
   interval alone (mosaic.ml [update_subscriptions]); two live [every]-subs
   sharing an interval swap clocks, so a one-shot (quit notice, flash) armed
   while the brief tick is near its boundary would inherit that near-elapsed time
   and fire immediately — the notice would flash and vanish. Distinct intervals
   keep each timer's clock its own. Upstream: mosaic should key elapsed on a
   stable subscription id, not the interval (see the mosaic friction report). *)
let brief_interval = 2.0

(* The chat-phase Dune health poll's own interval, distinct from every timer it
   can run beside (the turn tick, the armed expiries, the flash) for the same
   elapsed-keying reason. It never coexists with the prelude brief tick — health
   is polled only in chat, the brief only in the prelude — but stays distinct
   from [brief_interval] too so the two never share a clock across the drop. *)
let health_interval = 2.15

(* Each armed kind keeps its own expiry interval for the same reason: a
   same-frame swap of one armed sub for another sharing an interval would
   inherit the outgoing timer's elapsed and fire early. The differences are
   imperceptible on screen. *)
let quit_notice_timeout = 3.0
let clear_notice_timeout = 3.05
let interrupt_notice_timeout = 3.1
let flash_timeout = 4.0

(* The standing welcome notice (12-home.md §Notice slot): the one sanctioned
   exception to the no-greetings voice rule (08-brand §Voice) — these are spice's
   first users and the brand thanks them. Two lines: a lead and a muted caveat.
   Held on the model as the notice content so a later host announcement feed
   replaces it without reshaping the view; the home renders the [▎] bar and the
   committed line styling. *)
let welcome_notice =
  [
    "welcome — and thanks for trying spice this early.";
    "it's experimental: sessions and config may change without migration.";
  ]

let init_model ~snapshot ~reduced_motion =
  {
    snapshot;
    brief = None;
    notice = welcome_notice;
    composer = Composer.init ();
    help = false;
    motion = Home.Motion.init ~reduced:reduced_motion;
    frame_accum = 0.;
    flash = None;
    phase = Prelude;
    surface = Conversing;
    completion = No_completion;
    prompt_history = [];
    session_id = None;
    queued = [];
    mode = Spice_protocol.Mode.default;
    posture = Footer.Ask;
    borrow = Free;
    shell = None;
    cols = 80;
    rows = 24;
    pane_open = false;
    armed = None;
    show_reasoning = true;
    thread_runs = [];
    strip_focus = None;
    strip_hover = None;
    drill = None;
    next_request = 0;
    review_launch = false;
    attached = false;
  }

let completion_open t =
  match t.completion with
  | No_completion -> false
  | Commands _ | Mention _ | History_search _ -> true

let empty_chat =
  {
    transcript = Transcript.empty;
    turn = Turn.idle;
    board = None;
    expanded = false;
    spinner = 0;
    now = 0.;
    scroll = 0;
    reveal = None;
    health = Spice_ocaml_dune.Rpc.Instance.Health.Disconnected;
    build = Build_unknown;
    broken_since = None;
  }

(* Fold one live event into the chat: the reducer produces the settled blocks to
   append and the new tail state. *)
let apply_event ~show_reasoning ~now event chat =
  (* Rebase a pending turn's clock into this event's wall-clock domain before
     folding: the optimistic pending timer runs in the drop-relative modeled
     [chat.now] (from 0), and the first runtime-stamped event reseeds [now] to
     the wall clock, so shifting by the same delta carries the elapsed across
     Turn_started instead of restarting it. A no-op once the turn is running. *)
  let turn = Turn.rebase_pending ~by:(now -. chat.now) chat.turn in
  let turn, blocks = Turn.apply ~now ~show_reasoning event turn in
  let transcript = List.fold_left Transcript.append chat.transcript blocks in
  (* Retain the latest board across settle (02-tools.md §Todo block, revised
     2026-07-08): [Turn.todo_board] clears when the turn settles, so capture each
     board it reports and hold the last, dropping it only on a fresh chat. *)
  let board =
    match Turn.todo_board turn with Some _ as b -> b | None -> chat.board
  in
  { chat with turn; transcript; now; board }

(* An outage length for the heal notice's fact (01-transcript.md §Data notices,
   dune): seconds while short, then whole minutes and hours — a coarse "how long
   was it broken", not a stopwatch. *)
let format_outage secs =
  let s = max 0 (int_of_float (Float.round secs)) in
  if s < 60 then Printf.sprintf "%ds" s
  else if s < 3600 then Printf.sprintf "%dm" (s / 60)
  else Printf.sprintf "%dh" (s / 3600)

(* Append a [dune]-source data notice; the transcript's coalescing law folds a
   run of these into one row (transcript.ml §append). *)
let dune_notice ~facts ~atom ~disclosable chat =
  {
    chat with
    transcript =
      Transcript.append chat.transcript
        (Transcript.Notice
           (Notice.Data { source = "dune"; facts; atom; disclosable }));
  }

(* The broken record: [build broken], the red error count, and the failing file
   when Dune's diagnostics name one, disclosing to the diagnostics rows behind
   [/diagnostics] (01-transcript.md §Data notices). *)
let broken_notice ~count ~file chat =
  let facts =
    Notice.Fact "build broken" :: Notice.Errors count
    :: (match file with Some f -> [ Notice.Fact f ] | None -> [])
  in
  dune_notice ~facts ~atom:(Some "/diagnostics") ~disclosable:true chat

(* The heal record: [build clean] and the outage length it recovered from; no
   atom, nothing to disclose. Omits the outage fact only when the chat opened
   already broken and healed before any live poll could stamp the start. *)
let clean_notice ~now ~broken_since chat =
  let outage =
    match broken_since with
    | Some since -> [ Notice.Fact (format_outage (now -. since) ^ " broken") ]
    | None -> []
  in
  dune_notice
    ~facts:(Notice.Fact "build clean" :: outage)
    ~atom:None ~disclosable:false chat

(* Seed a fresh chat's Dune baseline from the home brief at the drop: the footer
   reads [health] immediately (no blank across the jump) and the transition law
   starts from the verdict the home last showed, so the first live break or heal
   after the drop is a real transition rather than a swallowed first verdict.
   Entering already broken carries no [broken_since] — the outage start is
   unknown until a live poll stamps it ([apply_health]). *)
let seed_health ~brief chat =
  let health =
    match brief with
    | Some b -> b.Home.Brief.dune
    | None -> Spice_ocaml_dune.Rpc.Instance.Health.Disconnected
  in
  let build =
    match health with
    | Spice_ocaml_dune.Rpc.Instance.Health.Clean -> Build_clean
    | Spice_ocaml_dune.Rpc.Instance.Health.Failing n -> Build_broken n
    | Spice_ocaml_dune.Rpc.Instance.Health.Disconnected
    | Spice_ocaml_dune.Rpc.Instance.Health.Unknown ->
        Build_unknown
  in
  { chat with health; build; broken_since = None }

(* Fold one Dune health poll into the chat (01-transcript.md §Data notices,
   dune). [health] always refreshes the footer's live value; a clean↔broken
   change of the DEFINITE baseline additionally records a data notice — broken
   with the error count and failing file, clean with the outage length. A
   Disconnected or Unknown poll refreshes only the footer: it is no verdict, so
   it neither fires nor resets the baseline, and the build state cannot flap when
   a turn spawns its watch and the RPC connection blips. While already broken
   only a count CHANGE re-fires; the append law coalesces the consecutive rows
   into one, and a still-sinceless outage clock (opened broken) is stamped on the
   first live confirmation so a later heal has a real length. *)
let apply_health ~now ~health ~file chat =
  let chat = { chat with health } in
  match health with
  | Spice_ocaml_dune.Rpc.Instance.Health.Disconnected
  | Spice_ocaml_dune.Rpc.Instance.Health.Unknown ->
      chat
  | Spice_ocaml_dune.Rpc.Instance.Health.Failing count -> (
      let broken_since =
        match chat.broken_since with None -> Some now | since -> since
      in
      match chat.build with
      | Build_broken prev when prev = count -> { chat with broken_since }
      | Build_broken _ | Build_clean | Build_unknown ->
          broken_notice ~count ~file
            { chat with build = Build_broken count; broken_since })
  | Spice_ocaml_dune.Rpc.Instance.Health.Clean -> (
      match chat.build with
      | Build_broken _ ->
          clean_notice ~now ~broken_since:chat.broken_since
            { chat with build = Build_clean; broken_since = None }
      | Build_clean | Build_unknown ->
          { chat with build = Build_clean; broken_since = None })

(* Start a turn from a submitted prompt: the drop from the prelude, or a
   mid-chat submit (the host queues one made while a turn is in flight). *)
let start_turn value t =
  match t.phase with
  | Prelude ->
      (* The drop: the one sanctioned layout jump (12-home.md §The drop). Freeze
         motion and start the turn. The turn is marked requested so the prompt
         echo and working line show this frame, ahead of the host's
         Turn_started; [empty_chat.now] (0) is the drop-relative clock origin
         the pending timer counts from. The banner record heads the document as
         its first block, so the chat is never bannerless and the record scrolls
         away with the conversation (04-header-footer.md §Purpose). *)
      let transcript =
        Transcript.append Transcript.empty (Transcript.Banner t.snapshot)
      in
      let turn =
        Turn.request ~now:empty_chat.now ~prompt:value empty_chat.turn
      in
      ( {
          t with
          phase =
            Chat
              (seed_health ~brief:t.brief { empty_chat with transcript; turn });
          motion = Home.Motion.freeze t.motion;
        },
        [ Start_turn value ] )
  | Chat chat ->
      (* A submit while a turn is in flight queues CLIENT-side (03-composer.md
         §Queued prompts): the draft joins [queued], stays editable in spirit
         (cancellable, discarded on error), and drains one per turn boundary —
         never handed to the host early, so the queue remains the user's.
         Otherwise the prompt echoes optimistically, exactly as the drop
         does. *)
      if Turn.in_flight chat.turn || t.shell <> None then
        ({ t with queued = t.queued @ [ value ] }, [])
      else
        let turn = Turn.request ~now:chat.now ~prompt:value chat.turn in
        ({ t with phase = Chat { chat with turn } }, [ Start_turn value ])

(* Start a user shell command (03-composer.md §Shell mode): echo the [!command]
   as a durable user block, pin the running header above the composer, and hand
   the command to the executor. From the prelude this is the drop's layout jump
   without a turn — the banner heads the document and the shell block follows. *)
let start_shell command t =
  let echo transcript =
    Transcript.append transcript (Transcript.User ("!" ^ command))
  in
  let t = { t with shell = Some command } in
  match t.phase with
  | Prelude ->
      let transcript =
        echo (Transcript.append Transcript.empty (Transcript.Banner t.snapshot))
      in
      ( {
          t with
          phase =
            Chat (seed_health ~brief:t.brief { empty_chat with transcript });
          motion = Home.Motion.freeze t.motion;
        },
        [ Run_shell command ] )
  | Chat chat ->
      ( { t with phase = Chat { chat with transcript = echo chat.transcript } },
        [ Run_shell command ] )

(* Enter a session's chat by resume or fork (12-home.md §The drop, "resumes skip
   the home"): swap to a banner-headed empty transcript, close any surface, and
   freeze the lockup, then ask the runtime to replay the session's durable events
   — they arrive as {!Live_event}s and rebuild the transcript through the same
   reducer the live turn uses. Unlike the drop this starts no turn; the
   transcript fills from the replay. [command] is the runtime intent
   ({!Resume_session} or {!Fork_session}). *)
let enter_session command t =
  let transcript =
    Transcript.append Transcript.empty (Transcript.Banner t.snapshot)
  in
  ( {
      t with
      phase = Chat (seed_health ~brief:t.brief { empty_chat with transcript });
      surface = Conversing;
      motion = Home.Motion.freeze t.motion;
    },
    [ command ] )

(* Replace the draft wholesale (a palette completion or insertion, or the
   [--draft] startup seed), cursor at end: the text-only history-entry
   round-trip is the composer's one out-of-band setter. *)
let set_draft text t =
  let composer, _ =
    Composer.update
      (Composer.Restore_history (Draft.history_entry (Draft.of_text text)))
      t.composer
  in
  { t with composer }

(* Open the review screen over the worktree diff (11-review.md): the one
   opener behind the [/review] dispatch and the [spice review] launch, so the
   two cannot drift. [base_spec] is the base target ([/review main]); absent,
   the loader defaults to [HEAD]. The sub-library's initial effect (a snapshot
   load) is forwarded to the runtime as {!Review_command}. *)
let open_review ?base_spec t =
  let review, effects = Spice_tui_review.create ?base_spec () in
  ( { t with surface = Screen (Review review) },
    List.map (fun e -> Review_command e) effects )

let init ~(startup : startup) ~snapshot ~reduced_motion =
  let model =
    { (init_model ~snapshot ~reduced_motion) with mode = startup_mode startup }
  in
  let model, commands =
    match (startup.session, startup.input) with
    | None, Empty -> (model, [ Reload_brief ])
    | None, Draft text -> (set_draft text model, [ Reload_brief ])
    | None, Submit prompt ->
        (* [-p]/[--prompt]: the first turn starts before the first frame — the
           drop happens at once, so the process never shows the home stage and
           the prelude [Reload_brief] goes with it. *)
        start_turn prompt model
    | Some id, (Empty | Submit _ | Draft _) ->
        (* [spice resume <id>]: launch straight into the session's chat through
           the very transition an in-app resume takes, so both are one path by
           construction. The prelude brief tick is dropped (the drop stops it
           anyway); the replayed events rebuild the transcript. A [Submit] into
           a resumed session would race that replay — the CLI rejects the
           combination, and this shell degrades it to the draft seat. *)
        let model, commands = enter_session (Resume_session id) model in
        let model =
          match startup.input with
          | Empty -> model
          | Draft text | Submit text -> set_draft text model
        in
        (model, commands)
  in
  let model, commands =
    match startup.launch with
    | Launch_chat -> (model, commands)
    | Launch_review { base_spec } ->
        (* [spice review [BASE]]: open the review screen at launch through the
           same opener the [/review] dispatch uses; [review_launch] makes its
           close quit the process rather than land on an unasked-for home
           stage. *)
        let model, effects =
          open_review ?base_spec { model with review_launch = true }
        in
        (model, commands @ effects)
  in
  (model, commands @ [ Load_prompt_history ])

(* Open the model panel over the current surface and load its facts; [return]
   records where esc restores to — the composer for [/model], the settings screen
   for its managed Model row (doc/plans/tui-next-surfaces.md §Sequencing 5). *)
let open_model_panel ~return t =
  ( {
      t with
      surface = Panel (Model { panel_state = Model_panel.loading; return });
    },
    [ Load_model_panel ] )

(* Restore the surface the model panel was opened from once it closes or resolves
   (esc, a pick, or a locked-row flash). *)
let restore_model_return return t =
  match return with
  | To_chat -> { t with surface = Conversing }
  | To_settings screen -> { t with surface = Screen (Settings screen) }

(* Open the provider login / logout drill-down and ask the runtime for the
   passive provider facts the pickers render (09-auth.md). [provider]
   pre-selects one ([/login openai]), skipping the provider picker once the
   entries load. The draft is untouched — esc from the provider picker restores
   the composer. *)
let open_auth ~mode ?provider t =
  ( { t with surface = Panel (Auth (Auth_panel.loading ~mode ?provider ())) },
    [ Load_auth_providers ] )

(* Dispatch a catalog command by its fate (10-commands.md): the shell's one
   command-routing match, shared by a typed [/command] submit and a palette ↵.
   [argument] is the trailing text of an argument-taking command ([/login
   openai], [/rename …]); only the arms that consume it read it, the rest ignore
   it. Idle-only commands wait for the turn to finish; unwired fates flash an
   honest placeholder until their wave lands. *)
let dispatch_command ?(argument = None) command t =
  let turn_in_flight =
    match t.phase with
    | Chat chat -> Turn.in_flight chat.turn
    | Prelude -> false
  in
  match Command.availability command with
  | Command.Idle_only when turn_in_flight ->
      ( {
          t with
          flash =
            Some
              (Command.slash command ^ " is available after the turn finishes");
        },
        [] )
  | Command.Idle_only | Command.Anytime -> (
      match Command.fate command with
      | Command.Open_sessions ->
          ( { t with surface = Panel (Session_switch Sessions_panel.loading) },
            [ Load_sessions ] )
      | Command.Open_model -> open_model_panel ~return:To_chat t
      | Command.Open_login ->
          open_auth ~mode:Auth_panel.Login ?provider:argument t
      | Command.Open_logout ->
          open_auth ~mode:Auth_panel.Logout ?provider:argument t
      | Command.Quit -> (t, [ Quit ])
      | Command.Switch_mode mode -> (
          (* Set the next-turn contract and record the switch: the muted echo,
             then the event line naming the mode with its glyph
             (10-commands.md §Mode switches). The composer frame wears the mode
             from this frame on; on the home stage the frame chip is the only
             record — there is no document to echo into yet. *)
          let event =
            match mode with
            | Spice_protocol.Mode.Plan ->
                Theme.mode_plan ^ " plan mode on — spice proposes, you approve"
            | Spice_protocol.Mode.Review ->
                Theme.mode_review ^ " review mode on"
            | Spice_protocol.Mode.Build -> "build mode on"
          in
          let notices =
            [
              Transcript.Notice
                (Notice.Echo { command = Command.slash command; result = None });
              Transcript.Notice (Notice.Event event);
            ]
          in
          let t = { t with mode } in
          match t.phase with
          | Chat chat ->
              let transcript =
                List.fold_left Transcript.append chat.transcript notices
              in
              ( { t with phase = Chat { chat with transcript } },
                [ Set_mode mode ] )
          | Prelude -> (t, [ Set_mode mode ]))
      | Command.Toggle_thinking -> (
          (* Flip the session-scoped reasoning preference and record it: the
             muted [❯ /thinking] echo, then the event-class outcome
             (01-transcript.md §Notices). The flip is honored at append time, so
             this turn's not-yet-added reasoning obeys it while the document's
             history stays put. On the home stage there is no document to echo
             into, so the flip is silent until the first turn. *)
          let show_reasoning = not t.show_reasoning in
          let t = { t with show_reasoning } in
          let outcome =
            if show_reasoning then
              "thinking shown — reasoning returns to the transcript"
            else
              "thinking hidden — reasoning stays in the session, not on screen"
          in
          let notices =
            [
              Transcript.Notice
                (Notice.Echo { command = Command.slash command; result = None });
              Transcript.Notice (Notice.Event outcome);
            ]
          in
          match t.phase with
          | Chat chat ->
              let transcript =
                List.fold_left Transcript.append chat.transcript notices
              in
              ({ t with phase = Chat { chat with transcript } }, [])
          | Prelude -> (t, []))
      | Command.Open_settings tab ->
          (* Open the settings screen on the requested tab and load its facts;
             the runtime assembles them from the host and dispatches
             {!Settings_loaded} (doc/plans/tui-next-surfaces.md §Sequencing 4). *)
          let tab =
            match tab with
            | Command.Config -> Settings_screen.Config
            | Command.Status -> Settings_screen.Status
            | Command.Usage -> Settings_screen.Usage
            | Command.Skills -> Settings_screen.Skills
          in
          ( { t with surface = Screen (Settings (Settings_screen.loading ~tab)) },
            [ Load_settings ] )
      | Command.Open_review -> open_review ?base_spec:argument t
      | Command.Compact_session -> (
          (* Summarize the conversation so far to free context: the echo lands
             now, the runtime runs the standalone compaction over the attached
             document (serialized with any drain through Live.write), and the
             narration arrives as live events — the Compacting verb, then the
             durable compaction's [compacted] seam. The document's history
             stays on screen: compaction changes what the MODEL sees next turn,
             not what happened (01-transcript.md — the document is history).
             The [attached] gate mirrors /fork. *)
          match t.session_id with
          | Some id when t.attached ->
              let t =
                match t.phase with
                | Chat chat ->
                    let transcript =
                      Transcript.append chat.transcript
                        (Transcript.Notice
                           (Notice.Echo
                              { command = Command.slash command; result = None }))
                    in
                    { t with phase = Chat { chat with transcript } }
                | Prelude -> t
              in
              (t, [ Compact_session id ])
          | Some _ | None ->
              ({ t with flash = Some "no session to compact" }, []))
      | Command.Clear_session ->
          (* Start over on a fresh, empty chat — the chat layout, never a return
             to the home stage (its composer moves exactly once per process,
             12-home.md §The drop) — re-bannered, with the echo and settle copy
             in the fresh transcript; the previous session stays on disk,
             resumable from /sessions (10-commands.md §/clear). The session
             facts reset with it: nothing is attached until the next submit
             creates the new document. *)
          let transcript =
            List.fold_left Transcript.append
              (Transcript.append Transcript.empty (Transcript.Banner t.snapshot))
              [
                Transcript.Notice
                  (Notice.Echo
                     { command = Command.slash command; result = None });
                Transcript.Notice
                  (Notice.Event
                     "cleared the conversation · previous saved, /sessions to \
                      resume");
              ]
          in
          ( {
              t with
              phase =
                Chat (seed_health ~brief:t.brief { empty_chat with transcript });
              surface = Conversing;
              motion = Home.Motion.freeze t.motion;
              session_id = None;
              attached = false;
              queued = [];
              thread_runs = [];
              strip_focus = None;
              strip_hover = None;
              drill = None;
            },
            [ Clear_session ] )
      | Command.Fork_session -> (
          (* Fork the attached session into a child and continue there — the
             same {!Fork_session} transition the sessions screen's fork takes
             (10-commands.md §/fork). The echo lands in the child's fresh
             transcript (the pre-fork one is swapped out, so an echo there would
             be wiped); the lineage record follows via {!Session_forked}, then
             the inherited history replays below both. The gate is [attached],
             not [session_id] alone — the fresh path's id is a pre-minted seed
             whose document exists only once the first turn attaches, and
             forking an unwritten document dies on the store read. *)
          match t.session_id with
          | Some id when t.attached ->
              let t, commands = enter_session (Fork_session id) t in
              let t =
                match t.phase with
                | Chat chat ->
                    let transcript =
                      Transcript.append chat.transcript
                        (Transcript.Notice
                           (Notice.Echo
                              { command = Command.slash command; result = None }))
                    in
                    { t with phase = Chat { chat with transcript } }
                | Prelude -> t
              in
              (t, commands)
          | Some _ | None ->
              ({ t with flash = Some "fork: no active session" }, []))
      | Command.Rename_session -> (
          (* Rename the attached session. With the trailing title the effect
             fires directly and the record lands optimistically — the runtime's
             write is fire-and-forget, exactly as the sessions screen's inline
             rename. Bare, the shell seeds the draft with [/rename ] — the same
             argument-insert the palette's ↵ performs — so the title is typed
             inline; there is no separate borrowed prompt. The [attached] gate
             mirrors /fork: a pre-minted seed has no document to rename. *)
          match t.session_id with
          | Some id when t.attached -> (
              match argument with
              | Some title ->
                  let notices =
                    [
                      Transcript.Notice
                        (Notice.Echo
                           {
                             command = Command.slash command ^ " " ^ title;
                             result = None;
                           });
                      Transcript.Notice
                        (Notice.Event ("renamed to \"" ^ title ^ "\""));
                    ]
                  in
                  let t =
                    match t.phase with
                    | Chat chat ->
                        let transcript =
                          List.fold_left Transcript.append chat.transcript
                            notices
                        in
                        { t with phase = Chat { chat with transcript } }
                    | Prelude -> t
                  in
                  (t, [ Rename_session { id; title } ])
              | None -> (set_draft (Command.slash command ^ " ") t, []))
          | Some _ | None -> ({ t with flash = Some "no session to rename" }, [])
          )
      | Command.Toggle_verbose -> (
          (* Flip the ctrl+o expand lens — the same [chat.expanded] the key
             flips, so the command and the key cannot drift — and record it:
             the muted [❯ /verbose] echo, then the event-class outcome
             (01-transcript.md §Notices). The lens is a property of the chat
             document; on the home stage there is nothing to expand, so the
             command flashes honestly instead (ctrl+o is gated to chat for the
             same reason). *)
          match t.phase with
          | Chat chat ->
              let expanded = not chat.expanded in
              let outcome =
                if expanded then "tool output expanded"
                else "tool output collapsed"
              in
              let transcript =
                List.fold_left Transcript.append chat.transcript
                  [
                    Transcript.Notice
                      (Notice.Echo
                         { command = Command.slash command; result = None });
                    Transcript.Notice (Notice.Event outcome);
                  ]
              in
              ({ t with phase = Chat { chat with expanded; transcript } }, [])
          | Prelude ->
              ({ t with flash = Some "no tool output to expand yet" }, [])))

(* A submitted draft routes by shape (03-composer.md, 10-commands.md): a known
   slash command dispatches through its catalog fate; a [!] command runs on the
   shell executor — refused while a turn streams (the spec's mid-turn rule) or
   while another shell command runs; an unknown [/word] and all plain text
   start a turn. The composer already consumed the draft, so a command submit
   leaves the composer empty for esc to restore. *)
let submit_text value t =
  let trimmed = String.trim value in
  if String.starts_with ~prefix:"!" trimmed then
    let turn_in_flight =
      match t.phase with
      | Chat chat -> Turn.in_flight chat.turn
      | Prelude -> false
    in
    if turn_in_flight then ({ t with flash = Some shell_wait_flash }, [])
    else if t.shell <> None then ({ t with flash = Some shell_busy_flash }, [])
    else
      let command =
        String.trim (String.sub trimmed 1 (String.length trimmed - 1))
      in
      if String.equal command "" then
        ({ t with flash = Some shell_empty_flash }, [])
      else start_shell command t
  else
    match Command.parse trimmed with
    | Some (Command.Exact command) -> dispatch_command command t
    | Some (Command.With_argument (command, argument)) ->
        dispatch_command ~argument:(Some argument) command t
    | None -> start_turn value t

(* Fold one composer event into the shell (the composer's outward seam). Every
   committed draft — submitted or discarded — is appended to the JSONL prompt
   history; the composer's in-memory copy already has it, so persistence is the
   only effect. (The composer's arrow-walk recalls slash commands too, so the
   file keeps them — a deliberate divergence from the old TUI, which persisted
   only turn prompts.) *)
(* The continuation command a resolved dialog submits, reading the boundary ids
   from the dialog's pending projection. The resolution kind and the boundary
   kind always agree by construction (a permission dialog yields a [Reply], a
   plan dialog a [Resolve_plan], a question dialog an [Answer]), so a disagreement
   is [None] and submits nothing. Owner routing (Main vs Child) is deferred — only
   the parent turn opens dialogs this iteration. *)
let command_of_resolution boundary (resolution : Dialog.resolution) =
  match (resolution, (boundary : Spice_protocol.Pending.t)) with
  | Dialog.Reply { answer; message }, Spice_protocol.Pending.Permission request
    ->
      Some
        (Reply_permission
           {
             permission = Spice_session.Permission.Requested.id request;
             answer;
             message;
           })
  | ( Dialog.Answer { text },
      ( Spice_protocol.Pending.Question { turn; call_id; _ }
      | Spice_protocol.Pending.Host_tool { turn; call_id; _ } ) ) ->
      Some (Answer_tool { turn; call_id; text })
  | ( Dialog.Resolve_plan { decision; _ },
      Spice_protocol.Pending.Plan { turn; call_id; _ } ) ->
      Some (Resolve_plan { turn; call_id; decision })
  | _ -> None

(* Close a resolved dialog: append its echo as an event notice under the tool
   call, apply the accept-edits posture in the same stroke when a plan approval
   asked for it, and hand back the continuation command. Dialogs only open in
   chat, so the echo always has a transcript to land in. *)
let resolve_dialog ~resolution ~echo dialog t =
  let boundary = (Dialog.pending dialog).Dialog.boundary in
  let commands = Option.to_list (command_of_resolution boundary resolution) in
  let t =
    match resolution with
    | Dialog.Resolve_plan { accept_edits = true; _ } ->
        { t with posture = Footer.Accept_edits }
    | Dialog.Reply _ | Dialog.Answer _ | Dialog.Resolve_plan _ -> t
  in
  let t =
    match t.phase with
    | Chat chat ->
        {
          t with
          phase =
            Chat
              {
                chat with
                transcript =
                  Transcript.append chat.transcript
                    (Transcript.Notice (Notice.Event echo));
              };
        }
    | Prelude -> t
  in
  ({ t with surface = Conversing; borrow = Free }, commands)

(* Finish a borrowed feedback composer from the submitted [text]: an empty custom
   answer is refused (flash, stay borrowed), everything else resolves. The saved
   draft is restored before the composer returns. *)
let resolve_borrow_text text t =
  match (t.surface, t.borrow) with
  | Panel (Dialog dialog), For_answer { saved_draft; _ } -> (
      match Dialog.resolve_borrow ~text dialog with
      | Ok (resolution, echo) ->
          let t = set_draft saved_draft t in
          resolve_dialog ~resolution ~echo dialog t
      | Error message -> ({ t with flash = Some message }, []))
  | _ -> (t, [])

let composer_event event t =
  match event with
  | Composer.Submitted { text; entry } -> (
      (* A borrowed composer resolves the pending dialog instead of starting a
         turn; feedback text is not persisted as prompt history. *)
      match t.borrow with
      | For_answer _ -> resolve_borrow_text text t
      | Free ->
          let t, commands = submit_text text t in
          (t, commands @ [ Append_prompt_history entry ]))
  | Composer.Blank_submitted -> (
      match t.borrow with
      | For_answer _ -> resolve_borrow_text "" t
      | Free -> (
          (* An empty submit on the home stage resumes the newest session
             directly — the recognition surface is the workspace block's session
             line (12-home.md §Keybindings, the v2 revision). With no session, and
             in chat, it is a no-op. *)
          match (t.phase, t.brief) with
          | Prelude, Some { Home.Brief.session = Some session; _ } ->
              enter_session (Resume_session session.Home.Brief.id) t
          | (Prelude | Chat _), _ -> (t, [])))
  | Composer.Draft_saved entry -> (
      (* A borrowed composer holds dialog feedback, not a prompt: a discard
         (esc/ctrl+c) must not persist it as prompt history, symmetric with the
         [Submitted]/[Blank_submitted] borrow guards above. *)
      match t.borrow with
      | For_answer _ -> (t, [])
      | Free -> (t, [ Append_prompt_history entry ]))
  | Composer.Help_requested ->
      (* One overlay at a time: opening the help sheet closes any open completion
         so the two never stack (03-composer.md §Keybindings). *)
      let help = not t.help in
      ( {
          t with
          help;
          completion = (if help then No_completion else t.completion);
        },
        [] )

(* The completion mirrors the draft after every composer fold (the filter law:
   the composer text IS the filter). The palette opens when "/" is typed on an
   empty draft — the text is exactly "/" — tracks the text after the slash, and
   closes the moment the draft stops being a single-line slash form
   (backspacing past the "/", a newline, a palette insertion). The mention list
   opens whenever an @-token sits at the cursor (mid-draft, nearest "@" with no
   whitespace between — 03-composer.md §File completion), tracks the token, and
   closes when the token dissolves. Opening or descending the mention tree may
   need directory loads, so the sync returns effect intents. *)
let sync_completion t =
  (* One overlay at a time: opening or refreshing a completion closes the help
     sheet so the two never stack (03-composer.md §Keybindings). *)
  let close_help (t, effects) =
    ((if completion_open t then { t with help = false } else t), effects)
  in
  let text = Composer.draft_text t.composer in
  let slash_form =
    String.starts_with ~prefix:"/" text && not (String.contains text '\n')
  in
  let query () = String.sub text 1 (String.length text - 1) in
  let token () = Composer.active_file_ref_token t.composer in
  let token_query token = String.sub token 1 (String.length token - 1) in
  close_help
  @@
  match t.completion with
  | Commands palette ->
      if slash_form then
        ( {
            t with
            completion = Commands (Palette.with_query (query ()) palette);
          },
          [] )
      else ({ t with completion = No_completion }, [])
  | Mention mention -> (
      match token () with
      | Some token ->
          ( {
              t with
              completion =
                Mention (Mention.with_query (token_query token) mention);
            },
            [] )
      | None -> ({ t with completion = No_completion }, []))
  | History_search { search; saved } ->
      (* The whole draft is the search query (the filter law: the text after
         ctrl+r). *)
      ( {
          t with
          completion =
            History_search
              { search = History.Search.with_query text search; saved };
        },
        [] )
  | No_completion -> (
      if String.equal text "/" then
        ( { t with completion = Commands (Palette.with_query "" Palette.make) },
          [] )
      else
        match token () with
        | Some token ->
            let mention, dirs =
              Mention.request_loads (Mention.make ~query:(token_query token) ())
            in
            ( { t with completion = Mention mention },
              List.map (fun dir -> Load_dir dir) dirs )
        | None -> (t, []))

(* Insert the chosen mention into the draft as an atomic reference plus a
   trailing space and close the list (03-composer.md §File completion): a
   directory keeps its trailing slash; thread mentions land with live
   threads. *)
let complete_mention item t =
  let path =
    match item with
    | Mention.File path -> Spice_path.Rel.to_string path
    | Mention.Directory path -> Spice_path.Rel.to_string path ^ "/"
    | Mention.Agent_thread { name } -> name
  in
  let composer, _ =
    Composer.update (Composer.Complete_file_ref path) t.composer
  in
  { t with composer; completion = No_completion }

(* Route an intercepted ↑/↓/tab: list navigation while a completion is open,
   the prompt-history walk on a single-line draft otherwise (03-composer.md
   §History navigation). Tab completes the shared prefix on the palette and
   descends a directory on the mention list — which stays open
   (03-ia-screens-overlays.md §Completions). *)
let list_key key t =
  match t.completion with
  | Commands palette -> (
      match key with
      | `Up -> ({ t with completion = Commands (Palette.move `Up palette) }, [])
      | `Down ->
          ({ t with completion = Commands (Palette.move `Down palette) }, [])
      | `Tab -> (
          match Palette.complete palette with
          | Some prefix -> sync_completion (set_draft prefix t)
          | None -> (t, [])))
  | Mention mention -> (
      match key with
      | `Up ->
          ({ t with completion = Mention (Mention.select_previous mention) }, [])
      | `Down ->
          ({ t with completion = Mention (Mention.select_next mention) }, [])
      | `Tab -> (
          match Mention.tab mention with
          | Mention.Descended mention ->
              let mention, dirs = Mention.request_loads mention in
              ( { t with completion = Mention mention },
                List.map (fun dir -> Load_dir dir) dirs )
          | Mention.Chosen item -> (complete_mention item t, [])
          | Mention.No_selection -> (t, [])))
  | History_search { search; saved } -> (
      match key with
      | `Up ->
          ( {
              t with
              completion =
                History_search
                  { search = History.Search.move `Up search; saved };
            },
            [] )
      | `Down ->
          ( {
              t with
              completion =
                History_search
                  { search = History.Search.move `Down search; saved };
            },
            [] )
      | `Tab -> (t, []))
  | No_completion -> (
      let walk msg =
        let composer, _ = Composer.update msg t.composer in
        ({ t with composer }, [])
      in
      let in_chat = match t.phase with Chat _ -> true | Prelude -> false in
      match key with
      (* Threads switcher (doc/plans/tui-next-threads.md §2.2): on an empty draft
         [↓] engages the below-footer strip, then [↑/↓] walk its rows; [↑] stays
         with the queue/history so the two navigations never collide. Once
         engaged, [↑/↓] belong to the strip regardless of the queue. *)
      | `Up when t.strip_focus <> None ->
          let i = Option.value ~default:0 t.strip_focus in
          ({ t with strip_focus = Some (max 0 (i - 1)) }, [])
      | `Down when t.strip_focus <> None ->
          let i = Option.value ~default:0 t.strip_focus in
          ( {
              t with
              strip_focus = Some (min (List.length t.thread_runs) (i + 1));
            },
            [] )
      | `Down
        when in_chat && t.thread_runs <> [] && Composer.is_blank t.composer ->
          ({ t with strip_focus = Some 0 }, [])
      (* [↑] on an empty composer pops the NEWEST queued prompt back into the
         composer for editing, ahead of history recall while the queue is
         non-empty (01-transcript.md §The status strip, revised 2026-07-08): the
         queued prompt is the newest thing typed. It leaves the queue and
         re-queues at the tail on re-submit. Otherwise [↑] walks prompt history.
         The queue is only ever non-empty while a turn is in flight. *)
      | `Up when t.queued <> [] && Composer.is_blank t.composer -> (
          match List.rev t.queued with
          | newest :: rest_rev ->
              (set_draft newest { t with queued = List.rev rest_rev }, [])
          | [] -> walk Composer.History_previous)
      | `Up -> walk Composer.History_previous
      | `Down -> walk Composer.History_next
      | `Tab -> (t, []))

(* ↵ while a list is open activates the selection and never sends the draft
   (03-ia-screens-overlays.md §Completions): a no-argument command runs, an
   arg-taking one seeds the draft with [/command ] and closes; a mention
   inserts and closes. [None] means no palette row matched — the caller
   swallows the submit, keeping the list up. *)
let activate_completion t =
  match t.completion with
  | No_completion -> None
  | Commands palette -> (
      match Palette.activate palette with
      | None -> None
      | Some (Palette.Insert text) ->
          Some (set_draft text { t with completion = No_completion }, [])
      | Some (Palette.Run command) ->
          Some
            (dispatch_command command
               (set_draft "" { t with completion = No_completion })))
  | Mention mention ->
      Some
        ( (match Mention.enter mention with
          | Some item -> complete_mention item t
          | None -> { t with completion = No_completion }),
          [] )
  | History_search { search; saved = _ } ->
      (* A ctrl+r pick INSERTS the prompt into the draft — never submits
         (03-ia-screens-overlays.md §Completions); with no match ↵ just closes,
         keeping the typed query as the draft. *)
      let t = { t with completion = No_completion } in
      Some
        ( (match History.Search.selected_entry search with
          | Some entry ->
              let composer, _ =
                Composer.update (Composer.Restore_history entry) t.composer
              in
              let composer, _ =
                Composer.update Composer.End_history_search composer
              in
              { t with composer }
          | None ->
              let composer, _ =
                Composer.update Composer.End_history_search t.composer
              in
              { t with composer }),
          [] )

(* Interrupt is esc's alone (03-composer.md §Keybindings); Ctrl+C is the quit
   chord and never reaches here. Two-stage: the first press arms the notice, the
   second fires — cancelling the running user shell when one is up, else flipping
   the in-flight turn to its draining [Turn.interrupting] state. *)
let interrupt_rung chat t =
  match t.armed with
  | Some Interrupt_armed ->
      if t.shell <> None then ({ t with armed = None }, [ Interrupt_shell ])
      else
        ( {
            t with
            phase = Chat { chat with turn = Turn.interrupting chat.turn };
            armed = None;
          },
          [ Interrupt ] )
  | Some Quit_armed | Some Clear_armed | None ->
      ({ t with armed = Some Interrupt_armed }, [])

(* An interrupt arm targets the in-flight turn; once that turn settles the arm is
   stale. Drop it so the footer notice does not outlive the turn and — the real
   hazard — a queued correction draining at the boundary does not inherit the arm
   and fire on its first esc. Quit/Clear arms are about the app, not the turn, so
   they persist. *)
let disarm_interrupt = function Some Interrupt_armed -> None | armed -> armed

(* Whether esc/ctrl+c have something to interrupt: a streaming turn or a
   running user shell. *)
let interruptible chat t = Turn.in_flight chat.turn || t.shell <> None

(* Issue a relative transcript scroll as a serial-keyed reveal (mirrors the old
   TUI; 01-transcript.md §Seam replay, scroll, spacing): each jump carries a
   fresh serial so an equal offset re-honors, since the scrollport ignores a
   reused reveal key. Clamped at the top; the scrollport clamps the bottom. A
   no-op outside chat. *)
let scroll_transcript ~delta t =
  match t.phase with
  | Chat chat ->
      let target = max 0 (chat.scroll + delta) in
      let serial =
        match chat.reveal with Some (serial, _) -> serial + 1 | None -> 0
      in
      { t with phase = Chat { chat with reveal = Some (serial, target) } }
  | Prelude -> t

(* Upsert a run's latest ledger record by child id: the registry re-emits the
   whole record on every transition, so the newest wins and the child id keys
   one row (doc/plans/tui-next-threads.md §4.3). Prepended; order is not load
   bearing for the count, and the switcher iteration sorts by creation. *)
let upsert_run run runs =
  let child = Spice_protocol.Subagent_run.child run in
  run
  :: List.filter
       (fun r ->
         not
           (Spice_session.Id.equal (Spice_protocol.Subagent_run.child r) child))
       runs

(* The count of a session's live children — running, blocked, or queued — for
   the footer's [* N agents] fact (04-header-footer.md §2; old TUI [agents_status]).
   [None] when none are live so the segment simply drops. *)
let agents_active t =
  let live =
    List.fold_left
      (fun n run ->
        match Thread_view.of_run run with
        | Thread_view.Running | Thread_view.Blocked | Thread_view.Queued ->
            n + 1
        | Thread_view.Completed | Thread_view.Failed | Thread_view.Interrupted
          ->
            n)
      0 t.thread_runs
  in
  if live = 0 then None else Some live

(* The switcher's row order: live agents first (running, then blocked, then
   queued), then the settled outcomes (doc/plans/tui-next-threads.md §2.6). Ties
   within a rank break by creation time, so a rank holds spawn order regardless of
   which run last re-emitted (the ledger re-emits the whole record on every
   transition, so ordering by list position would reshuffle a rank on each
   update). This is the same order the strip rows draw in, so a [strip_focus]
   index maps to the same run the view shows. *)
let thread_rank run =
  match Thread_view.of_run run with
  | Thread_view.Running -> 0
  | Thread_view.Blocked -> 1
  | Thread_view.Queued -> 2
  | Thread_view.Failed -> 3
  | Thread_view.Interrupted -> 4
  | Thread_view.Completed -> 5

let ordered_runs t =
  List.stable_sort
    (fun a b ->
      match Int.compare (thread_rank a) (thread_rank b) with
      | 0 ->
          Spice_session.Time.compare
            (Spice_protocol.Subagent_run.created_at a)
            (Spice_protocol.Subagent_run.created_at b)
      | order -> order)
    t.thread_runs

(* The run a [strip_focus] index points at, or [None] for the synthetic [Main]
   row (index 0) or an out-of-range index. Row 0 is [Main]; row [i > 0] is the
   [i-1]th run in display order. *)
let selected_run t =
  match t.strip_focus with
  | Some i when i >= 1 -> List.nth_opt (ordered_runs t) (i - 1)
  | Some _ | None -> None

(* Whether a run can be drilled into read-only: only a settled child, whose
   persisted document is complete and quiescent. A running/blocked child is still
   writing its document (the live-snapshot race, §3.2), and a queued one has no
   document yet — both wait on [Jobs.observe] (deferred). *)
let thread_openable run =
  match Thread_view.of_run run with
  | Thread_view.Completed | Thread_view.Failed | Thread_view.Interrupted -> true
  | Thread_view.Queued | Thread_view.Running | Thread_view.Blocked -> false

(* The run backing a drilled-in thread id, for its banner (role/task). *)
let drilled_run t id =
  List.find_opt
    (fun r -> Spice_session.Id.equal (Spice_protocol.Subagent_run.child r) id)
    t.thread_runs

(* [↵]/click on the engaged switcher: drill into the selected settled child
   (read-only), flash on a still-running one, and no-op on [Main] / out of range.
   Clears the focus so the strip collapses back to its glance behind the thread
   view. *)
let drill_selected t =
  match selected_run t with
  | Some run when thread_openable run ->
      ( { t with strip_focus = None },
        [ Load_thread_document (Spice_protocol.Subagent_run.child run) ] )
  | Some _ ->
      ( { t with flash = Some "agent still running — open it once it settles" },
        [] )
  | None -> (t, [])

(* A run belongs to the attached session when its parent is the session this
   process drives; a stray event for another tree is ignored. *)
let owns_run t run =
  match t.session_id with
  | Some id ->
      Spice_session.Id.equal id (Spice_protocol.Subagent_run.parent run)
  | None -> false

(* Append a notice to the chat transcript and carry the clock forward, a no-op
   on the home stage (a spawn only settles mid-turn, so the chat phase always
   holds). *)
let append_chat_notice ~now t notice =
  match t.phase with
  | Prelude -> t
  | Chat chat ->
      {
        t with
        phase =
          Chat
            {
              chat with
              now;
              transcript =
                Transcript.append chat.transcript (Transcript.Notice notice);
            };
      }

(* The headline of a settled-thread line — the role/word/facts row, dropping the
   clipped detail the vocabulary hangs on a second line (its disclosure lands
   with the switcher strip). *)
let notice_headline line =
  match String.index_opt line '\n' with
  | Some i -> String.sub line 0 i
  | None -> line

(* The muted event-notice line a settled auth flow records (09-auth §8, degraded
   to one line — see the [Auth_settled] arm). The qualified field pattern picks
   [Auth_panel.record] so the shared [provider_title] label needs no
   type-directed disambiguation. *)
let auth_settled_line record =
  let { Auth_panel.provider_title; outcome; acct_fingerprint; source_word } =
    record
  in
  let ident =
    match (acct_fingerprint, source_word) with
    | Some fp, Some src -> Theme.separator ^ "…" ^ fp ^ " (" ^ src ^ ")"
    | Some fp, None -> Theme.separator ^ "…" ^ fp
    | None, Some src -> " (" ^ src ^ ")"
    | None, None -> ""
  in
  let verb, body =
    match outcome with
    | Auth_panel.Signed_in -> ("Log in to ", "✓ signed in" ^ ident)
    | Auth_panel.Saved_blocked ->
        ("Log in to ", "✓ saved · ! blocked — key rejected by the provider")
    | Auth_panel.Saved_unchecked reason ->
        ("Log in to ", "✓ saved · unchecked — " ^ reason)
    | Auth_panel.Removed -> ("Log out of ", "removed" ^ ident)
    | Auth_panel.Env_active var ->
        ("Log out of ", "! env " ^ var ^ " still active")
    | Auth_panel.Failed message ->
        ("Log in to ", "✗ sign-in failed · " ^ message)
  in
  verb ^ provider_title ^ Theme.separator ^ body

(* Interpret an Auth_panel outcome: keep the panel, close it, flash, copy, open
   the browser, or START a flow — minting the request id the runtime tags the
   attempt with, stamping it into the panel ({!Auth_panel.started}), and emitting
   the runtime command (09-auth.md; mirrors the old TUI's begin_auth). Closing
   restores the composer + draft (the surface never touched the draft). *)
let interpret_auth_event panel event t =
  let stay = { t with surface = Panel (Auth panel) } in
  let begin_flow command =
    let request = t.next_request in
    ( {
        t with
        surface = Panel (Auth (Auth_panel.started ~request panel));
        next_request = request + 1;
      },
      [ command request ] )
  in
  match event with
  | Auth_panel.Stay -> (stay, [])
  | Auth_panel.Close -> ({ t with surface = Conversing }, [])
  | Auth_panel.Flash message -> ({ stay with flash = Some message }, [])
  | Auth_panel.Copy text -> (stay, [ Auth_copy text ])
  | Auth_panel.Open_url url -> (
      match Auth_panel.active_request panel with
      | Some request -> (stay, [ Auth_open_url { request; url } ])
      | None -> (stay, []))
  | Auth_panel.Cancel { request } -> (stay, [ Auth_cancel { request } ])
  | Auth_panel.Reload -> (stay, [ Load_auth_providers ])
  | Auth_panel.Begin_api_key { provider; method_id; key } ->
      begin_flow (fun request ->
          Auth_save_api_key { request; provider; method_id; key })
  | Auth_panel.Begin_browser { provider; method_id } ->
      begin_flow (fun request ->
          Auth_browser_login { request; provider; method_id })
  | Auth_panel.Begin_device { provider; method_id } ->
      begin_flow (fun request ->
          Auth_device_login { request; provider; method_id })
  | Auth_panel.Begin_logout { provider } ->
      begin_flow (fun request -> Auth_logout { request; provider })

let update msg t =
  match msg with
  | Composer_msg (Composer.List_key key) -> list_key key t
  | Composer_msg (Composer.Submit _)
    when t.strip_focus <> None && not (completion_open t) ->
      (* [↵] while the switcher is engaged drills into the selected thread rather
         than submitting: the draft is blank whenever the strip holds focus (a
         printable releases it), so no prompt is lost
         (doc/plans/tui-next-threads.md §2.3). *)
      drill_selected t
  | Composer_msg (Composer.Submit _) when completion_open t -> (
      match activate_completion t with
      | Some result -> result
      | None ->
          (* The only [None] is a slash palette with no match ([Mention] and
             [History_search] always activate): [↵] never sends the draft while a
             list is up (03-ia-screens-overlays.md §Completions), so it is
             swallowed — the palette stays and a mistyped [/…] never reaches the
             model as a prompt. *)
          (t, []))
  | Composer_msg m ->
      (* Composer activity disarms any pending two-stage notice; the first
         keystroke freezes the lockup for the rest of the process (12-home.md
         §Liveness) — the latch never re-arms. *)
      let composer, events = Composer.update m t.composer in
      let motion =
        if String.equal (Composer.draft_text composer) "" then t.motion
        else Home.Motion.freeze t.motion
      in
      (* Composer activity (typing, paste) returns focus from the threads strip to
         the composer with the keystroke applied (doc/plans/tui-next-threads.md
         §2.2); arrow walking of the strip is a separate [List_key] path. *)
      let t, sync_commands =
        sync_completion
          { t with composer; motion; armed = None; strip_focus = None }
      in
      List.fold_left
        (fun (t, commands) event ->
          let t, more = composer_event event t in
          (t, commands @ more))
        (t, sync_commands) events
  | Live_event { event; now } -> (
      match t.phase with
      | Chat chat ->
          ( {
              t with
              attached = true;
              phase =
                Chat
                  (apply_event ~show_reasoning:t.show_reasoning ~now event chat);
            },
            [] )
      | Prelude -> (t, []))
  | Settled { result; now } -> (
      match t.phase with
      | Prelude -> (t, [])
      | Chat chat -> (
          match result with
          | Finished -> (
              (* The turn boundary drains the queue oldest-first, one prompt per
                 boundary (01-transcript.md §The status strip, revised
                 2026-07-08). An interrupted turn settles [Finished] too, so this
                 one arm is the committed interrupt-then-queued-correction-sends
                 fast path. *)
              let t =
                {
                  t with
                  phase = Chat { chat with now };
                  armed = disarm_interrupt t.armed;
                }
              in
              match t.queued with
              | [] -> (t, [])
              | next :: queued -> start_turn next { t with queued })
          | Waiting pending -> (
              (* Park the working line, then open a decision dialog on the typed
                 boundary. A boundary with no user-facing form (an unclassifiable
                 host tool) parks without a dialog. *)
              let t =
                {
                  t with
                  phase = Chat { chat with turn = Turn.waiting chat.turn; now };
                }
              in
              match
                Option.bind pending (Dialog.of_pending ~owner:Dialog.Main)
              with
              | Some dialog -> ({ t with surface = Panel (Dialog dialog) }, [])
              | None -> (t, []))
          | Failed { message } ->
              (* A transport failure that never produced a Turn_finished: the
                 turn is still active, so reset the tail and record the failure
                 with an honest next step. Queued prompts are discarded — they
                 were written against a conversation that just broke — and the
                 discard is said out loud. *)
              let notice =
                Notice.Failure
                  {
                    message;
                    next_step = "Tell spice how to proceed.";
                    count = 1;
                  }
              in
              let chat =
                {
                  chat with
                  transcript =
                    Transcript.append chat.transcript (Transcript.Notice notice);
                  turn = Turn.idle;
                  now;
                }
              in
              let flash =
                if t.queued = [] then t.flash
                else Some "queued prompts discarded after the failure"
              in
              ( {
                  t with
                  phase = Chat chat;
                  queued = [];
                  flash;
                  armed = disarm_interrupt t.armed;
                },
                [] )))
  | Turn_tick -> (
      match t.phase with
      | Chat chat ->
          ( {
              t with
              phase =
                Chat
                  {
                    chat with
                    spinner = chat.spinner + 1;
                    now = chat.now +. turn_tick_interval;
                  };
            },
            [] )
      | Prelude -> (t, []))
  | Toggle_expanded -> (
      match t.phase with
      | Chat chat ->
          ( { t with phase = Chat { chat with expanded = not chat.expanded } },
            [] )
      | Prelude -> (t, []))
  | Transcript_scrolled y -> (
      match t.phase with
      | Chat chat -> ({ t with phase = Chat { chat with scroll = y } }, [])
      | Prelude -> (t, []))
  | Transcript_paged direction ->
      (* Page by a viewport-minus-chrome span, floored so a short terminal still
         moves (mirrors the old TUI). *)
      let page = max 4 (t.rows - 8) in
      let delta = match direction with `Up -> -page | `Down -> page in
      (scroll_transcript ~delta t, [])
  | Transcript_wheeled (direction, notches) ->
      (* Three lines per wheel notch, the terminal-native step. *)
      let step = 3 * max 1 notches in
      let delta = match direction with `Up -> -step | `Down -> step in
      (scroll_transcript ~delta t, [])
  | Thread_runs_loaded { session; runs } ->
      (* The artifact ledger's whole set at session entry, carrying the runtime's
         authoritative attached-session id (dispatched from [enter_session] on a
         resume / fork). Adopt it as [session_id]: the fresh path's [session_id]
         is the pre-minted seed the first turn attaches under, but a resume / fork
         attaches under a DIFFERENT id, and [owns_run] must gate the live
         [Thread_*] events on the session actually attached — otherwise every
         spawn in a resumed session is dropped and nothing renders below the
         footer (doc/plans/tui-next-threads.md §1). *)
      let strip_focus =
        (* A resume can shrink the set, so drop a now-out-of-range focus. *)
        match t.strip_focus with
        | Some i when i > List.length runs -> None
        | focus -> focus
      in
      (* A drill-in belongs to the previous session; entering a new one drops it. *)
      ( {
          t with
          session_id = Some session;
          attached = true;
          thread_runs = runs;
          strip_focus;
          drill = None;
        },
        [] )
  | Thread_started run ->
      if owns_run t run then
        ({ t with thread_runs = upsert_run run t.thread_runs }, [])
      else (t, [])
  | Thread_asked { run; message; now } ->
      (* The child's [message_parent] ask relays to the parent as a gray event
         notice attributed to the thread (subagent-tui.md decision 17; the
         [✉ waiting on reply] switcher fact lands with the strip). *)
      if owns_run t run then
        let role =
          Spice_protocol.Subagent.Role.to_string
            (Spice_protocol.Subagent_run.role run)
        in
        let line =
          "› Message from @" ^ role ^ ": " ^ Thread_view.clip ~max:100 message
        in
        let t = { t with thread_runs = upsert_run run t.thread_runs } in
        (append_chat_notice ~now t (Notice.Event line), [])
      else (t, [])
  | Thread_settled { run; now } ->
      (* The terminal transition writes the settled line to the parent transcript
         once (02-tools.md §Subagents; subagent-tui.md decision 9) and drops the
         run from the live [* N agents] count via the upsert. *)
      if owns_run t run then
        let line, _severity = Thread_view.settled_line run in
        let t = { t with thread_runs = upsert_run run t.thread_runs } in
        (append_chat_notice ~now t (Notice.Event (notice_headline line)), [])
      else (t, [])
  | Thread_strip_hovered hover -> ({ t with strip_hover = hover }, [])
  | Thread_strip_clicked i ->
      (* A click selects the row and drills in when it is a settled child — the
         same action as [↵] (doc/plans/tui-next-threads.md §2.3, fix 5). *)
      drill_selected { t with strip_focus = Some i }
  | Thread_document_loaded { run; events; now } -> (
      (* Drop a load that outlived its session: a resume or fork sets
         [drill = None] and replaces [thread_runs] for a different session, and
         this late reply must not resurrect the old session's thread on top of
         it. The child id resolves back to a run in the session's set (which a
         resume has swapped out), and [owns_run] gates on the parent like every
         sibling thread message. *)
      match drilled_run t run with
      | Some backing when owns_run t backing ->
          (* Fold the child's durable events into a fresh read-only chat, exactly
             as a resume replays (each event through the turn reducer). The drilled
             chat is rendered under a thread banner with the way-home footer; [now]
             stamps the fold so the settled turns' elapsed reads off their own
             terminal timestamps. *)
          let tchat =
            List.fold_left
              (fun chat event ->
                apply_event ~show_reasoning:t.show_reasoning ~now event chat)
              { empty_chat with now } events
          in
          ({ t with drill = Some (run, tchat) }, [])
      | Some _ | None -> (t, []))
  | Thread_drill_failed { run = _; message } ->
      ({ t with flash = Some ("could not open thread: " ^ message) }, [])
  | Escape when Option.is_some t.drill ->
      (* A drilled-in thread owns esc's topmost rung: return home before any
         strip-release or interrupt rung. *)
      ({ t with drill = None }, [])
  | Escape when t.strip_focus <> None ->
      (* The switcher, once engaged, owns esc's topmost rung: release it back to
         the composer (doc/plans/tui-next-threads.md §2.2) before any other rung. *)
      ({ t with strip_focus = None }, [])
  | Escape -> (
      (* The esc ladder (03-composer.md §Keybindings), one rung per press:
         close the open completion (the palette clears its slash input); close
         the help sheet; exit shell mode; clear a non-empty draft (two-stage,
         saved to history); interrupt the in-flight turn (two-stage). *)
      match t.completion with
      (* Rung 1: the palette closes and clears its slash input; the mention
         list closes and leaves the literal @-token in the draft
         (03-composer.md §File completion); ctrl+r closes and restores the
         draft it displaced (05-overlays-pickers.md §Prompt-history search). *)
      | Commands _ -> (set_draft "" { t with completion = No_completion }, [])
      | Mention _ -> ({ t with completion = No_completion }, [])
      | History_search { saved; _ } ->
          let composer, _ =
            Composer.update (Composer.Restore_history saved) t.composer
          in
          let composer, _ =
            Composer.update Composer.End_history_search composer
          in
          ({ t with composer; completion = No_completion }, [])
      | No_completion -> (
          if t.help then ({ t with help = false }, [])
          else
            match Composer.input_mode t.composer with
            | Composer.Input_mode.Shell ->
                let composer, _ =
                  Composer.update Composer.Exit_shell t.composer
                in
                ({ t with composer; armed = None }, [])
            | Composer.Input_mode.History_search | Composer.Input_mode.Plain
              -> (
                if not (Composer.is_blank t.composer) then
                  match t.armed with
                  | Some Clear_armed ->
                      (* Fold the discard's events: [Draft_saved] carries the JSONL
                     persistence (Append_prompt_history); dropping it would
                     keep the recall in-memory only. *)
                      let composer, events =
                        Composer.update Composer.Clear_to_history t.composer
                      in
                      List.fold_left
                        (fun (t, commands) event ->
                          let t, more = composer_event event t in
                          (t, commands @ more))
                        ({ t with composer; armed = None }, [])
                        events
                  | Some Quit_armed | Some Interrupt_armed | None ->
                      ({ t with armed = Some Clear_armed }, [])
                else
                  match t.phase with
                  | Chat chat when interruptible chat t ->
                      (* The esc decision ladder with the composer empty and a turn
                     or user shell in flight. Esc owns interrupt and force and the
                     queue never captures it (01-transcript.md §The status strip,
                     revised 2026-07-08): a wrong-direction turn stops in one
                     gesture even while a correction sits queued, and the queue's
                     own edit key is [↑], not esc (see {!list_key}). Ctrl+C is the
                     quit chord and never on this ladder. Two rungs, highest
                     precedence first:
                     1. force while the turn is already draining: a further esc
                        after the interrupt fired hard-cancels it ([Interrupt_force]
                        → {!Spice_host.Live.force_interrupt}), a single press with
                        no arm, since the working line advertises "esc again to
                        force".
                     2. else the two-stage interrupt ([interrupt_rung]): arm the
                        notice, then fire — flipping the turn to its draining
                        [Turn.interrupting] state, from which rung 1 is reachable. *)
                      if Turn.is_forcing chat.turn then
                        (* The hard cancel is already scheduled; nothing left to
                       escalate. *)
                        (t, [])
                      else if Turn.is_interrupting chat.turn then
                        ( {
                            t with
                            phase =
                              Chat { chat with turn = Turn.forcing chat.turn };
                            armed = None;
                          },
                          [ Interrupt_force ] )
                      else interrupt_rung chat t
                  | Chat _ | Prelude -> (t, []))))
  | Session_forked { parent_title } -> (
      (* The fork persisted; the child's replay events follow this message, so
         the lineage record lands under the fresh banner (and under /fork's
         echo when the command drove it), above the inherited history
         (10-commands.md §/fork). *)
      match t.phase with
      | Chat chat ->
          let transcript =
            Transcript.append chat.transcript
              (Transcript.Notice
                 (Notice.Event
                    ("forked to a new session · ↳ from \"" ^ parent_title ^ "\"")))
          in
          ({ t with phase = Chat { chat with transcript } }, [])
      | Prelude -> (t, []))
  | Compaction_failed message -> (
      (* The compaction's success narration flows through the live events (the
         Compacting verb, then the durable compaction's seam); only a failure
         needs this dedicated surface. *)
      match t.phase with
      | Chat chat ->
          let transcript =
            Transcript.append chat.transcript
              (Transcript.Notice
                 (Notice.Event ("compaction failed: " ^ message)))
          in
          ({ t with phase = Chat { chat with transcript } }, [])
      | Prelude -> (t, []))
  | Sessions_loaded rows -> (
      (* Fold the runtime-loaded rows into the panel, but only while it is still
         up — the user may have esc'd before the load arrived. *)
      match t.surface with
      | Panel (Session_switch panel) ->
          ( {
              t with
              surface =
                Panel (Session_switch (Sessions_panel.loaded rows panel));
            },
            [] )
      | Conversing | Panel (Model _ | Dialog _ | Auth _) | Screen _ -> (t, []))
  | Sessions_load_failed message -> (
      (* A transient store failure renders the panel's error line, not the empty
         state (doc/plans/tui-next-surfaces.md §Sequencing 5). *)
      match t.surface with
      | Panel (Session_switch panel) ->
          ( {
              t with
              surface =
                Panel (Session_switch (Sessions_panel.failed message panel));
            },
            [] )
      | Conversing | Panel (Model _ | Dialog _ | Auth _) | Screen _ -> (t, []))
  | Panel_msg m -> (
      match t.surface with
      | Panel (Session_switch panel) -> (
          let panel, event = Sessions_panel.update m panel in
          match event with
          | Sessions_panel.Stay ->
              ({ t with surface = Panel (Session_switch panel) }, [])
          | Sessions_panel.Close -> ({ t with surface = Conversing }, [])
          | Sessions_panel.Resume id -> enter_session (Resume_session id) t
          (* [tab] promotes to the browse screen, carrying the panel's filter and
             selection (03-ia §Sessions); the screen loads the full listing. *)
          | Sessions_panel.Promote { filter; select } ->
              ( {
                  t with
                  surface =
                    Screen (Sessions (Sessions_screen.promoted ~filter ~select));
                },
                [ Load_screen_sessions ] ))
      | Conversing | Panel (Model _ | Dialog _ | Auth _) | Screen _ -> (t, []))
  | Screen_msg m -> (
      match t.surface with
      | Screen (Sessions screen) -> (
          let screen, event = Sessions_screen.update m screen in
          let stay = { t with surface = Screen (Sessions screen) } in
          match event with
          | Sessions_screen.Stay -> (stay, [])
          | Sessions_screen.Close -> ({ t with surface = Conversing }, [])
          | Sessions_screen.Resume id -> enter_session (Resume_session id) t
          | Sessions_screen.Fork id -> enter_session (Fork_session id) t
          (* Rename and delete stay on the screen; the runtime mutates then
             reloads the rows, so the screen reflects the new store state. *)
          | Sessions_screen.Rename { id; title } ->
              (stay, [ Rename_session { id; title } ])
          | Sessions_screen.Delete id -> (stay, [ Delete_session id ]))
      | Conversing | Panel _ | Screen (Settings _ | Review _) -> (t, []))
  | Screen_loaded rows -> (
      match t.surface with
      | Screen (Sessions screen) ->
          ( {
              t with
              surface = Screen (Sessions (Sessions_screen.loaded rows screen));
            },
            [] )
      | Conversing | Panel _ | Screen (Settings _ | Review _) -> (t, []))
  | Screen_failed message -> (
      match t.surface with
      | Screen (Sessions _) ->
          ( {
              t with
              surface = Screen (Sessions (Sessions_screen.failed message));
            },
            [] )
      | Conversing | Panel _ | Screen (Settings _ | Review _) -> (t, []))
  | Settings_msg m -> (
      match t.surface with
      | Screen (Settings screen) -> (
          let screen, event = Settings_screen.update m screen in
          let stay = { t with surface = Screen (Settings screen) } in
          match event with
          | Settings_screen.Stay -> (stay, [])
          | Settings_screen.Close -> ({ t with surface = Conversing }, [])
          (* The managed model row opens the model panel over the settings screen;
             esc returns here (03-ia §Settings). The screen state is captured as
             the panel's return target. *)
          | Settings_screen.Open_model_panel ->
              open_model_panel ~return:(To_settings screen) stay
          (* Config and skill mutations are carried out host-side; the runtime
             writes then re-assembles the facts, so the screen reflects the
             persisted state rather than an optimistic edit. *)
          | Settings_screen.Write_field { field; value } ->
              (stay, [ Write_config { field; value } ])
          | Settings_screen.Toggle_skill name -> (stay, [ Toggle_skill name ])
          | Settings_screen.Copy id ->
              ({ stay with flash = Some "session id copied" }, [ Copy_text id ])
          )
      | Conversing | Panel _ | Screen (Sessions _ | Review _) -> (t, []))
  | Settings_loaded facts -> (
      match t.surface with
      | Screen (Settings screen) ->
          ( {
              t with
              surface = Screen (Settings (Settings_screen.loaded facts screen));
            },
            [] )
      | Conversing | Panel _ | Screen (Sessions _ | Review _) -> (t, []))
  | Settings_load_failed message -> (
      match t.surface with
      | Screen (Settings _) ->
          ( {
              t with
              surface = Screen (Settings (Settings_screen.failed message));
            },
            [] )
      | Conversing | Panel _ | Screen (Sessions _ | Review _) -> (t, []))
  | Review_msg m -> (
      match t.surface with
      | Screen (Review review) -> (
          (* The review sub-library folds the key/completion into new state and an
             event the shell interprets (doc/plans/tui-next-review.md §3.3): [Stay]
             forwards the effects and stays open, [Close] returns to chat — or
             quits when the process was launched onto the screen ([spice review]),
             since there is no chat behind it to return to — and [Task_spice]
             closes then submits the agent review turn — the old [submit_review]
             as an explicit action, echoing the prompt through {!start_turn} so
             it shows as user content. Task spice deliberately enters the chat,
             so it clears the launch flag. *)
          let review, event = Spice_tui_review.update m review in
          let forward effects = List.map (fun e -> Review_command e) effects in
          match event with
          | Spice_tui_review.Stay effects ->
              ({ t with surface = Screen (Review review) }, forward effects)
          | Spice_tui_review.Close effects when t.review_launch ->
              (t, forward effects @ [ Quit ])
          | Spice_tui_review.Close effects ->
              ({ t with surface = Conversing }, forward effects)
          | Spice_tui_review.Task_spice effects ->
              let t =
                {
                  t with
                  surface = Conversing;
                  mode = Spice_protocol.Mode.Review;
                  review_launch = false;
                }
              in
              let t, turn = start_turn "Review the current changes." t in
              ( t,
                forward effects @ (Set_mode Spice_protocol.Mode.Review :: turn)
              ))
      | Conversing | Panel _ | Screen (Sessions _ | Settings _) -> (t, []))
  | Model_panel_msg m -> (
      match t.surface with
      | Panel (Model { panel_state; return }) -> (
          let panel_state, event = Model_panel.update m panel_state in
          let stay =
            { t with surface = Panel (Model { panel_state; return }) }
          in
          match event with
          | Model_panel.Stay -> (stay, [])
          | Model_panel.Close -> (restore_model_return return t, [])
          (* A pick closes the panel; the runtime pins it as the session
             selection (next turn's binding reads it), persists it as the
             future-session default, and replies with the confirmation
             flash. *)
          | Model_panel.Select { selector; effort } ->
              ( restore_model_return return t,
                [ Switch_model { selector; effort } ] )
          (* A locked provider's model needs a login: reroute to the login flow
             pre-selected on [provider] (the provider id — 09-auth.md §9). The
             model panel closes to wherever it was opened from before the auth
             panel takes the region; [open_auth] emits [Load_auth_providers]. *)
          | Model_panel.Login_required provider ->
              open_auth ~mode:Auth_panel.Login ~provider
                (restore_model_return return t))
      | Conversing | Panel (Session_switch _ | Dialog _ | Auth _) | Screen _ ->
          (t, []))
  | Model_facts_loaded facts -> (
      match t.surface with
      | Panel (Model panel) ->
          ( {
              t with
              surface =
                Panel
                  (Model
                     {
                       panel with
                       panel_state = Model_panel.loaded facts panel.panel_state;
                     });
            },
            [] )
      | Conversing | Panel (Session_switch _ | Dialog _ | Auth _) | Screen _ ->
          (t, []))
  | Model_facts_failed message -> (
      match t.surface with
      | Panel (Model panel) ->
          ( {
              t with
              surface =
                Panel
                  (Model
                     {
                       panel with
                       panel_state =
                         Model_panel.failed message panel.panel_state;
                     });
            },
            [] )
      | Conversing | Panel (Session_switch _ | Dialog _ | Auth _) | Screen _ ->
          (t, []))
  | Model_switched notice -> ({ t with flash = Some notice }, [])
  (* An unchanged push keeps the model physically equal, so memoized renders
     stay valid; only real fact movement re-renders the footer. *)
  | Snapshot_refreshed snapshot ->
      ( (if Snapshot.equal snapshot t.snapshot then t else { t with snapshot }),
        [] )
  | Auth_panel_msg m -> (
      match t.surface with
      | Panel (Auth panel) ->
          let panel, event = Auth_panel.update m panel in
          interpret_auth_event panel event t
      | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _ ->
          (t, []))
  | Auth_providers_loaded result -> (
      match t.surface with
      | Panel (Auth panel) ->
          let panel, event = Auth_panel.providers_loaded result panel in
          interpret_auth_event panel event t
      | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _ ->
          (t, []))
  | Auth_challenge { request; challenge } -> (
      match t.surface with
      | Panel (Auth panel) ->
          ( {
              t with
              surface =
                Panel (Auth (Auth_panel.challenge ~request challenge panel));
            },
            [] )
      | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _ ->
          (t, []))
  | Auth_browser_opened { request } -> (
      match t.surface with
      | Panel (Auth panel) ->
          ( {
              t with
              surface = Panel (Auth (Auth_panel.browser_opened ~request panel));
            },
            [] )
      | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _ ->
          (t, []))
  | Auth_browser_open_failed { request } -> (
      match t.surface with
      | Panel (Auth panel) ->
          ( {
              t with
              surface =
                Panel (Auth (Auth_panel.browser_open_failed ~request panel));
            },
            [] )
      | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _ ->
          (t, []))
  | Auth_tick -> (
      match t.surface with
      | Panel (Auth panel) ->
          ({ t with surface = Panel (Auth (Auth_panel.tick panel)) }, [])
      | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _ ->
          (t, []))
  | Auth_paste text -> (
      match t.surface with
      | Panel (Auth panel) ->
          ({ t with surface = Panel (Auth (Auth_panel.paste text panel)) }, [])
      | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _ ->
          (t, []))
  (* A settled flow closes the panel and records the outcome. Guarded by the
     request so a superseded / late settle is dropped. The record lands as a
     muted event notice — the honest degrade of 09-auth §8's two-line ⏺/⎿ record,
     since Notice.t carries no colored two-line tool-record form and Tool_block
     is off-limits to this workstream (reported to the lead, Q2). On the home
     stage there is no transcript to echo into (Q3): close silently and let the
     footer's account segment flip on the refresh. *)
  | Auth_settled { request; record } -> (
      match t.surface with
      | Panel (Auth panel) when Auth_panel.active_request panel = Some request
        ->
          let t = { t with surface = Conversing } in
          let t =
            match t.phase with
            | Chat chat ->
                {
                  t with
                  phase =
                    Chat
                      {
                        chat with
                        transcript =
                          Transcript.append chat.transcript
                            (Transcript.Notice
                               (Notice.Event (auth_settled_line record)));
                      };
                }
            | Prelude -> t
          in
          (t, [ Reload_brief ])
      | Conversing
      | Panel (Auth _ | Session_switch _ | Model _ | Dialog _)
      | Screen _ ->
          (t, []))
  | Dialog_key ev -> (
      match t.surface with
      | Panel (Dialog dialog) -> (
          let dialog, event = Dialog.key ev dialog in
          let t = { t with surface = Panel (Dialog dialog) } in
          match event with
          | Dialog.Stay -> (t, [])
          | Dialog.Resolve { resolution; echo } ->
              resolve_dialog ~resolution ~echo dialog t
          | Dialog.Borrow { placeholder } ->
              (* Save the in-progress draft, clear the composer for the feedback
                 answer, and borrow it (07-dialogs §Deny with feedback). *)
              let saved_draft = Composer.draft_text t.composer in
              let t = set_draft "" t in
              ({ t with borrow = For_answer { placeholder; saved_draft } }, [])
          | Dialog.Flash message -> ({ t with flash = Some message }, []))
      | Conversing | Panel (Session_switch _ | Model _ | Auth _) | Screen _ ->
          (t, []))
  | Cancel_borrow -> (
      match (t.surface, t.borrow) with
      | Panel (Dialog dialog), For_answer { saved_draft; _ } ->
          let t = set_draft saved_draft t in
          ( {
              t with
              surface = Panel (Dialog (Dialog.cancel_borrow dialog));
              borrow = Free;
            },
            [] )
      | _ -> (t, []))
  | Dir_loaded { dir; result } -> (
      (* Fold the enumerated directory into the mention tree, but only while it
         is still up — the user may have closed the list before the load
         arrived. A fold can reveal further needed loads (an expanded child). *)
      match t.completion with
      | Mention mention ->
          let mention, dirs =
            Mention.request_loads (Mention.loaded ~dir result mention)
          in
          ( { t with completion = Mention mention },
            List.map (fun dir -> Load_dir dir) dirs )
      | Commands _ | History_search _ | No_completion -> (t, []))
  | Prompt_history_loaded { session; entries } ->
      (* Feed the composer's arrow-walk and keep the raw records for ctrl+r
         (History.Search ranks the current session first). A search opened
         before the load landed refreshes in place — ctrl+r never waits on
         the load. *)
      let composer =
        Composer.with_history (List.map History.Entry.draft entries) t.composer
      in
      let completion =
        match t.completion with
        | History_search { search; saved } ->
            History_search
              {
                search = History.Search.refresh ~current:session ~entries search;
                saved;
              }
        | (Commands _ | Mention _ | No_completion) as completion -> completion
      in
      ( {
          t with
          composer;
          completion;
          prompt_history = entries;
          session_id = Some session;
        },
        [] )
  | Prompt_history_appended entry ->
      (* The persisted record comes back so the next ctrl+r sees it; the
         composer's in-memory walk already recorded its own copy at
         submit/discard time. *)
      ({ t with prompt_history = entry :: t.prompt_history }, [])
  | Ctrl_r ->
      (* Open reverse history search: the draft is borrowed as the query
         (cleared here, restored on esc), the marker flips to ⌕
         (03-ia-screens-overlays.md §Composer input modes). Before the load has
         attributed a session, nothing ranks as current and the row set
         refreshes when the load lands — the keypress is never dropped. *)
      let saved = Draft.history_entry (Composer.draft t.composer) in
      let composer, _ =
        Composer.update Composer.Begin_history_search t.composer
      in
      let t = set_draft "" { t with composer } in
      ( {
          t with
          completion =
            History_search
              {
                search =
                  History.Search.make ?current:t.session_id
                    ~entries:t.prompt_history ();
                saved;
              };
        },
        [] )
  | Flash_expired -> ({ t with flash = None }, [])
  | Brief_tick -> (t, [ Reload_brief ])
  | Brief_loaded brief -> ({ t with brief = Some brief }, [])
  | Health_tick -> (
      match t.phase with Chat _ -> (t, [ Reload_health ]) | Prelude -> (t, []))
  | Health_loaded { health; file; now } -> (
      match t.phase with
      | Chat chat ->
          ({ t with phase = Chat (apply_health ~now ~health ~file chat) }, [])
      | Prelude -> (t, []))
  | Frame_tick dt ->
      let accum = t.frame_accum +. Float.min dt frame_interval in
      if accum >= frame_interval then
        ( {
            t with
            motion = Home.Motion.tick t.motion;
            frame_accum = accum -. frame_interval;
          },
          [] )
      else ({ t with frame_accum = accum }, [])
  | Resized { cols; rows } ->
      (* Recompute the side panel's presence with the width hysteresis — the one
         place it changes (doc/plans/tui-next-side-panel.md §App-wiring). *)
      ( { t with cols; rows; pane_open = Pane.presence ~cols ~was:t.pane_open },
        [] )
  | Ctrl_c -> (
      (* Ctrl+C is the quit chord — with one exception: while a browser /
         device login flow is waiting, the abort a user means is the flow's,
         not the app's, so the first press cancels the flow exactly as esc
         does and the chord regains its quit meaning once no flow is live.
         Esc otherwise owns interrupt (see the esc ladder in [interrupt_rung]
         and [Escape]). *)
      let auth_flow_cancel =
        match t.surface with
        | Panel (Auth panel) -> Auth_panel.cancel_active panel
        | Conversing | Panel (Session_switch _ | Model _ | Dialog _) | Screen _
          ->
            None
      in
      match auth_flow_cancel with
      | Some (panel, event) -> interpret_auth_event panel event t
      | None -> (
          if
            (* A non-empty draft discards to history in one press
               (03-composer.md §Keybindings); otherwise, in every phase and
               turn state — home, chat idle, mid-turn, mid-Interrupting, or
               with a panel up — the first press arms the exit notice and a
               second within the window quits. The quit chord must always
               reach [Quit]: no turn state diverts it. *)
            not (Composer.is_blank t.composer)
          then
            (* Fold the discard's events: [Draft_saved] carries the JSONL
               persistence, exactly as the esc-clear rung does. *)
            let composer, events =
              Composer.update Composer.Clear_to_history t.composer
            in
            List.fold_left
              (fun (t, commands) event ->
                let t, more = composer_event event t in
                (t, commands @ more))
              ({ t with composer; armed = None }, [])
              events
          else
            match t.armed with
            | Some Quit_armed -> ({ t with armed = None }, [ Quit ])
            | Some Clear_armed | Some Interrupt_armed | None ->
                ({ t with armed = Some Quit_armed }, [])))
  | Armed_expired -> ({ t with armed = None }, [])
  | Shift_tab ->
      (* Cycle the approval posture (04-header-footer.md §4): the pill is the
         readout; the gate itself bites when the dialogs wave lands. *)
      let posture =
        match t.posture with
        | Footer.Ask -> Footer.Accept_edits
        | Footer.Accept_edits -> Footer.Never_ask
        | Footer.Never_ask -> Footer.Ask
      in
      ({ t with posture }, [])
  | Shell_finished block -> (
      (* The shell result settles as one durable tool block; the turn boundary
         then drains the queue exactly as a finished turn does (03-composer.md
         §Queued prompts). *)
      let t = { t with shell = None } in
      match t.phase with
      | Prelude -> (t, [])
      | Chat chat -> (
          let chat =
            {
              chat with
              transcript =
                Transcript.append chat.transcript (Transcript.Tool block);
            }
          in
          let t = { t with phase = Chat chat } in
          match t.queued with
          | [] -> (t, [])
          | next :: queued -> submit_text next { t with queued }))

(* The one composer element both geometries share (03-composer.md §Home
   screen): the home stage insets it at [Home.composer_width] and owns its
   vertical rhythm (zero top margin); chat spans the full width with the
   frame's own one-row margin. The component is geometry-agnostic; the frame
   wears the declared mode (03-composer.md §Mode-colored frame). *)
let composer_element ?placeholder ~width ~top_margin t =
  let turn_running =
    match t.phase with
    | Chat chat -> Turn.in_flight chat.turn
    | Prelude -> false
  in
  let mode =
    match t.mode with
    | Spice_protocol.Mode.Build -> Composer.Build
    | Spice_protocol.Mode.Plan -> Composer.Plan
    | Spice_protocol.Mode.Review -> Composer.Review
  in
  Composer.render ?placeholder ~turn_running ~top_margin ~width ~mode
    ~list_open:(completion_open t)
    ~on_msg:(fun m -> Composer_msg m)
    t.composer

(* The open completion's rows, rendered directly above the composer's top rule
   (zero gap — the frame's own top margin collapses while one is up). *)
let completion_rows ~width t =
  match t.completion with
  | No_completion -> []
  | Commands palette -> [ Palette.view ~width palette ]
  | Mention mention -> [ Mention.view ~width mention ]
  | History_search { search; saved = _ } ->
      [ History.Search.view ~width search ]

(* The composer region: the completion rows over the frame, one element so both
   geometries place them together. [top_margin] is the frame's idle breathing
   row — 1 in chat, 0 on the home stage (which owns its own rhythm) — and
   collapses to 0 whenever completion rows sit directly above (03-composer.md
   §Overlap). *)
let composer_region ?placeholder ~width ~top_margin t =
  let top_margin = if completion_open t then 0 else top_margin in
  box ~key:"composer.region" ~flex_direction:Flex_direction.Column
    ~flex_shrink:0.
    ~size:{ width = pct 100; height = auto }
    (completion_rows ~width t
    @ [ composer_element ?placeholder ~width ~top_margin t ])

(* The shortcuts sheet renders between the composer region and the footer while
   toggled ("?" — 03-composer.md §Keybindings); "?" or esc closes it. *)
let help_sheet t = if t.help then [ Help.view Help.sections ] else []

(* The dune health drives the footer glyph and its ✓/✗ verdict. In chat it is
   the live value the health poll watches; at the home it is the brief's,
   Disconnected until the first brief load — the honest at-launch state. *)
let dune t =
  match t.phase with
  | Chat chat -> chat.health
  | Prelude -> (
      match t.brief with
      | Some brief -> brief.Home.Brief.dune
      | None -> Spice_ocaml_dune.Rpc.Instance.Health.Disconnected)

(* The logged-out nudge state, sourced from the live brief so it clears within a
   tick of a [/login] while the home is up (12-home.md §States). After the drop
   the brief holds its last value; a user who has started a turn is connected, so
   the frozen [false] is honest. [None] before the first load reads as connected —
   the nudge never flashes on during startup. *)
let account_absent t =
  match t.brief with
  | Some brief -> brief.Home.Brief.account_absent
  | None -> false

(* A transient footer notice takes over the whole row for its lifetime (the
   ctrl+c disarm prompt, or the honest resume placeholder), otherwise the idle
   footer renders. *)
let notice_row style text_ =
  box ~key:"footer" ~flex_shrink:0. ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [ text ~style ~wrap:`None text_ ]

(* The app's transient notice row when one is up: the armed two-stage chord
   prompt or a flash. It renders on the footer in chat/home; a screen suppresses
   the footer, so {!screen_view} overlays this on the screen's bottom row instead
   (doc/plans/tui-next-review.md Appendix D). [None] means no notice is pending. *)
let app_notice t =
  match t.armed with
  | Some Quit_armed -> Some (notice_row Theme.warning ctrl_c_exit_notice)
  | Some Clear_armed -> Some (notice_row Theme.warning esc_clear_notice)
  | Some Interrupt_armed -> Some (notice_row Theme.warning interrupt_notice)
  | None -> Option.map (notice_row Theme.muted) t.flash

let footer t =
  match app_notice t with
  | Some notice -> notice
  | None ->
      (* The composer's input mode plants its badge and key hints on the footer
         (03-ia-screens-overlays.md §Composer input modes). *)
      let input_mode =
        match Composer.input_mode t.composer with
        | Composer.Input_mode.Plain -> None
        | Composer.Input_mode.Shell -> Some Footer.Shell
        | Composer.Input_mode.History_search -> Some Footer.History_search
      in
      Footer.view ~posture:t.posture ?input_mode ?agents:(agents_active t)
        ~account_absent:(account_absent t) t.snapshot ~dune:(dune t)
        ~width:t.cols

(* The home stage above the surface region. [composer] is [None] while a panel
   is up — the inset composer is hidden (its draft preserved on the model), the
   panel takes the region below (doc/plans/tui-next-surfaces.md §Panel geometry).
*)
let stage ~composer t =
  Home.stage ~snapshot:t.snapshot ~brief:t.brief ~notice:t.notice
    ~motion:t.motion ~composer ~width:t.cols ~rows:t.rows

let prelude_view t =
  [
    stage
      ~composer:
        (Some
           (composer_region ~width:(Home.composer_width t.cols) ~top_margin:0 t))
      t;
  ]
  @ help_sheet t
  @ [ footer t ]

(* The chat layout after the drop (12-home.md §Transition): one scrollport
   holding the banner record (its first block), the settled document, the live
   turn tail, and the working line — everything scrolls together, with no sticky
   header (04-header-footer.md §Purpose). Below it hang the shared composer and
   footer; the footer is the same [footer t] the prelude renders, so the row is
   byte-identical across the drop. *)
let blank_row = box ~size:{ width = pct 100; height = px 1 } []

(* The transcript region above the surface: one scrollport with the banner-headed
   document, then the live tail and the working line flowing after it. Both the
   composer+footer (Conversing) and the panel block hang below it. *)
(* An item that keeps the board on screen: pending or in progress. Completed and
   cancelled are terminal (02-tools.md §Todo block, revised 2026-07-08). *)
let board_has_open todo =
  List.exists
    (fun it ->
      match Spice_protocol.Todo.Item.status it with
      | Spice_protocol.Todo.Status.Pending
      | Spice_protocol.Todo.Status.In_progress ->
          true
      | Spice_protocol.Todo.Status.Completed
      | Spice_protocol.Todo.Status.Cancelled ->
          false)
    (Spice_protocol.Todo.items todo)

(* The wide-terminal side panel's live tenant (doc/plans/tui-next-side-panel.md):
   the todo board while it has open work, else the idle workspace glance.
   [active_board] is the single visibility source, shared with the strip-region
   mount in [chat_view] so the board renders in exactly one region — the pane when
   [pane_open], the strip otherwise (the double-render law). It reads the retained
   [chat.board] and renders while any item is non-terminal, so a board with open
   work stays visible between turns after the turn settles (02-tools.md §Todo
   block, revised 2026-07-08); an all-terminal board leaves. *)
let active_board chat =
  match chat.board with
  | Some todo when board_has_open todo -> Some todo
  | _ -> None

(* The modeled clock as a session time, so the switcher rows read a live elapsed
   off the same [now] the working line does (the view keeps no clock of its own,
   app.ml §chat [now]). *)
let now_of chat = Spice_session.Time.of_unix_seconds_float chat.now

(* One switcher row from a run record, its facts in the row grammar (§2.1: glyph ·
   name · task · elapsed · ↓ tokens). [elapsed] is live off the modeled clock
   [now] while the run is running or blocked and off the terminal timestamp once
   settled. [↓ tokens] renders only once the run carries a usage record — a
   running child has none (Subagent_run.usage is terminal-only by protocol), so
   its live token count waits on the progress ticker (a recorded gap, §4.3);
   until then a running row still shows its elapsed. *)
let thread_row_of ~now run =
  let status = Thread_view.of_run run in
  let facts =
    Option.to_list (Thread_view.elapsed ~now run)
    @
    match Spice_protocol.Subagent_run.usage run with
    | Some usage -> [ Thread_view.tokens usage ]
    | None -> []
  in
  Threads_strip.Thread
    {
      glyph = Thread_view.glyph status;
      style = Thread_view.style status;
      name = Thread_view.role_label (Spice_protocol.Subagent_run.role run);
      task =
        Thread_view.compact
          (Spice_protocol.Subagent.Spawn.task
             (Spice_protocol.Subagent_run.spawn run));
      facts;
      depth = 0;
      last = true;
    }

(* The switcher rows in display order — [Main] first, then the child runs
   live-first — or [] when the session has spawned no children. Shared by the
   below-footer strip and the wide-terminal pane tenant so the two never diverge
   (the double-render law routes the same rows to exactly one region). *)
let threads_rows ~now t =
  match t.thread_runs with
  | [] -> []
  | _ -> Threads_strip.Main :: List.map (thread_row_of ~now) (ordered_runs t)

(* Render the switcher at a given width and row budget. [can_open] gates the
   selected row's [enter to open] hint on whether that row is a SETTLED child —
   the only kind drill-in opens for now (the honest-hint rule): a running row
   selected shows no hint, a settled one does. *)
(* A click selects+switches (the [↵] action) and a move highlights; a wheel
   returns [None] so it bubbles to the transcript (the wheel-always-scrolls law).
   [index] is the absolute switcher-row index. *)
let strip_mouse index ev =
  match Mosaic.Event.Mouse.kind ev with
  | Mosaic.Event.Mouse.Down { button = Mosaic.Event.Mouse.Left; _ } ->
      Some (Thread_strip_clicked index)
  | Mosaic.Event.Mouse.Move -> Some (Thread_strip_hovered (Some index))
  | _ -> None

let threads_strip_render ~now ~width ~rows_avail t =
  match threads_rows ~now t with
  | [] -> []
  | rows ->
      let can_open =
        match selected_run t with
        | Some run -> thread_openable run
        | None -> false
      in
      Threads_strip.view ~can_open ~on_mouse:strip_mouse ~hovered:t.strip_hover
        ~rows ~selected:t.strip_focus ~width ~rows_avail ()

(* The [agents] section header's live count facts: running and blocked children,
   each shown only when non-zero ([agents · 1 running · 1 blocked]). Exhaustive
   over the thread status so a new one has to be placed here, not silently
   dropped. *)
let agents_facts t =
  let running, blocked =
    List.fold_left
      (fun (r, b) run ->
        match Thread_view.of_run run with
        | Thread_view.Running -> (r + 1, b)
        | Thread_view.Blocked -> (r, b + 1)
        | Thread_view.Queued | Thread_view.Completed | Thread_view.Failed
        | Thread_view.Interrupted ->
            (r, b))
      (0, 0) t.thread_runs
  in
  (if running > 0 then [ Printf.sprintf "%d running" running ] else [])
  @ if blocked > 0 then [ Printf.sprintf "%d blocked" blocked ] else []

(* The [tasks] section header's count facts — [tasks · 2 done · 1 running] — which
   the board no longer carries in the pane (its [~count_header:false] path), so the
   header is the one place the counts read. The same done/running projection the
   settled block's [⏺ Todo(…)] header shows. *)
let task_facts todo =
  let items = Spice_protocol.Todo.items todo in
  let is s it =
    Spice_protocol.Todo.Status.equal (Spice_protocol.Todo.Item.status it) s
  in
  let count p = List.length (List.filter p items) in
  let done_count =
    count (fun it ->
        is Spice_protocol.Todo.Status.Completed it
        || is Spice_protocol.Todo.Status.Cancelled it)
  in
  let running_count = count (is Spice_protocol.Todo.Status.In_progress) in
  [
    Printf.sprintf "%d done" done_count;
    Printf.sprintf "%d running" running_count;
  ]

let pane_right ~now t chat =
  if not t.pane_open then []
  else
    let width = Pane.content_width ~cols:t.cols
    and max_rows = Pane.content_rows ~rows:t.rows in
    (* The wide pane is a stacked, named-section dashboard (Pane_sections;
       doc/plans/tui-next-side-panel.md §Sections): workspace state is ambient —
       always present — while the agents switcher and the todo board stack under
       their own headers. This supersedes the former one-tenant XOR, where a todo
       turn's board replaced the workspace glance (Thibaut 2026-07-08). Order:
       workspace (ambient, top) → agents → tasks. Each tenant's below-footer/strip
       mount stays gated on [pane_open], so it renders in exactly one region (the
       double-render law). *)
    let workspace_section =
      match t.brief with
      | Some brief ->
          Some
            (Pane_sections.section ~label:"workspace" ~ambient:true
               (fun ~max_rows -> Workspace_glance.view ~width ~max_rows brief))
      | None -> None
    in
    (* The switcher rows carry the pane's two-column indent under the [agents]
       header so they align with the other sections. [Threads_strip.view] draws
       flush full-width rows (its below-footer home), so the pane indents each here
       and truncates to the reduced width — the section contract's row indent, held
       at the pane seam until the switcher grows a native pane form (strip-ux). *)
    let agents_section =
      match threads_rows ~now t with
      | [] -> None
      | rows ->
          Some
            (Pane_sections.section ~label:"agents" ~facts:(agents_facts t)
               (fun ~max_rows ->
                 Threads_strip.view ~can_open:false ~rows
                   ~selected:t.strip_focus
                   ~width:(max 1 (width - 2))
                   ~rows_avail:max_rows ()
                 |> List.map (fun row ->
                     box ~padding:(padding_lrtb 2 0 0 0) [ row ])))
    in
    let tasks_section =
      match active_board chat with
      | Some todo ->
          Some
            (Pane_sections.section ~label:"tasks" ~facts:(task_facts todo)
               (fun ~max_rows ->
                 Todo_board.view ~count_header:false ~width ~max_rows todo))
      | None -> None
    in
    Pane_sections.view ~width ~max_rows
      (List.filter_map Fun.id
         [ workspace_section; agents_section; tasks_section ])

let chat_above t chat ~right =
  (* The transcript is fluid (doc/plans/tui-next-side-panel.md): it renders at the
     reduced column when the pane is open, full width otherwise — never a cap. *)
  let width = Pane.transcript_width ~cols:t.cols ~open_:t.pane_open in
  let now = chat.now and spinner = chat.spinner in
  let document =
    Transcript.view ~expanded:chat.expanded ~width chat.transcript
  in
  let tail =
    Turn.tail ~now ~spinner ~width ~show_reasoning:t.show_reasoning
      ~expanded:chat.expanded chat.turn
  in
  let working = Turn.working_line ~now ~spinner chat.turn in
  (* The live parts flow after the settled document inside the scrollport
     (01-transcript.md §The working line): the tail, then the ephemeral working
     line, each separated from what precedes it by the one-blank law. A fresh
     document (banner only) self-separates through the banner's own bottom margin,
     so no blank precedes the tail there — [Transcript.is_fresh] holds it honest.
     On settle both go [None] and the scrollport holds the document alone; the
     working line never enters scrollback. *)
  let leading_gap =
    if Transcript.is_fresh chat.transcript then [] else [ blank_row ]
  in
  let live =
    match List.filter_map Fun.id [ tail; working ] with
    | [] -> []
    | first :: rest ->
        leading_gap
        @ (first :: List.concat_map (fun el -> [ blank_row; el ]) rest)
  in
  let scrollport =
    Scrollport.view
      ?reveal:
        (Option.map
           (fun (serial, y) ->
             {
               Mosaic.Scroll_box.key = "transcript-page-" ^ string_of_int serial;
               x = None;
               y = Some y;
               align_x = `Nearest;
               align_y = `Start;
               margin = 0;
             })
           chat.reveal)
      ~on_scroll:(fun ~x:_ ~y -> Some (Transcript_scrolled y))
      (document :: live)
  in
  (* The pane opens right of a │ rule when [pane_open] holds; [right] is the live
     tenant. Closed, [Pane.frame] returns the scrollport alone, byte-identical to
     the one-column layout. *)
  [ Pane.frame ~cols:t.cols ~open_:t.pane_open ~left:scrollport ~right ]

(* The running user shell pins its header above the composer while the command
   executes (03-composer.md §Shell mode): the ephemeral counterpart of the
   settled block the result appends — the one steady accent dot on screen. *)
let shell_running_row t =
  match t.shell with
  | None -> []
  | Some command ->
      [
        Tool_block.header Tool_block.Shell ~argument:command
          ~dot:Tool_block.Running;
      ]

(* The threads switcher strip below the footer (doc/plans/tui-next-threads.md
   §2.6): [main] first, then the child runs live-first, drawn as the unfocused
   3-row glance or — once [↓] engages [strip_focus] — the windowed browse. A
   blank spacer row separates it from the footer above (§2.2). While the wide
   side pane is open the switcher is absorbed into it as the top tenant
   ([pane_right]), so this below-footer mount is gated off then — the strip
   renders in exactly one region (the double-render law). Empty (so no region)
   while the session has spawned no children; a settled run's row stays until the
   unread model lands (a recorded follow-up). *)
let threads_strip_view ~now t =
  if t.pane_open then []
  else
    let rows_avail = max 3 (min 8 (t.rows - 12)) in
    match threads_strip_render ~now ~width:t.cols ~rows_avail t with
    | [] -> []
    | rows -> blank_row :: rows

(* The status strip sits between the transcript region and the composer frame
   (01-transcript.md §The status strip): the ctrl+o verbose lens announcement and
   one row per queued prompt, absent when neither holds. It is the composer's
   margin, so a present strip collapses the frame's idle breathing row to 0
   (03-composer.md §Overlap), the same rule completion rows and the running
   shell header follow. *)
(* The heap banner naming a drilled-in thread (03-ia §Agent threads §7c): the
   agent handle and its task, then a muted [started by main] line — the
   child-focused replacement for the parent's session banner. Chrome owned here
   (not banner.ml, the transcript workstream's), since it names an agent, not a
   session; [▂▄▆▄▂] is the brand heap motif the home stage draws. *)
let thread_banner t id =
  let handle, task =
    match drilled_run t id with
    | Some run ->
        ( "@"
          ^ Spice_protocol.Subagent.Role.to_string
              (Spice_protocol.Subagent_run.role run),
          Thread_view.compact
            (Spice_protocol.Subagent.Spawn.task
               (Spice_protocol.Subagent_run.spawn run)) )
    | None -> ("@agent", "")
  in
  let title =
    "▂▄▆▄▂ " ^ handle
    ^
    if task = "" then ""
    else " — " ^ Thread_view.clip ~max:(max 8 (t.cols - 14)) task
  in
  box ~key:"thread.banner" ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~padding:(padding_lrtb 2 2 1 0)
    ~size:{ width = pct 100; height = auto }
    [
      Mosaic.text ~style:Theme.accent ~wrap:`None title;
      Mosaic.text ~style:Theme.muted ~wrap:`None "started by main";
    ]

(* The drilled-in thread's footer: the app notice while armed, else the idle row
   claiming its right slot for the way-home badge ([⏴ @role · esc for main]). *)
let thread_footer t id =
  match app_notice t with
  | Some notice -> notice
  | None ->
      let handle =
        match drilled_run t id with
        | Some run ->
            "@"
            ^ Spice_protocol.Subagent.Role.to_string
                (Spice_protocol.Subagent_run.role run)
        | None -> "@agent"
      in
      Footer.view ~posture:t.posture ?agents:(agents_active t)
        ~home_badge:("⏴ " ^ handle ^ " · esc for main")
        ~account_absent:(account_absent t) t.snapshot ~dune:(dune t)
        ~width:t.cols

(* The read-only drilled-in thread (doc/plans/tui-next-threads.md §2.3, §6 phase
   5a): the thread banner, the child's replayed transcript in its own scrollport
   (the wheel scrolls it, the scroll box's own handling), and the way-home footer.
   No composer — composing into a thread is deferred, so the view is read-only;
   [esc] returns to the parent chat ([Thread_home]). *)
let thread_drill_view t id tchat =
  let document = Transcript.view ~width:t.cols tchat.transcript in
  let scrollport = Scrollport.view ~key:"thread.scrollport" [ document ] in
  [ thread_banner t id; scrollport; thread_footer t id ]

let chat_view t chat =
  (* The live todo board mirrors the current turn's list while it is in flight
     (02-tools.md §Todo block, strip mirror), bounded by its [┈] rule at the top
     of the strip region. Visibility is the data ([active_board]): [Turn.todo_board]
     is [Some] with items only during a turn that has written todos, and clears on
     settle. The row budget reserves the composer, footer, and the [┈] rule. At
     ≥110 cols the wide-terminal side panel hosts this same tenant
     ([pane_right] carries [active_board] into the pane), so the strip mount is
     gated off when [pane_open] — the double-render law
     (doc/plans/tui-next-side-panel.md §IP4). *)
  let board =
    if t.pane_open then []
    else
      match active_board chat with
      | Some todo ->
          let max_rows = max 1 (min 8 (t.rows - 11)) in
          Todo_board.strip_rule ~width:t.cols
          :: Todo_board.view ~width:t.cols ~max_rows todo
      | None -> []
  in
  let strip =
    Strip.view ~width:t.cols ~verbose:chat.expanded ~queued:t.queued
  in
  let shell = shell_running_row t in
  let top_margin = if board = [] && strip = [] && shell = [] then 1 else 0 in
  let now = now_of chat in
  chat_above t chat ~right:(pane_right ~now t chat)
  @ board @ shell @ strip
  @ [ composer_region ~width:t.cols ~top_margin t ]
  @ help_sheet t
  @ [ footer t ]
  @ threads_strip_view ~now t

(* One panel geometry everywhere (doc/plans/tui-next-surfaces.md §Panel
   geometry): the panel block is bottom-anchored where the composer and footer
   were — under the home stage (composer hidden) in the prelude, and under the
   transcript region in chat. *)
let surface_view t panel =
  let block =
    match panel with
    | Session_switch panel ->
        Sessions_panel.view ~frame:Theme.color_rule ~width:t.cols panel
    | Model { panel_state; _ } ->
        Model_panel.view ~frame:Theme.color_rule ~width:t.cols ~rows:t.rows
          panel_state
    | Auth panel ->
        Auth_panel.view ~frame:Theme.color_rule ~width:t.cols ~rows:t.rows panel
    | Dialog dialog -> (
        match t.borrow with
        (* Borrowed: the option list collapses to a one-line record and the real
           composer returns with the scoped placeholder (07-dialogs §Deny with
           feedback). *)
        | For_answer { placeholder; _ } ->
            box ~key:"dialog.borrow" ~flex_direction:Flex_direction.Column
              ~flex_shrink:0.
              ~size:{ width = pct 100; height = auto }
              [
                box ~padding:(padding_lrtb 2 2 0 0) ~flex_shrink:0.
                  [
                    Mosaic.text ~style:Theme.accent ~wrap:`Word
                      (Dialog.borrow_summary dialog);
                  ];
                composer_region ~placeholder ~width:t.cols ~top_margin:1 t;
              ]
        | Free -> Dialog.view ~width:t.cols dialog)
  in
  (* The panel takes its natural height pinned to the bottom; the transcript
     region above it grows to fill (03-ia §Dialogs, the parked working line stays
     visible). Pinning the block in a non-growing, non-shrinking box keeps its
     [height:auto] content from stretching to the full height when it is the
     scrollport's flex sibling. *)
  let pinned =
    box ~key:"surface.block" ~flex_grow:0. ~flex_shrink:0.
      ~size:{ width = pct 100; height = auto }
      [ block ]
  in
  match t.phase with
  | Prelude -> [ stage ~composer:None t; pinned ]
  | Chat chat ->
      (* Wrap the transcript in a grow:1 region so it fills the space above the
         pinned panel regardless of the scrollport's own flex. *)
      [
        box ~key:"surface.transcript" ~flex_grow:1. ~flex_shrink:1.
          ~size:{ width = pct 100; height = px 0 }
          (chat_above t chat ~right:(pane_right ~now:(now_of chat) t chat));
        pinned;
      ]

(* A screen owns the whole region — no stage, transcript, composer, or footer
   beneath it (03-ia §The three forms). It fills the height so its hint row sits
   at the bottom. *)
let screen_view t screen =
  let content =
    match screen with
    | Sessions screen ->
        Sessions_screen.view ~frame:Theme.color_rule ~width:t.cols ~rows:t.rows
          screen
    | Settings screen ->
        Settings_screen.view ~frame:Theme.color_rule ~width:t.cols ~rows:t.rows
          screen
    | Review review ->
        (* The review screen owns the whole region and draws its own frame (top
           rule, two-pane split, bottom legend), so it does not go through
           {!Screen.view}'s shared chrome (doc/plans/tui-next-review.md §3.1). *)
        Spice_tui_review.view ~width:t.cols ~height:t.rows
          ~inject:(fun m -> Review_msg m)
          review
  in
  let fill =
    box ~key:"screen.fill" ~flex_direction:Flex_direction.Column
      ~size:{ width = pct 100; height = pct 100 }
      [ content ]
  in
  (* A screen owns the whole region and suppresses the app footer, so the
     transient app notice (the ctrl+c arm prompt, a flash) has no home there;
     overlay it on the bottom row so ctrl+c-arm and flashes stay honest on
     screens as they are in chat. Absolutely positioned with an explicit inset and
     fixed height (the sanctioned abspos shape) so the screen does not re-layout
     while armed; it covers the screen's own bottom row for the notice's lifetime,
     exactly as the footer notice takes over the footer row
     (doc/plans/tui-next-review.md Appendix D). The row carries {!Theme.color_overlay}
     so it is opaque across its full width: the notice text has transparent gaps
     between its words, and a screen draws its own hint row underneath, so without
     an opaque backdrop the hint bleeds through those gaps. *)
  match app_notice t with
  | None -> [ fill ]
  | Some notice ->
      [
        fill;
        box ~key:"screen.notice" ~position:Position.Absolute
          ~inset:(inset_lrtb 0 0 (t.rows - 1) 0)
          ~size:{ width = pct 100; height = px 1 }
          ~background:Theme.color_overlay ~z_index:10 [ notice ];
      ]

(* Route wheel input from anywhere in the app to the transcript (01-transcript.md
   §Seam replay, scroll, spacing: the wheel always scrolls the transcript). The
   scrollport stops propagation of the wheel it consumes, so this root-level
   handler — an ancestor in the element tree — sees only the dead zones the
   transcript does not cover: the composer, the footer, panel chrome. A [Sub]
   mouse handler cannot serve here: [Sub.on_mouse_all] ignores propagation
   outright, and [Sub.on_mouse] keys off [prevent_default], neither of which the
   scrollport's [stop_propagation] trips (mosaic [handle_mouse]) — either would
   double-count a wheel over the transcript. Chat-only: the prelude has nothing
   to scroll. *)
let wheel_to_transcript t =
  match t.phase with
  | Prelude -> None
  | Chat _ ->
      Some
        (fun ev ->
          match Mosaic.Event.Mouse.kind ev with
          | Mosaic.Event.Mouse.Scroll
              { direction = Mosaic.Event.Mouse.Scroll_up; delta } ->
              Some (Transcript_wheeled (`Up, delta))
          | Mosaic.Event.Mouse.Scroll
              { direction = Mosaic.Event.Mouse.Scroll_down; delta } ->
              Some (Transcript_wheeled (`Down, delta))
          | _ -> None)

(* The terminal window title (OSC): the workspace root's leaf, [✳] idle and an
   alternating braille tick while a turn streams — the tab names the workspace
   and telegraphs work at a glance, as the old TUI's title did. The spinner
   counter (the ~1s turn tick) drives the alternation. *)
let terminal_title t =
  let leaf =
    Filename.basename (Spice_path.Abs.to_string t.snapshot.Snapshot.cwd)
  in
  match t.phase with
  | Chat chat when Turn.in_flight chat.turn ->
      (if chat.spinner mod 2 = 0 then "⠂ " else "⠐ ") ^ leaf
  | Chat _ | Prelude -> "✳ " ^ leaf

let view t =
  let children =
    match t.surface with
    | Panel panel -> surface_view t panel
    | Screen screen -> screen_view t screen
    | Conversing -> (
        match t.phase with
        | Prelude -> prelude_view t
        | Chat chat -> (
            (* A drilled-in thread re-points the shell at the child's read-only
               conversation (doc/plans/tui-next-threads.md §2.3); esc returns. *)
            match t.drill with
            | Some (id, tchat) -> thread_drill_view t id tchat
            | None -> chat_view t chat))
  in
  box ~key:"shell" ~flex_direction:Flex_direction.Column
    ?on_mouse:(wheel_to_transcript t)
    ~size:{ width = pct 100; height = px t.rows }
    children

(* Key routing (doc/plans/tui-next-surfaces.md §Key routing): Ctrl+C always
   arms/quits. When a panel is up it is modal below the boundary — every key goes
   to its key handler and unclaimed keys die there, so the shell's own chords and
   the composer never see them. Otherwise (Conversing) today's routing holds: in
   chat, ctrl+o toggles the expand lens and esc interrupts an in-flight turn;
   everything else — typing, Enter, composer completions — flows to the composer,
   which owns the keyboard. *)
let key_msg t ev =
  let data = Mosaic.Event.Key.data ev in
  let open Matrix.Input in
  let ctrl c =
    data.Key.modifier.Modifier.ctrl
    &&
    match data.Key.key with
    | Key.Char u -> Uchar.equal u (Uchar.of_char c)
    | _ -> false
  in
  let is_escape = match data.Key.key with Key.Escape -> true | _ -> false in
  let is_page_up = match data.Key.key with Key.Page_up -> true | _ -> false in
  let is_page_down =
    match data.Key.key with Key.Page_down -> true | _ -> false
  in
  let in_chat = match t.phase with Chat _ -> true | Prelude -> false in
  let emit m =
    Mosaic.Event.Key.prevent_default ev;
    Some m
  in
  if ctrl 'c' then emit Ctrl_c
  else
    match t.surface with
    | Panel (Session_switch _) ->
        (* Modal: the panel owns the keyboard. Prevent default on every key so a
           claimed key stops here and an unclaimed one simply dies. *)
        Mosaic.Event.Key.prevent_default ev;
        Option.map (fun m -> Panel_msg m) (Sessions_panel.key data)
    | Panel (Model _) ->
        Mosaic.Event.Key.prevent_default ev;
        Option.map (fun m -> Model_panel_msg m) (Model_panel.key data)
    | Panel (Auth _) ->
        Mosaic.Event.Key.prevent_default ev;
        Option.map (fun m -> Auth_panel_msg m) (Auth_panel.key data)
    | Panel (Dialog _) -> (
        (* While the composer is borrowed the composer owns typing; esc steps
           back to the option list. Otherwise the dialog is modal: every key
           goes to it (prevented so unclaimed keys die below the boundary). *)
        match t.borrow with
        | For_answer _ -> if is_escape then emit Cancel_borrow else None
        | Free -> emit (Dialog_key data))
    | Screen (Sessions _) ->
        (* A screen owns its keyboard wholly (03-ia §Key routing): prevent
           default on every key so a claimed key stops here and an unclaimed one
           dies, never reaching the composer beneath. *)
        Mosaic.Event.Key.prevent_default ev;
        Option.map (fun m -> Screen_msg m) (Sessions_screen.key data)
    | Screen (Settings _) ->
        Mosaic.Event.Key.prevent_default ev;
        Option.map (fun m -> Settings_msg m) (Settings_screen.key data)
    | Screen (Review review) ->
        (* The review screen owns its keyboard wholly (uniform [msg option]
           contract, doc/plans/tui-next-review.md §3.2). ctrl+c is already
           handled above as the global quit chord, so the screen never sees it;
           an unclaimed key returns [None] and dies here. *)
        Mosaic.Event.Key.prevent_default ev;
        Option.map (fun m -> Review_msg m) (Spice_tui_review.key review data)
    | Conversing ->
        let is_shift_tab =
          match data.Key.key with
          | Key.Tab -> data.Key.modifier.Modifier.shift
          | _ -> false
        in
        if in_chat && ctrl 'o' then emit Toggle_expanded
        else if ctrl 'r' && not (completion_open t) then emit Ctrl_r
        else if is_shift_tab && not (completion_open t) then emit Shift_tab
        else if is_escape then emit Escape
        else if in_chat && is_page_up then emit (Transcript_paged `Up)
        else if in_chat && is_page_down then emit (Transcript_paged `Down)
        else None

let subscriptions t =
  let prelude = match t.phase with Prelude -> true | Chat _ -> false in
  let turn_running =
    match t.phase with
    | Chat chat -> Turn.in_flight chat.turn
    | Prelude -> false
  in
  Mosaic.Sub.batch
    [
      Mosaic.Sub.on_key_all (key_msg t);
      Mosaic.Sub.on_resize (fun ~width ~height ->
          Resized { cols = width; rows = height });
      (if prelude then Mosaic.Sub.every brief_interval (fun () -> Brief_tick)
       else Mosaic.Sub.none);
      (* IP6 (doc/plans/tui-next-side-panel.md): while the side panel shows the
         idle workspace glance in chat — pane open and no turn streaming — keep the
         brief refreshing so its facts stay live. It pauses while a turn streams (a
         tenant replaces the glance then) and when the pane is closed (nothing
         reads the brief); the prelude arm above owns the home stage's cadence. *)
      (if (not prelude) && t.pane_open && not turn_running then
         Mosaic.Sub.every brief_interval (fun () -> Brief_tick)
       else Mosaic.Sub.none);
      (if prelude && Home.Motion.animating t.motion then
         Mosaic.Sub.on_tick (fun ~dt -> Frame_tick dt)
       else Mosaic.Sub.none);
      (* The spinner/elapsed tick runs only while a chat turn is in flight,
         mirroring the prelude frame gate; it stops the instant the turn settles.
      *)
      (if turn_running then
         Mosaic.Sub.every turn_tick_interval (fun () -> Turn_tick)
       else Mosaic.Sub.none);
      (* The Dune health poll runs across the whole chat phase, not only while a
         turn is in flight: an edit's build can break or heal after the turn
         settles (the workspace's own [dune build --watch] keeps compiling), and
         the footer and its transitions must track that. It stops at the home,
         where the brief tick already carries dune health. *)
      (match t.phase with
      | Chat _ -> Mosaic.Sub.every health_interval (fun () -> Health_tick)
      | Prelude -> Mosaic.Sub.none);
      (match t.armed with
      | Some Quit_armed ->
          Mosaic.Sub.every quit_notice_timeout (fun () -> Armed_expired)
      | Some Clear_armed ->
          Mosaic.Sub.every clear_notice_timeout (fun () -> Armed_expired)
      | Some Interrupt_armed ->
          Mosaic.Sub.every interrupt_notice_timeout (fun () -> Armed_expired)
      | None -> Mosaic.Sub.none);
      (if t.flash <> None then
         Mosaic.Sub.every flash_timeout (fun () -> Flash_expired)
       else Mosaic.Sub.none);
      (* A waiting auth flow ticks its spinner/countdown once a second. *)
      (match t.surface with
      | Panel (Auth panel) when Auth_panel.ticking panel ->
          Mosaic.Sub.every auth_tick_interval (fun () -> Auth_tick)
      | _ -> Mosaic.Sub.none);
      (* Route paste to the masked api-key buffer — the composer widget's own
         [on_paste] is dead while the panel occupies the region, and the secret
         must never reach the draft (09-auth §10 rule 1). *)
      (match t.surface with
      | Panel (Auth panel) when Auth_panel.accepts_paste panel ->
          Mosaic.Sub.on_paste_all (fun ev ->
              Mosaic.Event.Paste.prevent_default ev;
              Some (Auth_paste (Mosaic.Event.Paste.text ev)))
      | _ -> Mosaic.Sub.none);
    ]
