(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] transcript and turn loop
   (doc/ui-design/01-transcript.md, doc/plans/tui-next-transcript.md). Unlike the
   home stage these run a real turn, so they drive the fake provider: the tests
   type a prompt, send Enter as a separate write (an atomic ["text\r"] write is
   swallowed), and golden the streamed and settled screen.

   SPICE_REDUCED_MOTION=1 settles the lockup so the pre-drop screen is stable;
   after the drop the transcript owns the screen. The harness pins
   SPICE_SANDBOX_MODE=danger-full-access, which the compact banner record shows
   as a hanging sandbox line. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

(* The 1-based screen row a needle first lands on, or 0 when it is absent. The
   screen is the raw VTE dump, its rows joined by newlines; tests use it to
   assert one block's vertical position relative to another. *)
let row_of needle screen =
  let rec find i = function
    | [] -> 0
    | line :: rest -> if Util.contains line needle then i else find (i + 1) rest
  in
  find 1 (String.split_on_char '\n' screen)

(* The text of the 1-based screen row [n], or [""] past the last row. *)
let row_text n screen =
  match List.nth_opt (String.split_on_char '\n' screen) (n - 1) with
  | Some line -> line
  | None -> ""

let run ?env ?rows ?cols ?provider project f =
  Term.run ?env ?rows ?cols ?provider project f

let json_strings texts =
  String.concat "," (List.map (Printf.sprintf "%S") texts)

(* A completed Responses payload the server streams with a hold: the visible
   deltas flush, then [stream_delay_ms] pauses before the terminal
   [response.completed] (the fake provider's [stream_delay_ms] knob). During the
   hold the streamed-but-unsettled document is on screen — the working line and
   the streaming text — so a test can observe streaming before the blocks
   settle. Answers stay ASCII: [%S] escapes non-ASCII bytes into forms that are
   not valid JSON. *)
let streaming_line ~id ~body_contains ~stream_delay_ms ~answer =
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"stream_delay_ms":%d,"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":%S}]}]}}|}
    (json_strings body_contains)
    stream_delay_ms id answer

(* {!streaming_line} with a reasoning summary item ahead of the assistant
   message: the ticker streams while the turn is in flight and the block settles
   to the [∴ Thought for] one-liner. *)
let reasoning_line ~id ~body_contains ~stream_delay_ms ~summary ~answer =
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"stream_delay_ms":%d,"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":%S}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":%S}]}]}}|}
    (json_strings body_contains)
    stream_delay_ms id summary answer

(* An HTTP error reply: the provider fails the turn before any document block is
   produced, so the drain settles a failure the frontend folds into the [✗]
   notice. Status 400 (Invalid_request) is not retried, so exactly one request
   fails. *)
let error_line ~status ~message =
  Printf.sprintf {|{"http":{"status":%d,"json":{"error":{"message":%S}}}}|}
    status message

(* A turn that asks a host question: the model returns an [ask_user]
   function_call with no assistant text, so the host suspends the turn on the
   durable host-tool call and the drain settles Waiting (live-questions.t). The
   [arguments] field is a JSON string, so the question object is stringified. *)
let question_line ~id ~call_id ~body_contains ~question =
  let arguments = Printf.sprintf {|{"question":%S}|} question in
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-question","call_id":%S,"name":"ask_user","arguments":%S}]}}|}
    (json_strings body_contains)
    id call_id arguments

(* A model step that reads a file and reports [output_tokens] of usage on its
   terminal event. [read_file] is a Read op the Default posture auto-allows
   (permission.ml), so it runs without a prompt; the real adapter parses the
   [usage] member of [response.completed] into a live [Usage_updated], and the
   step's durable [Assistant] folds it into the turn's committed output spend.
   Pairs with a held follow-up step so the working line can be caught rendering
   [↓ N tokens] from the settled step's spend. *)
let read_usage_line ~id ~body_contains ~path ~output_tokens =
  let arguments = Printf.sprintf {|{"path":%S}|} path in
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]},"response":{"id":%S,"status":"completed","model":"gpt-5.5","usage":{"input_tokens":7,"output_tokens":%d},"output":[{"type":"function_call","id":"item-read-usage","call_id":"call-read-usage","name":"read_file","arguments":%S}]}}|}
    (json_strings body_contains)
    id output_tokens arguments

(* The drop then a settled answer: submitting drops into chat — the compact
   banner record at the top, the user message echoed, the composer at the bottom
   above the unmoved footer — and the model's answer settles as a muted [⏺]
   assistant block. The working line is gone once the turn settles. *)
