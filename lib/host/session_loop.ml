(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The private execution core. It owns the host-side interpreter machinery —
   {!type:hooks}, the error flatteners, and the loop itself — and speaks the
   protocol vocabulary: a {!Spice_protocol.Command.t} in, a saved document beside
   a {!Spice_protocol.Outcome.t} out, {!Spice_protocol.Event.t} on the observer,
   {!Spice_protocol.Error.t} on failure. {!Session} re-exposes the hooks surface
   abstractly and adds the standalone workflows; {!Runner} holds the injected
   parts and calls {!execute}. Keeping the loop here makes {!Runner.execute} the
   sole public execution ingress: there is no second "advance the session" verb.

   The [.mli] exposes the {!type:hooks} record transparently: its fields must
   stay visible to the sibling {!Runner} and {!Live} that read them, while
   consumers see only the abstract {!Session.hooks}. *)

open Result.Syntax

let log_src =
  Logs.Src.create "spice.host.session_loop" ~doc:"Session interpreter loop"

module Log = (val Logs.src_log log_src : Logs.LOG)

let no_after_save _document _events = ()
let no_observe _event = ()
let not_cancelled () = false

let waiting_kind = function
  | Spice_session.Waiting.Permission _ -> "permission"
  | Spice_session.Waiting.Tool_claim _ -> "tool_claim"
  | Spice_session.Waiting.Host_tool _ -> "host_tool"

(* Error flattening. Lower-layer errors are regrouped by the protocol error's
   caller-recovery classes; invariant violations hosts cannot repair become
   {!Spice_protocol.Error.Internal}. *)

let session_error ~id (error : Spice_session.Error.t) : Spice_protocol.Error.t =
  match error with
  | Spice_session.Error.Archived -> Spice_protocol.Error.Archived id
  | Spice_session.Error.Deleted -> Spice_protocol.Error.Deleted id
  | Spice_session.Error.Active_turn turn ->
      Spice_protocol.Error.Active_turn_exists turn
  | Spice_session.Error.State _ | Spice_session.Error.Replay _
  | Spice_session.Error.Unknown_turn _
  | Spice_session.Error.Turn_not_finished _ ->
      (* Anchor-resolution errors cannot arise here: the loop never resolves
         rewind anchors. They flatten with [State] as unrepairable. *)
      Spice_protocol.Error.Internal (Spice_session.Error.message error)

let of_store (error : Spice_session_store.Error.t) : Spice_protocol.Error.t =
  match error with
  | Spice_session_store.Error.Not_found id -> Spice_protocol.Error.Not_found id
  | Spice_session_store.Error.Conflict { id; expected; actual } ->
      Spice_protocol.Error.Conflict { id; expected; actual }
  | Spice_session_store.Error.Corrupt { path; message }
  | Spice_session_store.Error.Io { path; message } ->
      Spice_protocol.Error.Storage { path; message }
  | Spice_session_store.Error.Already_exists _ ->
      Spice_protocol.Error.Internal (Spice_session_store.Error.message error)
  | Spice_session_store.Error.Session { id; error } -> session_error ~id error

let of_compaction (error : Compaction_run.error) : Spice_protocol.Error.t =
  match error with
  | Compaction_run.Nothing_to_summarize ->
      Spice_protocol.Error.Nothing_to_summarize
  | Compaction_run.No_compaction_model ->
      Spice_protocol.Error.No_compaction_model
  | Compaction_run.Empty_compaction_summary ->
      Spice_protocol.Error.Empty_compaction_summary
  | Compaction_run.Transcript_not_ready error ->
      Spice_protocol.Error.Transcript_not_ready error
  | Compaction_run.Provider error -> Spice_protocol.Error.Provider error
  | Compaction_run.Store error -> of_store error
  | Compaction_run.Internal message -> Spice_protocol.Error.Internal message

