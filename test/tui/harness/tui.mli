(** Deterministic in-process Spice TUI test sessions.

    [run] owns the application, temporary project, virtual clock, optional
    provider runtime, and all associated resources. Virtual time moves only
    through {!advance}; {!settle} observes quiescence without moving time. *)

type t
(** The type for a live in-process TUI session. Values remain valid only during
    the callback passed to {!run}. *)

type sandbox = [ `Read_only | `Workspace_write | `Danger_full_access ]
(** The sandbox mode selected for the application under test. *)

val run :
  ?size:int * int ->
  ?env:(string * string) list ->
  ?unordered:bool ->
  ?review:bool ->
  ?openai_auth:bool ->
  ?sandbox:sandbox ->
  ?provider:Provider_script.t ->
  ?session:string ->
  ?draft:string ->
  ?submit:string ->
  ?unset:string list ->
  ?seed:(Project.t -> unit) ->
  name:string ->
  (t -> unit) ->
  unit
(** [run ~name f] runs one application and calls [f] after launch. [draft] and
    [submit] are mutually exclusive. Resources are stopped before [run] returns,
    including if [f] raises. *)

val keys : t -> string -> unit
(** [keys session bytes] feeds terminal input bytes through the real input
    decoder. *)

val enter : t -> unit
(** [enter session] sends the Enter key. *)

val paste : t -> string -> unit
(** [paste session text] sends [text] using terminal bracketed-paste framing. *)

val resize : t -> width:int -> height:int -> unit
(** [resize session ~width ~height] changes the headless terminal size. *)

val settle : t -> unit
(** [settle t] waits until the application's single runtime probe has no
    runnable work and the current frame is stable. Work blocked on a held
    provider gate is an intentional observation point and does not prevent
    settlement. [settle] does not advance virtual time. *)

val advance : t -> float -> unit
(** [advance session seconds] moves virtual time by [seconds], then settles the
    application. *)

val screen : t -> string
(** [screen session] is the current rendered cell grid. *)

val print : t -> unit
(** [print session] writes the normalized, row-numbered current frame. *)

val project : t -> Project.t
(** [project session] is the temporary workspace owned by [session]. *)

val await_request : t -> int -> string
(** [await_request session index] waits for provider request [index] and returns
    its body. *)

val await_turn : t -> int -> string
(** [await_turn session index] waits for provider request [index], its ungated
    response, and the resulting turn settlement, then returns the request body.
*)

val await_file : ?timeout:float -> t -> string -> unit
(** [await_file ?timeout session path] pumps the application until [path]
    exists in the temporary project. [timeout] defaults to five real seconds.
    *)

val release : t -> string -> unit
(** [release session gate] resolves provider [gate] and settles the app. *)

val release_response : t -> string -> unit
(** [release_response session gate] resolves provider [gate] and waits only
    until its response is written. Unlike {!release}, it does not wait for work
    that response schedules to settle. *)

val release_background : t -> string -> unit
(** [release_background session gate] resolves a child-run provider [gate] and
    waits until its delivery is rendered, while allowing unrelated held work to
    remain pending. *)

(** {1:advanced Advanced synchronization} *)

val settle_pending_perform : ?provider_responses:int -> t -> unit
(** [settle_pending_perform session] settles a flow whose perform operation
    intentionally remains pending. [provider_responses] additionally requires
    that many scripted responses to have been fully written before the frame is
    considered stable. *)

val await_suspend : t -> unit
(** [await_suspend session] waits until a tool-call drain settles and its dialog
    is rendered. *)

val settle_turn : t -> unit
(** [settle_turn session] waits for the main-session settlement and settles its
    resulting frame while allowing a held provider request to remain
    outstanding. *)

val await_review_refresh : t -> (unit -> unit) -> unit
(** [await_review_refresh session change] applies [change], waits for the real
    workspace watcher, advances the virtual debounce, and settles. *)

val await_exit : ?timeout:float -> t -> unit
(** [await_exit ?timeout session] waits until the application has returned an
    outcome. [timeout], when supplied, bounds the wait in real seconds. *)

val exits_within : t -> float -> bool
(** [exits_within session seconds] waits up to [seconds] for the application to
    return. It is [false] on timeout instead of raising. *)

val outcome : t -> Spice_tui.outcome
(** [outcome session] is the completed application outcome.

    Raises [Failure] if the application has not exited. *)
