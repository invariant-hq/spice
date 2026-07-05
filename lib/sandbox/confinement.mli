(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure command confinement descriptions.

    A confinement describes what one spawned process may read, write, and reach
    on the network. It is inert data built by combinators and consumed by
    interpreters: backends lower it to platform enforcement, explain renderers
    print it, and profile hashing digests it. Constructing a confinement
    enforces nothing.

    Values are normalized: writable roots, protected paths, and protected
    metadata names are deduplicated and canonically ordered, so structurally
    equal confinement intents are equal values, render equally, and hash
    equally.

    Paths are {!Spice_path.Abs.t} lexical syntax. The confinement does not
    resolve symlinks or prove existence; hosts canonicalize paths (for example
    [/tmp] to [/private/tmp] on macOS) before building the confinement so the
    described confinement matches the enforced one. *)

type network =
  | Restricted
  | Enabled  (** Requested network capability for the spawned command. *)

type t
(** The type for confinement descriptions. *)

val read_only : t
(** [read_only] permits reads of everything, no writes, and no network.

    This is the base value every confinement is built from. *)

val writable : Spice_path.Abs.t list -> t -> t
(** [writable roots t] adds [roots] as writable subtrees.

    Duplicate roots collapse; order is canonical. Adding no roots is the
    identity. *)

val protect_meta : string list -> t -> t
(** [protect_meta names t] protects relative [names] under every writable root,
    for example [".git"].

    Protected metadata stays read-only inside otherwise writable subtrees.

    Raises [Invalid_argument] if a name is not a single valid path component
    (see {!Spice_path.Rel.is_component}). *)

val protect : Spice_path.Abs.t list -> t -> t
(** [protect paths t] protects absolute [paths] from writes regardless of
    writable roots. *)

val network : network -> t -> t
(** [network state t] sets the requested network capability. *)

val writable_roots : t -> Spice_path.Abs.t list
(** [writable_roots t] are the writable subtrees in canonical order. *)

val protected_meta : t -> string list
(** [protected_meta t] are the protected relative names in canonical order. *)

val protected_paths : t -> Spice_path.Abs.t list
(** [protected_paths t] are the protected absolute paths in canonical order. *)

val write_carveouts : t -> Spice_path.Abs.t list
(** [write_carveouts t] are the protected concrete paths that must remain
    read-only inside otherwise writable roots.

    This expands every {!protected_meta} name under every writable root and
    includes protected absolute paths that fall under a writable root. The
    result is canonical and backend-independent, so platform lowerings cannot
    drift on nested-root behavior. *)

val network_state : t -> network
(** [network_state t] is the requested network capability. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] describe the same confinement. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats a confinement for diagnostics. The output is not stable storage
    syntax. *)
