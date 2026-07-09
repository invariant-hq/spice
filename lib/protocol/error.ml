(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Conflict of {
      id : Spice_session.Id.t;
      expected : Spice_session.Revision.t;
      actual : Spice_session.Revision.t;
    }
  | Not_found of Spice_session.Id.t
  | Storage of { path : string; message : string }
  | Provider of Spice_llm.Error.t
  | Invalid_answer of string
  | Archived of Spice_session.Id.t
  | Deleted of Spice_session.Id.t
  | Active_turn_exists of Spice_session.Turn.Id.t
  | No_active_turn
  | Permission_not_pending of Spice_session.Permission.Id.t
  | Tool_claim_not_pending of Spice_session.Tool_claim.Id.t
  | Tool_call_not_pending of { call_id : string; name : string }
  | Transcript_not_ready of Spice_llm.Transcript.Error.t
  | Nothing_to_summarize
  | No_compaction_model
  | Empty_compaction_summary
  | Internal of string

let message = function
  | Conflict { id; expected; actual } ->
      Format.asprintf
        "session conflict for %a: expected revision %s but found %s"
        Spice_session.Id.pp id
        (Spice_session.Revision.to_string expected)
        (Spice_session.Revision.to_string actual)
  | Not_found id ->
      Format.asprintf "session not found: %a" Spice_session.Id.pp id
  | Storage { path; message } -> path ^ ": " ^ message
  | Provider error -> Spice_llm.Error.message error
  | Invalid_answer message -> message
  | Archived id ->
      Format.asprintf "session is archived: %a" Spice_session.Id.pp id
  | Deleted id ->
      Format.asprintf "session is deleted: %a" Spice_session.Id.pp id
  | Active_turn_exists turn ->
      Format.asprintf "session already has active turn: %a"
        Spice_session.Turn.Id.pp turn
  | No_active_turn -> "session has no active turn"
  | Permission_not_pending id ->
      Format.asprintf "permission is not pending: %a"
        Spice_session.Permission.Id.pp id
  | Tool_claim_not_pending id ->
      Format.asprintf "tool claim is not pending: %a"
        Spice_session.Tool_claim.Id.pp id
  | Tool_call_not_pending { call_id; name } ->
      Printf.sprintf "tool call is not pending: %s (%s)" call_id name
  | Transcript_not_ready error ->
      Format.asprintf "transcript is not request-ready: %a"
        Spice_llm.Transcript.Error.pp error
  | Nothing_to_summarize ->
      "conversation already fits within the retained tail; nothing to compact"
  | No_compaction_model ->
      "compaction needs an explicit model or a previous session turn"
  | Empty_compaction_summary -> "compaction summary must not be empty"
  | Internal message -> message

let hints = function
  | Conflict _ -> [ "reload the session and retry the operation" ]
  | Provider error -> (
      match Spice_llm.Error.kind error with
      | Spice_llm.Error.Auth -> [ "check the provider login or credential" ]
      | Spice_llm.Error.Quota | Spice_llm.Error.Rate_limited ->
          [ "retry later or reduce request volume" ]
      | Spice_llm.Error.Context_overflow ->
          [ "compact the session or reduce the request size" ]
      | Spice_llm.Error.Cancelled | Spice_llm.Error.Invalid_request
      | Spice_llm.Error.Unsupported | Spice_llm.Error.Content_policy
      | Spice_llm.Error.Transport | Spice_llm.Error.Timeout
      | Spice_llm.Error.Decode | Spice_llm.Error.Malformed_stream
      | Spice_llm.Error.Provider | Spice_llm.Error.Other _ ->
          [])
  | Transcript_not_ready _ ->
      [ "resolve the pending tool calls or waiting before compacting" ]
  | No_compaction_model ->
      [ "configure an explicit compaction model or run a turn first" ]
  | Archived id ->
      [
        "restore it first: spice session restore "
        ^ Filename.quote (Spice_session.Id.to_string id);
      ]
  | Tool_claim_not_pending _ ->
      [ "run `spice session show` to find the pending tool claim id" ]
  | Not_found _ | Storage _ | Invalid_answer _ | Deleted _
  | Active_turn_exists _ | No_active_turn | Permission_not_pending _
  | Tool_call_not_pending _ | Nothing_to_summarize | Empty_compaction_summary
  | Internal _ ->
      []

let diagnostic error =
  Spice_diagnostic.of_text ~hints:(hints error) (message error)

let pp ppf error = Format.pp_print_string ppf (message error)
