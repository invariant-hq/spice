(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The slash-command catalog: the single source every consumer reads.

    A {!t} is one command in spice's fixed catalog. Its slash spelling, palette
    strings, argument hint, idle gate, echo behavior, and dispatch {!fate} are
    all read here — the palette rows, the input parser, and the shell's dispatch
    draw from this one table so no property is re-derived in a parallel match
    elsewhere (10-commands.md, 03-composer.md §Slash palette).

    The catalog is closed: {!all} enumerates every command in display order, and
    a new command cannot exist without joining {!type:t}. Which commands the
    running frontend actually backs is a separate axis — {!implemented} — so the
    palette never advertises a command that would do nothing. *)

(** {1:types Types} *)

type t
(** The type for a slash command. [t] is a command's identity; its strings,
    gate, echo, and {!fate} are read through the queries below. The catalog is
    closed and fixed — construct values only via {!all}, {!filter}, or {!parse}.
*)

(** The type for a command's idle gate. *)
type availability =
  | Idle_only
      (** The command mutates session state and waits for the turn to finish.
          Invoked mid-turn it records
          [<cmd> is available after the turn finishes] and does nothing else
          (10-commands.md §States). *)
  | Anytime
      (** The command opens a surface or flips a next-turn contract and is safe
          mid-turn. *)

(** The type for the tab a settings command lands on. The settings screen is one
    surface with four tabs (03-ia-screens-overlays.md §Settings); [/config],
    [/status], [/usage], and [/skills] each open it on their own tab, and
    [/settings] on {!Config}. *)
type settings_tab =
  | Config  (** The effective-configuration inventory. *)
  | Status  (** The read-only session and workspace fact sheet. *)
  | Usage  (** Session cost, tokens, and plan quotas. *)
  | Skills  (** The discovered-skills inventory. *)

(** The type for a command's dispatch outcome — what the shell does when the
    command fires. Every arm names one shell-owned action, so the shell routes
    on {!fate} alone and needs no second table keyed on {!type:t}. Several
    commands collapse onto one arm: [/config], [/status], [/usage], [/skills],
    [/settings] all become {!Open_settings}, and [/plan], [/build] both become
    {!Switch_mode}. *)
type fate =
  | Clear_session
      (** Start a fresh empty session; the previous one stays on disk. Rebuilds
          the transcript and re-banners (10-commands.md §/clear). *)
  | Fork_session
      (** Fork the session into a child and continue in the child. *)
  | Compact_session
      (** Summarize the conversation so far to free context. Rebuilds the
          transcript. *)
  | Rename_session
      (** Rename the active session. With an argument the title is set directly;
          bare, the shell seeds the draft with [/rename ] — the palette's
          argument-insert idiom — so the title is typed inline. *)
  | Open_model
      (** Open the model-and-effort picker (05-overlays-pickers.md). *)
  | Open_sessions  (** Open the session quick-switch. *)
  | Open_settings of settings_tab  (** Open the settings screen on a tab. *)
  | Open_review  (** Open the review screen over the worktree diff (11). *)
  | Open_login  (** Open the provider login flow (09-auth.md). *)
  | Open_logout  (** Open the provider logout flow. *)
  | Switch_mode of Spice_protocol.Mode.t
      (** Set the turn mode for the next turn — a reversible toggle allowed
          mid-turn (10-commands.md §Mode switches). Only
          {!Spice_protocol.Mode.Build} and {!Spice_protocol.Mode.Plan} are
          reached this way; [/review] opens a screen ({!Open_review}) rather
          than switching mode. *)
  | Toggle_thinking  (** Flip whether thinking summaries are shown. *)
  | Toggle_verbose  (** Flip tool-output expansion (also [ctrl+o]). *)
  | Quit  (** Request process exit; the footer carries the press-again guard. *)

(** The type for a parsed command line (see {!parse}). *)
type parsed =
  | Exact of t  (** A bare command, e.g. ["/model"]. *)
  | With_argument of t * string
      (** A command and its trailing argument, e.g. ["/rename my title"]. The
          argument is trimmed and never empty; only {!Rename_session},
          {!Open_review}, {!Open_login}, and {!Open_logout} commands take one.
      *)

(** {1:catalog The catalog} *)

val all : t list
(** [all] is every command in palette display order. *)

val implemented : t -> bool
(** [implemented c] is [true] iff the running frontend backs [c] end to end. The
    palette shows only implemented commands, so a listed command always does
    something. The set widens per build-out wave. *)

val filter : query:string -> t list
(** [filter ~query] is the {!implemented} commands whose slash or title contains
    [query] (case-insensitive substring), in {!all} order. An empty [query]
    yields every implemented command. This is the palette's row source; it never
    surfaces an unimplemented command (03-ia-screens-overlays.md §The filter
    law). *)

(** {1:queries Queries} *)

val slash : t -> string
(** [slash c] is [c]'s canonical spelling with the leading ['/'], e.g.
    ["/model"]. *)

val title : t -> string
(** [title c] is [c]'s short palette label, e.g. ["Model"]. *)

val description : t -> string
(** [description c] is [c]'s one-line palette description. *)

val argument_hint : t -> string option
(** [argument_hint c] is the [faint] hint shown after the command once a
    trailing space is typed, e.g. [Some "<title>"] for [/rename] or
    [Some "[target]"] for [/review], and [None] for commands that take no
    argument (03-composer.md §Slash palette). *)

val availability : t -> availability
(** [availability c] is [c]'s idle gate. *)

val echoes : t -> bool
(** [echoes c] is [true] iff the shell emits [c]'s [❯ /command] echo into the
    transcript before dispatch. Transcript-rebuilding commands ([/clear],
    [/compact], [/fork]) return [false] because they re-echo into their fresh
    transcript themselves, and surface-openers return [false] because the
    surface is its own feedback (01-transcript.md §Notices, 10-commands.md §Echo
    scope). *)

val fate : t -> fate
(** [fate c] is [c]'s dispatch outcome. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same command. *)

(** {1:parsing Parsing} *)

val parse : string -> parsed option
(** [parse s] is the command [s] names, or [None] when [s] is not a command
    line. Matching on the slash is case-insensitive and ignores surrounding
    whitespace; an argument's case is preserved. ["/model"] is {!Exact};
    ["/rename My Title"] is {!With_argument}; ["/rename"] with no argument is
    {!Exact} (the shell then borrows the composer). Only argument-taking
    commands accept a trailing argument — for the rest, trailing text yields
    [None]. *)
