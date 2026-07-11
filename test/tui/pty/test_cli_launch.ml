(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact label value = Printf.printf "%s: %b\n" label value

let seed_prompt_session ?(updated_at = 2) project id ~title ~prompt =
  Project.write_path
    (Project.data project
       (Filename.concat "sessions" (Filename.concat id "session.json")))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":%d},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"%s"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"max_steps":100,"declarations":[],"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id title (Project.root project) updated_at prompt)

let%expect_test "default launch enters the home stage" =
  Project.with_temp "cli-default" @@ fun project ->
  Pty.run project ~trust:true ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  let screen = Pty.screen t in
  print_fact "home composer rendered" (Screen.has "message spice" screen);
  print_fact "process remains interactive" (not (Pty.exited t));
  [%expect
    {|
    home composer rendered: true
    process remains interactive: true |}]

let run_resume_case name command expected unexpected =
  Project.with_temp name @@ fun project ->
  seed_prompt_session project "ses_older" ~title:"older session"
    ~prompt:"the older prompt";
  seed_prompt_session project "ses_newer" ~updated_at:9 ~title:"newer session"
    ~prompt:"the newer prompt";
  Pty.run project ~trust:true ~env:reduced_motion ~rows:24 ~cols:80 ~command
    ~ready:(Screen.has expected)
  @@ fun t ->
  let screen = Pty.screen t in
  print_fact "target replayed" (Screen.has expected screen);
  print_fact "other session excluded" (Screen.lacks unexpected screen)

let%expect_test "launch flags resolve and replay the requested session" =
  run_resume_case "cli-continue" [ "-c" ] "the newer prompt" "the older prompt";
  run_resume_case "cli-session"
    [ "--session"; "ses_older" ]
    "the older prompt" "the newer prompt";
  run_resume_case "cli-last" [ "resume"; "--last" ] "the newer prompt"
    "the older prompt";
  [%expect
    {|
    target replayed: true
    other session excluded: true
    target replayed: true
    other session excluded: true
    target replayed: true
    other session excluded: true |}]

let%expect_test "review launch opens directly and closes the process" =
  Project.with_git_fixture "cli-review" @@ fun project ->
  Project.write project "lib/code.ml"
    "let alpha = 1\nlet beta = 2\nlet gamma = 33\nlet delta = 4\n";
  Pty.run project ~trust:true ~rows:24 ~cols:80 ~env:reduced_motion
    ~command:[ "review" ]
    ~ready:(Screen.has "0/1 reviewed")
  @@ fun t ->
  let screen = Pty.screen t in
  print_fact "review screen at launch" (Screen.has "0/1 reviewed" screen);
  print_fact "home stage skipped" (Screen.lacks "message spice" screen);
  Pty.send t Key.escape;
  Pty.wait_exit t;
  print_fact "close exits" (Pty.exited t);
  [%expect
    {|
    review screen at launch: true
    home stage skipped: true
    close exits: true |}]

let%expect_test "review Git runs through workspace confinement" =
  Project.with_git_fixture "cli-review-sandbox" @@ fun project ->
  Project.write project "lib/code.ml" "let answer = 43\n";
  let real_git =
    match Sys.getenv_opt "PATH" with
    | None -> failwith "PATH is unavailable"
    | Some _ -> (
        let channel = Unix.open_process_in "command -v git" in
        Fun.protect
          ~finally:(fun () -> ignore (Unix.close_process_in channel))
          (fun () -> input_line channel))
  in
  let bin = Project.path project ".spice/fake-bin" in
  let fake_git = Filename.concat bin "git" in
  let marker = Project.scratch project "config/spice/git-escaped" in
  Project.write_path fake_git
    (Printf.sprintf
       "#!/bin/sh\nprintf escaped > \"$GIT_ESCAPE_MARKER\" 2>/dev/null || true\nexec %s \"$@\"\n"
       (Filename.quote real_git));
  Unix.chmod fake_git 0o700;
  let env =
    [
      ("PATH", bin ^ ":" ^ Sys.getenv "PATH");
      ("GIT_ESCAPE_MARKER", marker);
      ("SPICE_REDUCED_MOTION", "1");
      ("SPICE_SANDBOX_MODE", "workspace-write");
    ]
  in
  Pty.run project ~trust:true ~rows:24 ~cols:80 ~env ~command:[ "review" ]
    ~ready:(Screen.has "0/1 reviewed")
  @@ fun t ->
  print_fact "review loaded" (Screen.has "0/1 reviewed" (Pty.screen t));
  print_fact "Git could not escape confinement" (not (Sys.file_exists marker));
  Pty.send t Key.escape;
  Pty.wait_exit t;
  [%expect
    {|
    review loaded: true
    Git could not escape confinement: true |}]

[%%run_tests "spice.tui-pty.cli-launch"]