let%expect_test "the drop and a settled answer" =
  Project.with_temp "next-drop" @@ fun project ->
  let answer = "The retry logic backs off exponentially." in
  Provider.with_openai project ~answer ~body_contains:[ "retry" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "explain the retry logic";
  Term.wait t (Screen.has "❯ explain the retry logic");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has answer s && Screen.has "? for shortcuts" s);
  print_fact "banner record at top" (Screen.has "spice" (Term.screen t));
  print_fact "user block"
    (Screen.has "❯ explain the retry logic" (Term.screen t));
  print_fact "assistant answer settled" (Screen.has answer (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|banner record at top: true
user block: true
assistant answer settled: true
01 | ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
02 | ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
03 |       sandbox: danger-full-access (config)
04 | ❯ explain the retry logic
05 |
06 | ⏺ The retry logic backs off exponentially.
07 |
08 |
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

(* The working line is present while the turn is in flight and gone once it
   settles. A server-side delay holds the model request open long enough to
   observe [⠹ Working… (…s · esc to interrupt)]. *)
let%expect_test "working line while a turn is in flight" =
  Project.with_temp "next-working" @@ fun project ->
  let answer = "Done thinking about it." in
  let line =
    Provider.delayed_response_line ~delay_ms:2500 ~id:"resp-next-working"
      ~body_contains:[ "ponder" ] ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "ponder this";
  Term.wait t (Screen.has "❯ ponder this");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  print_fact "working line present"
    (Screen.has "esc to interrupt" (Term.screen t));
  print_fact "verb is Working" (Screen.has "Working" (Term.screen t));
  Term.wait t (Screen.has answer);
  print_fact "answer settled" (Screen.has answer (Term.screen t));
  print_fact "working line gone"
    (not (Screen.has "esc to interrupt" (Term.screen t)));
  [%expect
    {|
    working line present: true
    verb is Working: true
    answer settled: true
    working line gone: true|}]

(* Esc while a turn streams is the two-stage interrupt (03-composer.md
   §Keybindings): the first press arms the "press again" footer notice, the
   second fires — the drain settles Interrupted and the reducer folds a single
   [◌ Interrupted] notice. *)
let%expect_test "esc interrupts an in-flight turn" =
  Project.with_temp "next-interrupt" @@ fun project ->
  let answer = "This answer should never render." in
  let line =
    Provider.delayed_response_line ~delay_ms:4000 ~id:"resp-next-interrupt"
      ~body_contains:[ "wait" ] ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "wait for me";
  Term.wait t (Screen.has "❯ wait for me");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Press Esc again to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Interrupted");
  print_fact "interrupt notice is the exact spec line"
    (Screen.has "◌ Interrupted — tell spice what to do differently."
       (Term.screen t));
  print_fact "answer never rendered" (not (Screen.has answer (Term.screen t)));
  [%expect
    {|
    interrupt notice is the exact spec line: true
    answer never rendered: true|}]

(* A second esc while the turn is already draining FORCES the interrupt
   (01-transcript.md §The working line, app.ml esc ladder): once the cooperative
   interrupt fires, the working line advertises [⠹ Interrupting… (esc again to
   force)]; a further esc escalates to {!Spice_host.Live.force_interrupt} and the
   turn settles [◌ Interrupted]. This drives a stream-hold fixture, so the
   cooperative interrupt is itself cancellable — the test pins the force
   AFFORDANCE and settle, not a genuinely lagging drain (that needs an
   uncancellable systhread tool wait). *)
let%expect_test "a second esc while interrupting advertises and forces" =
  Project.with_temp "next-force" @@ fun project ->
  let answer = "This answer should never render." in
  let line =
    Provider.delayed_response_line ~delay_ms:8000 ~id:"resp-next-force"
      ~body_contains:[ "force" ] ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "force this turn";
  Term.wait t (Screen.has "❯ force this turn");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Press Esc again to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "esc again to force");
  print_fact "drain advertises the force affordance"
    (Screen.has "Interrupting" (Term.screen t)
    && Screen.has "esc again to force" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Interrupted");
  print_fact "force settles the turn Interrupted"
    (Screen.has "◌ Interrupted — tell spice what to do differently."
       (Term.screen t));
  print_fact "answer never rendered" (not (Screen.has answer (Term.screen t)));
  [%expect
    {|
    drain advertises the force affordance: true
    force settles the turn Interrupted: true
    answer never rendered: true|}]

(* Ctrl+C is the quit chord, never an interrupt (app.ml [Ctrl_c]): pressed while
   a turn streams it arms "Press Ctrl+C again to exit" — never the esc interrupt
   notice — and the turn keeps streaming to its real answer, since Ctrl+C never
   cancels a turn. This is the routing the user hit live: Ctrl+C must not be
   swallowed by the interrupt affordance. *)
let%expect_test "ctrl+c while a turn streams arms quit and never interrupts" =
  Project.with_temp "next-ctrlc-stream" @@ fun project ->
  let answer = "The turn finished despite the ctrl+c." in
  let line =
    Provider.delayed_response_line ~delay_ms:2500 ~id:"resp-next-ctrlc"
      ~body_contains:[ "keep" ] ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "keep going";
  Term.wait t (Screen.has "❯ keep going");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t Keys.ctrl_c;
  Term.wait t (Screen.has "Press Ctrl+C again to exit");
  print_fact "ctrl+c armed the quit chord"
    (Screen.has "Press Ctrl+C again to exit" (Term.screen t));
  print_fact "ctrl+c did not arm the interrupt"
    (Screen.lacks "again to interrupt" (Term.screen t));
  Term.wait t (Screen.has answer);
  print_fact "turn streamed to its answer" (Screen.has answer (Term.screen t));
  [%expect
    {|
    ctrl+c armed the quit chord: true
    ctrl+c did not arm the interrupt: true
    turn streamed to its answer: true|}]

(* The live bug: stuck on the [⠹ Interrupting…] drain, the user pressed Ctrl+C to
   LEAVE and could not, because Ctrl+C was conflated with interrupt. Now the quit
   chord works in every turn state — after esc fires the interrupt, Ctrl+C twice
   exits to the goodbye. Before the fix, Ctrl+C here re-armed the interrupt and
   never reached [Quit]. *)
let%expect_test "ctrl+c leaves the app while a turn is interrupting" =
  Project.with_temp "next-ctrlc-interrupting" @@ fun project ->
  let answer = "This answer should never render." in
  let line =
    Provider.delayed_response_line ~delay_ms:8000 ~id:"resp-next-ctrlc-int"
      ~body_contains:[ "hang" ] ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "hang for a while";
  Term.wait t (Screen.has "❯ hang for a while");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Press Esc again to interrupt");
  Term.send t Keys.escape;
  (* The interrupt has fired; the turn is draining (or just settled). The quit
     chord must reach [Quit] regardless. *)
  Term.send t Keys.ctrl_c;
  Term.wait t (Screen.has "Press Ctrl+C again to exit");
  print_fact "ctrl+c armed the quit chord mid-interrupt"
    (Screen.has "Press Ctrl+C again to exit" (Term.screen t));
  Term.send t Keys.ctrl_c;
  Term.wait_exit t;
  print_fact "app exited" (Term.exited t);
  print_fact "goodbye lockup printed"
    (Screen.has "▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂" (Term.screen t));
  [%expect
    {|
    ctrl+c armed the quit chord mid-interrupt: true
    app exited: true
    goodbye lockup printed: true|}]

(* Interrupting a turn that settled Waiting on a host question does not wedge the
   conversation: the model's [ask_user] call leaves the turn suspended on the
   working line [⋯ Waiting for your answer]; esc settles it Interrupted (the
   suspended host-tool call is answered with an interrupted result under the
   hood, spice_session.ml), and the next prompt runs a fresh turn that completes.
   Before the session-layer fix the second submit failed with "assistant tool
   calls are missing tool results", so this pins the regression end-to-end. *)
let%expect_test
    "interrupting a waiting question then submitting again completes" =
  Project.with_temp "next-wedge" @@ fun project ->
  let answer = "Summarizing the deploy options instead." in
  let question =
    question_line ~id:"resp-next-wedge-q" ~call_id:"question-1"
      ~body_contains:[ "deploy" ] ~question:"Which environment should I target?"
  in
  let final =
    Provider.response_line ~id:"resp-next-wedge-final"
      ~body_contains:[ "summarize" ] ~body_not_contains:[] ~answer
  in
  Provider.with_responses project [ question; final ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "help me deploy the app";
  Term.wait t (Screen.has "❯ help me deploy the app");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Waiting for your answer");
  print_fact "waiting working line"
    (Screen.has "⋯ Waiting for your answer" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Press Esc again to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Interrupted");
  print_fact "interrupt notice is the exact spec line"
    (Screen.has "◌ Interrupted — tell spice what to do differently."
       (Term.screen t));
  Term.send t "never mind, just summarize";
  Term.wait t (Screen.has "❯ never mind, just summarize");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has answer s && Screen.has "? for shortcuts" s);
  print_fact "second turn completed" (Screen.has answer (Term.screen t));
  print_fact "no missing-tool-results failure"
    (Screen.lacks "missing tool results" (Term.screen t));
  [%expect
    {|
    waiting working line: true
    interrupt notice is the exact spec line: true
    second turn completed: true
    no missing-tool-results failure: true|}]

(* Streaming reaches the screen before the turn settles: with the terminal event
   held, the working line and the streamed text are both on screen while the
   turn is in flight, and the same text stands as a settled [⏺] block once the
   hold ends. Settled == streamed (01-transcript.md §Purpose): the mid-stream
   text and the settled block carry the identical string. *)
let%expect_test "streaming is observed before the turn settles" =
  Project.with_temp "next-stream" @@ fun project ->
  let answer = "Streaming reaches the screen before settle." in
  let line =
    streaming_line ~id:"resp-next-stream" ~body_contains:[ "stream" ]
      ~stream_delay_ms:2500 ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "stream the answer";
  Term.wait t (Screen.has "❯ stream the answer");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has "esc to interrupt" s && Screen.has answer s);
  print_fact "working line present mid-stream"
    (Screen.has "esc to interrupt" (Term.screen t));
  print_fact "streamed text visible before settle"
    (Screen.has answer (Term.screen t));
  Term.wait t (fun s -> not (Screen.has "esc to interrupt" s));
  print_fact "working line gone after settle"
    (not (Screen.has "esc to interrupt" (Term.screen t)));
  print_fact "settled text equals streamed" (Screen.has answer (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|working line present mid-stream: true
streamed text visible before settle: true
working line gone after settle: true
settled text equals streamed: true
01 | ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
02 | ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
03 |       sandbox: danger-full-access (config)
04 | ❯ stream the answer
05 |
06 | ⏺ Streaming reaches the screen before settle.
07 |
08 |
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
24 |   …/tmp/spice-tui-next-stream · gpt-5.5 medium · dune: ✗       ? for shortcuts|}]

(* Reasoning streams the ticker mid-turn and settles to the titled one-liner:
   the [∴ Thinking] ticker header is on screen while the turn runs, then the
   block collapses to [∴ Thought for Ns · <title>] with the title taken from the
   thought's leading [**bold**] line (01-transcript.md §Reasoning). The elapsed
   seconds are wall-clock, so this asserts the durable facts rather than
   goldening the line. *)
let%expect_test "reasoning streams a ticker and settles to a titled one-liner" =
  Project.with_temp "next-reasoning" @@ fun project ->
  let summary =
    "**Backoff plan**\n\
     The user asks how retries space out, so I walk the exponential schedule."
  in
  let answer = "Retries back off exponentially." in
  let line =
    reasoning_line ~id:"resp-next-reasoning" ~body_contains:[ "retries" ]
      ~stream_delay_ms:2500 ~summary ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "how do retries space out";
  Term.wait t (Screen.has "❯ how do retries space out");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "∴ Thinking");
  print_fact "ticker header mid-stream"
    (Screen.has "∴ Thinking" (Term.screen t));
  Term.wait t (fun s -> not (Screen.has "esc to interrupt" s));
  print_fact "settled thought one-liner"
    (Screen.has "∴ Thought for" (Term.screen t));
  print_fact "title from the bold lead"
    (Screen.has "Backoff plan" (Term.screen t));
  print_fact "ticker header gone after settle"
    (not (Screen.has "∴ Thinking" (Term.screen t)));
  print_fact "answer settled" (Screen.has answer (Term.screen t));
  [%expect
    {|ticker header mid-stream: true
settled thought one-liner: true
title from the bold lead: true
ticker header gone after settle: true
answer settled: true|}]

(* The document grammar spaces its top-level blocks: exactly one blank line
   between the user block and the assistant block, none before the first block
   (01-transcript.md §Base grammar). The user block is keyed by [❯] on the user
   background (the background is a color the VTE dump cannot assert), the
   assistant block by a muted [⏺]. *)
let%expect_test "the document grammar spaces top-level blocks" =
  Project.with_temp "next-blocks" @@ fun project ->
  let answer =
    "## Retry design\n\n\
     The client backs off exponentially between attempts.\n\n\
     Each failure doubles the delay until it reaches the ceiling."
  in
  Provider.with_openai project ~answer ~body_contains:[ "design" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "describe the retry design";
  Term.wait t (Screen.has "❯ describe the retry design");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "Retry design" s && Screen.has "? for shortcuts" s);
  print_fact "user block keyed by cursor"
    (Screen.has "❯ describe the retry design" (Term.screen t));
  print_fact "assistant block keyed by a dot" (Screen.has "⏺" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|user block keyed by cursor: true
assistant block keyed by a dot: true
01 | ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
02 | ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
03 |       sandbox: danger-full-access (config)
04 | ❯ describe the retry design
05 |
06 | ⏺ Retry design
07 |
08 |   The client backs off exponentially between attempts.
09 |
10 |   Each failure doubles the delay until it reaches the ceiling.
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
24 |   …/tmp/spice-tui-next-blocks · gpt-5.5 medium · dune: ✗       ? for shortcuts|}]

(* A provider failure settles the failure notice: the [✗] error line carries the
   provider message and a muted next-step line, and no assistant block is
   produced (01-transcript.md §Notices, failure class). *)
let%expect_test "a provider failure settles a failure notice" =
  Project.with_temp "next-failure" @@ fun project ->
  let line =
    error_line ~status:400 ~message:"the model provider rejected the request"
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "trigger the failure";
  Term.wait t (Screen.has "❯ trigger the failure");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Tell spice how to proceed.");
  print_fact "failure glyph" (Screen.has "✗" (Term.screen t));
  print_fact "provider message shown"
    (Screen.has "rejected the request" (Term.screen t));
  print_fact "muted next-step line"
    (Screen.has "Tell spice how to proceed." (Term.screen t));
  print_fact "no assistant block" (Screen.lacks "⏺" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|failure glyph: true
provider message shown: true
muted next-step line: true
no assistant block: true
01 | ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
02 | ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
03 |       sandbox: danger-full-access (config)
04 | ❯ trigger the failure
05 |
06 | ✗ the model provider rejected the request
07 |   Tell spice how to proceed.
08 |
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
24 |   …/tmp/spice-tui-next-failure · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* An ocaml fence renders borderless: the code text is on screen with no fence
   markers and no box/gutter characters around it (01-transcript.md §Code fences:
   "No border, background, or gutter on fences"). The subdued syntax colors are
   not assertable in the VTE dump, so this pins content and the absence of
   borders. *)
let%expect_test "an ocaml fence renders borderless code" =
  Project.with_temp "next-fence" @@ fun project ->
  let answer =
    "Here is the helper:\n\n\
     ```ocaml\n\
     let add x y = x + y\n\
     ```\n\n\
     Call it with two ints."
  in
  Provider.with_openai project ~answer ~body_contains:[ "helper" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "show me the helper";
  Term.wait t (Screen.has "❯ show me the helper");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "let add x y = x + y" s && Screen.has "? for shortcuts" s);
  print_fact "code text renders"
    (Screen.has "let add x y = x + y" (Term.screen t));
  print_fact "no vertical border" (Screen.lacks "│" (Term.screen t));
  print_fact "no fence markers" (Screen.lacks "```" (Term.screen t));
  Screen.print ~project (Term.screen t);
  [%expect
    {|code text renders: true
no vertical border: true
no fence markers: true
01 | ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
02 | ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
03 |       sandbox: danger-full-access (config)
04 | ❯ show me the helper
05 |
06 | ⏺ Here is the helper:
07 |
08 |   let add x y = x + y
09 |
10 |   Call it with two ints.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗ ? for shortcuts|}]

(* The banner record scrolls away with the document (04-header-footer.md
   §Purpose): it is the transcript's first block, not sticky chrome, so a
   conversation that overflows the viewport pushes the lockup and its hanging
   sandbox line off the top while the settled tail stays pinned to the bottom.
   The many-paragraph answer overflows the 24-row screen; the assertions read the
   final settled frame. *)
let%expect_test "the banner record scrolls away as the conversation overflows" =
  Project.with_temp "next-scroll" @@ fun project ->
  let answer =
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
  in
  Provider.with_openai project ~answer ~body_contains:[ "overflow" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "overflow the viewport";
  Term.wait t (Screen.has "❯ overflow the viewport");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "cap the ceiling" s && Screen.has "? for shortcuts" s);
  print_fact "last paragraph settled at the tail"
    (Screen.has "The final word is to cap the ceiling." (Term.screen t));
  print_fact "banner lockup scrolled off the top"
    (Screen.lacks "▄▀▀" (Term.screen t));
  print_fact "banner sandbox line scrolled off"
    (Screen.lacks "sandbox: danger-full-access" (Term.screen t));
  [%expect
    {|
    last paragraph settled at the tail: true
    banner lockup scrolled off the top: true
    banner sandbox line scrolled off: true|}]

(* The working line flows with the live tail inside the scrollport
   (01-transcript.md §The working line): it is a flowing part of the tail, one
   base-grammar blank below the streaming assistant text, not a chrome row glued
   straight under it. With a short streamed answer held mid-turn the tail
   bottom-pins in the scrollport, so [answer_row + 2] locates the working line —
   one blank below the tail — while the row between them is blank. A working line
   pinned as a sibling would sit one row below the tail with no blank, so the
   [+2] gap is the discriminator that it flows rather than being pinned. *)
let%expect_test "the working line flows directly after the tail" =
  Project.with_temp "next-working-flow" @@ fun project ->
  let answer = "Pondering the plan." in
  let line =
    streaming_line ~id:"resp-next-working-flow" ~body_contains:[ "flow" ]
      ~stream_delay_ms:2500 ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "flow the working line";
  Term.wait t (Screen.has "❯ flow the working line");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has "esc to interrupt" s && Screen.has answer s);
  let screen = Term.screen t in
  let answer_row = row_of answer screen in
  let working_row = row_of "esc to interrupt" screen in
  print_fact "working line one blank below the streamed tail"
    (working_row = answer_row + 2);
  print_fact "exactly one blank row separates the tail and the working line"
    (String.trim (row_text (answer_row + 1) screen) = "");
  [%expect
    {|
    working line one blank below the streamed tail: true
    exactly one blank row separates the tail and the working line: true|}]

