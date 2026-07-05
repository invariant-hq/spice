(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The host's single approximate token heuristic.

    Estimates are roughly bytes over four with small structural floors: text is
    [max 1 ((len + 3) / 4)]; each URI-sourced media block adds [256] over its
    type and URI; each assistant tool call and each reasoning part contributes a
    flat [64]; an empty tool result floors at [1]. They fill the gaps
    provider-reported usage cannot cover — messages appended since the last
    response, summary inputs, and replays with no usage baseline yet — and are
    never presented as exact counts.

    Maintainers extending {!Spice_llm.Message}, {!Spice_llm.Content}, or
    {!Spice_llm.Message.Assistant} must update {!message} to keep the weights in
    one place. *)

val string : string -> int
(** [string text] is the estimated token count of [text]. *)

val message : Spice_llm.Message.t -> int
(** [message m] is the estimated token count of [m], summing its content,
    tool-call, and reasoning weights. *)

val messages : Spice_llm.Message.t list -> int
(** [messages ms] is the sum of {!message} over [ms]. *)

val request : Spice_llm.Request.t -> int
(** [request r] is {!messages} over [r]'s messages plus each tool's name,
    description, input schema, and a flat per-tool weight. *)
