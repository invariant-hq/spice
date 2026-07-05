(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Tool execution event rendering for [spice run].

    One product event derived from host timeline events, projected to both the
    compact human line and the JSONL event fields so the two surfaces cannot
    diverge. Evidence comes from typed tool outputs retained in the erased
    result ({!Spice_tools.Evidence}); nothing is parsed from model-visible text
    or JSON. *)

type t
(** The type for tool claim events. *)

val of_timeline : Spice_protocol.Event.t -> t option
(** [of_timeline event] is the tool event for tool lifecycle and workspace
    timeline events, and [None] for every other timeline event. *)

val to_json : t -> string * (string * Jsont.json) list
(** [to_json t] is [t]'s JSONL event type and fields, without the envelope
    (schema version, session id) owned by the caller. *)

val to_human : t -> string option
(** [to_human t] is [t]'s compact human line, when one should print. Started and
    workspace events print nothing in V1; terminal results print one line that
    never hides failures, interruptions, or truncation. *)
