(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure command sandbox policies.

    A policy is the complete inert description of one process route. Confined
    policies state readable and writable roots, protected write carveouts, and
    network access. Direct and external policies state that Spice does not
    apply a filesystem or network confinement profile.

    Constructing a policy enforces nothing. A backend seals a confined policy
    before a command can use it. *)

module Network : sig
  (** Command network access. *)

  type t = Restricted | Enabled

  val all : t list
  (** [all] is [[Restricted; Enabled]]. *)

  val of_string : string -> t option
  (** [of_string s] is the network access spelled by [s], or [None] if [s] is
      neither ["restricted"] nor ["enabled"]. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s configuration spelling. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] grant the same network access. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s configuration spelling. *)
end

type reads =
  | All
  | Only of Spice_path.Abs.t list
      (** Filesystem read access. [Only roots] confines reads to [roots]. *)

type t = private
  | Confined of {
      reads : reads;
      writable_roots : Spice_path.Abs.t list;
      protected_paths : Spice_path.Abs.t list;
      network : Network.t;
      environment : Environment.t;
    }
  | Direct of Environment.t
  | External of Environment.t
      (** The type for command sandbox policies.

          [Direct] requests no Spice filesystem or network confinement.
          [External] declares that another boundary owns confinement. *)

val confined :
  reads:reads ->
  writable_roots:Spice_path.Abs.t list ->
  protected_paths:Spice_path.Abs.t list ->
  network:Network.t ->
  environment:Environment.t ->
  t
(** [confined ~reads ~writable_roots ~protected_paths ~network]
    is a confined policy with normalized lists.

    Writable roots and private scratch are included in [Only] read roots.
    Duplicate and redundant descendant roots collapse, order is canonical, and
    protected paths outside writable roots are discarded. *)

val direct : environment:Environment.t -> t
(** [direct ~environment] requests direct execution without Spice filesystem or network
    confinement. *)

val external_ : environment:Environment.t -> t
(** [external_ ~environment] declares an external confinement boundary that Spice does not
    verify. *)

val environment : t -> Environment.t
(** [environment t] is the exact child environment shared by every execution
    route for [t]. *)

val reads : t -> reads option
(** [reads t] is [Some reads] for a confined policy and [None] for direct and
    external policies. *)

val writable_roots : t -> Spice_path.Abs.t list
(** [writable_roots t] is the confined policy's writable roots in canonical
    order, or [[]] when [t] is direct or external. *)

val protected_paths : t -> Spice_path.Abs.t list
(** [protected_paths t] is the confined policy's protected absolute paths in
    canonical order, or [[]] when [t] is direct or external. *)

val network : t -> Network.t option
(** [network t] is the confined policy's network access, or [None] when [t] is
    direct or external. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] describe the same process policy. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. The output is not stable storage
    syntax. *)
