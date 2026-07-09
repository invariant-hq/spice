(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Subagent contracts and spawn requests.

    A subagent is a model-visible host-tool request to run a child session under
    a {!Role.t} contract: the parent transcript holds an ordinary {!tool} call
    and eventual result, and the child runs in its own {!Spice_session.t}. The
    run record linking parent to child lives in {!Subagent_run}.

    {!tool} declares the spawn request and {!decode} validates it as a
    {!Spawn.t}. Construction is pure and reports invariant failures as
    diagnostic strings. *)

module Role : sig
  (** Child session roles.

      A role is a product contract for a child run, expressed as a
      {!Contract.t}: permission and tool restrictions first, with prompt text
      only explaining them to the model. Parent modes decide which roles may be
      spawned (see {!Mode.allows_role}). Roles arrive only from decoded JSON, so
      there is no string parser here. *)

  type t =
    | Explore
    | Review
    | Verify  (** The type for built-in child session roles. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable JSON spelling. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same role. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps child roles to JSON strings; an unknown spelling is a decode
      error. *)

  val contract : t -> Contract.t
  (** [contract t] is [t]'s read-only contract.

      {!Explore} and {!Review} are {!Contract.read_only}. {!Verify} is
      {!Contract.checks} — read-only discovery plus shell, under the configured
      policy — so a child can run checks. Callers should only allow {!Verify}
      when the parent mode permits it. *)

  val prelude_messages : t -> Spice_llm.Message.t list
  (** [prelude_messages t] are request-scoped child role instructions, combined
      with host instruction preludes at child request assembly time. *)
end

module Spawn : sig
  (** Decoded subagent spawn requests. *)

  type t
  (** The type for a checked spawn request.

      [task] is non-empty, [scope] has no empty entries, and [expected_output]
      is absent or non-empty. The host supplies parent and child session ids
      when creating a {!Subagent_run.t}. *)

  val make :
    role:Role.t ->
    task:string ->
    ?scope:string list ->
    ?expected_output:string ->
    unit ->
    (t, string) result
  (** [make ~role ~task ?scope ?expected_output ()] is a checked spawn request.
      Errors when [task] is empty, a [scope] entry is empty, or
      [expected_output] is present and empty. This is the single validation
      path; {!jsont} and {!decode} funnel through it. *)

  val role : t -> Role.t
  (** [role t] is the requested child role. *)

  val task : t -> string
  (** [task t] is the child task prompt. *)

  val scope : t -> string list
  (** [scope t] is the caller-provided scope list; empty means the request did
      not narrow the child context. *)

  val expected_output : t -> string option
  (** [expected_output t] describes the expected child result, if supplied. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same request. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps spawn requests to JSON objects, funneling through {!make}. *)
end

module Wait : sig
  (** The [wait_subagents] host tool: block for named runs' results.

      Spawning is detached; calling this tool after spawn is the explicit
      synchronous composition. It waits for the named run settlements without
      changing their execution or ownership. {!decode} validates calls as
      {!Request.t} values. *)

  module Request : sig
    type t
    (** The type for a checked wait request: a non-empty run list. *)

    val make : runs:Spice_session.Id.t list -> (t, string) result
    (** [make ~runs] is a checked wait request. Errors when [runs] is empty. *)

    val runs : t -> Spice_session.Id.t list
    (** [runs t] is the child session ids to wait for, in request order. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] name the same runs in the same
        order. *)

    val pp : Format.formatter -> t -> unit
    (** [pp] formats [t] for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps wait requests to JSON objects, funneling through {!make}.
    *)
  end

  val name : string
  (** [name] is the model-visible wait tool name. *)

  val tool : Spice_llm.Tool.t
  (** [tool] is the model-visible wait tool declaration. *)

  val decode : Spice_llm.Tool.Call.t -> (Request.t, string) result
  (** [decode call] decodes [call]'s input as a wait request. Errors with a
      diagnostic when [call] does not target {!name} or its payload fails
      validation. *)
end

