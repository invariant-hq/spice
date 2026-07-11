(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Access = Spice_permission.Access
module Json = Jsont.Json
module Request = Spice_permission.Request
module Shell = Spice_tools.Shell
module Tool = Spice_tool
module Workspace = Spice_workspace

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let print_case name = Printf.printf "-- %s --\n" name

let abs path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error ->
      failf "invalid absolute test path %S: %s" path
        (Spice_path.Error.message error)

let path root rel = Filename.concat root rel

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stats -> (
      match stats.Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path
          |> Array.iter (fun name ->
              if (not (String.equal name ".")) && not (String.equal name "..")
              then rm_rf (Filename.concat path name));
          Unix.rmdir path
      | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Unix.unlink path)

let mkdir_p dir =
  let rec loop dir =
    if Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  loop dir

let write_disk file contents =
  mkdir_p (Filename.dirname file);
  let oc = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc contents;
      flush oc)

let with_temp_dir f =
  let dir = Filename.temp_file "spice-shell-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let with_fixture f =
  with_temp_dir @@ fun root ->
  let outside = Filename.temp_file "spice-shell-outside-" ".tmp" in
  Unix.unlink outside;
  Unix.mkdir outside 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf outside)
    (fun () ->
      Unix.mkdir (path root "subject") 0o755;
      Unix.mkdir (path root "subject/nested") 0o755;
      write_disk (path root "file.txt") "not a directory\n";
      Unix.symlink "subject" (path root "subject_link");
      Unix.symlink outside (path root "outside_link");
      let workspace = Workspace.single (Workspace.Root.make (abs root)) in
      Eio_main.run @@ fun env ->
      f ~root ~outside ~fs:(Eio.Stdenv.fs env) ~workspace)

let input ?workdir ?timeout_ms ?description ?escalate command =
  Shell.Input.make ?workdir ?timeout_ms ?description ?escalate command

let unconfined ?default_timeout_ms ?max_timeout_ms ?max_output_bytes
    ?(environment = []) () =
  Shell.Config.make ?default_timeout_ms ?max_timeout_ms ?max_output_bytes
    ~sandbox:(Spice_sandbox.seal Spice_sandbox.Spec.Unconfined)
    ~environment ()

let normalize_paths ?root ?outside message =
  let replace_one ~by pattern message =
    if String.is_empty pattern then message
    else String.replace_all ~sub:pattern ~by message
  in
  let message =
    match root with
    | None -> message
    | Some root ->
        let real_root =
          match Unix.realpath root with
          | path -> path
          | exception Unix.Unix_error _ -> root
        in
        message
        |> replace_one ~by:"<root>" real_root
        |> replace_one ~by:"<root>" root
  in
  match outside with
  | None -> message
  | Some outside ->
      let real_outside =
        match Unix.realpath outside with
        | path -> path
        | exception Unix.Unix_error _ -> outside
      in
      message
      |> replace_one ~by:"<outside>" real_outside
      |> replace_one ~by:"<outside>" outside

let stream ?root ?outside = function
  | Shell.Output.Complete text ->
      Printf.sprintf "complete %S" (normalize_paths ?root ?outside text)
  | Shell.Output.Truncated { head; tail; omitted_bytes } ->
      Printf.sprintf "truncated head=%S tail=%S omitted=%d"
        (normalize_paths ?root ?outside head)
        (normalize_paths ?root ?outside tail)
        omitted_bytes

let output_status ?root ?outside = function
  | Shell.Output.Exited code -> Printf.sprintf "exited %d" code
  | Shell.Output.Signaled signal -> Printf.sprintf "signaled %d" signal
  | Shell.Output.Timed_out { timeout_ms } ->
      Printf.sprintf "timed_out %dms" timeout_ms
  | Shell.Output.Cancelled -> "cancelled"
  | Shell.Output.Failed_to_start message ->
      Printf.sprintf "failed_to_start %S"
        (normalize_paths ?root ?outside message)

let enforcement = function
  | Spice_sandbox.Evidence.Not_requested -> "not_requested"
  | Spice_sandbox.Evidence.Enforced { backend; profile } ->
      Printf.sprintf "enforced backend=%s hash=%s" backend
        (Spice_digest.to_hex profile)
  | Spice_sandbox.Evidence.Refused reason ->
      "refused " ^ Spice_sandbox.Error.message reason
  | Spice_sandbox.Evidence.Declared_external -> "declared_external"

