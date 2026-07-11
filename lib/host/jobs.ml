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

type resume_runner =
  Spice_protocol.Subagent_run.t ->
  notices:Notice_queue.t ->
  (Runner.t, string) result

type settlement = (Spice_protocol.Subagent_run.t * outcome, string) result

module Close_error = struct
  type failure = { child : Spice_session.Id.t; message : string }
  type t = failure list

  let make failures = failures
  let failures t = t

  let pp_failure formatter { child; message } =
    Format.fprintf formatter "subagent %a: %s" Spice_session.Id.pp child message

  let pp formatter = function
    | [] -> Format.pp_print_string formatter "subagent registry close failed"
    | failures ->
        Format.pp_print_list
          ~pp_sep:(fun formatter () -> Format.pp_print_string formatter "; ")
          pp_failure formatter failures

  let message error = Format.asprintf "%a" pp error
end

type entry = {
  mutable record : Spice_protocol.Subagent_run.t;
  mutable document : Spice_session_store.Document.t;
  mutable live : Live.t option;
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
  parent : Spice_session.Id.t;
  fs : Eio.Fs.dir_ty Eio.Path.t;
  root : string;
  max_concurrent : int;
  max_depth : int;
  max_exchanges : int;
  mutable running : int;
  mutable entries : (Spice_session.Id.t * entry) list; (* newest first *)
  mutable subscribers : (event -> unit) list;
  mutable closing : bool;
  closed : (unit, Close_error.t) result Eio.Promise.t;
  close : (unit, Close_error.t) result Eio.Promise.u;
}

let create ~sw ~stdenv ~store ~parent ~max_concurrent ~max_depth ~max_exchanges =
  let closed, close = Eio.Promise.create () in
  {
    sw;
    stdenv;
    store;
    parent;
    fs = Eio.Stdenv.fs stdenv;
    root = Spice_session_store.root store |> Spice_path.Abs.to_string;
    max_concurrent;
    max_depth;
    max_exchanges;
    running = 0;
    entries = [];
    subscribers = [];
    closing = false;
    closed;
    close;
  }

let subscribe t handler =
  if t.closing then invalid_arg "Jobs.subscribe: closed";
  t.subscribers <- handler :: t.subscribers

(* A subscriber that raises is isolated to that delivery, like [Live]'s
   subscribers: one bad renderer must not break the drain or its siblings. *)
let emit t event =
  List.iter
    (fun handler -> try handler event with _ -> ())
    (List.rev t.subscribers)

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
  let metrics = Spice_session.metrics session in
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

let parked_boundary_of_document document =
  let session = Spice_session_store.Document.session document in
  match Spice_session.State.waiting (Spice_session.state session) with
  | Some waiting -> Some (Spice_session.Waiting.turn waiting, waiting)
  | None -> None

let settlement_of_record record =
  match Spice_protocol.Subagent_run.status record with
  | Spice_protocol.Subagent_run.Status.Blocked { blocker; _ } ->
      Ok (record, Blocked_on { blocker })
  | Spice_protocol.Subagent_run.Status.Completed { summary; _ } ->
      Ok (record, Summary summary)
  | Spice_protocol.Subagent_run.Status.Failed { message; _ } ->
      Ok (record, Failed_with message)
  | Spice_protocol.Subagent_run.Status.Cancelled _ ->
      Ok (record, Interrupted { reason = None; cancelled = true })
  | Spice_protocol.Subagent_run.Status.Queued
  | Spice_protocol.Subagent_run.Status.Running _ ->
      Error
        ("subagent run has no live owner: "
        ^ Spice_session.Id.to_string (Spice_protocol.Subagent_run.child record))