module Cancel : sig
  (** The [cancel_subagent] host tool: interrupt one run.

      A cancelled run settles with the ledger's [Cancelled] status — a neutral
      outcome, not a failure. {!decode} validates calls as {!Request.t}
      values. *)

  module Request : sig
    type t
    (** The type for a cancel request. *)

    val make : run:Spice_session.Id.t -> t
    (** [make ~run] is a cancel request for [run]. *)

    val run : t -> Spice_session.Id.t
    (** [run t] is the child session id to cancel. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] name the same run. *)

    val pp : Format.formatter -> t -> unit
    (** [pp] formats [t] for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps cancel requests to JSON objects. *)
  end

  val name : string
  (** [name] is the model-visible cancel tool name. *)

  val tool : Spice_llm.Tool.t
  (** [tool] is the model-visible cancel tool declaration. *)

  val decode : Spice_llm.Tool.Call.t -> (Request.t, string) result
  (** [decode call] decodes [call]'s input as a cancel request. Errors with a
      diagnostic when [call] does not target {!name} or its payload fails
      validation. *)
end

module Message : sig
  (** The [message_subagent] host tool: steer or resume one run.

      Delivery is owned by the run registry and is instant: a running child sees
      the message immediately before its next model request; a child parked on a
      [message_parent] ask resumes with the message as that call's result; a
      settled child resumes with a new turn on the same child session and run
      identity — resume, not respawn. {!decode} validates calls as {!Request.t}
      values. *)

  module Request : sig
    type t
    (** The type for a checked message request: a target run and a non-empty
        message. *)

    val make : run:Spice_session.Id.t -> message:string -> (t, string) result
    (** [make ~run ~message] is a checked message request. Errors when [message]
        is empty. *)

    val run : t -> Spice_session.Id.t
    (** [run t] is the child session id to message. *)

    val message : t -> string
    (** [message t] is the message text. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same request. *)

    val pp : Format.formatter -> t -> unit
    (** [pp] formats [t] for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps message requests to JSON objects, funneling through
        {!make}. *)
  end

  val name : string
  (** [name] is the model-visible message tool name. *)

  val tool : Spice_llm.Tool.t
  (** [tool] is the model-visible message tool declaration. *)

  val decode : Spice_llm.Tool.Call.t -> (Request.t, string) result
  (** [decode call] decodes [call]'s input as a message request. Errors with a
      diagnostic when [call] does not target {!name} or its payload fails
      validation. *)
end

module Message_parent : sig
  (** The [message_parent] host tool: a child's question to its parent.

      Granted through every child contract and offered by no root mode. A valid
      call parks the child turn on its waiting boundary — the child's analogue
      of [ask_user], pointed at the parent — and the run registry surfaces the
      message as a notice with a wake; the reply, a parent [message_subagent] or
      a drill-in user message, resumes the turn as this call's result.
      {!decode} validates calls as {!Request.t} values. *)

  module Request : sig
    type t
    (** The type for a checked parent message: non-empty text. *)

    val make : message:string -> (t, string) result
    (** [make ~message] is a checked parent message. Errors when [message] is
        empty. *)

    val message : t -> string
    (** [message t] is the message text. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] carry the same text. *)

    val pp : Format.formatter -> t -> unit
    (** [pp] formats [t] for diagnostics. *)

    val jsont : t Jsont.t
    (** [jsont] maps parent messages to JSON objects, funneling through {!make}.
    *)
  end

  val name : string
  (** [name] is the model-visible parent-message tool name. *)

  val tool : Spice_llm.Tool.t
  (** [tool] is the model-visible parent-message tool declaration. *)

  val decode : Spice_llm.Tool.Call.t -> (Request.t, string) result
  (** [decode call] decodes [call]'s input as a parent message. Errors with a
      diagnostic when [call] does not target {!name} or its payload fails
      validation. *)
end

(** {1:host_tool Host tool} *)

val name : string
(** [name] is the model-visible subagent spawn tool name. *)

val tool : Spice_llm.Tool.t
(** [tool] is the model-visible subagent spawn tool declaration. Decoding
    validates shape and spawn invariants only; whether the current mode allows
    the role is a separate {!Mode.allows_role} check. *)

val decode : Spice_llm.Tool.Call.t -> (Spawn.t, string) result
(** [decode call] decodes [call]'s input as a spawn request. Errors with a
    diagnostic when [call] does not target {!name} or its payload fails shape or
    spawn validation. *)