let description = function None -> "-" | Some description -> description

let print_output ?root ?outside output =
  Printf.printf "output status: %s\n"
    (output_status ?root ?outside (Shell.Output.status output));
  Printf.printf "workdir: %s\n"
    (Workspace.Path.display (Shell.Output.workdir output));
  Printf.printf "limits: timeout=%d max_output=%d description=%s\n"
    (Shell.Output.timeout_ms output)
    (Shell.Output.max_output_bytes output)
    (description (Shell.Output.description output));
  Printf.printf "sandbox: %s\n" (enforcement (Shell.Output.enforcement output));
  Printf.printf "stdout: %s\n"
    (stream ?root ?outside (Shell.Output.stdout output));
  Printf.printf "stderr: %s\n"
    (stream ?root ?outside (Shell.Output.stderr output))

let print_result ?root ?outside result =
  begin match Tool.Result.status result with
  | Tool.Result.Completed -> Printf.printf "completed\n"
  | Tool.Result.Failed { kind; message; metadata } ->
      ignore metadata;
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        (normalize_paths ?root ?outside message)
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "interrupted cancelled=%b: %s\n" cancelled reason
  end;
  match Tool.Result.output result with
  | None -> Printf.printf "output: none\n"
  | Some output -> print_output ?root ?outside output

let run ?root ?outside ~fs ~workspace ~config ?cancelled input =
  Shell.run ~fs ~workspace ~config ?cancelled input
  |> print_result ?root ?outside

let print_decode label json =
  let status =
    match Shell.Input.decode json with
    | Error _ -> "error"
    | Ok input ->
        Printf.sprintf "ok command=%S workdir=%s timeout=%s description=%s"
          (Shell.Input.command input)
          (Option.value ~default:"-" (Shell.Input.workdir input))
          (match Shell.Input.timeout_ms input with
          | None -> "-"
          | Some timeout_ms -> string_of_int timeout_ms)
          (description (Shell.Input.description input))
  in
  Printf.printf "%s: %s\n" label status

let print_invalid label make =
  match make () with
  | _ -> Printf.printf "%s: accepted\n" label
  | exception Invalid_argument message ->
      Printf.printf "%s: invalid %s\n" label message

let print_resolved_timeout label config timeout_ms =
  match Shell.Config.resolve_timeout_ms config timeout_ms with
  | Ok timeout_ms -> Printf.printf "%s: ok %d\n" label timeout_ms
  | Error message -> Printf.printf "%s: error %s\n" label message

let relative_display ?root ?outside text =
  let text = normalize_paths ?root ?outside text in
  let root_prefix = "<root>/" in
  if String.equal text "<root>" then "."
  else if String.starts_with ~prefix:root_prefix text then
    String.drop_first (String.length root_prefix) text
  else text

let workspace_scope_display relative =
  if Spice_path.Rel.is_root relative then "."
  else Spice_path.Rel.to_string relative

let cwd ?root ?outside = function
  | None -> "-"
  | Some (Access.Path_scope.Workspace { relative; _ }) ->
      relative |> workspace_scope_display |> relative_display ?root ?outside
  | Some (Access.Path_scope.Outside_workspace path) ->
      Format.asprintf "outside:%a" Spice_path.Abs.pp path
      |> relative_display ?root ?outside
  | Some (Access.Path_scope.Unknown path) -> "unknown:" ^ path

let argv_text argv = String.concat " " (List.map (Printf.sprintf "%S") argv)

let access ?root ?outside = function
  | Access.Command
      (Access.Command.Argv { program; args; cwd = access_cwd; _ }) ->
      Printf.sprintf "exec cwd=%s argv=%s"
        (cwd ?root ?outside access_cwd)
        (argv_text (program :: args))
  | Access.Command (Access.Command.Shell { text; cwd = access_cwd; _ }) ->
      Printf.sprintf "shell cwd=%s command=%S"
        (cwd ?root ?outside access_cwd)
        text
  | Access.Path { op; scope } -> (
      ignore scope;
      match op with
      | `Read -> "path read"
      | `Create -> "path create"
      | `Modify -> "path modify"
      | `Delete -> "path delete")
  | Access.Network _ -> "network"
  | Access.Custom { name; subject; _ } ->
      "extension " ^ name
      ^ Option.fold ~none:"" ~some:(fun subject -> " " ^ subject) subject

