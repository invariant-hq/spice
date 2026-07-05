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
  unit ->
  (outcome, [ `No_tty | `Runtime of string ]) result
(** [run ~stdenv ~startup ()] runs the TUI in the current
    terminal. [`No_tty] reports an unsupported or non-interactive terminal;
    [`Runtime message] reports a recoverable bootstrap failure. *)