let run_error session (error : Spice_session_run.Error.t) :
    Spice_protocol.Error.t =
  match error with
  | Spice_session_run.Error.No_active_turn ->
      Spice_protocol.Error.No_active_turn
  | Spice_session_run.Error.Permission_not_pending id ->
      Spice_protocol.Error.Permission_not_pending id
  | Spice_session_run.Error.Tool_claim_not_pending id ->
      Spice_protocol.Error.Tool_claim_not_pending id
  | Spice_session_run.Error.Tool_call_not_pending { call_id; name } ->
      Spice_protocol.Error.Tool_call_not_pending { call_id; name }
  | Spice_session_run.Error.Archived ->
      Spice_protocol.Error.Archived (Spice_session.id session)
  | Spice_session_run.Error.Deleted ->
      Spice_protocol.Error.Deleted (Spice_session.id session)
  | Spice_session_run.Error.Request _ | Spice_session_run.Error.Tool _
  | Spice_session_run.Error.Tool_result_mismatch _
  | Spice_session_run.Error.State _ ->
      Spice_protocol.Error.Internal (Spice_session_run.Error.message error)

let map_run session result = Result.map_error (run_error session) result

let document_id document = Spice_session_store.Document.id document
let map_store result = Result.map_error of_store result

(* Compaction reuses raw store appends and maps its own error class back into
   the protocol error boundary. *)
let raw_save store document events =
  match events with
  | [] -> Ok document
  | _ :: _ -> Spice_session_store.append store document events

type request_preparation = {
  request : Spice_llm.Request.t;
  commit : unit -> unit;
  rollback : unit -> unit;
}

let rollback_if_raises prepared f =
  match f () with
  | result -> result
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      (match prepared.rollback () with
      | () -> ()
      | exception rollback ->
          Log.err (fun m ->
              m "prepared request rollback failed: %s"
                (Printexc.to_string rollback)));
      Printexc.raise_with_backtrace exn backtrace

type hooks = {
  prepare_request :
    observe:(Spice_protocol.Event.t -> unit) ->
    Spice_llm.Request.t ->
    (request_preparation, Spice_protocol.Error.t) result;
  after_save :
    Spice_session_store.Document.t -> Spice_session.Event.t list -> unit;
  around_tool :
    observe:(Spice_protocol.Event.t -> unit) ->
    Spice_session_store.Document.t ->
    Spice_session.Tool_claim.Started.t ->
    Spice_tool.Output.t Spice_tool.Result.t ->
    unit;
  observe : Spice_protocol.Event.t -> unit;
  terminal :
    observe:(Spice_protocol.Event.t -> unit) ->
    Spice_session_store.Document.t * Spice_protocol.Outcome.t ->
    unit;
  cancelled : unit -> bool;
}

let no_prepare_request ~observe:_ request =
  Ok { request; commit = ignore; rollback = ignore }

let no_around_tool ~observe:_ _document _execution _result = ()

let no_hooks =
  {
    prepare_request = no_prepare_request;
    after_save = no_after_save;
    around_tool = no_around_tool;
    observe = no_observe;
    terminal = (fun ~observe:_ _ -> ());
    cancelled = not_cancelled;
  }

let with_prepare_request prepare_request hooks = { hooks with prepare_request }
let with_after_save after_save hooks = { hooks with after_save }
let after_save hooks document events = hooks.after_save document events

let with_around_tool around hooks =
  let previous = hooks.around_tool in
  {
    hooks with
    around_tool =
      (fun ~observe document execution ->
        let finish_previous = previous ~observe document execution in
        around ~observe document execution finish_previous);
  }

let with_observe observe hooks = { hooks with observe }
let observe hooks event = hooks.observe event

let with_terminal_observed terminal hooks =
  let previous = hooks.terminal in
  {
    hooks with
    terminal =
      (fun ~observe settled ->
        previous ~observe settled;
        terminal ~observe settled);
  }

let with_cancelled cancelled hooks = { hooks with cancelled }

let request_with_notices request notices =
  match notices with
  | [] -> Ok request
  | _ :: _ ->
      Spice_llm.Request.append_prelude request
        (List.map Spice_protocol.Notice.to_message notices)
      |> Result.map_error (fun error ->
          Spice_protocol.Error.Internal (Spice_llm.Request.Error.message error))

let with_notices ?(before_request = ignore) queue hooks =
  let prepare_request ~observe request =
    before_request ();
    let batch = Notice_queue.take queue in
    let notices = Notice_queue.notices batch in
    match request_with_notices request notices with
    | Error _ as error ->
        Notice_queue.rollback batch;
        error
    | Ok request ->
        (match notices with
        | [] -> ()
        | _ :: _ ->
            observe (Spice_protocol.Event.Notices_injected notices));
        Ok
          {
            request;
            commit = (fun () -> Notice_queue.commit batch);
            rollback = (fun () -> Notice_queue.rollback batch);
          }
  in
  with_prepare_request prepare_request hooks