let print_permissions ?root ?outside ?config workspace input =
  let config =
    match config with Some config -> config | None -> unconfined ()
  in
  match Shell.permissions ~workspace ~config input with
  | [] -> Printf.printf "requests: none\n"
  | requests ->
      Printf.printf "requests: %d\n" (List.length requests);
      List.iter
        (fun request ->
          Printf.printf "source: %s\n"
            (Option.value ~default:"-" (Request.source request));
          Request.accesses request
          |> List.iter (fun item ->
              Printf.printf "access: %s\n" (access ?root ?outside item)))
        requests

let line_with prefix text =
  String.split_on_char '\n' text
  |> List.find_opt (String.starts_with ~prefix)
  |> Option.value ~default:("<missing " ^ prefix ^ ">")

let json_member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_string = function
  | Jsont.String (text, _) -> Some text
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Array _
  | Jsont.Object _ ->
      None

let%expect_test "input and config validation" =
  print_decode "minimal" (json_obj [ ("command", Json.string "pwd") ]);
  print_decode "full"
    (json_obj
       [
         ("command", Json.string "pwd");
         ("workdir", Json.string "subject");
         ("timeout_ms", Json.int 250);
         ("description", Json.string "show directory");
       ]);
  print_decode "unknown field"
    (json_obj [ ("command", Json.string "pwd"); ("extra", Json.bool true) ]);
  print_decode "empty command" (json_obj [ ("command", Json.string "") ]);
  print_invalid "nul workdir" (fun () ->
      Shell.Input.make ~workdir:"bad\000path" "pwd");
  print_invalid "zero timeout" (fun () -> Shell.Input.make ~timeout_ms:0 "pwd");
  print_invalid "empty description" (fun () ->
      Shell.Input.make ~description:"" "pwd");
  print_invalid "empty shell" (fun () -> Shell.Config.make ~shell:"" ());
  print_invalid "bad env name" (fun () ->
      Shell.Config.make ~environment:[ ("BAD=NAME", Some "1") ] ());
  print_invalid "bad env value" (fun () ->
      Shell.Config.make ~environment:[ ("BAD", Some "x\000y") ] ());
  print_invalid "bad timeout bounds" (fun () ->
      Shell.Config.make ~default_timeout_ms:20 ~max_timeout_ms:10 ());
  print_invalid "bad output bound" (fun () ->
      Shell.Config.make ~max_output_bytes:(-1) ());
  let config = Shell.Config.make ~default_timeout_ms:10 ~max_timeout_ms:20 () in
  print_resolved_timeout "default timeout" config None;
  print_resolved_timeout "capped timeout" config (Some 30);
  [%expect
    {|
    minimal: ok command="pwd" workdir=- timeout=- description=-
    full: ok command="pwd" workdir=subject timeout=250 description=show directory
    unknown field: error
    empty command: error
    nul workdir: invalid workdir must not contain NUL
    zero timeout: invalid timeout_ms must be positive
    empty description: invalid description must not be empty
    empty shell: invalid shell must not be empty
    bad env name: invalid environment name must not contain =
    bad env value: invalid environment value must not contain NUL
    bad timeout bounds: invalid default_timeout_ms must be <= max_timeout_ms
    bad output bound: invalid max_output_bytes must be non-negative
    default timeout: ok 10
    capped timeout: error timeout_ms must be <= 20 |}]

let%expect_test "default restricted sandbox refuses instead of spawning" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config = Shell.Config.make ~default_timeout_ms:100 () in
  run ~root ~outside ~fs ~workspace ~config
    (input ~description:"should not spawn" "printf 'unexpected\\n'");
  [%expect
    {|
    failed unavailable: no sandbox backend configured
    output status: failed_to_start "no sandbox backend configured"
    workdir: .
    limits: timeout=100 max_output=65536 description=should not spawn
    sandbox: refused no sandbox backend configured
    stdout: complete ""
    stderr: complete "" |}]

let fake_backend =
  Spice_sandbox.Backend.make ~id:"fake"
    ~available:(fun () -> Ok ())
    ~prepare:(fun _policy ->
      Ok
        (Spice_sandbox.Backend.prepared ~prefix:[]
           ~profile:(Spice_digest.string "canonical")))
    ()

