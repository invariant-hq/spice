(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Workspace-scoped filesystem observations.

    This module is the impure companion to {!Spice_workspace}. It keeps the
    workspace model pure while centralizing the filesystem checks that must
    agree across every workspace consumer: tool readers, writers, listers,
    searchers, and host instruction discovery.

    The base functions report path observation failures: resolution,
    containment, missing targets, unexpected filesystem kinds, and I/O errors.
    The {!Edit} submodule provides the shared UTF-8 text-file interpretation
    used by tools that lower mutations to {!Spice_edit}. Tool-specific planning
    such as exact replacements, anchored edits, patch parsing, and freshness
    diagnostics remains in the concrete tool. *)

type expected =
  | Regular_file
  | Directory  (** Expected filesystem target kind for kind checks. *)

module Error : sig
  type t =
    | Workspace of Spice_workspace.Resolve_error.t
        (** The workspace path model rejected the path or component. *)
    | Not_found of Spice_workspace.Path.t
        (** The filesystem target does not exist. *)
    | Escapes_workspace of Spice_workspace.Path.t
        (** The target resolves outside the workspace roots. *)
    | Unexpected_kind of {
        path : Spice_workspace.Path.t;
        expected : expected;
        actual : Eio.File.Stat.kind;
      }  (** The target exists but has the wrong filesystem kind. *)
    | Io of Spice_workspace.Path.t option * string
        (** Filesystem observation failed. *)

  val message : t -> string
  (** [message error] is a human-readable diagnostic. *)
end

val protected_meta_names : string list
(** [protected_meta_names] are the top-level workspace metadata directory names
    ([".git"], [".spice"]) that tools must not modify. This is the single source
    shared by the write-side guard in {!Edit.io} and the command sandbox's
    protected-meta carveouts, so a run cannot rewrite version-control or
    authority state through either the edit tools or the confined shell. *)

val protected_meta_component :
  workspace:Spice_workspace.t -> Spice_workspace.Path.t -> string option
(** [protected_meta_component ~workspace path] is [Some name] when [path] is, or
    lies under, a {!protected_meta_names} entry [name] at the top level of some
    workspace root, and [None] otherwise.

    The test is lexical: it does not require [path] to exist, so creating a
    protected path that does not exist yet is still caught. {!Edit.io} uses it
    to refuse write transitions against protected metadata. *)

val resolve :
  workspace:Spice_workspace.t ->
  string ->
  (Spice_workspace.Path.t, Error.t) result
(** [resolve ~workspace input] resolves raw path [input] in [workspace].

    This is workspace path resolution, not a filesystem observation. Use
    {!regular}, {!regular_opt}, or {!directory} before treating the path as an
    existing target. *)

val stat :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?follow_symlink:bool ->
  Spice_workspace.Path.t ->
  (Eio.File.Stat.t option, Error.t) result
(** [stat ~fs ~workspace ?follow_symlink path] stats [path] inside [workspace].

    [None] means the target is missing or an intermediate component is not a
    directory. [follow_symlink] defaults to [true]. If following is enabled, the
    resolved target must still be contained by one of the workspace roots. When
    following is disabled, symlink entries are reported without checking their
    targets. *)

val regular_opt :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?follow_symlink:bool ->
  Spice_workspace.Path.t ->
  (Eio.File.Stat.t option, Error.t) result
(** [regular_opt ~fs ~workspace ?follow_symlink path] checks that [path] is
    missing or exists as a regular file inside [workspace].

    [follow_symlink] defaults to [false]. If following is enabled, the resolved
    target must still be contained by one of the workspace roots. *)

val regular :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?follow_symlink:bool ->
  Spice_workspace.Path.t ->
  (Eio.File.Stat.t, Error.t) result
(** [regular ~fs ~workspace ?follow_symlink path] checks that [path] exists as a
    regular file and remains inside [workspace].

    [follow_symlink] defaults to [false]. If following is enabled, the resolved
    target must still be contained by one of the workspace roots. *)

val directory :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?follow_symlink:bool ->
  Spice_workspace.Path.t ->
  (Eio.File.Stat.t, Error.t) result
(** [directory ~fs ~workspace ?follow_symlink path] checks that [path] exists as
    a directory and remains inside [workspace].

    [follow_symlink] defaults to [false]. If following is enabled, the resolved
    target must still be contained by one of the workspace roots. *)

val child :
  Spice_workspace.Path.t -> string -> (Spice_workspace.Path.t, Error.t) result
(** [child parent name] is [name] below [parent].

    Errors with {!Workspace} if [name] is not a valid single path component. *)

val read_dir_names :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?follow_symlink:bool ->
  Spice_workspace.Path.t ->
  (string list, Error.t) result
