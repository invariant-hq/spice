(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

let prompt_ready = Screen.has "Spice repository activation"
let print_fact label value = Printf.printf "%s: %b\n" label value
let trust_store project = Project.scratch project "config/spice/trust.json"

let store_has project status =
  let path = trust_store project in
  Sys.file_exists path
  && Screen.contains (Project.read_scratch project "config/spice/trust.json")
       (Printf.sprintf "\":\"%s\"" status)

let run_unknown project f =
  Pty.run project ~trust:false ~rows:24 ~cols:90 ~ready:prompt_ready f

let fake_dune_environment project =
  let bin = Project.path project "fake-bin" in
  let marker = Project.scratch project "dune-spawned" in
  Unix.mkdir bin 0o700;
  let dune = Filename.concat bin "dune" in
  Project.write_path dune
    (Printf.sprintf "#!/bin/sh\nprintf spawned > %s\nexit 1\n"
       (Filename.quote marker));
  Unix.chmod dune 0o700;
  ( marker,
    [
      ("PATH", bin ^ ":" ^ Sys.getenv "PATH");
      ("SPICE_WORKSPACE_TOOLING", "auto");
    ] )

let%expect_test "Enter accepts the safe restricted default" =
  Project.with_temp "trust-default" @@ fun project ->
  run_unknown project @@ fun t ->
  Pty.wait t (Screen.has "Selection: 1");
  print_fact "safe choice selected"
    (Screen.has "Selection: 1" (Pty.screen t));
  Pty.send t "\r";
  Pty.wait t (Screen.has "dune:");
  print_fact "explicit untrusted stored" (store_has project "untrusted");
  print_fact "decision remains in scrollback"
    (Screen.contains (Pty.raw t) "Repository remains restricted");
  Pty.quit t;
  [%expect
    {|
    safe choice selected: true
    explicit untrusted stored: true
    decision remains in scrollback: true |}]

let%expect_test "numeric shortcut 1 remembers the restricted choice" =
  Project.with_temp "trust-number-1" @@ fun project ->
  run_unknown project @@ fun t ->
  Pty.send t "1";
  Pty.wait t (Screen.has "dune:");
  print_fact "explicit untrusted stored" (store_has project "untrusted");
  Pty.quit t;
  [%expect {| explicit untrusted stored: true |}]

let%expect_test "arrow navigation can trust and continue" =
  Project.with_temp "trust-arrows" @@ fun project ->
  let marker, env = fake_dune_environment project in
  Provider_process.with_openai project ~answer:"Trusted turn complete."
    ~expect:[ "start after trust" ]
  @@ fun provider ->
  Pty.run project ~trust:false ~provider ~env ~rows:24 ~cols:90
    ~ready:prompt_ready
  @@ fun t ->
  print_fact "no project process before consent" (not (Sys.file_exists marker));
  Pty.send t "\027[B";
  Pty.wait t (Screen.has "Selection: 2");
  Pty.send t "\r";
  Pty.wait t (Screen.has "dune:");
  print_fact "project process remains deferred" (not (Sys.file_exists marker));
  Pty.send t "start after trust\r";
  Pty.wait t (fun _ -> Sys.file_exists marker);
  print_fact "trusted stored" (store_has project "trusted");
  print_fact "project process starts under first turn" (Sys.file_exists marker);
  print_fact "trusted decision remains in scrollback"
    (Screen.contains (Pty.raw t) "Repository activation is enabled");
  Pty.quit t;
  [%expect
    {|
    no project process before consent: true
    project process remains deferred: true
    trusted stored: true
    project process starts under first turn: true
    trusted decision remains in scrollback: true |}]

let exit_without_store name input =
  Project.with_temp name @@ fun project ->
  run_unknown project @@ fun t ->
  Pty.send t input;
  Pty.wait_exit t;
  ( (not (Sys.file_exists (trust_store project))),
    not (Sys.file_exists (Project.data project "sessions")),
    Screen.contains (Pty.raw t)
      "Exited without saving a workspace trust decision" )

let%expect_test "exit inputs save nothing and create no session" =
  let digit_store, digit_session, digit_message =
    exit_without_store "trust-exit-3" "3"
  in
  let escape_store, escape_session, escape_message =
    exit_without_store "trust-exit-esc" "\027"
  in
  let ctrl_c_store, ctrl_c_session, ctrl_c_message =
    exit_without_store "trust-exit-ctrl-c" "\003"
  in
  let eof_store, eof_session, eof_message =
    exit_without_store "trust-exit-eof" "\004"
  in
  print_fact "digit 3 exits cleanly"
    (digit_store && digit_session && digit_message);
  print_fact "Escape exits cleanly"
    (escape_store && escape_session && escape_message);
  print_fact "Ctrl+C exits cleanly"
    (ctrl_c_store && ctrl_c_session && ctrl_c_message);
  print_fact "EOF exits cleanly" (eof_store && eof_session && eof_message);
  [%expect
    {|
    digit 3 exits cleanly: true
    Escape exits cleanly: true
    Ctrl+C exits cleanly: true
    EOF exits cleanly: true |}]

let%expect_test "a persistence failure stays in preflight and can retry" =
  Project.with_temp "trust-retry" @@ fun project ->
  run_unknown project @@ fun t ->
  let config = Project.scratch project "config/spice" in
  let lock = Filename.concat config "trust.json.lock" in
  Unix.mkdir config 0o700;
  Unix.mkdir lock 0o700;
  Pty.send t "2";
  Pty.wait t (Screen.has "Could not save the decision");
  print_fact "normal app not started after failure"
    (Screen.lacks "dune:" (Pty.screen t));
  Unix.rmdir lock;
  Pty.send t "2";
  Pty.wait t (Screen.has "dune:");
  print_fact "retry stores trusted" (store_has project "trusted");
  Pty.quit t;
  [%expect
    {|
    normal app not started after failure: true
    retry stores trusted: true |}]

let%expect_test "failed trusted activation rolls back and can retry" =
  Project.with_temp "trust-activation-rollback" @@ fun project ->
  run_unknown project @@ fun t ->
  let config = Project.scratch project "config/spice" in
  Unix.mkdir config 0o700;
  Project.write_scratch project "config/spice/config.json"
    "{\"web\":{\"timeout_ms\":2,\"max_timeout_ms\":1}}\n";
  Pty.send t "2";
  Pty.wait t (Screen.has "returned to restricted mode");
  print_fact "trusted activation rolled back" (store_has project "untrusted");
  print_fact "normal app not started after activation failure"
    (Screen.lacks "dune:" (Pty.screen t));
  Unix.unlink (Project.scratch project "config/spice/config.json");
  Pty.send t "2";
  Pty.wait t (Screen.has "dune:");
  print_fact "retry stores trusted" (store_has project "trusted");
  Pty.quit t;
  [%expect
    {|
    trusted activation rolled back: true
    normal app not started after activation failure: true
    retry stores trusted: true |}]

[%%run_tests "spice.tui-pty.trust-prompt"]
