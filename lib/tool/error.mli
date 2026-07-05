(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Tool dispatch errors for the executable-tool boundary.

    Dispatch errors happen before a tool handler runs. They cover catalog
    ambiguity, lookup failure, and input decoding failure. Expected failures
    from a running handler belong in {!Result.failed}.

    Pattern match on {!type:t} for stable behavior. {!message} and {!pp} are
    diagnostics for humans. *)

type t =
  | Duplicate_name of string
      (** [Duplicate_name name] means a dispatch catalog contains more than one
          tool named [name]. Duplicate detection is catalog-local and uses exact
          string equality. *)
  | Unknown_tool of string
      (** [Unknown_tool name] means no tool named [name] exists in the dispatch
          catalog. *)
  | Invalid_input of { tool : string; diagnostic : string }
      (** [Invalid_input { tool; diagnostic }] means [tool]'s input contract
          rejected the provider JSON. [diagnostic] is the decoder diagnostic
          returned by {!Input.decode}; it is human-readable and not a stable
          data format. *)

val message : t -> string
(** [message e] is a human-readable diagnostic.

    The message is intended for diagnostics and logs. Pattern match on {!type:t}
    for stable program behavior. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf e] formats {!message}[ e] on [ppf]. *)
