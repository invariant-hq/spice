(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Boundary error diagnostics.

    A diagnostic is the validated, renderable form of a user-fixable boundary
    error: a message, optional context, and actionable hints. Error-owning
    libraries expose [Error.diagnostic : t -> Spice_diagnostic.t] where the
    fixable knowledge lives; hosts render every such error uniformly at one
    boundary with {!to_string}. Diagnostics are presentation values — build and
    render them; do not inspect or parse them for control flow. No dependencies,
    so any error producer can attach hints without a host runtime. *)

type t
(** The type for diagnostics.

    Invariant: [message] is non-empty and single-line, every hint is non-empty
    and single-line, and [context] is non-empty when present. The hint list
    itself may be empty. *)

val make : ?context:string -> ?hints:string list -> string -> t
(** [make ?context ?hints message] is a diagnostic with primary description
    [message]. [message] must be a single line: renderers may style it as a head
    line and the rest as secondary detail. Put multi-line prose in [context].

    [context], when present, is secondary detail printed verbatim after the
    message. It may contain multiple lines. [hints] defaults to [[]]; each hint
    is one actionable suggestion, rendered as a ["Hint: …"] line by
    {!to_string}.

    Raises [Invalid_argument] if [message] is empty or contains a newline, if
    any hint is empty or contains a newline, or if [context] is empty when
    present. *)

(** {1:hints Hints}

    Produce hints where the candidate knowledge lives — the code that fails a
    lookup has the valid spellings. Both return a [string list] fragment (empty
    or one hint) to splice into {!make}'s [~hints]. *)

val did_you_mean : string -> candidates:string list -> string list
(** [did_you_mean s ~candidates] keeps candidates within edit distance two of
    [s], in [candidates] order, as one ["did you mean …?"] hint; empty when none
    is close. Exact matches are never suggested.

    Raises [Invalid_argument] if a candidate is empty or contains a newline. *)

val suggest : string list -> string list
(** [suggest candidates] renders [candidates] verbatim — the caller has already
    judged them relevant — as one ["did you mean …?"] hint: one directly, two
    joined with [" or "], longer lists with commas before the final [" or "].
    Empty for [[]].

    Raises [Invalid_argument] if a candidate is empty or contains a newline. *)

(** {1:fmt Formatting} *)

val to_string : t -> string
(** [to_string t] renders [t] as user-facing text: the message, then the context
    when present, then one ["Hint: …"] line per hint, each on its own line. Not
    stable storage syntax; do not parse it. *)
