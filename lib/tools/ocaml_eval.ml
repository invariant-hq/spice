(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "ocaml_eval"
let description = Spice_prompts.Tools.ocaml_eval

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let contains_nul s = String.contains s '\000'

let validate_non_empty name = function
  | "" -> invalid_arg (name ^ " must not be empty")
  | s when contains_nul s -> invalid_arg (name ^ " must not contain NUL")
  | _ -> ()

module Input = struct
  type t = { code : string; dir : string option; timeout_ms : int option }

  let make ?dir ?timeout_ms code =
    validate_non_empty "code" code;
    Option.iter (validate_non_empty "dir") dir;
    begin match timeout_ms with
    | Some timeout_ms when timeout_ms <= 0 ->
        invalid_arg "timeout_ms must be positive"
    | Some _ | None -> ()
    end;
    { code; dir; timeout_ms }

  let code t = t.code
  let dir t = t.dir
  let timeout_ms t = t.timeout_ms

  let codec =
    Jsont.Object.map ~kind:"ocaml_eval input" (fun code dir timeout_ms ->
        decode_invalid_arg (fun () -> make ?dir ?timeout_ms code))
    |> Jsont.Object.mem "code" Jsont.string ~enc:code
    |> Jsont.Object.opt_mem "dir" Jsont.string ~enc:dir
    |> Jsont.Object.opt_mem "timeout_ms" Jsont.int ~enc:timeout_ms
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "code",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Non-empty OCaml toplevel phrase text to evaluate." );
                  ] );
              ( "dir",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Workspace-relative or workspace-contained absolute \
                         Dune directory. Defaults to the workspace root." );
                  ] );
              ( "timeout_ms",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "Optional total timeout in milliseconds for setup and \
                         evaluation, bounded by host configuration." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "code" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Config = struct
  type t = {
    dune : string;
    ocaml : string;
    default_timeout_ms : int;
    max_timeout_ms : int;
    max_output_bytes : int;
    environment : (string * string option) list;
  }

  let validate_env_binding = function
    | "", _ -> invalid_arg "environment name must not be empty"
    | name, _ when contains_nul name ->
        invalid_arg "environment name must not contain NUL"
    | name, _ when String.contains name '=' ->
        invalid_arg "environment name must not contain ="
    | _, Some value when contains_nul value ->
        invalid_arg "environment value must not contain NUL"
    | _, None | _, Some _ -> ()

  let make ?(dune = "dune") ?(ocaml = "ocaml") ?(default_timeout_ms = 10_000)
      ?(max_timeout_ms = 120_000) ?(max_output_bytes = 65_536)
      ?(environment = []) () =
    validate_non_empty "dune" dune;
    validate_non_empty "ocaml" ocaml;
    if default_timeout_ms <= 0 then
      invalid_arg "default_timeout_ms must be positive";
    if max_timeout_ms <= 0 then invalid_arg "max_timeout_ms must be positive";
    if default_timeout_ms > max_timeout_ms then
      invalid_arg "default_timeout_ms must be <= max_timeout_ms";
    if max_output_bytes < 0 then
      invalid_arg "max_output_bytes must be non-negative";
    List.iter validate_env_binding environment;
    {
      dune;
      ocaml;
      default_timeout_ms;
      max_timeout_ms;
      max_output_bytes;
      environment;
    }

  let dune t = t.dune
  let ocaml t = t.ocaml
  let default_timeout_ms t = t.default_timeout_ms
  let max_timeout_ms t = t.max_timeout_ms
  let max_output_bytes t = t.max_output_bytes
  let environment t = t.environment

  let resolve_timeout_ms t = function
    | None -> Ok t.default_timeout_ms
    | Some timeout_ms when timeout_ms <= 0 ->
        Error "timeout_ms must be positive"
    | Some timeout_ms when timeout_ms > t.max_timeout_ms ->
        Error (Printf.sprintf "timeout_ms must be <= %d" t.max_timeout_ms)
    | Some timeout_ms -> Ok timeout_ms
end

module String_map = Map.Make (String)

let split_env binding =
  match String.split_first ~sep:"=" binding with
  | None -> (binding, Some "")
  | Some (name, value) -> (name, Some value)

let apply_env_overlay env overlay =
  List.fold_left
    (fun env -> function
      | name, Some value -> String_map.add name value env
      | name, None -> String_map.remove name env)
    env overlay

let deterministic_overlay =
  [
    ("TERM", Some "dumb");
    ("NO_COLOR", Some "1");
    ("CLICOLOR", Some "0");
    ("CLICOLOR_FORCE", Some "0");
    ("PAGER", Some "cat");
    ("GIT_PAGER", Some "cat");
    ("LESS", Some "-FRX");
  ]

let process_environment config =
  let inherited =
    Array.fold_left
      (fun env binding ->
        match split_env binding with
        | "", _ -> env
        | name, None -> String_map.remove name env
        | name, Some value -> String_map.add name value env)
      String_map.empty (Unix.environment ())
  in
  let with_defaults = apply_env_overlay inherited deterministic_overlay in
  let with_config =
    apply_env_overlay with_defaults (Config.environment config)
  in
  with_config |> String_map.bindings
  |> List.map (fun (name, value) -> name ^ "=" ^ value)
  |> Array.of_list

(* [run_shell]'s [execvp] resolves a bare program against the process [PATH], not
   [env], so pin the absolute path the search space yields. *)
let program_path toolchain name =
  match Spice_ocaml_toolchain.find toolchain name with
  | Some (abs, _) -> abs
  | None -> name

let resolve_dir ~fs ~workspace input =
  let resolved =
    match Input.dir input with
    | None -> Ok (Workspace.root_path workspace)
    | Some dir -> Fs.resolve ~workspace dir
  in
  match resolved with
  | Error error -> Error (Fs.Error.message error)
  | Ok dir -> (
      match Fs.directory ~fs ~workspace ~follow_symlink:true dir with
      | Ok _ -> Ok dir
      | Error error -> Error (Fs.Error.message error))

let command_execution sandbox =
  match Spice_sandbox.evidence sandbox with
  | Spice_sandbox.Evidence.Enforced _ ->
      Some Permission.Access.Command.Enforced
  | Spice_sandbox.Evidence.Declared_external ->
      Some Permission.Access.Command.External
  | Spice_sandbox.Evidence.Not_requested ->
      Some Permission.Access.Command.Direct
  | Spice_sandbox.Evidence.Refused _ -> None

let permissions ~sandbox ~workspace input =
  let resolved =
    match Input.dir input with
    | None -> Ok (Workspace.root_path workspace)
    | Some dir -> Fs.resolve ~workspace dir
  in
  match (resolved, command_execution sandbox) with
  | Error _, _ | _, None -> []
  | Ok dir, Some execution ->
      let cwd = Permission.Access.Path_scope.workspace dir in
      [
        Permission.Request.of_accesses ~source:name ~display:(Input.code input)
          [
            Permission.Access.path ~op:`Read dir;
            Permission.Access.code ~cwd ~execution ~language:"ocaml"
              (Input.code input);
          ];
      ]

module Output = struct
  type stage = Dune_top | Eval

  type stream =
    | Complete of string
    | Truncated of { head : string; tail : string; omitted_bytes : int }

  type status =
    | Exited of int
    | Signaled of int
    | Timed_out of { timeout_ms : int }
    | Cancelled
    | Failed_to_start of string

  type t = {
    code : string;
    dir : Workspace.Path.t;
    stage : stage;
    status : status;
    stdout : stream;
    stderr : stream;
    duration_ms : int;
    timeout_ms : int;
    max_output_bytes : int;
  }

  let make ~code ~dir ~stage ~status ~stdout ~stderr ~duration_ms ~timeout_ms
      ~max_output_bytes =
    {
      code;
      dir;
      stage;
      status;
      stdout;
      stderr;
      duration_ms;
      timeout_ms;
      max_output_bytes;
    }

  let code t = t.code
  let dir t = t.dir
  let stage t = t.stage
  let status t = t.status
  let stdout t = t.stdout
  let stderr t = t.stderr
  let duration_ms t = t.duration_ms
  let timeout_ms t = t.timeout_ms
  let max_output_bytes t = t.max_output_bytes
  let stage_text = function Dune_top -> "dune_top" | Eval -> "eval"

  let status_text = function
    | Exited code -> Printf.sprintf "exited %d" code
    | Signaled signal -> Printf.sprintf "signaled %d" signal
    | Timed_out { timeout_ms } ->
        Printf.sprintf "timed out after %dms" timeout_ms
    | Cancelled -> "cancelled"
    | Failed_to_start _ -> "failed to start"

  let status_json = function
    | Exited code ->
        json_obj [ ("type", Json.string "exited"); ("code", Json.int code) ]
    | Signaled signal ->
        json_obj
          [ ("type", Json.string "signaled"); ("signal", Json.int signal) ]
    | Timed_out { timeout_ms } ->
        json_obj
          [
            ("type", Json.string "timed_out");
            ("timeout_ms", Json.int timeout_ms);
          ]
    | Cancelled -> json_obj [ ("type", Json.string "cancelled") ]
    | Failed_to_start message ->
        json_obj
          [
            ("type", Json.string "failed_to_start");
            ("message", Json.string message);
          ]

  let stream_text = function
    | Complete text -> text
    | Truncated { head; tail; omitted_bytes } ->
        head
        ^ Printf.sprintf "\n... %d bytes omitted ...\n" omitted_bytes
        ^ tail

  let stream_json = function
    | Complete text ->
        json_obj [ ("truncated", Json.bool false); ("text", Json.string text) ]
    | Truncated { head; tail; omitted_bytes } ->
        json_obj
          [
            ("truncated", Json.bool true);
            ("head", Json.string head);
            ("tail", Json.string tail);
            ("omitted_bytes", Json.int omitted_bytes);
          ]

  let stream_truncated = function Complete _ -> false | Truncated _ -> true

  let json t =
    json_obj
      [
        ("code", Json.string (code t));
        ("dir", Json.string (Workspace.Path.display (dir t)));
        ("stage", Json.string (stage_text (stage t)));
        ("status", status_json (status t));
        ("stdout", stream_json (stdout t));
        ("stderr", stream_json (stderr t));
        ("duration_ms", Json.int (duration_ms t));
        ("timeout_ms", Json.int (timeout_ms t));
        ("max_output_bytes", Json.int (max_output_bytes t));
      ]

  let text t =
    Printf.sprintf
      "OCaml eval\n\
       Directory: %s\n\
       Stage: %s\n\
       Status: %s\n\
       Duration: %dms\n\
       Timeout: %dms\n\n\
       stdout:\n\
       %s\n\
       stderr:\n\
       %s"
      (Workspace.Path.display (dir t))
      (stage_text (stage t))
      (status_text (status t))
      (duration_ms t) (timeout_ms t)
      (stream_text (stdout t))
      (stream_text (stderr t))

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~truncated:(stream_truncated (stdout t) || stream_truncated (stderr t))
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let elapsed_ms start = int_of_float ((Unix.gettimeofday () -. start) *. 1000.)

let remaining_timeout ~started timeout_ms =
  let remaining = timeout_ms - elapsed_ms started in
  if remaining <= 0 then None else Some remaining

let status_of_process : Process.shell_status -> Output.status = function
  | Process.Shell_exited code -> Output.Exited code
  | Process.Shell_signaled signal -> Output.Signaled signal
  | Process.Shell_timed_out { timeout_ms } -> Output.Timed_out { timeout_ms }
  | Process.Shell_cancelled -> Output.Cancelled
  | Process.Shell_refused error ->
      Output.Failed_to_start (Spice_sandbox.Error.message error)
  | Process.Shell_failed_to_start message -> Output.Failed_to_start message

let stream_of_process : Process.captured -> Output.stream = function
  | Process.Complete text -> Output.Complete text
  | Process.Truncated { head; tail; omitted_bytes } ->
      Output.Truncated { head; tail; omitted_bytes }

let output_of_process ~input ~dir ~stage ~started ~timeout_ms ~max_output_bytes
    result =
  Output.make ~code:(Input.code input) ~dir ~stage
    ~status:(status_of_process result.Process.shell_status)
    ~stdout:(stream_of_process result.Process.shell_stdout)
    ~stderr:(stream_of_process result.Process.shell_stderr)
    ~duration_ms:(elapsed_ms started) ~timeout_ms ~max_output_bytes

let result_of_output output =
  match Output.status output with
  | Output.Exited 0 -> Tool.Result.completed ~output ()
  | Output.Exited code ->
      Tool.Result.failed ~output `Failed
        (Printf.sprintf "OCaml eval %s exited with status %d"
           (Output.stage output |> Output.stage_text)
           code)
  | Output.Signaled signal ->
      Tool.Result.failed ~output `Failed
        (Printf.sprintf "OCaml eval %s terminated by signal %d"
           (Output.stage output |> Output.stage_text)
           signal)
  | Output.Timed_out { timeout_ms } ->
      Tool.Result.failed ~output `Timed_out
        (Printf.sprintf "OCaml eval timed out after %dms" timeout_ms)
  | Output.Cancelled ->
      Tool.Result.interrupted ~output ~reason:"tool call cancelled"
        ~cancelled:true ()
  | Output.Failed_to_start message ->
      Tool.Result.failed ~output `Unavailable message

let captured_complete = function
  | Process.Complete text -> Some text
  | Process.Truncated _ -> None

let append_phrase_terminator code =
  let trimmed = String.trim code in
  if String.length trimmed >= 2 then
    let last = String.length trimmed - 1 in
    if Char.equal trimmed.[last] ';' && Char.equal trimmed.[last - 1] ';' then
      code
    else code ^ "\n;;\n"
  else code ^ "\n;;\n"

let init_text ~directives ~code =
  let b = Buffer.create (String.length directives + String.length code + 8) in
  Buffer.add_string b directives;
  if
    String.length directives > 0
    && not (Char.equal directives.[String.length directives - 1] '\n')
  then Buffer.add_char b '\n';
  Buffer.add_string b (append_phrase_terminator code);
  Buffer.add_string b "\n#quit;;\n";
  Buffer.contents b

let default_cancelled () = false

let watch_incompatible_message endpoint =
  Printf.sprintf
    "ocaml_eval cannot run while a Dune watch (%s) holds the build lock: `dune \
     ocaml top` takes the same lock and fails fast rather than sharing it. \
     Stop the watch, or run the evaluation outside this session, and retry."
    endpoint

let run ~sandbox ~fs ~workspace ~config ?watch
    ?(cancelled = default_cancelled) input =
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Config.resolve_timeout_ms config (Input.timeout_ms input) with
    | Error message -> Tool.Result.failed `Invalid_input message
    | Ok timeout_ms -> (
        match resolve_dir ~fs ~workspace input with
        | Error message -> Tool.Result.failed `Invalid_input message
        | Ok dir -> (
            match Option.bind watch (fun watch -> watch ()) with
            | Some endpoint ->
                Tool.Result.failed `Unavailable
                  (watch_incompatible_message endpoint)
            | None -> (
                let started = Unix.gettimeofday () in
                let max_output_bytes = Config.max_output_bytes config in
                let cwd = Spice_path.Abs.to_string (Workspace.Path.abs dir) in
                let toolchain =
                  Spice_ocaml_toolchain.discover
                    ~env:(process_environment config)
                    ~workspace_root:
                      (Some
                         (Spice_path.Abs.to_string
                            (Workspace.Path.abs (Workspace.root_path workspace))))
                in
                let env =
                  Spice_ocaml_toolchain.env toolchain
                    ~program:(Config.ocaml config)
                in
                let dune_result =
                  Process.run_sandboxed_shell ~sandbox ~cwd ~env ~timeout_ms
                    ~max_output_bytes ~cancelled
                    [
                      program_path toolchain (Config.dune config);
                      "ocaml";
                      "top";
                      ".";
                    ]
                in
                let dune_output =
                  output_of_process ~input ~dir ~stage:Output.Dune_top ~started
                    ~timeout_ms ~max_output_bytes dune_result
                in
                match dune_result.Process.shell_status with
                | Process.Shell_exited 0 -> (
                    match
                      captured_complete dune_result.Process.shell_stdout
                    with
                    | None ->
                        Tool.Result.failed ~output:dune_output `Failed
                          "dune ocaml top output exceeded the retained output \
                           limit"
                    | Some directives -> (
                        match remaining_timeout ~started timeout_ms with
                        | None ->
                            let output =
                              Output.make ~code:(Input.code input) ~dir
                                ~stage:Output.Eval
                                ~status:(Output.Timed_out { timeout_ms })
                                ~stdout:(Output.Complete "")
                                ~stderr:(Output.Complete "")
                                ~duration_ms:(elapsed_ms started) ~timeout_ms
                                ~max_output_bytes
                            in
                            Tool.Result.failed ~output `Timed_out
                              (Printf.sprintf "OCaml eval timed out after %dms"
                                 timeout_ms)
                        | Some eval_timeout_ms ->
                            let eval_result =
                              Process.run_sandboxed_shell ~sandbox ~cwd ~env
                                ~timeout_ms:eval_timeout_ms ~max_output_bytes
                                ~stdin:
                                  (init_text ~directives
                                     ~code:(Input.code input))
                                ~cancelled
                                [
                                  program_path toolchain (Config.ocaml config);
                                  "-stdin";
                                  "-noinit";
                                ]
                            in
                            output_of_process ~input ~dir ~stage:Output.Eval
                              ~started ~timeout_ms ~max_output_bytes eval_result
                            |> result_of_output))
                | Process.Shell_exited _ | Process.Shell_signaled _
                | Process.Shell_timed_out _ | Process.Shell_cancelled
                | Process.Shell_refused _
                | Process.Shell_failed_to_start _ ->
                    result_of_output dune_output)))

let tool ~sandbox ~fs ~workspace ~config ?watch () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(permissions ~sandbox ~workspace)
    ~run:(fun ctx input ->
      run ~sandbox ~fs ~workspace ~config ?watch
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
