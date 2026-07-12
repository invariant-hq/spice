(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The composer: the two-rule input surface over a structured {!Draft.t}
    (03-composer.md, 03-ia-screens-overlays.md §Composer input modes).

    The composer owns the editing state the shell would otherwise scatter: the
    structured draft, the input mode that recolors the prompt marker, the
    prompt-history walk, and the controlled-textarea bookkeeping that keeps the
    Mosaic widget in step with the draft. It follows the same Elm shape as
    [app.ml]: the view emits {!type-msg} values through [on_msg]; {!update}
    folds a message into new state and a list of {!type-event}s the shell routes
    (a submitted prompt, a discarded draft to persist, a help request).

    The composer, not the shell, owns key routing into the textarea: Mosaic keys
    reach only the focused widget and app-level subscriptions run after the
    widget's default insertion, so the two keys whose default must be suppressed
    — ["?"] on an empty draft (help) and bracketed paste — are intercepted in
    the textarea's own handlers here and surfaced as messages. The shell never
    inspects a raw key the composer can see; it reads draft state through the
    accessors below (e.g. {!active_file_ref_token} for [@]-completion).

    Slash and mention completion lists, the command catalog, prompt-history
    persistence and ctrl+r search, and the mode/agent frame wiring live in later
    waves; this module renders the frame and models the full message surface
    those waves route through. *)

(** {1:modes Input mode} *)

module Input_mode : sig
  (** The composer input mode. [Shell] is explicit state entered by a leading
      ["!"] trigger; the trigger is consumed and is not part of the draft.
      Whenever history search is active it takes precedence over [Shell]. *)
  type t =
    | Plain  (** Ordinary prompt: the [❯] marker in the frame color. *)
    | Shell  (** A shell command: the ["!"] marker in warning. *)
    | History_search
        (** ctrl+r history search is active: the [⌕] marker in the history
            color. Set by {!Begin_history_search} / {!End_history_search}. *)
end

(** The composer frame's mode, which colors both rules and chips the top rule
    (03-composer.md §Mode-colored frame). Mapped from the session mode at the
    call site; [Build] is the default and shows no chip. *)
type mode = Build | Plan | Review

(** {1:state State} *)

type t
(** The type for composer state: a {!Draft.t}, the history walk, whether ctrl+r
    search is active, and the controlled-textarea sync flag. *)

val init : ?draft:string -> unit -> t
(** [init ?draft ()] is a fresh composer. [draft] seeds the visible text (cursor
    at end) and defaults to empty. History is empty until {!with_history}. *)

val draft : t -> Draft.t
(** [draft t] is the structured draft. *)

val draft_text : t -> string
(** [draft_text t] is the visible draft text ([Draft.text (draft t)]). *)

val is_blank : t -> bool
(** [is_blank t] is [true] iff the draft would submit to nothing — the shell's
    test for whether a non-empty draft occupies the esc/ctrl+c ladder. *)

val history_entry : t -> Draft.History_entry.t
(** [history_entry t] is the editable state to persist or restore. Shell
    commands include their leading ["!"] intent marker even though the live
    shell buffer contains only the command. *)

val input_mode : t -> Input_mode.t
(** [input_mode t] is the current input mode (see {!Input_mode.t}). *)

val active_file_ref_token : t -> string option
(** [active_file_ref_token t] is the [@]-token being edited at the cursor — the
    nearest [@] before the cursor with no whitespace between, [@] included — or
    [None]. The shell derives whether the [@]-completion list is open from this;
    it is one visibility truth, not a duplicated key parse. *)

val with_history : Draft.History_entry.t list -> t -> t
(** [with_history entries t] adds loaded prompt-history [entries] (newest first)
    that [t] does not already hold, resetting any in-progress walk. The history
    module (a later wave) owns the JSONL codec and ctrl+r search and feeds
    entries through this seam. *)

(** {1:messages Messages and events} *)

