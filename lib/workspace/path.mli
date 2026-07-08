(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace-root-relative addresses.

    A workspace path is a pure lexical address below a workspace root.

    It proves only lexical membership in a workspace root. It does not prove
    that the filesystem target exists, that it has a particular kind, or that
    following symlinks remains inside the root. *)

type t
(** The type for workspace paths.

    A value is a pair of a {!Root.t} and a normalized {!Spice_path.Rel.t}. It
    may name a regular file, directory, symlink, special file, or missing
    target.

    A [Path.t] may be constructed directly with {!make}, but values received
    from untrusted or user-facing strings should come from
    {!Spice_workspace.resolve_string} so workspace membership and current
    directory semantics are applied before use. *)

val make : root:Root.t -> Spice_path.Rel.t -> t
(** [make ~root rel] is [rel] below [root].

    This is a low-level constructor. Use {!Spice_workspace.make_path} when the
    root should be checked against a workspace, {!append} for typed relative
    paths below an existing workspace path, {!Spice_workspace.import_abs} for
    absolute paths, or {!Spice_workspace.resolve_string} for raw strings. *)

val root : t -> Root.t
(** [root path] is [path]'s workspace root. *)

val rel : t -> Spice_path.Rel.t
(** [rel path] is [path]'s root-relative path. *)

val abs : t -> Spice_path.Abs.t
(** [abs path] is [path]'s logical absolute path.

    The value is computed by appending [rel path] below [Root.dir (root path)].
    It is a projection, not evidence that the target exists or remains inside
    the root after symlink traversal. *)

val is_root : t -> bool
(** [is_root path] is [true] iff [rel path] is {!Spice_path.Rel.root}. *)

val basename : t -> string option
(** [basename path] is [Some name] if [path] is not a root path and [None]
    otherwise. *)

val parent : t -> t option
(** [parent path] is [Some parent] if [path] is not a root path and [None]
    otherwise. *)

val add_component : t -> string -> (t, Spice_path.Error.t) result
(** [add_component path component] appends [component] below [path].

    [component] must be a valid single path component. It must not contain a
    slash or backslash separator, be [.] or [..], be empty, contain NUL, or use
    absolute-path syntax. Errors with
    [Spice_path.Error.Malformed_component component] if [component] is
    malformed. *)

val append : t -> Spice_path.Rel.t -> t
(** [append path suffix] appends [suffix] below [path], preserving [path]'s
    root. *)

val relativize : root:t -> t -> Spice_path.Rel.t option
(** [relativize ~root path] is [Some suffix] iff [path] is [root] or below
    [root] in the same workspace root. If [path] and [root] are equal, [suffix]
    is {!Spice_path.Rel.root}. *)

val display : t -> string
(** [display path] is [path]'s root-relative display text.

    Root paths render as ["."]. Non-root paths render as their relative path.
    Multi-root disambiguation belongs outside this module. *)

val to_string : t -> string
(** [to_string path] is [path]'s logical absolute path as text. Like {!abs},
    this is display and host-boundary text, not filesystem authority. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same root and relative path.
*)

val compare : t -> t -> int
(** [compare a b] orders paths by root and then relative path. The order is
    compatible with {!equal}. *)

module Set : Set.S with type elt = t
(** Sets of workspace paths. *)

module Map : Map.S with type key = t
(** Maps keyed by workspace paths. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf path] formats [path]'s logical absolute path. *)
