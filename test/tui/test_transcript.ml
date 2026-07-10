(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The transcript grammar (doc/ui-design/01-transcript.md), re-expressed as
   full-frame goldens: the drop and a settled answer, the document block spacing,
   a borderless ocaml fence, the interrupt ladder (esc interrupts, ctrl+c arms
   quit and never interrupts), mid-stream streaming observed pre-settle, and the
   reasoning ticker settling to a titled one-liner. Completions are held on a gate
   ({!Provider_script.message} ~gate, or {!Provider_script.stream_hold} which flushes the deltas
   then holds before the terminal event) so the settled OR mid-flight frame is
   observed deterministically.

   Not here (deferred): /thinking hides+restores reasoning (three reasoning
   turns), ctrl+o pinning the ticker open, committed output-token counts. Provider
   failure notices live in test_turn_errors (suite-coverage). The ctrl+c-exits-
   mid-interrupt goodbye frame is pty-only (printed after the alt-screen closes). *)

(* Submit a prompt, sync on the request the turn sends, release the held final,
   and drive to the settled frame. {!Tui.release} waits for the unblocked
   response to reach the loop (see the harness), so a bare settle then settles
   the completion rather than racing the socket read — no time advance needed. *)
let run_turn t prompt =
  Tui.keys t prompt;
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t

(* The drop then a settled answer: submitting drops into chat — the compact
   banner record at the top, the user message echoed, the composer above the
   footer — and the model's answer settles as a muted [⏺] assistant block. The
   working line is gone once the turn settles. *)
let%expect_test "the drop and a settled answer" =
  let script =
    [
      Provider_script.message ~expect:[ "retry" ] ~gate:"fin" ~id:"resp-1"
        "The retry logic backs off exponentially.";
    ]
  in
  Tui.run ~name:"transcript-drop" ~provider:script @@ fun t ->
  Tui.settle t;
  run_turn t "explain the retry logic";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ explain the retry logic
07 |
08 | ⏺ The retry logic backs off exponentially.
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

(* The document grammar spaces top-level blocks: a heading, then two paragraphs,
   each separated by a blank line under the [⏺] assistant block. *)
let%expect_test "the document grammar spaces top-level blocks" =
  let answer =
    "## Retry design\n\n\
     The client backs off exponentially between attempts.\n\n\
     Each failure doubles the delay until it reaches the ceiling."
  in
  let script =
    [
      Provider_script.message ~expect:[ "design" ] ~gate:"fin" ~id:"resp-1"
        answer;
    ]
  in
  Tui.run ~name:"transcript-blocks" ~provider:script @@ fun t ->
  Tui.settle t;
  run_turn t "describe the retry design";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ describe the retry design
07 |
08 | ⏺ Retry design
09 |
10 |   The client backs off exponentially between attempts.
11 |
12 |   Each failure doubles the delay until it reaches the ceiling.
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}]

(* An ocaml fence renders borderless: the code text is on screen with no fence
   markers and no box/gutter characters around it. *)
let%expect_test "an ocaml fence renders borderless code" =
  let answer =
    "Here is the helper:\n\n\
     ```ocaml\n\
     let add x y = x + y\n\
     ```\n\n\
     Call it with two ints."
  in
  let script =
    [
      Provider_script.message ~expect:[ "helper" ] ~gate:"fin" ~id:"resp-1"
        answer;
    ]
  in
  Tui.run ~name:"transcript-fence" ~provider:script @@ fun t ->
  Tui.settle t;
  run_turn t "show me the helper";
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ show me the helper
07 |
08 | ⏺ Here is the helper:
09 |
10 |   let add x y = x + y
11 |
12 |   Call it with two ints.
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* Esc while a turn is in flight is the interrupt ladder: the first press arms the
   "Press Esc again to interrupt" footer notice; the second fires the cooperative
   interrupt, and the working line advertises [⠙ Interrupting… (esc again to
   force)]; a third esc forces it and the reducer settles a single
   [◌ Interrupted] notice.

   This test specifically exercises the FORCE path: the completion is held on a
   gate that is never released, so the turn's HTTP read blocks on the gate and the
   cooperative interrupt can never yield to complete on its own — the third-esc
   FORCE is what settles it. The held gate is the harness making the race space
   explicit; a real provider that eventually responds would let the cooperative
   interrupt settle on the second esc. Off this held gate, folding the old
   "esc interrupts" (183) and "advertises and forces" (218) into one ladder is
   the honest rendering. The answer never renders. *)
