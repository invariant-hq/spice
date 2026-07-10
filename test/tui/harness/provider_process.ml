(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { base_url : string }

let base_url t = t.base_url

let with_script ?(unordered = false) ?delay_ms project script f =
  let script_path = Project.scratch project "openai-script.jsonl" in
  let capture_dir = Project.scratch project "openai-capture" in
  let port_file = Project.scratch project "openai-port" in
  let log = Project.scratch project "openai-server.log" in
  script
  |> List.map (Provider_script.to_process_line ?delay_ms)
  |> String.concat "\n"
  |> fun contents ->
  Project.write_path script_path (contents ^ "\n");
  let bin = Project.resolve_env_path "SPICE_FAKE_PROVIDER_BIN" in
  let argv =
    [|
      bin;
      "--script";
      script_path;
      "--capture";
      capture_dir;
      "--port-file";
      port_file;
      "--accept-timeout";
      "30";
    |]
  in
  let argv =
    if unordered then Array.append argv [| "--unordered" |] else argv
  in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let log_fd =
    Unix.openfile log [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o644
  in
  let pid =
    Unix.create_process_env bin argv
      (Project.env_array project)
      dev_null log_fd log_fd
  in
  Unix.close dev_null;
  Unix.close log_fd;
  let stop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] pid : int * Unix.process_status)
    | _ -> ()
    | exception Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:stop (fun () ->
      Project.wait_for_file port_file;
      let port = Project.read_path port_file |> String.trim in
      f { base_url = "http://127.0.0.1:" ^ port ^ "/v1" })

let with_openai ?(expect = [ "test" ]) project ~answer f =
  let script =
    [ Provider_script.message ~id:"resp-tui-answer" ~expect answer ]
  in
  with_script project script f