let%expect_test "confined command reports enforced evidence and strips env" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  Unix.putenv "SPICE_EXPECT_FAKE_TOKEN" "tok-value";
  let sandbox =
    Spice_sandbox.seal ~backend:fake_backend
      (Spice_sandbox.Spec.Confined
         Spice_sandbox.Confinement.(read_only |> writable [ abs root ]))
  in
  let config = Shell.Config.make ~sandbox () in
  run ~root ~outside ~fs ~workspace ~config
    (input "echo ${SPICE_EXPECT_FAKE_TOKEN:-stripped}");
  [%expect
    {|
    completed
    output status: exited 0
    workdir: .
    limits: timeout=60000 max_output=65536 description=-
    sandbox: enforced backend=fake hash=0deeb8fa1dbbee4c0dbe7f5e3c9183940139f26d22797ee8ab07c00557a4c2ff
    stdout: complete "stripped\n"
    stderr: complete "" |}]

let workspace_write_config ~root =
  Shell.Config.make
    ~sandbox:
      (Spice_sandbox.seal ~backend:fake_backend
         (Spice_sandbox.Spec.Confined
            Spice_sandbox.Confinement.(read_only |> writable [ abs root ])))
    ()

let read_only_config =
  Shell.Config.make
    ~sandbox:
      (Spice_sandbox.seal ~backend:fake_backend
         (Spice_sandbox.Spec.Confined Spice_sandbox.Confinement.read_only))
    ()

let%expect_test "escalation raises a distinct reviewable access" =
  with_fixture @@ fun ~root ~outside:_ ~fs:_ ~workspace ->
  let escalating = input ~escalate:true "git commit -m fix" in
  print_permissions ~root
    ~config:(workspace_write_config ~root)
    workspace escalating;
  [%expect
    {|
    requests: 1
    source: shell
    access: exec cwd=. argv="git" "commit" "-m" "fix"
    access: extension shell.escalate git commit -m fix |}];
  (* Read-only confinement raises no escalation access: the run path refuses
     the input before any permission flow. *)
  print_permissions ~root ~config:read_only_config workspace escalating;
  [%expect
    {|
    requests: 1
    source: shell
    access: exec cwd=. argv="git" "commit" "-m" "fix" |}];
  (* Unconfined decisions ignore the flag: it requests what is already
     true. *)
  print_permissions ~root workspace escalating;
  [%expect
    {|
    requests: 1
    source: shell
    access: exec cwd=. argv="git" "commit" "-m" "fix" |}]

let%expect_test "spoofable command syntax degrades to a coarse shell match" =
  with_fixture @@ fun ~root ~outside:_ ~fs:_ ~workspace ->
  (* A plain command classifies confidently as an argv access the policy can
     key on by program and prefix. *)
  print_permissions ~root workspace (input "rm data.txt");
  (* A leading assignment, a glob, or a tilde-expanded program each make the
     shell exec something other than the parsed words, so they degrade to the
     whole-string shell match rather than a spoofable argv. *)
  print_permissions ~root workspace (input "FOO=1 rm data.txt");
  print_permissions ~root workspace (input "rm *.log");
  print_permissions ~root workspace (input "~/bin/tool run");
  [%expect
    {|
    requests: 1
    source: shell
    access: exec cwd=. argv="rm" "data.txt"
    requests: 1
    source: shell
    access: shell cwd=. command="FOO=1 rm data.txt"
    requests: 1
    source: shell
    access: shell cwd=. command="rm *.log"
    requests: 1
    source: shell
    access: shell cwd=. command="~/bin/tool run" |}]

(* Escalation drops the sandbox's filesystem confinement but not its credential
   strip: a workspace-write escalation runs unconfined yet still passes through
   [Env.partition], so secrets and loader-injection variables are removed. Only
   danger-full-access (Unconfined) passes the environment verbatim. *)
let%expect_test "approved escalation runs unconfined but still strips secrets" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  Unix.putenv "SPICE_EXPECT_FAKE_TOKEN" "tok-value";
  let config = workspace_write_config ~root in
  run ~root ~outside ~fs ~workspace ~config
    (input ~escalate:true "echo ${SPICE_EXPECT_FAKE_TOKEN:-stripped}");
  [%expect
    {|
    completed
    output status: exited 0
    workdir: .
    limits: timeout=60000 max_output=65536 description=-
    sandbox: not_requested
    stdout: complete "stripped\n"
    stderr: complete "" |}]

