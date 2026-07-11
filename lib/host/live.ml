(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.host.live" ~doc:"Live session subscriber dispatch"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* The failure a {!force_interrupt} raises on the in-flight drain's switch. It is
   a private sentinel so the drain distinguishes a forced unwind — which it
   reconciles into an [Interrupted] settle — from a genuine teardown cancellation
   coming down from the attachment switch, which must propagate and end the
   loop. *)
exception Force_interrupt

(* The single-drain command loop. Commands enter through {!submit} (from any
   fiber) and are drained one at a time on the loop fiber forked by {!attach}.
   The queue is a mutable deque: ordinary commands append to the back, an
   {!Spice_protocol.Command.Interrupt} jumps to the front so it drains ahead of a
   queued follow-up while leaving the rest of the queue preserved.

   Because Eio schedules fibers cooperatively within one domain, the queue and
   subscriber lists are only mutated between suspension points, so they need no
   lock; {!Eio.Condition} wakes the loop when a command arrives.

   Live taps the runner's hooks (via {!Runner.with_hooks}) at {!attach}: an
   observer forwards every {!Spice_protocol.Event.t} — durable after its save,
   live-only as it occurs — to subscribers on the drain fiber, a cancellation
   samples a Live-owned flag, and an after-save records the latest durable
   document. The flag is what lets an {!Spice_protocol.Command.Interrupt} preempt
   an in-flight drain: a model or tool step samples it and unwinds the turn to a
   terminal [Interrupted]. A provider that surfaces the cancellation as an error
   mid-stream instead of at a step boundary is reconciled by the queued
   interrupt, which finishes the still-active turn from the last saved document. *)

(* A settled drain: the saved document beside the protocol outcome, exactly the
   pair {!Runner.execute} returns. *)
type settled =
  ( Spice_session_store.Document.t * Spice_protocol.Outcome.t,
    Spice_protocol.Error.t )
  result

(* An [amend] job: a read-modify-write over the drain's current document, run on
   the drain fiber so it serializes with turn appends. [reply] resolves the
   blocked caller with the adopted document or the failure. *)
type job = {
  edit :
    Spice_session_store.Document.t ->
    (Spice_session_store.Document.t, Spice_protocol.Error.t) result;
  reply :
    (Spice_session_store.Document.t, Spice_protocol.Error.t) result
    Eio.Promise.u;
}

type t = {
  mutable runner : Runner.t;
  mutable document : Spice_session_store.Document.t;
  mutable last_saved : Spice_session_store.Document.t;
  mutable front : Spice_protocol.Command.t list;
  mutable back : Spice_protocol.Command.t list;
  mutable jobs : job list;
  mutable events : (Spice_protocol.Event.t -> unit) list;
  mutable settled : (settled -> unit) list;
  mutable cancelling : bool;
  mutable closing : bool;
  mutable working : bool;
  mutable drain_cancel : Eio.Switch.t option;
  signal : Eio.Condition.t;
  stopped : unit Eio.Promise.t;
  stop : unit Eio.Promise.u;
}

let has_active_turn document =
  let session = Spice_session_store.Document.session document in
  Option.is_some (Spice_session.State.active_turn (Spice_session.state session))

(* Deliver to subscribers synchronously in registration order; a raising
   subscriber is isolated to its own delivery and never aborts the loop or
   starves other subscribers. *)
let deliver subscribers value =
  List.iter
    (fun handler ->
      try handler value with
      (* A cancellation must unwind the drain fiber, not be isolated as a
         subscriber error. Subscribers do not suspend today, so this cannot
         fire; the filter keeps the invariant if one ever does. *)
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          Log.warn (fun m ->
              m "subscriber raised, isolated: %s" (Printexc.to_string exn)))
    subscribers

