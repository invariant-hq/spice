(** Condition-driven Spice sessions running under a real pseudo-terminal. *)

type t
(** The type for a live PTY session. Values remain valid only during the
    callback passed to {!run} or {!run_shell}. *)

val screen : t -> string
(** [screen session] is the latest complete, non-blank terminal frame. *)

val raw : t -> string
(** [raw session] is every byte read from the PTY so far. *)

val exited : t -> bool
(** [exited session] reports whether the PTY reached EOF or an equivalent
    platform exit indication. *)

val wait : ?deadline:float -> t -> (string -> bool) -> unit
(** [wait t predicate] returns once [predicate] holds on a complete screen. It
    fails if the child exits first or the deadline expires. *)

val wait_raw : ?deadline:float -> t -> (string -> bool) -> unit
(** [wait_raw session predicate] returns once [predicate] holds on the raw byte
    stream, or fails on exit or timeout. *)

val wait_exit : ?deadline:float -> t -> unit
(** [wait_exit session] waits for the child to exit or fails on timeout. *)

val send : t -> string -> unit
(** [send session bytes] writes all [bytes] to the PTY. *)

val resize : t -> rows:int -> cols:int -> unit
(** [resize session ~rows ~cols] resizes both the PTY and the screen emulator.
*)

val quit : t -> unit
(** [quit session] performs Spice's double-Control-C shutdown and waits for
    exit. *)

val spice_bin : unit -> string
(** [spice_bin ()] is the verified executable path from [SPICE_BIN]. *)

val run :
  ?provider:Provider_process.t ->
  ?command:string list ->
  ?args:string list ->
  ?unset:string list ->
  ?env:(string * string) list ->
  ?rows:int ->
  ?cols:int ->
  ?ready:(string -> bool) ->
  Project.t ->
  (t -> 'a) ->
  'a
(** [run project f] launches Spice in a real PTY, waits until [ready] holds,
    calls [f], and always closes the PTY. [command] precedes Spice's [--cwd]
    option; [args] follows it. *)

val run_shell :
  ?provider:Provider_process.t ->
  ?unset:string list ->
  ?env:(string * string) list ->
  ?rows:int ->
  ?cols:int ->
  ?ready:(string -> bool) ->
  Project.t ->
  script:string ->
  (t -> 'a) ->
  'a
(** [run_shell project ~script f] launches [script] through [/bin/sh] in a real
    PTY, waits until [ready] holds, calls [f], and always closes the PTY. *)
