(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Alternate-screen terminal UI for Spice.

    The interactive TUI behind the default [spice] command (design docs in
    doc/ui-design; genesis as the tui-next rewrite in doc/plans/tui-next.md).
    The previous generation is parked, unbuilt, under [_tui_old/]. *)

module Startup : sig
  (** TUI startup configuration.

      Construct one with {!make} and pass it to {!run}. *)

  type t
  (** The type for one TUI run's startup input. *)

  val make :
    ?cwd:Spice_path.Abs.t ->
    ?mode:Spice_protocol.Mode.t ->
    ?session:Spice_session.Id.t ->
    unit ->
    t
  (** [make ?cwd ?mode ?session ()] is startup input for one TUI run. [cwd] is
      the workspace root; when absent the runtime resolves the process working
      directory. [mode] is the turn mode the first runner is built under
      (default {!Spice_protocol.Mode.default}). [session] resumes that saved
      session at launch ([spice resume]): the TUI opens on its replayed
      transcript instead of the home stage. *)
end

module Error : sig
  (** TUI startup and runtime errors. *)

  type t
  (** The type for TUI startup and runtime errors. *)

  val message : t -> string
  (** [message t] is the user-facing diagnostic text for [t]. *)

  val diagnostic : t -> Spice_diagnostic.t
  (** [diagnostic t] is [t] as a structured Spice diagnostic. *)
end

module Goodbye : sig
  (** The farewell printed to the normal terminal once the TUI exits. *)

  val render : color:bool -> session:Spice_session.Id.t option -> string
  (** [render ~color ~session] is the parting frame: the two-row brand lockup
      and, when [session] is [Some id], a muted line naming the resume command
      [spice resume ID]. A quit with no session ([None]) prints the lockup alone.
      [color] toggles ANSI styling; [false] emits plain text for [NO_COLOR] and
      non-color terminals. Written to stdout after {!run} returns, once the
      alternate screen has restored. *)
end

type outcome = { last_session : Spice_session.Id.t option }
(** TUI outcome after the terminal exits. [last_session] is always [None] until
    the turn loop lands. *)

val run :
  stdenv:Eio_unix.Stdenv.base ->
  startup:Startup.t ->
  unit ->
  (outcome, Error.t) result
(** [run ~stdenv ~startup ()] runs the interactive TUI in the
    current terminal. [Error e] reports unsupported terminals or recoverable
    runtime failures. *)
