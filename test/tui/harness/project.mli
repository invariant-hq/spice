(** Isolated temporary projects for TUI tests.

    A project owns a workspace root and a sibling scratch tree containing its
    home and XDG directories. Values remain valid only during the callback
    passed to {!with_temp} or {!with_git_fixture}. *)

type t
(** The type for temporary test projects. *)

val root : t -> string
(** [root project] is the absolute workspace root. *)

val path : t -> string -> string
(** [path project local] resolves [local] below the workspace root. *)

val scratch : t -> string -> string
(** [scratch project local] resolves [local] below the project-private scratch
    tree, which is outside the workspace. *)

val data : t -> string -> string
(** [data project local] resolves Spice's test XDG data path. *)

val state : t -> string -> string
(** [state project local] resolves Spice's test XDG state path. *)

val exists : t -> string -> bool
(** [exists project local] tests whether a workspace path exists. *)

val write : t -> string -> string -> unit
(** [write project local contents] writes [contents] below the workspace root.
*)

val read : t -> string -> string
(** [read project local] reads a file below the workspace root. *)

val write_scratch : t -> string -> string -> unit
(** [write_scratch project local contents] writes a private scratch file. *)

val read_scratch : t -> string -> string
(** [read_scratch project local] reads a private scratch file. *)

val write_path : string -> string -> unit
(** [write_path path contents] writes an arbitrary test-owned path, creating
    parent directories as necessary. *)

val read_path : string -> string
(** [read_path path] reads the entire file at [path]. *)

val bindings :
  ?openai_base_url:string ->
  ?unset:string list ->
  ?extra:(string * string) list ->
  t ->
  (string * string) list
(** [bindings project] is the deterministic process configuration for [project].
    Later [extra] bindings override harness defaults. *)

val env_snapshot :
  ?unset:string list -> (string * string) list -> Spice_host.Env.t
(** [env_snapshot overrides] combines the current environment with [overrides],
    excluding Dune RPC variables and names in [unset]. *)

val env_array :
  ?openai_base_url:string ->
  ?unset:string list ->
  ?extra:(string * string) list ->
  t ->
  string array
(** [env_array project] is the isolated environment passed to child processes.
*)

val apply : (string * string) list -> unit
(** [apply bindings] installs [bindings] in the current process environment. *)

val git : t -> string list -> unit
(** [git project args] runs Git with [args] in the workspace and a pinned test
    identity. It fails the test if Git exits unsuccessfully. *)

val git_baseline : t -> unit
(** [git_baseline project] initializes Git and commits the current workspace. *)

val with_temp : string -> (t -> 'a) -> 'a
(** [with_temp name f] calls [f] with a fresh project and removes the project
    and scratch trees before returning, including if [f] raises. The generated
    path has the same width as the diagnostic [name], keeping terminal layout
    stable across runs. *)

val with_git_fixture : string -> (t -> 'a) -> 'a
(** [with_git_fixture name f] creates a temporary project with a committed
    baseline and calls [f]. *)

val with_external_dune_watch : t -> (unit -> 'a) -> 'a
(** [with_external_dune_watch project f] runs [dune build --watch] for [project]
    while [f] executes, then stops it. *)

val resolve_env_path : string -> string
(** [resolve_env_path name] resolves the path stored in environment variable
    [name] against the current directory and verifies that it exists.

    Raises [Failure] if [name] is absent or its path does not exist. *)

val wait_for_file : string -> unit
(** [wait_for_file path] waits until [path] exists and is non-empty.

    Raises [Failure] if the file does not appear before the harness deadline. *)