(* ctrl+o mid-stream pins the reasoning ticker open (01-transcript.md
   §Reasoning): the constant-height 3-line window hides the summary's leading
   lines, and the global verbose lens re-renders the whole wrapped buffer so a
   leading marker only the pinned ticker can show comes on screen. The summary is
   six short lines, so its [ALPHA] head sits outside the last-three window and
   appears only once expanded. *)
let%expect_test "ctrl+o pins the reasoning ticker open mid-stream" =
  Project.with_temp "next-ticker-pin" @@ fun project ->
  let summary =
    "ALPHA leading marker line\n\
     second thought about backoff\n\
     third thought continues here\n\
     fourth line of the plan\n\
     fifth line nears the end\n\
     omega trailing marker line"
  in
  let answer = "Retries back off exponentially." in
  let line =
    reasoning_line ~id:"resp-next-ticker-pin" ~body_contains:[ "space out" ]
      ~stream_delay_ms:4000 ~summary ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "how do retries space out";
  Term.wait t (Screen.has "❯ how do retries space out");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "∴ Thinking");
  print_fact "leading line hidden by the 3-line window"
    (Screen.lacks "ALPHA" (Term.screen t));
  Term.send t Keys.ctrl_o;
  Term.wait t (Screen.has "ALPHA");
  print_fact "leading line visible once pinned open"
    (Screen.has "ALPHA" (Term.screen t));
  print_fact "trailing line still visible"
    (Screen.has "omega trailing marker line" (Term.screen t));
  [%expect
    {|
    leading line hidden by the 3-line window: true
    leading line visible once pinned open: true
    trailing line still visible: true|}]

