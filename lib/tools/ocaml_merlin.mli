(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared single-shot [ocamlmerlin] transport for the OCaml tools.

    [Ocaml_merlin] is the one place spice invokes the project's [ocamlmerlin]
    binary. It builds the argv with Merlin's mandatory [single] selector, runs
    the child from a chosen directory with the buffer piped on standard input,
    bounds and drains its output, honours cancellation, and parses Merlin's
    [{"class":…}] result envelope. Callers decode the per-command [value]
    payload themselves; this module owns only the transport and the envelope.

    Merlin is reached through an argv {e prefix} rather than a single program
    name, so a toolchain that exposes it only via
    [dune tools exec ocamlmerlin --] is supported alongside a plain
    [ocamlmerlin] on [PATH]. The [single] selector is not optional: without it
    [ocamlmerlin] dispatches to its old-protocol frontend, where the single-shot
    query flags and the [{"class":"return"}] envelope do not exist. The module
    links nothing from Merlin and is version-decoupled. Output is deterministic
    and carries no ANSI. *)

val default_program : string list
(** The default invocation prefix, [["ocamlmerlin"]] — Merlin resolved through
    [PATH]. *)

(** Why a configured [dune tools exec] prefix could not be materialised into a
    lock-free binary. *)
type resolution_error =
  | Warm_failed of string
      (** The one-shot warming [dune tools exec] invocation could not be started
          or produced a build error; the payload is bounded diagnostic evidence.
      *)
  | Binary_not_found of string
      (** Warming ran without an error, but no built binary for the named tool
          was found under dune's dev-tool layout — for instance a future dune
          version changed that layout. The payload names the tool. *)

val resolution_error_message : resolution_error -> string
(** [resolution_error_message e] is a human-readable one-line diagnostic for
    [e], suitable to cache and surface as a tool's [Unavailable] reason. *)

val resolve_program :
  cwd:string ->
  ?env:string array ->
  ?timeout_ms:int ->
  configured:string list ->
  unit ->
  (string list, resolution_error) result
(** [resolve_program ~cwd ~configured ()] materialises a configured Merlin
    invocation {e prefix} into a lock-free argv, to be called {e once} at
    session boot in the lock-free window; the caller caches the result for the
    session.

    Resolution is filesystem-first: an already-built dev-tool binary under
    [_build/_private/<context>/.dev-tool/<pkg>/target/bin/<tool>] is a pure
    filesystem lookup that engages no dune engine and never contends with a
    running watch, so it is always preferred. The cases:

    - A bare program name that [PATH] resolves (the default [["ocamlmerlin"]] in
      an opam switch, say) is returned unchanged — it is already lock-free.
    - A bare program name that [PATH] cannot resolve (the default
      [["ocamlmerlin"]] in a dune-managed project, where there is no
      [ocamlmerlin] on [PATH] by design) falls back to dune's already-built
      dev-tool binary of the same name when one is present; otherwise the prefix
      is returned unchanged and the query reports [Unavailable] honestly.
    - An absolute/relative binary or a non-dune wrapper prefix is returned
      unchanged.
    - A [dune tools exec <tool> --] prefix resolves to the already-built
      dev-tool binary when present; only when it is absent is the tool warmed
      once with a single [dune tools exec] invocation from [cwd] (this {e does}
      engage the dune engine, hence the boot-window requirement) and then
      located under the dev-tool layout.

    On success the result is a one-element argv — the resolved dev-tool binary,
    or the passed-through prefix — which every subsequent query execs directly
    with no per-query dune engagement.

    Resolution failure (only reachable from a warmed [dune tools exec] prefix) is
    a typed {!resolution_error} the caller caches so Merlin queries do not
    re-probe (and re-engage dune under a now-held watch lock) per call. [env]
    defaults to the current process environment and supplies the [PATH] searched
    for a bare program name; [timeout_ms] bounds the warming invocation and
    defaults to a generous one-time boot budget.

    Raises [Invalid_argument] if [configured] is empty. *)

val argv :
  program:string list -> command:string -> args:string list -> string list
(** [argv ~program ~command ~args] is the full argument vector for [command]:
    [program], then Merlin's mandatory [single] selector, then [command] and
    [args]. For example
    [argv ~program:["ocamlmerlin"] ~command:"outline" ~args:["-filename"; f]] is
    [["ocamlmerlin"; "single"; "outline"; "-filename"; f]]. Callers use it both
    to run the command and to build the corresponding execution permission.

    Raises [Invalid_argument] if [program] is empty. *)

type error =
  | Cancelled  (** The call was cancelled before Merlin completed. *)
  | Unavailable of string
      (** Merlin could not be started (missing binary or exec failure). *)
  | Timed_out of { timeout_ms : int }
      (** Merlin did not finish within [timeout_ms]. *)
  | Signaled of int  (** Merlin was terminated by a signal. *)
  | Exited of { code : int; detail : string }
      (** Merlin exited non-zero. [detail] is its trimmed stderr, or its stdout
          when stderr was empty, with ANSI styling stripped and length bounded.
      *)
  | Output_exceeded of string
      (** The named stream exceeded the output cap; the response is not parsed.
      *)
  | Query_failure of { class_ : string; detail : string }
      (** Merlin returned a non-[return] envelope — class [failure], [error], or
          [exception]. [detail] is its [value], as a string when the value is
          one, otherwise its JSON encoding. *)
  | Malformed of string
      (** Merlin's stdout was not a decodable [{"class":"return",…}] envelope.
      *)

val error_message : error -> string
(** [error_message e] is a human-readable one-line diagnostic for [e]. *)

val run :
  program:string list ->
  cwd:string ->
  ?env:string array ->
  ?timeout_ms:int ->
  ?max_output_bytes:int ->
  command:string ->
  args:string list ->
  source:string ->
  cancelled:(unit -> bool) ->
  unit ->
  (Jsont.json, error) result
(** [run ~program ~cwd ~command ~args ~source ~cancelled ()] invokes
    [ocamlmerlin single command args] from [cwd] with [source] on standard
    input, and returns the [value] payload of Merlin's [return] envelope on
    success. Interpreting that payload is the caller's responsibility.

    [env] defaults to the current process environment; a non-interactive overlay
    ([TERM=dumb], [NO_COLOR], [CLICOLOR], [CLICOLOR_FORCE]) is always applied so
    child output carries no ANSI. [timeout_ms] defaults to 30s and
    [max_output_bytes] to 1 MiB, matching the shared subprocess bounds.
    [cancelled] is polled while the child runs; a cancellation yields
    [Error Cancelled]. Every other failure — a Merlin start failure, a timeout,
    a signal, a non-zero exit, an output overrun, a non-[return] envelope, or
    malformed output — is a distinct {!error}.

    Raises [Invalid_argument] if [program] is empty. *)
