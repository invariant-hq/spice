(** External fake-provider processes for PTY tests. *)

type t
(** The type for a running provider process. Values remain valid only during the
    callback passed to {!with_script}. *)

val base_url : t -> string
(** [base_url provider] is the OpenAI-compatible [/v1] endpoint. *)

val with_script :
  ?unordered:bool ->
  ?delay_ms:int ->
  Project.t ->
  Provider_script.t ->
  (t -> 'a) ->
  'a
(** [with_script project script f] serves [script] from a child process and
    calls [f] with its connection information. The process is stopped before
    returning, including if [f] raises. *)

val with_openai :
  ?expect:string list -> Project.t -> answer:string -> (t -> 'a) -> 'a
(** [with_openai project ~answer f] serves one successful completion while [f]
    executes. [expect] lists required request-body fragments. *)
