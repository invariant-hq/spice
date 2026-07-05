(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Explanations for host decisions.

    A reason says why a host value or decision won. Configuration origins remain
    the source of truth for configured values; derived decisions carry explicit
    host-level labels. A reason attaches to a resolved choice — a model, for
    example — so a surface can explain the choice without re-deriving it. *)

(** {1:types Types} *)

(** The type for a decision's winning source. *)
type source =
  | Config of Config.Source.t
      (** A configuration source, preserving file, environment, override, and
          default detail. *)
  | Explicit of string
      (** A caller-supplied value, for example a command-line model selector.
          The string labels the input for diagnostics. *)
  | Derived of string
      (** A deterministic host fallback or heuristic, labelled for diagnostics.
      *)

type t
(** The type for one winning explanation.

    A reason also carries the lower-precedence sources it shadowed when the
    winning source came from configuration; derived and explicit reasons shadow
    nothing. *)

(** {1:constructors Constructors} *)

val configured : Config.Origin.t -> t
(** [configured origin] explains a decision that came directly from
    configuration, preserving [origin]'s shadowed lower-precedence sources. *)

val explicit : string -> t
(** [explicit label] explains a caller-supplied value labelled [label]. *)

val derived : string -> t
(** [derived label] explains a deterministic host fallback or heuristic labelled
    [label]. *)

(** {1:queries Queries} *)

val source : t -> source
(** [source t] is [t]'s winning explanation source. *)

val shadowed : t -> source list
(** [shadowed t] are the lower-precedence sources [t]'s winner shadowed, nearest
    first. It is empty for explicit and derived reasons. *)

val config_origin : t -> Config.Origin.t option
(** [config_origin t] is [Some origin] iff [t] came directly from configuration.
*)

(** {1:formatting Formatting} *)

val to_string : t -> string
(** [to_string t] is a stable diagnostic spelling of [t]'s winning source:
    ["configured"] for a config source, or the label for an explicit or derived
    reason. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] using {!to_string}. *)