(** [read_dir_names ~fs ~workspace ?follow_symlink path] lists entry names in
    directory [path].

    [path] must be an existing directory inside [workspace]. Names are returned
    in filesystem order.

    [follow_symlink] defaults to [false]. When [true], a [path] that is itself a
    symlink to an in-workspace directory is followed and its target's entries
    are listed; containment is re-checked on the resolved target. *)

val load_regular :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?follow_symlink:bool ->
  Spice_workspace.Path.t ->
  (string, Error.t) result
(** [load_regular ~fs ~workspace ?follow_symlink path] loads [path] as a
    complete regular file inside [workspace].

    [follow_symlink] defaults to [false]. If following is enabled, the resolved
    target must still be contained by one of the workspace roots. *)

val with_regular_in :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?follow_symlink:bool ->
  Spice_workspace.Path.t ->
  (Eio.File.ro_ty Eio.Resource.t -> 'a) ->
  ('a, Error.t) result
(** [with_regular_in ~fs ~workspace ?follow_symlink path f] opens [path] as a
    regular file inside [workspace] and calls [f] with the input flow.

    [follow_symlink] defaults to [false]. If following is enabled, the resolved
    target must still be contained by one of the workspace roots. Eio exceptions
    raised while opening the file are returned as {!Error.Io}; exceptions raised
    by [f] are not caught. *)

val ensure_parent_dirs :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  Spice_workspace.Path.t ->
  (Spice_workspace.Path.t list, Error.t) result
(** [ensure_parent_dirs ~fs ~workspace path] creates missing parent directories
    for [path] inside [workspace].

    The returned list contains directories created by the call, ordered from
    shallowest to deepest. Existing parent components must be directories and no
    component may be a symlink. The operation is not transactional; callers that
    need rollback must remove returned directories themselves when later work
    fails. *)

val eio_error : ?path:Spice_workspace.Path.t -> exn -> Error.t
(** [eio_error ?path exn] classifies an Eio filesystem exception. *)

module Edit : sig
  (** Workspace filesystem bridge for {!Spice_edit}.

      This module centralizes complete UTF-8 file reads, binary detection, size
      checks, atomic writes, optional parent-directory creation, and
      {!Spice_edit.Apply.io} construction. It does not plan edits or map
      failures to tool result text. *)

  val binary_sample_bytes : int
  (** [binary_sample_bytes] is the maximum prefix read for early binary
      detection. *)

  val read_text :
    fs:_ Eio.Path.t ->
    workspace:Spice_workspace.t ->
    max_bytes:int ->
    ?follow_symlink:bool ->
    Spice_workspace.Path.t ->
    (string, Spice_edit.Error.t) result
  (** [read_text ~fs ~workspace ~max_bytes ?follow_symlink path] reads [path] as
      a complete regular UTF-8 text file inside [workspace].

      The target must exist, be a regular file, remain contained by [workspace],
      be no larger than [max_bytes], and decode as UTF-8. Binary files are
      rejected before full decoding when possible.

      [follow_symlink] defaults to [false]. If following is enabled, the
      resolved target must still be contained by one of the workspace roots;
      containment is re-checked after the symlink is followed, so following
      never weakens the workspace guard. *)

  val target :
    fs:_ Eio.Path.t ->
    workspace:Spice_workspace.t ->
    max_bytes:int ->
    ?follow_symlink:bool ->
    Spice_workspace.Path.t ->
    (Spice_edit.Observed.t, Spice_edit.Error.t) result
  (** [target ~fs ~workspace ~max_bytes ?follow_symlink path] reads [path] as an
      edit target.

      Missing paths become {!Spice_edit.Observed.Missing}; valid text regular
      files become {!Spice_edit.Observed.Text}; binary or invalid UTF-8 regular
      files become {!Spice_edit.Observed.Other}. Oversized files and filesystem
      observation failures are returned as structured {!Spice_edit.Error.t}
      values.

      [follow_symlink] defaults to [false] and behaves as in {!read_text}:
      following remains containment-checked. *)

  val io :
    fs:_ Eio.Path.t ->
    workspace:Spice_workspace.t ->
    max_bytes:int ->
    ?create_parent_dirs:bool ->
    ?allow_remove:bool ->
    ?remove_error:string ->
    unit ->
    Spice_edit.Apply.io * (unit -> Spice_workspace.Path.t list)
  (** [io ~fs ~workspace ~max_bytes ()] is an edit IO implementation plus a
      thunk returning parent directories created by writes.

      [create_parent_dirs] defaults to [false]. When [true], create transitions
      create missing parent directories before an exclusive create; directories
      created for a failed create are rolled back when still empty.

      [allow_remove] defaults to [false]. When [false], delete transitions
      report [remove_error], which defaults to ["delete is not supported"].

      The returned IO commits complete transitions: missing-to-text uses an
      exclusive create, text-to-text uses an atomic replacement, and
      text-to-missing removes the target when removal is allowed. *)
end