let%expect_test "esc interrupts an in-flight turn, forcing on the third press" =
  let script =
    [
      Provider_script.message ~expect:[ "wait" ] ~gate:"held" ~id:"resp-1"
        "This answer should never render.";
    ]
  in
  Tui.run ~name:"transcript-interrupt" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "wait for me";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  (* First esc arms the interrupt. *)
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ wait for me
07 |
08 | ⠋ Working… (0s · esc to interrupt)
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   Press Esc again to interrupt|}];
  (* Second esc fires the cooperative interrupt; the drain advertises the force. *)
  Tui.keys t Key.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ wait for me
07 |
08 | ⠙ Interrupting… (esc again to force)
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  (* Third esc forces it. The main-session check remains pending until the
     interrupted turn reaches its terminal event, even though the provider gate
     itself remains held. *)
  Tui.keys t Key.escape;
  Tui.settle_turn t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ wait for me
07 |
08 | ◌ Interrupted — tell spice what to do differently.
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* Ctrl+C is the quit chord, never an interrupt: pressed while a turn is in
   flight it arms "Press Ctrl+C again to exit" — never the esc interrupt notice —
   and the turn keeps running to its real answer once released. *)
let%expect_test "ctrl+c while a turn runs arms quit and never interrupts" =
  let script =
    [
      Provider_script.message ~expect:[ "keep" ] ~gate:"fin" ~id:"resp-1"
        "The turn finished despite the ctrl+c.";
    ]
  in
  Tui.run ~name:"transcript-ctrlc" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "keep going";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  Tui.keys t Key.ctrl_c;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ keep going
07 |
08 | ⠋ Working… (0s · esc to interrupt)
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   Press Ctrl+C again to exit|}];
  (* The chord armed; releasing lets the turn stream to its settled answer.
     [release] waits for the response to reach the loop, so a bare settle then
     settles it. *)
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ keep going
07 |
08 | ⏺ The turn finished despite the ctrl+c.
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   Press Ctrl+C again to exit|}]

(* Streaming reaches the screen before the turn settles: with the terminal event
   held by a stream gate, the streamed text and the working line are both on
   screen while the turn is in flight, and the same text stands as a settled [⏺]
   block once released. Settled == streamed: the mid-stream text and the settled
   block carry the identical string. *)
let%expect_test "streaming is observed before the turn settles" =
  let answer = "Streaming reaches the screen before settle." in
  let script =
    [
      Provider_script.stream_hold ~expect:[ "stream" ] ~gate:"held" ~id:"resp-1"
        answer;
    ]
  in
  Tui.run ~name:"transcript-stream" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "stream the answer";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  (* Mid-stream: the streamed text is on screen AND the working line is up. *)
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ stream the answer
07 |
08 | ⏺ Streaming reaches the screen before settle.
09 |
10 | ⠋ Working… (0s · esc to interrupt)
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}];
  Tui.release t "held";
  (* [release] waits for the terminal event to reach the loop even though it is
     the only thing a hold_stream sends after release, so a bare settle then
     settles it — no time advance needed. *)
  Tui.settle t;
  (* Settled: the same text, now a [⏺] block, working line gone. *)
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ stream the answer
07 |
08 | ⏺ Streaming reaches the screen before settle.
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗     ? for shortcuts|}]

(* Reasoning streams a ticker mid-turn and settles to a titled one-liner: the
   [∴ Thinking] ticker header is on screen while the turn runs (reasoning deltas
   flushed, terminal held), then the block collapses to [∴ Thought for Ns ·
   <title>] with the title taken from the thought's leading [**bold**] line.
   Elapsed is virtual, frozen at 0s since the test advances no time. *)
