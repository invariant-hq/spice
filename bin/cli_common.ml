(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Cmdliner
open Result.Syntax

type exit_status =
  | Success
  | Failed
  | Usage_error of string
  | Runtime_error of string
  | Blocked of string
(* A saved session needs user action before it can continue. Not an
         error: the message carries the continuation commands, and the
         dedicated exit code lets scripts branch on "actionable block" versus
         "error" without parsing output. *)

(* A CLI journey fails in one of these ways: invalid command-line input
   ([`Usage]), a session store or pure document operation
   ([`Session_store], [`Session_document]), a host assembly error caused by
   explicit user input such as [--model] ([`Invalid_input], also a usage
   failure), a host assembly error caused by host state ([`Assembly]), a session
   execution error ([`Execution]), a host artifact storage error ([`Sidecar]),
   or a CLI runtime check with no structured owner ([`Runtime]).
   [status] is the single rendering boundary: every structured error becomes a
   diagnostic (message plus "Hint:" lines). *)
type error =
  [ `Usage of string
  | `Runtime of string
  | `Session_store of Spice_session.Id.t option * Spice_session_store.Error.t
  | `Session_document of Spice_session.Id.t * Spice_session.Error.t
  | `Invalid_input of Spice_host.Host.Error.t
  | `Assembly of Spice_host.Host.Error.t
  | `Execution of Spice_protocol.Error.t
  | `Sidecar of Spice_host.Artifacts.Error.t ]

let usage message = Error (`Usage message)

let invalid_input result =
  Result.map_error (fun error -> `Invalid_input error) result

let assembly result = Result.map_error (fun error -> `Assembly error) result
let execution result = Result.map_error (fun error -> `Execution error) result

let session_store ?id result =
  Result.map_error (fun error -> `Session_store (id, error)) result

let session_document ~id result =
  Result.map_error (fun error -> `Session_document (id, error)) result

let sidecar result = Result.map_error (fun error -> `Sidecar error) result
let diagnostic message = Spice_diagnostic.make message

let session_document_diagnostic id error =
  match error with
  | Spice_session.Error.Archived ->
      Spice_protocol.Error.diagnostic (Spice_protocol.Error.Archived id)
  | Spice_session.Error.Deleted ->
      Spice_protocol.Error.diagnostic (Spice_protocol.Error.Deleted id)
  | Spice_session.Error.Active_turn turn ->
      Spice_protocol.Error.diagnostic
        (Spice_protocol.Error.Active_turn_exists turn)
  | Spice_session.Error.State _ | Spice_session.Error.Replay _
  | Spice_session.Error.Unknown_turn _
  | Spice_session.Error.Turn_not_finished _ ->
      diagnostic (Spice_session.Error.message error)

let session_store_diagnostic id error =
  match error with
  | Spice_session_store.Error.Corrupt _ ->
      (* The store's corrupt diagnostic names the on-disk artifact and its
         decode failure; the protocol [Storage] flattening would lose them. *)
      Spice_session_store.Error.diagnostic ?id error
  | error ->
      Spice_protocol.Error.diagnostic (Spice_host.Session.store_error error)

let status (result : (exit_status, error) result) =
  let render diagnostic = Spice_diagnostic.to_string diagnostic in
  match result with
  | Ok status -> status
  | Error (`Usage message) -> Usage_error message
  | Error (`Runtime message) -> Runtime_error message
  | Error (`Session_store (id, error)) ->
      Runtime_error (render (session_store_diagnostic id error))
  | Error (`Session_document (id, error)) ->
      Runtime_error (render (session_document_diagnostic id error))
  | Error (`Invalid_input error) ->
      Usage_error (render (Spice_host.Host.Error.diagnostic error))
  | Error (`Assembly error) ->
      Runtime_error (render (Spice_host.Host.Error.diagnostic error))
  | Error (`Execution error) ->
      Runtime_error (render (Spice_protocol.Error.diagnostic error))
  | Error (`Sidecar error) ->
      Runtime_error (render (Spice_host.Artifacts.Error.diagnostic error))

(* Top-level help sections; commands opt in via [Cmd.info ~docs] and
   [bin/main.ml] orders the sections in the root man page. *)
let s_run_commands = "RUN COMMANDS"
let s_session_commands = "SESSION COMMANDS"
let s_config_commands = "CONFIGURATION COMMANDS"
let s_diagnostic_commands = "DIAGNOSTIC COMMANDS"

(* Option sections for flag-heavy commands; args opt in via [Arg.info ~docs]. *)
let s_sandbox_options = "SANDBOX AND PERMISSION OPTIONS"
let s_context_options = "CONTEXT OPTIONS"

let exits =
  Cmd.Exit.
    [
      info 0 ~doc:"on success.";
      info 1 ~doc:"if a runtime error happened.";
      info 2 ~doc:"if command input is invalid.";
      info 3 ~doc:"if the session is blocked on user action.";
      info 124 ~doc:"if command-line parsing fails.";
      info 125 ~doc:"if an unexpected internal error happens.";
    ]

let stdout_printf fmt = Printf.printf (fmt ^^ "%!")
let stderr_printf fmt = Printf.eprintf (fmt ^^ "%!")

(* The one human table renderer: column widths from content, two-space
   separators, last column unpadded so free-form text never drags trailing
   spaces. Every tabular surface goes through here so alignment cannot
   diverge between commands. *)
let print_table ~header rows =
  (* Column width in codepoints, not bytes, so multibyte cell content such as
     the … fingerprint prefix does not skew padding. *)
  let cell_width cell =
    String.fold_left
      (fun count char ->
        if Char.code char land 0xC0 <> 0x80 then count + 1 else count)
      0 cell
  in
  let widths =
    List.fold_left
      (fun widths row ->
        let rec loop widths cells =
          match (widths, cells) with
          | _, [] -> widths
          | [], cell :: cells -> cell_width cell :: loop [] cells
          | width :: widths, cell :: cells ->
              max width (cell_width cell) :: loop widths cells
        in
        loop widths row)
      [] (header :: rows)
  in
  let pad width cell =
    cell ^ String.make (max 0 (width - cell_width cell)) ' '
  in
  let trim_right line =
    let length = ref (String.length line) in
    while !length > 0 && Char.equal line.[!length - 1] ' ' do
      decr length
    done;
    String.sub line 0 !length
  in
  let print_row row =
    let rec cells widths row =
      match (widths, row) with
      | _, [] -> []
      | _, [ last ] -> [ last ]
      | width :: widths, cell :: row -> pad width cell :: cells widths row
      | [], cell :: row -> cell :: cells [] row
    in
    stdout_printf "%s\n" (trim_right (String.concat "  " (cells widths row)))
  in
  print_row header;
  List.iter print_row rows

let absolute_cwd stdenv cwd_text =
  let process_cwd =
    let cwd = Eio.Path.native_exn (Eio.Stdenv.cwd stdenv) in
    if Filename.is_relative cwd then Sys.getcwd () else cwd
  in
  match Spice_path.Abs.of_string process_cwd with
  | Error error -> Error (process_cwd ^ ": " ^ Spice_path.Error.message error)
  | Ok base -> (
      match Spice_path.Abs.resolve_any ~base cwd_text with
      | Ok cwd -> Ok cwd
      | Error error -> Error (cwd_text ^ ": " ^ Spice_path.Error.message error))

let optional_absolute_cwd stdenv = function
  | None -> Ok None
  | Some cwd -> Result.map Option.some (absolute_cwd stdenv cwd)

(* The session scope root is the host workspace root. *)
let host_cwd host =
  Result.map
    (fun workspace -> Spice_workspace.Path.abs (Spice_workspace.cwd workspace))
    (Spice_host.workspace host)

(* Corrupt store entries never fail a listing; every consumer reports them
   with the same loud stderr line — one line per document, first diagnostic
   line only, pointing at doctor for the full trace. *)
let warn_corrupt corrupt =
  List.iter
    (fun corrupt ->
      let message =
        let message = Spice_session_store.Corrupt.message corrupt in
        match String.split_first ~sep:"\n" message with
        | Some (line, _) -> line
        | None -> message
      in
      stderr_printf
        "spice: corrupt session document at %s: %s; run `spice doctor` for \
         details\n"
        (Spice_session_store.Corrupt.path corrupt)
        message)
    corrupt

(* Session helpers shared by the [session] and [run] surfaces. *)

let now stdenv =
  Eio.Time.now (Eio.Stdenv.clock stdenv)
  |> Spice_session.Time.of_unix_seconds_float

let in_cwd cwd document =
  let metadata =
    Spice_session.metadata (Spice_session_store.Document.session document)
  in
  Spice_path.Abs.equal cwd (Spice_session.Metadata.cwd metadata)

let validate_title = function
  | Some "" -> usage "session title must not be empty"
  | Some _ | None -> Ok ()

let shell_arg = Filename.quote

(* The newest saved session in the host workspace: the target of [--last]
   and bare-resume continuations. [surface] selects the invocation wording
   of the guidance messages: the interactive resume surface or the headless
   run surface. *)
let newest_session_in_cwd ~surface ~stdenv host =
  let resume_invocation =
    match surface with
    | `Tui -> "spice resume "
    | `Headless -> "spice run resume "
  in
  let store = Spice_host.Session.store ~stdenv host in
  let* cwd = assembly (host_cwd host) in
  let* summary, corrupt =
    execution (Spice_host.Session.newest_in_cwd store ~cwd)
  in
  warn_corrupt corrupt;
  match summary with
  | Some summary -> Ok summary.Spice_protocol.Session_summary.id
  | None ->
      let* all_documents, _all_corrupt =
        session_store (Spice_session_store.list store ~limit:1 ())
      in
      let message =
        match (all_documents, corrupt) with
        | document :: _, _ ->
            let session = Spice_session_store.Document.session document in
            let metadata = Spice_session.metadata session in
            "no session in "
            ^ Spice_path.Abs.to_string cwd
            ^ "; most recent session is "
            ^ shell_arg (Spice_session.Id.to_string (Spice_session.id session))
            ^ " in "
            ^ Spice_path.Abs.to_string (Spice_session.Metadata.cwd metadata)
            ^ "; run: cd "
            ^ shell_arg
                (Spice_path.Abs.to_string (Spice_session.Metadata.cwd metadata))
            ^ " && " ^ resume_invocation
            ^ shell_arg (Spice_session.Id.to_string (Spice_session.id session))
        | [], _ :: _ ->
            "no valid sessions in "
            ^ Spice_path.Abs.to_string cwd
            ^ "; corrupt session documents were found"
        | [], [] -> (
            match surface with
            | `Tui ->
                "no sessions found; run `spice session list` or start one with \
                 `spice`"
            | `Headless ->
                "no sessions found; run `spice session list` or start one with \
                 `spice run`")
      in
      Error (`Runtime message)

(* Session targets accept unique id prefixes: exact ids load directly, and a
   miss falls back to one prefix scan across every lifecycle, so long
   generated ids stay addressable by a distinguishing head. Zero matches
   report the original not-found; ambiguity fails loudly with candidates;
   corrupt documents never resolve. *)
let locate_session ~store raw =
  match Spice_session_store.load store raw with
  | Ok document -> Ok document
  | Error (Spice_session_store.Error.Not_found _) as not_found -> (
      let prefix = Spice_session.Id.to_string raw in
      let document_id document =
        Spice_session.Id.to_string
          (Spice_session.id (Spice_session_store.Document.session document))
      in
      let matches document =
        String.starts_with ~prefix (document_id document)
      in
      match
        Spice_session_store.list store ~include_archived:true
          ~include_deleted:true ~filter:matches ()
      with
      | Error _ | Ok ([], _) -> session_store ~id:raw not_found
      | Ok ([ document ], _) -> Ok document
      | Ok (documents, _) ->
          let candidates = List.map document_id documents in
          let shown = List.take 5 candidates in
          let suffix =
            if List.compare_lengths candidates shown > 0 then ", …" else ""
          in
          Error
            (`Runtime
               ("ambiguous session id prefix \"" ^ prefix ^ "\": matches "
              ^ String.concat ", " shown ^ suffix)))
  | Error _ as error -> session_store ~id:raw error

let session_document_cwd document =
  let session = Spice_session_store.Document.session document in
  Spice_session.metadata session |> Spice_session.Metadata.cwd

(* Explicit session continuations execute in the canonical cwd recorded by the
   session. The first host is only a global-store discovery context; after the
   document is found, reload project inputs for its workspace. An explicit
   [--cwd] is an assertion and must agree before any durable mutation. *)
let host_for_session ~stdenv ~overrides ~cwd_was_explicit discovery_host
    document =
  let recorded = session_document_cwd document in
  let requested =
    Spice_host.Host.config discovery_host |> Spice_host.Config.cwd
  in
  let recorded_text = Spice_path.Abs.to_string recorded in
  if cwd_was_explicit && not (Spice_path.Abs.equal requested recorded) then
    usage
      ("--cwd "
      ^ shell_arg (Spice_path.Abs.to_string requested)
      ^ " does not match the session cwd " ^ shell_arg recorded_text)
  else
    let path = Eio.Path.( / ) (Eio.Stdenv.fs stdenv) recorded_text in
    if not (Eio.Path.is_directory path) then
      Error
        (`Runtime ("session cwd is not an existing directory: " ^ recorded_text))
    else
      assembly
        (Spice_host.bootstrap ~stdenv ~registry:Spice_host_builtin.registry
           ~cwd:recorded_text ~overrides ())

(* The one resolver behind every SESSION-or---last surface: an explicit id or
   unique prefix wins, [--last] selects the newest session in this workspace,
   and their combination or absence is a usage error naming the command. *)
let resolve_session_target ~command ~surface ~stdenv host ~last session =
  let store = Spice_host.Session.store ~stdenv host in
  match (session, last) with
  | Some _, true -> usage "choose SESSION or --last, not both"
  | Some raw, false -> locate_session ~store raw
  | None, true ->
      let* id = newest_session_in_cwd ~surface ~stdenv host in
      session_store ~id (Spice_session_store.load store id)
  | None, false ->
      usage (command ^ " requires SESSION or --last; run `spice session list`")

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> failwith message

let json_encode codec value =
  match Jsont.Json.encode codec value with
  | Ok json -> json
  | Error message -> failwith message

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_null = Jsont.Json.null ()

let json_null_or_string = function
  | None -> json_null
  | Some value -> Jsont.Json.string value

let json_null_or_int = function
  | None -> json_null
  | Some value -> Jsont.Json.int value

let json_list values = Jsont.Json.list values

let json_envelope ~type_ fields =
  json_obj
    (("schema_version", Jsont.Json.int 1)
    :: ("type", Jsont.Json.string type_)
    :: fields)

(* Account rendering shared by auth and models surfaces. *)

let account_source_string source =
  match Spice_account.Credential.Source.tag source with
  | `Process -> "process"
  | `Env -> "env"
  | `Store -> "store"

let account_status_string account =
  Spice_account.State.to_string (Spice_account.state account)

let load_host ?cwd ~overrides stdenv =
  Spice_host.bootstrap ~stdenv ~registry:Spice_host_builtin.registry ?cwd
    ~overrides ()

let with_host ?cwd ?(overrides = []) f =
  Eio_main.run @@ fun stdenv ->
  match load_host ?cwd ~overrides stdenv with
  | Error error -> status (assembly (Error error))
  | Ok host -> f ~stdenv host

let with_loaded_host ?cwd ?(overrides = []) f =
  Eio_main.run @@ fun stdenv ->
  match load_host ?cwd ~overrides stdenv with
  | Error error -> status (assembly (Error error))
  | Ok host -> f ~stdenv host

(* Run assembly shared by [spice run] and [spice debug]: the debug surfaces
   print exactly what an exec run sends, so both build the same config. *)

(* One context load per invocation: the same snapshot supplies the prelude
   and the projection identity reported on execution events. *)
let host_skills ~stdenv host =
  Spice_host.Skills.load ~stdenv ~builtins:Spice_prompts.Skills.all
    (Spice_host.Host.config host)

let host_context ~stdenv host =
  Spice_host.Context.load ~stdenv (Spice_host.Host.config host)

let mode_prelude context mode =
  (* Mode instructions extend the host prelude, so rejecting the combined
     messages is an instruction failure like any other. *)
  Spice_host.Context.extend_prelude context
    (Spice_protocol.Mode.prelude_messages mode)
  |> Result.map_error (fun error -> Spice_host.Host.Error.Instructions error)

(* One rule table per invocation is the single source of truth for the run
   policy, the denial wording, blocked-output provenance, and `spice
   permission list`: durable config rules in descending layer precedence,
   then the active preset's rules. Every consumer receives this one value so
   the surfaces cannot disagree. *)
type permission_args = Spice_host.Config.Source.t Spice_host.Permission.Run.t

let permission_args host override =
  Spice_host.Config.permission_posture ?preset:override
    (Spice_host.Host.config host)

let source_kind_string = Spice_host.Config.Source.kind_string

(* The CLI sandbox surface: a per-run mode override and the per-run
   require-enforcement override, threaded as one value. *)
type sandbox_args = {
  sandbox_flag : Spice_host.Sandbox.Mode.t option;
  require_sandbox : bool;
}

(* One resolution feeds exec, debug, and the sandbox status surfaces. The
   require gate is separate so surfaces that only describe the posture can
   resolve without failing on unavailable backends. *)
let resolve_sandbox ~sw ~stdenv host ~workspace args =
  let process_env = Spice_host.Env.current () in
  let config = Spice_host.Host.config host in
  let sandbox_config = Spice_host.Config.sandbox config in
  let workspace_trusted =
    Spice_host.Config.workspace_trust config |> Spice_host.Trust.is_trusted
  in
  let require =
    if args.require_sandbox then Spice_host.Sandbox.Require.Enforced
    else Spice_host.Config.Sandbox.require sandbox_config
  in
  Spice_host.Sandbox.resolve ~sw ?flag:args.sandbox_flag
    ?config_mode:(Spice_host.Config.Sandbox.mode sandbox_config)
    ~require
    ~protect:(Spice_host.Config.sandbox_protected_roots config)
    ~read:(Spice_host.Config.Sandbox.read sandbox_config)
    ~readable_roots:(Spice_host.Config.Sandbox.readable_roots sandbox_config)
    ~writable_roots:(Spice_host.Config.Sandbox.writable_roots sandbox_config)
    ~network:(Spice_host.Config.Sandbox.network sandbox_config)
    ~workspace_trusted
    ~stdenv
    ~env:(Spice_host.Env.get process_env)
    ~workspace ()

let gate_sandbox effective =
  Spice_host.Sandbox.gate effective
  |> Result.map_error (fun error ->
      `Runtime (Spice_host.Sandbox.Gate_error.message error))

let exit_code = function
  | Success -> 0
  | Failed -> 1
  | Usage_error message ->
      stderr_printf "spice: %s\n" message;
      2
  | Runtime_error message ->
      stderr_printf "spice: %s\n" message;
      1
  | Blocked message ->
      stderr_printf "spice: %s\n" message;
      3

let exit_term term = Term.(const exit_code $ term)

(* Diagnostics logging is configured from the environment before Cmdliner
   runs: SPICE_LOG sets the level (logging is off when unset) and
   SPICE_LOG_FILE appends messages to a file instead of stderr. Level and
   reporter policy live here; libraries only declare sources and log. *)

let log_timestamp () =
  let now = Unix.gettimeofday () in
  let tm = Unix.localtime now in
  let ms = int_of_float (Float.rem now 1. *. 1000.) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec ms

let log_run_id =
  Printf.sprintf "%Ld-%d"
    (Int64.of_float (Unix.gettimeofday () *. 1_000_000.))
    (Unix.getpid ())

(* Every message flushes so a crashed or killed process keeps its trail. *)
let log_reporter oc =
  let formatter = Format.formatter_of_out_channel oc in
  (* Concurrent spice processes append to the same default log file; the pid
     is what lets a reader pull one process's trail back apart. *)
  let pid = Unix.getpid () in
  let report src level ~over k msgf =
    let k _ =
      Format.pp_print_flush formatter ();
      over ();
      k ()
    in
    msgf @@ fun ?header:_ ?tags:_ fmt ->
    Format.kfprintf k formatter
      ("%s [%d] [run=%s] %a [%s] @[" ^^ fmt ^^ "@]@.")
      (log_timestamp ()) pid log_run_id Logs.pp_level level (Logs.Src.name src)
  in
  { Logs.report }

let log_env_failure name message =
  stderr_printf "spice: %s: %s\n" name message;
  Stdlib.exit Cmd.Exit.cli_error

let log_level_of_env () =
  match Sys.getenv_opt "SPICE_LOG" with
  | None -> None
  | Some value -> (
      match Logs.level_of_string value with
      | Ok level -> level
      | Error (`Msg message) -> log_env_failure "SPICE_LOG" message)

let open_log_file path =
  match open_out_gen [ Open_append; Open_creat ] 0o600 path with
  | oc -> oc
  | exception Sys_error message -> log_env_failure "SPICE_LOG_FILE" message

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then (
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let state_home_or_fail () =
  match Spice_host.User_dirs.state_home Sys.getenv_opt with
  | Ok home -> home
  | Error error ->
      log_env_failure "SPICE_STATE_HOME"
        (Spice_host.User_dirs.Error.message error)

let cleanup_dir ~keep ~suffix ~current dir =
  let entries =
    try
      Sys.readdir dir |> Array.to_list
      |> List.filter_map (fun name ->
             let path = Filename.concat dir name in
             if String.equal path current || not (Filename.check_suffix name suffix)
             then None
             else
               try Some ((Unix.stat path).Unix.st_mtime, path)
               with Unix.Unix_error _ -> None)
      |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
    with Sys_error _ -> []
  in
  List.drop (Int.max 0 (keep - 1)) entries
  |> List.iter (fun (_, path) ->
         try Unix.unlink path
         with Unix.Unix_error _ | Sys_error _ -> ())

let save_latest_log ~dir ~path =
  let latest = Filename.concat dir "latest.json" in
  let tmp = latest ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let text = Printf.sprintf {|{"run_id":%S,"path":%S}\n|} log_run_id path in
  try
    let oc = open_out_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 tmp in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
        output_string oc text);
    Unix.rename tmp latest
  with Sys_error _ | Unix.Unix_error _ -> (
    try Unix.unlink tmp with Unix.Unix_error _ -> ())

let setup_log () =
  Logs_threaded.enable ();
  Logs.set_level ~all:true (log_level_of_env ());
  match Sys.getenv_opt "SPICE_LOG_FILE" with
  | Some path when Filename.is_relative path ->
      log_env_failure "SPICE_LOG_FILE" "must be an absolute path"
  | Some path -> Logs.set_reporter (log_reporter (open_log_file path))
  | None -> Logs.set_reporter (log_reporter stderr)

(* The TUI owns the terminal, so stderr logging would corrupt the screen.
   When logging is on with no explicit destination, divert it to a per-process
   file under state home before the runtime takes over. *)
let divert_logs_for_tui () =
  match (Logs.level (), Sys.getenv_opt "SPICE_LOG_FILE") with
  | None, _ | Some _, Some _ -> ()
  | Some _, None ->
      let dir = Filename.concat (state_home_or_fail ()) "logs" in
      mkdir_p dir;
      let path = Filename.concat dir (log_run_id ^ ".log") in
      let oc = open_log_file path in
      Logs.set_reporter (log_reporter oc);
      save_latest_log ~dir ~path;
      cleanup_dir ~keep:20 ~suffix:".log" ~current:path dir

let write_crash_report ~version () =
  match Spice_host.User_dirs.state_home Sys.getenv_opt with
  | Error _ -> ()
  | Ok home -> (
      let dir = Filename.concat home "crashes" in
      let path = Filename.concat dir (log_run_id ^ ".txt") in
      try
        mkdir_p dir;
        let oc = open_out_gen [ Open_wronly; Open_creat; Open_excl ] 0o600 path in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
            Printf.fprintf oc
              "spice_version=%s\nrun_id=%s\npid=%d\nkind=uncaught_exception\n%s"
              version log_run_id (Unix.getpid ())
              (Printexc.get_backtrace ()));
        cleanup_dir ~keep:20 ~suffix:".txt" ~current:path dir
      with Sys_error _ | Unix.Unix_error _ -> ())
