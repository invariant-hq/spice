(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The settings screen (03-ia-screens-overlays.md §Settings): four tabs —
    [config · status · usage · skills] — over the workspace's host-level state,
    only [config] and [skills] interactive.

    A mini-Elm surface (doc/plans/tui-next-surfaces.md): the shell holds {!t},
    routes keys through {!key}, folds the resulting {!msg} with {!update} —
    which yields the next {!t} and an {!event} the shell interprets — and
    renders {!view} through {!Screen.view}. The screen reads no config, clock,
    host, or environment: every host fact arrives as the {!facts} record the
    runtime ({!Settings_facts}) assembles from the host views and re-assembles
    after each write, so the screen reflects reality rather than optimistic
    state.

    Editing outcomes are carried out host-side: {!Write_field} persists one
    config field through [Config_file.edit], {!Toggle_skill} flips a skill's
    membership in [skills.disabled], and both reload the facts.
    {!Open_model_panel} and {!Copy} are the two non-config outcomes — the model
    row defers to the model panel (a later iteration), and the status tab copies
    the session id. *)

(** The four tabs. Selection, filter, and sort are per-tab; switching resets the
    filter and the inline editing state. *)
type tab = Config | Status | Usage | Skills

(** {1:facts Host facts}

    Each tab's facts live in their own submodule so the shared field names
    ([label], [value], [rows]) never collide. Every type is transparent so
    {!Settings_facts} constructs it directly. *)

module Config : sig
  (** One config field's editable value, shaped by how it edits (03-ia
      §Settings). [Managed] is the one row the screen never edits in place — the
      model row defers to the model panel. *)
  type value =
    | Enum of { current : string; options : string list }
        (** A closed-vocabulary field ([Field.values] is [Some]); [current] is
            the effective spelling, [options] the allowed set. Edited through
            the inline [●] radio. *)
    | Toggle of bool  (** A boolean field, toggled on [↵]. *)
    | Text of string
        (** An open-shape field, edited through the inline input. *)
    | Managed of string
        (** The [model] row: [current] is the configured selector; [↵] opens the
            model panel rather than editing in place. *)

  type row = {
    field : string;
        (** The stable config-file spelling ([Field.name]) the {!Write_field}
            event carries. *)
    label : string;  (** The human label shown in the name column. *)
    value : value;
    is_default : bool;
        (** Whether the effective value comes from no configured layer. A
            default value renders muted; a changed one renders in the default
            foreground (03-ia §Settings). *)
    danger : string option;
        (** An advisory in-place caution for a dangerous value
            ([bypass — approvals skipped],
            [danger-full-access — no filesystem confinement],
            [sandbox required off]); never a confirmation prompt (those are
            dialogs, 07). *)
  }
  (** One config row, assembled from the {!Field} inventory, grouped into
      families. *)

  type group = { title : string; rows : row list }
  (** A config family under a muted, non-selectable header (03-ia §Settings). *)

  type t = {
    groups : group list;
    sources : string;
        (** The rule's right label: the config sources present, joined
            ([user + project]); [""] when only defaults resolve. *)
  }
end

module Status : sig
  type fact = { label : string; value : string }
  (** One read-only status row: a padded label column, then the value. *)

  type t = {
    rows : fact list;
    session_id : string option;
        (** The active session id, what [c] copies; [None] when no session is
            attached (the [c] key is then inert). *)
  }
end

