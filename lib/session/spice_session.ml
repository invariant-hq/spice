(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Id = Id
module Time = Time
module Revision = Revision
module Metadata = Metadata
module Turn = Turn
module Permission = Permission
module Tool_claim = Tool_claim
module Compaction = Compaction
module Waiting = Waiting
module Event = Event
module State = State
module Anchor = Anchor

module Error = struct
  type t =
    | State of State.Error.t
    | Archived
    | Deleted
    | Active_turn of Turn.Id.t
    | Unknown_turn of Turn.Id.t
    | Turn_not_finished of Turn.Id.t

  let message = function
    | State error -> State.Error.message error
    | Archived -> "session is archived"
    | Deleted -> "session has been deleted"
    | Active_turn turn ->
        Format.asprintf "turn is still active: %a" Turn.Id.pp turn
    | Unknown_turn turn ->
        Format.asprintf "turn is not in the session: %a" Turn.Id.pp turn
    | Turn_not_finished turn ->
        Format.asprintf "turn has not finished: %a" Turn.Id.pp turn

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Session_error = Error

type t = {
  id : Id.t;
  metadata : Metadata.t;
  events : Event.t list;
  state : State.t;
}

type session = t

let make ~id ~metadata ~events =
  match State.of_events events with
  | Error error -> Error (Error.State error)
  | Ok state -> Ok { id; metadata; events; state }

let create ~id ?title ~cwd ~created_at () =
  {
    id;
    metadata = Metadata.make ?title ~cwd ~created_at ~updated_at:created_at ();
    events = [];
    state = State.empty;
  }

let id t = t.id
let metadata t = t.metadata
let events t = t.events
let state t = t.state

let require_not_deleted t =
  if Metadata.is_deleted t.metadata then Error Error.Deleted else Ok ()

let require_active_status t =
  match Metadata.status t.metadata with
  | Metadata.Status.Active -> Ok ()
  | Metadata.Status.Archived -> Error Error.Archived
  | Metadata.Status.Deleted -> Error Error.Deleted

let require_no_active_turn t =
  match State.active_turn t.state with
  | None -> Ok ()
  | Some turn -> Error (Error.Active_turn turn)

let append event t =
  match require_active_status t with
  | Error _ as error -> error
  | Ok () -> (
      match State.apply event t.state with
      | Error error -> Error (Error.State error)
      | Ok state -> Ok { t with events = t.events @ [ event ]; state })

let append_all events t =
  let rec loop t = function
    | [] -> Ok t
    | event :: events -> (
        match append event t with
        | Error _ as error -> error
        | Ok t -> loop t events)
  in
  loop t events

let set_title title t =
  { t with metadata = Metadata.with_title title t.metadata }

let touch time t = { t with metadata = Metadata.touch time t.metadata }

let archive t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () ->
          Ok
            {
              t with
              metadata =
                Metadata.with_status Metadata.Status.Archived t.metadata;
            })

let restore t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () ->
      Ok
        {
          t with
          metadata = Metadata.with_status Metadata.Status.Active t.metadata;
        }

let delete t =
  if Metadata.is_deleted t.metadata then Ok t
  else
    match require_no_active_turn t with
    | Error _ as error -> error
    | Ok () ->
        Ok
          {
            t with
            metadata = Metadata.with_status Metadata.Status.Deleted t.metadata;
          }

let fork ~id ?title ~cwd ~created_at t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () ->
          let forked_from =
            Metadata.Forked_from.make ~parent:t.id
              ~copied_events:(List.length t.events)
          in
          let metadata =
            Metadata.make ?title ~forked_from ~cwd ~created_at
              ~updated_at:created_at ()
          in
          make ~id ~metadata ~events:t.events)

let turn_started_index events turn_id =
  let rec loop i = function
    | [] -> None
    | Event.Turn_started turn :: _ when Turn.Id.equal (Turn.id turn) turn_id ->
        Some i
    | _ :: events -> loop (i + 1) events
  in
  loop 0 events

let turn_finished_index events turn_id =
  let rec loop i = function
    | [] -> None
    | Event.Turn_finished { turn; _ } :: _ when Turn.Id.equal turn turn_id ->
        Some i
    | _ :: events -> loop (i + 1) events
  in
  loop 0 events

