(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "shell"
let description = Spice_prompts.Tools.shell

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()
let contains_nul s = String.contains s '\000'

module Input = struct
  type t = {
    command : string;
    workdir : string option;
    timeout_ms : int option;
    description : string option;
    escalate : bool;
  }

  type field = Command | Workdir | Description

  type error =
    | Empty of field
    | Contains_nul of field
    | Non_positive_timeout of int

  let field_name = function
    | Command -> "shell command"
    | Workdir -> "workdir"
    | Description -> "description"

  let message = function
    | Empty field -> field_name field ^ " must not be empty"
    | Contains_nul field -> field_name field ^ " must not contain NUL"
    | Non_positive_timeout timeout_ms ->
        Printf.sprintf "timeout_ms must be positive, got %d" timeout_ms

  let pp_error ppf error = Format.pp_print_string ppf (message error)

  let validate_non_empty field = function
    | "" -> Error (Empty field)
    | value when contains_nul value -> Error (Contains_nul field)
    | _ -> Ok ()

  let make ?workdir ?timeout_ms ?description ?(escalate = false) command =
    let ( let* ) = Result.bind in
    let* () = validate_non_empty Command command in
    let* () =
      match workdir with
      | Some workdir -> validate_non_empty Workdir workdir
      | None -> Ok ()
    in
    let* () =
      match description with
      | Some description -> validate_non_empty Description description
      | None -> Ok ()
    in
    let* () =
      match timeout_ms with
      | Some timeout_ms when timeout_ms <= 0 ->
          Error (Non_positive_timeout timeout_ms)
      | Some _ | None -> Ok ()
    in
    Ok { command; workdir; timeout_ms; description; escalate }

  let command t = t.command
  let workdir t = t.workdir
  let timeout_ms t = t.timeout_ms
  let description t = t.description
  let escalate t = t.escalate

  let codec =
    Jsont.Object.map ~kind:"shell input"
      (fun command workdir timeout_ms description escalate ->
        match make ?workdir ?timeout_ms ?description ?escalate command with
        | Ok input -> input
        | Error error -> decode_error (message error))
    |> Jsont.Object.mem "command" Jsont.string ~enc:command
    |> Jsont.Object.opt_mem "workdir" Jsont.string ~enc:workdir
    |> Jsont.Object.opt_mem "timeout_ms" Jsont.int ~enc:timeout_ms
    |> Jsont.Object.opt_mem "description" Jsont.string ~enc:description
    |> Jsont.Object.opt_mem "escalate" Jsont.bool ~enc:(fun t ->
        if t.escalate then Some true else None)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "command",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("description", Json.string "Non-empty shell command text.");
                  ] );
              ( "workdir",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Workspace-relative or workspace-contained absolute \
                         directory. Defaults to the workspace root." );
                  ] );
              ( "timeout_ms",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "Optional command timeout in milliseconds, bounded by \
                         host configuration." );
                  ] );
              ( "description",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("description", Json.string "Optional reviewer/UI metadata.");
                  ] );
              ( "escalate",
                json_obj
                  [
                    ("type", Json.string "boolean");
                    ( "description",
                      Json.string
                        "Request to run this one command outside the sandbox. \
                         Use only after a command failed because of sandbox \
                         restrictions, with the reason in description. \
                         Requires explicit user approval and is unavailable in \
                         read-only runs." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "command" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json

  let encode input =
    match Jsont.Json.encode codec input with
    | Ok json -> json
    | Error message ->
        invalid_arg ("Spice_tools.Shell.Input.encode: " ^ message)
end

module Config = struct
  type t = {
    shell : string;
    sandbox : Spice_sandbox.t;
    network_restricted : bool;
    default_timeout_ms : int;
    max_timeout_ms : int;
    max_output_bytes : int;
    environment : (string * string option) list;
    toolchain_root : Spice_path.Abs.t option;
  }

  let default_shell =
    if String.equal Sys.os_type "Win32" then "cmd.exe" else "/bin/sh"

  let validate_env_binding = function
    | "", _ -> invalid_arg "environment name must not be empty"
    | name, _ when contains_nul name ->
        invalid_arg "environment name must not contain NUL"
    | name, _ when String.contains name '=' ->
        invalid_arg "environment name must not contain ="
    | _, Some value when contains_nul value ->
        invalid_arg "environment value must not contain NUL"
    | _, None | _, Some _ -> ()

  (* Fail closed: a confined request sealed without a backend refuses every
     command. The host passes real authority in. *)
  let default_sandbox () =
    Spice_sandbox.seal
      (Spice_sandbox.Spec.Confined Spice_sandbox.Confinement.read_only)

  let make ?(shell = default_shell) ?sandbox ?(network_restricted = false)
      ?(default_timeout_ms = 60_000) ?(max_timeout_ms = 600_000)
      ?(max_output_bytes = 65_536) ?(environment = []) ?toolchain_root () =
    let sandbox =
      match sandbox with Some sandbox -> sandbox | None -> default_sandbox ()
    in
    if String.equal shell "" then invalid_arg "shell must not be empty";
    if contains_nul shell then invalid_arg "shell must not contain NUL";
    if default_timeout_ms <= 0 then
      invalid_arg "default_timeout_ms must be positive";
    if max_timeout_ms <= 0 then invalid_arg "max_timeout_ms must be positive";
    if default_timeout_ms > max_timeout_ms then
      invalid_arg "default_timeout_ms must be <= max_timeout_ms";
    if max_output_bytes < 0 then
      invalid_arg "max_output_bytes must be non-negative";
    List.iter validate_env_binding environment;
    {
      shell;
      sandbox;
      network_restricted;
      default_timeout_ms;
      max_timeout_ms;
      max_output_bytes;
      environment;
      toolchain_root;
    }

  let shell t = t.shell
  let sandbox t = t.sandbox
  let network_restricted t = t.network_restricted
  let default_timeout_ms t = t.default_timeout_ms
  let max_timeout_ms t = t.max_timeout_ms
  let max_output_bytes t = t.max_output_bytes
  let environment t = t.environment
  let toolchain_root t = t.toolchain_root

  let resolve_timeout_ms t = function
    | None -> Ok t.default_timeout_ms
    | Some timeout_ms when timeout_ms <= 0 ->
        Error "timeout_ms must be positive"
    | Some timeout_ms when timeout_ms > t.max_timeout_ms ->
        Error (Printf.sprintf "timeout_ms must be <= %d" t.max_timeout_ms)
    | Some timeout_ms -> Ok timeout_ms
end

let resolve_workdir ~fs ~workspace input =
  let resolved =
    match Input.workdir input with
    | None -> Ok (Workspace.root_path workspace)
    | Some workdir -> Fs.resolve ~workspace workdir
  in
  match resolved with
  | Error error -> Error (Fs.Error.message error)
  | Ok path -> (
      match Fs.directory ~fs ~workspace ~follow_symlink:true path with
      | Ok _ -> Ok path
      | Error error -> Error (Fs.Error.message error))

let close_noerr fd = try Unix.close fd with Unix.Unix_error _ -> ()

let same_file left right =
  left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino

let open_workdir path =
  let logical = Spice_path.Abs.to_string (Workspace.Path.abs path) in
  let root =
    Workspace.Path.root path |> Workspace.Root.dir |> Spice_path.Abs.to_string
  in
  match
    Unix.openfile logical
      [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ]
      0
  with
  | exception Unix.Unix_error (error, _, _) ->
      Error
        (Printf.sprintf "%s: %s" (Workspace.Path.display path)
           (Unix.error_message error))
  | fd ->
      let fail message =
        close_noerr fd;
        Error message
      in
      let result =
        try
          let opened = Unix.fstat fd in
          if opened.Unix.st_kind <> Unix.S_DIR then
            Error
              (Printf.sprintf "%s: expected a directory"
                 (Workspace.Path.display path))
          else
            let canonical_root = Unix.realpath root in
            let canonical_path = Unix.realpath logical in
            match
              ( Spice_path.Abs.of_string canonical_root,
                Spice_path.Abs.of_string canonical_path )
            with
            | Error error, _ | _, Error error ->
                Error (Spice_path.Error.message error)
            | Ok canonical_root, Ok canonical_path -> (
                  match
                    Spice_path.Abs.relativize ~root:canonical_root canonical_path
                  with
                  | None ->
                      Error
                        (Printf.sprintf "%s: path resolves outside workspace"
                           (Workspace.Path.display path))
                  | Some _ ->
                      let current =
                        Unix.stat (Spice_path.Abs.to_string canonical_path)
                      in
                      if same_file opened current then Ok fd
                      else
                        Error
                          (Printf.sprintf
                             "%s: path changed while it was being opened"
                             (Workspace.Path.display path)))
        with
        | Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
      in
      begin match result with
      | Ok fd -> Ok fd
      | Error message -> fail message
      end

type segment = { argv : string list option }

type parsed = {
  segments : segment list;
  confidence : [ `Confident | `Fallback ];
}

let shell_syntax = function
  | '\n' | ';' | '|' | '&' | '<' | '>' | '(' | ')' | '$' | '`' -> true
  (* Glob metacharacters: the shell expands them before exec, so an [argv] built
     from the unexpanded text would not match the program or args actually run.
     Degrade to the coarse whole-string command match. Quoted globs never reach
     here — [command_words] adds quoted content without this check. *)
  | '*' | '?' | '[' | ']' | '{' | '}' -> true
  | _ -> false

(* A leading environment assignment ([NAME=value cmd]) or a tilde-prefixed
   program is rewritten by the shell before exec, so the first word an [argv]
   match keys on is not the program that runs. Such commands degrade to the
   coarse whole-string match. Erring toward [Fallback] is the safe direction. *)
let spoofable_program = function
  | "" -> false
  | word -> String.contains word '=' || Char.equal word.[0] '~'

let command_words script =
  let len = String.length script in
  let b = Buffer.create len in
  let words = ref [] in
  let word_started = ref false in
  let add_word () =
    if !word_started then begin
      words := Buffer.contents b :: !words;
      Buffer.clear b;
      word_started := false
    end
  in
  let rec quoted quote i =
    if i = len then None
    else
      let c = String.unsafe_get script i in
      if Char.equal c quote then scan (i + 1)
      else begin
        Buffer.add_char b c;
        quoted quote (i + 1)
      end
  and scan i =
    if i = len then Some ()
    else
      match String.unsafe_get script i with
      | ' ' | '\t' ->
          add_word ();
          scan (i + 1)
      | '\'' ->
          word_started := true;
          quoted '\'' (i + 1)
      | '"' ->
          word_started := true;
          quoted '"' (i + 1)
      | '\\' when i + 1 < len ->
          word_started := true;
          Buffer.add_char b (String.unsafe_get script (i + 1));
          scan (i + 2)
      | c when shell_syntax c -> None
      | c ->
          word_started := true;
          Buffer.add_char b c;
          scan (i + 1)
  in
  match scan 0 with
  | None -> None
  | Some () ->
      add_word ();
      begin match List.rev !words with
      | [] -> None
      | words when List.exists (String.equal "") words -> None
      | program :: _ when spoofable_program program -> None
      | words -> Some words
      end

let trim s =
  let len = String.length s in
  let rec left i =
    if i = len then len
    else match s.[i] with ' ' | '\t' | '\r' -> left (i + 1) | _ -> i
  in
  let rec right i =
    if i < 0 then -1
    else match s.[i] with ' ' | '\t' | '\r' -> right (i - 1) | _ -> i
  in
  let first = left 0 in
  let last = right (len - 1) in
  if last < first then "" else String.sub s first (last - first + 1)

let parsed_fallback () =
  { segments = [ { argv = None } ]; confidence = `Fallback }

let parse_shell script =
  let len = String.length script in
  let segments = ref [] in
  let b = Buffer.create len in
  let redirects = ref false in
  let substitutions = ref false in
  let add_segment () =
    let raw = trim (Buffer.contents b) in
    Buffer.clear b;
    if String.equal raw "" then false
    else begin
      let argv = command_words raw in
      segments := { argv } :: !segments;
      true
    end
  in
  let rec quoted quote i =
    if i = len then false
    else
      let c = String.unsafe_get script i in
      if Char.equal quote '"' && (Char.equal c '$' || Char.equal c '`') then
        substitutions := true;
      Buffer.add_char b c;
      if Char.equal c quote then scan (i + 1) else quoted quote (i + 1)
  and scan i =
    if i = len then add_segment ()
    else
      match String.unsafe_get script i with
      | '\'' ->
          Buffer.add_char b '\'';
          quoted '\'' (i + 1)
      | '"' ->
          Buffer.add_char b '"';
          quoted '"' (i + 1)
      | '\\' when i + 1 < len ->
          Buffer.add_char b '\\';
          Buffer.add_char b (String.unsafe_get script (i + 1));
          scan (i + 2)
      | '&' when i + 1 < len && Char.equal script.[i + 1] '&' ->
          if add_segment () then scan (i + 2) else false
      | '|' when i + 1 < len && Char.equal script.[i + 1] '|' ->
          if add_segment () then scan (i + 2) else false
      | '|' -> if add_segment () then scan (i + 1) else false
      | ';' | '\n' -> if add_segment () then scan (i + 1) else false
      | '<' | '>' ->
          redirects := true;
          Buffer.add_char b script.[i];
          scan (i + 1)
      | '$' | '`' | '(' | ')' ->
          substitutions := true;
          Buffer.add_char b script.[i];
          scan (i + 1)
      | c ->
          Buffer.add_char b c;
          scan (i + 1)
  in
  if not (scan 0) then parsed_fallback ()
  else
    let segments = List.rev !segments in
    let confident =
      segments <> []
      && List.for_all (fun segment -> Option.is_some segment.argv) segments
      && (not !redirects) && not !substitutions
    in
    { segments; confidence = (if confident then `Confident else `Fallback) }

type command_route =
  | Enforced
  | External
  | Direct
  | Escalated
  | Sandbox_refused of Spice_sandbox.Error.t
  | Escalation_refused of Spice_sandbox.Error.t

let sandbox_route sandbox =
  match Spice_sandbox.evidence sandbox with
  | Spice_sandbox.Evidence.Enforced _ -> Enforced
  | Spice_sandbox.Evidence.Declared_external -> External
  | Spice_sandbox.Evidence.Not_requested -> Direct
  | Spice_sandbox.Evidence.Refused error -> Sandbox_refused error

let command_route ~config input =
  let sandbox = Config.sandbox config in
  if not (Input.escalate input) then sandbox_route sandbox
  else
    match Spice_sandbox.escalation sandbox with
    | Spice_sandbox.Available -> Escalated
    | Spice_sandbox.Denied error -> Escalation_refused error
    | Spice_sandbox.Ignored -> sandbox_route sandbox

let access_of_argv ~cwd ~execution argv =
  match argv with
  | [] -> None
  | program :: args ->
      Some
        (Permission.Access.argv ~cwd ~execution ~program args)

let command_accesses ~cwd ~execution command =
  let cwd = Permission.Access.Path_scope.workspace cwd in
  match parse_shell command with
  | { confidence = `Confident; segments; _ } ->
      List.filter_map
        (fun segment ->
          Option.bind segment.argv (access_of_argv ~cwd ~execution))
        segments
  | { confidence = `Fallback; _ } ->
      [ Permission.Access.shell ~cwd ~execution command ]

let escalation_access_name = "shell.escalate"

(* The escalation fact is emitted only when escalation means something: the
   sealed decision is confined with writable roots. Under read-only the run
   path refuses the input before any permission flow; under unconfined or
   declared-external requests the flag asks for what is already true. *)
let escalation_access input = function
  | Escalated ->
      [
        Permission.Access.custom ~subject:(Input.command input)
          escalation_access_name;
      ]
  | Enforced | External | Direct | Sandbox_refused _ | Escalation_refused _ -> []

let permissions ~workspace ~config input =
  let resolved =
    match Input.workdir input with
    | None -> Ok (Workspace.root_path workspace)
    | Some workdir -> Workspace.resolve_string workspace workdir
  in
  match resolved with
  | Error _ -> []
  | Ok cwd ->
      let route = command_route ~config input in
      let request execution =
        [
          Permission.Request.of_accesses ~source:name
            ~display:(Input.command input)
            (command_accesses ~cwd ~execution (Input.command input)
            @ escalation_access input route);
        ]
      in
      begin match route with
      | Sandbox_refused _ | Escalation_refused _ -> []
      | Enforced -> request Permission.Access.Command.Enforced
      | External -> request Permission.Access.Command.External
      | Direct | Escalated -> request Permission.Access.Command.Direct
      end

module Output = struct
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
    command : string;
    workdir : Workspace.Path.t;
    status : status;
    stdout : stream;
    stderr : stream;
    duration_ms : int;
    timeout_ms : int;
    max_output_bytes : int;
    enforcement : Spice_sandbox.Evidence.t;
    description : string option;
  }

  let make ~command ~workdir ~status ~stdout ~stderr ~duration_ms ~timeout_ms
      ~max_output_bytes ~enforcement ~description =
    {
      command;
      workdir;
      status;
      stdout;
      stderr;
      duration_ms;
      timeout_ms;
      max_output_bytes;
      enforcement;
      description;
    }

  let command t = t.command
  let workdir t = t.workdir
  let status t = t.status
  let stdout t = t.stdout
  let stderr t = t.stderr
  let duration_ms t = t.duration_ms
  let timeout_ms t = t.timeout_ms
  let max_output_bytes t = t.max_output_bytes
  let enforcement t = t.enforcement
  let description t = t.description

  type render = Compact | Verbose

  let compact = Compact
  let verbose = Verbose

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

  let enforcement_text = function
    | Spice_sandbox.Evidence.Not_requested -> "not_requested"
    | Spice_sandbox.Evidence.Enforced { backend; profile } ->
        Printf.sprintf "enforced backend=%s profile_hash=%s" backend
          (Spice_digest.to_hex profile)
    | Spice_sandbox.Evidence.Refused reason ->
        "refused: " ^ Spice_sandbox.Error.message reason
    | Spice_sandbox.Evidence.Declared_external -> "declared_external"

  let stream_text = function
    | Complete text -> text
    | Truncated { head; tail; omitted_bytes } ->
        head
        ^ Printf.sprintf "\n... %d bytes omitted ...\n" omitted_bytes
        ^ tail

  let stream_verbose_text = function
    | Complete text -> text
    | Truncated { head; tail; omitted_bytes } ->
        Printf.sprintf "[truncated: %d bytes omitted]\n%s\n%s" omitted_bytes
          head tail

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
        ("command", Json.string (command t));
        ("workdir", Json.string (Workspace.Path.display (workdir t)));
        ("status", status_json (status t));
        ("stdout", stream_json (stdout t));
        ("stderr", stream_json (stderr t));
        ("duration_ms", Json.int (duration_ms t));
        ("timeout_ms", Json.int (timeout_ms t));
        ("max_output_bytes", Json.int (max_output_bytes t));
        ("enforcement", Spice_sandbox.Evidence.to_json (enforcement t));
        ( "description",
          match description t with
          | None -> json_null
          | Some description -> Json.string description );
      ]

  let text ?(render = Compact) t =
    let stream =
      match render with
      | Compact -> stream_text
      | Verbose -> stream_verbose_text
    in
    Printf.sprintf
      "Command: %s\n\
       Workdir: %s\n\
       Status: %s\n\
       Duration: %dms\n\
       Timeout: %dms\n\
       Sandbox: %s\n\n\
       stdout:\n\
       %s\n\
       stderr:\n\
       %s"
      (command t)
      (Workspace.Path.display (workdir t))
      (status_text (status t))
      (duration_ms t) (timeout_ms t)
      (enforcement_text (enforcement t))
      (stream (stdout t))
      (stream (stderr t))

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode ?(render = compact) t =
    Tool.Output.make ~text:(text ~render t) ~json:(json t)
      ~truncated:(stream_truncated (stdout t) || stream_truncated (stderr t))
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let shell_command shell command =
  let executable = String.lowercase_ascii (Filename.basename shell) in
  let argv =
    if
      String.equal Sys.os_type "Win32"
      && (String.equal executable "cmd" || String.equal executable "cmd.exe")
    then [ shell; "/C"; command ]
    else if
      String.equal Sys.os_type "Win32"
      && (String.equal executable "powershell"
         || String.equal executable "powershell.exe"
         || String.equal executable "pwsh"
         || String.equal executable "pwsh.exe")
    then [ shell; "-NoLogo"; "-NoProfile"; "-Command"; command ]
    else [ shell; "-c"; command ]
  in
  match argv with
  | [] -> invalid_arg "shell command argv must not be empty"
  | program :: args -> Spice_sandbox.Argv.make ~program args

module String_map = Map.Make (String)

let split_env binding =
  match String.split_first ~sep:"=" binding with
  | None -> (binding, Some "")
  | Some (name, value) -> (name, Some value)

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

let apply_env_overlay env overlay =
  List.fold_left
    (fun env -> function
      | name, Some value -> String_map.add name value env
      | name, None -> String_map.remove name env)
    env overlay

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
  String_map.bindings with_config

let environment_array bindings =
  bindings
  |> List.map (fun (name, value) -> name ^ "=" ^ value)
  |> Array.of_list

(* The inner [/bin/sh] resolves a bare program against this environment's
   [PATH]. Recover the OCaml toolchain the way every direct OCaml spawn does —
   a no-op when [dune] already resolves — so a session launched without the
   switch on [PATH] still runs [dune] from the shell tool. The adjustment
   precedes the sandbox partition, which never strips [PATH]; the search space
   is also what the exit-127 note consults. *)
let with_toolchain ~workspace_root bindings =
  let env = environment_array bindings in
  let toolchain =
    Spice_ocaml_toolchain.discover ~env
      ~workspace_root:(Option.map Spice_path.Abs.to_string workspace_root)
  in
  let adjusted = Spice_ocaml_toolchain.env toolchain ~program:"dune" in
  let bindings =
    if adjusted == env then bindings
    else
      Array.to_list adjusted
      |> List.map (fun binding ->
          match String.index_opt binding '=' with
          | Some i ->
              ( String.sub binding 0 i,
                String.sub binding (i + 1) (String.length binding - i - 1) )
          | None -> (binding, ""))
  in
  (toolchain, bindings)

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

let failed_output ~input ~workdir ~timeout_ms ~max_output_bytes ~enforcement
    message =
  Output.make ~command:(Input.command input) ~workdir
    ~status:(Output.Failed_to_start message) ~stdout:(Output.Complete "")
    ~stderr:(Output.Complete "") ~duration_ms:0 ~timeout_ms ~max_output_bytes
    ~enforcement ~description:(Input.description input)

let output_of_process ~input ~workdir ~timeout_ms ~max_output_bytes ~enforcement
    result =
  (* A wrapper that failed to spawn enforced nothing: nothing ran. *)
  let enforcement =
    match (result.Process.shell_status, enforcement) with
    | Process.Shell_failed_to_start message, Spice_sandbox.Evidence.Enforced _
      ->
        Spice_sandbox.Evidence.refused
          (Spice_sandbox.Error.invalid_request message)
    | _, enforcement -> enforcement
  in
  Output.make ~command:(Input.command input) ~workdir
    ~status:(status_of_process result.Process.shell_status)
    ~stdout:(stream_of_process result.Process.shell_stdout)
    ~stderr:(stream_of_process result.Process.shell_stderr)
    ~duration_ms:result.Process.shell_duration_ms ~timeout_ms ~max_output_bytes
    ~enforcement ~description:(Input.description input)

let stream_text = function
  | Output.Complete text -> text
  | Output.Truncated { head; tail; _ } -> head ^ tail

let contains_affix ~affix haystack =
  let affix_len = String.length affix and hay_len = String.length haystack in
  if affix_len = 0 then true
  else
    let rec loop i =
      if i + affix_len > hay_len then false
      else if String.equal (String.sub haystack i affix_len) affix then true
      else loop (i + 1)
    in
    loop 0

(* Signatures a blocked outbound request leaves in command output, across the
   platform sandboxes: a denied socket surfaces as a name-resolution or connect
   failure rather than a spawn error, so a failed command carrying one of these
   under a network-restricted confinement is a policy denial, not a transient
   fault. Matched case-insensitively against the combined streams. *)
let network_denial_signatures =
  [
    "could not resolve host";
    "couldn't resolve host";
    "could not resolve";
    "name or service not known";
    "temporary failure in name resolution";
    "couldn't connect to server";
    "connection refused";
    "network is unreachable";
    "no route to host";
    "operation not permitted while establishing";
  ]

let looks_like_network_denial output =
  let lowered = String.lowercase_ascii output in
  List.exists
    (fun affix -> contains_affix ~affix lowered)
    network_denial_signatures

let confined_enforcement = function
  | Spice_sandbox.Evidence.Enforced _ -> true
  | Spice_sandbox.Evidence.Refused _ | Spice_sandbox.Evidence.Not_requested
  | Spice_sandbox.Evidence.Declared_external ->
      false

let network_denial_diagnosis =
  "\n\n\
   This command ran inside a sandbox with network access restricted, and its \
   output looks like a blocked network request. That is a policy restriction, \
   not a transient error: re-running the command unchanged will fail the same \
   way. If the command genuinely needs the network, re-run this exact command \
   with escalate:true to ask the user to approve running it outside the \
   sandbox, or ask the user to allow network access for this run."

let network_denial_note ~network_restricted output =
  if
    network_restricted
    && confined_enforcement (Output.enforcement output)
    && looks_like_network_denial
         (stream_text (Output.stdout output)
         ^ "\n"
         ^ stream_text (Output.stderr output))
  then network_denial_diagnosis
  else ""

(* Exit 127 is the shell's command-not-found. When the command names a known
   OCaml tool that the toolchain search space cannot resolve either, the launch
   context lost the switch; name that cause instead of leaving the bare shell
   error. Word extraction keeps [-_.] so a program like [my-ocaml-helper] never
   matches the plain [ocaml] name. *)
let ocaml_tool_names =
  [
    "dune";
    "opam";
    "ocaml";
    "ocamlc";
    "ocamlopt";
    "ocamlfind";
    "ocamlmerlin";
    "ocamllsp";
    "ocamlformat";
    "utop";
  ]

let command_words command =
  String.map
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> c
      | _ -> ' ')
    command
  |> String.split_on_char ' '
  |> List.filter (fun word -> not (String.equal word ""))

let toolchain_note ~toolchain ~command output =
  match Output.status output with
  | Output.Exited 127 -> (
      let missing word =
        List.mem word ocaml_tool_names
        && Option.is_none (Spice_ocaml_toolchain.find toolchain word)
      in
      match List.find_opt missing (command_words command) with
      | Some program ->
          "\n\n" ^ Spice_ocaml_toolchain.unreachable_hint toolchain ~program
      | None -> "")
  | Output.Exited _ | Output.Signaled _ | Output.Timed_out _ | Output.Cancelled
  | Output.Failed_to_start _ ->
      ""

let result_of_output ~network_restricted ~toolchain ~command output =
  let note =
    network_denial_note ~network_restricted output
    ^ toolchain_note ~toolchain ~command output
  in
  match Output.status output with
  | Output.Exited 0 -> Tool.Result.completed ~output ()
  | Output.Exited code ->
      Tool.Result.failed ~output `Failed
        (Printf.sprintf "command exited with status %d%s" code note)
  | Output.Signaled signal ->
      Tool.Result.failed ~output `Failed
        (Printf.sprintf "command terminated by signal %d%s" signal note)
  | Output.Timed_out { timeout_ms } ->
      Tool.Result.failed ~output `Timed_out
        (Printf.sprintf "command timed out after %dms%s" timeout_ms note)
  | Output.Cancelled ->
      Tool.Result.interrupted ~output ~reason:"tool call cancelled"
        ~cancelled:true ()
  | Output.Failed_to_start message ->
      Tool.Result.failed ~output `Unavailable message

let default_cancelled () = false

let run ~fs ~workspace ~config ?(cancelled = default_cancelled) input =
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Config.resolve_timeout_ms config (Input.timeout_ms input) with
    | Error message -> Tool.Result.failed `Invalid_input message
    | Ok timeout_ms -> (
        let max_output_bytes = Config.max_output_bytes config in
        match resolve_workdir ~fs ~workspace input with
        | Error message -> Tool.Result.failed `Invalid_input message
        | Ok workdir -> (
            match open_workdir workdir with
            | Error message ->
                let output =
                  failed_output ~input ~workdir ~timeout_ms ~max_output_bytes
                    ~enforcement:(Spice_sandbox.evidence (Config.sandbox config))
                    message
                in
                Tool.Result.failed ~output `Unavailable message
            | Ok workdir_fd ->
                Fun.protect
                  ~finally:(fun () -> close_noerr workdir_fd)
                  (fun () ->
            let argv =
              shell_command (Config.shell config) (Input.command input)
            in
            let toolchain, base_env =
              with_toolchain ~workspace_root:(Config.toolchain_root config)
                (process_environment config)
            in
            let run_spawn ~argv ~env ~enforcement =
              let result =
                Process.run_shell_fd ~cwd:workdir_fd
                  ~env:(environment_array env) ~timeout_ms ~max_output_bytes
                  ~cancelled
                  (Spice_sandbox.Argv.to_list argv)
              in
              let output =
                output_of_process ~input ~workdir ~timeout_ms ~max_output_bytes
                  ~enforcement result
              in
              result_of_output
                ~network_restricted:(Config.network_restricted config)
                ~toolchain ~command:(Input.command input) output
            in
            match command_route ~config input with
            | Escalation_refused reason ->
                (* No spawn and no permission flow: the mode's promise admits
                   no approval-shaped exception. *)
                Tool.Result.failed `Invalid_input
                  (Spice_sandbox.Error.message reason)
            | Sandbox_refused reason ->
                let message = Spice_sandbox.Error.message reason in
                let output =
                  failed_output ~input ~workdir ~timeout_ms ~max_output_bytes
                    ~enforcement:(Spice_sandbox.evidence (Config.sandbox config))
                    message
                in
                Tool.Result.failed ~output `Unavailable message
            | Escalated ->
                (* Reaching execution means the escalation access was
                   approved by policy or reviewer. Escalation drops the
                   filesystem confinement, not the credential strip: a command
                   run outside the sandbox still must not inherit secrets or
                   loader-injection variables. Only danger-full-access
                   (Unconfined) passes the environment verbatim, deliberately. *)
                let env, _stripped = Spice_sandbox.Env.partition base_env in
                run_spawn ~argv ~env
                  ~enforcement:Spice_sandbox.Evidence.not_requested
            | Enforced | External | Direct -> (
                match
                  Spice_sandbox.spawn (Config.sandbox config) ~argv
                    ~env:base_env
                with
                | Error error ->
                    let message = Spice_sandbox.Error.message error in
                    let output =
                      failed_output ~input ~workdir ~timeout_ms
                        ~max_output_bytes
                        ~enforcement:
                          (Spice_sandbox.evidence (Config.sandbox config))
                        message
                    in
                    Tool.Result.failed ~output `Unavailable message
                | Ok spawn ->
                    run_spawn
                      ~argv:(Spice_sandbox.Spawn.argv spawn)
                      ~env:(Spice_sandbox.Spawn.env spawn)
                      ~enforcement:(Spice_sandbox.Spawn.evidence spawn)))))

let tool ~fs ~workspace ~config ?(render = Output.compact) () =
  Tool.make ~name ~description ~input:Input.contract
    ~output:(Output.encode ~render)
    ~permissions:(fun input -> permissions ~workspace ~config input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ~config
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
