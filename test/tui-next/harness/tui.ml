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
  mutable last_timeout : float option;
  mutable stopping : bool;
  mutable finished : bool;
  mutable probe : Mosaic.Probe.t option;
  project : Project.t;
  provider : Provider.t option;
}

(* A fixed launch instant (2026-07-09T02:40:00Z). Ages, elapsed counters, and
   session-id stamps derive from it deterministically. *)
let epoch = 1_783_565_000.
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
   nothing new. In-flight performs do NOT block settling — a perform parked on
   a held provider gate is exactly the stable mid-flight state a test wants to
   observe. *)
let gate_held t =
  match t.provider with
  | Some provider -> Provider.any_held provider
  | None -> false

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

let next_second t =
  let position = Matrix_test.now t.backend -. epoch in
  epoch +. Float.ceil (position +. 1e-6)

let settle_budget = 20_000 (* iterations, ~1ms each: fail loudly, never hang *)

let rec settle_from t spent =
  if (debug || timings) && Option.is_some t.probe then (
    let probe = Option.get t.probe in
    mark "settle iteration";
    Printf.eprintf
      "[settle %d] performs:%b messages:%b render:%b redraw:%b \
       parked:%b         gate:%b now:%.3f\n\
       %!"
      spent
      (Mosaic.Probe.performs_pending probe)
      (Mosaic.Probe.messages_pending probe)
      (Mosaic.Probe.render_pending probe)
      (Matrix.redraw_requested (Matrix_test.app t.backend))
      t.parked (gate_held t)
      (Matrix_test.now t.backend -. epoch));
  (if spent > settle_budget then
     let probe = Option.get t.probe in
     Util.failf
       "tui harness: settle did not converge (performs:%b messages:%b        \
        render:%b redraw:%b parked:%b gate_held:%b)"
       (Mosaic.Probe.performs_pending probe)
       (Mosaic.Probe.messages_pending probe)
       (Mosaic.Probe.render_pending probe)
       (Matrix.redraw_requested (Matrix_test.app t.backend))
       t.parked (gate_held t));
  wait_parked t;
  let probe = Option.get t.probe in
  if Mosaic.Probe.performs_pending probe && not (gate_held t) then (
    (* Asynchronous work (the brief load, a turn past its released gate) is
       in flight and nothing is deliberately held: wait for its completion —
       the perform wrapper wakes the loop when it finishes. Some background
       work also sleeps on the (virtual) clock — the dune RPC probe's retry
       backoff, for example — so periodically step time forward one second,
       as real waiting would. Held-gate states never reach this branch, so
       observed elapsed counters stay frozen where tests need them. *)
    breathe t;
    if spent mod 32 = 31 then step_to t (next_second t);
    settle_from t (spent + 1))
  else if
    Mosaic.Probe.messages_pending probe
    || Matrix.redraw_requested (Matrix_test.app t.backend)
  then (
    (* Work is queued but the loop parked: under live animation the render
       cadence gates it behind a virtual frame deadline. Flush by advancing
       to the deadline — at most one frame interval, exactly what real time
       would have done. *)
    (match t.last_timeout with
    | Some s when s > 0. && t.parked ->
        set_time t (Matrix_test.now t.backend +. s)
    | _ -> ());
    round_trip t;
    settle_from t (spent + 1))
  else if Mosaic.Probe.render_pending probe then (
    Matrix.request_redraw (Matrix_test.app t.backend);
    round_trip t;
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

(* Settle, then land on a whole virtual second. Settling can consume a few
   render-cadence steps (16.7ms each) whenever live animation gates queued
   messages, and how many depends on real async interleaving. Quantizing to
   the next second boundary absorbs that drift, so spinner phases and elapsed
   counters are identical run to run. *)
let settle t =
  mark "settle: begin";
  let rec quantized rounds =
    settle_from t 0;
    let now = Matrix_test.now t.backend in
    (* Tolerant ceiling: already sitting on a boundary is settled. *)
    let boundary = epoch +. Float.ceil (now -. epoch -. 1e-6) in
    if now < boundary -. 1e-6 && rounds < 4 then begin
      step_to t boundary;
      quantized (rounds + 1)
    end
  in
  quantized 0;
  mark "settle: end"

(* Move virtual time forward by [dt] seconds. Relative to the current
   instant — call after {!settle} so the base is a quantized boundary and
   displayed counters move by exactly [dt]. The trailing settle is
   non-quantizing: a tick left queued at landing flushes one frame
   (16.7 ms), and quantizing that residue would ratchet displayed counters
   a full second on timing parity. Displayed state doesn't need it — the
   spinner phase follows the tick count, not the clock. *)
let advance t dt =
  step_to t (Matrix_test.now t.backend +. dt);
  settle_from t 0

(* A lone trailing ESC byte is ambiguous (Escape vs. the start of an Alt/CSI
   sequence), so the parser buffers it behind a 50 ms disambiguation deadline
   and emits the [Escape] key only once that deadline passes. A real terminal
   resolves it when the escape timeout elapses; the deterministic backend only
   drains its parser while processing a fed chunk, so a bare wake never fires
   the deadline and the Escape would stall until the next keystroke. Model the
   timeout: let the loop buffer the ESC, step virtual time past the deadline,
   then feed an empty chunk to force the drain that delivers the key. *)
let flush_pending_escape t =
  round_trip t;
  set_time t (Matrix_test.now t.backend +. 0.06);
  Matrix_test.feed t.backend "";
  wake t

let ends_with_escape bytes =
  let n = String.length bytes in
  n > 0 && Char.equal bytes.[n - 1] '\027'

let keys t bytes =
  Matrix_test.feed t.backend bytes;
  wake t;
  if ends_with_escape bytes then flush_pending_escape t

let enter t = keys t Keys.enter
let paste t text = keys t (Keys.bracketed_paste text)

let resize t ~width ~height =
  Matrix_test.resize t.backend ~width ~height;
  wake t

let screen t = Matrix_test.screen t.backend

let print t =
  Screen.print ~project:t.project (screen t);
  flush stdout

let project t = t.project

let provider t =
  match t.provider with
  | Some provider -> provider
  | None -> failwith "tui harness: no provider script was given to run"

let release t name = Provider.release (provider t) name

(* Await the [index]th request while pumping the app: the turn pipeline
   interleaves host work with messages the shell must process (and small
   cadence-gated delays), so a plain condition wait can starve it. Each round
   settles — flushing gated frames and messages — then breathes one real
   millisecond for the pipeline's own IO. Fails loudly rather than hanging. *)
let await_request t index =
  let provider = provider t in
  let rec wait rounds =
    match Provider.request provider index with
    | Some body -> body
    | None ->
        if rounds > 60_000 then
          Util.failf "tui harness: request %d never arrived" index;
        settle t;
        breathe t;
        wait (rounds + 1)
  in
  wait 0

let stop t =
  t.stopping <- true;
  Matrix_test.stop t.backend

let run ?(size = (80, 24)) ?(env = []) ?provider:script ?startup ?seed ~name f =
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
    Option.map (Provider.start ~sw ~net:(Eio.Stdenv.net stdenv)) script
  in
  let overrides =
    Project.bindings
      ?openai_base_url:(Option.map Provider.base_url provider)
      ~extra:env project
  in
  Project.apply overrides;
  let process_env = Project.env_snapshot overrides in
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
  let on_wake () = Option.iter wake !cell in
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
      last_timeout = None;
      stopping = false;
      finished = false;
      probe = None;
      project;
      provider;
    }
  in
  cell := Some t;
  let startup =
    match startup with
    | Some startup -> startup
    | None ->
        Spice_tui.Startup.make
          ~cwd:(Spice_path.Abs.of_string_exn (Project.root project))
          ()
  in
  let result = ref None in
  mark "run: launching";
  Eio.Fiber.both
    (fun () ->
      Fun.protect
        ~finally:(fun () ->
          mark "loop: finished";
          t.finished <- true;
          Eio.Condition.broadcast t.parked_cond)
        (fun () ->
          result :=
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
  match !result with
  | Some (Ok (_ : Spice_tui.outcome)) -> ()
  | Some (Error error) ->
      Util.failf "tui harness: %s" (Spice_tui.Error.message error)
  | None -> failwith "tui harness: the TUI never returned"
