(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The model + effort panel (03-ia-screens-overlays.md §The three forms,
    05-overlays-pickers.md §Model picker): the coding-model catalog grouped by
    provider, type-to-filter, an inline reasoning-effort line for the
    highlighted model, esc closes. A panel, not an overlay — it replaces the
    composer region below the [▔] boundary while the transcript stays above.

    A mini-Elm surface (doc/plans/tui-next-surfaces.md): the shell holds {!t},
    routes keys through {!key}, folds the resulting {!msg} with {!update} —
    which yields the next {!t} and an {!event} the shell interprets — and
    renders {!view} through {!Panel.view}. The panel reads no config, catalog,
    clock, or host: every fact arrives as the {!facts} record the runtime
    assembles from the host catalog and the per-provider account phases,
    formatted once.

    A pick is carried out host-side: {!Select} carries the resolve-able selector
    and the chosen effort, which the runtime validates through
    [Spice_host.Models.for_select] and persists as [Field.model] +
    [Field.reasoning] in the user config — effective the next turn, not a
    hot-swap of the live attachment (old [lib/tui/runtime.ml]
    [save_model_selection] is the reference). A locked (unauthenticated)
    provider's model is shown muted rather than hidden: selecting it does not
    use it — tui-next has no auth flow yet — so {!Login_required} lets the shell
    flash the honest placeholder instead. *)

(** {1:facts Host facts} *)

type model = {
  selector : string;
      (** The canonical [provider/model] selector a {!Select} carries and
          [Spice_host.Models.for_select] validates. *)
  name : string;  (** The display name shown in the row's label column. *)
  provider_title : string;
      (** The provider's display title ([Anthropic], [OpenAI], …): the muted
          group header. Consecutive models sharing it form one group. *)
  detail : string;
      (** The right-aligned muted detail: the [·]-joined subset of
          {default, status, context, description} that fits, provider and name
          excluded (they are the header and the label). *)
  locked : bool;
      (** Whether the model's provider has no resolved credential (account phase
          [`Missing]): the whole row renders muted with a [log in to use]
          affordance and selecting it yields {!Login_required} rather than
          {!Select}. *)
  is_current : bool;
      (** Whether this is the configured current model: it carries the trailing
          [✓] and seeds the initial selection. *)
  supported_reasoning : Spice_llm.Request.Options.Reasoning_effort.t list;
      (** The efforts [←]/[→] cycles through for this model (with the model
          default); empty means the model takes no effort. *)
  default_reasoning : Spice_llm.Request.Options.Reasoning_effort.t option;
      (** The model's default effort, marked [(default)] on the effort line. *)
  warning : string option;
      (** A caution ([preview], [deprecated]) shown as the effort line's tail
          while this model is highlighted; [None] for a stable model. *)
  search_key : string;
      (** The filter key — name, provider, and selector — matched
          case-insensitively. *)
}
(** One catalog model, assembled by the runtime from
    {!Spice_provider.Catalog.models} (tool-capable and visible only) paired with
    the provider's account phase. *)

type facts = {
  models : model list;
      (** The models in provider declaration order; the panel groups consecutive
          rows by {!provider_title}. *)
  reasoning : Spice_llm.Request.Options.Reasoning_effort.t option;
      (** The configured effort ([Field.reasoning]), or [None] for the model
          default. [←]/[→] adjusts it; {!Select} carries it when the highlighted
          model supports it, else [None]. *)
}
(** Everything the panel draws, assembled once when the panel opens. *)

(** {1:surface The surface} *)

type t
(** The panel state: loading (facts not yet arrived), a load-error line, or
    loaded facts with a filter, a selection into the filtered options, and the
    live effort. *)

type msg
(** A key routed to the panel, opaque; produced by {!key}. *)

(** The panel's outcome, which the shell interprets. *)
type event =
  | Stay  (** Remain open with the updated state. *)
  | Close  (** Esc: close and restore the composer unchanged. *)
  | Select of {
      selector : string;
      effort : Spice_llm.Request.Options.Reasoning_effort.t option;
    }
      (** [↵] on an unlocked model: persist [selector] as the default model and
          [effort] as the default reasoning, then close. Effective the next
          turn. *)
  | Login_required of string
      (** [↵] on a locked model: the string is the provider {b id} (the value
          [/login <provider>] resolves against, from the model's [selector]), so
          the shell reroutes to the login flow pre-selected on that provider
          (09-auth.md §9). Until the reroute arm lands the shell flashes an
          honest placeholder naming the id. *)

val loading : t
(** [loading] is the panel just opened, before its facts arrive: {!view} renders
    a muted loading line and an empty filter. *)

val loaded : facts -> t -> t
(** [loaded facts t] folds [facts] into [t]. From loading or error it seeds the
    filter empty, the effort from [facts.reasoning], and the selection on the
    hoisted default (the current model) or the first unlocked model; from a
    loaded state it replaces the models, keeping the filter, selection, and
    effort. Called once per open. *)

val failed : string -> t -> t
(** [failed message t] renders the catalog-error line [message] rather than the
    empty state. A failed refresh keeps facts that already arrived. *)

val key : Matrix.Input.Key.event -> msg option
(** [key ev] is the panel's message for [ev] under the filter law
    ({!Panel.classify}), or [None] for a key the panel ignores — so it dies in
    the modal shell rather than leaking to a chord. *)

val update : msg -> t -> t * event
(** [update msg t] folds one key. A printable narrows the filter and resets the
    selection; backspace shortens it; a digit jump-picks the nth visible model
    while the filter is empty (moving the selection, not confirming — the effort
    is part of a model pick) and narrows otherwise; [↑]/[↓] move the selection
    (wrapping over models, skipping the group headers); [←]/[→] lower/raise the
    effort within the highlighted model's supported set; [↵] yields {!Select}
    for an unlocked model or {!Login_required} for a locked one; esc yields
    {!Close}. Every other message is [(t, Stay)]. *)

val view : frame:Mosaic.Ansi.Color.t -> width:int -> rows:int -> t -> _ Mosaic.t
(** [view ~frame ~width ~rows t] renders the panel through {!Panel.view},
    [frame] tinting the boundary and the [model] chip. The content is the
    provider-grouped model list — muted headers, a blank line above each group
    after the first, a [❯] accent cursor and hover tint on the selection, locked
    rows muted with [log in to use], the current model's trailing [✓] — windowed
    to keep the transcript visible (03-ia open question 1: the list windows
    rather than growing unbounded, [↑ N]/[↓ N more] at the seams, the window
    sized from [rows]), then the highlighted model's effort line ([○◐●◉]
    intensity glyph, level word, [(default)] marker, [← → to adjust], or a muted
    [Effort not supported…] when the model takes none). The muted loading and
    [! …] error lines replace the list before facts arrive or on a catalog
    failure. *)
