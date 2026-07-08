(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the [spice tui-next] provider login / logout panel
   (doc/ui-design/09-auth.md in the 03-ia panel shell; doc/plans/tui-next-auth.md).

   FAKING: the pickers, the masked api-key entry, and the esc ladder are
   deterministic with an env credential and NO network. [OPENAI_API_KEY]
   authenticates OpenAI (its row reads connected in the provider picker; it is
   the removable-vs-env case for /logout), while Anthropic/Google stay [not
   connected] and DeepSeek is [no login needed]. The masked-input test asserts
   the typed key NEVER appears on screen (security rule 1). The save-check
   (case 4), device-code (case 5), and browser (case 6) paths land in phases 2-4
   against the fake provider server / fake auth issuer; the browser
   SUCCESS/timeout paths are honestly cram-only.

   These assert FACTS, not full-screen goldens: the home stage's dune line is
   non-deterministic (✓/✗ by the workspace's build state). SPICE_REDUCED_MOTION=1
   pins a static lockup. Enter is ALWAYS a SEPARATE write from the command text
   (the atomic-enter artifact). *)

open Tui_harness

(* OpenAI authenticated via env (connected in the picker, removable-vs-env in
   logout); the other providers stay unconnected for the not-connected rows. *)
let env = [ ("SPICE_REDUCED_MOTION", "1"); ("OPENAI_API_KEY", "test-key-abcd") ]
let print_fact = Util.print_fact

let run ?rows ?cols project f =
  Term.run ~env ?rows ?cols project f

(* Open the login flow via [/login] from the home stage: the palette filters to
   the command, Enter runs it (separate write), and we wait for the provider
   picker's subtitle — proof the entries loaded. *)
(* [/login] with no argument goes through the palette: the row is offered (its
   description shows), the first Enter INSERTS "/login " and closes the list
   (/login is arg-taking — 03-composer.md §Slash palette), and a second Enter
   submits the inserted command, opening the provider picker. (The argument
   forms — [/login openai] — keep the palette open but with a query that matches
   no command, so a single Enter falls through to submit.) *)
let open_login t =
  Term.send t "/login";
  Term.wait t (Screen.has "Log in to a provider");
  Term.send t Keys.enter;
  Term.wait t (Screen.lacks "Log in to a provider");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Choose a provider to authenticate.")

(* 0. Discovery: [/login] and [/logout] must appear in the slash palette — the
   command catalog's [implemented] set gates palette visibility, so a command
   wired only in dispatch but missing from that set ships hidden (the regression
   this asserts). Typing [/log] filters the palette to both. *)
let%expect_test "login and logout are discoverable in the palette" =
  Project.with_temp "auth-palette" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/log";
  Term.wait t (fun s -> Screen.has "/login" s && Screen.has "/logout" s);
  let s = Term.screen t in
  print_fact "/login offered in palette" (Screen.has "/login" s);
  print_fact "/logout offered in palette" (Screen.has "/logout" s);
  [%expect
    {|
    /login offered in palette: true
    /logout offered in palette: true |}]

(* 1. The provider picker: OpenAI connected (env credential), Anthropic not
   connected, DeepSeek non-selectable [no login needed]; the [log in] chip. *)
let%expect_test "login provider picker renders account state" =
  Project.with_temp "auth-providers" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  open_login t;
  let s = Term.screen t in
  print_fact "log in chip" (Screen.has "log in" s);
  print_fact "OpenAI row" (Screen.has "OpenAI" s);
  print_fact "OpenAI connected (env source)" (Screen.has "env OPENAI_API_KEY" s);
  print_fact "Anthropic not connected" (Screen.has "not connected" s);
  print_fact "DeepSeek no login needed" (Screen.has "no login needed" s);
  [%expect
    {|
    log in chip: true
    OpenAI row: true
    OpenAI connected (env source): true
    Anthropic not connected: true
    DeepSeek no login needed: true |}]

(* 2. [/login openai] skips the provider picker (argument fast-path) and opens
   the method picker; OpenAI declares three methods. *)
let%expect_test "login openai opens the method picker" =
  Project.with_temp "auth-methods" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/login openai";
  Term.wait t (Screen.has "/login openai");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Choose how to sign in.");
  let s = Term.screen t in
  print_fact "Browser method" (Screen.has "Browser" s);
  print_fact "device method" (Screen.has "device code" s);
  print_fact "API key method" (Screen.has "API key" s);
  [%expect
    {|
    Browser method: true
    device method: true
    API key method: true |}]

(* 3. The masked api-key entry (Anthropic is single-method -> straight to the
   borrow): typed chars render as bullets and NEVER as the key; an empty submit
   flashes; and the esc ladder steps back one rung (to the provider picker), then
   out to the composer with the draft restored. *)
let%expect_test "api-key input masks the buffer; esc walks the ladder" =
  Project.with_temp "auth-apikey" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/login anthropic";
  Term.wait t (Screen.has "/login anthropic");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Paste your Anthropic API key");
  (* Empty submit flashes, saves nothing. *)
  Term.send t Keys.enter;
  Term.wait t (Screen.has "enter a key");
  print_fact "empty-key flash" (Screen.has "enter a key" (Term.screen t));
  (* Type a secret; it renders as bullets, never as text. *)
  Term.send t "sk-secret-value-123";
  Term.wait t (Screen.has "\xe2\x80\xa2" (* • *));
  let s = Term.screen t in
  print_fact "bullets shown" (Screen.has "\xe2\x80\xa2" s);
  print_fact "secret NOT on screen" (Screen.lacks "sk-secret-value-123" s);
  (* Esc steps back one rung to the provider picker (the attempt is dropped, no
     secret written), then out to the composer. *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Choose a provider to authenticate.");
  print_fact "esc -> provider picker"
    (Screen.has "Choose a provider to authenticate." (Term.screen t));
  Term.send t Keys.escape;
  Term.wait t (Screen.has "message spice");
  print_fact "esc -> composer restored" (Screen.has "message spice" (Term.screen t));
  [%expect
    {|
    empty-key flash: true
    bullets shown: true
    secret NOT on screen: true
    esc -> provider picker: true
    esc -> composer restored: true |}]

(* 7. [/logout openai] on the home stage: OpenAI is the only connected provider,
   so logout runs directly (no picker) and — its credential being env-sourced,
   which logout cannot remove — settles. On the home stage the settled record is
   silent (no transcript to echo into, 09-auth Q3), so the observable effect is
   the panel closing back to the composer once the flow completes. *)
let%expect_test "logout runs and returns to the composer" =
  Project.with_temp "auth-logout-env" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/logout openai";
  Term.wait t (Screen.has "/logout openai");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "message spice");
  print_fact "logout completed, composer restored"
    (Screen.has "message spice" (Term.screen t));
  [%expect {| logout completed, composer restored: true |}]

(* 6. The browser flow panel (OpenAI's first method): the authorization URL is
   built locally (PKCE), so the panel renders with no network round-trip — the
   URL row, the spinner, and the headless device-code steer. [c] copies the
   display-safe URL; esc cancels the attempt (no secret written) and steps back
   to the method picker. The successful callback exchange and the 300 s timeout
   are cram-only (they need a real localhost redirect). *)
let%expect_test "browser flow renders, copies the url, and cancels" =
  Project.with_temp "auth-browser" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/login openai";
  Term.wait t (Screen.has "/login openai");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Choose how to sign in.");
  (* Browser is the first declared method — Enter selects it. *)
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Waiting for authorization");
  let s = Term.screen t in
  print_fact "browser title" (Screen.has "browser" s);
  print_fact "authorization url shown" (Screen.has "https://" s);
  print_fact "headless device-code steer" (Screen.has "device code" s);
  print_fact "spinner waiting" (Screen.has "Waiting for authorization" s);
  (* c copies the display-safe URL. *)
  Term.send t "c";
  Term.wait t (Screen.has "copied");
  print_fact "copied flash" (Screen.has "copied" (Term.screen t));
  (* Esc cancels the attempt and steps back to the method picker (esc ladder). *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Choose how to sign in.");
  print_fact "esc -> method picker"
    (Screen.has "Choose how to sign in." (Term.screen t));
  [%expect
    {|
    browser title: true
    authorization url shown: true
    headless device-code steer: true
    spinner waiting: true
    copied flash: true
    esc -> method picker: true |}]

(* 5. The device-code flow (OpenAI's ChatGPT device method) against a fake auth
   issuer. The usercode response scripts a long poll [interval], and the engine
   sleeps [interval]s before its first poll (login.ml), so the challenge stays up
   for assertions — no token/settle scripting needed. The panel renders the
   verification URL, the user code, the phishing warning, and the expiry; [c]
   copies the raw user code; esc cancels the attempt (no secret) back to the
   method picker. The poll/exchange/settle is cram-covered (auth/oauth.t). *)
let%expect_test "device-code renders the challenge, copies the code, cancels" =
  Project.with_temp "auth-device" @@ fun project ->
  let usercode =
    {|{"expect":{"request_line":"POST /api/accounts/deviceauth/usercode HTTP/1.1"},"http":{"status":200,"json":{"device_auth_id":"dev-1","user_code":"CODE-1234","expires_in":900,"interval":300}}}|}
  in
  Provider.with_script project ~script_lines:[ usercode ] @@ fun srv ->
  (* The auth issuer is the fake server's root (Provider appends [/v1] for the
     model API, which the auth reroot does not want). *)
  let auth_base =
    let b = Provider.base_url srv in
    String.sub b 0 (String.length b - String.length "/v1")
  in
  let env = env @ [ ("SPICE_OPENAI_AUTH_BASE_URL", auth_base) ] in
  (* The device panel is the tallest flow surface; give it room above the home
     stage so the phishing warning and the waiting line are not clipped. *)
  Term.run ~env ~rows:32 ~cols:80 project @@ fun t ->
  Term.send t "/login openai";
  Term.wait t (Screen.has "/login openai");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Choose how to sign in.");
  (* Filter to the device-code method, then select it. *)
  Term.send t "device";
  Term.wait t (Screen.has "enter a code on another device");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "CODE-1234");
  let s = Term.screen t in
  print_fact "device title" (Screen.has "device code" s);
  print_fact "user code shown" (Screen.has "CODE-1234" s);
  print_fact "phishing warning" (Screen.has "Never share this code" s);
  print_fact "expiry countdown" (Screen.has "expires in" s);
  print_fact "waiting" (Screen.has "Waiting for authorization" s);
  (* c copies the raw user code. *)
  Term.send t "c";
  Term.wait t (Screen.has "copied");
  print_fact "copied flash" (Screen.has "copied" (Term.screen t));
  (* Esc cancels and steps back to the method picker. *)
  Term.send t Keys.escape;
  Term.wait t (Screen.has "Choose how to sign in.");
  print_fact "esc -> method picker"
    (Screen.has "Choose how to sign in." (Term.screen t));
  [%expect
    {|
    device title: true
    user code shown: true
    phishing warning: true
    expiry countdown: true
    waiting: true
    copied flash: true
    esc -> method picker: true |}]

(* 8. Locked-model → login reroute (09-auth §9, B.4): open /model, filter to
   Anthropic's (locked, under the OpenAI-only env) Claude models, [↵] the
   highlighted locked row, and land in the login flow pre-selected on that
   provider — for single-method Anthropic that is straight to the api-key entry.
   Proves the model-panel `Login_required` arm reroutes rather than flashing. *)
let%expect_test "a locked model row reroutes to login pre-selected" =
  Project.with_temp "auth-model-reroute" @@ fun project ->
  run project ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "/model";
  Term.wait t (Screen.has "/model");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Default (recommended)");
  (* Filter to Anthropic's Claude models — locked under this env. *)
  Term.send t "claude";
  Term.wait t (Screen.has "log in to use");
  (* Enter on the highlighted locked row reroutes to the login flow. *)
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Paste your Anthropic API key");
  print_fact "locked row -> anthropic login pre-selected"
    (Screen.has "Paste your Anthropic API key" (Term.screen t));
  [%expect {| locked row -> anthropic login pre-selected: true |}]

(* 9. With NO provider connected the model line shows the registry-order
   default (openai/gpt-5.5). An api-key login makes Anthropic the only
   connected provider, so the derived default — and the rendered model line —
   flip to its default model without a restart: the login is the next
   binding's input, and the settle pushes the rebuilt snapshot. The provider
   base URL points at a closed port so the persist-then-check settles
   Unchecked immediately (saved, unvalidated) instead of reaching the real
   API; a saved-but-unchecked credential still counts as connected. *)
let%expect_test "api-key login flips the derived default model line" =
  Project.with_temp "auth-default-flip" @@ fun project ->
  (* SPICE_MODEL is unset — the harness default would CONFIGURE the model, and
     a configured selection never flips on login (that is the design); the
     derived default is what connectivity moves. *)
  let env =
    [
      ("SPICE_REDUCED_MOTION", "1");
      ("SPICE_ANTHROPIC_BASE_URL", "http://127.0.0.1:9/v1");
    ]
  in
  Term.run ~unset:[ "SPICE_MODEL" ] ~env ~rows:24 ~cols:80 project @@ fun t ->
  Term.wait t (Screen.has "dev \xc2\xb7 openai/gpt-5.5");
  print_fact "registry default before login"
    (Screen.has "dev \xc2\xb7 openai/gpt-5.5" (Term.screen t));
  (* Reach the api-key entry through the model panel's locked-row reroute (the
     [/login PROVIDER] arg-command path is exercised by test 2). *)
  Term.send t "/model";
  Term.wait t (Screen.has "/model");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Default (recommended)");
  Term.send t "claude";
  Term.wait t (Screen.has "log in to use");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Paste your Anthropic API key");
  Term.send t "sk-ant-test-key-1234";
  Term.wait t (Screen.has "\xe2\x80\xa2");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "dev \xc2\xb7 anthropic/claude-sonnet-4-6");
  print_fact "model line flips to the connected default"
    (Screen.has "dev \xc2\xb7 anthropic/claude-sonnet-4-6" (Term.screen t));
  [%expect
    {|
    registry default before login: true
    model line flips to the connected default: true |}]