let hydrate t child =
  match
    Artifacts.Subagent_run.find_descendant ~fs:t.fs ~root:t.root
      ~parent:t.parent ~child
  with
  | Error error -> Error (Artifacts.Error.message error)
  | Ok None ->
      Error ("subagent run not found: " ^ Spice_session.Id.to_string child)
  | Ok (Some record) ->
      let* document =
        Session.load t.store child
        |> Result.map_error Spice_protocol.Error.message
      in
      let* record =
        match settlement_of_record record with
        | Ok _ -> Ok record
        | Error message ->
            update_run t
              ~parent:(Spice_protocol.Subagent_run.parent record)
              ~child ~f:(fun record ->
                Spice_protocol.Subagent_run.fail ~failed_at:(now t.stdenv)
                  ~message record)
      in
      let settlement = settlement_of_record record in
      let settled, resolve = Eio.Promise.create () in
      ignore (Eio.Promise.try_resolve resolve settlement : bool);
      let asked =
        match parked_boundary_of_document document with
        | Some (_, waiting) -> ask_of waiting
        | None -> None
      in
      let entry =
        {
          record;
          document;
          live = None;
          notices = Notice_queue.create ();
          settled;
          resolve;
          exchanges = 0;
          asked;
          message_seq = 0;
        }
      in
      t.entries <- (child, entry) :: t.entries;
      Ok entry

let find t child =
  match List.assoc_opt child t.entries with
  | Some entry -> Ok entry
  | None -> hydrate t child

let find_descendant t ~caller child =
  if Spice_session.Id.equal caller child then
    Error
      ("a subagent cannot target its own session: "
      ^ Spice_session.Id.to_string child)
  else
    match
      Artifacts.Subagent_run.find_descendant ~fs:t.fs ~root:t.root
        ~parent:caller ~child
    with
    | Error error -> Error (Artifacts.Error.message error)
    | Ok None ->
        Error
          ("subagent run " ^ Spice_session.Id.to_string child
         ^ " is not a descendant of session "
          ^ Spice_session.Id.to_string caller)
    | Ok (Some _) -> find t child

let publish_notice t child notice =
  if t.closing then Error "subagent registry is closed"
  else
    let* entry = find t child in
    Notice_queue.publish entry.notices notice;
    Ok ()

let reserve_running t =
  if t.closing then Error "subagent registry is closed"
  else if t.running >= t.max_concurrent then
    Error
      (Printf.sprintf
         "%d subagents are already running, the configured limit \
          (run.subagent_max_concurrent); wait for one to settle or cancel one \
          before spawning"
         t.max_concurrent)
  else begin
    t.running <- t.running + 1;
    Ok ()
  end

let release_running t =
  if t.running <= 0 then invalid_arg "subagent running capacity underflow";
  t.running <- t.running - 1

let close_live entry =
  match entry.live with
  | None -> ()
  | Some live ->
      Live.close live;
      (match entry.live with
      | Some current when current == live -> entry.live <- None
      | Some _ | None -> ())

(* [settle] runs inside the child's Live drain fiber, so it cannot join that
   same fiber. Transfer the terminal attachment to a one-shot owner on the
   registry switch; [entry.live] remains set until the join completes so a
   racing registry close or terminal resume converges on the same [Live.close]. *)
let release_live t entry =
  Eio.Fiber.fork ~sw:t.sw (fun () -> close_live entry)