(* The interrupt double-press (03-composer.md §Keybindings) settles into the
   honest drain line: [⠹ Interrupting…]. The host's cooperative drain escalates
   to a hard cancel ([Live.force_interrupt]), so the line advertises that next
   rung — [(esc again to force)] — until forcing begins (01-transcript.md §The
   working line). *)
let%expect_test
    "esc shows an interrupting line advertising the force escalation" =
  Project.with_temp "next-interrupting" @@ fun project ->
  let answer = "This answer is held open by the stream delay." in
  let line =
    streaming_line ~id:"resp-next-interrupting" ~body_contains:[ "hold" ]
      ~stream_delay_ms:4000 ~answer
  in
  Provider.with_responses project [ line ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "hold the line open";
  Term.wait t (Screen.has "❯ hold the line open");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "esc to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Press Esc again to interrupt");
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Interrupting…");
  print_fact "interrupting line present"
    (Screen.has "Interrupting…" (Term.screen t));
  print_fact "advertises the force escalation"
    (Screen.has "esc again to force" (Term.screen t));
  [%expect
    {|
    interrupting line present: true
    advertises the force escalation: true|}]

(* The working line renders committed turn output spend as [↓ N tokens]
   (01-transcript.md §The working line, "tokens once nonzero"). Usage lands with
   a step's terminal event, so a single-step turn commits the count only at
   settle, when the line is already gone; the honest observable is a two-step
   turn. Step one reads a file and reports 3100 output tokens, which the durable
   Assistant folds into committed spend; step two holds its final answer open, so
   during the hold the line shows the settled step's [↓ 3.1k tokens] (also pinning
   the thousands-with-one-decimal formatting). It clears when the turn settles. *)
