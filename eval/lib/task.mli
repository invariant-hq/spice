(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Inert evaluation task descriptions.

    A task states what an agent should attempt: where the workspace comes from,
    which setup commands a runner should execute, the prompt to send, and the
    checks that grade the completed attempt. Tasks are pure data; workspace
    materialization and command execution are runner responsibilities. *)

(** {1:types Types} *)

(** A source from which an eval runner can materialize a workspace. *)
type source = private
  | Git of { url : string; rev : string }
      (** A Git repository [url] checked out at revision [rev]. *)
  | Dir of string
      (** A local directory path. Relative paths are interpreted by runners. *)

val git : url:string -> rev:string -> source
(** [git ~url ~rev] is [Git { url; rev }].

    Raises [Invalid_argument] if [url] or [rev] is empty. *)

val dir : string -> source
(** [dir path] is [Dir path].

    Raises [Invalid_argument] if [path] is empty. *)

type limits = {
  timeout_s : float option;
      (** Optional wall-clock timeout hint, in seconds. *)
  steps : int option;  (** Optional agent turn or step budget hint. *)
}
(** Runner limits attached to a task.

    Limits are hints in the core schema. Runner code decides how to enforce them
    for a particular agent adapter. *)

type t
(** A validated eval corpus task.

    Task identifiers, prompts, setup commands, and check names are non-empty.
    Check names must be unique within a task. *)

(** {1:constructors Constructors} *)

val make :
  ?tags:string list ->
  ?metadata:(string * string) list ->
  ?setup:string list ->
  ?limits:limits ->
  string ->
  source:source ->
  prompt:string ->
  Check.t list ->
  t
(** [make ?tags ?metadata ?setup ?limits id ~source ~prompt checks] is a task
    named [id].

    Optional arguments default as follows:
    - [tags] defaults to [[]].
    - [metadata] defaults to [[]].
    - [setup] defaults to [[]].
    - [limits] defaults to [None].

    Raises [Invalid_argument] if [id], [prompt], a tag, a metadata key or value,
    or a setup command is empty; if [checks] is empty; if two checks have the
    same {!Check.name}; if [limits.timeout_s] is present and not a positive
    finite float; or if [limits.steps] is present and not positive. *)

(** {1:queries Queries} *)

val id : t -> string
(** [id task] is [task]'s non-empty identifier. *)

val source : t -> source
(** [source task] is the workspace source. *)

val setup : t -> string list
(** [setup task] is the setup command list, in runner execution order. *)

val prompt : t -> string
(** [prompt task] is the prompt given to the agent. *)

val checks : t -> Check.t list
(** [checks task] is the non-empty list of grading descriptions. *)

val tags : t -> string list
(** [tags task] is the task's ordered list of non-empty tags. *)

val metadata : t -> (string * string) list
(** [metadata task] is the task's ordered list of non-empty key/value metadata.
    The core library does not interpret metadata keys. *)

val limits : t -> limits option
(** [limits task] is [Some limits] if runner limits were supplied and [None]
    otherwise. *)

(** {1:formatting Formatting} *)

val pp_source : Format.formatter -> source -> unit
(** [pp_source ppf source] formats [source] for human-readable diagnostics. The
    output is not a stable serialization format. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf task] formats [task] for human-readable diagnostics. The output is
    not a stable serialization format. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are structurally equal. *)
