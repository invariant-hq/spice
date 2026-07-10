(** Shared harness for terminal UI tests. *)

module Key = Key
(** Raw terminal key encodings. *)

module Project = Project
(** Isolated workspaces and process environments. *)

module Provider_process = Provider_process
(** External fake-provider processes used at the PTY boundary. *)

module Provider_script = Provider_script
(** Provider expectations and replies shared by both drivers. *)

module Pty = Pty_session
(** Real-process sessions driven through a pseudo-terminal. *)

module Screen = Screen
(** Screen predicates, normalization, and golden formatting. *)

module Tui = Tui
(** Deterministic in-process TUI sessions. *)
