(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_pty_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

let%expect_test "raw OSC output tracks idle and working titles" =
  Project.with_temp "terminal-title" @@ fun project ->
  let response =
    Provider.delayed_response_line ~delay_ms:500 ~id:"resp-title"
      ~body_contains:[ "title" ] ~body_not_contains:[]
      ~answer:"Title transition complete."
  in
  Provider.with_responses project [ response ] @@ fun provider ->
  Term.run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  let leaf = Filename.basename (Project.root project) in
  let idle = "\027]0;✳ " ^ leaf ^ "\027\\" in
  Term.wait_raw t (fun raw -> Util.contains raw idle);
  Term.send t "show the title";
  Term.wait t (Screen.has "❯ show the title");
  Term.send t Keys.enter;
  Term.wait_raw t (fun raw ->
      Util.contains raw ("\027]0;⠂ " ^ leaf ^ "\027\\")
      || Util.contains raw ("\027]0;⠐ " ^ leaf ^ "\027\\"));
  Term.wait t (Screen.has "Title transition complete.");
  print_fact "idle title emitted" (Util.contains (Term.raw t) idle);
  print_fact "working title emitted"
    (Util.contains (Term.raw t) ("\027]0;⠂ " ^ leaf ^ "\027\\")
    || Util.contains (Term.raw t) ("\027]0;⠐ " ^ leaf ^ "\027\\"));
  Term.quit t;
  [%expect
    {|
    idle title emitted: true
    working title emitted: true |}]

let%expect_test "a PTY resize delivers SIGWINCH and reflows review" =
  Project.with_git_fixture "terminal-resize" @@ fun project ->
  Project.write project "lib/code.ml"
    "let alpha = 1\nlet beta = 2\nlet gamma = 33\nlet delta = 4\n";
  Term.run project ~env:reduced_motion ~rows:24 ~cols:100 ~command:[ "review" ]
    ~ready:(Screen.has "0/1 reviewed")
  @@ fun t ->
  print_fact "wide review is split" (Screen.has "│" (Term.screen t));
  Term.resize t ~rows:24 ~cols:60;
  Term.wait t (fun screen ->
      Screen.has "code.ml" screen && Screen.lacks "│" screen);
  print_fact "narrow review collapses" (Screen.lacks "│" (Term.screen t));
  Term.send t Keys.escape;
  Term.wait_exit t;
  [%expect
    {|
    wide review is split: true
    narrow review collapses: true |}]

let%expect_test "terminal settings are restored after exit" =
  Project.with_temp "terminal-stty" @@ fun project ->
  let before = Project.scratch project "stty-before" in
  let after = Project.scratch project "stty-after" in
  let script =
    {|
before=$(stty -g) || exit 70
printf '%s\n' "$before" > "$SPICE_STTY_BEFORE"
"$SPICE_UNDER_TEST" --cwd "$SPICE_TEST_CWD"
status=$?
after=$(stty -g) || exit 71
printf '%s\n' "$after" > "$SPICE_STTY_AFTER"
exit "$status"
|}
  in
  Term.run_shell project ~script
    ~env:
      (reduced_motion
      @ [
          ("SPICE_STTY_BEFORE", before);
          ("SPICE_STTY_AFTER", after);
          ("SPICE_UNDER_TEST", Term.spice_bin ());
          ("SPICE_TEST_CWD", Project.root project);
        ])
  @@ fun t ->
  Term.quit t;
  let before_mode = Util.read_file before |> String.trim in
  let after_mode = Util.read_file after |> String.trim in
  print_fact "stty mode restored" (String.equal before_mode after_mode);
  [%expect {| stty mode restored: true |}]

[%%run_tests "spice.tui-pty.terminal"]
