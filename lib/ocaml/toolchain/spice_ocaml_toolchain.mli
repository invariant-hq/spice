(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Keeping the OCaml toolchain reachable for spawned tools.

    Spice hands the OCaml tools it spawns ([dune], [ocamlmerlin], the compiler)
    the environment it inherited from the process that launched it. When that
    environment's [PATH] already resolves the toolchain — Spice was launched from
    a shell with the opam switch on [PATH] — nothing here changes it. When it does
    not, this module recovers the switch [bin] directory from the variables opam
    exports and prepends it to [PATH], so a session launched without the switch on
    [PATH] still finds [dune].

    Recovery reads variables opam already set ([DUNE_OCAML_STDLIB], then
    [OPAM_SWITCH_PREFIX]); it never runs [opam env]. Every operation is a no-op
    when the tool already resolves, so it can never shadow a reachable toolchain.

    Two transports need different treatment. An inner [/bin/sh -c] resolves a bare
    program against the {e environment}'s [PATH], so {!augment} alone suffices
    (the confined shell, [dune build --watch]). A direct [execvp]/[execve] resolves
    a bare program against the {e process}'s [PATH] — not the environment handed to
    the child — so those callers also need {!locate} to pin an absolute executable
    (the [dune describe] capture, the Merlin transport, the OCaml evaluator). *)

val bin_dir : lookup:(string -> string option) -> string option
(** [bin_dir ~lookup] is the OCaml toolchain [bin] directory recovered from the
    opam-exported variables [lookup] resolves, or [None] when none is set.

    It tries, in order, [DUNE_OCAML_STDLIB] (whose [<prefix>/lib/ocaml] value
    yields [<prefix>/bin]) then [OPAM_SWITCH_PREFIX] (yielding [<prefix>/bin]).
    The directory is returned whether or not it exists on disk; callers that
    prepend it tolerate an absent directory. *)

val resolves_on_path : path:string -> string -> bool
(** [resolves_on_path ~path program] is [true] iff [program] resolves to an
    executable file in one of [path]'s [PATH]-separated directories. Empty entries
    are skipped and [program] is joined by basename, mirroring the [execvp]-style
    search the spawn transports perform. *)

val augment : string array -> program:string -> string array
(** [augment env ~program] is [env] unchanged when [program] already resolves on
    [env]'s [PATH]; otherwise [env] with {!bin_dir} — recovered from [env]'s own
    bindings — prepended to [PATH]. When [env] has no [PATH] binding and a
    directory is recovered, a [PATH] binding is added. A no-op whenever [program]
    is already reachable. *)

val unreachable_hint : program:string -> string
(** [unreachable_hint ~program] is guidance for when [program] could not be found.
    Spice inherits the [PATH] of the process that launched it, which may expose
    [program] only through a shell alias or a hook that child processes do not
    inherit. It advises relaunching from a shell where [command -v <program>]
    prints a real path (for example after [eval $(opam env)]) or putting the opam
    switch [bin] on [PATH]. It distinguishes an unreachable toolchain from a
    refused sandbox, which reports its own reason. *)

val locate : string array -> program:string -> string array * string option
(** [locate env ~program] is [(env', exe)] where [env'] is [augment env ~program]
    and [exe] is [Some abs] when [program] is a bare name that resolves to the
    executable [abs] on [env']'s [PATH], else [None] (when [program] already
    contains a directory separator, or does not resolve).

    Direct-[execvp] transports must spawn [exe] as the executable (and [argv.(0)])
    when it is [Some]: those transports search the process [PATH], not [env'], so a
    bare name would miss the toolchain directory {!augment} added to [env']. When
    [exe] is [None] the caller keeps [program] and lets the transport report its
    own not-found error. *)
