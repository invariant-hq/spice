(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Evaluation-marker scanning.

    Agents under evaluation must not be able to tell that they are being
    evaluated from anything they can observe in normal operation. Marker
    scanning checks text the harness introduces into the agent-visible surface —
    file names, file contents, environment values, git identities — for
    evaluation vocabulary before an agent runs.

    Matching is case-insensitive substring search with no word-boundary rule:
    ["eval"] matches ["eval_calc"], ["_evals"], and ["Spice_eval_smoke"].
    Boundary-aware matching is deliberately rejected: underscores are word
    characters in mainstream regexp engines, so a word-bounded ["eval"] passes
    exactly the leaks this module exists to catch. *)

(** {1:scanning Scanning} *)

type hit = {
  term : string;  (** The denylist entry that matched. *)
  context : string;  (** The line of scanned text containing the match. *)
}
(** One marker occurrence, for diagnostics. *)

val denylist : string list
(** [denylist] is the default marker vocabulary. It contains ["eval"] (which
    subsumes ["spice-eval"], ["spice_eval"], and ["_evals"]), ["benchmark"],
    ["grader"], and ["rubric"]. *)

val scan : ?deny:string list -> string -> hit list
(** [scan ?deny text] is the marker occurrences in [text], scanned line by line.
    Each line reports each matching [deny] term (default {!denylist}) at most
    once, in line order.

    Raises [Invalid_argument] if [deny] contains an empty term. *)

(** {1:formatting Formatting} *)

val pp_hit : Format.formatter -> hit -> unit
(** [pp_hit ppf hit] formats [hit] for human-readable diagnostics. The output is
    not a stable serialization format. *)