(* Settle [entry]: transition the ledger from the drain result and publish.
   Terminal settlements release the attachment; a Blocked settlement keeps it,
   so an answer or a message can resume the parked turn in place. Runs on the
   child's drain fiber. *)
let settle t entry ~parent ~child result =
  let prior_error =
    match Spice_protocol.Subagent_run.status entry.record with
    | Spice_protocol.Subagent_run.Status.Running _ when t.running > 0 ->
        release_running t;
        None
    | Spice_protocol.Subagent_run.Status.Running _ ->
        Some "subagent running capacity underflow while settling"
    | Spice_protocol.Subagent_run.Status.Blocked _ -> None
    | Spice_protocol.Subagent_run.Status.Queued
    | Spice_protocol.Subagent_run.Status.Completed _
    | Spice_protocol.Subagent_run.Status.Failed _
    | Spice_protocol.Subagent_run.Status.Cancelled _ ->
        Some
          ("subagent settled from non-running ledger status: "
          ^ Spice_protocol.Subagent_run.Status.to_string
              (Spice_protocol.Subagent_run.status entry.record))
  in
  let settled_at = now t.stdenv in
  (match result with
  | Ok (document, _) -> entry.document <- document
  | Error _ -> ());
  let parked = ref None in
  let transition_and_outcome () =
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
    match prior_error with
    | Some message -> Error message
    | None -> (
        match transition_and_outcome () with
        | Ok run, outcome ->
            entry.record <- run;
            (match (outcome, entry.asked, !parked) with
            | Blocked_on _, Some message, _ -> emit t (Asked { run; message })
            | Blocked_on _, None, Some waiting ->
                emit t (Blocked { run; waiting })
            | Blocked_on _, None, None -> ()
            | (Summary _ | Interrupted _ | Failed_with _ | Wait_interrupted),
              _, _ ->
                ());
            emit t (Settled run);
            Ok (run, outcome)
        | Error ledger, _ -> Error ledger)
  in
  ignore (Eio.Promise.try_resolve entry.resolve settlement : bool);
  (* A blocked child stays attached — its parked turn resumes in place. A
     terminal (or drain-errored) attachment transfers to a closer fiber because
     this callback is running on the attachment it must join. *)
  match settlement with
  | Ok (_, Blocked_on _) -> ()
  | Ok (_, (Summary _ | Interrupted _ | Failed_with _ | Wait_interrupted))
  | Error _ ->
      release_live t entry

(* (Re-)subscribe progress and settlement wiring on [entry]'s current Live.
   The run identity comes from the ledger record, so a Live re-attached over a
   terminal resume rewires with the same tags. *)
let wire t entry live =
  let child = Spice_protocol.Subagent_run.child entry.record in
  let parent = Spice_protocol.Subagent_run.parent entry.record in
  let role = Spice_protocol.Subagent_run.role entry.record in
  let depth = Spice_protocol.Subagent_run.depth entry.record in
  Live.events live (fun event ->
      emit t
        (Progress
           {
             Spice_protocol.Subagent_progress.run = child;
             parent;
             role;
             depth;
             event;
           }));
  Live.on_settled live (fun result -> settle t entry ~parent ~child result)

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

let reserve_spawn t ~depth =
  if depth > t.max_depth then
    Error
      (Printf.sprintf
         "subagent depth %d exceeds the configured limit %d \
          (run.subagent_max_depth)"
         depth t.max_depth)
  else reserve_running t

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

let spawn_reserved t ~parent ~parent_turn ~parent_call_id ~spawn ~depth
    (child_spec : child) =
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
      document = child_document;
      live = Some live;
      notices;
      settled;
      resolve;
      exchanges = 0;
      asked = None;
      message_seq = 0;
    }
  in
  t.entries <- (child, entry) :: t.entries;
  wire t entry live;
  emit t (Started run);
  let request =
    Spice_protocol.Command.Start.make
      ~id:(Spice_session.Turn.Id.of_string (fresh_id t.stdenv "turn"))
      ~input:(Spice_session.Turn.Input.user_text child_spec.prompt)
      ()
  in
  Live.submit live (Spice_protocol.Command.Start request);
  Ok child

let spawn t ~parent ~parent_turn ~parent_call_id ~spawn ~depth child_spec =
  let* () = reserve_spawn t ~depth in
  match
    spawn_reserved t ~parent ~parent_turn ~parent_call_id ~spawn ~depth
      child_spec
  with
  | Ok _ as launched -> launched
  | Error _ as error ->
      release_running t;
      error

(* Re-arm the settlement promise; the next drain settlement resolves the new
   promise, and later [wait]s observe the new episode. *)
let rearm entry =
  let settled, resolve = Eio.Promise.create () in
  entry.settled <- settled;
  entry.resolve <- resolve