(* Tap a runner's hooks with Live's own: forward every event to subscribers
   (after the consumer's own observer, which stays installed), own cancellation
   through the Live flag, and track the latest saved document for interrupt
   recovery. The after-save chains the consumer's callback rather than replacing
   it, so a runner configured with its own after-save keeps it. Shared by
   {!attach} and {!set_runner} so a swapped runner is tapped the same way. *)
let tapped t runner =
  Runner.with_hooks
    (fun hooks ->
      let prior_observe event = Session.observe hooks event in
      hooks
      |> Session.with_observe (fun event ->
          deliver t.events event;
          prior_observe event)
      |> Session.with_after_save (fun document events ->
          t.last_saved <- document;
          Session.after_save hooks document events)
      |> Session.with_cancelled (fun () -> t.cancelling))
    runner

let drain t command =
  (* Sample a fresh cancellation per drain: a flag flipped by an interrupt
     preempts only the drain it arrives during, and is cleared before the queued
     interrupt (or any later command) runs. *)
  t.cancelling <- false;
  (* An interrupt with nothing active to finish is a no-op: the turn it would
     have targeted already settled, so there is no drain result to report. *)
  let noop =
    match command with
    | Spice_protocol.Command.Interrupt _ -> not (has_active_turn t.document)
    | Spice_protocol.Command.Start _ | Spice_protocol.Command.Resume
    | Spice_protocol.Command.Reply _ | Spice_protocol.Command.Answer _
    | Spice_protocol.Command.Resolve_plan _
    | Spice_protocol.Command.Finish_tool _ ->
        false
  in
  if noop then ()
  else begin
    (* Run the drain under a fresh switch a {!force_interrupt} can fail: cancelling
       that switch's context unwinds a step blocked in an {!Eio} flow read, which a
       cooperative flag sample cannot reach. A genuine teardown cancellation from
       the attachment switch is not [Force_interrupt], so it propagates rather than
       being reconciled here. *)
    let settled =
      try
        `Settled
          ( Eio.Switch.run @@ fun sw ->
            t.drain_cancel <- Some sw;
            Fun.protect
              ~finally:(fun () -> t.drain_cancel <- None)
              (fun () -> Runner.execute t.runner t.document command) )
      with
      | Force_interrupt | Eio.Cancel.Cancelled Force_interrupt -> `Forced
      | Eio.Cancel.Cancelled _ as exn ->
          (* A genuine teardown cancellation from the attachment switch: let it
             unwind the drain fiber rather than reporting a spurious failure. *)
          raise exn
      | exn ->
          (* An unexpected fault in turn execution must not tear the whole
             session down: log it with its backtrace and settle the turn as an
             internal failure, which the shell renders as a failure notice while
             the drain loop keeps running. *)
          let backtrace = Printexc.get_raw_backtrace () in
          Log.err (fun m ->
              m "turn execution raised, recovered as internal failure: %s@.%s"
                (Printexc.to_string exn)
                (Printexc.raw_backtrace_to_string backtrace));
          `Settled
            (Error (Spice_protocol.Error.Internal (Printexc.to_string exn)))
    in
    match settled with
    | `Forced ->
        (* A [force_interrupt] hard-cancelled this drain. Advance to the last
           durable document — the turn is still active there — and let the
           front-queued {!Spice_protocol.Command.Interrupt} finish it as
           [Interrupted] next, exactly as the mid-stream error path below. This
           drain reports nothing. *)
        t.document <- t.last_saved
    | `Settled (Ok (document, _outcome) as result) ->
        t.document <- document;
        deliver t.settled result
    | `Settled (Error _) when t.cancelling ->
        (* The cancellation surfaced as a provider error mid-stream rather than
           at a step boundary. Advance to the last durable document — the turn is
           still active there — and let the queued
           {!Spice_protocol.Command.Interrupt}, next in line, finish it as
           [Interrupted]. This drain reports nothing. *)
        t.document <- t.last_saved
    | `Settled (Error _ as result) ->
        (* An errored drain does not advance past the last durably-saved state
           and does not flush the queue. *)
        t.document <- t.last_saved;
        deliver t.settled result
  end

let take_command t =
  match t.front with
  | command :: rest ->
      t.front <- rest;
      Some command
  | [] -> (
      match List.rev t.back with
      | command :: rest ->
          t.back <- List.rev rest;
          Some command
      | [] -> None)

type work = Command of Spice_protocol.Command.t | Job of job

(* An [amend] job drains ahead of queued commands: it is a quick metadata write
   whose caller is blocked awaiting it, so running it promptly (never during an
   in-flight turn — that turn holds the drain fiber until it blocks or finishes)
   unblocks the caller without delaying it behind a queued turn. *)
let take_work t =
  match t.jobs with
  | job :: rest ->
      t.jobs <- rest;
      Some (Job job)
  | [] -> Option.map (fun command -> Command command) (take_command t)

(* Run an [amend] job against the drain's current document and reply to its
   caller. On success the adopted document becomes both the current and
   last-saved state, exactly as a normal drain step maintains it; a failed job
   advances neither. *)
let run_job t job =
  match job.edit t.document with
  | Ok document as result ->
      t.document <- document;
      t.last_saved <- document;
      Eio.Promise.resolve job.reply result
  | Error _ as result -> Eio.Promise.resolve job.reply result

let rec run t =
  (* [loop_no_mutex] registers the waiter before re-checking the queue, so a
     [submit] or [amend] that broadcasts between two drains is never a lost
     wakeup. A {!close} that preserved or synthesized an interrupt drains that
     work first; otherwise closing stops the daemon even when its document is
     parked on an idle boundary. *)
  let next =
    Eio.Condition.loop_no_mutex t.signal (fun () ->
        match take_work t with
        | Some work -> Some (Some work)
        | None when t.closing -> Some None
        | None -> None)
  in
  match next with
  | None ->
      (* Closing before these jobs could drain: their callers are blocked on the
         reply promise, so fail them rather than strand the fibers. *)
      List.iter
        (fun job ->
          Eio.Promise.resolve job.reply
            (Error (Spice_protocol.Error.Internal "live session closed")))
        t.jobs;
      t.jobs <- [];
      `Stop_daemon
  | Some (Command command) ->
      t.working <- true;
      Fun.protect
        (fun () -> drain t command)
        ~finally:(fun () -> t.working <- false);
      run t
  | Some (Job job) ->
      t.working <- true;
      Fun.protect
        (fun () -> run_job t job)
        ~finally:(fun () -> t.working <- false);
      run t

let attach ~sw ~runner document =
  let stopped, stop = Eio.Promise.create () in
  let t =
    {
      runner;
      document;
      last_saved = document;
      front = [];
      back = [];
      jobs = [];
      events = [];
      settled = [];
      cancelling = false;
      closing = false;
      working = false;
      drain_cancel = None;
      signal = Eio.Condition.create ();
      stopped;
      stop;
    }
  in
  t.runner <- tapped t runner;
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Fun.protect
        ~finally:(fun () ->
          t.events <- [];
          t.settled <- [];
          ignore (Eio.Promise.try_resolve t.stop () : bool))
        (fun () -> run t));
  t

