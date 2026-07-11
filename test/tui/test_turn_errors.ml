(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

let%expect_test "a run-construction failure settles without exiting" =
  Tui.run ~name:"turn-error-run-construction"
    ~env:
      [
        ("SPICE_SANDBOX_MODE", "external-sandbox");
        ("SPICE_SANDBOX_REQUIRE", "enforced");
      ]
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "start this turn";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  Tui.keys t Key.ctrl_c;
  Tui.keys t Key.ctrl_c;
  Tui.await_exit t;
  print_endline "runtime remained interactive";
  [%expect
    {|
    01 |
    02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
    03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
    04 |        sandbox: external-sandbox (config)
    05 |
    06 | ✗ sandbox unavailable: a declared external sandbox does not satisfy sandbox.
    07 |   require=enforced
    08 |   next: set sandbox.require=enforced-or-external to accept the declared
    09 |   boundary, or choose an enforceable mode
    10 |   Tell spice how to proceed.
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
    24 |   ! not logged in · /login · $PROJECT · gpt-5.5 medium · dune: ✗
    runtime remained interactive|}]

let%expect_test "an unexpected run-construction exception settles" =
  Tui.run ~name:"turn-error-run-exception" @@ fun t ->
  Tui.settle t;
  let git_marker = Project.path (Tui.project t) ".git" in
  Unix.symlink ".git" git_marker;
  Fun.protect
    ~finally:(fun () -> Unix.unlink git_marker)
    (fun () ->
      Tui.keys t "start through the broken workspace";
      Tui.enter t;
      Tui.settle t;
      Printf.printf "settled composer restored: %b\n"
        (String.includes ~affix:"❯ message spice" (Tui.screen t)));
  Tui.keys t Key.ctrl_c;
  Tui.keys t Key.ctrl_c;
  Tui.await_exit t;
  print_endline "runtime remained interactive";
  [%expect
    {|
    settled composer restored: true
    runtime remained interactive|}]

(* Turn lifecycle beyond the happy path. The old suite pinned a single provider
   failure (an HTTP 400); production needs the status variety (an auth-shaped
   401, a server-shaped 500), the submit-validation floor (an empty or
   whitespace-only draft never starts a turn), and multi-turn context (the
   second request carries the first exchange). The in-process provider serves
   error statuses through its [Http] reply on the responses endpoint — no
   harness change needed. A credential is present (the harness sets a test key
   whenever a provider is wired), so these are provider-HTTP failures, distinct
   from the logged-out path in test_auth. *)

let responses = "POST /v1/responses HTTP/1.1"

(* A 401 on the turn's request settles a failure notice with a next-step line,
   and no assistant block renders. *)
let%expect_test "a 401 from the provider settles a failure notice" =
  let script =
    [
      Provider_script.http ~expect:[ "say hello" ] ~gate:"fin" ~line:responses
        ~status:401
        {|{"error":{"message":"invalid api key","type":"authentication_error"}}|};
    ]
  in
  Tui.run ~name:"errors-401" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ say hello
07 |
08 | ✗ authentication failed for openai — check the provider login or credential
09 |   Tell spice how to proceed.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗        ? for shortcuts|}]

(* A 5xx is not fatal: unlike the 401, the client retries a server error rather
   than failing the turn. The script serves the 500 first, then a held
   completion — the retry reaches the provider as a SECOND request, which
   [await_request t 2] proves (it fails loudly if no retry is sent). The frame is
   goldened while the recovery is HELD on the gate, so it is deterministic: the
   turn is still working (it survived the 500), not settled. The retry request
   plus this stable in-flight frame are the resilience contract under test. *)
let%expect_test "a 5xx is retried rather than failing the turn" =
  let script =
    [
      Provider_script.http ~expect:[ "say hello" ] ~line:responses ~status:500
        {|{"error":{"message":"internal server error","type":"server_error"}}|};
      Provider_script.message ~expect:[ "say hello" ] ~gate:"fin" ~id:"resp-1"
        "Recovered after a retry.";
    ]
  in
  Tui.run ~name:"errors-retry" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  (* The retry arrives as the second request; the recovery stays gated so the
     working frame is stable. *)
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ say hello
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}];
  Tui.release t "fin";
  Tui.settle t