let%expect_test "the working line shows committed output tokens across a step" =
  Project.with_temp "next-tokens" @@ fun project ->
  Project.write project "notes.txt" "retry notes: backoff doubles each attempt";
  let answer = "The notes describe exponential backoff." in
  let step_read =
    read_usage_line ~id:"resp-next-tokens-read"
      ~body_contains:[ "read the notes" ] ~path:"notes.txt" ~output_tokens:3100
  in
  let step_answer =
    streaming_line ~id:"resp-next-tokens-answer"
      ~body_contains:[ "function_call_output" ] ~stream_delay_ms:4000 ~answer
  in
  Provider.with_responses project [ step_read; step_answer ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "read the notes file";
  Term.wait t (Screen.has "❯ read the notes file");
  Term.send t Keys.enter;
  (* The answer only streams in step two, after step one's usage is committed, so
     this condition is reached during the held second step with 3100 committed. *)
  Term.wait t (fun s -> Screen.has "esc to interrupt" s && Screen.has answer s);
  print_fact "committed token clause rendered"
    (Screen.has "↓ 3.1k tokens" (Term.screen t));
  Term.wait t (fun s -> not (Screen.has "esc to interrupt" s));
  print_fact "token clause gone once the line settles"
    (Screen.lacks "↓ 3.1k tokens" (Term.screen t));
  print_fact "answer settled" (Screen.has answer (Term.screen t));
  [%expect
    {|
    committed token clause rendered: true
    token clause gone once the line settles: true
    answer settled: true|}]

(* The overflow answer used by the scroll tests: twelve one-line paragraphs
   overrun the 24-row viewport so the banner is pushed off the top and the
   settled tail (the final paragraph) pins to the bottom. *)
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

(* PageUp/PageDown as the terminal's legacy CSI tilde sequences (matrix's input
   parser maps [5~]/[6~] to the page keys); the tui-next harness has no key
   constants for them. *)
