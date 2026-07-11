(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact label value = Printf.printf "%s: %b\n" label value

let%expect_test "raw OSC output tracks idle and working titles" =
  Project.with_temp "terminal-title" @@ fun project ->
  let script =
    [
      Provider_script.message ~id:"resp-title" ~expect:[ "title" ]
        "Title transition complete.";
    ]
  in
  Provider_process.with_script ~delay_ms:500 project script @@ fun provider ->
  Pty.run project ~trust:true ~provider ~env:reduced_motion ~rows:24 ~cols:80
  @@ fun t ->
  let leaf = Filename.basename (Project.root project) in
  let idle = "\027]0;✳ " ^ leaf ^ "\027\\" in
  Pty.wait_raw t (fun raw -> Screen.contains raw idle);
  Pty.send t "show the title";
  Pty.wait t (Screen.has "❯ show the title");
  Pty.send t Key.enter;
  Pty.wait_raw t (fun raw ->
      Screen.contains raw ("\027]0;⠂ " ^ leaf ^ "\027\\")
      || Screen.contains raw ("\027]0;⠐ " ^ leaf ^ "\027\\"));
  Pty.wait t (Screen.has "Title transition complete.");
  print_fact "idle title emitted" (Screen.contains (Pty.raw t) idle);
  print_fact "working title emitted"
    (Screen.contains (Pty.raw t) ("\027]0;⠂ " ^ leaf ^ "\027\\")
    || Screen.contains (Pty.raw t) ("\027]0;⠐ " ^ leaf ^ "\027\\"));
  Pty.quit t;
  [%expect {|
    idle title emitted: true
    working title emitted: true |}]

let%expect_test "a PTY resize delivers SIGWINCH and reflows review" =
  Project.with_git_fixture "terminal-resize" @@ fun project ->
  Project.write project "lib/code.ml"
    "let alpha = 1\nlet beta = 2\nlet gamma = 33\nlet delta = 4\n";
  Pty.run project ~trust:true ~env:reduced_motion ~rows:24 ~cols:100
    ~command:[ "review" ]
    ~ready:(Screen.has "0/1 reviewed")
  @@ fun t ->
  print_fact "wide review is split" (Screen.has "│" (Pty.screen t));
  Pty.resize t ~rows:24 ~cols:60;
  Pty.wait t (fun screen ->
      Screen.has "code.ml" screen && Screen.lacks "│" screen);
  print_fact "narrow review collapses" (Screen.lacks "│" (Pty.screen t));
  Pty.send t Key.escape;
  Pty.wait_exit t;
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
  Pty.run_shell project ~trust:true ~script
    ~env:
      (reduced_motion
      @ [
          ("SPICE_STTY_BEFORE", before);
          ("SPICE_STTY_AFTER", after);
          ("SPICE_UNDER_TEST", Pty.spice_bin ());
          ("SPICE_TEST_CWD", Project.root project);
        ])
  @@ fun t ->
  Pty.quit t;
  let before_mode = Project.read_path before |> String.trim in
  let after_mode = Project.read_path after |> String.trim in
  print_fact "stty mode restored" (String.equal before_mode after_mode);
  [%expect {| stty mode restored: true |}]

[%%run_tests "spice.tui-pty.terminal"]
