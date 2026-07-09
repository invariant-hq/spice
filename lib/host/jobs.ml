(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ( let* ) = Result.bind

(* Fresh ids for registry-minted child sessions and turns. The process id
   separates concurrent Spice processes and the counter breaks ties within one
   clock reading. *)
let id_counter = ref 0

let fresh_id stdenv prefix =
  incr id_counter;
  let stamp =
    Eio.Time.now (Eio.Stdenv.clock stdenv)
    |> Int64.bits_of_float |> Int64.to_string
  in
  prefix ^ "_" ^ stamp ^ "_"
  ^ string_of_int (Unix.getpid ())
  ^ "_" ^ string_of_int !id_counter

let now stdenv =
  Eio.Time.now (Eio.Stdenv.clock stdenv)
  |> Spice_session.Time.of_unix_seconds_float

type outcome =
  | Summary of string
  | Blocked_on of { blocker : string }
  | Interrupted of { reason : string option; cancelled : bool }
  | Failed_with of string
  | Wait_interrupted

type event =
  | Started of Spice_protocol.Subagent_run.t
  | Progress of Spice_protocol.Subagent_progress.t
  | Blocked of {
      run : Spice_protocol.Subagent_run.t;
      waiting : Spice_session.Waiting.t;
    }
  | Asked of { run : Spice_protocol.Subagent_run.t; message : string }
  | Resumed of Spice_protocol.Subagent_run.t
  | Settled of Spice_protocol.Subagent_run.t

type child = {
  runner :
    Spice_session.Id.t -> notices:Notice_queue.t -> (Runner.t, string) result;
  prompt : string;
  title : string;
  cwd : Spice_path.Abs.t;
}

type settlement = (Spice_protocol.Subagent_run.t * outcome, string) result

type entry = {
  mutable record : Spice_protocol.Subagent_run.t;
  mutable live : Live.t;
  child_runner : Runner.t; (* kept for terminal-resume re-attach *)
  notices : Notice_queue.t; (* parent messages ride it, unique keys *)
  mutable settled : settlement Eio.Promise.t;
  mutable resolve : settlement Eio.Promise.u;
  mutable exchanges : int; (* parent<->child messages + asks, across resumes *)
  mutable asked : string option; (* pending unanswered message_parent text *)
  mutable message_seq : int; (* per-message notice key counter *)
}

type t = {
  sw : Eio.Switch.t;
  stdenv : Eio_unix.Stdenv.base;
  store : Spice_session_store.t;
  fs : Eio.Fs.dir_ty Eio.Path.t;
  root : string;
  max_concurrent : int;
  max_depth : int;
  max_exchanges : int;
  mutable entries : (Spice_session.Id.t * entry) list; (* newest first *)
  mutable subscribers : (event -> unit) list;
}

let create ~sw ~stdenv ~store ~max_concurrent ~max_depth ~max_exchanges =
  {
    sw;
    stdenv;
    store;
    fs = Eio.Stdenv.fs stdenv;
    root = Spice_session_store.root store |> Spice_path.Abs.to_string;
    max_concurrent;
    max_depth;
    max_exchanges;
    entries = [];
    subscribers = [];
  }

let subscribe t handler = t.subscribers <- handler :: t.subscribers

(* A subscriber that raises is isolated to that delivery, like [Live]'s
   subscribers: one bad renderer must not break the drain or its siblings. *)
let emit t event =
  List.iter
    (fun handler -> try handler event with _ -> ())
    (List.rev t.subscribers)

let find t child =
  List.assoc_opt child t.entries
  |> Option.to_result
       ~none:("subagent run not found: " ^ Spice_session.Id.to_string child)

let update_run t ~parent ~child ~f =
  match Artifacts.Subagent_run.load ~fs:t.fs ~root:t.root ~parent ~child with
  | Error error -> Error (Artifacts.Error.message error)
  | Ok None ->
      Error ("subagent run not found: " ^ Spice_session.Id.to_string child)
  | Ok (Some run) -> (
      match f run with
      | Error _ as error -> error
      | Ok updated -> (
          match Artifacts.Subagent_run.put ~fs:t.fs ~root:t.root updated with
          | Error error -> Error (Artifacts.Error.message error)
          | Ok () -> Ok updated))

let blocker_text (waiting : Spice_session.Waiting.t) =
  match waiting with
  | Spice_session.Waiting.Permission _ ->
      "child session is waiting for permission"
  | Spice_session.Waiting.Tool_claim _ ->
      "child session has an unfinished tool claim"
  | Spice_session.Waiting.Host_tool host_tool -> (
      let call = host_tool.Spice_session.Waiting.call in
      match Spice_protocol.Call.classify call with
      | Some (Spice_protocol.Call.Question request) ->
          "child session asked: "
          ^ Spice_protocol.Question.Request.question request
      | Some
          ( Spice_protocol.Call.Plan _ | Spice_protocol.Call.Todo _
          | Spice_protocol.Call.Goal _ | Spice_protocol.Call.Subagent _
          | Spice_protocol.Call.Subagent_wait _
          | Spice_protocol.Call.Subagent_cancel _
          | Spice_protocol.Call.Subagent_message _
          | Spice_protocol.Call.Subagent_message_parent _
          | Spice_protocol.Call.Invalid _ )
      | None ->
          "child session is waiting for host tool "
          ^ Spice_llm.Tool.Call.name call)

(* Terminal usage facts from the child's own event log: summed provider
   usage and the finished executable tool-call count. *)
let usage_of session =
  let metrics = Spice_session.Metrics.of_session session in
  Spice_protocol.Subagent_run.Usage.make
    ~prompt_tokens:metrics.Spice_session.Metrics.usage.Spice_llm.Usage.input
    ~completion_tokens:
      metrics.Spice_session.Metrics.usage.Spice_llm.Usage.output
    ~tool_uses:metrics.Spice_session.Metrics.tool_calls
  |> Result.map_error (fun error ->
      Format.asprintf "invalid child session usage: %a"
        Spice_protocol.Subagent_run.Usage.pp_error error)

let exchange_cap_blocker =
  "message exchange limit reached (run.subagent_max_exchanges); waiting for \
   user steering"

(* The pending ask on a Waiting boundary, when the child parked on a
   [message_parent] call. *)
let ask_of (waiting : Spice_session.Waiting.t) =
  match waiting with
  | Spice_session.Waiting.Host_tool host_tool -> (
      match
        Spice_protocol.Call.classify host_tool.Spice_session.Waiting.call
      with
      | Some (Spice_protocol.Call.Subagent_message_parent request) ->
          Some (Spice_protocol.Subagent.Message_parent.Request.message request)
      | Some _ | None -> None)
  | Spice_session.Waiting.Permission _ | Spice_session.Waiting.Tool_claim _ ->
      None

(* Settle [entry]: transition the ledger from the drain result and publish.
   Terminal settlements release the attachment; a Blocked settlement keeps it,
   so an answer or a message can resume the parked turn in place. Runs on the
   child's drain fiber. *)
let settle t entry ~parent ~child result =
  let settled_at = now t.stdenv in
  let parked = ref None in
  let transition_and_outcome :
      unit -> (Spice_protocol.Subagent_run.t, string) result * outcome =
   fun () ->
    match result with
    | Error error ->
        let message = Spice_protocol.Error.message error in
        ( update_run t ~parent ~child ~f:(fun run ->
              Spice_protocol.Subagent_run.fail ~failed_at:settled_at ~message
                run),
          Failed_with message )
    | Ok (document, Spice_protocol.Outcome.Finished { outcome; _ }) -> (
        let session = Spice_session_store.Document.session document in
        let summary =
          match
            Spice_session.State.final_text (Spice_session.state session)
          with
          | Some text when not (String.equal text "") -> text
          | Some _ | None -> "Child session completed without visible text."
        in
        match usage_of session with
        | Error message ->
            ( update_run t ~parent ~child ~f:(fun run ->
                  Spice_protocol.Subagent_run.fail ~failed_at:settled_at
                    ~message run),
              Failed_with message )
        | Ok usage -> (
            match outcome with
            | Spice_session.Turn.Outcome.Completed
            | Spice_session.Turn.Outcome.Step_limit ->
                ( update_run t ~parent ~child ~f:(fun run ->
                      Spice_protocol.Subagent_run.complete
                        ~completed_at:settled_at ~summary ~usage run),
                  Summary summary )
            | Spice_session.Turn.Outcome.Interrupted { reason; cancelled } ->
                ( update_run t ~parent ~child ~f:(fun run ->
                      Spice_protocol.Subagent_run.cancel
                        ~cancelled_at:settled_at ~usage run),
                  Interrupted { reason; cancelled } )
            | Spice_session.Turn.Outcome.Failed { message } ->
                ( update_run t ~parent ~child ~f:(fun run ->
                      Spice_protocol.Subagent_run.fail ~failed_at:settled_at
                        ~message ~usage run),
                  Failed_with message )))
    | Ok (_document, Spice_protocol.Outcome.Waiting { waiting; _ }) ->
        parked := Some waiting;
        let ask = ask_of waiting in
        (match ask with
        | Some message ->
            entry.exchanges <- entry.exchanges + 1;
            entry.asked <- Some message
        | None -> ());
        let blocker =
          match ask with
          | Some message when entry.exchanges > t.max_exchanges ->
              exchange_cap_blocker ^ "; the child asked: " ^ message
          | Some message -> "child session asked: " ^ message
          | None -> blocker_text waiting
        in
        ( update_run t ~parent ~child ~f:(fun run ->
              Spice_protocol.Subagent_run.block ~blocked_at:settled_at ~blocker
                run),
          Blocked_on { blocker } )
  in
  let settlement =
    match transition_and_outcome () with
    | Ok run, outcome ->
        entry.record <- run;
        (match (outcome, entry.asked, !parked) with
        | Blocked_on _, Some message, _ -> emit t (Asked { run; message })
        | Blocked_on _, None, Some waiting -> emit t (Blocked { run; waiting })
        | Blocked_on _, None, None -> ()
        | (Summary _ | Interrupted _ | Failed_with _ | Wait_interrupted), _, _
          ->
            ());
        emit t (Settled run);
        Ok (run, outcome)
    | Error ledger, _ -> Error ledger
  in
  (* A blocked child stays attached — its parked turn resumes in place; only
     terminal (or drain-errored) settlements release the attachment. *)
  (match settlement with
  | Ok (_, Blocked_on _) -> ()
  | Ok (_, (Summary _ | Interrupted _ | Failed_with _ | Wait_interrupted))
  | Error _ ->
      Live.detach entry.live);
  ignore (Eio.Promise.try_resolve entry.resolve settlement : bool)

(* (Re-)subscribe progress and settlement wiring on [entry]'s current Live.
   The run identity comes from the ledger record, so a Live re-attached over a
   terminal resume rewires with the same tags. *)
let wire t entry =
  let child = Spice_protocol.Subagent_run.child entry.record in
  let parent = Spice_protocol.Subagent_run.parent entry.record in
  let role = Spice_protocol.Subagent_run.role entry.record in
  let depth = Spice_protocol.Subagent_run.depth entry.record in
  Live.events entry.live (fun event ->
      emit t
        (Progress
           {
             Spice_protocol.Subagent_progress.run = child;
             parent;
             role;
             depth;
             event;
           }));
  Live.on_settled entry.live (fun result ->
      settle t entry ~parent ~child result)

let escaped_id_component text =
  let hex = "0123456789ABCDEF" in
  let buffer = Buffer.create (String.length text) in
  String.iter
    (fun char ->
      match char with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' ->
          Buffer.add_char buffer char
      | _ ->
          let code = Char.code char in
          Buffer.add_char buffer '%';
          Buffer.add_char buffer hex.[code lsr 4];
          Buffer.add_char buffer hex.[code land 0x0f])
    text;
  Buffer.contents buffer

(* The child session id derives from the parent id and the spawning tool call
   id. Percent-encoding keeps opaque provider ids injective within one parent,
   while leaving common ids readable and stable across reloads. A duplicate
   raw call id — a rewound-and-replayed spawn — still fails at session creation
   rather than silently reusing the old child. An empty call id falls back to
   fresh minting. *)
let child_id t ~parent ~parent_call_id =
  if String.is_empty parent_call_id then
    Spice_session.Id.of_string (fresh_id t.stdenv "ses")
  else
    Spice_session.Id.of_string
      (Spice_session.Id.to_string parent
      ^ "-sub-"
      ^ escaped_id_component parent_call_id)

let running_count t =
  List.length
    (List.filter
       (fun (_, entry) -> Option.is_none (Eio.Promise.peek entry.settled))
       t.entries)

let check_caps t ~depth =
  if depth > t.max_depth then
    Error
      (Printf.sprintf
         "subagent depth %d exceeds the configured limit %d \
          (run.subagent_max_depth)"
         depth t.max_depth)
  else if running_count t >= t.max_concurrent then
    Error
      (Printf.sprintf
         "%d subagents are already running, the configured limit \
          (run.subagent_max_concurrent); wait for one to settle or cancel one \
          before spawning"
         t.max_concurrent)
  else Ok ()

let rollback_spawn t ~document ?run error =
  let ledger_errors =
    match run with
    | None -> []
    | Some run -> (
        match Artifacts.Subagent_run.remove ~fs:t.fs ~root:t.root run with
        | Ok () -> []
        | Error cleanup ->
            [ "ledger cleanup: " ^ Artifacts.Error.message cleanup ])
  in
  let session_errors =
    match Spice_session_store.remove t.store document with
    | Ok () -> []
    | Error cleanup ->
        [ "session cleanup: " ^ Spice_session_store.Error.message cleanup ]
  in
  match ledger_errors @ session_errors with
  | [] -> Error error
  | cleanup ->
      Error (error ^ "; spawn rollback failed: " ^ String.concat "; " cleanup)

let spawn t ~parent ~parent_turn ~parent_call_id ~spawn ~depth
    (child_spec : child) =
  let* () = check_caps t ~depth in
  let child = child_id t ~parent ~parent_call_id in
  let created_at = now t.stdenv in
  (* Build the fallible runner before any durable write, so a runner-assembly
     failure leaves no orphaned child session or ledger record on disk: a failed
     spawn leaves no registered run (see the .mli). *)
  let notices = Notice_queue.create () in
  let* runner = child_spec.runner child ~notices in
  let* run =
    Spice_protocol.Subagent_run.make ~child ~parent ~parent_turn ~parent_call_id
      ~spawn ~depth ~created_at ()
  in
  let* child_document =
    Session.create ~store:t.store ~id:child ~title:child_spec.title
      ~cwd:child_spec.cwd ~created_at ()
    |> Result.map_error Spice_protocol.Error.message
  in
  let run =
    match Artifacts.Subagent_run.put ~fs:t.fs ~root:t.root run with
    | Error error ->
        rollback_spawn t ~document:child_document
          (Artifacts.Error.message error)
    | Ok () -> (
        match
          update_run t ~parent ~child ~f:(fun run ->
              Spice_protocol.Subagent_run.start ~started_at:(now t.stdenv) run)
        with
        | Ok run -> Ok run
        | Error error -> rollback_spawn t ~document:child_document ~run error)
  in
  let* run = run in
  let live = Live.attach ~sw:t.sw ~runner child_document in
  let settled, resolve = Eio.Promise.create () in
  let entry =
    {
      record = run;
      live;
      child_runner = runner;
      notices;
      settled;
      resolve;
      exchanges = 0;
      asked = None;
      message_seq = 0;
    }
  in
  t.entries <- (child, entry) :: t.entries;
  wire t entry;
  emit t (Started run);
  let request =
    Spice_protocol.Command.Start.make
      ~id:(Spice_session.Turn.Id.of_string (fresh_id t.stdenv "turn"))
      ~input:(Spice_session.Turn.Input.user_text child_spec.prompt)
      ()
  in
  Live.submit live (Spice_protocol.Command.Start request);
  Ok child

(* Re-arm the settlement promise; the next drain settlement resolves the new
   promise, and later [wait]s observe the new episode. *)
let rearm entry =
  let settled, resolve = Eio.Promise.create () in
  entry.settled <- settled;
  entry.resolve <- resolve

let resume_ledger t entry ~child =
  let* record =
    update_run t ~parent:(Spice_protocol.Subagent_run.parent entry.record)
      ~child ~f:(fun run ->
        Spice_protocol.Subagent_run.resume ~resumed_at:(now t.stdenv) run)
  in
  entry.record <- record;
  Ok record

(* The parked host-tool boundary of a blocked child, from its held document. *)
let parked_boundary entry =
  let session =
    Spice_session_store.Document.session (Live.document entry.live)
  in
  match
    ( Spice_session.Run.phase session,
      Spice_session.State.active_turn (Spice_session.state session) )
  with
  | ( Spice_session.Run.Phase.Waiting (Spice_session.Waiting.Host_tool waiting),
      Some turn ) ->
      Some (turn, Spice_llm.Tool.Call.id waiting.Spice_session.Waiting.call)
  | _ -> None

(* Resume a blocked child in place: its attachment is still live, so the
   continuation command drains the parked turn. *)
let resume_parked t entry ~child command =
  let* record = resume_ledger t entry ~child in
  rearm entry;
  entry.asked <- None;
  emit t (Resumed record);
  Live.submit entry.live command;
  Ok ()

(* Resume a terminal child: the old attachment was released at settlement, so
   rebuild one over the run's document and start a new turn. *)
let resume_terminal t entry ~child text =
  let* record = resume_ledger t entry ~child in
  rearm entry;
  let live =
    Live.attach ~sw:t.sw ~runner:entry.child_runner (Live.document entry.live)
  in
  entry.live <- live;
  wire t entry;
  emit t (Resumed record);
  let request =
    Spice_protocol.Command.Start.make
      ~id:(Spice_session.Turn.Id.of_string (fresh_id t.stdenv "turn"))
      ~input:(Spice_session.Turn.Input.user_text text)
      ()
  in
  Live.submit live (Spice_protocol.Command.Start request);
  Ok ()

let message ~origin t child text =
  let* entry = find t child in
  let* () =
    match origin with
    | `User -> Ok ()
    | `Model when entry.exchanges < t.max_exchanges -> Ok ()
    | `Model ->
        Error
          ("message exchange limit reached for subagent run "
          ^ Spice_session.Id.to_string child
          ^ " (run.subagent_max_exchanges)")
  in
  let count () =
    match origin with
    | `Model -> entry.exchanges <- entry.exchanges + 1
    | `User -> ()
  in
  (* Queue the message as a notice for the run's next request. *)
  let deliver_message () =
    count ();
    entry.message_seq <- entry.message_seq + 1;
    Notice_queue.publish entry.notices
      (Spice_protocol.Notice.make ~source:"parent"
         ~severity:Spice_protocol.Notice.Severity.Info
         ~title:"message from your caller" ~body:text
         ~key:("parent-message:" ^ string_of_int entry.message_seq)
         ());
    Ok `Delivered
  in
  (* No suspension between reading the settlement state and acting, so a
     message is never both delivered and resumed, and never dropped. *)
  match Eio.Promise.peek entry.settled with
  | None -> deliver_message ()
  | Some (Error ledger) -> Error ledger
  | Some (Ok (record, _)) -> (
      match Spice_protocol.Subagent_run.status record with
      | Spice_protocol.Subagent_run.Status.Blocked _ -> (
          match (entry.asked, parked_boundary entry) with
          | Some _, Some (turn, call_id) ->
              count ();
              let* () =
                resume_parked t entry ~child
                  (Spice_protocol.Command.Answer
                     { turn; call_id; answer = text })
              in
              Ok `Resumed
          | _ ->
              (* Parked on a non-ask boundary (permission, tool claim): the
                 message queues for the run's next request. *)
              deliver_message ())
      | Spice_protocol.Subagent_run.Status.Completed _
      | Spice_protocol.Subagent_run.Status.Failed _
      | Spice_protocol.Subagent_run.Status.Cancelled _ ->
          count ();
          let* () = resume_terminal t entry ~child text in
          Ok `Resumed
      | Spice_protocol.Subagent_run.Status.Queued
      | Spice_protocol.Subagent_run.Status.Running _ ->
          Error
            ("subagent run settled with an unexpected status: "
            ^ Spice_session.Id.to_string child))

let asked t child =
  match find t child with Error _ -> None | Ok entry -> entry.asked

let answer t child command =
  let* entry = find t child in
  match Eio.Promise.peek entry.settled with
  | Some (Ok (record, _))
    when match Spice_protocol.Subagent_run.status record with
         | Spice_protocol.Subagent_run.Status.Blocked _ -> true
         | _ -> false ->
      resume_parked t entry ~child command
  | Some _ | None ->
      Error
        ("subagent run is not parked on a boundary: "
        ^ Spice_session.Id.to_string child)

let wait ?(cancelled = fun () -> false) t child =
  let* entry = find t child in
  (* Sampling, not awaiting: the interrupt signal is a flag Live flips with
     no condition to broadcast, so a blocked wait polls it between short
     sleeps. An interrupted wait returns the latest non-terminal record with
     {!Wait_interrupted}; the run keeps running. *)
  let clock = Eio.Stdenv.clock t.stdenv in
  let rec await () =
    match Eio.Promise.peek entry.settled with
    | Some settlement -> settlement
    | None ->
        if cancelled () then Ok (entry.record, Wait_interrupted)
        else begin
          Eio.Time.sleep clock 0.05;
          await ()
        end
  in
  await ()

let drain ?cancelled t =
  let entries = List.rev t.entries in
  List.iter
    (fun (child, entry) ->
      match Eio.Promise.peek entry.settled with
      | Some _ -> ()
      | None -> ignore (wait ?cancelled t child : _ result))
    entries

let cancel t child =
  let* entry = find t child in
  match Eio.Promise.peek entry.settled with
  | None ->
      Live.submit entry.live
        (Spice_protocol.Command.Interrupt { reason = None });
      Ok ()
  | Some (Ok (record, _)) -> (
      match Spice_protocol.Subagent_run.status record with
      | Spice_protocol.Subagent_run.Status.Blocked _ ->
          (* A parked run has no drain to interrupt: cancellation is a pure
             ledger transition plus release of the held attachment. *)
          let* record =
            update_run t ~parent:(Spice_protocol.Subagent_run.parent record)
              ~child ~f:(fun run ->
                Spice_protocol.Subagent_run.cancel ~cancelled_at:(now t.stdenv)
                  run)
          in
          entry.record <- record;
          entry.asked <- None;
          Live.detach entry.live;
          rearm entry;
          emit t (Settled record);
          ignore
            (Eio.Promise.try_resolve entry.resolve
               (Ok (record, Interrupted { reason = None; cancelled = true }))
              : bool);
          Ok ()
      | _ ->
          Error
            ("subagent run already settled: " ^ Spice_session.Id.to_string child)
      )
  | Some (Error _) ->
      Error ("subagent run already settled: " ^ Spice_session.Id.to_string child)

let list t = List.rev_map (fun (_, entry) -> entry.record) t.entries
