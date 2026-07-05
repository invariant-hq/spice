(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Inert evaluation check descriptions.

    Checks describe how a completed attempt should be graded. They do not run
    commands, read diffs, call judges, or decide short-circuit policy; runner
    code interprets {!test} values and records {!Result.finding} values in a
    {!Result.t}. *)

(** {1:types Types} *)

(** The type for deterministic checks that runners can evaluate from captured
    workspace facts.

    Shell commands are interpreted by runners. Diff tests use runner-defined
    glob and regular-expression semantics; the core library only validates that
    patterns are non-empty. *)
type test =
  | Shell of string
      (** Run a shell command in the task workspace. The command must be
          non-empty. *)
  | Diff_within of string list
      (** Require every changed file to stay within these non-empty glob-like
          path patterns. *)
  | Diff_touches_any of string list
      (** Require the diff to touch at least one of these non-empty glob-like
          path patterns. *)
  | Diff_touches_all of string list
      (** Require the diff to touch every one of these non-empty glob-like path
          patterns. *)
  | Diff_free_of of string
      (** Require the added diff lines to be free of this non-empty regular
          expression. *)

type kind = [ `Gate | `Penalty of float | `Judge of float ]
(** The scoring kind of a check.

    [`Gate] is a hard pass/fail check. [`Penalty points] subtracts [points] when
    the check fails. [`Judge weight] contributes a weighted quality score when
    judge samples are present. *)

type t = private
  | Gate of { name : string; test : test }
  | Penalty of { name : string; points : float; test : test }
  | Judge of { name : string; weight : float; criterion : string }
      (** A named grading description.

          Names are task-local identifiers and must be non-empty. *)

(** {1:constructors Constructors} *)

val shell : string -> test
(** [shell command] is [Shell command].

    Raises [Invalid_argument] if [command] is empty. *)

val diff_within : string list -> test
(** [diff_within globs] is [Diff_within globs].

    Raises [Invalid_argument] if [globs] is empty or contains an empty pattern.
*)

val diff_touches_any : string list -> test
(** [diff_touches_any globs] is [Diff_touches_any globs].

    Raises [Invalid_argument] if [globs] is empty or contains an empty pattern.
*)

val diff_touches_all : string list -> test
(** [diff_touches_all globs] is [Diff_touches_all globs].

    Raises [Invalid_argument] if [globs] is empty or contains an empty pattern.
*)

val diff_free_of : string -> test
(** [diff_free_of regex] is [Diff_free_of regex].

    Raises [Invalid_argument] if [regex] is empty. *)

val gate : string -> test -> t
(** [gate name test] is a hard check named [name].

    A failed gate makes the enclosing {!Result.t} unsuccessful. Raises
    [Invalid_argument] if [name] is empty. *)

val penalty : string -> points:float -> test -> t
(** [penalty name ~points test] is a soft check named [name].

    A failed penalty subtracts [points] from the final score after quality is
    computed. Raises [Invalid_argument] if [name] is empty or [points] is not a
    positive finite float. *)

val judge : string -> ?weight:float -> criterion:string -> unit -> t
(** [judge name ?weight ~criterion ()] is a judge-scored quality check.

    [weight] defaults to [1.0]. The runner decides how to obtain judge samples
    for [criterion]. Raises [Invalid_argument] if [name] or [criterion] is
    empty, or if [weight] is not a positive finite float. *)

(** {1:queries Queries} *)

val name : t -> string
(** [name check] is [check]'s non-empty task-local name. *)

val kind : t -> kind
(** [kind check] is [check]'s scoring kind. *)

(** {1:formatting Formatting and codecs} *)

val pp : Format.formatter -> t -> unit
(** [pp ppf check] formats [check] for human-readable diagnostics. The output is
    not a stable serialization format. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are structurally equal. *)

val jsont : t Jsont.t
(** [jsont] maps checks to JSON objects. Decoding validates the same invariants
    as the constructors. *)