let%expect_test "read-only refuses escalation without spawning" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  run ~root ~outside ~fs ~workspace ~config:read_only_config
    (input ~escalate:true "echo never");
  [%expect
    {|
    failed invalid_input: escalation is not available in a read-only sandbox: read-only runs do not mutate; rerun with --sandbox workspace-write for mutating work
    output: none |}]

let%expect_test
    "declared external command inherits env and reports the\n\
    \                 declaration" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  Unix.putenv "SPICE_EXPECT_FAKE_TOKEN" "tok-value";
  let sandbox = Spice_sandbox.seal Spice_sandbox.Spec.Declared_external in
  let config = Shell.Config.make ~sandbox () in
  run ~root ~outside ~fs ~workspace ~config
    (input "echo ${SPICE_EXPECT_FAKE_TOKEN:-stripped}");
  [%expect
    {|
    completed
    output status: exited 0
    workdir: .
    limits: timeout=60000 max_output=65536 description=-
    sandbox: declared_external
    stdout: complete "tok-value\n"
    stderr: complete "" |}]

let%expect_test
    "unconfined command uses workdir env overlay and deterministic env" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config =
    unconfined ~default_timeout_ms:1_000
      ~environment:[ ("SPICE_SHELL_TEST", Some "from-config") ]
      ()
  in
  run ~root ~outside ~fs ~workspace ~config
    (input ~workdir:"subject/nested"
       "printf 'cwd='; pwd; printf 'var=%s\\npager=%s\\n' \
        \"$SPICE_SHELL_TEST\" \"$PAGER\"");
  [%expect
    {|
    completed
    output status: exited 0
    workdir: subject/nested
    limits: timeout=1000 max_output=65536 description=-
    sandbox: not_requested
    stdout: complete "cwd=<root>/subject/nested\nvar=from-config\npager=cat\n"
    stderr: complete "" |}]

let%expect_test "non-zero exit carries stdout and stderr evidence" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config = unconfined ~default_timeout_ms:1_000 () in
  run ~root ~outside ~fs ~workspace ~config
    (input "printf 'out\\n'; printf 'err\\n' >&2; exit 7");
  [%expect
    {|
    failed failed: command exited with status 7
    output status: exited 7
    workdir: .
    limits: timeout=1000 max_output=65536 description=-
    sandbox: not_requested
    stdout: complete "out\n"
    stderr: complete "err\n" |}]

let%expect_test "timeout reports effective timeout and retained output" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config = unconfined ~default_timeout_ms:80 ~max_timeout_ms:1_000 () in
  run ~root ~outside ~fs ~workspace ~config
    (input ~timeout_ms:60 "printf 'before\\n'; sleep 5; printf 'after\\n'");
  [%expect
    {|
    failed timed_out: command timed out after 60ms
    output status: timed_out 60ms
    workdir: .
    limits: timeout=60 max_output=65536 description=-
    sandbox: not_requested
    stdout: complete "before\n"
    stderr: complete "" |}]

let%expect_test "output truncation keeps head and tail for each stream" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config = unconfined ~default_timeout_ms:1_000 ~max_output_bytes:8 () in
  run ~root ~outside ~fs ~workspace ~config
    (input "printf 'abcdefghijklmnopqrst'; printf 'ABCDEFGHIJKLMNOPQRST' >&2");
  [%expect
    {|
    completed
    output status: exited 0
    workdir: .
    limits: timeout=1000 max_output=8 description=-
    sandbox: not_requested
    stdout: truncated head="abcd" tail="qrst" omitted=12
    stderr: truncated head="ABCD" tail="QRST" omitted=12 |}]