let page_up = "\027[5~"
let page_down = "\027[6~"

(* An SGR mouse wheel notch at a screen cell (1-based). Button code 64 is wheel
   up, 65 is wheel down (matrix input parser [is_scroll_code]); each notch
   carries [delta = 1], which the shell scales to three lines. The app enables
   mouse reporting (runtime.ml [~mouse_enabled:true]), so the sequence reaches
   the input parser. *)
let wheel_up ~col ~row = Printf.sprintf "\027[<64;%d;%dM" col row

(* No scrollbar, ever (01-transcript.md §Seam replay, scroll, spacing): an
   overflowing answer scrolls, but the transcript renders no scroll bar. Mosaic's
   scroll box draws its thumb with the full-block glyph [█] (scroll_bar.ml); with
   the bar suppressed and the banner (whose lockup also draws [█]) scrolled off
   the top at the tail, no [█] remains on screen. *)
let%expect_test "the transcript renders no scrollbar on overflow" =
  Project.with_temp "next-noscroll" @@ fun project ->
  Provider.with_openai project ~answer:overflow_answer
    ~body_contains:[ "overflow" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "overflow the viewport";
  Term.wait t (Screen.has "❯ overflow the viewport");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "cap the ceiling" s && Screen.has "? for shortcuts" s);
  print_fact "banner lockup scrolled off the top"
    (Screen.lacks "▄▀▀" (Term.screen t));
  print_fact "no scroll bar thumb glyph on screen"
    (Screen.lacks "█" (Term.screen t));
  [%expect
    {|
    banner lockup scrolled off the top: true
    no scroll bar thumb glyph on screen: true|}]