(** The type for composer messages. Most are emitted by {!render}'s textarea
    callbacks ([Edited], [Cursor_moved], [Paste], [Submit], [Help_key]); the
    rest are dispatched by the shell to drive the composer from key routing it
    owns (completion picks, history walk, the esc ladder's draft rungs). *)
type msg =
  | Edited of string
      (** The textarea reported a new full value (keystroke-level). *)
  | Cursor_moved of int
      (** The textarea reported a new cursor grapheme offset. *)
  | Paste of string
      (** A bracketed paste was intercepted; the raw pasted text. *)
  | Submit of string  (** Enter was pressed; the textarea's full value. *)
  | Help_key  (** ["?"] was pressed on an empty draft (default suppressed). *)
  | Complete_file_ref of string
      (** Replace the active [@]-token with a file reference to this path (a
          mention pick). *)
  | Restore_history of Draft.History_entry.t
      (** Load this history entry into the draft (a ctrl+r pick), cursor at end.
          A leading ["!"] restores shell mode and is consumed from the buffer.
      *)
  | History_previous  (** Walk to the previous (older) prompt. *)
  | History_next
      (** Walk to the next (newer) prompt, then the initial draft. *)
  | Begin_history_search
      (** Enter ctrl+r history search (marker becomes [⌕]). *)
  | End_history_search  (** Leave ctrl+r history search. *)
  | Clear_to_history
      (** Discard a non-empty draft, saving it to history so [History_previous]
          recalls it (the esc double-tap and ctrl+c). *)
  | Exit_shell
      (** Leave an empty shell mode. Non-empty shell commands use
          {!Clear_to_history}, like ordinary drafts. *)
  | List_key of [ `Up | `Down | `Tab ]
      (** An arrow or tab the composer intercepted before the widget's default
          for the shell to route: completion-list navigation while a list is
          open ({!render}'s [list_open]), or the prompt-history walk on a
          single-line draft. {!update} treats it as a no-op — its meaning
          belongs to the shell. *)

(** The type for events the shell routes after {!update}. *)
type event =
  | Submitted of { text : string; entry : Draft.History_entry.t }
      (** A non-blank draft was submitted: [text] to send, [entry] to persist.
      *)
  | Shell_submitted of { command : string; entry : Draft.History_entry.t }
      (** A non-blank shell command was submitted. [command] is the exact
          command payload without the mode trigger; [entry] includes the trigger
          so history restores shell mode. *)
  | Blank_submitted
      (** [↵] on a blank draft — nothing to send, the draft is unchanged. The
          shell owns what a blank submit means (the home's ↵-resume, 12-home.md
          §Keybindings). *)
  | Draft_saved of Draft.History_entry.t
      (** A non-empty draft was discarded and should be appended to prompt
          history. *)
  | Help_requested  (** ["?"] on an empty draft toggles the shortcuts sheet. *)

val update : ?submit_enabled:bool -> msg -> t -> t * event list
(** [update ?submit_enabled msg t] folds [msg] into new state and any events.
    [submit_enabled] gates [Submit] (a completion list is up when [false]) and
    defaults to [true]. *)

(** {1:view View} *)

val render :
  ?submit_enabled:bool ->
  ?list_open:bool ->
  ?mode:mode ->
  ?agent:string ->
  ?placeholder:string ->
  ?turn_running:bool ->
  ?top_margin:int ->
  width:int ->
  on_msg:(msg -> 'msg) ->
  t ->
  'msg Mosaic.t
(** [render ~width ~on_msg t] is the composer frame for [t]: the two hand-rolled
    rules (chipped by [mode] and [agent]), the input-mode marker, and the
    controlled textarea that grows 1–6 rows then scrolls internally. Callbacks
    wrap composer {!type-msg}s with [on_msg].

    - [submit_enabled] gates Enter at the widget (defaults to [true]). The shell
      intercepts [Submit] while a list is open so ↵ activates a selection.
      A command palette with no matching row closes and rejoins the ordinary
      submission path with the unchanged draft.
    - [list_open] widens the pre-default key interception (defaults to [false]):
      while [true], ↑/↓ (and ctrl+p/n) and tab are swallowed and surface as
      {!List_key} for the shell to route. ↑/↓ also surface on a single-line
      draft while closed — the prompt-history walk.
    - [mode] colors the frame ([Build] gray, else the mode color) and chips the
      top rule; defaults to [Build].
    - [agent] renders a filled chip at the right of the top rule and heats a
      [Build] frame to accent; [None] shows no chip.
    - [placeholder] overrides the state-derived placeholder (a borrowed-composer
      string such as a rename or deny prompt).
    - [turn_running] selects the queue placeholder when [true] and no override
      or shell/agent state applies.
    - [top_margin] is the blank rows above the frame (defaults to [1]; the shell
      collapses it to [0] under an overlay or queued rows).
    - [width] is the terminal column count; the rules span it fully. *)
