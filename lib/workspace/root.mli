(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace root identities.

    A root is a pure workspace boundary: a logical absolute directory admitted
    into a workspace plus a stable key used to recognize that boundary across
    workspace construction, permissions, and durable records.

    Roots do not inspect the filesystem, resolve symlinks, prove existence, or
    grant access. Filesystem-backed root discovery and validation belong to the
    workspace IO layer. *)

type t
(** The type for workspace roots.

    A root has two pieces of identity: a stable key, and an absolute directory
    used as the lexical base for paths below the root. It is a lexical boundary,
    not a filesystem capability.

    Two roots are equal iff they have the same stable key and logical directory.
    Use {!same_key} when comparing durable root identity alone. *)

val make : ?key:string -> Spice_path.Abs.t -> t
(** [make ?key dir] is a workspace root at logical absolute directory [dir].

    [key] is the stable root identity. It defaults to [dir]'s normalized string
    form. Callers that have a stronger host-level identity, for example a
    canonical filesystem target or container mount id, should pass it here.

    Raises [Invalid_argument] if [key] is empty. This is a programmer error in
    root construction; recoverable workspace conflicts are reported by
    {!Spice_workspace.make}. *)

val dir : t -> Spice_path.Abs.t
(** [dir root] is the logical absolute directory of [root]. *)

val key : t -> string
(** [key root] is [root]'s stable identity.

    The key is for equality-sensitive uses. It is not user-facing display text.
*)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same stable key and logical
    directory. *)

val same_key : t -> t -> bool
(** [same_key a b] is [true] iff [a] and [b] have the same stable key.

    This is the comparison used by workspace construction to detect duplicate
    and conflicting durable root identities. *)

val compare : t -> t -> int
(** [compare a b] orders roots by stable key and then logical directory. The
    order is compatible with {!equal}. It also backs workspace path ordering. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf root] formats [root]'s logical directory. *)