let status session =
  Spice_session.Metadata.status (Spice_session.metadata session)

let check_active_document session : (unit, Spice_protocol.Error.t) result =
  match status session with
  | Spice_session.Metadata.Status.Active -> Ok ()
  | Spice_session.Metadata.Status.Archived ->
      Error (Spice_protocol.Error.Archived (Spice_session.id session))
  | Spice_session.Metadata.Status.Deleted ->
      Error (Spice_protocol.Error.Deleted (Spice_session.id session))

let active_turn session =
  Spice_session.State.active_turn_id (Spice_session.state session)

let require_no_active_turn session : (unit, Spice_protocol.Error.t) result =
  match active_turn session with
  | None -> Ok ()
  | Some turn -> Error (Spice_protocol.Error.Active_turn_exists turn)

let require_active_turn session : (unit, Spice_protocol.Error.t) result =
  match active_turn session with
  | Some _ -> Ok ()
  | None -> Error Spice_protocol.Error.No_active_turn

(* The live replay projector. It maps saved session events to durable
   {!Spice_protocol.Event}s, correlating host-tool calls with their answers.
   [Tool_started] comes from the saved claim; [Tool_finished] and [Turn_finished]
   are emitted explicitly from the loop with the real tool result and computed
   final text, so they are skipped here. *)
module String_set = Set.Make (String)
module String_map = Map.Make (String)

let string_set names =
  List.fold_left
    (fun set name -> String_set.add name set)
    String_set.empty names

type projector = {
  mutable host_tool_names : String_set.t;
  mutable pending_calls : Spice_llm.Tool.Call.t String_map.t;
  mutable steps : int;
}

let active_host_tool_names session =
  let state = Spice_session.state session in
  match Spice_session.State.active_turn state with
  | None -> String_set.empty
  | Some turn -> string_set (Spice_session.Turn.host_tools turn)

let new_projector session =
  {
    host_tool_names = active_host_tool_names session;
    pending_calls = String_map.empty;
    steps = 0;
  }

let register_answer projector call =
  projector.pending_calls <-
    String_map.add (Spice_llm.Tool.Call.id call) call projector.pending_calls

let emit_saved projector observe events =
  List.iter
    (fun event ->
      match (event : Spice_session.Event.t) with
      | Spice_session.Event.Turn_started turn ->
          projector.host_tool_names <-
            string_set (Spice_session.Turn.host_tools turn);
          projector.pending_calls <- String_map.empty;
          observe (Spice_protocol.Event.Turn_started turn)
      | Spice_session.Event.Response_appended response ->
          observe (Spice_protocol.Event.Assistant response);
          List.iter
            (fun call ->
              if
                String_set.mem
                  (Spice_llm.Tool.Call.name call)
                  projector.host_tool_names
              then register_answer projector call)
            (Spice_llm.Response.tool_calls response)
      | Spice_session.Event.Tool_claim_started claim ->
          observe (Spice_protocol.Event.Tool_started claim)
      | Spice_session.Event.Tool_claim_finished _ -> ()
      | Spice_session.Event.Message_appended
          (Spice_llm.Message.Tool_result result) -> (
          let call_id = Spice_llm.Tool.Result.call_id result in
          match String_map.find_opt call_id projector.pending_calls with
          | Some call ->
              projector.pending_calls <-
                String_map.remove call_id projector.pending_calls;
              observe
                (Spice_protocol.Event.Host_call
                   {
                     call;
                     kind = Spice_protocol.Call.classify call;
                     result = Some result;
                   })
          | None -> ())
      | Spice_session.Event.Message_appended _ -> ()
      | Spice_session.Event.Permission_requested request ->
          observe (Spice_protocol.Event.Permission_requested request)
      | Spice_session.Event.Permission_resolved resolution ->
          observe (Spice_protocol.Event.Permission_resolved resolution)
      | Spice_session.Event.Compaction_installed compaction ->
          observe (Spice_protocol.Event.Compaction compaction)
      | Spice_session.Event.Turn_finished _ -> ())
    events