(* PageUp/PageDown paging (01-transcript.md §Seam replay, scroll, spacing): from
   the settled tail, PageUp brings the scrolled-off banner lockup back on screen;
   PageDown returns to the bottom, where the final paragraph is pinned and the
   banner is gone again. The transcript never takes focus — the keys route
   through the shell (app.ml [key_msg]) while the composer keeps the caret. *)
let%expect_test
    "PageUp reveals earlier content and PageDown returns to the tail" =
  Project.with_temp "next-paging" @@ fun project ->
  Provider.with_openai project ~answer:overflow_answer
    ~body_contains:[ "overflow" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "overflow the viewport";
  Term.wait t (Screen.has "❯ overflow the viewport");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "cap the ceiling" s && Screen.has "? for shortcuts" s);
  print_fact "banner off the top at the settled tail"
    (Screen.lacks "▄▀▀" (Term.screen t));
  Term.send t page_up;
  Term.wait t (Screen.has "▄▀▀");
  print_fact "PageUp brought the banner lockup back"
    (Screen.has "▄▀▀" (Term.screen t));
  Term.send t page_down;
  Term.send t page_down;
  Term.wait t (fun s ->
      Screen.has "The final word is to cap the ceiling." s
      && Screen.lacks "▄▀▀" s);
  print_fact "PageDown returned to the settled tail"
    (Screen.has "The final word is to cap the ceiling." (Term.screen t));
  print_fact "banner off the top again" (Screen.lacks "▄▀▀" (Term.screen t));
  [%expect
    {|
    banner off the top at the settled tail: true
    PageUp brought the banner lockup back: true
    PageDown returned to the settled tail: true
    banner off the top again: true|}]

(* The wheel always scrolls the transcript (01-transcript.md §Seam replay,
   scroll, spacing): a wheel notch over the composer — a dead zone the transcript
   does not cover — still scrolls the transcript up. At the settled tail the
   second paragraph is scrolled off the top; one notch over the composer's
   [❯ message spice] row (row 22 in the 24-row layout) brings it back on screen.
   The app-root mouse handler routes the notch because the scrollport stops
   propagation only for wheels it consumes over its own tree, so a wheel outside
   that tree bubbles to the shell root and pages the transcript. *)
let%expect_test "the wheel over the composer scrolls the transcript" =
  Project.with_temp "next-wheel" @@ fun project ->
  Provider.with_openai project ~answer:overflow_answer
    ~body_contains:[ "overflow" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "overflow the viewport";
  Term.wait t (Screen.has "❯ overflow the viewport");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "cap the ceiling" s && Screen.has "? for shortcuts" s);
  print_fact "second paragraph hidden above the top at the settled tail"
    (Screen.lacks "The delay doubles on each failure." (Term.screen t));
  Term.send t (wheel_up ~col:10 ~row:22);
  Term.wait t (Screen.has "The delay doubles on each failure.");
  print_fact "wheel over the composer scrolled the transcript up"
    (Screen.has "The delay doubles on each failure." (Term.screen t));
  [%expect
    {|
    second paragraph hidden above the top at the settled tail: true
    wheel over the composer scrolled the transcript up: true|}]

