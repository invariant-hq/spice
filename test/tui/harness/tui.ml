(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The deterministic in-process TUI driver.

   The real application runs under [Spice_tui.run] with its environment
   swapped through public seams: a headless [Matrix_test] backend, one virtual
   clock feeding both the matrix loop and every Eio timestamp/sleep (a mock
   Eio clock mirrored with the backend's [now]), a pinned process-environment
   snapshot, and the Mosaic runtime probe.

   The loop runs in one fiber and parks inside the backend's [on_idle] on an
   [Eio.Condition]; the test script runs in another fiber. [signaled] is set
   before every broadcast and re-checked in a loop, so wakes landing between
   drain and await are never lost. Time only moves through {!advance}; waiting
   is {!settle} (quiescence), never a poll against screen content. *)

type t = {
  backend : Matrix_test.t;
  clock : Eio_mock.Clock.t;
  real_clock : float Eio.Time.clock_ty Eio.Std.r;
  cond : Eio.Condition.t;
  parked_cond : Eio.Condition.t;
  mutable signaled : bool;
  mutable parked : bool;
  mutable idles : int;
  mutable wakes : int;
  mutable async_wakes : int;
  mutable last_timeout : float option;
  mutable stopping : bool;
  mutable finished : bool;
  mutable probe : Mosaic.Probe.t option;
  mutable exit_result : (Spice_tui.outcome, Spice_tui.Error.t) result option;
      (** the [Spice_tui.run] result, set once the loop fiber exits *)
  project : Project.t;
  provider : Provider_runtime.t option;
}

(* The virtual clock's launch instant. Ages, elapsed counters, and session-id
   stamps derive from it deterministically. Kept small on purpose: the runtime
   and Mosaic pace frames off sub-second intervals (0.1 s and finer), and at a
   real-epoch magnitude (~1.7e9) those intervals fall below the float ULP, so
   [last +. interval -. now] and [now -. last >= interval] disagree at the
   boundary and a cadence check can stall. A small base keeps that arithmetic
   exact; nothing here renders an absolute wall-clock date. *)
let epoch = 1000.
let debug = Option.is_some (Sys.getenv_opt "TUI_HARNESS_DEBUG")
let timings = Option.is_some (Sys.getenv_opt "TUI_HARNESS_TIMINGS")
let t0 = ref 0.

let mark label =
  if timings then
    let now = Unix.gettimeofday () in
    Printf.eprintf "[t+%6.1fms] %s\n%!" ((now -. !t0) *. 1000.) label

let wake t =
  t.wakes <- t.wakes + 1;
  t.signaled <- true;
  Eio.Condition.broadcast t.cond

(* One short real-clock sleep: lets the backend poll IO and lets systhread
   completions (process spawns, fswatch) re-enter the scheduler. A zero-length
   sleep is not enough — eio's fast path re-runs the fiber without reaching
   the poll phase, starving IO. *)
let breathe t = Eio.Time.sleep t.real_clock 0.001

let check_alive t =
  if t.finished then
    failwith "tui harness: the TUI exited while the script was waiting"

(* Event-based: the loop broadcasts [parked_cond] as it parks (and the loop
   fiber broadcasts it once more when it finishes, so waiters fail loudly). *)
let wait_parked t =
  if debug && not t.parked then Printf.eprintf "[wait_parked] awaiting\n%!";
  while not t.parked do
    check_alive t;
    Eio.Condition.await_no_mutex t.parked_cond
  done

let set_time t time =
  Matrix_test.set_now t.backend time;
  Eio_mock.Clock.set_time t.clock time

(* Quiescence: the loop is parked, no messages are pending, the renderer
   reports no async work (nudged with a redraw when it does), no frame sits
   gated behind the virtual render cadence, and a scheduler drain settles
   nothing new. In-flight performs normally block settling; work parked on a
   held provider gate is the deliberate stable mid-flight state a test wants to
   observe. *)
let gate_held t =
  match t.provider with
  | Some provider -> Provider_runtime.any_held provider
  | None -> false

let provider t =
  match t.provider with
  | Some provider -> provider
  | None -> failwith "tui harness: no provider script was given to run"

(* Wake the loop and block until it parks again — event-paced, no sleep.
   Every wake leads to exactly one fresh park (the loop always returns to
   [on_idle]), so waiting for the idle counter to move is race-free. *)
let round_trip t =
  let target = t.idles + 1 in
  wake t;
  while t.idles < target do
    check_alive t;
    Eio.Condition.await_no_mutex t.parked_cond
  done

(* Step virtual time to [target], letting due frames and timers fire in
   cadence-sized steps. Event-paced: each step costs a loop round-trip
   (microseconds), not a scheduler sleep. *)
let step_to t target =
  let rec loop () =
    wait_parked t;
    let now = Matrix_test.now t.backend in
    if now < target then begin
      let step =
        match t.last_timeout with
        | Some s when s > 0. -> Float.min s (target -. now)
        | _ -> target -. now
      in
      set_time t (now +. step);
      round_trip t;
      loop ()
    end
  in
  loop ()

let messages_pending = "messages"
let performs_pending = "performs"
let render_pending = "render"
let live_pending = "spice.live"
let jobs_pending = "spice.jobs"
let pending probe name = List.mem name (Mosaic.Probe.pending probe)

let held_work name =
  String.equal name performs_pending
  || String.equal name live_pending
  || String.equal name jobs_pending

let settle_budget = 20_000 (* iterations, ~1ms each: fail loudly, never hang *)

let rec settle_from t spent =
  if (debug || timings) && Option.is_some t.probe then (
    let probe = Option.get t.probe in
    mark "settle iteration";
    Printf.eprintf
      "[settle %d] pending:%s redraw:%b parked:%b gate:%b now:%.3f\n%!" spent
      (String.concat "," (Mosaic.Probe.pending probe))
      (Matrix.redraw_requested (Matrix_test.app t.backend))
      t.parked (gate_held t)
      (Matrix_test.now t.backend -. epoch));
  (if spent > settle_budget then
     let probe = Option.get t.probe in
     Util.failf
       "tui harness: settle did not converge (pending:%s redraw:%b parked:%b \
        gate_held:%b)"
       (String.concat "," (Mosaic.Probe.pending probe))
       (Matrix.redraw_requested (Matrix_test.app t.backend))
       t.parked (gate_held t));
  wait_parked t;
  let probe = Option.get t.probe in
  let work = Mosaic.Probe.pending probe in
  if
    List.mem messages_pending work
    || Matrix.redraw_requested (Matrix_test.app t.backend)
  then (
    (* Async work landed a message or a redraw between the loop parking and
       this observation (a provider fiber dispatching, say). Wake the loop to
       process it and re-settle — never step time. The backend renders a
       one-shot redraw at the current instant, so no cadence-flush advance is
       needed; advancing here would instead march live timers (the working-line
       [Sub.every]) a frame past where the interaction left them. *)
    round_trip t;
    settle_from t (spent + 1))
  else if List.mem render_pending work then (
    Matrix.request_redraw (Matrix_test.app t.backend);
    round_trip t;
    settle_from t (spent + 1))
  else if List.exists (fun name -> not (gate_held t && held_work name)) work
  then (
    (* The remaining checks are application or perform fibers. Let Eio poll
       real IO without moving the virtual clock. A deliberately held provider
       request is a stable observation point, so its perform/Live checks do not
       prevent settlement. *)
    breathe t;
    settle_from t (spent + 1))
  else
    (* Quiet-confirmation drain: a few scheduler rounds must pass without a
       wake before the frame counts as settled; bail out early on the first
       sign of activity (the recursion re-evaluates from the top). *)
    let before = (t.idles, t.wakes) in
    let stable = ref true in
    let round = ref 0 in
    while !stable && !round < 3 do
      incr round;
      breathe t;
      if (t.idles, t.wakes) <> before then stable := false
    done;
    if not (!stable && t.parked) then settle_from t (spent + 1)

(* Settle to quiescence and stop where the settle lands — do not step time
   forward. The old backend forced cadence-gated frames through the harness
   here, so a settle drifted a nondeterministic handful of render steps and
   was quantized up to the next whole second to erase that drift. The current
   backend renders a one-shot redraw at the current instant ([pace_redraws]
   off) and advances its own clock only for a live-animation frame deadline, so
   a settle observes a stable frame at an unmoved clock — there is no sub-second
   drift left to quantize away. Quantizing now would only march live timers —
   the working-line [Sub.every] most visibly — a full second past where the
   interaction left them. Time moves solely through {!advance}. *)
let settle t =
  mark "settle: begin";
  settle_from t 0;
  mark "settle: end"

(* Settle the rendered application while one long-lived perform deliberately
   remains pending. Auth browser/device flows publish their challenge and then
   wait for completion or cancellation inside the same perform; ordinary
   [settle] correctly treats that as unfinished work and would wait forever.
   This helper instead requires a pending perform as a positive signal, drains
   every queued message/redraw/render at the current virtual instant, and only
   returns after a short quiet confirmation. *)
let settle_pending_perform ?(provider_responses = 0) t =
  if provider_responses < 0 then
    invalid_arg "Tui.settle_pending_perform: negative provider response count";
  let provider_ready () =
    match (provider_responses, t.provider) with
    | 0, _ -> true
    | _, Some provider -> Provider_runtime.served provider >= provider_responses
    | _, None ->
        invalid_arg
          "Tui.settle_pending_perform: provider responses requested without a \
           provider"
  in
  let rec loop spent quiet =
    if spent > settle_budget then
      Util.failf "tui harness: a pending perform never reached a stable frame";
    wait_parked t;
    let probe = Option.get t.probe in
    let work = Mosaic.Probe.pending probe in
    if
      List.mem messages_pending work
      || Matrix.redraw_requested (Matrix_test.app t.backend)
    then (
      round_trip t;
      loop (spent + 1) 0)
    else if List.mem render_pending work then (
      Matrix.request_redraw (Matrix_test.app t.backend);
      round_trip t;
      loop (spent + 1) 0)
    else if not (provider_ready ()) then (
      breathe t;
      loop (spent + 1) 0)
    else if List.mem performs_pending work then (
      let other_work =
        List.exists
          (fun name ->
            not
              (String.equal name performs_pending
              || (gate_held t && held_work name)))
          work
      in
      if other_work then (
        breathe t;
        loop (spent + 1) 0)
      else if quiet >= 3 then ()
      else
        let before = (t.idles, t.wakes, t.async_wakes) in
        breathe t;
        let quiet =
          if t.parked && before = (t.idles, t.wakes, t.async_wakes) then
            quiet + 1
          else 0
        in
        loop (spent + 1) quiet)
    else (
      breathe t;
      loop (spent + 1) 0)
  in
  loop 0 0

let await_probe_clear t name what =
  let rec loop spent =
    if spent > settle_budget then
      Util.failf "tui harness: %s but %s remained pending" what name;
    check_alive t;
    wait_parked t;
    let probe = Option.get t.probe in
    if pending probe name then (
      breathe t;
      loop (spent + 1))
  in
  loop 0

(* A force-interrupt can settle the main turn while its provider gate remains
   nominally held. Wait for Live to publish that settlement, then settle the
   message and render checks it produced. *)
let settle_turn t =
  await_probe_clear t live_pending "ended a turn";
  settle t

let await_suspend = settle

(* Move virtual time forward by [dt] seconds, relative to the current instant.
   Displayed counters move by exactly [dt]. The trailing settle is
   non-quantizing: a tick left queued at landing flushes one frame, and
   quantizing that residue would ratchet displayed counters a full second on
   timing parity — the spinner phase follows the tick count, not the clock. *)
let advance t dt =
  step_to t (Matrix_test.now t.backend +. dt);
  settle_from t 0

(* A review worktree change arrives through a real fswatch systhread, then the
   review live protocol debounces it for 0.5 seconds on the virtual clock. Wait
   for the out-of-loop watcher wake, park on the pending debounce perform, move
   exactly through that deadline, and settle the resulting reload. *)
let await_review_refresh t change =
  (* The watcher is installed by an asynchronous review-open effect. Give its
     initial scan a scheduler window, then drive one empty polling interval so
     the snapshot is known to predate the mutation. *)
  for _ = 1 to 30 do
    breathe t
  done;
  step_to t (Matrix_test.now t.backend +. 0.25);
  let wake0 = t.async_wakes in
  change ();
  (* Native backends settle an event for 50ms; the polling fallback samples at
     250ms. Driving the larger interval covers both without wall-clock timing. *)
  step_to t (Matrix_test.now t.backend +. 0.25);
  let rec await_wake spent =
    if t.async_wakes > wake0 then ()
    else if spent > settle_budget then
      Util.failf "tui harness: review worktree watcher never fired"
    else (
      check_alive t;
      breathe t;
      await_wake (spent + 1))
  in
  await_wake 0;
  settle_pending_perform t;
  advance t 0.5

(* A lone trailing ESC byte is ambiguous (Escape vs. the start of an Alt/CSI
   sequence), so the parser buffers it behind a 50 ms disambiguation deadline
   and emits the [Escape] key only once that deadline passes. Model the timeout
   exactly as a real terminal does: let the loop buffer the ESC, then step
   virtual time past the deadline and wake it. The backend drains its parser at
   the current instant on that wake (as the Unix backend drains after every
   wait), so the buffered ESC resolves to [Escape] — no synthetic input, so the
   escape-timeout decode path stays covered. (Feeding an empty chunk to force
   the drain does not work: [Parser.feed] re-scans the buffered ESC and re-arms
   its deadline, swallowing the key and the next keystroke with it.) *)
let flush_pending_escape t =
  round_trip t;
  set_time t (Matrix_test.now t.backend +. 0.06);
  wake t

let ends_with_escape bytes =
  let n = String.length bytes in
  n > 0 && Char.equal bytes.[n - 1] '\027'

let keys t bytes =
  Matrix_test.feed t.backend bytes;
  wake t;
  if ends_with_escape bytes then flush_pending_escape t

let enter t = keys t Key.enter
let paste t text = keys t (Key.bracketed_paste text)

let resize t ~width ~height =
  Matrix_test.resize t.backend ~width ~height;
  wake t

let screen t = Matrix_test.screen t.backend

let print t =
  Screen.print ~project:t.project (screen t);
  flush stdout

let project t = t.project

(* Release a held response and wait only until the provider writes it. This is
   the seam for a child response that immediately schedules parent work: waiting
   for the whole application to settle would consume that continuation too. *)
let release_response t name =
  let provider = provider t in
  let served0 = Provider_runtime.served provider in
  Provider_runtime.release provider name;
  let rec await_served spent =
    if Provider_runtime.served provider > served0 then ()
    else if spent > settle_budget then
      Util.failf "tui harness: released gate %S but its response was never sent"
        name
    else (
      check_alive t;
      breathe t;
      await_served (spent + 1))
  in
  await_served 0

(* Release a held response and wait for the main-session settlement. The probe
   remains pending across the socket read, session save, terminal event, and
   settlement delivery, so no provider counter or screen-state proxy is needed.
*)
let release t name =
  Provider_runtime.release (provider t) name;
  settle_turn t

let release_background t name =
  let async0 = t.async_wakes in
  release t name;
  let rec await_delivery spent =
    if t.async_wakes > async0 then ()
    else if spent > settle_budget then
      Util.failf "tui harness: released background gate %S without delivery"
        name
    else (
      check_alive t;
      breathe t;
      await_delivery (spent + 1))
  in
  await_delivery 0;
  settle t

(* Await the [index]th request while pumping the app: the turn pipeline
   interleaves host work with messages the shell must process. *)
let await_request t index =
  let provider = provider t in
  let rec wait rounds =
    match Provider_runtime.request provider index with
    | Some body -> body
    | None ->
        if rounds > 60_000 then
          Util.failf "tui harness: request %d never arrived" index;
        if debug && rounds = 1_000 then
          Printf.eprintf "[await_request %d] screen:\n%s\n%!" index
            (Matrix_test.screen t.backend);
        settle t;
        breathe t;
        wait (rounds + 1)
  in
  wait 0

let await_turn t index =
  let body = await_request t index in
  settle_turn t;
  body

let stop t =
  t.stopping <- true;
  Matrix_test.stop t.backend

(* Block until the app quits on its own (a quit chord, /quit, or a review close),
   i.e. the loop fiber's [Spice_tui.run] returned. Use before {!outcome}; do not
   {!settle} after the app has exited (settle would fail loudly). *)
let await_exit t =
  while not t.finished do
    Eio.Condition.await_no_mutex t.parked_cond
  done

(* The TUI's exit outcome, valid once the app has quit ({!await_exit}). Fails if
   the run errored or the app has not exited yet. *)
let outcome t =
  match t.exit_result with
  | Some (Ok outcome) -> outcome
  | Some (Error error) ->
      Util.failf "tui harness: %s" (Spice_tui.Error.message error)
  | None -> failwith "tui harness: the TUI has not exited (await_exit first)"

type sandbox = [ `Read_only | `Workspace_write | `Danger_full_access ]

let sandbox_mode = function
  | `Read_only -> Spice_host.Sandbox.Mode.Read_only
  | `Workspace_write -> Spice_host.Sandbox.Mode.Workspace_write
  | `Danger_full_access -> Spice_host.Sandbox.Mode.Danger_full_access

let auth_base_url provider =
  let base = Provider_runtime.base_url provider in
  let suffix = "/v1" in
  if String.ends_with ~suffix base then
    String.sub base 0 (String.length base - String.length suffix)
  else base

let run ?(size = (80, 24)) ?(env = []) ?(unordered = false) ?(review = false)
    ?(openai_auth = false) ?sandbox ?provider:script ?session ?draft ?submit
    ?(unset = []) ?seed ~name f =
  t0 := Unix.gettimeofday ();
  mark "run: start";
  Project.with_temp name @@ fun project ->
  mark "run: project ready";
  (* Fixtures (seeded sessions, prompt history, a file tree) are written into
     the fresh project before the app loads, so the boot reads them. *)
  Option.iter (fun seed -> seed project) seed;
  Eio_main.run @@ fun stdenv ->
  mark "run: eio up";
  (* The mock clock tracelns every [set_time]; keep goldens free of it. *)
  let silent =
    {
      Eio.Debug.traceln =
        (fun ?__POS__:_ fmt -> Format.ikfprintf ignore Format.err_formatter fmt);
    }
  in
  Eio.Fiber.with_binding (Eio.Stdenv.debug stdenv)#traceln silent @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let provider =
    Option.map
      (fun script ->
        Provider_runtime.start ~sw ~net:(Eio.Stdenv.net stdenv) ~unordered
          script)
      script
  in
  let env =
    match (openai_auth, provider) with
    | true, Some provider ->
        ("SPICE_OPENAI_AUTH_BASE_URL", auth_base_url provider) :: env
    | false, _ -> env
    | true, None -> failwith "tui harness: openai_auth requires a provider"
  in
  let overrides =
    Project.bindings
      ?openai_base_url:(Option.map Provider_runtime.base_url provider)
      ~unset ~extra:env project
  in
  Project.apply overrides;
  let process_env = Project.env_snapshot ~unset overrides in
  let root = Spice_path.Abs.of_string_exn (Project.root project) in
  (match Spice_host.Trust.trust ~stdenv ~process_env ~root () with
  | Ok _ -> ()
  | Error error ->
      Util.failf "tui harness trust seed: %s"
        (Spice_host.Trust.Error.message error));
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock epoch;
  let width, height = size in
  let cell = ref None in
  let on_idle _backend ~timeout =
    let t = Option.get !cell in
    t.idles <- t.idles + 1;
    if t.idles = 1 then mark "loop: first park";
    t.last_timeout <- timeout;
    t.parked <- true;
    Eio.Condition.broadcast t.parked_cond;
    while (not t.signaled) && not t.stopping do
      Eio.Condition.await_no_mutex t.cond
    done;
    t.signaled <- false;
    t.parked <- false
  in
  let on_wake () =
    Option.iter
      (fun t ->
        t.async_wakes <- t.async_wakes + 1;
        wake t)
      !cell
  in
  (* 10 fps virtual cadence: every time-march round-trip renders one real
     frame, so the cadence sets the cost of advancing time (advance 1.0 =
     10 renders, not 60). The app's finest [Sub.every] is 0.1 s, so timer
     fidelity is unchanged; frames between timer firings are unobservable —
     tests only read settled frames. *)
  let backend =
    Matrix_test.create ~target_fps:10. ~now:epoch ~on_idle ~on_wake ~width
      ~height ()
  in
  let t =
    {
      backend;
      clock;
      real_clock = Eio.Stdenv.clock stdenv;
      cond = Eio.Condition.create ();
      parked_cond = Eio.Condition.create ();
      signaled = false;
      parked = false;
      idles = 0;
      wakes = 0;
      async_wakes = 0;
      last_timeout = None;
      stopping = false;
      finished = false;
      probe = None;
      exit_result = None;
      project;
      provider;
    }
  in
  cell := Some t;
  (* The temp project root is created inside {!run}, so the startup is built
     here rather than passed in: [cwd] is always the project root, and the
     launch inputs map to the same startup the CLI resolves before the TUI
     boots — [session] resumes a seeded document ([spice resume]), [draft] seeds
     the composer ([--draft]), [submit] runs the first prompt ([-p]). *)
  let startup =
    let input =
      match (draft, submit) with
      | None, None -> Spice_tui.Startup.Empty
      | Some text, None -> Spice_tui.Startup.Draft text
      | None, Some text -> Spice_tui.Startup.Submit text
      | Some _, Some _ ->
          failwith "tui harness: draft and submit are mutually exclusive"
    in
    (* [~review] boots straight onto the /review screen, the [spice review]
       subcommand's [Launch_review] path (base = HEAD); the default is the chat
       launch. Kept as a bool so tests need no [Spice_tui] dependency. *)
    let launch =
      if review then Some (Spice_tui.Startup.Launch_review { base_spec = None })
      else None
    in
    Spice_tui.Startup.make
      ~cwd:(Spice_path.Abs.of_string_exn (Project.root project))
      ?session:(Option.map Spice_session.Id.of_string session)
      ?launch
      ?sandbox:(Option.map sandbox_mode sandbox)
      ~input ()
  in
  mark "run: launching";
  Eio.Fiber.both
    (fun () ->
      Fun.protect
        ~finally:(fun () ->
          mark "loop: finished";
          t.finished <- true;
          Eio.Condition.broadcast t.parked_cond)
        (fun () ->
          t.exit_result <-
            Some
              (Spice_tui.run ~stdenv ~startup
                 ~clock:(clock :> float Eio.Time.clock_ty Eio.Std.r)
                 ~matrix:(Matrix_test.app backend)
                 ~probe:(fun probe ->
                   mark "loop: probe received (host loaded)";
                   t.probe <- Some probe)
                 ~process_env ())))
    (fun () ->
      Fun.protect
        ~finally:(fun () ->
          mark "script: done, stopping";
          stop t)
        (fun () -> f t));
  mark "run: fibers joined";
  match t.exit_result with
  | Some (Ok (_ : Spice_tui.outcome)) -> ()
  | Some (Error error) ->
      Util.failf "tui harness: %s" (Spice_tui.Error.message error)
  | None -> failwith "tui harness: the TUI never returned"