let resolve_anchor anchor t =
  let turn_id = Anchor.turn anchor in
  match Anchor.edge anchor with
  | Anchor.Before -> (
      match turn_started_index t.events turn_id with
      | Some index -> Ok index
      | None -> Error (Error.Unknown_turn turn_id))
  | Anchor.After -> (
      match State.turn turn_id t.state with
      | None -> Error (Error.Unknown_turn turn_id)
      | Some _ -> (
          match turn_finished_index t.events turn_id with
          | Some index -> Ok (index + 1)
          | None -> Error (Error.Turn_not_finished turn_id)))

let dropped_turns anchor t =
  match resolve_anchor anchor t with
  | Error _ as error -> error
  | Ok cut ->
      let rec loop i acc = function
        | [] -> List.rev acc
        | Event.Turn_started turn :: events ->
            let acc = if i >= cut then Turn.id turn :: acc else acc in
            loop (i + 1) acc events
        | _ :: events -> loop (i + 1) acc events
      in
      Ok (loop 0 [] t.events)

let rewind ~id ?title ~cwd ~created_at anchor t =
  match require_not_deleted t with
  | Error _ as error -> error
  | Ok () -> (
      match require_no_active_turn t with
      | Error _ as error -> error
      | Ok () -> (
          match resolve_anchor anchor t with
          | Error _ as error -> error
          | Ok copied_events ->
              let events = List.take copied_events t.events in
              let forked_from =
                Metadata.Forked_from.make ~parent:t.id ~copied_events
              in
              let metadata =
                Metadata.make ?title ~forked_from ~cwd ~created_at
                  ~updated_at:created_at ()
              in
              make ~id ~metadata ~events))

let jsont =
  let version = 1 in
  let make version' id metadata events =
    if not (Int.equal version version') then
      decode_error "unsupported session version";
    match make ~id ~metadata ~events with
    | Ok session -> session
    | Error error -> decode_error (Error.message error)
  in
  Jsont.Object.map ~kind:"session" make
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun _ -> version)
  |> Jsont.Object.mem "id" Id.jsont ~enc:id
  |> Jsont.Object.mem "metadata" Metadata.jsont ~enc:metadata
  |> Jsont.Object.mem "events" (Jsont.list Event.jsont) ~enc:events
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

module Metrics = struct
  (* CR: if you need to expose Metrics, just do Metrics = Metrics, otherwise remove this entirely. *)
  include Metrics

  let of_session session = of_events (events session)
end

module Log = struct
  let append = append
  let append_all = append_all
end