let resume_ledger t entry ~child =
  let* () = reserve_running t in
  let previous = entry.record in
  let resumed_at = now t.stdenv in
  let resume () =
    let* reserved = Spice_protocol.Subagent_run.resume ~resumed_at previous in
    (* Reserve both the counter and the record before the ledger write can
       suspend. Other attempts therefore observe the consumed running slot and
       this run as active. *)
    entry.record <- reserved;
    update_run t ~parent:(Spice_protocol.Subagent_run.parent previous) ~child
      ~f:(Spice_protocol.Subagent_run.resume ~resumed_at)
  in
  match resume () with
  | Ok record ->
      entry.record <- record;
      Ok record
  | Error _ as error ->
      entry.record <- previous;
      release_running t;
      error

(* The parked host-tool boundary of a blocked child, from its held document. *)
let parked_boundary entry =
  match parked_boundary_of_document entry.document with
  | Some (turn, Spice_session.Waiting.Host_tool waiting) ->
      Some (turn, Spice_llm.Tool.Call.id waiting.Spice_session.Waiting.call)
  | Some
      ( _,
        ( Spice_session.Waiting.Permission _
        | Spice_session.Waiting.Tool_claim _ ) )
  | None ->
      None

let attach t entry runner =
  let live = Live.attach ~sw:t.sw ~runner entry.document in
  entry.live <- Some live;
  wire t entry live;
  live

(* Resume a blocked child in place: its attachment is still live, so the
   continuation command drains the parked turn. *)
let resume_parked t entry ~child ~runner command =
  let* record = resume_ledger t entry ~child in
  let live =
    match entry.live with Some live -> live | None -> attach t entry runner
  in
  rearm entry;
  entry.asked <- None;
  emit t (Resumed record);
  Live.submit live command;
  Ok ()