module Usage : sig
  type lane = { label : string; tokens : int }
  (** One token lane (input, output, reasoning, cache read/write, total). *)

  type t = {
    has_turns : bool;
        (** Whether the session has run a turn; [false] renders the
            [no turns yet] empty state. *)
    model : string;
        (** The session's model label, heading the per-model row. *)
    lanes : lane list;
    cost : string;
        (** The formatted session cost, or [cost unavailable] when the model has
            no pricing (an unknown rate is not billed as free —
            {!Spice_provider.Model.cost}). *)
    scope : string;
        (** The honest scope line. Plan-quota bars and the all-time line are
            omitted (no quota or aggregate facts exist upstream), so this names
            the [this session] scope in their place. *)
  }
end

module Skills : sig
  type row = {
    name : string;
    state : string;  (** [active] / [shadowed] / [disabled] / [invalid]. *)
    source : string;  (** The discovery root ([builtin], [project], …). *)
    cost : int;
        (** The [~N tok] context cost; [0] when the skill loads nothing. *)
    enabled : bool;
        (** Whether the skill is not excluded by [skills.disabled]; the [↵]
            toggle target. *)
    description : string option;
        (** The one-line detail shown faint under the selected row: the
            description for an active skill, else its status reason. *)
  }

  type t = {
    rows : row list;
    budget : int;
        (** The enabled context budget summed for the header ([~N tok]): the
            catalog's standing cost plus every active skill's. *)
    available : bool;
        (** Whether the skills surface exists; [false] renders the
            [skills are disabled] empty state. *)
  }
end

type facts = {
  config : Config.t;
  status : Status.t;
  usage : Usage.t;
  skills : Skills.t;
}
(** Everything the four tabs draw, assembled once per open and re-assembled
    after each write. *)

(** {1:surface The surface} *)

type t
(** The screen state: loading, a load-error line, or loaded facts with the
    active tab, the per-tab selection and filter, the skills sort, and any
    inline editing affordance. *)

type msg
(** A key routed to the screen, opaque; produced by {!key}. *)

(** The screen's outcome, which the shell interprets. Every config or skill
    mutation is carried out host-side and reflected by reloading the facts. *)
type event =
  | Stay  (** Remain open with the updated state. *)
  | Close
      (** Esc with the filter and editing closed: return to the prior view. *)
  | Open_model_panel
      (** [↵] on the model row: the shell flashes the honest model-panel
          placeholder until that iteration lands. *)
  | Write_field of { field : string; value : string option }
      (** Persist [field] to the user config ([Some] sets, [None] unsets), then
          reload the facts. *)
  | Toggle_skill of string
      (** Flip the named skill's membership in [skills.disabled], then reload
          the facts. *)
  | Copy of string  (** Copy the string (the session id) to the clipboard. *)

val loading : tab:tab -> t
(** [loading ~tab] is the screen just opened on [tab], before its facts arrive:
    {!view} renders a muted loading line. *)

val loaded : facts -> t -> t
(** [loaded facts t] folds [facts] into [t]. From a loading or error state it
    seeds them on the opening tab; from a loaded state it replaces them while
    keeping the active tab, filter, selection, sort, and any inline editing — so
    a write's own reload lands the user back exactly where they were, now
    reading the persisted value. *)

val failed : string -> t
(** [failed message] is the screen showing a facts-assembly error line rather
    than an empty body. *)

val key : Matrix.Input.Key.event -> msg option
(** [key ev] is the screen's message for [ev], or [None] for a key it ignores.
    The screen owns its keyboard, so an ignored key dies. *)

val update : msg -> t -> t * event
(** [update msg t] folds one key under the filter law (03-ia §The filter law)
    and the per-tab keymap:

    - {b Tabs.} [tab] cycles to the next tab; [←]/[→] switch tabs except where
      the config tab captures them for the inline enum radio. Switching clears
      the filter and any inline editing.
    - {b Config.} [↑]/[↓] move between rows; [↵] toggles a boolean, opens the
      inline text input, or — on the model row — yields {!Open_model_panel}. On
      an enum row [←]/[→] open the inline [●] radio and commit a {!Write_field}.
      The text input commits on [↵] and cancels on esc.
    - {b Status.} [c] yields {!Copy} of the session id.
    - {b Skills.} [↑]/[↓] move; [t] cycles the sort (name/state/cost); [↵]
      yields {!Toggle_skill} of the selected skill.
    - {b Filter.} [/] opens the bare filter line over the active tab's rows; esc
      closes the filter, then (closed) yields {!Close}.

    Every other message is [(t, Stay)]. *)

val view : frame:Mosaic.Ansi.Color.t -> width:int -> rows:int -> t -> _ Mosaic.t
(** [view ~frame ~width ~rows t] renders the screen through {!Screen.view},
    [frame] tinting the top rule and the [settings] chip. The tab row sits under
    the rule (selected accent, rest muted), a blank line below it, then the
    active tab's body. Config groups render under muted family headers with the
    selected row's cursor and any inline radio, input, or danger caution; status
    and usage are read-only fact sheets; skills lists
    [name · state · source · ~N tok] rows with the selected row's faint
    description. [rows] bounds the visible window; overflow collapses into a
    muted tail. *)