let save_step ~store projector hooks document step =
  let events = Spice_session_run.Step.events step in
  match events with
  | [] -> Ok document
  | _ :: _ ->
      let* document =
        Spice_session_store.append store document events |> map_store
      in
      hooks.after_save document events;
      emit_saved projector hooks.observe events;
      Ok document

(* Automatic compaction inside execution reuses the interpreter's [model] effect
   and hooks, including its cancellation signal. The pending request, when given,
   grounds the started progress delta's projection in the same number the
   trigger compared. *)
let execute_compact ~store ~model hooks policy ?request document ~reason =
  (* Summary generation is not an assistant step: its stream deltas must not
     reach the observer as assistant or reasoning text, so the compaction model
     call drops them. *)
  let model ~cancelled request = model ~on_event:ignore ~cancelled request in
  Compaction_run.compact_with
    ~save:(fun document events -> raw_save store document events)
    ~model ~policy ~observe:hooks.observe ~after_save:hooks.after_save
    ~cancelled:hooks.cancelled ?request document ~reason
  |> Result.map_error of_compaction

let should_compact_request policy state request =
  match Compactor.Policy.auto_limit policy with
  | None -> false
  | Some threshold ->
      let pressure = Compactor.Pressure.of_state ~request state in
      Compactor.Pressure.projected_input pressure >= threshold

(* [Spice_protocol.Event.Tool_started] is emitted by the projector from the saved
   [Tool_claim_started] event; this only runs the tool and reports its terminal
   result, so the started fact is not re-emitted here. *)
