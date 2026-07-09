(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* The login panel's abort and repair seams under the deterministic harness.

   Mid-flight browser/device waits cannot be OBSERVED here — the login engine's
   perform stays pending until the flow settles, so [Tui.settle] would spin —
   but both journeys below end with the flow torn down, so every settle
   converges. The waiting-panel rendering itself is pty-covered
   (test/tui/test_auth.ml).

   XXX goldens unfilled: the [/login openai] argument form cannot be submitted
   through this harness yet — the slash palette's no-match state swallows every
   Enter (app.ml [activate_completion]: ↵ never sends the draft while a list is
   up), where the pty suite observes a single Enter falling through. Route the
   ctrl+c journey through the bare [/login] command (which matches, inserts,
   and submits) and the provider picker instead, then fill the goldens from
   _build/_tests. *)

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
  [%expect {|01 |
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
  [%expect {|01 |
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
  Tui.run ~name:"auth-load-retry"
    ~seed:(fun project -> Util.write_file (store project) "{\"version\":")
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
  Util.write_file
    (store (Tui.project t))
    "{\"version\":1,\"credentials\":{}}\n";
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