(* Resume a terminal child: the old attachment was released at settlement, so
   rebuild one over the run's document and start a new turn. *)
let resume_terminal t entry ~child ~runner text =
  close_live entry;
  let* record = resume_ledger t entry ~child in
  rearm entry;
  let live = attach t entry runner in
  emit t (Resumed record);
  let request =
    Spice_protocol.Command.Start.make
      ~id:(Spice_session.Turn.Id.of_string (fresh_id t.stdenv "turn"))
      ~input:(Spice_session.Turn.Input.user_text text)
      ()
  in
  Live.submit live (Spice_protocol.Command.Start request);
  Ok ()

let message ~runner ~origin t ~caller child text =
  let* () = if t.closing then Error "subagent registry is closed" else Ok () in
  let* entry = find_descendant t ~caller child in
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
              let* runner = runner record ~notices:entry.notices in
              let* () =
                resume_parked t entry ~child ~runner
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
          let* runner = runner record ~notices:entry.notices in
          let* () = resume_terminal t entry ~child ~runner text in
          Ok `Resumed
      | Spice_protocol.Subagent_run.Status.Queued
      | Spice_protocol.Subagent_run.Status.Running _ ->
          Error
            ("subagent run settled with an unexpected status: "
            ^ Spice_session.Id.to_string child))

let asked t child =
  match List.assoc_opt child t.entries with
  | None -> None
  | Some entry -> entry.asked

let answer ~runner t ~caller child command =
  let* () = if t.closing then Error "subagent registry is closed" else Ok () in
  let* entry = find_descendant t ~caller child in
  match Eio.Promise.peek entry.settled with
  | Some (Ok (record, _))
    when match Spice_protocol.Subagent_run.status record with
         | Spice_protocol.Subagent_run.Status.Blocked _ -> true
         | _ -> false ->
      let* runner = runner record ~notices:entry.notices in
      resume_parked t entry ~child ~runner command
  | Some _ | None ->
      Error
        ("subagent run is not parked on a boundary: "
        ^ Spice_session.Id.to_string child)

let await ?(cancelled = fun () -> false) t entry =
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

let wait ?cancelled t ~caller child =
  let* entry = find_descendant t ~caller child in
  await ?cancelled t entry

let cancel t ~caller child =
  let* entry = find_descendant t ~caller child in
  match Eio.Promise.peek entry.settled with
  | None ->
      (match entry.live with
      | Some live ->
          Live.force_interrupt live;
          let settlement = Eio.Promise.await entry.settled in
          close_live entry;
          settlement
      | None ->
          Error
            ("subagent run has no live owner: "
            ^ Spice_session.Id.to_string child))
  | Some (Ok (record, outcome)) -> (
      match Spice_protocol.Subagent_run.status record with
      | Spice_protocol.Subagent_run.Status.Blocked _ ->
          (match entry.live with
          | Some live ->
              (* Rearm before closing the parked attachment. The explicit
                 force supplies cancellation provenance; [Live.close] preserves
                 that queued interrupt, joins the drain, and [settle] owns the
                 one ledger transition and event. The Blocked record makes it
                 explicit that this episode no longer owns running capacity. *)
              entry.asked <- None;
              rearm entry;
              Live.force_interrupt live;
              close_live entry;
              Eio.Promise.await entry.settled
          | None ->
              (* A blocked entry hydrated after process restart has no live
                 executor to finish its held turn. Preserve the recovery
                 contract by settling its durable run record directly; a later
                 persistence repair can derive this view from session truth. *)
              let* record =
                update_run t
                  ~parent:(Spice_protocol.Subagent_run.parent record)
                  ~child ~f:(fun run ->
                    Spice_protocol.Subagent_run.cancel
                      ~cancelled_at:(now t.stdenv) run)
              in
              entry.record <- record;
              entry.asked <- None;
              rearm entry;
              emit t (Settled record);
              let settlement =
                Ok (record, Interrupted { reason = None; cancelled = true })
              in
              ignore
                (Eio.Promise.try_resolve entry.resolve settlement : bool);
              settlement)
      | Spice_protocol.Subagent_run.Status.Cancelled _ -> Ok (record, outcome)
      | Spice_protocol.Subagent_run.Status.Completed _
      | Spice_protocol.Subagent_run.Status.Failed _
      | Spice_protocol.Subagent_run.Status.Queued
      | Spice_protocol.Subagent_run.Status.Running _ ->
          Error
            ("subagent run already settled: " ^ Spice_session.Id.to_string child)
      )
  | Some (Error _) ->
      Error ("subagent run already settled: " ^ Spice_session.Id.to_string child)

let close t =
  Eio.Cancel.protect (fun () ->
      if t.closing then Eio.Promise.await t.closed
      else begin
        t.closing <- true;
        t.subscribers <- [];
        let errors = ref [] in
        let add_error child message =
          errors := { Close_error.child; message } :: !errors
        in
        List.iter
          (fun (child, entry) ->
            (match Eio.Promise.peek entry.settled with
            | Some (Ok (record, _)) -> (
                match Spice_protocol.Subagent_run.status record with
                | Spice_protocol.Subagent_run.Status.Blocked _ -> ()
                | Spice_protocol.Subagent_run.Status.Queued
                | Spice_protocol.Subagent_run.Status.Running _ ->
                    add_error child
                      "settled promise has a non-terminal ledger status"
                | Spice_protocol.Subagent_run.Status.Completed _
                | Spice_protocol.Subagent_run.Status.Failed _
                | Spice_protocol.Subagent_run.Status.Cancelled _ ->
                    ())
            | Some (Error message) -> add_error child message
            | None -> (
                match cancel t ~caller:t.parent child with
                | Ok _ -> ()
                | Error message -> add_error child message));
            close_live entry)
          (List.rev t.entries);
        let result =
          match List.rev !errors with
          | [] -> Ok ()
          | errors -> Error (Close_error.make errors)
        in
        ignore (Eio.Promise.try_resolve t.close result : bool);
        result
      end)

let is_pending t =
  (not t.closing)
  && List.exists
       (fun (_, entry) ->
         Option.fold ~none:false ~some:Live.is_pending entry.live)
       t.entries

let list t = List.rev_map (fun (_, entry) -> entry.record) t.entries
