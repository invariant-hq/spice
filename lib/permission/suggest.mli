(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Durable rule suggestions from reviewed accesses.

    A reviewer who chooses to always allow an access wants more than the exact
    {!Access.t} grant, which never broadens past the identical fact (see
    {!Policy.Grants}). A suggestion generalizes one access to a durable allow
    {!Policy.Rule.t} over its family — a command prefix, a path subtree or file,
    or a network host — paired with a neutral one-line description of what the
    rule matches, so a prompt can show the reviewer exactly what saving it
    grants.

    Suggestions are pure policy data: constructing one runs no operation and
    reads no configuration. Accesses with no safe generalization — shell text
    whose command structure is unknown, and custom accesses such as sandbox
    escalation — yield no suggestion. *)

type t
(** The type for a durable-rule suggestion. *)

val rule : t -> Policy.Rule.t
(** [rule t] is the allow rule [t] suggests. *)

val summary : t -> string
(** [summary t] is a neutral one-line description of what {!rule} matches, for a
    reviewer to inspect before saving — for example ["git commit"],
    ["edits under lib/"], or ["requests to example.com"]. It is display text,
    not storage syntax. *)

val of_access : Access.t -> t option
(** [of_access access] is the family suggestion for [access], or [None] when
    [access] has no safe generalization.

    An ([Argv]) command in a workspace generalizes to a
    route-and-cwd-constrained program-and-subcommand prefix
    (["git commit -m msg"] to all ["git commit"], ["dune build @runtest"] to all
    ["dune build"]) using a small command-arity table with a program-only
    fallback. A workspace path
    generalizes to its parent subtree, or to the exact file when the file sits
    at the workspace root. A network access generalizes to its host, across
    every protocol and port. Shell-text commands, commands outside or at an
    unknown workspace, out-of-workspace and unknown paths, and custom accesses
    yield [None]. *)

val of_accesses : Access.t list -> t list
(** [of_accesses accesses] are the suggestions for [accesses] with duplicate
    rules removed, keeping the first occurrence, in access order. *)
