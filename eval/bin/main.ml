(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
module Eval = Spice_eval
module Json = Jsont.Json
module Catalog = Spice_provider.Catalog
module Model = Spice_provider.Model
module Llm_usage = Spice_llm.Usage

let exits = CCmd.Exit.defaults
let stdout_printf format = Format.printf (format ^^ "%!")
let stderr_printf format = Format.eprintf (format ^^ "%!")

(* Processes *)

type process_result = {
  status : Unix.process_status;
  duration_s : float;
  timed_out : bool;
}

let process_success = function Unix.WEXITED 0 -> true | _ -> false

let status_message = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped by signal %d" signal

let ensure_dir path =
  let rec loop path =
    if path = "" || path = Filename.dirname path then ()
    else if Sys.file_exists path then (
      if not (Sys.is_directory path) then
        invalid_arg (path ^ " exists and is not a directory"))
    else (
      loop (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  loop path

let write_file path text =
  ensure_dir (Filename.dirname path);
  let output = open_out path in
  output_string output text;
  close_out output

let append_line path line =
  ensure_dir (Filename.dirname path);
  let output = open_out_gen [ Open_creat; Open_text; Open_append ] 0o644 path in
  output_string output line;
  output_char output '\n';
  close_out output

let read_file path =
  let input = open_in path in
  let length = in_channel_length input in
  let text = really_input_string input length in
  close_in input;
  text

let copy_file ~src ~dst =
  ensure_dir (Filename.dirname dst);
  let input_channel = open_in_bin src in
  let output_channel = open_out_bin dst in
  let buffer = Bytes.create 65536 in
  let rec loop () =
    match input input_channel buffer 0 (Bytes.length buffer) with
    | 0 -> ()
    | count ->
        output output_channel buffer 0 count;
        loop ()
  in
  match loop () with
  | () ->
      close_in input_channel;
      close_out output_channel
  | exception exn ->
      close_in_noerr input_channel;
      close_out_noerr output_channel;
      raise exn

let skip_copy_name = function
  | ".git" | ".spice" | "_build" -> true
  | _ -> false

let rec copy_dir ~src ~dst =
  ensure_dir dst;
  Sys.readdir src |> Array.to_list
  |> List.iter (fun name ->
      if not (skip_copy_name name) then
        let src_path = Filename.concat src name in
        let dst_path = Filename.concat dst name in
        if Sys.is_directory src_path then copy_dir ~src:src_path ~dst:dst_path
        else copy_file ~src:src_path ~dst:dst_path)

let with_output_files stdout_path stderr_path f =
  ensure_dir (Filename.dirname stdout_path);
  ensure_dir (Filename.dirname stderr_path);
  let stdout_fd =
    Unix.openfile stdout_path
      [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ]
      0o644
  in
  let stderr_fd =
    Unix.openfile stderr_path
      [ Unix.O_CREAT; Unix.O_WRONLY; Unix.O_TRUNC ]
      0o644
  in
  match f stdout_fd stderr_fd with
  | value ->
      Unix.close stdout_fd;
      Unix.close stderr_fd;
      value
  | exception exn ->
      Unix.close stdout_fd;
      Unix.close stderr_fd;
      raise exn

(* The child calls setsid so a timeout can kill its whole process tree (the
   agent's shell tools, the shell's children) via the process group. *)
let kill_group pid =
  (try Unix.kill (-pid) Sys.sigkill with Unix.Unix_error _ -> ());
  try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()

let env_binding_name binding =
  match String.split_first ~sep:"=" binding with
  | None -> binding
  | Some (name, _) -> name

let env_with_extra env_extra =
  let overridden = List.map fst env_extra |> List.sort_uniq String.compare in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter (fun binding ->
        not (List.mem (env_binding_name binding) overridden))
  in
  inherited @ List.map (fun (name, value) -> name ^ "=" ^ value) env_extra
  |> Array.of_list

let wait_with_timeout ?timeout_s pid =
  let start = Unix.gettimeofday () in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> (
        match timeout_s with
        | Some timeout_s when Unix.gettimeofday () -. start >= timeout_s ->
            kill_group pid;
            let _, status = Unix.waitpid [] pid in
            {
              status;
              duration_s = Unix.gettimeofday () -. start;
              timed_out = true;
            }
        | Some _ | None ->
            ignore (Unix.select [] [] [] 0.05);
            loop ())
    | _, status ->
        {
          status;
          duration_s = Unix.gettimeofday () -. start;
          timed_out = false;
        }
  in
  loop ()

let run_process ?timeout_s ?(env_extra = []) ~cwd ~stdout_path ~stderr_path argv
    =
  with_output_files stdout_path stderr_path @@ fun stdout_fd stderr_fd ->
  let env = env_with_extra env_extra in
  let pid = Unix.fork () in
  if pid = 0 then (
    (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
    Unix.dup2 stdout_fd Unix.stdout;
    Unix.dup2 stderr_fd Unix.stderr;
    (match Unix.chdir cwd with
    | () -> ()
    | exception exn ->
        prerr_endline ("chdir failed: " ^ Printexc.to_string exn);
        exit 127);
    (match Unix.execvpe argv.(0) argv env with _ -> () | exception _ -> ());
    exit 127)
  else wait_with_timeout ?timeout_s pid

let run_shell ?timeout_s ?env_extra ~cwd ~stdout_path ~stderr_path command =
  run_process ?timeout_s ?env_extra ~cwd ~stdout_path ~stderr_path
    [| "/bin/sh"; "-c"; command |]

(* JSON utilities *)

let encode_row row =
  match Jsont_bytesrw.encode_string Eval.Result.jsont row with
  | Ok text -> text
  | Error message -> failwith message

let decode_json text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok json -> Ok json
  | Error message -> Error message

let json_member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | _ -> None

let json_string_member name json =
  match json_member name json with
  | Some (Jsont.String (text, _)) -> Some text
  | _ -> None

let json_int_member name json =
  match json_member name json with
  | Some (Jsont.Number (number, _)) ->
      let value = int_of_float number in
      if Float.equal (float_of_int value) number then Some value else None
  | _ -> None

let json_float_member name json =
  match json_member name json with
  | Some (Jsont.Number (number, _)) -> Some number
  | _ -> None

let json_decode codec json =
  match Json.decode codec json with Ok value -> Some value | Error _ -> None

let final_json lines =
  lines |> List.rev
  |> List.find_map (fun line ->
      match decode_json line with Ok json -> Some json | Error _ -> None)

let jsonl_events text =
  String.split_on_char '\n' text
  |> List.filter_map (fun line ->
      match decode_json line with Ok json -> Some json | Error _ -> None)

(* Versions and revisions *)

let capture_command ~name argv =
  let tmp = Filename.temp_file ("spice-eval-" ^ name) ".txt" in
  let err = Filename.temp_file ("spice-eval-" ^ name) ".err" in
  let result =
    run_process ~cwd:(Sys.getcwd ()) ~stdout_path:tmp ~stderr_path:err argv
  in
  let text =
    if process_success result.status then Some (String.trim (read_file tmp))
    else None
  in
  Sys.remove tmp;
  Sys.remove err;
  match text with Some "" -> None | value -> value

let current_git_rev () =
  match
    capture_command ~name:"git" [| "git"; "rev-parse"; "--short"; "HEAD" |]
  with
  | None -> None
  | Some rev -> (
      (* capture_command maps empty output to None: a clean tree. *)
      match
        capture_command ~name:"git" [| "git"; "status"; "--porcelain" |]
      with
      | None -> Some rev
      | Some _ -> Some (rev ^ "-dirty"))

let command_version command =
  capture_command ~name:"version" [| command; "--version" |]

let current_path () = Option.value (Sys.getenv_opt "PATH") ~default:""
let path_separator = if Sys.win32 then ";" else ":"

let lines text =
  String.split_on_char '\n' text
  |> List.map String.trim
  |> List.filter (fun line -> not (String.is_empty line))

let find_toolchain_ocamlc () =
  match Sys.getenv_opt "HOME" with
  | None -> None
  | Some home -> (
      let ( / ) = Filename.concat in
      let root = home / ".cache" / "dune" / "toolchains" in
      if not (Sys.file_exists root) then None
      else
        match
          capture_command ~name:"find-ocamlc"
            [|
              "/bin/sh";
              "-c";
              "find -L \"$1\" -path '*/target/bin/ocamlc' -type f 2>/dev/null \
               | sort";
              "find-ocamlc";
              root;
            |]
        with
        | None -> None
        | Some output ->
            lines output |> List.rev
            |> List.find_opt (fun path ->
                Filename.basename (Filename.dirname path) = "bin"))

let ocaml_toolchain_env () =
  let ocamlc =
    match
      capture_command ~name:"ocamlc"
        [|
          "dune";
          "exec";
          "--root";
          Sys.getcwd ();
          "--no-build";
          "--";
          "/bin/sh";
          "-c";
          "command -v ocamlc";
        |]
    with
    | Some ocamlc -> Some ocamlc
    | None -> find_toolchain_ocamlc ()
  in
  match ocamlc with
  | None -> []
  | Some ocamlc ->
      let bin = Filename.dirname ocamlc in
      [ ("PATH", bin ^ path_separator ^ current_path ()) ]

let default_spice_bin () =
  let ( / ) = Filename.concat in
  let local = Sys.getcwd () / "_build" / "default" / "bin" / "main.exe" in
  if Sys.file_exists local then local else "spice"

(* Cost interpretation backed by the built-in provider catalog. *)

let catalog = lazy Spice_provider_builtin.catalog

let price_cost price (usage : Eval.Usage.t) =
  match (price.Model.input_per_million, price.Model.output_per_million) with
  | Some input_rate, Some output_rate ->
      let cached_rate =
        Option.value price.Model.cached_input_per_million ~default:input_rate
      in
      let cache_write_rate =
        Option.value price.Model.cache_write_5m_per_million ~default:input_rate
      in
      Some
        (((float_of_int usage.Eval.Usage.input *. input_rate)
         +. (float_of_int usage.Eval.Usage.cache_read *. cached_rate)
         +. (float_of_int usage.Eval.Usage.cache_write *. cache_write_rate)
         +. float_of_int (usage.Eval.Usage.output + usage.Eval.Usage.reasoning)
            *. output_rate)
        /. 1_000_000.)
  | _ -> None

let model_cost ~model usage =
  match Catalog.resolve (Lazy.force catalog) model with
  | Error _ -> None
  | Ok declared ->
      Option.bind (Model.pricing declared) @@ fun pricing ->
      price_cost (Model.price_for pricing) usage

module Agent = struct
  module Outcome = struct
    type status = Eval.Result.agent_status =
      | Completed
      | Blocked
      | Timed_out
      | Failed of Eval.Result.failure

    type t = { status : status; metrics : Eval.Result.metrics }

    let make ~status ?usage ?turns ?tool_calls ?tool_failures ?tool_rejections
        ~duration_s ?log () =
      {
        status;
        metrics =
          Eval.Result.metrics ~duration_s ?usage ?turns ?tool_calls
            ?tool_failures ?tool_rejections ?log ();
      }
  end

  type ctx = {
    workspace : string;
    max_steps : int option;
    timeout_s : float option;
    artifact_dir : string option;
    env_extra : (string * string) list;
  }

  type t = { name : string; run : ctx -> prompt:string -> Outcome.t }

  let v ~name run =
    if String.is_empty name then
      invalid_arg "spice-eval.Agent.v: name must not be empty";
    { name; run }

  let name t = t.name
  let run t ctx ~prompt = t.run ctx ~prompt
end

let failed_status ?log stage message =
  Eval.Result.Failed
    { Eval.Result.stage; Eval.Result.message; Eval.Result.failure_log = log }

(* Result directories *)

let make_result_dir output =
  match output with
  | Some path ->
      ensure_dir path;
      path
  | None ->
      let tm = Unix.localtime (Unix.time ()) in
      let name =
        Printf.sprintf "%04d%02d%02d-%02d%02d%02d" (tm.Unix.tm_year + 1900)
          (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
          tm.Unix.tm_sec
      in
      let ( / ) = Filename.concat in
      let path = "_evals" / "results" / name in
      ensure_dir path;
      path

let run_artifact_dir result_dir task run_index =
  let path =
    Filename.concat result_dir
      (Printf.sprintf "%s-%d" (Eval.Task.id task) run_index)
  in
  ensure_dir path;
  path

(* Workspace materialization *)

let materialize_source source workspace artifact_dir =
  match source with
  | Eval.Task.Dir path ->
      let source =
        if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
        else path
      in
      if not (Sys.file_exists source && Sys.is_directory source) then
        Error ("source directory does not exist: " ^ source)
      else (
        copy_dir ~src:source ~dst:workspace;
        Ok ())
  | Eval.Task.Git { url; rev } ->
      let stdout_path = Filename.concat artifact_dir "source-clone.stdout" in
      let stderr_path = Filename.concat artifact_dir "source-clone.stderr" in
      let clone =
        run_process ~cwd:(Sys.getcwd ()) ~stdout_path ~stderr_path
          [| "git"; "clone"; url; workspace |]
      in
      if not (process_success clone.status) then
        Error ("git clone failed: " ^ status_message clone.status)
      else
        let stdout_path =
          Filename.concat artifact_dir "source-checkout.stdout"
        in
        let stderr_path =
          Filename.concat artifact_dir "source-checkout.stderr"
        in
        let checkout =
          run_process ~cwd:workspace ~stdout_path ~stderr_path
            [| "git"; "checkout"; rev |]
        in
        if process_success checkout.status then Ok ()
        else Error ("git checkout failed: " ^ status_message checkout.status)

let git_baseline workspace artifact_dir =
  let run name argv =
    let stdout_path = Filename.concat artifact_dir (name ^ ".stdout") in
    let stderr_path = Filename.concat artifact_dir (name ^ ".stderr") in
    run_process ~cwd:workspace ~stdout_path ~stderr_path argv
  in
  let init = run "git-init" [| "git"; "init" |] in
  if not (process_success init.status) then
    Error ("git init failed: " ^ status_message init.status)
  else
    let ( / ) = Filename.concat in
    let git_exclude = workspace / ".git" / "info" / "exclude" in
    append_line git_exclude "_build/";
    append_line git_exclude ".spice/";
    let config_email =
      run "git-config-email"
        [| "git"; "config"; "user.email"; "spice-eval@example.invalid" |]
    in
    let config_name =
      run "git-config-name" [| "git"; "config"; "user.name"; "spice eval" |]
    in
    let add = run "git-add" [| "git"; "add"; "-A" |] in
    (* --allow-empty: a clean git-source checkout has nothing to commit. *)
    let commit =
      run "git-commit"
        [| "git"; "commit"; "--allow-empty"; "-m"; "spice eval baseline" |]
    in
    if not (process_success config_email.status) then
      Error
        ("git config user.email failed: " ^ status_message config_email.status)
    else if not (process_success config_name.status) then
      Error ("git config user.name failed: " ^ status_message config_name.status)
    else if not (process_success add.status) then
      Error ("git add failed: " ^ status_message add.status)
    else if process_success commit.status then Ok ()
    else Error ("git commit failed: " ^ status_message commit.status)

let capture_diff workspace artifact_dir =
  let run name argv =
    let stdout_path = Filename.concat artifact_dir (name ^ ".stdout") in
    let stderr_path = Filename.concat artifact_dir (name ^ ".stderr") in
    let result = run_process ~cwd:workspace ~stdout_path ~stderr_path argv in
    (result, stdout_path)
  in
  ignore (run "git-add-intent" [| "git"; "add"; "-N"; "." |]);
  let names_result, names_path =
    run "git-diff-name-only" [| "git"; "diff"; "--name-only"; "HEAD"; "--" |]
  in
  let diff_result, diff_path =
    run "git-diff" [| "git"; "diff"; "--unified=0"; "HEAD"; "--" |]
  in
  if process_success names_result.status && process_success diff_result.status
  then
    let names =
      read_file names_path |> String.split_on_char '\n'
      |> List.filter (fun path -> not (String.is_empty path))
    in
    Ok (names, read_file diff_path)
  else Error "git diff failed"

(* Outcome helpers *)

let outcome_error ?(stage = Eval.Result.Agent) ?(duration_s = 0.) ?log message =
  Agent.Outcome.make
    ~status:(failed_status ?log stage message)
    ~duration_s ?log ()

let usage_of_lanes ~input ~output ~reasoning ~cache_read ~cache_write =
  let lane value = max 0 value in
  Eval.Usage.make ~input:(lane input) ~output:(lane output)
    ~reasoning:(lane reasoning) ~cache_read:(lane cache_read)
    ~cache_write:(lane cache_write) ()

let usage_of_llm (usage : Llm_usage.t) =
  Eval.Usage.make ~input:usage.Llm_usage.input ~output:usage.Llm_usage.output
    ~cache_read:usage.Llm_usage.cache_read
    ~cache_write:usage.Llm_usage.cache_write
    ~reasoning:usage.Llm_usage.reasoning ()

(* Check interpretation *)

let glob_regex pattern =
  let buffer = Buffer.create (String.length pattern * 2) in
  Buffer.add_string buffer "^";
  let rec loop index =
    if index >= String.length pattern then ()
    else
      match pattern.[index] with
      | '*' when index + 1 < String.length pattern && pattern.[index + 1] = '*'
        ->
          Buffer.add_string buffer ".*";
          loop (index + 2)
      | '*' ->
          Buffer.add_string buffer "[^/]*";
          loop (index + 1)
      | '?' ->
          Buffer.add_string buffer "[^/]";
          loop (index + 1)
      | c ->
          if String.contains ".+()[]{}^$|\\" c then Buffer.add_char buffer '\\';
          Buffer.add_char buffer c;
          loop (index + 1)
  in
  loop 0;
  Buffer.add_string buffer "$";
  Str.regexp (Buffer.contents buffer)

let any_glob_matches compiled path =
  List.exists (fun regex -> Str.string_match regex path 0) compiled

let diff_added_lines diff =
  diff |> String.split_on_char '\n'
  |> List.filter (fun line ->
      String.length line > 0
      && line.[0] = '+'
      && not (String.starts_with ~prefix:"+++" line))

let evaluate_test ~shell ~diff_files ~diff test =
  match test with
  | Eval.Check.Shell command -> shell command
  | Eval.Check.Diff_within globs ->
      let compiled = List.map glob_regex globs in
      let outside =
        List.filter
          (fun path -> not (any_glob_matches compiled path))
          diff_files
      in
      if outside = [] then Ok ()
      else
        Error ("diff touched out-of-scope paths: " ^ String.concat ", " outside)
  | Eval.Check.Diff_touches_any globs ->
      let compiled = List.map glob_regex globs in
      if List.exists (any_glob_matches compiled) diff_files then Ok ()
      else Error ("diff did not touch any of: " ^ String.concat ", " globs)
  | Eval.Check.Diff_touches_all globs ->
      let missing =
        List.filter
          (fun glob ->
            let compiled = [ glob_regex glob ] in
            not (List.exists (any_glob_matches compiled) diff_files))
          globs
      in
      if missing = [] then Ok ()
      else Error ("diff did not touch: " ^ String.concat ", " missing)
  | Eval.Check.Diff_free_of regex -> (
      match Str.regexp regex with
      | exception Failure message -> Error ("invalid regex: " ^ message)
      | compiled -> (
          let matched =
            List.find_opt
              (fun line ->
                match Str.search_forward compiled line 0 with
                | _ -> true
                | exception Not_found -> false)
              (diff_added_lines diff)
          in
          match matched with
          | None -> Ok ()
          | Some line -> Error ("diff contains forbidden line: " ^ line)))

let sample_mean samples =
  match samples with
  | [] -> invalid_arg "spice-eval: sample mean of empty list"
  | _ :: _ ->
      List.fold_left
        (fun total sample -> total +. sample.Eval.Result.sample_score)
        0. samples
      /. float_of_int (List.length samples)

let collect_findings ~evaluate ?judge checks =
  let judge_finding check criterion =
    match judge with
    | None -> Eval.Result.skipped check
    | Some judge -> (
        match judge ~criterion with
        | [] -> Eval.Result.skipped check
        | samples ->
            Eval.Result.scored check ~score:(sample_mean samples) ~samples)
  in
  let rec loop acc gate_failed = function
    | [] -> List.rev acc
    | check :: rest when gate_failed ->
        loop (Eval.Result.skipped check :: acc) true rest
    | check :: rest -> (
        match check with
        | Eval.Check.Gate { test; _ } -> (
            match evaluate test with
            | Ok () -> loop (Eval.Result.passed check :: acc) false rest
            | Error message ->
                loop (Eval.Result.failed check message :: acc) true rest)
        | Eval.Check.Penalty { test; _ } -> (
            match evaluate test with
            | Ok () -> loop (Eval.Result.passed check :: acc) false rest
            | Error message ->
                loop (Eval.Result.failed check message :: acc) false rest)
        | Eval.Check.Judge { criterion; _ } ->
            loop (judge_finding check criterion :: acc) false rest)
  in
  loop [] false checks

(* The spice adapter: drives [spice run --json] and reads the metrics member
   of the final JSONL event, which is exactly the product surface the eval
   milestone adds. The task prompt is passed verbatim. *)

let spice_run ~bin ~model ctx ~prompt =
  let artifact path fallback =
    match ctx.Agent.artifact_dir with
    | None -> Filename.temp_file "spice-eval-agent" fallback
    | Some dir -> Filename.concat dir path
  in
  let stdout_path = artifact "agent.jsonl" ".jsonl" in
  let stderr_path = artifact "agent.stderr" ".stderr" in
  let args =
    [
      bin;
      "run";
      "--json";
      "--cwd";
      ctx.Agent.workspace;
      "--permission-mode";
      "bypass";
      "--sandbox";
      "danger-full-access";
    ]
    @ (match model with None -> [] | Some model -> [ "--model"; model ])
    @ (match ctx.Agent.max_steps with
      | None -> []
      | Some max_steps -> [ "--max-steps"; string_of_int max_steps ])
    @ [ prompt ]
  in
  let result =
    run_process ?timeout_s:ctx.Agent.timeout_s ~env_extra:ctx.Agent.env_extra
      ~cwd:(Sys.getcwd ()) ~stdout_path ~stderr_path (Array.of_list args)
  in
  let log = Some stdout_path in
  if result.timed_out then
    Agent.Outcome.make ~status:Agent.Outcome.Timed_out
      ~duration_s:result.duration_s ?log ()
  else
    match final_json (String.split_on_char '\n' (read_file stdout_path)) with
    | None ->
        outcome_error ~duration_s:result.duration_s ?log
          ("agent did not produce JSONL: " ^ status_message result.status)
    | Some json -> (
        let status =
          match json_string_member "type" json with
          | Some "turn.finished" -> (
              match json_string_member "outcome" json with
              | Some "completed" -> Agent.Outcome.Completed
              | Some outcome ->
                  failed_status Eval.Result.Agent
                    ("spice turn finished with outcome: " ^ outcome)
              | None ->
                  failed_status Eval.Result.Agent
                    "turn.finished event is missing outcome")
          | Some "session.blocked" -> Agent.Outcome.Blocked
          | Some "session.failed" ->
              let detail =
                match json_member "error" json with
                | None -> "spice run failed"
                | Some error -> (
                    match
                      ( json_string_member "kind" error,
                        json_string_member "message" error )
                    with
                    | Some kind, Some message -> kind ^ ": " ^ message
                    | _ -> "spice run failed")
              in
              failed_status Eval.Result.Agent detail
          | Some other ->
              failed_status Eval.Result.Agent
                ("unexpected final event: " ^ other)
          | None ->
              failed_status Eval.Result.Agent "final event is missing type"
        in
        match
          Option.bind
            (json_member "metrics" json)
            (json_decode Spice_session.Metrics.jsont)
        with
        | None ->
            outcome_error ~duration_s:result.duration_s ?log
              "final event is missing metrics"
        | Some metrics ->
            let duration_s =
              match json_int_member "duration_ms" json with
              | None -> result.duration_s
              | Some ms -> float_of_int ms /. 1000.
            in
            Agent.Outcome.make ~status
              ~usage:(usage_of_llm metrics.Spice_session.Metrics.usage)
              ~turns:metrics.Spice_session.Metrics.turns
              ~tool_calls:metrics.Spice_session.Metrics.tool_calls
              ~tool_failures:metrics.Spice_session.Metrics.tool_failures
              ~tool_rejections:metrics.Spice_session.Metrics.tool_rejections
              ~duration_s ?log ())

(* Row identity and cost lookup use qualified [provider/model] ids; foreign
   CLIs want their own bare model id, so adapters strip the provider
   prefix. *)
let bare_model model =
  Option.map
    (fun model ->
      match String.split_first ~sep:"/" model with
      | None -> model
      | Some (_, model) -> model)
    model

(* The claude adapter: [claude -p --output-format json]. Claude Code reports
   usage and turns; tool-call counts are not exposed. *)

let claude_run ~model ctx ~prompt =
  let model = bare_model model in
  let artifact path fallback =
    match ctx.Agent.artifact_dir with
    | None -> Filename.temp_file "spice-eval-agent" fallback
    | Some dir -> Filename.concat dir path
  in
  let stdout_path = artifact "agent.json" ".json" in
  let stderr_path = artifact "agent.stderr" ".stderr" in
  let args =
    [
      "claude";
      "-p";
      "--output-format";
      "json";
      "--dangerously-skip-permissions";
    ]
    @ (match model with None -> [] | Some model -> [ "--model"; model ])
    @ (match ctx.Agent.max_steps with
      | None -> []
      | Some max_steps -> [ "--max-turns"; string_of_int max_steps ])
    @ [ prompt ]
  in
  let result =
    run_process ?timeout_s:ctx.Agent.timeout_s ~env_extra:ctx.Agent.env_extra
      ~cwd:ctx.Agent.workspace ~stdout_path ~stderr_path (Array.of_list args)
  in
  let log = Some stdout_path in
  if result.timed_out then
    Agent.Outcome.make ~status:Agent.Outcome.Timed_out
      ~duration_s:result.duration_s ?log ()
  else
    match final_json (String.split_on_char '\n' (read_file stdout_path)) with
    | None ->
        outcome_error ~duration_s:result.duration_s ?log
          ("agent did not produce JSON: " ^ status_message result.status)
    | Some json ->
        let status =
          match json_string_member "subtype" json with
          | Some "success" -> Agent.Outcome.Completed
          | Some other ->
              failed_status Eval.Result.Agent ("claude result subtype: " ^ other)
          | None ->
              failed_status Eval.Result.Agent "claude result has no subtype"
        in
        let usage =
          Option.map
            (fun usage ->
              let lane name =
                Option.value (json_int_member name usage) ~default:0
              in
              usage_of_lanes ~input:(lane "input_tokens")
                ~output:(lane "output_tokens") ~reasoning:0
                ~cache_read:(lane "cache_read_input_tokens")
                ~cache_write:(lane "cache_creation_input_tokens"))
            (json_member "usage" json)
        in
        let duration_s =
          match json_int_member "duration_ms" json with
          | None -> result.duration_s
          | Some ms -> float_of_int ms /. 1000.
        in
        Agent.Outcome.make ~status ?usage
          ?turns:(json_int_member "num_turns" json)
          ~duration_s ?log ()

(* The codex adapter: [codex exec --json] JSONL events; usage comes from
   [turn.completed] events. Codex reports input tokens inclusive of cached
   tokens and output tokens inclusive of reasoning tokens. *)

let codex_run ~model ctx ~prompt =
  let model = bare_model model in
  let artifact path fallback =
    match ctx.Agent.artifact_dir with
    | None -> Filename.temp_file "spice-eval-agent" fallback
    | Some dir -> Filename.concat dir path
  in
  let stdout_path = artifact "agent.jsonl" ".jsonl" in
  let stderr_path = artifact "agent.stderr" ".stderr" in
  let args =
    [ "codex"; "exec"; "--json"; "--skip-git-repo-check"; "--full-auto" ]
    @ (match model with None -> [] | Some model -> [ "--model"; model ])
    @ [ prompt ]
  in
  let result =
    run_process ?timeout_s:ctx.Agent.timeout_s ~env_extra:ctx.Agent.env_extra
      ~cwd:ctx.Agent.workspace ~stdout_path ~stderr_path (Array.of_list args)
  in
  let log = Some stdout_path in
  if result.timed_out then
    Agent.Outcome.make ~status:Agent.Outcome.Timed_out
      ~duration_s:result.duration_s ?log ()
  else
    let events = jsonl_events (read_file stdout_path) in
    let typed type_ =
      List.filter
        (fun json -> json_string_member "type" json = Some type_)
        events
    in
    let completed = typed "turn.completed" in
    let failed = typed "turn.failed" @ typed "error" in
    let status =
      match (completed, failed, process_success result.status) with
      | _ :: _, [], true -> Agent.Outcome.Completed
      | _, _ :: _, _ -> failed_status Eval.Result.Agent "codex turn failed"
      | _, _, false ->
          failed_status Eval.Result.Agent
            ("codex exec failed: " ^ status_message result.status)
      | [], [], true ->
          failed_status Eval.Result.Agent
            "codex emitted no turn.completed event"
    in
    let usage =
      match
        List.filter_map (fun json -> json_member "usage" json) completed
      with
      | [] -> None
      | usages ->
          let lane name =
            List.fold_left
              (fun total usage ->
                total + Option.value (json_int_member name usage) ~default:0)
              0 usages
          in
          let cached = lane "cached_input_tokens" in
          let reasoning = lane "reasoning_output_tokens" in
          Some
            (usage_of_lanes
               ~input:(lane "input_tokens" - cached)
               ~output:(lane "output_tokens" - reasoning)
               ~reasoning ~cache_read:cached ~cache_write:0)
    in
    Agent.Outcome.make ~status ?usage ~turns:(List.length completed)
      ~duration_s:result.duration_s ?log ()

(* The cmd adapter runs an arbitrary shell command in the workspace with the
   prompt in SPICE_EVAL_PROMPT. It reports no model metrics; it exists to
   exercise the harness deterministically. *)

let cmd_run command ctx ~prompt =
  let artifact path fallback =
    match ctx.Agent.artifact_dir with
    | None -> Filename.temp_file "spice-eval-agent" fallback
    | Some dir -> Filename.concat dir path
  in
  let stdout_path = artifact "agent.stdout" ".stdout" in
  let stderr_path = artifact "agent.stderr" ".stderr" in
  let result =
    run_shell ?timeout_s:ctx.Agent.timeout_s
      ~env_extra:(("SPICE_EVAL_PROMPT", prompt) :: ctx.Agent.env_extra)
      ~cwd:ctx.Agent.workspace ~stdout_path ~stderr_path command
  in
  if result.timed_out then
    Agent.Outcome.make ~status:Agent.Outcome.Timed_out
      ~duration_s:result.duration_s ~log:stdout_path ()
  else if process_success result.status then
    Agent.Outcome.make ~status:Agent.Outcome.Completed
      ~duration_s:result.duration_s ~log:stdout_path ()
  else
    outcome_error ~duration_s:result.duration_s ~log:stdout_path
      ("agent command failed: " ^ status_message result.status)

let noop_run ctx ~prompt =
  ignore ctx;
  ignore prompt;
  Agent.Outcome.make ~status:Agent.Outcome.Completed ~duration_s:0. ()

(* Agent selection *)

type agent_kind = Spice | Noop | Claude | Codex | Cmd of string

let agent_kind_of_string raw =
  match raw with
  | "spice" -> Ok Spice
  | "noop" -> Ok Noop
  | "claude" -> Ok Claude
  | "codex" -> Ok Codex
  | _ when String.starts_with ~prefix:"cmd:" raw ->
      let command = String.drop_first 4 raw in
      if String.trim command = "" then
        Error (`Msg "cmd: agent requires a non-empty command")
      else Ok (Cmd command)
  | _ ->
      Error
        (`Msg
           (Printf.sprintf
              "unsupported agent %S; supported: spice, claude, codex, noop, \
               cmd:COMMAND"
              raw))

let pp_agent_kind ppf = function
  | Spice -> Format.pp_print_string ppf "spice"
  | Noop -> Format.pp_print_string ppf "noop"
  | Claude -> Format.pp_print_string ppf "claude"
  | Codex -> Format.pp_print_string ppf "codex"
  | Cmd command -> Format.fprintf ppf "cmd:%s" command

let make_agent kind ~spice_bin ~model =
  match kind with
  | Spice ->
      ( Agent.v ~name:"spice" (spice_run ~bin:spice_bin ~model),
        command_version spice_bin )
  | Noop -> (Agent.v ~name:"noop" noop_run, Some "builtin-noop")
  | Claude ->
      (Agent.v ~name:"claude" (claude_run ~model), command_version "claude")
  | Codex -> (Agent.v ~name:"codex" (codex_run ~model), command_version "codex")
  | Cmd command -> (Agent.v ~name:"cmd" (cmd_run command), None)

(* Judge: each sample is one [spice run] call with the judge model in a fresh
   directory; the response must be a JSON object with score and rationale. *)

let truncate_text limit text =
  if String.length text <= limit then text
  else String.sub text 0 limit ^ "\n[... truncated ...]"

let judge_prompt ~criterion ~task_prompt ~diff =
  String.concat "\n"
    [
      "You are an impartial code-review judge for an OCaml coding-agent \
       evaluation.";
      "Score how well the change below satisfies the criterion, as a number \
       between 0 and 1.";
      "Do not use any tools and do not inspect any files: judge only from the \
       material below.";
      "Respond with ONLY a JSON object of the form {\"score\": <number>, \
       \"rationale\": <short string>}.";
      "";
      "Criterion: " ^ criterion;
      "";
      "Task given to the agent:";
      task_prompt;
      "";
      "Unified diff produced by the agent:";
      truncate_text 16_000 diff;
    ]

let parse_judge_reply text =
  let trimmed = String.trim text in
  let candidate =
    match decode_json trimmed with
    | Ok json -> Some json
    | Error _ -> (
        match (String.index_opt trimmed '{', String.rindex_opt trimmed '}') with
        | Some start, Some stop when stop > start -> (
            match decode_json (String.sub trimmed start (stop - start + 1)) with
            | Ok json -> Some json
            | Error _ -> None)
        | _ -> None)
  in
  Option.bind candidate @@ fun json ->
  Option.map
    (fun score ->
      let score = Float.max 0. (Float.min 1. score) in
      let rationale =
        match json_string_member "rationale" json with
        | Some rationale when String.trim rationale <> "" -> rationale
        | Some _ | None -> "no rationale"
      in
      { Eval.Result.sample_score = score; rationale })
    (json_float_member "score" json)

let judge_sample ~spice_bin ~judge_model ~artifact_dir ~counter ~prompt =
  incr counter;
  let dir =
    Filename.concat artifact_dir (Printf.sprintf "judge-%02d" !counter)
  in
  ensure_dir dir;
  let stdout_path = Filename.concat dir "judge.jsonl" in
  let stderr_path = Filename.concat dir "judge.stderr" in
  write_file (Filename.concat dir "judge-prompt.txt") prompt;
  let result =
    run_process ~timeout_s:180. ~cwd:(Sys.getcwd ()) ~stdout_path ~stderr_path
      [|
        spice_bin;
        "run";
        "--json";
        "--ephemeral";
        "--cwd";
        dir;
        "--model";
        judge_model;
        "--max-steps";
        "3";
        prompt;
      |]
  in
  if result.timed_out || not (process_success result.status) then None
  else
    Option.bind (final_json (String.split_on_char '\n' (read_file stdout_path)))
    @@ fun json ->
    match
      (json_string_member "type" json, json_string_member "final_text" json)
    with
    | Some "turn.finished", Some text -> parse_judge_reply text
    | _ -> None

let make_judge ~spice_bin ~judge_model ~judge_samples ~artifact_dir ~task_prompt
    ~diff =
  match judge_model with
  | None -> None
  | Some judge_model ->
      let counter = ref 0 in
      Some
        (fun ~criterion ->
          let prompt = judge_prompt ~criterion ~task_prompt ~diff in
          List.init judge_samples (fun _ ->
              match
                judge_sample ~spice_bin ~judge_model ~artifact_dir ~counter
                  ~prompt
              with
              | sample -> sample
              | exception _ -> None)
          |> List.filter_map Fun.id)

(* One run *)

let default_timeout_s = 600.

let setup_workspace ~env_extra task workspace artifact_dir =
  let rec loop index = function
    | [] -> Ok ()
    | command :: rest ->
        let stdout_path =
          Filename.concat artifact_dir
            (Printf.sprintf "setup-%02d.stdout" index)
        in
        let stderr_path =
          Filename.concat artifact_dir
            (Printf.sprintf "setup-%02d.stderr" index)
        in
        let result =
          run_shell ~env_extra ~cwd:workspace ~stdout_path ~stderr_path command
        in
        if process_success result.status then loop (index + 1) rest
        else
          Error
            ("setup failed: " ^ command ^ ": " ^ status_message result.status)
  in
  loop 1 (Eval.Task.setup task)

let skipped_findings task = List.map Eval.Result.skipped (Eval.Task.checks task)

let run_one ~result_dir ~rows_path ~env_extra ~agent ~agent_version ~model
    ~spice_bin ~spice_version ~judge_model ~judge_samples task run_index =
  let artifact_dir = run_artifact_dir result_dir task run_index in
  let workspace = Filename.concat artifact_dir "workspace" in
  ensure_dir workspace;
  let series =
    {
      Eval.Result.task = Eval.Task.id task;
      agent =
        {
          Eval.Result.name = Agent.name agent;
          Eval.Result.version = agent_version;
          Eval.Result.model;
        };
      spice_version;
      judge_model;
    }
  in
  let finish outcome findings =
    let row =
      Eval.Result.make ~series ~run_index ~status:outcome.Agent.Outcome.status
        ~metrics:outcome.Agent.Outcome.metrics ~findings ()
    in
    append_line rows_path (encode_row row);
    row
  in
  match materialize_source (Eval.Task.source task) workspace artifact_dir with
  | Error message ->
      finish
        (outcome_error ~stage:Eval.Result.Harness message)
        (skipped_findings task)
  | Ok () -> (
      match setup_workspace ~env_extra task workspace artifact_dir with
      | Error message ->
          finish
            (outcome_error ~stage:Eval.Result.Setup message)
            (skipped_findings task)
      | Ok () -> (
          match git_baseline workspace artifact_dir with
          | Error message ->
              finish
                (outcome_error ~stage:Eval.Result.Harness message)
                (skipped_findings task)
          | Ok () ->
              let limits = Eval.Task.limits task in
              let ctx =
                {
                  Agent.workspace;
                  max_steps =
                    Option.bind limits (fun limits -> limits.Eval.Task.steps);
                  timeout_s =
                    Some
                      (Option.value
                         (Option.bind limits (fun limits ->
                              limits.Eval.Task.timeout_s))
                         ~default:default_timeout_s);
                  artifact_dir = Some artifact_dir;
                  env_extra;
                }
              in
              let outcome =
                match Agent.run agent ctx ~prompt:(Eval.Task.prompt task) with
                | outcome -> outcome
                | exception exn ->
                    outcome_error
                      ("agent adapter raised: " ^ Printexc.to_string exn)
              in
              let diff_files, diff =
                match capture_diff workspace artifact_dir with
                | Ok diff -> diff
                | Error message ->
                    write_file
                      (Filename.concat artifact_dir "diff-error.txt")
                      message;
                    ([], "")
              in
              let cmd_counter = ref 0 in
              let evaluate_cmd command =
                incr cmd_counter;
                let stdout_path =
                  Filename.concat artifact_dir
                    (Printf.sprintf "check-cmd-%02d.stdout" !cmd_counter)
                in
                let stderr_path =
                  Filename.concat artifact_dir
                    (Printf.sprintf "check-cmd-%02d.stderr" !cmd_counter)
                in
                let result =
                  run_shell ~timeout_s:default_timeout_s ~env_extra
                    ~cwd:workspace ~stdout_path ~stderr_path command
                in
                if process_success result.status then Ok ()
                else Error (status_message result.status)
              in
              let evaluate probe =
                evaluate_test ~shell:evaluate_cmd ~diff_files ~diff probe
              in
              let judge =
                make_judge ~spice_bin ~judge_model ~judge_samples ~artifact_dir
                  ~task_prompt:(Eval.Task.prompt task) ~diff
              in
              let findings =
                collect_findings ~evaluate ?judge (Eval.Task.checks task)
              in
              finish outcome findings))

(* CLI arguments *)

let suite =
  CArg.(
    value
    & opt (conv (Corpus.suite_of_string, Corpus.pp_suite)) Corpus.all_suite
    & info [ "suite" ] ~docv:"SUITE"
        ~doc:"Corpus suite: all, smoke, core, long, or robustness.")

let task_metadata key task = List.assoc_opt key (Eval.Task.metadata task)

let print_task ?(checks = false) task =
  let tier = Option.value (task_metadata "tier" task) ~default:"unknown" in
  let category =
    Option.value (task_metadata "category" task) ~default:"unknown"
  in
  let size = Option.value (task_metadata "size" task) ~default:"unknown" in
  stdout_printf "%s [%s/%s/%s] %a\n" (Eval.Task.id task) tier category size
    Eval.Task.pp_source (Eval.Task.source task);
  if checks then
    List.iter
      (fun check -> stdout_printf "  - %a\n" Eval.Check.pp check)
      (Eval.Task.checks task)

let list_command =
  let checks =
    CArg.(
      value & flag & info [ "checks" ] ~doc:"Show each task's grading checks.")
  in
  let run suite checks =
    let tasks = Corpus.tasks suite in
    if tasks = [] then
      stdout_printf "No tasks in suite %a yet.\n" Corpus.pp_suite suite
    else List.iter (print_task ~checks) tasks;
    0
  in
  CCmd.v
    (CCmd.info "list" ~doc:"List eval corpus tasks." ~exits)
    CTerm.(const run $ suite $ checks)

(* Reading rows *)

let rows_path path =
  if Sys.file_exists path && Sys.is_directory path then
    Filename.concat path "rows.jsonl"
  else path

let decode_row ~path ~line_no line =
  match Jsont_bytesrw.decode_string Eval.Result.jsont line with
  | Ok row -> Ok row
  | Error message ->
      Error
        (Printf.sprintf "%s:%d: invalid eval run row: %s" path line_no message)

let read_rows path =
  let path = rows_path path in
  match open_in path with
  | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn)
  | input -> (
      let rec loop line_no acc = function
        | None ->
            close_in input;
            Ok (List.rev acc)
        | Some line when String.trim line = "" ->
            loop (line_no + 1) acc
              (match input_line input with
              | line -> Some line
              | exception End_of_file -> None)
        | Some line -> (
            match decode_row ~path ~line_no line with
            | Ok row ->
                loop (line_no + 1) (row :: acc)
                  (match input_line input with
                  | line -> Some line
                  | exception End_of_file -> None)
            | Error message ->
                close_in_noerr input;
                Error message)
      in
      match input_line input with
      | line -> loop 1 [] (Some line)
      | exception End_of_file ->
          close_in input;
          Ok [])

(* Reports *)

let float_opt_string format = function
  | None -> "-"
  | Some value -> Printf.sprintf format value

let print_report_summary report =
  stdout_printf "\nSuccess rate: %.3f\n" (Eval.Report.success_rate report);
  stdout_printf "Mean score: %.3f\n" (Eval.Report.mean_score report);
  stdout_printf "Cost of success: %s\n"
    (float_opt_string "$%.4f" (Eval.Report.cost_of_success report));
  stdout_printf "Wasted cost: %s\n"
    (float_opt_string "$%.4f" (Eval.Report.wasted_cost report));
  stdout_printf "Cache hit rate: %s\n"
    (float_opt_string "%.1f%%"
       (Option.map
          (fun rate -> rate *. 100.)
          (Eval.Report.cache_hit_rate report)))

let print_text_report report =
  stdout_printf
    "Agent\tModel\tTask\tRuns\tSuccesses\tMean score\tIn tokens\tOut \
     tokens\tCost\tCache hit\n";
  List.iter
    (fun task ->
      let series = task.Eval.Report.series in
      let model =
        Option.value series.Eval.Result.agent.Eval.Result.model
          ~default:"default"
      in
      stdout_printf "%s\t%s\t%s\t%d\t%d\t%.3f\t%s\t%s\t%s\t%s\n"
        series.Eval.Result.agent.Eval.Result.name model series.Eval.Result.task
        task.Eval.Report.runs task.Eval.Report.successes
        task.Eval.Report.mean_score
        (float_opt_string "%.0f" task.Eval.Report.mean_success_input_tokens)
        (float_opt_string "%.0f" task.Eval.Report.mean_success_output_tokens)
        (float_opt_string "$%.4f" task.Eval.Report.mean_success_cost)
        (float_opt_string "%.1f%%"
           (Option.map
              (fun rate -> rate *. 100.)
              task.Eval.Report.mean_cache_hit)))
    (Eval.Report.tasks report);
  print_report_summary report

let print_markdown_report report =
  stdout_printf
    "| Agent | Model | Task | Runs | Successes | Mean score | In tokens | Out \
     tokens | Cost | Cache hit |\n";
  stdout_printf
    "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n";
  List.iter
    (fun task ->
      let series = task.Eval.Report.series in
      let model =
        Option.value series.Eval.Result.agent.Eval.Result.model
          ~default:"default"
      in
      stdout_printf "| %s | %s | %s | %d | %d | %.3f | %s | %s | %s | %s |\n"
        series.Eval.Result.agent.Eval.Result.name model series.Eval.Result.task
        task.Eval.Report.runs task.Eval.Report.successes
        task.Eval.Report.mean_score
        (float_opt_string "%.0f" task.Eval.Report.mean_success_input_tokens)
        (float_opt_string "%.0f" task.Eval.Report.mean_success_output_tokens)
        (float_opt_string "$%.4f" task.Eval.Report.mean_success_cost)
        (float_opt_string "%.1f%%"
           (Option.map
              (fun rate -> rate *. 100.)
              task.Eval.Report.mean_cache_hit)))
    (Eval.Report.tasks report);
  stdout_printf "\n";
  stdout_printf "- Success rate: %.3f\n" (Eval.Report.success_rate report);
  stdout_printf "- Mean score: %.3f\n" (Eval.Report.mean_score report);
  stdout_printf "- Cost of success: %s\n"
    (float_opt_string "$%.4f" (Eval.Report.cost_of_success report));
  stdout_printf "- Wasted cost: %s\n"
    (float_opt_string "$%.4f" (Eval.Report.wasted_cost report));
  stdout_printf "- Cache hit rate: %s\n"
    (float_opt_string "%.1f%%"
       (Option.map
          (fun rate -> rate *. 100.)
          (Eval.Report.cache_hit_rate report)))

let report_command =
  let markdown =
    CArg.(value & flag & info [ "markdown" ] ~doc:"Print Markdown output.")
  in
  let path =
    CArg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"PATH" ~doc:"rows.jsonl file or result directory.")
  in
  let warn_missing_rates rows =
    let missing =
      List.filter_map
        (fun row ->
          let series = Eval.Result.series row in
          match
            ( series.Eval.Result.agent.Eval.Result.model,
              (Eval.Result.metrics_of row).Eval.Result.usage )
          with
          | Some model, Some usage when Option.is_none (model_cost ~model usage)
            ->
              Some model
          | Some _, Some _ | Some _, None | None, Some _ | None, None -> None)
        rows
      |> List.sort_uniq String.compare
    in
    List.iter
      (fun model ->
        stderr_printf
          "spice-eval: no catalog rates for model %s; its cost columns \
           are            omitted\n"
          model)
      missing
  in
  let cost row =
    let series = Eval.Result.series row in
    match
      ( series.Eval.Result.agent.Eval.Result.model,
        (Eval.Result.metrics_of row).Eval.Result.usage )
    with
    | Some model, Some usage -> model_cost ~model usage
    | Some _, None | None, Some _ | None, None -> None
  in
  let run markdown path =
    match read_rows path with
    | Error message ->
        stderr_printf "spice-eval: %s\n" message;
        CCmd.Exit.some_error
    | Ok rows ->
        warn_missing_rates rows;
        let report = Eval.Report.of_results ~cost rows in
        if markdown then print_markdown_report report
        else print_text_report report;
        0
  in
  CCmd.v
    (CCmd.info "report" ~doc:"Summarize eval run rows." ~exits)
    CTerm.(const run $ markdown $ path)

let metric_string = function
  | Eval.Report.Success_rate -> "success-rate"
  | Eval.Report.Mean_score -> "mean-score"
  | Eval.Report.Cost_of_success -> "cost-of-success"
  | Eval.Report.Cache_hit_rate -> "cache-hit-rate"

let verdict_string = function
  | Eval.Report.Improved -> "improved"
  | Eval.Report.Regressed -> "regressed"
  | Eval.Report.Unchanged -> "unchanged"

let compare_command =
  let baseline =
    CArg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"BASELINE" ~doc:"Baseline rows.jsonl or result directory.")
  in
  let current =
    CArg.(
      required
      & pos 1 (some string) None
      & info [] ~docv:"CURRENT" ~doc:"Current rows.jsonl or result directory.")
  in
  let run baseline current =
    match (read_rows baseline, read_rows current) with
    | Error message, _ | _, Error message ->
        stderr_printf "spice-eval: %s\n" message;
        CCmd.Exit.some_error
    | Ok baseline_rows, Ok current_rows ->
        let cost row =
          let series = Eval.Result.series row in
          match
            ( series.Eval.Result.agent.Eval.Result.model,
              (Eval.Result.metrics_of row).Eval.Result.usage )
          with
          | Some model, Some usage -> model_cost ~model usage
          | Some _, None | None, Some _ | None, None -> None
        in
        let baseline = Eval.Report.of_results ~cost baseline_rows in
        let current = Eval.Report.of_results ~cost current_rows in
        let verdicts = Eval.Report.compare ~baseline current in
        let task_verdicts = Eval.Report.compare_tasks ~baseline current in
        List.iter
          (fun (metric, verdict) ->
            stdout_printf "%s\t%s\n" (metric_string metric)
              (verdict_string verdict))
          verdicts;
        List.iter
          (fun (series, verdict) ->
            let model =
              Option.value series.Eval.Result.agent.Eval.Result.model
                ~default:"default"
            in
            stdout_printf "task\t%s/%s/%s\t%s\n"
              series.Eval.Result.agent.Eval.Result.name model
              series.Eval.Result.task (verdict_string verdict))
          task_verdicts;
        let regressed verdict = verdict = Eval.Report.Regressed in
        if
          List.exists (fun (_, verdict) -> regressed verdict) verdicts
          || List.exists (fun (_, verdict) -> regressed verdict) task_verdicts
        then 1
        else 0
  in
  CCmd.v
    (CCmd.info "compare" ~doc:"Compare two eval reports." ~exits)
    CTerm.(const run $ baseline $ current)

(* Run command *)

let run_command =
  let agent =
    CArg.(
      value
      & opt (conv (agent_kind_of_string, pp_agent_kind)) Spice
      & info [ "agent" ] ~docv:"AGENT"
          ~doc:"Agent adapter: spice, claude, codex, noop, or cmd:COMMAND.")
  in
  let model =
    CArg.(
      value
      & opt (some string) None
      & info [ "model" ] ~docv:"MODEL"
          ~doc:
            "Model identifier (provider/model). Recorded in row identity and \
             used for cost reporting.")
  in
  let runs =
    CArg.(value & opt int 1 & info [ "runs" ] ~docv:"N" ~doc:"Runs per task.")
  in
  let tasks =
    CArg.(
      value & opt_all string []
      & info [ "task" ] ~docv:"ID" ~doc:"Run only this task id (repeatable).")
  in
  let judge_model =
    CArg.(
      value
      & opt (some string) None
      & info [ "judge-model" ] ~docv:"MODEL"
          ~doc:
            "Judge quality checks with this model via spice run. Quality \
             checks are skipped when absent.")
  in
  let judge_samples =
    CArg.(
      value & opt int 3
      & info [ "judge-samples" ] ~docv:"N"
          ~doc:"Judge samples per quality criterion.")
  in
  let output =
    CArg.(
      value
      & opt (some string) None
      & info [ "output" ] ~docv:"DIR" ~doc:"Result directory.")
  in
  let run suite agent_kind model runs task_filter judge_model judge_samples
      output =
    if runs < 1 then (
      stderr_printf "spice-eval: --runs must be positive\n";
      CCmd.Exit.some_error)
    else if judge_samples < 1 then (
      stderr_printf "spice-eval: --judge-samples must be positive\n";
      CCmd.Exit.some_error)
    else
      let all_tasks = Corpus.tasks suite in
      let tasks =
        match task_filter with
        | [] -> all_tasks
        | ids ->
            List.filter (fun task -> List.mem (Eval.Task.id task) ids) all_tasks
      in
      let unknown =
        List.filter
          (fun id ->
            not
              (List.exists
                 (fun task -> String.equal (Eval.Task.id task) id)
                 all_tasks))
          task_filter
      in
      if unknown <> [] then (
        stderr_printf "spice-eval: unknown task ids: %s\n"
          (String.concat ", " unknown);
        CCmd.Exit.some_error)
      else
        let result_dir = make_result_dir output in
        let rows_path = Filename.concat result_dir "rows.jsonl" in
        let spice_bin = default_spice_bin () in
        let spice_version = current_git_rev () in
        let env_extra = ocaml_toolchain_env () in
        let agent, agent_version = make_agent agent_kind ~spice_bin ~model in
        List.iter
          (fun task ->
            for run_index = 0 to runs - 1 do
              let row =
                run_one ~result_dir ~rows_path ~env_extra ~agent ~agent_version
                  ~model ~spice_bin ~spice_version ~judge_model ~judge_samples
                  task run_index
              in
              stdout_printf "%a\n" Eval.Result.pp row
            done)
          tasks;
        stdout_printf "rows: %s\n" rows_path;
        0
  in
  CCmd.v
    (CCmd.info "run" ~doc:"Run eval tasks." ~exits)
    CTerm.(
      const run $ suite $ agent $ model $ runs $ tasks $ judge_model
      $ judge_samples $ output)

let command =
  let man =
    [
      `S CManpage.s_description;
      `P
        "spice-eval runs and reports on the Spice evaluation corpus: it \
         materializes task workspaces, drives coding agents headlessly, grades \
         the result with the task's checks, and aggregates rows into \
         comparable reports.";
    ]
  in
  CCmd.group
    (CCmd.info "spice-eval" ~doc:"Run and report Spice evaluations." ~man ~exits)
    [ list_command; run_command; report_command; compare_command ]

let () = exit (CCmd.eval' command)