let%expect_test "reasoning streams a ticker then settles to a titled one-liner"
    =
  let summary =
    "**Backoff plan**\n\
     The user asks how retries space out, so I walk the exponential schedule."
  in
  let answer = "Retries back off exponentially." in
  let script =
    [
      Provider_script.stream_hold ~expect:[ "retries" ] ~gate:"held"
        ~reasoning:summary ~id:"resp-1" answer;
    ]
  in
  Tui.run ~name:"transcript-reasoning" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "how do retries space out";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  (* Mid-stream: the thinking ticker is up. *)
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ how do retries space out
07 |
08 | ∴ Thinking
09 |
10 |   **Backoff plan**
11 |   The user asks how retries space out, so I walk the exponential schedule.
12 |
13 | ⏺ Retries back off exponentially.
14 |
15 | ⠋ Working… (0s · esc to interrupt)
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.release t "held";
  (* [release] waits for the terminal event to reach the loop; a bare settle then
     settles it. Time never moves, so the thought's elapsed stays "0s". *)
  Tui.settle t;
  (* Settled: the titled thought one-liner and the answer; ticker gone. *)
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ how do retries space out
07 |
08 | ∴ Thought for 0s · Backoff plan  (ctrl+o)
09 |
10 | ⏺ Retries back off exponentially.
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

let overflow_answer =
  String.concat "\n\n"
    [
      "Retries begin at the base delay.";
      "The delay doubles on each failure.";
      "A jitter term spreads the retries apart.";
      "The ceiling caps the longest wait.";
      "Idempotent requests retry safely.";
      "Non-idempotent ones need an idempotency key.";
      "The budget bounds the total attempts.";
      "Giving up surfaces the last error.";
      "Metrics record every retry attempt.";
      "Backpressure slows the caller down.";
      "Circuit breakers trip on sustained failure.";
      "The final word is to cap the ceiling.";
    ]

let page_up = "\027[5~"
let page_down = "\027[6~"
let wheel_up ~col ~row = Printf.sprintf "\027[<64;%d;%dM" col row

(* An overflowing settled transcript pins its tail without a scrollbar. Paging
   and a wheel event over the composer both reveal earlier content, and paging
   down returns to the sticky tail. *)
let%expect_test "overflow paging and wheel scrolling preserve the transcript" =
  let script =
    [
      Provider_script.message ~expect:[ "overflow" ] ~gate:"fin"
        ~id:"resp-overflow" overflow_answer;
    ]
  in
  Tui.run ~name:"transcript-overflow" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "overflow the viewport";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |   A jitter term spreads the retries apart.
02 |
03 |   The ceiling caps the longest wait.
04 |
05 |   Idempotent requests retry safely.
06 |
07 |   Non-idempotent ones need an idempotency key.
08 |
09 |   The budget bounds the total attempts.
10 |
11 |   Giving up surfaces the last error.
12 |
13 |   Metrics record every retry attempt.
14 |
15 |   Backpressure slows the caller down.
16 |
17 |   Circuit breakers trip on sustained failure.
18 |
19 |   The final word is to cap the ceiling.
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}];
  Tui.keys t page_up;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ overflow the viewport
07 |
08 | ⏺ Retries begin at the base delay.
09 |
10 |   The delay doubles on each failure.
11 |
12 |   A jitter term spreads the retries apart.
13 |
14 |   The ceiling caps the longest wait.
15 |
16 |   Idempotent requests retry safely.
17 |
18 |   Non-idempotent ones need an idempotency key.
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}];
  Tui.keys t page_down;
  Tui.settle t;
  Tui.keys t (wheel_up ~col:10 ~row:22);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |   The delay doubles on each failure.
03 |
04 |   A jitter term spreads the retries apart.
05 |
06 |   The ceiling caps the longest wait.
07 |
08 |   Idempotent requests retry safely.
09 |
10 |   Non-idempotent ones need an idempotency key.
11 |
12 |   The budget bounds the total attempts.
13 |
14 |   Giving up surfaces the last error.
15 |
16 |   Metrics record every retry attempt.
17 |
18 |   Backpressure slows the caller down.
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

(* Ctrl+O expands the complete streamed reasoning buffer while the terminal
   event is held, including a leading line outside the normal three-line ticker. *)
let%expect_test "ctrl+o pins the streamed reasoning ticker open" =
  let reasoning =
    "ALPHA leading marker line\n\
     second thought\n\
     third thought\n\
     fourth thought\n\
     fifth thought\n\
     omega trailing marker line"
  in
  let script =
    [
      Provider_script.stream_hold ~expect:[ "space out" ] ~reasoning ~gate:"fin"
        ~id:"resp-reasoning-pin" "Retries back off exponentially.";
    ]
  in
  Tui.run ~name:"transcript-reasoning-pin" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "how do retries space out";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ how do retries space out
07 |
08 | ∴ Thinking
09 |   fourth thought
10 |   fifth thought
11 |   omega trailing marker line
12 |
13 | ⏺ Retries back off exponentially.
14 |
15 | ⠋ Working… (0s · esc to interrupt)
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.keys t Key.ctrl_o;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ how do retries space out
07 |
08 | ∴ Thinking
09 |   ALPHA leading marker line
10 |   second thought
11 |   third thought
12 |   fourth thought
13 |   fifth thought
14 |   omega trailing marker line
15 |
16 | ⏺ Retries back off exponentially.
17 |
18 | ⠋ Working… (0s · esc to interrupt)
19 |
20 |   ◎ verbose ctrl+o closes
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.release t "fin";
  Tui.settle t

