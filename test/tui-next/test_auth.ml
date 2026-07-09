(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The login panel's abort and repair seams under the deterministic harness.

   Mid-flight browser/device waits cannot be OBSERVED here — the login engine's
   perform stays pending until the flow settles, so [Tui.settle] would spin —
   but every journey below ends with its flow torn down, so every settle
   converges. The waiting-panel rendering itself is pty-covered
   (test/tui/test_auth.ml).

   Slash-command driving: the [/login openai] argument form cannot be submitted
   here — the palette's no-match state swallows every Enter (app.ml
   [activate_completion]) — so journeys route through the bare command (which
   matches, inserts, and submits on the second Enter) and the provider
   picker. *)

(* [/login] through the palette: the first Enter inserts the arg-taking
   command and closes the list, the second submits it. *)
let open_login t =
  Tui.keys t "/login";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t

(* Ctrl+C while a browser login waits must cancel the FLOW — resolve its cancel
   promise and step back to the method picker, exactly as esc — not arm quit;
   the chord regains its quit meaning once no flow is live. The ctrl+c lands
   without an intermediate settle: a settle cannot converge while the flow's
   perform is pending, and the panel stamps the request id synchronously when
   the flow starts, so the abort routes correctly straight away. *)
let%expect_test "ctrl+c cancels a waiting browser login, then regains quit" =
  Tui.run ~name:"auth-ctrl-c-cancel" @@ fun t ->
  Tui.settle t;
  open_login t;
  (* Filter the provider picker to OpenAI and confirm into its methods. *)
  Tui.keys t "openai";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  (* Browser is the first declared method; the flow starts and waits. *)
  Tui.enter t;
  Tui.keys t Keys.ctrl_c;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                            dev · openai/gpt-5.5 medium
08 |
09 |      ▎ welcome — and thanks for trying spice this early.
10 |      ▎ it's experimental: sessions and config may change without migration.
11 |
12 |
13 |
14 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
15 |    log in
16 |
17 |   Log in to OpenAI
18 |   Choose how to sign in.
19 |
20 |   ❯ Browser                                     open your browser to authorize
21 |     OpenAI ChatGPT device code                  enter a code on another device
22 |     API key                                      paste a key from the provider
23 |
24 |   ↵ choose · esc back · type to filter · ↑↓ select|}];
  (* No flow is waiting now: the chord arms the exit notice as everywhere
     else. *)
  Tui.keys t Keys.ctrl_c;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                            dev · openai/gpt-5.5 medium
08 |
09 |      ▎ welcome — and thanks for trying spice this early.
10 |      ▎ it's experimental: sessions and config may change without migration.
11 |
12 |
13 |
14 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
15 |    log in
16 |
17 |   Log in to OpenAI
18 |   Choose how to sign in.
19 |
20 |   ❯ Browser                                     open your browser to authorize
21 |     OpenAI ChatGPT device code                  enter a code on another device
22 |     API key                                      paste a key from the provider
23 |
24 |   ↵ choose · esc back · type to filter · ↑↓ select|}]

(* A provider-load failure is repairable in place: [↵] on the error line
   reloads the entries. The store starts corrupt (load error), is repaired
   behind the panel, and the retry lands in the provider picker. *)
let%expect_test "a provider load error retries in place" =
  let store project = Project.scratch project "config/spice/auth.json" in
  Tui.run ~name:"auth-load-retry" ~seed:(fun project ->
      Util.write_file (store project) "{\"version\":")
  @@ fun t ->
  Tui.settle t;
  open_login t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |      ▎ welcome — and thanks for trying spice this early.
11 |      ▎ it's experimental: sessions and config may change without migration.
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
20 |    log in
21 |
22 |   ! $PROJECT.xdg/config/spice/auth.json: Expe
23 |
24 |   ↵ retry · esc close|}];
  (* Repair the store behind the panel; [↵] retries the load. *)
  Util.write_file (store (Tui.project t)) "{\"version\":1,\"credentials\":{}}\n";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |      ▎ welcome — and thanks for trying spice this early.
11 |      ▎ it's experimental: sessions and config may change without migration.
12 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
13 |    log in
14 |
15 |   Choose a provider to authenticate.
16 |
17 |   ❯ OpenAI                                                       not connected
18 |     Anthropic                                                    not connected
19 |     Google                                                       not connected
20 |     Ollama                                                       not connected
21 |     DeepSeek                                                   no login needed
22 |     Local                                                      no login needed
23 |
24 |   ↵ choose · esc cancel · type to filter · ↑↓ select|}]

(* A submit with nothing connected fails the turn AND opens the login flow:
   the failure notice is the transcript record, the panel is the repair
   (09-auth §9). The harness default env carries no credential. *)
let%expect_test "a logged-out submit opens the login flow" =
  Tui.run ~name:"auth-logged-out-submit" @@ fun t ->
  Tui.settle t;
  Tui.keys t "hello";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |   Tell spice how to proceed.
02 |
03 |
04 |
05 |
06 |
07 |
08 |
09 |
10 |
11 |
12 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
13 |    log in
14 |
15 |   Choose a provider to authenticate.
16 |
17 |   ❯ OpenAI                                                       not connected
18 |     Anthropic                                                    not connected
19 |     Google                                                       not connected
20 |     Ollama                                                       not connected
21 |     DeepSeek                                                   no login needed
22 |     Local                                                      no login needed
23 |
24 |   ↵ choose · esc cancel · type to filter · ↑↓ select|}]

