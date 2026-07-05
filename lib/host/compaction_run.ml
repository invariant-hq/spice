(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The compaction engine shared by manual compaction ({!Session.compact}) and
   the interpreter's automatic pressure and overflow recovery ({!Session_loop}).
   It plans the summary request, runs the summary model through the caller's
   effects, installs the durable compaction, and emits {!Spice_protocol.Event}
   progress. It owns no store, model client, or hooks: those arrive as callbacks
   so both the idle manual path and the mid-turn automatic path reuse one
   summarizer.

   Its {!error} mirrors the recovery-class distinctions the protocol error keeps;
   callers map it back with their session id in scope. *)

open Result.Syntax

let log_src =
  Logs.Src.create "spice.host.compaction_run"
    ~doc:"Session compaction summarizer"

module Log = (val Logs.src_log log_src : Logs.LOG)

type error =
  | Nothing_to_summarize
  | No_compaction_model
  | Empty_compaction_summary
  | Transcript_not_ready of Spice_llm.Transcript.Error.t
  | Provider of Spice_llm.Error.t
  | Store of Spice_session_store.Error.t
  | Internal of string

let error_message = function
  | Nothing_to_summarize ->
      "conversation already fits within the retained tail; nothing to compact"
  | No_compaction_model ->
      "compaction needs an explicit model or a previous session turn"
  | Empty_compaction_summary -> "compaction summary must not be empty"
  | Transcript_not_ready error ->
      Format.asprintf "transcript is not request-ready: %a"
        Spice_llm.Transcript.Error.pp error
  | Provider error -> Spice_llm.Error.message error
  | Store error -> Spice_session_store.Error.message error
  | Internal message -> message

module Partition = struct
  type t = {
    summary_messages : Spice_llm.Message.t list;
    retained_tail_messages : Spice_llm.Message.t list;
    range : Spice_session.Compaction.Range.t;
  }

  let summary_messages t = t.summary_messages
  let retained_tail_messages t = t.retained_tail_messages
  let range t = t.range

  let finish_turn current_rev turns_rev =
    match current_rev with
    | [] -> turns_rev
    | _ :: _ -> List.rev current_rev :: turns_rev

  let turn_groups messages =
    let rec loop prefix_rev current_rev turns_rev = function
      | [] -> (List.rev prefix_rev, List.rev (finish_turn current_rev turns_rev))
      | (Spice_llm.Message.User _ as message) :: rest ->
          let turns_rev = finish_turn current_rev turns_rev in
          loop prefix_rev [ message ] turns_rev rest
      | message :: rest -> (
          match current_rev with
          | [] -> loop (message :: prefix_rev) [] turns_rev rest
          | _ :: _ -> loop prefix_rev (message :: current_rev) turns_rev rest)
    in
    loop [] [] [] messages

  let add_saturating a b = if b > max_int - a then max_int else a + b

  let invalid parameter value =
    invalid_arg
      (Printf.sprintf "Spice_host.Compaction_run.Partition.make: %s, got %d"
         parameter value)

  let estimate_group estimate =
    List.fold_left
      (fun total message ->
        let size = estimate message in
        if size < 0 then invalid "estimate must be non-negative" size
        else add_saturating total size)
      0

  let retained_group_count ~tail_turns ~tail_budget ~estimate groups =
    let rec loop count total = function
      | [] -> count
      | group :: remaining ->
          if count >= tail_turns then count
          else
            let next_total =
              add_saturating total (estimate_group estimate group)
            in
            if next_total <= tail_budget then
              loop (count + 1) next_total remaining
            else count
    in
    loop 0 0 (List.rev groups)

  let split_at n list =
    let rec loop count left_rev rest =
      if count = 0 then (List.rev left_rev, rest)
      else
        match rest with
        | [] -> (List.rev left_rev, [])
        | value :: rest -> loop (count - 1) (value :: left_rev) rest
    in
    loop n [] list

  let make ?(tail_turns = 2) ?(tail_budget = max_int) ~estimate transcript =
    if tail_turns < 0 then invalid "tail_turns must be non-negative" tail_turns;
    if tail_budget < 0 then
      invalid "tail_budget must be non-negative" tail_budget;
    match Spice_llm.Transcript.require_ready transcript with
    | Error error -> Error error
    | Ok () ->
        let messages = Spice_llm.Transcript.messages transcript in
        let prefix, groups = turn_groups messages in
        let retained_groups =
          retained_group_count ~tail_turns ~tail_budget ~estimate groups
        in
        let summarized_groups, retained_groups =
          split_at (List.length groups - retained_groups) groups
        in
        let summary_messages = prefix @ List.concat summarized_groups in
        let retained_tail_messages = List.concat retained_groups in
        let range =
          Spice_session.Compaction.Range.make
            ~summarized_messages:(List.length summary_messages)
            ~retained_tail_messages:(List.length retained_tail_messages)
        in
        Ok { summary_messages; retained_tail_messages; range }
