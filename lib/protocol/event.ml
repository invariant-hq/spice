(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Session = Spice_session

type basis = Usage | Estimate

type compaction_progress =
  | Started of {
      reason : Session.Compaction.Reason.t;
      projected_input : int;
      basis : basis;
      auto_limit : int option;
    }
  | Summarizing of Spice_llm.Request.t
  | Retrying of { dropped_messages : int }
  | Skipped of { reason : Session.Compaction.Reason.t; message : string }
  | Failed of { reason : Session.Compaction.Reason.t; message : string }

type t =
  (* Durable — also produced by {!of_session}. *)
  | Turn_started of Session.Turn.t
  | Assistant of Spice_llm.Response.t
  | Tool_started of Session.Tool_claim.Started.t
  | Tool_finished of {
      claim : Session.Tool_claim.Started.t;
      result : Spice_tool.Output.t Spice_tool.Result.t;
    }
  | Host_call of {
      call : Spice_llm.Tool.Call.t;
      kind : Call.t option;
      result : Spice_llm.Tool.Result.t option;
    }
  | Permission_requested of Session.Permission.Requested.t
  | Permission_resolved of Session.Permission.Resolved.t
  | Compaction of Session.Compaction.t
  | Turn_finished of {
      turn : Session.Turn.Id.t;
      outcome : Session.Turn.Outcome.t;
      final_text : string option;
    }
  (* Live-only — never produced by {!of_session}. *)
  | Assistant_delta of { text : string }
  | Reasoning_delta of { text : string }
  | Usage_updated of Spice_llm.Usage.t
  | Model_started of Spice_llm.Request.t
  | Model_artifact of Model_artifact.progress
  | Tool_updated of {
      claim : Session.Tool_claim.Started.t;
      update : Spice_tool.Update.t;
    }
  | Workspace_changed of {
      claim : Session.Tool_claim.Started.t;
      checkpoint : Spice_mutation.Checkpoint.t option;
      changes : Spice_mutation.Change.t list;
      total : Spice_mutation.Change.totals;
    }
  | Workspace_degraded of { message : string }
  | Compaction_progress of compaction_progress
  | Notices_injected of Notice.t list

let is_durable = function
  | Turn_started _ | Assistant _ | Tool_started _ | Tool_finished _
  | Host_call _ | Permission_requested _ | Permission_resolved _ | Compaction _
  | Turn_finished _ ->
      true
  | Assistant_delta _ | Reasoning_delta _ | Usage_updated _ | Model_started _
  | Model_artifact _ | Tool_updated _ | Workspace_changed _
  | Workspace_degraded _ | Compaction_progress _ | Notices_injected _ ->
      false

(* Replay reconstruction. A durable finished claim stores the model-visible
   result plus the erased typed output, if the tool retained any. Live
   [Tool_finished] carries the real typed result; the replay projection
   reconstructs the closest faithful value: it keeps the retained output and
   derives the status from the model-visible error flag. The interrupted /
   failed distinction and the exact failure kind are not durably recorded, so
   a replayed non-completed result is reported as a generic failure. *)
let reconstruct_result finished =
  let model_result = Session.Tool_claim.Finished.result finished in
  let output =
    match Session.Tool_claim.Finished.output finished with
    | Some output -> output
    | None ->
        let text =
          match Spice_llm.Tool.Result.texts model_result with
          | [] -> " "
          | texts -> String.concat "\n" texts
        in
        Spice_tool.Output.make
          ~text:(if String.is_empty text then " " else text)
          ()
  in
  if Spice_llm.Tool.Result.is_error model_result then
    let message =
      match Spice_llm.Tool.Result.texts model_result with
      | [] -> "tool failed"
      | texts -> (
          match String.concat "\n" texts with "" -> "tool failed" | m -> m)
    in
    Spice_tool.Result.failed ~output `Failed message
  else Spice_tool.Result.completed ~output ()

module String_set = Set.Make (String)
module String_map = Map.Make (String)

(* The replay fold. Durable events are emitted in transcript order. Host calls
   are correlated across the transcript: a call appears in an assistant
   response and is answered by a later tool-result message. Each answered call
   yields one [Host_call] with [result = Some _] at the answer; a single
   still-pending call (the current unanswered host-tool boundary) yields one
   [Host_call] with [result = None]. *)
let of_session session =
  let events = Session.events session in
  let host_tool_names = ref String_set.empty in
  let started = ref String_map.empty in
  (* call_id -> the original host-tool call, awaiting its answer. *)
  let pending_calls = ref String_map.empty in
  let last_text = ref None in
  let rev = ref [] in
  let emit event = rev := event :: !rev in
  let is_host_call call =
    String_set.mem (Spice_llm.Tool.Call.name call) !host_tool_names
  in
  List.iter
    (fun event ->
      match (event : Session.Event.t) with
      | Session.Event.Turn_started turn ->
          host_tool_names :=
            List.fold_left
              (fun set name -> String_set.add name set)
              !host_tool_names
              (Session.Turn.host_tools turn);
          emit (Turn_started turn)
      | Session.Event.Response_appended response ->
          (* Match {!Spice_session.State.final_text}: trim and skip a
             whitespace-only response so the live and replayed [Turn_finished]
             carry the identical final text. *)
          let text = String.trim (Spice_llm.Response.text ~sep:"\n" response) in
          if not (String.is_empty text) then last_text := Some text;
          emit (Assistant response);
          List.iter
            (fun call ->
              if is_host_call call then
                pending_calls :=
                  String_map.add
                    (Spice_llm.Tool.Call.id call)
                    call !pending_calls)
            (Spice_llm.Response.tool_calls response)
      | Session.Event.Tool_claim_started claim ->
          started :=
            String_map.add
              (Session.Tool_claim.Id.to_string
                 (Session.Tool_claim.Started.id claim))
              claim !started;
          emit (Tool_started claim)
      | Session.Event.Tool_claim_finished finished -> (
          let id =
            Session.Tool_claim.Id.to_string
              (Session.Tool_claim.Finished.id finished)
          in
          let result = reconstruct_result finished in
          match String_map.find_opt id !started with
          | Some claim -> emit (Tool_finished { claim; result })
          | None -> ())
      | Session.Event.Message_appended (Spice_llm.Message.Tool_result result)
        -> (
          let call_id = Spice_llm.Tool.Result.call_id result in
          match String_map.find_opt call_id !pending_calls with
          | Some call ->
              pending_calls := String_map.remove call_id !pending_calls;
              emit
                (Host_call
                   { call; kind = Call.classify call; result = Some result })
          | None -> ())
      | Session.Event.Message_appended _ -> ()
      | Session.Event.Permission_requested request ->
          emit (Permission_requested request)
      | Session.Event.Permission_resolved resolution ->
          emit (Permission_resolved resolution)
      | Session.Event.Compaction_installed compaction ->
          emit (Compaction compaction)
      | Session.Event.Turn_finished { turn; outcome } ->
          emit (Turn_finished { turn; outcome; final_text = !last_text }))
    events;
  (* The single still-pending host-tool call is the current unanswered
     boundary; emit it once with [result = None]. *)
  String_map.iter
    (fun _ call ->
      emit (Host_call { call; kind = Call.classify call; result = None }))
    !pending_calls;
  List.rev !rev
