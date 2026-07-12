(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

let dune_environment =
  [ ("SPICE_REDUCED_MOTION", "1"); ("SPICE_WORKSPACE_TOOLING", "auto") ]

let print_fact label value = Printf.printf "%s: %b\n" label value

let disable_internal_dune_watch project =
  Project.write_scratch project "config/spice/config.json"
    {|{"notices":{"dune_diagnostics":false,"dune_build":false}}|}

let process_alive pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception Unix.Unix_error _ -> true

let fake_watching_dune project =
  let bin = Project.path project "fake-bin" in
  let pid_file = Project.scratch project "dune-watch.pid" in
  Unix.mkdir bin 0o700;
  let dune = Filename.concat bin "dune" in
  Project.write_path dune
    (Printf.sprintf
       "#!/bin/sh\nif [ \"$1\" = describe ]; then exit 1; fi\nprintf '%%s' \
        \"$$\" > %s\nwhile :; do sleep 1; done\n"
       (Filename.quote pid_file));
  Unix.chmod dune 0o700;
  (pid_file, ("PATH", bin ^ ":" ^ Sys.getenv "PATH") :: dune_environment)

let%expect_test "a real dune watch connects while home is open" =
  Project.with_git_fixture "dune-home" @@ fun project ->
  Project.write project "lib/code.ml" "let alpha = 1\nlet beta = 20\n";
  disable_internal_dune_watch project;
  Pty.run project ~trust:true ~env:dune_environment ~rows:24 @@ fun t ->
  Pty.wait t (Screen.has "diagnostics unavailable");
  print_fact "starts disconnected" (Screen.has "dune: ✗" (Pty.screen t));
  Project.with_external_dune_watch project @@ fun () ->
  Pty.wait ~deadline:40.0 t (Screen.has "build unknown");
  let screen = Pty.screen t in
  print_fact "home connects" (Screen.has "✓ · build unknown" screen);
  print_fact "footer connects" (Screen.has "dune: ✓" screen);
  [%expect
    {|
    starts disconnected: true
    home connects: true
    footer connects: true |}]

let%expect_test "tooling engages when a dune project appears mid-session" =
  Project.with_temp "dune-reprobe" @@ fun project ->
  (* The scaffold flow: launch in a directory with NO dune marker — [auto]
     must not engage at boot — then grow one mid-session. The footer heals
     through the loaders' latching probe on the health tick; the external
     watch stands in for the endpoint, as in the tests above. *)
  Sys.remove (Filename.concat (Project.root project) "dune-project");
  disable_internal_dune_watch project;
  Pty.run project ~trust:true ~env:dune_environment ~rows:24 @@ fun t ->
  Pty.wait t (Screen.has "diagnostics unavailable");
  print_fact "marker-less boot is disconnected"
    (Screen.has "dune: ✗" (Pty.screen t));
  Project.write project "dune-project" "(lang dune 3.0)\n(name fixture)\n";
  Project.with_external_dune_watch project @@ fun () ->
  Pty.wait ~deadline:40.0 t (Screen.has "dune: ✓");
  print_fact "footer heals after the marker appears"
    (Screen.has "dune: ✓" (Pty.screen t));
  [%expect
    {|
    marker-less boot is disconnected: true
    footer heals after the marker appears: true |}]

let%expect_test
    "a real dune watch connects during chat without a verdict notice" =
  Project.with_temp "dune-chat" @@ fun project ->
  disable_internal_dune_watch project;
  Provider_process.with_openai project ~answer:"Watching the build now."
    ~expect:[ "watch" ]
  @@ fun provider ->
  Pty.run project ~trust:true ~provider ~env:dune_environment ~rows:24 ~cols:80
  @@ fun t ->
  Pty.send t "watch the build";
  Pty.wait t (Screen.has "❯ watch the build");
  Pty.send t Key.enter;
  Pty.wait t (Screen.has "Watching the build now.");
  print_fact "chat starts disconnected" (Screen.has "dune: ✗" (Pty.screen t));
  Project.with_external_dune_watch project @@ fun () ->
  Pty.wait ~deadline:40.0 t (fun screen ->
      Screen.has "dune: ✓" screen && Screen.lacks "dune: ✗" screen);
  let screen = Pty.screen t in
  print_fact "chat connects" (Screen.has "dune: ✓" screen);
  print_fact "no unknown-verdict notice"
    (Screen.lacks "⊙ dune" screen
    && Screen.lacks "build broken" screen
    && Screen.lacks "build clean" screen);
  [%expect
    {|
    chat starts disconnected: true
    chat connects: true
    no unknown-verdict notice: true |}]

let%expect_test "switching from Build to Plan stops project execution" =
  Project.with_temp "dune-mode-owner" @@ fun project ->
  let pid_file, env = fake_watching_dune project in
  Provider_process.with_openai project ~answer:"Build turn complete."
    ~expect:[ "start project tooling" ]
  @@ fun provider ->
  Pty.run project ~trust:true ~provider ~env ~rows:24 ~cols:80 @@ fun t ->
  Pty.send t "start project tooling";
  Pty.send t Key.enter;
  Pty.wait t (fun screen ->
      Screen.has "Build turn complete." screen && Sys.file_exists pid_file);
  let pid =
    Project.read_scratch project "dune-watch.pid" |> String.trim
    |> int_of_string
  in
  print_fact "Build starts the project watcher" (process_alive pid);
  Pty.send t "/plan";
  Pty.send t Key.enter;
  Pty.wait t (fun screen ->
      Screen.has "plan mode on" screen && not (process_alive pid));
  print_fact "Plan stops the project watcher" (not (process_alive pid));
  Pty.quit t;
  [%expect
    {|
    Build starts the project watcher: true
    Plan stops the project watcher: true |}]

[%%run_tests "spice.tui-pty.dune-live"]
