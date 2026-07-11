(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The impure runtime: terminal bootstrap, the Mosaic loop, and the command
    interpreter.

    It boots the alt-screen, loads the host for the brief, and — on the first
    submit — attaches the session's {!Spice_host.Live}, folds its events and
    settles into {!App} messages, and submits turns. *)

type outcome = { last_session : Spice_session.Id.t option }
(** The type for the runtime result. [last_session] is the id of the session
    created on the first submit, or [None] when no turn was started. *)

val run :
  stdenv:Eio_unix.Stdenv.base ->
  startup:App.startup ->
  ?clock:float Eio.Time.clock_ty Eio.Std.r ->
  ?matrix:Matrix.app ->
  ?probe:(Mosaic.Probe.t -> unit) ->
  ?process_env:Spice_host.Env.t ->
  unit ->
  (outcome, [ `No_tty | `Runtime of string ]) result
(** [run ~stdenv ~startup ()] runs the TUI in the current terminal. [`No_tty]
    reports an unsupported or non-interactive terminal; [`Runtime message]
    reports a recoverable bootstrap failure.

    The optional arguments swap the runtime's environment for an alternate one —
    a headless backend, a virtual clock, a pinned process environment — and
    default to the production wiring:
    - [clock] is the clock every runtime timestamp, sleep, and session-id mint
      reads. Defaults to [Eio.Stdenv.clock stdenv].
    - [matrix] is the terminal backend. Defaults to [Matrix_eio.create] over
      [stdenv]'s TTY; supplying one skips the interactive-TTY gate, since the
      backend owns its own I/O.
    - [probe] receives the {!Mosaic.Probe.t} before the loop starts, extended
      with [spice.live] for main-session work through settlement and
      [spice.jobs] for child-run drains owned outside Mosaic.
    - [process_env] is the environment snapshot host configuration reads.
      Defaults to {!Spice_host.Env.current}.

    Commands performed by the Mosaic application run in daemon fibers. Eio
    cancellation unwinds those fibers. A turn-construction exception is logged
    with its recorded backtrace and delivered as a failed turn settlement, so
    the composer becomes interactive again. Another command exception is logged
    and that command is dropped; neither failure fails the shared runtime switch
    or terminates the session. Fatal exceptions outside this contained command
    boundary follow Matrix's terminal-restoring uncaught-exception path. *)