(* Usage committed by one tool-call step is rendered on the following held
   step's working line, then disappears with that line at settle. *)
let%expect_test "the working line shows committed output tokens" =
  let script =
    [
      Provider_script.tool_call ~expect:[ "read the notes" ] ~output_tokens:3100
        ~id:"resp-token-read" ~call_id:"call-token-read" ~name:"read_file"
        ~arguments:{|{"path":"notes.txt"}|} ();
      Provider_script.stream_hold ~expect:[ "function_call_output" ] ~gate:"fin"
        ~id:"resp-token-answer" "The notes describe exponential backoff.";
    ]
  in
  Tui.run ~name:"transcript-output-tokens" ~provider:script
    ~seed:(fun project ->
      Project.write project "notes.txt" "retry notes: backoff doubles")
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "read the notes";
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ read the notes
07 |
08 | ⏺ Read(notes.txt)
09 |   ⎿  Read 1 line ▸
10 |
11 | ⏺ The notes describe exponential backoff.
12 |
13 | ⠋ Working… (0s · ↓ 3.1k tokens · esc to interrupt)
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ read the notes
07 |
08 | ⏺ Read(notes.txt)
09 |   ⎿  Read 1 line ▸
10 |
11 | ⏺ The notes describe exponential backoff.
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* /thinking drops new reasoning blocks at fold time while disabled and restores
   both the live ticker and settled thought once re-enabled. *)
let%expect_test "thinking visibility hides reasoning and restores it" =
  let script =
    [
      Provider_script.message ~expect:[ "start the session" ]
        ~id:"resp-thinking-1" "Ready when you are.";
      Provider_script.stream_hold ~expect:[ "reason while off" ]
        ~reasoning:"**Hidden plan**\nThis must not render." ~gate:"hidden"
        ~id:"resp-thinking-2" "Answered while reasoning was hidden.";
      Provider_script.stream_hold ~expect:[ "reason while on" ]
        ~reasoning:"**Shown plan**\nThis must render." ~gate:"shown"
        ~id:"resp-thinking-3" "Answered while reasoning was shown.";
    ]
  in
  Tui.run ~name:"thinking-toggle" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "start the session";
  Tui.settle t;
  Tui.enter t;
  ignore (Tui.await_turn t 1 : string);
  Tui.keys t "/thinking";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "reason while off";
  Tui.settle t;
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ start the session
07 |
08 | ⏺ Ready when you are.
09 |
10 | ❯ /thinking
11 |
12 |   thinking hidden — reasoning stays in the session, not on screen
13 |
14 | ❯ reason while off
15 |
16 | ⏺ Answered while reasoning was hidden.
17 |
18 | ⠋ Working… (0s · esc to interrupt)
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}];
  Tui.release t "hidden";
  Tui.settle t;
  Tui.keys t "/thinking";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "reason while on";
  Tui.settle t;
  Tui.enter t;
  ignore (Tui.await_request t 3 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 | ❯ reason while off
03 |
04 | ⏺ Answered while reasoning was hidden.
05 |
06 | ❯ /thinking
07 |
08 |   thinking shown — reasoning returns to the transcript
09 |
10 | ❯ reason while on
11 |
12 | ∴ Thinking
13 |
14 |   **Shown plan**
15 |   This must render.
16 |
17 | ⏺ Answered while reasoning was shown.
18 |
19 | ⠋ Working… (0s · esc to interrupt)
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ queue a message — sends after this turn
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}];
  Tui.release t "shown";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 | ⏺ Ready when you are.
02 |
03 | ❯ /thinking
04 |
05 |   thinking hidden — reasoning stays in the session, not on screen
06 |
07 | ❯ reason while off
08 |
09 | ⏺ Answered while reasoning was hidden.
10 |
11 | ❯ /thinking
12 |
13 |   thinking shown — reasoning returns to the transcript
14 |
15 | ❯ reason while on
16 |
17 | ∴ Thought for 0s · Shown plan  (ctrl+o)
18 |
19 | ⏺ Answered while reasoning was shown.
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

[%%run_tests "spice.tui.transcript"]