(* /thinking hides reasoning at the source and restores it (01-transcript.md
   §Reasoning "off ⇒ blocks omitted entirely", §Notices). Toggling off echoes
   the muted [❯ /thinking] and settles the event-class outcome; a following
   reasoning-bearing turn then shows no [∴] anywhere — no ticker mid-stream and
   no settled one-liner, because the block is dropped where it is folded, not
   filtered downstream. Toggling back on, the next turn's ticker and titled
   one-liner return. The flip governs only blocks added while off; the
   append-time law leaves already-rendered reasoning in the document. *)
let%expect_test "/thinking hides reasoning at the source and restores it" =
  Project.with_temp "next-thinking" @@ fun project ->
  let drop_answer = "Ready when you are." in
  let hidden_summary =
    "**Hidden plan**\n\
     Thinking is off, so this reasoning must never reach the screen."
  in
  let hidden_answer = "Answered while reasoning was hidden." in
  let shown_summary =
    "**Shown plan**\n\
     Thinking is back on, so the ticker streams this reasoning again."
  in
  let shown_answer = "Answered while reasoning was shown." in
  let drop =
    Provider.response_line ~id:"resp-next-thinking-drop"
      ~body_contains:[ "start the session" ] ~body_not_contains:[]
      ~answer:drop_answer
  in
  let hidden =
    reasoning_line ~id:"resp-next-thinking-hidden"
      ~body_contains:[ "reason while off" ] ~stream_delay_ms:2500
      ~summary:hidden_summary ~answer:hidden_answer
  in
  let shown =
    reasoning_line ~id:"resp-next-thinking-shown"
      ~body_contains:[ "reason while on" ] ~stream_delay_ms:2500
      ~summary:shown_summary ~answer:shown_answer
  in
  Provider.with_responses project [ drop; hidden; shown ] @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  (* Drop into chat so the toggle has a document to echo into. *)
  Term.send t "start the session";
  Term.wait t (Screen.has "❯ start the session");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has drop_answer s && Screen.has "? for shortcuts" s);
  (* Toggle thinking off (Enter is its own write, per the atomic-enter rule for
     slash commands too): the echo and the event-class outcome both settle. *)
  Term.send t "/thinking";
  Term.wait t (Screen.has "Toggle thinking");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "thinking hidden");
  print_fact "off: echo line rendered"
    (Screen.has "❯ /thinking" (Term.screen t));
  print_fact "off: event notice is the honest off line"
    (Screen.has
       "thinking hidden — reasoning stays in the session, not on screen"
       (Term.screen t));
  (* A reasoning-bearing turn while off: no [∴] mid-stream or settled. *)
  Term.send t "reason while off";
  Term.wait t (Screen.has "❯ reason while off");
  Term.send t Keys.enter;
  Term.wait t (fun s ->
      Screen.has "esc to interrupt" s && Screen.has hidden_answer s);
  print_fact "off: no thinking ticker mid-stream"
    (Screen.lacks "∴" (Term.screen t));
  Term.wait t (fun s -> not (Screen.has "esc to interrupt" s));
  print_fact "off: no thought one-liner after settle"
    (Screen.lacks "∴" (Term.screen t));
  print_fact "off: answer still settles"
    (Screen.has hidden_answer (Term.screen t));
  (* Toggle back on: the honest restore line settles. *)
  Term.send t "/thinking";
  Term.wait t (Screen.has "Toggle thinking");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "thinking shown");
  print_fact "on: event notice is the honest restore line"
    (Screen.has "thinking shown — reasoning returns to the transcript"
       (Term.screen t));
  (* A reasoning-bearing turn while on: the ticker streams, then the titled
     one-liner settles. *)
  Term.send t "reason while on";
  Term.wait t (Screen.has "❯ reason while on");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "∴ Thinking");
  print_fact "on: ticker header returns mid-stream"
    (Screen.has "∴ Thinking" (Term.screen t));
  Term.wait t (fun s -> not (Screen.has "esc to interrupt" s));
  print_fact "on: settled thought one-liner returns"
    (Screen.has "∴ Thought for" (Term.screen t));
  print_fact "on: title from the bold lead"
    (Screen.has "Shown plan" (Term.screen t));
  [%expect
    {|
    off: echo line rendered: true
    off: event notice is the honest off line: true
    off: no thinking ticker mid-stream: true
    off: no thought one-liner after settle: true
    off: answer still settles: true
    on: event notice is the honest restore line: true
    on: ticker header returns mid-stream: true
    on: settled thought one-liner returns: true
    on: title from the bold lead: true|}]

[%%run_tests "spice.tui-next.transcript"]
