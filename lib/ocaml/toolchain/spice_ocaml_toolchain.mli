(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Locating the OCaml toolchain for spawned tools.

    Spice hands the OCaml tools it spawns ([dune], [ocamlmerlin], the compiler)
    the environment it inherited from the process that launched it. {!discover}
    classifies that environment once into an ordered search space — the way dune
    classifies its build environment — and {!find} resolves a program against
    it:

    + an explicit override: the [SPICE_<PROGRAM>] environment variable
      ([SPICE_DUNE] for [dune]; the program name uppercased, with runs of
      non-alphanumeric characters as [_]). An override that is set but not an
      executable file fails the resolution instead of falling through: an
      explicit choice is never silently ignored;
    + the environment's [PATH]: a correctly launched session resolves here and
      nothing is changed;
    + [$OPAM_SWITCH_PREFIX/bin]: the variable opam exports for the active
      switch;
    + [<workspace_root>/_opam/bin]: opam's local-switch layout at the workspace
      root.

    Recovery reads variables opam already exported and directories opam owns on
    disk; it never runs [opam env].

    Two transports need different treatment. An inner [/bin/sh -c] resolves a
    bare program against the {e environment}'s [PATH], so {!env} suffices. A
    direct [execvp]/[execve] resolves a bare program against the {e process}'s
    [PATH] — not the environment handed to the child — so those callers must
    spawn the absolute executable {!find} returns. *)

type t
(** The toolchain search space of one environment: its [PATH] and the toolchain
    [bin] directories recovered from opam variables and the workspace's local
    switch. Values are cheap; a [t] observes the world only at {!discover}
    (directory existence) and {!find} (executable lookup). *)

(** The rung of the search space a resolution came from. *)
module Source : sig
  type t =
    | Explicit  (** The [SPICE_<PROGRAM>] override. *)
    | Path  (** The environment's [PATH]. *)
    | Opam_switch_prefix  (** [$OPAM_SWITCH_PREFIX/bin]. *)
    | Local_switch  (** [<workspace_root>/_opam/bin]. *)

  val to_string : t -> string
  (** [to_string source] is a short human-readable name: ["SPICE_* override"],
      ["PATH"], ["OPAM_SWITCH_PREFIX"], or ["local _opam switch"]. *)
end

val discover : env:string array -> workspace_root:string option -> t
(** [discover ~env ~workspace_root] is the search space of [env]. Recovered
    directories ([$OPAM_SWITCH_PREFIX/bin], [<workspace_root>/_opam/bin]) are
    kept only when they exist on disk. [env] bindings are ["NAME=value"] entries
    as returned by [Unix.environment]. *)

val find : t -> string -> (string * Source.t) option
(** [find t program] is the absolute executable [program] resolves to on the
    search space, with its provenance, walking the rungs in order. [None] when
    no rung resolves it — including when the [SPICE_<PROGRAM>] override is set
    but not an executable file, which never falls through to later rungs. A
    [program] containing a directory separator is not searched: it is the
    caller's to spawn as given. *)

val env : t -> program:string -> string array
(** [env t ~program] is [t]'s environment, adjusted so an inner shell resolves
    [program] the way {!find} does: unchanged (physically) when [program]
    already resolves on its [PATH] and no override is set; with the override's
    directory prepended to [PATH] when [SPICE_<PROGRAM>] is in force; with the
    resolving recovered directory prepended when a recovery rung matched; and
    unchanged when nothing resolves [program] — the transport then reports its
    own failure and {!unreachable_hint} names the cause. *)

val unreachable_hint : t -> program:string -> string
(** [unreachable_hint t ~program] explains a failed {!find}: which rungs were
    checked and why each did not resolve [program] (an override set to a
    non-executable, [PATH] entries without it, opam variables unset, no local
    switch), and how to fix it — relaunch from a shell where
    [command -v program] prints a real path, or set the override. *)

val describe : t -> program:string -> string
(** [describe t ~program] is a one-line status for diagnostics surfaces:
    ["<program>: <abs> (via <source>)"] when {!find} resolves, otherwise
    ["<program>: not found (<rungs checked>)"]. *)
