(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure workspace address resolution.

    A workspace is a set of admitted roots plus a current directory used to
    resolve relative input. Workspace paths are lexical addresses below those
    roots.

    The common construction path is: build roots with {!Root.make}, construct a
    workspace with {!make} or {!single}, resolve raw user or product input with
    {!resolve_string}, and pass the resulting {!Path.t} to host layers that
    perform filesystem observation and permission checks.

    This module is pure. It does not inspect the filesystem, discover roots,
    list directories, read files, classify entries, track freshness, authorize
    edits, or apply patches. *)

module Error = Error
(** Workspace construction and membership errors. *)

module Resolve_error = Resolve_error
(** Workspace path resolution errors. *)

module Root = Root
(** Workspace roots. *)

module Path = Path
(** Workspace paths. *)

type t
(** The type for pure workspaces.

    Invariant: a workspace has at least one root, root keys and logical
    directories have a bijective relationship, and [cwd] belongs to one of the
    admitted roots. Root order is preserved and participates in equality. *)

val make : ?cwd:Path.t -> Root.t list -> (t, Error.t) result
(** [make ?cwd roots] is a workspace whose roots are [roots].

    [roots] must be non-empty. Duplicate roots with the same stable key and
    logical directory are removed, preserving the first occurrence. A stable key
    cannot be reused for a different logical directory, and a logical directory
    cannot be admitted under more than one stable key.

    [cwd] defaults to the first root. If provided, [cwd] must belong to one of
    the workspace roots. The stored [cwd] is canonicalized to use the admitted
    root value from [roots].

    Errors with {!Error.Empty_roots} if [roots] is empty. Errors with
    {!Error.Conflicting_root} if the same stable key is used for different
    logical directories or the same logical directory is used with different
    stable keys. Errors with {!Error.Root_not_in_workspace} if [cwd] belongs to
    an unknown root. *)

val single : ?cwd:Spice_path.Rel.t -> Root.t -> t
(** [single ?cwd root] is a single-root workspace.

    [cwd] is root-relative and defaults to {!Spice_path.Rel.root}. This
    constructor cannot fail because [root] is admitted by construction and [cwd]
    is already normalized typed syntax. *)

val roots : t -> Root.t list
(** [roots workspace] are the unique workspace roots in construction order. *)

val cwd : t -> Path.t
(** [cwd workspace] is the current workspace path. *)

val root_path : t -> Path.t
(** [root_path workspace] is the root path at the first admitted workspace root.

    This is independent of {!cwd}; it is the stable default root for operations
    that need a workspace-level directory rather than the current directory. *)

val with_cwd : t -> Path.t -> (t, Error.t) result
(** [with_cwd workspace cwd] is [workspace] with current path [cwd].

    The stored current directory is canonicalized to use the admitted root value
    from [workspace].

    Errors with {!Error.Root_not_in_workspace} if [cwd] belongs to an unknown
    root. *)

val make_path : t -> root:Root.t -> Spice_path.Rel.t -> (Path.t, Error.t) result
(** [make_path workspace ~root rel] is [rel] below [root], if [root] belongs to
    [workspace].

    This is useful when reconstructing workspace paths from durable session or
    permission records that already carry a root identity and root-relative
    syntax. The returned path uses the admitted root from [workspace].

    Errors with {!Error.Root_not_in_workspace} if [root] is not in [workspace].
*)

val contains_path : t -> Path.t -> bool
(** [contains_path workspace path] is [true] iff an equal [Path.root path] is
    admitted by [workspace]. *)

val import_abs : t -> Spice_path.Abs.t -> (Path.t, Resolve_error.t) result
(** [import_abs workspace abs] imports [abs] as a workspace path.

    When multiple roots match, the most specific root wins. Errors with
    {!Resolve_error.Outside_workspace} if [abs] is outside all roots.

    Successful conversion proves lexical containment only. Filesystem existence,
    kind, permission, and symlink containment checks belong to the host
    observation layer. *)

val resolve_string : t -> string -> (Path.t, Resolve_error.t) result
(** [resolve_string workspace input] parses and resolves raw path input.

    Absolute input must be inside one of the workspace roots. Relative input is
    parsed and resolved against {!cwd} as a logical absolute path and then
    imported with the same most-specific-root rule as {!import_abs}. Use this at
    raw product/user input boundaries. Prefer {!Path.append}, {!make_path}, or
    {!import_abs} when the caller already has typed path syntax.

    Errors with {!Resolve_error.Invalid_input} if [input] is malformed or
    cannot be parsed as a relative or absolute path. Errors with
    {!Resolve_error.Outside_workspace} if [input] parses successfully but is
    outside every admitted root after resolution against {!cwd}. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same roots in the same order
    and the same current path. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf workspace] formats a compact diagnostic representation of
    [workspace]. *)