module Run = struct
  module Llm = Spice_llm
  module Tool = Spice_tool

  let ( let* ) result f =
    match result with Ok value -> f value | Error _ as e -> e

  module Error = struct
    type t =
      | Request of Llm.Request.Error.t
      | Tool of Tool.Error.t
      | No_active_turn
      | Unknown_active_turn of Turn.Id.t
      | Permission_not_pending of Permission.Id.t
      | Tool_claim_not_pending of Tool_claim.Id.t
      | Tool_call_not_pending of { call_id : string; name : string }
      | Tool_result_mismatch of {
          expected_call_id : string;
          expected_name : string;
          actual_call_id : string;
          actual_name : string;
        }
      | Archived
      | Deleted
      | State of State.Error.t

    let message = function
      | Request error -> Llm.Request.Error.message error
      | Tool error -> Tool.Error.message error
      | No_active_turn -> "session has no active turn"
      | Unknown_active_turn turn ->
          Printf.sprintf "active turn %s is not present in state"
            (Turn.Id.to_string turn)
      | Permission_not_pending id ->
          Format.asprintf "permission is not pending: %a" Permission.Id.pp id
      | Tool_claim_not_pending id ->
          Format.asprintf "tool claim is not pending: %a" Tool_claim.Id.pp id
      | Tool_call_not_pending { call_id; name } ->
          Printf.sprintf "tool call is not pending: %s (%s)" call_id name
      | Tool_result_mismatch
          { expected_call_id; expected_name; actual_call_id; actual_name } ->
          Printf.sprintf "host tool result mismatch: expected %s/%s, got %s/%s"
            expected_call_id expected_name actual_call_id actual_name
      | Archived -> "session is archived"
      | Deleted -> "session has been deleted"
      | State error -> State.Error.message error

    let pp ppf error = Format.pp_print_string ppf (message error)
  end

  let of_append_error = function
    | Session_error.State error -> Error.State error
    | Session_error.Archived -> Error.Archived
    | Session_error.Deleted -> Error.Deleted
    (* [append] guards only [require_active_status] and [State.apply], so it
       never yields these; only [archive]/[delete]/[fork]/[rewind] and anchor
       resolution do. *)
    | Session_error.Active_turn _ | Session_error.Unknown_turn _
    | Session_error.Turn_not_finished _ ->
        assert false

  let require_active_session session =
    match require_active_status session with
    | Ok () -> Ok ()
    | Error error -> Error (of_append_error error)

  module Config = struct
    type t = {
      tools : Tool.Catalog.t;
      host_tools : Llm.Tool.t list;
      policy : Spice_permission.Policy.t;
      prelude : Llm.Request.Prelude.t;
      max_steps : int;
      denial_message : Spice_permission.Policy.Denial.t -> string;
    }

    let default_denial_message _ = "Permission denied by policy."

    let executable_declaration tool =
      Llm.Tool.make ~name:(Tool.name tool) ~description:(Tool.description tool)
        ~input_schema:(Tool.input_schema tool) ()

    let validate_executable_declarations tools =
      try
        List.iter
          (fun tool -> ignore (executable_declaration tool))
          (Tool.Catalog.tools tools)
      with Invalid_argument message ->
        invalid_arg
          ("Spice_session.Run.Config.make: invalid executable tool \
            declaration: " ^ message)

    let invalid_config message =
      invalid_arg ("Spice_session.Run.Config.make: " ^ message)

    let validate_host_tool_names tools host_tools =
      let executable_names = List.map Tool.name (Tool.Catalog.tools tools) in
      let rec loop seen = function
        | [] -> ()
        | host_tool :: host_tools ->
            let name = Llm.Tool.name host_tool in
            if List.exists (String.equal name) executable_names then
              invalid_config
                ("host tool name also used by executable tool: " ^ name)
            else if List.exists (String.equal name) seen then
              invalid_config ("duplicate host tool name: " ^ name)
            else loop (name :: seen) host_tools
      in
      loop [] host_tools

    let make ~tools ?(host_tools = []) ~policy
        ?(prelude = Llm.Request.Prelude.empty) ?(max_steps = max_int)
        ?(denial_message = default_denial_message) () =
      if max_steps <= 0 then
        invalid_config
          (Printf.sprintf "max_steps must be positive, got %d" max_steps);
      match Tool.Catalog.make tools with
      | Error error -> invalid_config (Tool.Error.message error)
      | Ok tools ->
          validate_executable_declarations tools;
          validate_host_tool_names tools host_tools;
          { tools; host_tools; policy; prelude; max_steps; denial_message }

    let tools t = Tool.Catalog.tools t.tools
    let tool_catalog t = t.tools
    let host_tools t = t.host_tools
    let policy t = t.policy
    let prelude t = t.prelude
    let max_steps t = t.max_steps
    let denial_message t = t.denial_message

    let declarations t =
      List.map executable_declaration (Tool.Catalog.tools t.tools)
      @ t.host_tools
  end

  module Step = struct
    type next =
      | Request_model of Llm.Request.t
      | Run_tool of { claim : Tool_claim.Started.t; call : Tool.Call.t }
      | Waiting of Waiting.t
      | Finished of { turn : Turn.Id.t; outcome : Turn.Outcome.t }

    type nonrec t = { events : Event.t list; session : t; next : next }

    let pp_next ppf = function
      | Request_model _ -> Format.pp_print_string ppf "request-model"
      | Run_tool { claim; call = _ } ->
          Format.fprintf ppf "run-tool(%a)" Tool_claim.Started.pp claim
      | Waiting waiting -> Format.fprintf ppf "waiting %a" Waiting.pp waiting
      | Finished { turn; outcome } ->
          Format.fprintf ppf "finished %a %a" Turn.Id.pp turn Turn.Outcome.pp
            outcome

    let make ~session ~events ~next =
      match append_all events session with
      | Error error -> Error (of_append_error error)
      | Ok session -> Ok { events; session; next }

    let of_applied ~events ~session ~next = { events; session; next }
    let events (t : t) = t.events
    let session t = t.session
    let next t = t.next
  end

  let active_turn session =
    let* () = require_active_session session in
    let state = state session in
    match State.active_turn state with
    | None -> Error Error.No_active_turn
    | Some id -> (
        match State.turn id state with
        | None -> Error (Error.Unknown_active_turn id)
        | Some turn -> Ok (id, turn))

  let active_turn_id session =
    let* id, _ = active_turn session in
    Ok id

  let request_for_turn config session turn =
    let state = state session in
    (* The session id is the stable prompt-cache routing key: one conversation,
       one cache shard, across every request of every turn. *)
    Llm.Request.make ~model:(Turn.model turn) ~prelude:(Config.prelude config)
      ~tools:(Config.declarations config)
      ~options:(Turn.options turn)
      ~cache_key:(Id.to_string (id session))
      (State.transcript state)
    |> Result.map_error (fun error -> Error.Request error)

  let finish session turn outcome =
    let event = Event.turn_finished ~turn outcome in
    Step.make ~session ~events:[ event ] ~next:(Step.Finished { turn; outcome })

  let max_steps config turn =
    match Turn.max_steps turn with
    | Some n -> n
    | None -> Config.max_steps config

  let model_action config session turn_id turn =
    let state = state session in
    let response_count =
      match State.turn_response_count turn_id state with
      | Some count -> count
      | None -> 0
    in
    if response_count >= max_steps config turn then
      finish session turn_id Turn.Outcome.step_limit
    else
      let* request = request_for_turn config session turn in
      Step.make ~session ~events:[] ~next:(Step.Request_model request)

  let tool_result_from_output call result =
    match (Tool.Result.status result, Tool.Result.output result) with
    | Tool.Result.Completed, Some output ->
        Llm.Tool.Result.text call (Tool.Output.text output)
    | Tool.Result.Completed, None -> Llm.Tool.Result.empty call
    | Tool.Result.Failed { message; _ }, Some output ->
        Llm.Tool.Result.text ~error:true call
          (message ^ "\n\n" ^ Tool.Output.text output)
    | Tool.Result.Failed { message; _ }, None ->
        Llm.Tool.Result.text ~error:true call message
    | Tool.Result.Interrupted { reason; _ }, Some output ->
        Llm.Tool.Result.text ~error:true call
          (reason ^ "\n\n" ^ Tool.Output.text output)
    | Tool.Result.Interrupted { reason; _ }, None ->
        Llm.Tool.Result.text ~error:true call reason

  let tool_result_text ?(error = false) call text =
    if String.is_empty text then Llm.Tool.Result.empty ~error call
    else Llm.Tool.Result.text ~error call text

  let interrupt ?reason session =
    let* turn = active_turn_id session in
    let outcome = Turn.Outcome.interrupted ?reason ~cancelled:true () in
    let st = state session in
    let reason_text = Option.value reason ~default:"interrupted" in
    let interrupted =
      Tool.Result.interrupted ~reason:reason_text ~cancelled:true ()
    in
    let pending_claims = State.pending_tool_claims st in
    let claim_for call =
      List.find_opt
        (fun execution ->
          String.equal
            (Llm.Tool.Call.id (Tool_claim.Started.call execution))
            (Llm.Tool.Call.id call))
        pending_claims
    in
    (* An interrupted turn may leave assistant tool calls unanswered — a settled
       host-tool question, or calls the drain had not reached. Each must carry a
       result or the next request is rejected for missing tool results. A
       planned-but-unrun executable claim is finished with the interrupted
       result (recording the claim outcome and its transcript message); a
       host-tool or not-yet-claimed call gets a direct interrupted tool result. *)
    let result_event call =
      match claim_for call with
      | Some execution ->
          Event.tool_claim_finished
            (Tool_claim.Finished.make
               ~id:(Tool_claim.Started.id execution)
               ~output:(Tool.Result.output interrupted)
               (tool_result_from_output call interrupted))
      | None ->
          Event.message_appended
            (Llm.Message.tool_result
               (tool_result_text ~error:true call reason_text))
    in
    let result_events =
      List.map result_event (Llm.Transcript.pending (State.transcript st))
    in
    Step.make ~session
      ~events:(result_events @ [ Event.turn_finished ~turn outcome ])
      ~next:(Step.Finished { turn; outcome })

  let decode_tool tools call =
    Tool.Catalog.decode tools ~name:(Llm.Tool.Call.name call)
      ~input:(Llm.Tool.Call.input call) ()
    |> Result.map_error (fun error -> Error.Tool error)

  let is_host_tool_name host_tools call =
    List.exists (String.equal (Llm.Tool.Call.name call)) host_tools

  let permission_already_allows state call request review =
    let same_call requested =
      Llm.Tool.Call.equal (Permission.Requested.tool_call requested) call
    in
    let same_request requested =
      Spice_permission.Request.equal
        (Permission.Requested.request requested)
        request
    in
    let same_reviewed_accesses requested =
      Spice_permission.Access.Set.equal
        (Permission.Requested.asked requested)
        (Spice_permission.Policy.Review.access_set review)
    in
    let allows_reply resolved =
      match Permission.Resolved.decision resolved with
      | Permission.Resolved.Allow _ -> true
      | Permission.Resolved.Deny _ -> false
    in
    List.exists
      (fun (requested, resolved) ->
        same_call requested && same_request requested
        && same_reviewed_accesses requested
        &&
        match resolved with
        | Some reply -> allows_reply reply
        | None -> false)
      (State.permissions state)

  let digest_id prefix ~domain fields =
    Permission.Id.of_string
      (prefix ^ ":" ^ Spice_digest.key ~length:16 ~domain fields)

  let access_texts review =
    Spice_permission.Policy.Review.access_set review
    |> Spice_permission.Access.Set.elements
    |> List.map Spice_permission.Access.stable_text

  let permission_request_text review =
    match
      Jsont.Json.encode Spice_permission.Request.jsont
        (Spice_permission.Policy.Review.request review)
    with
    | Ok json -> Format.asprintf "%a" Jsont.Json.pp json
    | Error message ->
        invalid_arg
          ("Spice_session.Run.permission_id: permission request encode failed: "
         ^ message)

  let permission_id turn_id call request_index review =
    digest_id "perm" ~domain:"spice.session.permission.v3"
      (Turn.Id.to_string turn_id :: Llm.Tool.Call.id call
      :: string_of_int request_index
      :: permission_request_text review :: access_texts review)

  let tool_claim_id turn_id call =
    Tool_claim.Id.of_string
      ("tool_exec:"
      ^ Spice_digest.key ~length:16 ~domain:"spice.session.tool_claim.v1"
          [ Turn.Id.to_string turn_id; Llm.Tool.Call.id call ])

  let request_permission session turn_id call request_index review =
    let requested =
      Permission.Requested.of_review
        ~id:(permission_id turn_id call request_index review)
        ~turn:turn_id ~tool_call:call review
    in
    Step.make ~session
      ~events:[ Event.permission_requested requested ]
      ~next:(Step.Waiting (Waiting.Permission requested))

  let first_waiting state =
    match State.waiting state with waiting :: _ -> Some waiting | [] -> None

  let waiting_transition session waiting =
    Step.make ~session ~events:[] ~next:(Step.Waiting waiting)

  module Phase = struct
    type t = Idle | Waiting of Waiting.t | Active

    let to_string = function
      | Idle -> "idle"
      | Waiting _ -> "waiting"
      | Active -> "active"

    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end

  let waiting_of_active state turn =
    match first_waiting state with
    | Some (Waiting.Permission _ as waiting) -> Some waiting
    | Some (Waiting.Tool_claim _ as waiting) -> Some waiting
    | Some (Waiting.Host_tool _ as waiting) -> Some waiting
    | None -> (
        match Llm.Transcript.state (State.transcript state) with
        | Llm.Transcript.Ready -> None
        | Llm.Transcript.Awaiting_tool_results (call, _) ->
            if is_host_tool_name (Turn.host_tools turn) call then
              Some (Waiting.host_tool ~turn:(Turn.id turn) call)
            else None)

  let phase session =
    let state = state session in
    match State.active_turn state with
    | None -> Phase.Idle
    | Some turn_id -> (
        match State.turn turn_id state with
        | None -> Phase.Active
        | Some turn -> (
            match waiting_of_active state turn with
            | Some waiting -> Phase.Waiting waiting
            | None -> Phase.Active))

  let rec normalize config session events =
    match append_all events session with
    | Error error -> Error (of_append_error error)
    | Ok session ->
        let* step = plan config session in
        Ok
          (Step.of_applied
             ~events:(events @ Step.events step)
             ~session:(Step.session step) ~next:(Step.next step))

  and append_tool_result config session result =
    normalize config session
      [ Event.message_appended (Llm.Message.tool_result result) ]

  and append_tool_error config session call message =
    append_tool_result config session
      (Llm.Tool.Result.text ~error:true call message)

  and review_tool_permissions config session turn_id call tool_call =
    let state = state session in
    let rec loop request_index = function
      | [] -> Ok `Allowed
      | request :: requests -> (
          match
            Spice_permission.Policy.decide ~grants:(State.grants state)
              (Config.policy config) request
          with
          | Spice_permission.Policy.Decision.Allowed ->
              loop (request_index + 1) requests
          | Spice_permission.Policy.Decision.Denied (first, rest) ->
              Ok (`Denied (first, rest))
          | Spice_permission.Policy.Decision.Review review ->
              if permission_already_allows state call request review then
                loop (request_index + 1) requests
              else Ok (`Review (request_index, review)))
    in
    let* planning =
      match Tool.Call.permissions tool_call with
      | requests -> Ok (`Requests requests)
      | exception exn ->
          let* step =
            append_tool_error config session call
              ("tool permission planner raised: " ^ Printexc.to_string exn)
          in
          Ok (`Step step)
    in
    match planning with
    | `Step step -> Ok (`Step step)
    | `Requests requests -> (
        let* decision = loop 0 requests in
        match decision with
        | `Allowed -> Ok `Allowed
        | `Denied denials ->
            let denial = fst denials in
            let* step =
              append_tool_error config session call
                (Config.denial_message config denial)
            in
            Ok (`Step step)
        | `Review (request_index, review) ->
            let* step =
              request_permission session turn_id call request_index review
            in
            Ok (`Step step))

  and run_tool_action session turn_id call tool_call =
    let execution =
      Tool_claim.Started.make
        ~id:(tool_claim_id turn_id call)
        ~turn:turn_id ~call
    in
    Step.make ~session
      ~events:[ Event.tool_claim_started execution ]
      ~next:(Step.Run_tool { claim = execution; call = tool_call })

  and tool_action config session turn_id turn call =
    if is_host_tool_name (Turn.host_tools turn) call then
      Step.make ~session ~events:[]
        ~next:(Step.Waiting (Waiting.host_tool ~turn:turn_id call))
    else
      match decode_tool (Config.tool_catalog config) call with
      | Error (Error.Tool tool_error) ->
          append_tool_error config session call (Tool.Error.message tool_error)
      | Error error -> Error error
      | Ok tool_call -> (
          let* permission =
            review_tool_permissions config session turn_id call tool_call
          in
          match permission with
          | `Step step -> Ok step
          | `Allowed -> run_tool_action session turn_id call tool_call)

  and plan config session =
    let* turn_id, turn = active_turn session in
    let state = state session in
    match first_waiting state with
    | Some (Waiting.Permission request) ->
        waiting_transition session (Waiting.Permission request)
    | Some (Waiting.Tool_claim execution) ->
        waiting_transition session (Waiting.Tool_claim execution)
    | Some (Waiting.Host_tool _ as waiting) ->
        waiting_transition session waiting
    | None -> (
        match Llm.Transcript.state (State.transcript state) with
        | Llm.Transcript.Ready -> model_action config session turn_id turn
        | Llm.Transcript.Awaiting_tool_results (call, _) ->
            tool_action config session turn_id turn call)

  let resume config session = plan config session

  let start config ~id ~input ~model ?options ?mode ?origin ?max_steps session =
    let* () = require_active_session session in
    let host_tools = List.map Llm.Tool.name (Config.host_tools config) in
    let turn =
      Turn.make ~id ~input ~model ?options ?mode ?origin ?max_steps ~host_tools
        ()
    in
    normalize config session [ Event.turn_started turn ]

  let accept_response config response session =
    let* turn_id = active_turn_id session in
    let response_event = Event.response_appended response in
    if Llm.Response.has_tool_calls response then
      normalize config session [ response_event ]
    else
      let outcome = Turn.Outcome.completed in
      let finish_event = Event.turn_finished ~turn:turn_id outcome in
      Step.make ~session
        ~events:[ response_event; finish_event ]
        ~next:(Step.Finished { turn = turn_id; outcome })

  let finish_tool config id result session =
    let* () = require_active_session session in
    match State.pending_tool_claim id (state session) with
    | None -> Error (Error.Tool_claim_not_pending id)
    | Some saved ->
        let call = Tool_claim.Started.call saved in
        let finished =
          Tool_claim.Finished.make ~id ~output:(Tool.Result.output result)
            (tool_result_from_output call result)
        in
        normalize config session [ Event.tool_claim_finished finished ]

  let resolve_permission config ?(message = "Permission denied.") ?via id answer
      session =
    let* () = require_active_session session in
    (* The product invariant is that unattended resolution can only deny; a
       host bug pairing unattended provenance with an allow must fail loudly
       rather than be laundered into a reviewer allow. The JSON decoder rejects
       the same state. *)
    (match (via, answer) with
    | Some `Unattended, Spice_permission.Policy.Review.Allow _ ->
        invalid_arg
          "Spice_session.Run.resolve_permission: unattended provenance applies \
           only to denials"
    | (Some (`Unattended | `Reviewer) | None), _ -> ());
    match State.pending_permission id (state session) with
    | None -> Error (Error.Permission_not_pending id)
    | Some requested ->
        let resolved =
          match answer with
          | Spice_permission.Policy.Review.Allow
              Spice_permission.Policy.Review.Once ->
              Permission.Resolved.allow_once ~id
          | Spice_permission.Policy.Review.Allow
              Spice_permission.Policy.Review.Session ->
              Permission.Resolved.allow_session ~id
          | Spice_permission.Policy.Review.Deny ->
              let call = Permission.Requested.tool_call requested in
              Permission.Resolved.deny ~id ?via
                (tool_result_text ~error:true call message)
        in
        normalize config session [ Event.permission_resolved resolved ]

  let pending_tool_call ~call_id ~name session =
    State.transcript (state session)
    |> Llm.Transcript.pending
    |> List.find_opt (fun call ->
        String.equal (Llm.Tool.Call.id call) call_id
        && String.equal (Llm.Tool.Call.name call) name)

  let host_tool_matches_result waiting result =
    let call = waiting.Waiting.call in
    String.equal (Llm.Tool.Result.call_id result) (Llm.Tool.Call.id call)
    && String.equal (Llm.Tool.Result.name result) (Llm.Tool.Call.name call)

  let answer_host_tool_result config waiting result session =
    let* () = require_active_session session in
    if not (host_tool_matches_result waiting result) then
      let call = waiting.Waiting.call in
      Error
        (Error.Tool_result_mismatch
           {
             expected_call_id = Llm.Tool.Call.id call;
             expected_name = Llm.Tool.Call.name call;
             actual_call_id = Llm.Tool.Result.call_id result;
             actual_name = Llm.Tool.Result.name result;
           })
    else
      let call_id = Llm.Tool.Result.call_id result in
      let name = Llm.Tool.Result.name result in
      match phase session with
      | Phase.Waiting (Waiting.Host_tool current)
        when Waiting.equal (Waiting.Host_tool waiting)
               (Waiting.Host_tool current) -> (
          match pending_tool_call ~call_id ~name session with
          | None -> Error (Error.Tool_call_not_pending { call_id; name })
          | Some _ ->
              normalize config session
                [ Event.message_appended (Llm.Message.tool_result result) ])
      | Phase.Idle | Phase.Active | Phase.Waiting _ ->
          Error (Error.Tool_call_not_pending { call_id; name })

  let answer_host_tool config ?(error = false) waiting ~text session =
    let call = waiting.Waiting.call in
    answer_host_tool_result config waiting
      (tool_result_text ~error call text)
      session
end