let run_tool_result hooks execution runnable =
  let name = Spice_tool.Execution.tool runnable in
  Log.info (fun m -> m "tool started name=%s" name);
  let started = Unix.gettimeofday () in
  let result =
    if hooks.cancelled () then
      Spice_tool.Result.interrupted ~reason:"cancelled" ~cancelled:true ()
    else
      match
        Spice_tool.Execution.run runnable ~cancelled:hooks.cancelled
          ~emit:(fun update ->
            hooks.observe
              (Spice_protocol.Event.Tool_updated { claim = execution; update }))
          ()
      with
      | result -> result
      (* Structured cancellation must unwind the fiber, not be demoted to a
         completed-with-failure result: re-raise Eio's control exception before
         the catch-all so only genuine tool bugs become [Failed]. *)
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
          Spice_tool.Result.failed `Failed
            ("tool claim raised: " ^ Printexc.to_string exn)
  in
  let outcome =
    match Spice_tool.Result.status result with
    | Spice_tool.Result.Completed -> "ok"
    | Spice_tool.Result.Failed _ -> "failed"
    | Spice_tool.Result.Interrupted _ -> "interrupted"
  in
  Log.info (fun m ->
      m "tool finished name=%s outcome=%s duration=%.0fms" name outcome
        ((Unix.gettimeofday () -. started) *. 1000.));
  hooks.observe
    (Spice_protocol.Event.Tool_finished { claim = execution; result });
  result

(* [store] is threaded so automatic compaction reaches the durable log with a
   raw store append; the interpreter's own saves flow through {!save_step}. *)
let rec handle_step ~store ~projector ~pressure_compacted ~overflow_compacted
    ~model ~host_tool hooks ?compaction run document step =
  let* document = save_step ~store projector hooks document step in
  match Spice_session_run.Step.next step with
  | Spice_session_run.Step.Waiting
      (Spice_session.Waiting.Host_tool waiting as block) -> (
      let call = waiting.Spice_session.Waiting.call in
      let kind = Spice_protocol.Call.classify call in
      hooks.observe
        (Spice_protocol.Event.Host_call { call; kind; result = None });
      match host_tool ~cancelled:hooks.cancelled document call with
      | Error _ as error -> error
      | Ok (Some result) ->
          let session = Spice_session_store.Document.session document in
          let* step =
            Spice_session_run.answer_host_tool_result run waiting result session
            |> map_run session
          in
          handle_step ~store ~projector ~pressure_compacted ~overflow_compacted
            ~model ~host_tool hooks ?compaction run document step
      | Ok None ->
          let outcome = Spice_protocol.Outcome.of_waiting block in
          hooks.terminal ~observe:hooks.observe (document, outcome);
          Ok (document, outcome))
  | Spice_session_run.Step.Waiting block ->
      let outcome = Spice_protocol.Outcome.of_waiting block in
      hooks.terminal ~observe:hooks.observe (document, outcome);
      Ok (document, outcome)
  | Spice_session_run.Step.Finished { turn; outcome = turn_outcome } ->
      let final_text =
        Spice_session.State.turn_final_text turn
          (Spice_session.state (Spice_session_store.Document.session document))
      in
      hooks.observe
        (Spice_protocol.Event.Turn_finished
           { turn; outcome = turn_outcome; final_text });
      let outcome = Spice_protocol.Outcome.finished ~turn ~outcome:turn_outcome in
      hooks.terminal ~observe:hooks.observe (document, outcome);
      Ok (document, outcome)
  | Spice_session_run.Step.(Request_model _ | Run_tool _)
    when hooks.cancelled () ->
      (* The host cancellation signal fired; finish the active turn as
         interrupted instead of performing the planned effect. The interrupt
         step always reports [Finished]. *)
      let session = Spice_session_store.Document.session document in
      let* step =
        Spice_session_run.interrupt ~reason:"cancelled" session
        |> map_run session
      in
      handle_step ~store ~projector ~pressure_compacted ~overflow_compacted
        ~model ~host_tool hooks ?compaction run document step
  | Spice_session_run.Step.Request_model request ->
      (* Guard scoping: the pressure guard is a latch — set by a pressure
         compaction, held across consecutive over-limit boundaries (one summary
         request per pressure episode), released once a boundary projects under
         the limit. The overflow guard resets on each successful response: the
         next boundary's overflow is a fresh incident with its own single
         recovery. Attempts are bounded per episode: at most one pressure
         compaction, then — separated only by the failed model call — at most
         one overflow recovery, then the terminal error. *)
      let unsafe =
        match compaction with
        | None -> false
        | Some policy ->
            let state =
              Spice_session.state
                (Spice_session_store.Document.session document)
            in
            should_compact_request policy state request
      in
      let pressure_compacted = pressure_compacted && unsafe in
      let call_model () =
        let* prepared = hooks.prepare_request ~observe:hooks.observe request in
        let model_result =
          rollback_if_raises prepared (fun () ->
            projector.steps <- projector.steps + 1;
            Log.debug (fun m -> m "model step=%d" projector.steps);
            hooks.observe (Spice_protocol.Event.Model_started prepared.request);
            (* Stream the model step's deltas to the observer in stream order,
               before the durable [Assistant] this step saves. Visible text,
               reasoning, and the provider's usage snapshot for this response
               are surfaced live; the usage is reconciled durably from the
               response, so this is a progress signal only. Tool-input and
               complete-call deltas are reconciled from the durable response. *)
            let on_event = function
              | Spice_llm.Stream.Event.Text_delta text ->
                  hooks.observe (Spice_protocol.Event.Assistant_delta { text })
              | Spice_llm.Stream.Event.Reasoning_summary_delta text ->
                  hooks.observe (Spice_protocol.Event.Reasoning_delta { text })
              | Spice_llm.Stream.Event.Usage usage ->
                  hooks.observe (Spice_protocol.Event.Usage_updated usage)
              | Spice_llm.Stream.Event.Tool_input_delta _
              | Spice_llm.Stream.Event.Tool_call _ ->
                  ()
            in
            model ~on_event ~cancelled:hooks.cancelled prepared.request)
        in
        match model_result with
        | Error error
          when Option.is_some compaction && (not overflow_compacted)
               && Compaction_run.is_context_overflow error ->
            prepared.rollback ();
            begin match
              execute_compact ~store ~model hooks (Option.get compaction)
                ~request:prepared.request document
                ~reason:Spice_session.Compaction.Reason.Context_overflow
            with
            | Error Spice_protocol.Error.Nothing_to_summarize ->
                Error (Spice_protocol.Error.Provider error)
            | Error error -> Error error
            | Ok result ->
                (* The recovery install is this episode's compaction: latch
                     the pressure guard too, so a still-over-limit projection at
                     the retry boundary cannot trigger an immediate second
                     summary with no progress in between. *)
                advance ~store ~projector ~pressure_compacted:true
                  ~overflow_compacted:true ~model ~host_tool hooks ?compaction
                  run result.Compactor.document
            end
        | Error error ->
            prepared.rollback ();
            Error (Spice_protocol.Error.Provider error)
        | Ok response ->
            prepared.commit ();
            let session = Spice_session_store.Document.session document in
            let* step =
              Spice_session_run.accept_response run response session
              |> map_run session
            in
            handle_step ~store ~projector ~pressure_compacted
              ~overflow_compacted:false ~model ~host_tool hooks ?compaction run
              document step
      in
      if unsafe && not pressure_compacted then
        begin match
          execute_compact ~store ~model hooks (Option.get compaction) ~request
            document ~reason:Spice_session.Compaction.Reason.Context_pressure
        with
        | Error Spice_protocol.Error.Nothing_to_summarize -> call_model ()
        | Error error -> Error error
        | Ok result ->
            advance ~store ~projector ~pressure_compacted:true
              ~overflow_compacted ~model ~host_tool hooks ?compaction run
              result.Compactor.document
        end
      else call_model ()
  | Spice_session_run.Step.Prepare_tool preflight ->
      let preparation =
        Spice_session_run.Preflight.prepare ~cancelled:hooks.cancelled preflight
      in
      let session = Spice_session_store.Document.session document in
      let* step =
        Spice_session_run.finish_tool_preflight run preflight preparation session
        |> map_run session
      in
      handle_step ~store ~projector ~pressure_compacted ~overflow_compacted
        ~model ~host_tool hooks ?compaction run document step
  | Spice_session_run.Step.Run_tool { claim; execution } ->
      projector.steps <- projector.steps + 1;
      Log.debug (fun m -> m "tool step=%d" projector.steps);
      let finish_tool_effect =
        hooks.around_tool ~observe:hooks.observe document claim
      in
      let result = run_tool_result hooks claim execution in
      finish_tool_effect result;
      let session = Spice_session_store.Document.session document in
      let* step =
        Spice_session_run.finish_tool run
          (Spice_session.Tool_claim.Started.id claim)
          result session
        |> map_run session
      in
      handle_step ~store ~projector ~pressure_compacted ~overflow_compacted
        ~model ~host_tool hooks ?compaction run document step

and advance ~store ~projector ~pressure_compacted ~overflow_compacted ~model
    ~host_tool hooks ?compaction run document =
  let session = Spice_session_store.Document.session document in
  let* () = check_active_document session in
  let* () = require_active_turn session in
  let* step = Spice_session_run.resume run session |> map_run session in
  handle_step ~store ~projector ~pressure_compacted ~overflow_compacted ~model
    ~host_tool hooks ?compaction run document step

(* Re-derive the pending host-tool boundary for an {!Spice_protocol.Command.Answer}.
   The protocol answer names its call by [(turn, call_id)] rather than carrying
   the {!Spice_session.Waiting.host_tool} token, so the engine projects the
   session's current boundary and matches: a projection that is not the named
   host-tool call is a mismatch, reported as
   {!Spice_protocol.Error.Tool_call_not_pending}. *)
let pending_host_tool session ~turn ~call_id =
  match Spice_session.State.waiting (Spice_session.state session) with
  | Some (Spice_session.Waiting.Host_tool waiting)
    when Spice_session.Turn.Id.equal waiting.Spice_session.Waiting.turn turn
         && String.equal
              (Spice_llm.Tool.Call.id waiting.Spice_session.Waiting.call)
              call_id ->
      Ok waiting
  | Some (Spice_session.Waiting.Host_tool waiting) ->
      Error
        (Spice_protocol.Error.Tool_call_not_pending
           {
             call_id;
             name =
               Spice_llm.Tool.Call.name waiting.Spice_session.Waiting.call;
           })
  | Some (Spice_session.Waiting.Permission _)
  | Some (Spice_session.Waiting.Tool_claim _)
  | None ->
      Error (Spice_protocol.Error.Tool_call_not_pending { call_id; name = "" })

(* The interpreter loop, given its injected parts directly. {!Runner.execute} is
   the sole public entry; this stays private so there is no second ingress. The
   saved document travels beside the {!Spice_protocol.Outcome.t}. *)
type plan_resolver =
  decision:Spice_protocol.Plan.Decision.t ->
  Spice_protocol.Plan.Proposal.t ->
  (string, Spice_protocol.Error.t) result

let execute ~store ~client ~host_tool ~resolve_plan ~turn_model ~turn_mode ~run
    ?compaction ~hooks document (command : Spice_protocol.Command.t) =
  let session = Spice_session_store.Document.session document in
  let projector = new_projector session in
  let model ~on_event ~cancelled request =
    Spice_llm.Client.response ~on_event ~cancelled client request
  in
  (* The document as of the last committed save. The drive threads its document
     through [handle_step], but an [Error] discards it, and closing the turn
     must append to the latest revision or the store rejects it as a conflict.
     A drive whose first save never committed leaves this at the document we
     entered with — which has no turn of ours to close. *)
  let latest = ref document in
  (* Chained, not replaced: the run installs its own [after_save] (the
     workspace-tooling re-probe) and Live taps it too. *)
  let hooks =
    let prior = hooks.after_save in
    {
      hooks with
      after_save =
        (fun document events ->
          latest := document;
          prior document events);
    }
  in
  (* Every turn that becomes durably active in this call reaches a terminal
     event before this call returns — on the error and exception paths as much
     as on the ordinary one. A turn left active is not merely untidy: it refuses
     every later command against the session (a new prompt, a fork, a rewind, an
     archive), and the frontend, whose own turn ended with the error, never
     offers the interrupt that would close it.

     This wraps the drive — the model/tool loop — and nothing else. The command
     preambles stay outside it, so a stale or mismatched command (an answer to a
     resolved permission, a start against a waiting turn) is refused without
     destroying the healthy turn it was refused against. *)
  let finalize_failed_turn ~message =
    let session = Spice_session_store.Document.session !latest in
    match Spice_session_run.fail ~message session with
    | Error Spice_session_run.Error.No_active_turn ->
        (* This drive left no turn open: it never started one, or a terminal
           event was already saved. *)
        ()
    | Error error ->
        (* Never silent: this is the repair path, and an error here means the
           turn stays active and the session stays wedged. *)
        Log.err (fun m ->
            m "could not close the failed turn: %s"
              (Spice_session_run.Error.message error))
    | Ok step -> (
        match save_step ~store projector hooks !latest step with
        | Ok (_ : Spice_session_store.Document.t) -> ()
        | Error error ->
            Log.err (fun m ->
                m "could not save the failed turn's terminal event: %s"
                  (Spice_protocol.Error.message error)))
  in
  let drive f =
    match f () with
    | Ok _ as ok -> ok
    (* A cancellation in flight surfaces as an ordinary provider [Error] value,
       not an exception: the client polls [hooks.cancelled] mid-stream and
       returns [Llm.Error.Cancelled]. That turn is not failed — it is being
       interrupted, and Live keeps it active on purpose so the queued
       [Command.Interrupt] behind this drain finishes it as [Interrupted].
       Closing it here would both mislabel the outcome and strand that
       interrupt, which no-ops against a turn that is already closed. *)
    | Error _ as error when hooks.cancelled () -> error
    | Error error ->
        finalize_failed_turn ~message:(Spice_protocol.Error.message error);
        Error error
    (* A cancellation exception is the teardown path and travels on. *)
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        finalize_failed_turn
          ~message:("the turn raised: " ^ Printexc.to_string exn);
        Printexc.raise_with_backtrace exn backtrace
  in
  let continue_step document step =
    drive (fun () ->
        handle_step ~store ~projector ~pressure_compacted:false
          ~overflow_compacted:false ~model ~host_tool hooks ?compaction run
          document step)
  in
  let session_id = document_id document in
  let started = Unix.gettimeofday () in
  (match command with
  | Spice_protocol.Command.Start request ->
      Log.info (fun m ->
          m "turn started session=%a turn=%a" Spice_session.Id.pp session_id
            Spice_session.Turn.Id.pp
            (Spice_protocol.Command.Start.id request))
  | Spice_protocol.Command.Interrupt { reason } ->
      Log.info (fun m ->
          m "turn interrupt requested session=%a reason=%s" Spice_session.Id.pp
            session_id
            (Option.value reason ~default:"none"))
  | Spice_protocol.Command.Resume | Spice_protocol.Command.Reply _
  | Spice_protocol.Command.Answer _ | Spice_protocol.Command.Resolve_plan _
  | Spice_protocol.Command.Finish_tool _ ->
      ());
  let result =
    match command with
    | Spice_protocol.Command.Start request ->
        let* () = check_active_document session in
        let* () = require_no_active_turn session in
        let mode = Option.map Spice_protocol.Mode.to_string turn_mode in
        let* step =
          Spice_session_run.start run
            ~id:(Spice_protocol.Command.Start.id request)
            ~input:(Spice_protocol.Command.Start.input request)
            ~model:turn_model
            ?options:(Spice_protocol.Command.Start.options request)
            ?mode ?origin:(Spice_protocol.Command.Start.origin request)
            ?max_steps:(Spice_protocol.Command.Start.max_steps request)
            session
          |> map_run session
        in
        continue_step document step
    | Spice_protocol.Command.Resume ->
        let* () = check_active_document session in
        let* () = require_active_turn session in
        drive (fun () ->
            advance ~store ~projector ~pressure_compacted:false
              ~overflow_compacted:false ~model ~host_tool hooks ?compaction run
              document)
    | Spice_protocol.Command.Reply { permission; answer; via; message } ->
        let* () = check_active_document session in
        let* step =
          Spice_session_run.resolve_permission run ?message ?via permission
            answer session
          |> map_run session
        in
        continue_step document step
    | Spice_protocol.Command.Answer { turn; call_id; answer } ->
        let* () = check_active_document session in
        let* waiting = pending_host_tool session ~turn ~call_id in
        let* text =
          match
            Spice_protocol.Call.classify waiting.Spice_session.Waiting.call
          with
          | Some call ->
              Spice_protocol.Call.answer_text call answer
              |> Result.map_error (fun message ->
                  Spice_protocol.Error.Invalid_answer message)
          | None ->
              Error
                (Spice_protocol.Error.Invalid_answer
                   "the pending tool is not a user-answerable host tool")
        in
        register_answer projector waiting.Spice_session.Waiting.call;
        let* step =
          Spice_session_run.answer_host_tool run waiting ~text session
          |> map_run session
        in
        continue_step document step
    | Spice_protocol.Command.Resolve_plan { turn; call_id; decision } ->
        let* () = check_active_document session in
        let* waiting = pending_host_tool session ~turn ~call_id in
        (* The parked call must decode to a plan proposal; [pending_host_tool]
           proved it is the named host-tool boundary, this proves it is a plan.
           A question or other host tool named here is a client mismatch. *)
        let* proposal =
          match
            Option.bind
              (Spice_protocol.Call.classify waiting.Spice_session.Waiting.call)
              Spice_protocol.Call.plan_proposal
          with
          | Some proposal -> Ok proposal
          | None ->
              Error
                (Spice_protocol.Error.Tool_call_not_pending
                   {
                     call_id;
                     name =
                       Spice_llm.Tool.Call.name
                         waiting.Spice_session.Waiting.call;
                   })
        in
        (* The host applies the durable plan transition and owns the answer
           wording; the parked call is then answered with it exactly as
           {!Answer} would. *)
        let* text = resolve_plan ~decision proposal in
        register_answer projector waiting.Spice_session.Waiting.call;
        let* step =
          Spice_session_run.answer_host_tool run waiting ~text session
          |> map_run session
        in
        continue_step document step
    | Spice_protocol.Command.Finish_tool (id, result) -> (
        let* () = check_active_document session in
        let* step =
          Spice_session_run.finish_tool run id result session |> map_run session
        in
        continue_step document step)
    | Spice_protocol.Command.Interrupt { reason } ->
        let* () = check_active_document session in
        let* step =
          Spice_session_run.interrupt ?reason session |> map_run session
        in
        continue_step document step
  in
  (match result with
  | Ok (_document, Spice_protocol.Outcome.Finished { turn; outcome }) ->
      Log.info (fun m ->
          m
            "turn finished session=%a turn=%a steps=%d duration=%.0fms \
             outcome=%a"
            Spice_session.Id.pp session_id Spice_session.Turn.Id.pp turn
            projector.steps
            ((Unix.gettimeofday () -. started) *. 1000.)
            Spice_session.Turn.Outcome.pp outcome)
  | Ok (_document, Spice_protocol.Outcome.Waiting { waiting; _ }) ->
      Log.info (fun m ->
          m "turn blocked session=%a waiting=%s steps=%d" Spice_session.Id.pp
            session_id (waiting_kind waiting) projector.steps)
  | Error error ->
      Log.debug (fun m ->
          m "turn command failed session=%a error=%s" Spice_session.Id.pp
            session_id
            (Spice_protocol.Error.message error)));
  result