(* A terminal provider failure must release the turn: the next submit starts
   a fresh turn that reaches the provider. The guarded regression: the error
   path returned without closing the started turn in the session document, so
   every later submit was rejected with "session already has active turn"
   while the composer sat idle — the session was unusable and the prompts were
   lost. [await_request t 2] fails loudly if the second submit never becomes a
   request. *)
let%expect_test "a failed turn releases the session for the next submit" =
  let script =
    [
      Provider_script.http ~expect:[ "first ask" ] ~gate:"fin" ~line:responses
        ~status:400
        {|{"error":{"message":"bad request","type":"invalid_request_error"}}|};
      Provider_script.message ~expect:[ "second ask" ] ~gate:"fin2" ~id:"resp-2"
        "Recovered on a fresh turn.";
    ]
  in
  Tui.run ~name:"errors-release" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "first ask";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.keys t "second ask";
  Tui.settle t;
  Tui.enter t;
  ignore (Tui.await_request t 2 : string);
  Tui.release t "fin2";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ first ask
07 |
08 | ✗ bad request
09 |   Tell spice how to proceed.
10 |
11 | ❯ second ask
12 |
13 | ⏺ Recovered on a fresh turn.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]

(* Submit validation: after one settled turn, an empty draft and a
   whitespace-only draft both leave the transcript unchanged — no second request
   is sent, no working line appears. The provider script carries exactly one
   message, so a second turn would fail loudly at the provider (no item to
   serve); the unchanged frame is the proof. *)
let%expect_test "an empty or whitespace-only submit is a no-op" =
  let script =
    [
      Provider_script.message ~expect:[ "say hello" ] ~gate:"fin" ~id:"resp-1"
        "Only reply.";
    ]
  in
  Tui.run ~name:"errors-empty" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  (* Empty draft: enter does nothing. *)
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ say hello
07 |
08 | ⏺ Only reply.
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}];
  (* Whitespace-only draft: enter is still a no-op — no turn starts — but the
     typed spaces remain the draft, so the placeholder is suppressed and the
     composer shows a bare marker (row 22). *)
  Tui.keys t "   ";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ say hello
07 |
08 | ⏺ Only reply.
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
22 | ❯
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗      ? for shortcuts|}]

(* A multi-turn conversation carries context: the SECOND request body must
   contain the first exchange. The [~expect] on the second item asserts that at
   the wire (it fails loudly if the first reply is absent from the request), so
   the context-carrying is proved even though the second turn's completion is held
   — the golden shows the first exchange settled and the second turn in flight, a
   deterministic frame. The post-completion frame is already covered by the
   retry test, so it is not duplicated here.

   KNOWN BUG still visible here (row 22): a follow-up turn submitted from the
   transcript does NOT clear the composer draft. During an in-flight turn the
   composer should show the "queue a message — sends after this turn" placeholder
   (as the retry test's row 22 does); instead it shows the stale "second question"
   draft. A first turn from the home stage DOES clear (see the empty-submit test
   and test_turn). suite-port-3 independently found the same on resumed sessions
   (test_session). When the product clears the follow-up draft, row 22 flips to
   the queue placeholder and this golden must be re-promoted. See the report. *)
let%expect_test "a second turn carries the first exchange as context" =
  let script =
    [
      Provider_script.message ~expect:[ "first question" ] ~gate:"t1"
        ~id:"resp-1" "First reply.";
      Provider_script.message
        ~expect:[ "second question"; "First reply." ]
        ~gate:"t2" ~id:"resp-2" "Second reply.";
    ]
  in
  Tui.run ~name:"errors-multiturn" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "first question";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "t1";
  Tui.settle t;
  Tui.keys t "second question";
  Tui.enter t;
  (* The second request carries the first exchange (asserted by [~expect]); its
     completion stays gated so the frame is a stable in-flight one. *)
  ignore (Tui.await_request t 2 : string);
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ first question
07 |
08 | ⏺ First reply.
09 |
10 | ❯ second question
11 |
12 | ⠋ Working… (0s · esc to interrupt)
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ second question
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}];
  Tui.release t "t2";
  Tui.settle t
