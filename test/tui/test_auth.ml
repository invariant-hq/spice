(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

(* The login panel's abort and repair seams under the deterministic harness.

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

let select_openai_methods t =
  open_login t;
  Tui.keys t "openai";
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
22 |   ! $PROJECT.xdg/config/spice/auth.json: Expected
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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗   ? for shortcuts|}]

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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]

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
24 |   $PROJECT · gpt-5.5 medium · dune: ✗    ? for shortcuts|}]

(* The provider and method pickers are application state, not terminal wiring.
   A connected OpenAI env account and disconnected alternatives render in the
   provider list; selecting OpenAI exposes all three declared login methods. *)
let%expect_test "provider and login-method pickers render account state" =
  Tui.run ~name:"auth-pickers" ~env:[ ("OPENAI_API_KEY", "test-key-abcd") ]
  @@ fun t ->
  Tui.settle t;
  open_login t;
  Tui.print t;
  [%expect {|01 |
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
17 |   ❯ OpenAI                                                  env OPENAI_API_KEY
18 |     Anthropic                                                    not connected
19 |     Google                                                       not connected
20 |     Ollama                                                       not connected
21 |     DeepSeek                                                   no login needed
22 |     Local                                                      no login needed
23 |
24 |   ↵ choose · esc cancel · type to filter · ↑↓ select|}];
  Tui.keys t "openai";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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

(* API-key entry owns a masked buffer. Empty submit flashes, typed bytes appear
   only as bullets, and escape returns through the provider picker. *)
let%expect_test "api-key entry masks the secret and escape walks back" =
  Tui.run ~name:"auth-api-key-mask" @@ fun t ->
  Tui.settle t;
  open_login t;
  Tui.keys t "anthropic";
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.enter t;
  Tui.settle t;
  Tui.keys t "sk-secret-value-123";
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
20 |   ❯ •••••••••••••••••••▌
21 |   ────────────────────────────────────────────────────────────────────────────
22 |   enter save · esc back · paste works · your key is not shown
23 |
24 |   ↵ save · esc back|}];
  Tui.keys t Keys.escape;
  Tui.settle t;
  Tui.print t;
  [%expect {|01 |
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
17 |   ❯ OpenAI                                                  env OPENAI_API_KEY
18 |     Anthropic                                                    not connected
19 |     Google                                                       not connected
20 |     Ollama                                                       not connected
21 |     DeepSeek                                                   no login needed
22 |     Local                                                      no login needed
23 |
24 |   ↵ choose · esc cancel · type to filter · ↑↓ select|}]

(* Browser authorization publishes its URL before the flow waits for the
   callback. The pending-perform settle holds that exact challenge frame; copy
   flashes in place and escape cancels back to the method picker. *)
let%expect_test "browser authorization renders, copies, and cancels" =
  Tui.run ~name:"auth-browser-challenge" @@ fun t ->
  Tui.settle t;
  select_openai_methods t;
  Tui.enter t;
  Tui.settle_pending_perform t;
  Tui.print t;
  [%expect {|01 |
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
15 |   Log in to OpenAI · browser
16 |
17 |   Press enter to open your browser and authorize Spice.
18 |   Or open this link yourself:
19 |
20 |      https://auth.openai.com/oauth/authorize?response_type=code&cl…  c  copy
21 |
22 |   ⠋ Waiting for authorization… (0s · esc to cancel)
23 |
24 |   On a remote or headless machine? Press esc and choose device code.|}];
  Tui.keys t "c";
  Tui.settle_pending_perform t;
  Tui.print t;
  [%expect {|01 |
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
15 |   Log in to OpenAI · browser
16 |
17 |   Press enter to open your browser and authorize Spice.
18 |   Or open this link yourself:
19 |
20 |      https://auth.openai.com/oauth/authorize?response_type=code&cli…  copied
21 |
22 |   ⠋ Waiting for authorization… (0s · esc to cancel)
23 |
24 |   On a remote or headless machine? Press esc and choose device code.|}];
  Tui.keys t Keys.escape;
  Tui.settle t

(* The fake local auth issuer serves a long-polling device challenge. Virtual
   time stays before the first poll, keeping the code, warning, expiry, and copy
   affordance stable until escape cancels. *)
let%expect_test "device-code authorization renders, copies, and cancels" =
  let script =
    [
      Provider.http
        ~line:"POST /api/accounts/deviceauth/usercode HTTP/1.1" ~status:200
        {|{"device_auth_id":"dev-1","user_code":"CODE-1234","expires_in":900,"interval":300}|};
    ]
  in
  Tui.run ~name:"auth-device-challenge" ~size:(80, 32) ~provider:script
    ~openai_auth:true
  @@ fun t ->
  Tui.settle t;
  select_openai_methods t;
  Tui.keys t "device";
  Tui.settle t;
  Tui.enter t;
  Tui.settle_pending_perform t;
  Tui.print t;
  [%expect {|01 |
02 |
03 |
04 |
05 |
06 |
07 |
08 |
09 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
10 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
11 |
12 |                            dev · openai/gpt-5.5 medium
13 |
14 |      ▎ welcome — and thanks for trying spice this early.
15 |      ▎ it's experimental: sessions and config may change without migration.
16 | ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
17 |    log in
18 |
19 |   Log in to OpenAI · device code
20 |
21 |   1. Open this link and sign in:
22 |
23 |      http://127.0.0.1:$PORT/codex/device                             c  copy
24 |
25 |   2. Enter this code (expires in 15m 00s):
26 |
27 |      CODE-1234                                                       c  copy
28 |
29 |   Device codes are a common phishing target. Never share this code.
30 |
31 |   ⠋ Waiting for authorization… (0s · esc to cancel)
32 ||}];
  Tui.keys t "c";
  Tui.settle_pending_perform t;
  Tui.keys t Keys.escape;
  Tui.settle t

(* With no configured model, a successful saved API key changes the connected
   provider set and therefore the derived default rendered by the home stage. *)
let%expect_test "api-key login updates the derived model facts" =
  Tui.run ~name:"auth-derived-model" ~unset:[ "SPICE_MODEL" ]
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
  [%expect {|01 |
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
24 |   ↵ set default · ←→ effort · type to filter · ↑↓ select · esc close|}]
