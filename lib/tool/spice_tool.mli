(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Runtime-independent executable host tools.

    [Spice_tool] defines executable host capabilities without committing to a
    registry service, scheduler, provider protocol, workspace, sandbox,
    persistence layer, or model transcript format.

    A tool definition combines:

    - a stable external name and model-visible description;
    - an {!Input.t} that decodes provider JSON to a typed handler input;
    - an {!Output.type-encoder} that erases typed handler output to
      model-projectable {!Output.t};
    - optional permission planning computed from the decoded input;
    - a handler returning one terminal {!Result.t}.

    Dispatch is a two-step workflow. First, {!Call.decode} selects a named tool
    and decodes its input. Then callers may inspect {!Call.permissions} before
    executing the same decoded call with {!Call.run}. This guarantees that
    permission planning and execution see the exact same typed input.

    {[
    let tool =
      Spice_tool.make ~name:"echo" ~description:"Echo text." ~input
        ~output:(fun text -> Spice_tool.Output.make ~text ())
        ~run:(fun _ctx text -> Spice_tool.Result.completed ~output:text ())
        ()

    let run_provider_call json =
      match Spice_tool.Call.decode [ tool ] ~name:"echo" ~input:json () with
      | Error error -> Error error
      | Ok call ->
          let requests = Spice_tool.Call.permissions call in
          (* Host checks [requests] with Spice_permission.Policy. *)
          Ok (Spice_tool.Call.run call ())
    ]}

    Model-visible tool declaration formatting belongs to [spice.llm]. Permission
    policy decisions belong to [spice.permission]. Built-in catalogs, process
    execution, filesystem observation, sandboxing, audit records, and edit
    application belong to host layers. Tool names are not normalized by this
    module; any provider-specific name policy belongs at the adapter boundary.
*)

(** {1:contracts Contracts and results} *)

module Input = Input
(** Typed JSON input contracts. *)

module Output = Output
(** Typed output encoders and erased model-projectable outputs. *)

module Result = Result
(** Terminal invocation results. *)

module Error = Error
(** Dispatch errors. *)

(** {1:updates Live updates} *)

module Update : sig
  (** Non-terminal tool updates.

      Updates are live observations. The terminal {!Result.t} is the source of
      truth for replay, audit, and model projection. Hosts may choose to stream,
      buffer, ignore, or transform updates independently of the terminal result.

      [Spice_tool] does not validate update payloads, persist them, or merge
      them into the terminal {!Output.t}. *)
  type t =
    | Progress of { title : string option; metadata : Jsont.json option }
        (** [Progress { title; metadata }] reports a progress point.

            [title], when present, is short human-readable progress text.
            [metadata], when present, is already-encoded host data associated
            with the progress event. *)
    | Text_delta of string
        (** [Text_delta text] reports incremental text emitted by the running
            tool. [text] may be empty. The terminal {!Output.text} remains
            authoritative. *)
end

(** {1:context Running call context} *)

module Context : sig
  type t
  (** The type for one running tool-call context.

      A context contains only caller-supplied callbacks. It carries no
      scheduler, workspace, session store, policy, sandbox, or model state. *)

  val cancelled : t -> bool
  (** [cancelled t] is [true] iff the caller requested cooperative cancellation.

      Tool handlers should poll this value at useful boundaries and return
      {!Result.interrupted} when they stop cooperatively. [Spice_tool] does not
      enforce cancellation or interrupt running handlers. *)

  val emit : t -> Update.t -> unit
  (** [emit t update] emits a non-terminal update for the running call.

      Exceptions raised by the caller-provided update callback propagate to the
      handler. *)
end

(** {1:tools Tool definitions} *)

type t
(** The type for executable host capabilities.

    Values are pure definitions. Creating a tool does not start work, request
    permissions, access files, or allocate runtime resources. *)