end

let internal_transcript result =
  Result.map_error
    (fun error -> Internal (Spice_llm.Transcript.Error.message error))
    result

let internal_request result =
  Result.map_error
    (fun error -> Internal (Spice_llm.Request.Error.message error))
    result

let compaction_model policy state =
  match Compactor.Policy.model policy with
  | Some model -> Ok model
  | None -> (
      match Spice_session.State.latest_model state with
      | Some model -> Ok model
      | None -> Error No_compaction_model)

(* Summary quality gates every turn after a compaction, so the instruction is a
   fixed structured template like the reference agents ship, not a one-line
   ask. Tests pin only the first sentence and never parse summary prose. *)
let compaction_summary_prompt =
  String.concat "\n"
    [
      "Summarize the conversation history above so a coding agent can continue \
       this session from the summary alone.";
      "Structure the summary with these markdown sections, omitting a section \
       only when it has no content:";
      "## Goal";
      "## Constraints & Preferences";
      "## Key Decisions";
      "## Files & Commands";
      "## Completed";
      "## Pending";
      "## Errors & Learnings";
      "Preserve exact file paths, commands, identifiers, and error messages \
       that matter for continuing the work.";
      "Do not mention the compaction process. Do not invent facts.";
    ]

let summary_max_retries = 2

let summary_request policy model messages =
  let prelude =
    Option.value
      (Compactor.Policy.prelude policy)
      ~default:Spice_llm.Request.Prelude.empty
  in
  let prompt = Spice_llm.Message.user_text compaction_summary_prompt in
  let* transcript =
    Spice_llm.Transcript.of_list (messages @ [ prompt ]) |> internal_transcript
  in
  let options =
    Spice_llm.Request.Options.make
      ~tool_choice:Spice_llm.Request.Options.No_tools
      ?max_output_tokens:(Compactor.Policy.summary_max_output_tokens policy)
      ~temperature:0.0 ()
  in
  Spice_llm.Request.make ~model ~prelude ~options transcript |> internal_request

let is_context_overflow error =
  match Spice_llm.Error.kind error with
  | Spice_llm.Error.Context_overflow -> true
  | Spice_llm.Error.Cancelled | Spice_llm.Error.Auth | Spice_llm.Error.Quota
  | Spice_llm.Error.Rate_limited | Spice_llm.Error.Invalid_request
  | Spice_llm.Error.Unsupported | Spice_llm.Error.Content_policy
  | Spice_llm.Error.Transport | Spice_llm.Error.Timeout | Spice_llm.Error.Decode
  | Spice_llm.Error.Malformed_stream | Spice_llm.Error.Provider
  | Spice_llm.Error.Other _ ->
      false

(* Dropping one raw message can orphan tool results — they cannot stand without
   their assistant call — so one drop consumes the oldest message plus any tool
   results left at the head, keeping the remainder a valid transcript. *)
let drop_oldest_summary_input messages =
  let rec drop_orphans dropped = function
    | Spice_llm.Message.Tool_result _ :: rest -> drop_orphans (dropped + 1) rest
    | rest -> (dropped, rest)
  in
  match messages with [] -> (0, []) | _ :: rest -> drop_orphans 1 rest

let rec summarize_compaction ~model_effect ~observe ~cancelled ~policy ~model
    ~attempt messages =
  let* request = summary_request policy model messages in
  observe
    (Spice_protocol.Event.Compaction_progress
       (Spice_protocol.Event.Summarizing request));
  match model_effect ~cancelled request with
  | Ok response ->
      let summary = String.trim (Spice_llm.Response.text ~sep:"\n" response) in
      if String.is_empty summary then Error Empty_compaction_summary
      else
        (* [messages] is the list actually submitted: on the base success it is
           the original input, after retries the reduced (post-drop) list. The
           caller needs it to record what was truly summarized. *)
        Ok (summary, response, messages)
  | Error error
    when is_context_overflow error
         && attempt < summary_max_retries
         && List.length messages > 1 -> (
      match drop_oldest_summary_input messages with
      | _, [] -> Error (Provider error)
      | dropped, remaining ->
          Log.warn (fun m ->
              m
                "compaction summary retry after context overflow attempt=%d \
                 dropped=%d"
                (attempt + 1) dropped);
          observe
            (Spice_protocol.Event.Compaction_progress
               (Spice_protocol.Event.Retrying { dropped_messages = dropped }));
          summarize_compaction ~model_effect ~observe ~cancelled ~policy ~model
            ~attempt:(attempt + 1) remaining)
  | Error error -> Error (Provider error)

