(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let default_program = [ "ocamlmerlin" ]
let default_timeout_ms = 30_000
let default_max_output_bytes = 1024 * 1024

(* Upper bound on model-facing merlin error detail. Long compiler dumps are
   truncated so a single failing query cannot flood the tool result. *)
let max_detail_bytes = 4096

(* Non-interactive child environment: keep the OCaml driver and merlin from
   colourising stderr regardless of the inherited [TERM]. Defence in depth —
   the child's stderr is already a pipe — paired with {!strip_detail}. *)
let non_interactive_names = [ "TERM"; "NO_COLOR"; "CLICOLOR"; "CLICOLOR_FORCE" ]

let non_interactive_overlay =
  [| "TERM=dumb"; "NO_COLOR=1"; "CLICOLOR=0"; "CLICOLOR_FORCE=0" |]

let env_binding_name binding =
  match String.index_opt binding '=' with
  | Some i -> String.sub binding 0 i
  | None -> binding

let with_non_interactive_env env =
  let kept =
    Array.to_list env
    |> List.filter (fun binding ->
        not (List.mem (env_binding_name binding) non_interactive_names))
  in
  Array.append (Array.of_list kept) non_interactive_overlay

(* Strip CSI escapes from model-facing subprocess text. Mirrors the decode-
   boundary strip in {!Spice_tool.Input}; the shared home is a deferred infra
   text module. *)
let strip_ansi s =
  if not (String.contains s '\x1b') then s
  else begin
    let n = String.length s in
    let b = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '\x1b' && !i + 1 < n && s.[!i + 1] = '[' then begin
        i := !i + 2;
        while !i < n && (s.[!i] < '\x40' || s.[!i] > '\x7e') do
          incr i
        done;
        if !i < n then incr i
      end
      else begin
        Buffer.add_char b s.[!i];
        incr i
      end
    done;
    Buffer.contents b
  end

let strip_detail detail =
  let detail = strip_ansi detail in
  if String.length detail <= max_detail_bytes then detail
  else String.sub detail 0 max_detail_bytes

let captured_text = function
  | Process.Complete text -> text
  | Process.Truncated { head; tail; omitted_bytes = _ } -> head ^ tail

let argv ~program ~command ~args =
  match program with
  | [] -> invalid_arg "Ocaml_merlin.argv: program prefix must not be empty"
  | _ -> program @ ("single" :: command :: args)

(* A cold [dune tools exec] can relock and rebuild the dev tool; this is a
   one-time boot cost, so the warming budget is generous. *)
let default_resolve_timeout_ms = 120_000

type resolution_error = Warm_failed of string | Binary_not_found of string

let resolution_error_message = function
  | Warm_failed detail ->
      "could not resolve the Dune dev-tool Merlin binary: " ^ detail
  | Binary_not_found tool ->
      Printf.sprintf
        "could not resolve the Dune dev-tool Merlin binary: warming ran but no \
         built %s was found under _build/_private/*/.dev-tool"
        tool

(* Recognise a [dune tools exec <tool> --] invocation prefix. This is the only
   shape that engages the dune engine per query and therefore needs resolving to
   a concrete binary; every other prefix (a bare [PATH]/absolute binary, or a
   non-dune wrapper) is lock-free and passes through unchanged. *)
let dune_tools_exec_tool = function
  | [ dune; "tools"; "exec"; tool; "--" ]
    when String.equal (Filename.basename dune) "dune" ->
      Some tool
  | _ -> None

(* A single-token prefix that names a program to resolve through [PATH] rather
   than an absolute or relative path (its basename is itself, so it carries no
   directory separator). Only such a name can be served by a same-named dune
   dev-tool binary. *)
let bare_program = function
  | [ token ]
    when (not (String.equal token ""))
         && String.equal (Filename.basename token) token ->
      Some token
  | _ -> None

let env_value name env =
  Array.to_list env
  |> List.find_map (fun binding ->
      match String.index_opt binding '=' with
      | Some i when String.equal (String.sub binding 0 i) name ->
          Some (String.sub binding (i + 1) (String.length binding - i - 1))
      | _ -> None)

(* True when [tool] resolves to an executable on [env]'s [PATH], mirroring the
   [execvpe] search the transport itself performs. A present [PATH] binary is
   lock-free and is preferred over dune's dev-tool layout. *)
let on_path ~env tool =
  match env_value "PATH" env with
  | None -> false
  | Some path ->
      String.split_on_char ':' path
      |> List.exists (fun dir ->
          if String.equal dir "" then false
          else
            let candidate = Filename.concat dir tool in
            match Unix.access candidate [ Unix.X_OK ] with
            | () -> true
            | exception Unix.Unix_error _ -> false)

let read_dir dir =
  match Sys.readdir dir with
  | entries -> Array.to_list entries
  | exception Sys_error _ -> []

(* Locate the built dev-tool binary after a warming invocation. Dune installs it
   at [_build/_private/<context>/.dev-tool/<pkg>/target/bin/<tool>]; the <pkg>
   directory (e.g. [merlin]) need not match the binary name (e.g. [ocamlmerlin]),
   so the search globs across dev-tool packages and matches the binary name. *)
let find_dev_tool_binary ~cwd ~tool =
  let private_root =
    List.fold_left Filename.concat cwd [ "_build"; "_private" ]
  in
  read_dir private_root
  |> List.concat_map (fun context ->
      let dev_tool_root =
        List.fold_left Filename.concat private_root [ context; ".dev-tool" ]
      in
      read_dir dev_tool_root
      |> List.filter_map (fun pkg ->
          let bin =
            List.fold_left Filename.concat dev_tool_root
              [ pkg; "target"; "bin"; tool ]
          in
          if Sys.file_exists bin then Some bin else None))
  |> function
  | bin :: _ -> Some bin
  | [] -> None

(* Warm the dev tool with a single [dune tools exec] invocation, then locate the
   built binary. The exec's own exit status is ignored — even a non-zero exit
   from the tool means dune built its binary, which is all resolution needs.
   Warming engages the dune engine and so is the last resort, reached only when
   no already-built binary was found on disk. *)
let warm_dev_tool ~cwd ~env ~timeout_ms ~tool ~configured =
  (* [run_shell]'s [execvp] resolves a bare [dune] against the process [PATH],
     not [env]; pin the absolute path recovered from the switch [env] points at. *)
  let configured =
    match configured with
    | dune :: rest -> (
        match snd (Spice_ocaml_toolchain.locate env ~program:dune) with
        | Some dune -> dune :: rest
        | None -> configured)
    | [] -> configured
  in
  let warm =
    Process.run_shell ~cwd ~env ~timeout_ms
      ~max_output_bytes:default_max_output_bytes
      ~cancelled:(fun () -> false)
      configured
  in
  match warm.Process.shell_status with
  | Process.Shell_failed_to_start message ->
      Error (Warm_failed ("could not start dune: " ^ message))
  | Process.Shell_exited _ | Process.Shell_signaled _
  | Process.Shell_timed_out _ | Process.Shell_cancelled -> (
      match find_dev_tool_binary ~cwd ~tool with
      | Some bin -> Ok [ bin ]
      | None ->
          let stderr =
            String.trim (strip_detail (captured_text warm.Process.shell_stderr))
          in
          if String.equal stderr "" then Error (Binary_not_found tool)
          else Error (Warm_failed stderr))

let resolve_program ~cwd ?(env = Unix.environment ())
    ?(timeout_ms = default_resolve_timeout_ms) ~configured () =
  match configured with
  | [] ->
      invalid_arg
        "Ocaml_merlin.resolve_program: configured prefix must not be empty"
  | _ -> (
      (* Recover the switch bin when the inherited [PATH] does not already carry
         the toolchain, so [on_path], warming, and the pinned absolute below all
         see the same directory a correctly-launched session would. *)
      let env = Spice_ocaml_toolchain.augment env ~program:"dune" in
      match dune_tools_exec_tool configured with
      | Some tool -> (
          (* An explicit [dune tools exec] prefix. Prefer an already-built
             dev-tool binary: a pure filesystem lookup that engages no dune
             engine and never contends with a running watch. Warm only when the
             binary is absent. *)
          match find_dev_tool_binary ~cwd ~tool with
          | Some bin -> Ok [ bin ]
          | None -> warm_dev_tool ~cwd ~env ~timeout_ms ~tool ~configured)
      | None -> (
          (* A [PATH]/absolute binary or non-dune wrapper is lock-free and used
             as given, with one exception: a bare program name that [PATH]
             cannot resolve. In a dune-managed project the matching binary is
             dune's already-built dev tool, so fall back to it directly — again
             a pure filesystem lookup, no warming. Otherwise pin the absolute
             path so {!run}'s [execvp] does not re-search the process [PATH]. *)
          match bare_program configured with
          | Some tool when not (on_path ~env tool) -> (
              match find_dev_tool_binary ~cwd ~tool with
              | Some bin -> Ok [ bin ]
              | None -> Ok configured)
          | Some tool -> (
              match snd (Spice_ocaml_toolchain.locate env ~program:tool) with
              | Some bin -> Ok [ bin ]
              | None -> Ok configured)
          | None -> Ok configured))

type error =
  | Cancelled
  | Unavailable of string
  | Timed_out of { timeout_ms : int }
  | Signaled of int
  | Exited of { code : int; detail : string }
  | Output_exceeded of string
  | Query_failure of { class_ : string; detail : string }
  | Malformed of string

let error_message = function
  | Cancelled -> "ocamlmerlin query cancelled"
  | Unavailable message -> "could not start ocamlmerlin: " ^ message
  | Timed_out { timeout_ms } ->
      Printf.sprintf "ocamlmerlin timed out after %dms" timeout_ms
  | Signaled signal ->
      "ocamlmerlin was terminated by signal " ^ string_of_int signal
  | Exited { code; detail } ->
      if String.equal detail "" then
        "ocamlmerlin exited with status " ^ string_of_int code
      else detail
  | Output_exceeded stream -> "ocamlmerlin " ^ stream ^ " exceeded output limit"
  | Query_failure { class_; detail } ->
      "ocamlmerlin returned " ^ class_ ^ ": " ^ detail
  | Malformed message -> "could not decode ocamlmerlin response: " ^ message

let member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_member name json =
  match member name json with
  | Some (Jsont.String (value, _)) -> Some value
  | _ -> None

let json_to_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> "<unencodable value: " ^ message ^ ">"

let value_detail json =
  match member "value" json with
  | Some (Jsont.String (message, _)) -> message
  | Some value -> json_to_string value
  | None -> "<missing value>"

type envelope =
  | Return of Jsont.json
  | Failure of { class_ : string; detail : string }
  | Bad of string

let parse_envelope stdout =
  match Jsont_bytesrw.decode_string Jsont.json stdout with
  | Error message -> Bad message
  | Ok json -> (
      match string_member "class" json with
      | Some "return" -> (
          match member "value" json with
          | Some value -> Return value
          | None -> Bad "return envelope has no value")
      | Some (("failure" | "error" | "exception") as class_) ->
          Failure { class_; detail = value_detail json }
      | Some class_ -> Bad ("unexpected response class " ^ class_)
      | None -> Bad "response has no class")

let run ~program ~cwd ?(env = Unix.environment ())
    ?(timeout_ms = default_timeout_ms)
    ?(max_output_bytes = default_max_output_bytes) ~command ~args ~source
    ~cancelled () =
  (* [program] is usually already an absolute path from {!resolve_program}; pin
     it here too so a direct bare call still bypasses the process-[PATH] search. *)
  let env, program =
    match program with
    | head :: rest -> (
        match Spice_ocaml_toolchain.locate env ~program:head with
        | env, Some exe -> (env, exe :: rest)
        | env, None -> (env, program))
    | [] -> (env, program)
  in
  let command_argv = argv ~program ~command ~args in
  let env = with_non_interactive_env env in
  let result =
    Process.run_shell ~cwd ~env ~timeout_ms ~max_output_bytes ~stdin:source
      ~cancelled command_argv
  in
  match result.Process.shell_status with
  | Process.Shell_cancelled -> Error Cancelled
  | Process.Shell_failed_to_start message -> Error (Unavailable message)
  | Process.Shell_timed_out { timeout_ms } -> Error (Timed_out { timeout_ms })
  | Process.Shell_signaled signal -> Error (Signaled signal)
  | Process.Shell_exited 0 -> (
      match result.Process.shell_stdout with
      | Process.Truncated _ -> Error (Output_exceeded "stdout")
      | Process.Complete stdout -> (
          match parse_envelope stdout with
          | Return value -> Ok value
          | Failure { class_; detail } ->
              Error (Query_failure { class_; detail })
          | Bad message -> Error (Malformed message)))
  | Process.Shell_exited code ->
      let stderr = String.trim (captured_text result.Process.shell_stderr) in
      let detail =
        if String.equal stderr "" then
          String.trim (captured_text result.Process.shell_stdout)
        else stderr
      in
      Error (Exited { code; detail = strip_detail detail })
