(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-conditioned request options for one turn.

    [Turn_options] is the single seam where per-model request parameters are
    resolved before a turn is assembled. Every frontend builds its turn options
    here, so a conditioned request axis is single-sourced and reaches the CLI
    and TUI alike; adding one to only one assembly site would let the two
    frontends diverge.

    The resolution obeys the layer rule of
    [doc/design-notes/model-conditioning.md]: a per-model difference resolves
    here, from declared {!Spice_provider.Model} metadata and the frontend's
    configured choices, and reaches provider transports only as neutral
    {!Spice_llm.Request.Options} values — the transport never sees the model
    metadata. The value produced is thus provider-neutral; no reasoning tier or
    sampling cap it carries names a provider. *)

val resolve :
  model:Spice_provider.Model.t ->
  ?reasoning_effort:Spice_llm.Request.Options.Reasoning_effort.t ->
  unit ->
  Spice_llm.Request.Options.t
(** [resolve ~model ()] is the request option set for one turn against [model].

    [reasoning_effort] is the frontend-resolved effort choice, passed through
    unchanged; omitting it leaves the option unset, which providers read as
    their default effort. [model] conditions no option yet: it is the
    declared-metadata input from which future axes (sampling caps, request
    parameters) resolve, and frontends thread it so that landing such an axis
    touches only this seam. *)