(* Installing the tapped runner reassigns [t.runner], which the loop reads afresh
   at each {!drain}: the in-flight drain keeps the runner it was handed to
   {!Runner.execute}, and the swap takes effect at the next drain start. Queue,
   subscriptions, document, and cancellation flag are untouched. *)
let set_runner t runner =
  if t.closing then invalid_arg "Live.set_runner: closed";
  t.runner <- tapped t runner

let submit t command =
  if t.closing then invalid_arg "Live.submit: closed";
  (match command with
  | Spice_protocol.Command.Interrupt _ ->
      (* Preempt any in-flight drain and drain ahead of the preserved queue. *)
      t.cancelling <- true;
      t.front <- command :: t.front
  | Spice_protocol.Command.Start _ | Spice_protocol.Command.Resume
  | Spice_protocol.Command.Reply _ | Spice_protocol.Command.Answer _
  | Spice_protocol.Command.Resolve_plan _ | Spice_protocol.Command.Finish_tool _
    ->
      t.back <- command :: t.back);
  Eio.Condition.broadcast t.signal

let force_interrupt ?reason t =
  if t.closing then ()
  else begin
    (* Flip the sampled flag first: a [run_in_systhread] tool wait is
       uncancellable, so failing the drain's switch cannot wake it — the flag it
       polls does. Front-queue the interrupt exactly as {!submit} does so the
       hard-cancelled drain, once unwound to the last durable document, settles
       as [Interrupted]. Then fail the in-flight drain's switch, clearing the
       handle so a second force degrades to the cooperative path rather than
       re-failing. With no drain in flight this is precisely a submitted
       interrupt. *)
    t.cancelling <- true;
    t.front <- Spice_protocol.Command.Interrupt { reason } :: t.front;
    (match t.drain_cancel with
    | Some sw ->
        t.drain_cancel <- None;
        Eio.Switch.fail sw Force_interrupt
    | None -> ());
    Eio.Condition.broadcast t.signal
  end

let close t =
  Eio.Cancel.protect (fun () ->
      if not t.closing then begin
        t.closing <- true;
        t.cancelling <- true;
        let interrupt_drain = Option.is_some t.drain_cancel in
        t.back <- [];
        List.iter
          (fun job ->
            Eio.Promise.resolve job.reply
              (Error (Spice_protocol.Error.Internal "live session closed")))
          t.jobs;
        t.jobs <- [];
        t.front <-
          (match t.front with
          | (Spice_protocol.Command.Interrupt _ as command) :: _ -> [ command ]
          | _ when interrupt_drain ->
              [
                Spice_protocol.Command.Interrupt
                  { reason = Some "session closed" };
              ]
          | _ -> []);
        (match t.drain_cancel with
        | Some sw when interrupt_drain ->
            t.drain_cancel <- None;
            Eio.Switch.fail sw Force_interrupt
        | Some _ | None -> ());
        Eio.Condition.broadcast t.signal
      end;
      Eio.Promise.await t.stopped)

let amend t edit =
  (* Enqueue a read-modify-write for the single drain and block until it runs.
     A closed attachment has no drain to run it, so fail immediately rather
     than await a reply that never comes; the check and enqueue do not suspend,
     so [closing] cannot flip between them. *)
  if t.closing then Error (Spice_protocol.Error.Internal "live session closed")
  else begin
    let reply, resolver = Eio.Promise.create () in
    t.jobs <- t.jobs @ [ { edit; reply = resolver } ];
    Eio.Condition.broadcast t.signal;
    Eio.Promise.await reply
  end

let write ?live ~store ~session ~f () =
  match live with
  | Some live -> amend live f
  | None -> (
      match Session.load store session with
      | Error _ as error -> error
      | Ok document -> f document)

let events t handler =
  if t.closing then invalid_arg "Live.events: closed";
  t.events <- t.events @ [ handler ]

let on_settled t handler =
  if t.closing then invalid_arg "Live.on_settled: closed";
  t.settled <- t.settled @ [ handler ]

let is_pending t =
  (not t.closing)
  && (t.working
     || match (t.front, t.back, t.jobs) with [], [], [] -> false | _ -> true)

let document t = t.document