let replacement_transcript summary retained_tail =
  let summary_message =
    Spice_llm.Message.user_text
      ("This session was compacted. The following summary covers earlier \
        conversation history and is historical context, not a new request:\n"
     ^ summary)
  in
  Spice_llm.Transcript.of_list (summary_message :: retained_tail)
  |> internal_transcript

let compaction_tokens ~before ~summary_input ~summary_output ~after =
  Spice_session.Compaction.Token_estimate.make ~before ~summary_input
    ~summary_output ~after ()

let compact_with ~save ~model ~policy ~observe ~after_save ~cancelled ?request
    document ~reason =
  let session = Spice_session_store.Document.session document in
  let state = Spice_session.state session in
  let transcript = Spice_session.State.transcript state in
  let pressure = Compactor.Pressure.of_state ?request state in
  let projected_input = Compactor.Pressure.projected_input pressure in
  Log.info (fun m ->
      m "compaction started reason=%a projected_input=%d auto_limit=%s"
        Spice_session.Compaction.Reason.pp reason projected_input
        (match Compactor.Policy.auto_limit policy with
        | None -> "none"
        | Some limit -> string_of_int limit));
  observe
    (Spice_protocol.Event.Compaction_progress
       (Spice_protocol.Event.Started
          {
            reason;
            projected_input;
            basis = Compactor.Pressure.basis pressure;
            auto_limit = Compactor.Policy.auto_limit policy;
          }));
  let attempt () =
    let* model_choice = compaction_model policy state in
    let* partition =
      Partition.make
        ~tail_turns:(Compactor.Policy.keep_turns policy)
        ?tail_budget:(Compactor.Policy.keep_tokens policy)
        ~estimate:Token_heuristic.message transcript
      |> Result.map_error (fun error -> Transcript_not_ready error)
    in
    let summary_messages = Partition.summary_messages partition in
    if List.is_empty summary_messages then Error Nothing_to_summarize
    else
      let* summary, response, submitted =
        summarize_compaction ~model_effect:model ~observe ~cancelled ~policy
          ~model:model_choice ~attempt:0 summary_messages
      in
      let* replacement =
        replacement_transcript summary
          (Partition.retained_tail_messages partition)
      in
      (* The summary request's own usage is provider truth when reported; the
         heuristic only fills its absence. *)
      let summary_input, summary_output =
        match Spice_llm.Response.usage response with
        | Some usage ->
            ( Spice_llm.Usage.input_total usage,
              Spice_llm.Usage.output_total usage )
        | None ->
            ( Token_heuristic.messages submitted,
              Token_heuristic.string summary )
      in
      let after =
        Token_heuristic.messages (Spice_llm.Transcript.messages replacement)
      in
      let tokens =
        compaction_tokens ~before:projected_input ~summary_input ~summary_output
          ~after
      in
      let compaction =
        Spice_session.Compaction.make ~reason ~summary ~transcript:replacement
          ~model:(Spice_llm.Response.model response)
          ~tokens
            (* A context-overflow retry drops the oldest inputs, so the count
               actually summarized is the submitted list, not the partition's
               original span; the retained tail is unchanged by a drop. *)
          ~range:
            (Spice_session.Compaction.Range.make
               ~summarized_messages:(List.length submitted)
               ~retained_tail_messages:
                 (Spice_session.Compaction.Range.retained_tail_messages
                    (Partition.range partition)))
          ()
      in
      let event = Spice_session.Event.compaction_installed compaction in
      let* document =
        save document [ event ] |> Result.map_error (fun e -> Store e)
      in
      after_save document [ event ];
      Log.info (fun m ->
          m
            "compaction finished reason=%a before=%d after=%d summary_input=%d \
             summary_output=%d"
            Spice_session.Compaction.Reason.pp reason projected_input after
            summary_input summary_output);
      observe (Spice_protocol.Event.Compaction compaction);
      Ok { Compactor.document; compaction }
  in
  (* One wrap pairs every started progress delta with exactly one terminal
     fact: the install arrives as the durable {!Spice_protocol.Event.Compaction},
     a no-compactable-history outcome as {!Spice_protocol.Event.Skipped}, and any
     other failure as {!Spice_protocol.Event.Failed}. *)
  match attempt () with
  | Ok _ as ok -> ok
  | Error Nothing_to_summarize ->
      observe
        (Spice_protocol.Event.Compaction_progress
           (Spice_protocol.Event.Skipped
              { reason; message = error_message Nothing_to_summarize }));
      Error Nothing_to_summarize
  | Error error ->
      observe
        (Spice_protocol.Event.Compaction_progress
           (Spice_protocol.Event.Failed
              { reason; message = error_message error }));
      Error error
