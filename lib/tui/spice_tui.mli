(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Alternate-screen terminal UI for Spice.

    This is the interactive product behind the default [spice] command,
    [spice resume], and [spice review]. Construct startup input with
    {!Startup.make}; {!run} owns the alternate-screen lifetime and restores the
    normal terminal before returning. *)

module Startup : sig
  (** TUI startup configuration.

      Construct one with {!make} and pass it to {!run}. *)

  type t
  (** The type for one TUI run's startup input. *)

  (** The type for the composer's launch input. *)
  type input =
    | Empty  (** The composer starts blank. *)
    | Draft of string
        (** The composer starts seeded with the text ([--draft]). *)
    | Submit of string
        (** The text is submitted as the first turn's prompt ([-p]/[--prompt]);
            the TUI launches straight into the chat, past the home stage. *)

  (** The type for the surface the TUI launches onto. *)
  type launch =
    | Launch_chat  (** The home stage (or the chat, per {!input}/[session]). *)
    | Launch_review of { base_spec : string option }
        (** The review screen over the worktree diff ([spice review [BASE]]);
            [base_spec] is the base revision, [HEAD] when absent. Closing the
            screen quits the process. *)

  val make :
    ?cwd:Spice_path.Abs.t ->
    ?mode:Spice_protocol.Mode.t ->
    ?session:Spice_session.Id.t ->
    ?input:input ->
    ?launch:launch ->
    ?sandbox:Spice_host.Sandbox.Mode.t ->
    unit ->
    t
  (** [make ?cwd ?mode ?session ?input ?launch ?sandbox ()] is startup input for
      one TUI run. [cwd] is the workspace root; when absent the runtime resolves
      the process working directory. [mode] is the turn mode the first runner is
      built under (default {!Spice_protocol.Mode.default}). [session] resumes
      that saved session at launch ([spice resume]): the TUI opens on its
      replayed transcript instead of the home stage. [input] (default {!Empty})
      seeds the composer or submits the first prompt; combining {!Submit} with
      [session] is unsupported — callers reject it before {!run}. [launch]
      (default {!Launch_chat}) picks the launch surface. [sandbox] overrides the
      configured sandbox mode for this run's turns and user shell commands
      ([--sandbox]); the sandbox record names its origin ([(flag)] over
      [(config)]). *)
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
      [spice resume ID]. A quit with no session ([None]) prints the lockup
      alone. [color] toggles ANSI styling; [false] emits plain text for
      [NO_COLOR] and non-color terminals. Written to stdout after {!run}
      returns, once the alternate screen has restored. *)
end

type outcome = { last_session : Spice_session.Id.t option }
(** TUI outcome after the terminal exits. [last_session] is always [None] until
    the turn loop lands. *)

val run :
  stdenv:Eio_unix.Stdenv.base ->
  startup:Startup.t ->
  ?clock:float Eio.Time.clock_ty Eio.Std.r ->
  ?matrix:Matrix.app ->
  ?probe:(Mosaic.Probe.t -> unit) ->
  ?process_env:Spice_host.Env.t ->
  unit ->
  (outcome, Error.t) result
(** [run ~stdenv ~startup ()] runs the interactive TUI in the current terminal.
    [Error e] reports unsupported terminals or recoverable runtime failures.

    The optional arguments swap the runtime's environment for an alternate one
    and default to the production wiring: [clock] backs every runtime timestamp
    and sleep (default [Eio.Stdenv.clock stdenv]); [matrix] is the terminal
    backend (default a [Matrix_eio] backend over [stdenv]'s TTY — supplying one
    skips the interactive-TTY gate); [probe] receives the {!Mosaic.Probe.t} for
    the run before the loop starts; [process_env] is the environment snapshot
    host configuration reads (default {!Spice_host.Env.current}). Deterministic
    test harnesses drive the TUI through these — a headless [matrix.test]
    backend, a mock clock, and a pinned environment. *)