let%expect_test "workdir failures are invalid input before spawn" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config = unconfined ~default_timeout_ms:1_000 () in
  let cases =
    [
      ("missing", "missing");
      ("file", "file.txt");
      ("symlink outside", "outside_link");
      ("absolute outside", outside);
    ]
  in
  List.iter
    (fun (label, workdir) ->
      print_case label;
      run ~root ~outside ~fs ~workspace ~config (input ~workdir "pwd"))
    cases;
  [%expect
    {|
    -- missing --
    failed invalid_input: missing: path does not exist
    output: none
    -- file --
    failed invalid_input: file.txt: expected directory, found regular file
    output: none
    -- symlink outside --
    failed invalid_input: outside_link: path resolves outside workspace
    output: none
    -- absolute outside --
    failed invalid_input: path is outside workspace: <outside>
    output: none |}]

let%expect_test "permission parser uses exec evidence only when shell is simple"
    =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  ignore fs;
  print_case "simple sequence";
  print_permissions ~root ~outside workspace
    (input ~workdir:"subject" "git status --short && dune build");
  print_case "quoted argument";
  print_permissions ~root ~outside workspace (input "printf 'hello world'");
  print_case "redirect fallback";
  print_permissions ~root ~outside workspace (input "printf hi > out.txt");
  print_case "substitution fallback";
  print_permissions ~root ~outside workspace (input "echo $(pwd)");
  print_case "bad workdir";
  print_permissions ~root ~outside workspace (input ~workdir:"../outside" "pwd");
  [%expect
    {|
    -- simple sequence --
    requests: 1
    source: shell
    access: exec cwd=subject argv="git" "status" "--short"
    access: exec cwd=subject argv="dune" "build"
    -- quoted argument --
    requests: 1
    source: shell
    access: exec cwd=. argv="printf" "hello world"
    -- redirect fallback --
    requests: 1
    source: shell
    access: shell cwd=. command="printf hi > out.txt"
    -- substitution fallback --
    requests: 1
    source: shell
    access: shell cwd=. command="echo $(pwd)"
    -- bad workdir --
    requests: none |}]

let%expect_test "erased adapter output keeps text json and truncation signal" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config = unconfined ~default_timeout_ms:1_000 () in
  let tool = Shell.tool ~fs ~workspace ~config () in
  let call =
    match
      Tool.Call.decode [ tool ] ~name:Shell.name
        ~input:(json_obj [ ("command", Json.string "printf 'adapter\\n'") ])
        ()
    with
    | Ok call -> call
    | Error error ->
        failf "failed to decode adapter call: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let result = Tool.Call.run call () in
  begin match (Tool.Result.status result, Tool.Result.output result) with
  | Tool.Result.Completed, Some output ->
      let text = normalize_paths ~root ~outside (Tool.Output.text output) in
      Printf.printf "text command: %s\n" (line_with "Command:" text);
      Printf.printf "text status: %s\n" (line_with "Status:" text);
      Printf.printf "text sandbox: %s\n" (line_with "Sandbox:" text);
      let json_command =
        match Option.bind (Tool.Output.json output) (json_member "command") with
        | Some json -> Option.value ~default:"<not string>" (json_string json)
        | None -> "<missing>"
      in
      Printf.printf "json command: %S\n" json_command;
      Printf.printf "truncated=%b\n" (Tool.Output.truncated output)
  | Tool.Result.Completed, None -> failf "adapter call completed without output"
  | Tool.Result.Failed _, None | Tool.Result.Failed _, Some _ ->
      failf "adapter call failed"
  | Tool.Result.Interrupted _, None | Tool.Result.Interrupted _, Some _ ->
      failf "adapter call was interrupted"
  end;
  [%expect
    {|
    permissions: 1
    text command: Command: printf 'adapter\n'
    text status: Status: exited 0
    text sandbox: Sandbox: not_requested
    json command: "printf 'adapter\\n'"
    truncated=false |}]

let%expect_test
    "cancellation interrupts running command and returns output evidence" =
  with_fixture @@ fun ~root ~outside ~fs ~workspace ->
  let config = unconfined ~default_timeout_ms:5_000 () in
  let checks = ref 0 in
  let cancelled () =
    incr checks;
    !checks > 1
  in
  run ~root ~outside ~fs ~workspace ~config ~cancelled
    (input "sleep 5; printf 'late\\n'");
  [%expect
    {|
    interrupted cancelled=true: tool call cancelled
    output status: cancelled
    workdir: .
    limits: timeout=5000 max_output=65536 description=-
    sandbox: not_requested
    stdout: complete ""
    stderr: complete "" |}]

[%%run_tests "spice.tools.shell.expect"]
