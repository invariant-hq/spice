(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC

  The pattern-matching semantics are derived from ocamlgrep,
  Copyright (C) 2000-2026 LexiFi, released under the MIT license.
 ---------------------------------------------------------------------------*)

(** Syntactic structural search over OCaml parse trees.

    [Spice_ocaml_grep] matches an expression pattern against the untyped
    {!Parsetree} of OCaml source. It is pure: it owns no filesystem authority,
    no compiler environment, no typing, and no cache. Matching is syntactic —
    identifiers are compared as written, not as resolved, so a qualified pattern
    does not see through [open] or module aliases.

    {1 Pattern syntax}

    A pattern is a plain OCaml expression. Special forms:

    - [__] matches any expression, record field, or identifier component.
    - [__1], [__2], ... are metavariables: every occurrence with the same number
      must match structurally equal expressions.
    - Identifier paths match by component suffix in either direction: pattern
      [filter] matches [List.filter] as written, and pattern [List.filter]
      matches a bare [filter].
    - In an application, pattern arguments may omit any arguments of the call;
      [f ?arg:PRESENT] requires the labelled argument to be written at the call
      site, [f ?arg:MISSING] requires it to be absent.
    - [match]/[try]/[function] clauses, record fields, and [let] bindings match
      as sets: order is irrelevant and one pattern clause may cover several
      clauses of the code.
    - [e.lid] also matches the assignment [e.lid <- v]. The pattern [__.id]
      additionally matches any {e pattern} [{ ...; P.id; ... }], catching
      record-field reads in patterns.
    - Type annotations in the searched code are ignored: a pattern matches
      through [(e : t)] and [(p : t)] nodes.

    Type-constrained patterns such as [(__ : t)] are rejected: they require a
    typed backend, which this engine deliberately does not have. *)

(** {1 Patterns} *)

module Pattern : sig
  type t
  (** A parsed, validated search pattern. *)

  type error =
    | Syntax of string
        (** The query is not a parseable OCaml expression. The string is a
            human-readable diagnostic. *)
    | Unsupported of string
        (** The query parses but uses a construct this engine cannot match, such
            as a type constraint. The string explains the construct. *)

  val error_message : error -> string
  (** [error_message e] is the human-readable message of [e]. *)

  val parse : string -> (t, error) result
  (** [parse query] parses [query] as one OCaml expression and validates it as a
      search pattern.

      Errors with [Syntax _] when [query] is not a valid expression and with
      [Unsupported _] when it contains a type constraint or coercion ([(e : t)],
      [(p : t)], [(e :> t)], [let x : t = ...]). *)

  val source : t -> string
  (** [source t] is the query text [t] was parsed from. *)
end

(** {1 Parsing searched sources} *)

val parse_implementation :
  filename:string -> string -> (Parsetree.structure, string) result
(** [parse_implementation ~filename source] parses [source] as an OCaml
    implementation. [filename] is recorded in locations and used in the error
    diagnostic.

    Errors with a human-readable syntax diagnostic, including the error position
    when the parser reports one. *)

(** {1 Search} *)

val search :
  Pattern.t ->
  path:Spice_workspace.Path.t ->
  Parsetree.structure ->
  Spice_ocaml.Location.t list
(** [search pattern ~path structure] is the location of every syntactic match of
    [pattern] in [structure], attributed to [path].

    Matching starts at every non-ghost expression node (and, for [__.id]
    patterns, every pattern node). A node that matches is reported once and its
    sub-expressions are not searched further. Results are ordered by range start
    and contain no duplicates. *)

(** {1 Metavariable bindings} *)

module Binding : sig
  type captured =
    | Source of Spice_ocaml.Range.t
        (** An expression metavariable: slice the file's bytes at this range to
            recover the fragment verbatim, preserving its comments and
            formatting. This is the range of the first occurrence within the
            match that has a real (non-ghost) location; the compiler unwraps
            [(e : t)] first, so a constrained match captures the inner
            expression. *)
    | Ident of string
        (** A pattern-variable or identifier-path/field-component metavariable:
            it can only ever bind a bare identifier, which has no interior
            formatting, so render it by emitting this string. Resolves the
            no-location cases (identifier-path components have no per-component
            location; a pattern variable's identifier location is not
            byte-sliced). *)

  type t
  (** A pattern metavariable and how to render it at one match. *)

  val name : t -> string
  (** [name t] is the metavariable, e.g. ["__1"]. *)

  val captured : t -> captured
  (** [captured t] is how to reproduce [t]'s fragment: slice a source range or
      emit an identifier. *)
end

val search_with_bindings :
  Pattern.t ->
  path:Spice_workspace.Path.t ->
  Parsetree.structure ->
  (Spice_ocaml.Location.t * Binding.t list) list
(** [search_with_bindings pattern ~path structure] is like {!search} but
    returns, for every {e expression} match, how each metavariable it bound is
    rendered at that site.

    Only expression matches are returned: the [__.id]-in-pattern matches that
    {!search} also reports bind no metavariables and are not rewrite targets.
    Each match's binding list has one entry per distinct metavariable, in
    first-capture order; every metavariable is present, as a {!Binding.Source}
    range or a {!Binding.Ident}. Results are ordered and deduplicated by match
    location as in {!search}, and match ranges within a file are pairwise
    disjoint. *)

val strip_expr : Parsetree.expression -> Parsetree.expression
(** [strip_expr e] is [e] with every location set to a ghost none, every
    attribute removed, and every location stack cleared. It is the canonical
    notion of "structurally equal" used to unify metavariable bindings; callers
    that reconstruct or re-check a match must strip with this function to share
    one notion of equality with the matcher. *)
