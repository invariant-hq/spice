(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { base_url : string; capture_dir : string; log : string }

let base_url t = t.base_url
let capture_dir t = t.capture_dir
let log t = t.log

let response_line_json ?delay_ms ~id ~body_contains ~body_not_contains ~answer
    () =
  let body_not_contains =
    match body_not_contains with
    | [] -> ""
    | body_not_contains ->
        Printf.sprintf {|,"body_not_contains":[%s]|}
          (body_not_contains
          |> List.map (fun text -> Printf.sprintf "%S" text)
          |> String.concat ",")
  in
  let delay =
    match delay_ms with
    | None -> ""
    | Some delay_ms -> Printf.sprintf {|,"delay_ms":%d|} delay_ms
  in
  Printf.sprintf
    {|{"expect":{"request_line":"POST /v1/responses HTTP/1.1","body_contains":[%s]%s}%s,"response":{"id":%S,"status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":%S}]}]}}|}
    (body_contains
    |> List.map (fun text -> Printf.sprintf "%S" text)
    |> String.concat ",")
    body_not_contains delay id answer

let response_line ~id ~body_contains ~body_not_contains ~answer =
  response_line_json ~id ~body_contains ~body_not_contains ~answer ()

let delayed_response_line ~delay_ms ~id ~body_contains ~body_not_contains
    ~answer =
  response_line_json ~delay_ms ~id ~body_contains ~body_not_contains ~answer ()

let script_path project = Project.scratch project "openai-script.jsonl"
let port_file project = Project.scratch project "openai-port"
let fake_provider_bin () = Util.resolve_env_path "SPICE_FAKE_PROVIDER_BIN"

let with_script ?(unordered = false) project ~script_lines f =
  let script = script_path project in
  let capture_dir = Project.scratch project "openai-capture" in
  let port_file = port_file project in
  let log = Project.scratch project "openai-server.log" in
  Util.write_file script (String.concat "\n" script_lines ^ "\n");
  let bin = fake_provider_bin () in
  let argv =
    [|
      bin;
      "--script";
      script;
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
    Unix.create_process_env bin argv (Project.env project) dev_null log_fd
      log_fd
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
      Util.wait_for_file port_file;
      let port = Util.read_file port_file |> String.trim in
      f { base_url = "http://127.0.0.1:" ^ port ^ "/v1"; capture_dir; log })

let with_responses_unordered project script_lines f =
  with_script ~unordered:true project ~script_lines f

let with_openai ?(body_contains = [ "test" ]) project ~answer f =
  let line =
    response_line ~id:"resp-tui-answer" ~body_contains ~body_not_contains:[]
      ~answer
  in
  with_script project ~script_lines:[ line ] f

let with_responses project lines f = with_script project ~script_lines:lines f

let request_body t =
  let path = Filename.concat t.capture_dir "request-1.json" in
  Util.wait_for_file path;
  Util.read_file path

let print_debug t =
  Printf.printf "fake-log: %S\n"
    (if Sys.file_exists t.log then Util.read_file t.log else "<missing>");
  if Sys.file_exists t.capture_dir && Sys.is_directory t.capture_dir then
    Sys.readdir t.capture_dir |> Array.to_list |> List.sort String.compare
    |> List.iter (fun name ->
        let path = Filename.concat t.capture_dir name in
        Printf.printf "%s: %S\n" name (Util.read_file path))
