(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_pty_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

let disable_internal_dune_watch project =
  Util.write_file (Project.scratch project "config/spice/config.json")
    {|{"notices":{"dune_diagnostics":false,"dune_build":false}}|}

let%expect_test "a real dune watch connects while home is open" =
  Project.with_git_fixture "dune-home" @@ fun project ->
  Project.write project "lib/code.ml" "let alpha = 1\nlet beta = 20\n";
  disable_internal_dune_watch project;
  Term.run project ~env:reduced_motion ~rows:24 @@ fun t ->
  Term.wait t (Screen.has "diagnostics unavailable");
  print_fact "starts disconnected" (Screen.has "dune: ✗" (Term.screen t));
  Project.with_external_dune_watch project @@ fun () ->
  Term.wait ~deadline:40.0 t (Screen.has "build unknown");
  let screen = Term.screen t in
  print_fact "home connects" (Screen.has "✓ · build unknown" screen);
  print_fact "footer connects" (Screen.has "dune: ✓" screen);
  [%expect
    {|
    starts disconnected: true
    home connects: true
    footer connects: true |}]

let%expect_test "a real dune watch connects during chat without a verdict notice" =
  Project.with_temp "dune-chat" @@ fun project ->
  disable_internal_dune_watch project;
  Provider.with_openai project ~answer:"Watching the build now."
    ~body_contains:[ "watch" ]
  @@ fun provider ->
  Term.run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.send t "watch the build";
  Term.wait t (Screen.has "❯ watch the build");
  Term.send t Keys.enter;
  Term.wait t (Screen.has "Watching the build now.");
  print_fact "chat starts disconnected" (Screen.has "dune: ✗" (Term.screen t));
  Project.with_external_dune_watch project @@ fun () ->
  Term.wait ~deadline:40.0 t (fun screen ->
      Screen.has "dune: ✓" screen && Screen.lacks "dune: ✗" screen);
  let screen = Term.screen t in
  print_fact "chat connects" (Screen.has "dune: ✓" screen);
  print_fact "no unknown-verdict notice"
    (Screen.lacks "⊙ dune" screen && Screen.lacks "build broken" screen
   && Screen.lacks "build clean" screen);
  [%expect
    {|
    chat starts disconnected: true
    chat connects: true
    no unknown-verdict notice: true |}]

[%%run_tests "spice.tui-pty.dune-live"]