val make :
  name:string ->
  description:string ->
  input:'input Input.t ->
  output:'output Output.encoder ->
  ?permissions:('input -> Spice_permission.Request.t list) ->
  run:(Context.t -> 'input -> 'output Result.t) ->
  unit ->
  t
(** [make ~name ~description ~input ~output ~run ()] is an executable tool.

    [name] is the stable external name used by providers to call the tool.
    [description] is the model-visible contract for the tool. [input] describes
    and decodes provider JSON. [output] erases the typed handler output returned
    in {!Result.t}.

    [permissions], when present, computes required permission requests from the
    same decoded input later passed to [run]. It defaults to no requests.
    Permission requests are declarations for the host; {!Call.run} does not
    evaluate policy or enforce them.

    [run] returns exactly one terminal result. Expected tool-domain failures
    should be returned with {!Result.failed}. Exceptions raised by [permissions]
    or [run] propagate to the caller.

    Raises [Invalid_argument] if [name] or [description] is empty. *)

val name : t -> string
(** [name t] is [t]'s stable external name. *)

val description : t -> string
(** [description t] is [t]'s external model-visible contract. *)

val input_schema : t -> Jsont.json
(** [input_schema t] is [t]'s model-visible input schema.

    The value is the JSON Schema object retained by the tool's {!Input.t}. *)

(** {1:calls Decoded calls} *)

module Call : sig
  type tool := t

  type t
  (** The type for a decoded tool call bound to one hidden input.

      A call is the execution funnel for tools: lookup, input decoding,
      permission planning, and execution all use the same decoded input. This
      guarantees permissions are planned from the exact value the handler
      receives.

      The decoded input and selected tool implementation are intentionally
      hidden. Hosts can inspect the tool name, permission requests, and terminal
      result, but cannot mutate the decoded input between permission planning
      and execution. *)

  val decode :
    tool list -> name:string -> input:Jsont.json -> unit -> (t, Error.t) result
  (** [decode tools ~name ~input ()] decodes [input] and binds it to the named
      tool in [tools].

      [decode] is safe on a plain tool list. It first checks that [tools] has no
      duplicate names, so dispatch never silently picks one of multiple matching
      tools. Dispatch from a {!Catalog.t} that already passed this check should
      use {!Catalog.decode} instead.

      Returns {!Error.Duplicate_name} if [tools] contains duplicate names,
      {!Error.Unknown_tool} if [name] is not present, or {!Error.Invalid_input}
      if the selected tool rejects [input]. *)

  val tool : t -> string
  (** [tool t] is the invoked tool name. *)

  val permissions : t -> Spice_permission.Request.t list
  (** [permissions t] is the permission request list for [t].

      Requests are computed from the decoded input stored in [t]. The value is
      not cached; each call invokes the tool permission function. Exceptions
      raised by that function propagate to the caller. *)

  val run :
    t ->
    ?cancelled:(unit -> bool) ->
    ?emit:(Update.t -> unit) ->
    unit ->
    Output.t Result.t
  (** [run t ()] executes [t] and returns one terminal result.

      [cancelled] defaults to a function returning [false]. [emit] defaults to a
      function that ignores updates. The handler receives the decoded input
      stored in [t].

      Typed output carried by the handler's result is erased with the tool's
      {!Output.type-encoder}. If the encoder raises, the exception propagates to
      the caller. Handler exceptions also propagate to the caller. [run] does
      not call {!permissions} or enforce cancellation. *)
end

(** {1:catalogs Catalogs} *)

module Catalog : sig
  type tool := t

  type t
  (** The type for a validated executable tool catalog.

      Catalogs preserve declaration order for enumeration and provider
      projection. *)

  val make : tool list -> (t, Error.t) result
  (** [make tools] is a catalog containing [tools].

      Returns [Error (Error.Duplicate_name name)] if [tools] contains duplicate
      names. *)

  val tools : t -> tool list
  (** [tools t] is [t]'s tools in declaration order. *)

  val decode :
    t -> name:string -> input:Jsont.json -> unit -> (Call.t, Error.t) result
  (** [decode t ~name ~input ()] decodes [input] and binds it to [name] in [t].

      Catalog values constructed by {!make} have already passed the duplicate
      name check, so [decode] skips it and dispatches directly. Returns
      {!Error.Unknown_tool} if [name] is not present, or {!Error.Invalid_input}
      if the selected tool rejects [input]. *)
end