(* A home-stage settle is confirmed, not silent: the settled record takes over
   the standing notice slot. Logging out an env-sourced credential is the
   deterministic no-network variant — the env var survives the removal, and
   the record says so. *)
let%expect_test "a home logout settle takes over the notice slot" =
  Tui.run ~name:"auth-home-logout-notice"
    ~env:[ ("OPENAI_API_KEY", "test-key-abcd") ]
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/logout";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |              ▎ Log out of OpenAI · ! env OPENAI_API_KEY still active
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ message spice
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |
18 |                       sandbox: danger-full-access (config)
19 |
20 |
21 |
22 |
23 |
24 |   …ui-next-auth-home-logout-notice · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* A stored credential logs out through the same direct path (one connected
   provider, no picker) and records the removal. The store is seeded before
   boot; no env var shadows it. *)
let%expect_test "logging out a stored credential records the removal" =
  Tui.run ~name:"auth-logout-removed" ~seed:(fun project ->
      Util.write_file
        (Project.scratch project "config/spice/auth.json")
        {|{"version":1,"credentials":{"openai":{"default":{"kind":"api_key","api_key":"sk-test-abcd-9999"}}}}|})
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/logout";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |              ▎ Log out of OpenAI · ! env OPENAI_API_KEY still active
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ message spice
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |
18 |                       sandbox: danger-full-access (config)
19 |
20 |
21 |
22 |
23 |
24 |   …ce-tui-next-auth-logout-removed · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* In chat, a settled login lands as a transcript event notice. One scripted
   turn enters chat; the anthropic api-key login then saves and checks against
   a closed port — the network problem is non-fatal, so the record reads
   signed-in with the stored fingerprint. *)
let%expect_test "a chat-phase login settles as a transcript record" =
  let script =
    [ Provider.message ~expect:[ "say hello" ] ~id:"resp-1" "Hello!" ]
  in
  Tui.run ~name:"auth-chat-record" ~provider:script
    ~env:[ ("SPICE_ANTHROPIC_BASE_URL", "http://127.0.0.1:9/v1") ]
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  Tui.settle t;
  open_login t;
  Tui.keys t "anthropic";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "sk-ant-test-key-1234";
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
08 | ⏺ Hello!
09 |
10 |   Log in to Anthropic · ✓ signed in · …1234 (store)
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
24 |   …spice-tui-next-auth-chat-record · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* A saved key the provider rejects reads saved-but-blocked: the provider fake
   answers the post-save model-list check with 401. *)
let%expect_test "a rejected key records saved-but-blocked" =
  let script =
    [ Provider.http ~line:"GET /v1/models HTTP/1.1" ~status:401 "{}" ]
  in
  Tui.run ~name:"auth-blocked-key" ~provider:script @@ fun t ->
  Tui.settle t;
  open_login t;
  Tui.keys t "openai";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "api";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "sk-rejected-key-9999";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |      ▎ Log in to OpenAI · ✓ saved · ! blocked — key rejected by the provider
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ message spice
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |
18 |                       sandbox: danger-full-access (config)
19 |
20 |
21 |
22 |
23 |
24 |   …spice-tui-next-auth-blocked-key · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

(* A locked model row reroutes into the login flow pre-selected on its
   provider: single-method Anthropic lands straight in the api-key entry. *)
let%expect_test "a locked model row reroutes into login" =
  Tui.run ~name:"auth-locked-reroute"
    ~env:[ ("OPENAI_API_KEY", "test-key-abcd") ]
  @@ fun t ->
  Tui.settle t;
  Tui.keys t "/model";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "claude";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |      ▎ welcome — and thanks for trying spice this early.
11 |      ▎ it's experimental: sessions and config may change without migration.
12 |
13 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
14 |    log in
15 |
16 |   Paste your Anthropic API key
17 |   Stored locally in the auth store; never displayed again.
18 |
19 |   ────────────────────────────────────────────────────────────────────────────
20 |   ❯ ▌
21 |   ────────────────────────────────────────────────────────────────────────────
22 |   enter save · esc back · paste works · your key is not shown
23 |
24 |   ↵ save · esc back|}]

(* A home-stage login that saves a credential hands off to the model picker,
   seeded on the just-connected provider's group with the catalog whole (D1);
   esc lands back on the composer with the settled record standing in the
   notice slot. *)
let%expect_test "a home login settle hands off to the model picker" =
  Tui.run ~name:"auth-model-handoff"
    ~env:[ ("SPICE_ANTHROPIC_BASE_URL", "http://127.0.0.1:9/v1") ]
  @@ fun t ->
  Tui.settle t;
  open_login t;
  Tui.keys t "anthropic";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "sk-ant-test-key-1234";
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |                ▎ Log in to Anthropic · ✓ signed in · …1234 (store)
11 |
12 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
13 |    model
14 |
15 |   ↑ 10 more
16 |
17 |     Anthropic
18 |   ❯ Claude Sonnet 5         Default · 1M context · Efficient for routine tasks
19 |     Claude Fable 5               1M context · Best for everyday, complex tasks
20 |   ↓ 26 more
21 |
22 |   ○ No effort  ← → to adjust
23 |
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}];
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |
05 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
06 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
07 |
08 |                            dev · openai/gpt-5.5 medium
09 |
10 |                ▎ Log in to Anthropic · ✓ signed in · …1234 (store)
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ message spice
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |
18 |                       sandbox: danger-full-access (config)
19 |
20 |
21 |
22 |
23 |
24 |   …ice-tui-next-auth-model-handoff · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]
