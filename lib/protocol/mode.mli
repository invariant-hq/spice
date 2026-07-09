(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Primary turn modes.

    A mode is the product contract for a root session turn. It is stronger than
    a prompt label: it carries a read-only {!Contract.t}, contributes
    request-scoped instructions, offers a set of host tools, and decides which
    subagent roles it may spawn.

    A mode is thin data over its {!Contract.t}; the tool restriction and policy
    strengthening live there, reached through {!contract}, so they are stated
    once and shared with {!Subagent.Role.t}. *)

type t =
  | Build
  | Plan
  | Review  (** The type for built-in primary turn modes. *)

val default : t
(** [default] is {!Build}. *)

(** {1:parsing Parsing and spelling} *)

type parse_error = { input : string; candidates : string list }
(** The type for a failed {!of_string}. [input] is the unrecognized spelling and
    [candidates] are the valid spellings, carried so the host boundary can
    suggest close matches. *)

val of_string : string -> (t, parse_error) result
(** [of_string s] parses [s] as a mode. Unknown spellings error with a
    {!parse_error} carrying the candidate list.

    This is the only parse that surfaces the candidates; the stored-string
    degrade ({!of_turn}) reuses it and discards them. *)

val to_string : t -> string
(** [to_string t] is [t]'s stable CLI and JSON spelling. *)

val of_turn : Spice_session.Turn.t -> t
(** [of_turn turn] is the mode recorded on [turn].

    This is the single degrade policy for the uninterpreted [Turn.mode] string:
    an unknown or absent spelling is {!default}. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same mode. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] for diagnostics. *)

(** {1:contract Contract and instructions} *)

val contract : t -> Contract.t
(** [contract t] is [t]'s read-only contract.

    {!Build} is {!Contract.unrestricted}; {!Plan} and {!Review} are
    {!Contract.read_only}. Apply it with {!Contract.filter_tools} and
    {!Contract.policy}. *)

val prelude_messages : t -> Spice_llm.Message.t list
(** [prelude_messages t] are request-scoped mode instructions.

    They are not transcript state and should be combined with host instruction
    preludes at request assembly time. *)

(** {1:host_tools Host tools} *)

val host_tools : t -> Call.Kind.t list
(** [host_tools t] are the host-handled tool kinds offered to a root turn in
    mode [t]. Every mode offers question plus subagent spawn, wait, cancel, and
    message coordination. {!Build} additionally offers todo and goal;
    {!Plan} additionally offers plan; {!Review} has no mode-specific addition.
    The goal kind is further conditioned on the session's goal status at
    request assembly — the offer here is the mode ceiling, not the per-turn
    catalog. Map through {!Call.Kind.tool} for model-visible declarations. *)

val all_host_tools : Spice_llm.Tool.t list
(** [all_host_tools] is the complete built-in recognition set across root and
    child contexts. It includes child-only [message_parent], so it is broader
    than the union of root {!host_tools} catalogs. It is {!Call.Kind.all} mapped
    through {!Call.Kind.tool}. See {!Call.classify}. *)

val allows_role : t -> Subagent.Role.t -> bool
(** [allows_role mode role] is [true] iff a root turn in [mode] may spawn a
    child run with [role].

    {!Build} allows every built-in role. {!Plan} and {!Review} allow only
    {!Subagent.Role.Explore}, preserving their read-only contracts. *)
