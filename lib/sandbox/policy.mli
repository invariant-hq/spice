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
      protected_meta : string list;
      protected_paths : Spice_path.Abs.t list;
      network : Network.t;
    }
  | Direct
  | External
      (** The type for command sandbox policies.

          [Direct] requests no Spice filesystem or network confinement.
          [External] declares that another boundary owns confinement. *)

val confined :
  reads:reads ->
  writable_roots:Spice_path.Abs.t list ->
  protected_meta:string list ->
  protected_paths:Spice_path.Abs.t list ->
  network:Network.t ->
  t
(** [confined ~reads ~writable_roots ~protected_meta ~protected_paths ~network]
    is a confined policy with normalized lists.

    Writable roots are included in [Only] read roots. Duplicate paths and
    metadata names collapse and order is canonical.

    Raises [Invalid_argument] if an element of [protected_meta] is not a single
    valid path component. *)

val direct : t
(** [direct] requests direct execution without Spice filesystem or network
    confinement. *)

val external_ : t
(** [external_] declares an external confinement boundary that Spice does not
    verify. *)

val reads : t -> reads option
(** [reads t] is [Some reads] for a confined policy and [None] for direct and
    external policies. *)

val writable_roots : t -> Spice_path.Abs.t list
(** [writable_roots t] is the confined policy's writable roots in canonical
    order, or [[]] when [t] is direct or external. *)

val protected_meta : t -> string list
(** [protected_meta t] is the confined policy's protected relative metadata
    names in canonical order, or [[]] when [t] is direct or external. *)

val protected_paths : t -> Spice_path.Abs.t list
(** [protected_paths t] is the confined policy's protected absolute paths in
    canonical order, or [[]] when [t] is direct or external. *)

val write_carveouts : t -> Spice_path.Abs.t list
(** [write_carveouts t] is the concrete set of paths that remains read-only
    beneath [t]'s writable roots.

    For confined policies this expands {!protected_meta} under every writable
    root and includes protected absolute paths beneath a writable root. It is
    [[]] for direct and external policies. *)

val network : t -> Network.t option
(** [network t] is the confined policy's network access, or [None] when [t] is
    direct or external. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] describe the same process policy. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] for diagnostics. The output is not stable storage
    syntax. *)
