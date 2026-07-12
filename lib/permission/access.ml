(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
open Codec

type kind = [ `Read | `Write | `Command | `Network | `Custom ]
type path_op = [ `Read | `Create | `Modify | `Delete ]

type path_scope =
  | Workspace of {
      root_key : Spice_workspace.Root.Key.t;
      relative : Spice_path.Rel.t;
    }
  | Outside_workspace of Spice_path.Abs.t
  | Unknown of string

type network_protocol =
  [ `Http | `Https | `Ssh | `Tcp | `Udp | `Other of string ]

let invalid fn message = invalid_arg' "Spice_permission.Access" fn message

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let reject_empty_option fn field = Option.iter (reject_empty fn field)

let workspace_parts path =
  let root = Spice_workspace.Path.root path in
  let root_key = Spice_workspace.Root.key root in
  let relative = Spice_workspace.Path.rel path in
  (root_key, relative)

type t =
  | Path of { op : path_op; scope : path_scope }
  | Command of command
  | Network of { protocol : network_protocol; host : string; port : int option }
  | Custom of { name : string; subject : string option }

and command =
  | Shell of {
      text : string;
      cwd : path_scope;
      execution : command_execution;
    }
  | Argv of {
      program : string;
      args : string list;
      cwd : path_scope;
      execution : command_execution;
    }
  | Code of {
      language : string;
      source : string;
      cwd : path_scope;
      execution : command_execution;
    }

and command_execution = Enforced | External | Direct

let workspace_scope_of_parts ~root_key ~relative =
  Workspace { root_key; relative }

let unknown_scope path =
  reject_empty "unknown_path" "unknown path" path;
  Unknown path

let workspace_scope path =
  let root_key, relative = workspace_parts path in
  workspace_scope_of_parts ~root_key ~relative

let outside_workspace_scope path = Outside_workspace path

module Path_scope = struct
  type t = path_scope =
    | Workspace of {
        root_key : Spice_workspace.Root.Key.t;
        relative : Spice_path.Rel.t;
      }
    | Outside_workspace of Spice_path.Abs.t
    | Unknown of string

  let workspace = workspace_scope
  let workspace_key = workspace_scope_of_parts
  let outside_workspace = outside_workspace_scope
  let unknown = unknown_scope
  let equal a b = a = b

  let pp ppf = function
    | Workspace { root_key; relative } ->
        Format.fprintf ppf "workspace(root_key=%S, relative=%S)"
          (Spice_workspace.Root.Key.to_string root_key)
          (Spice_path.Rel.to_string relative)
    | Outside_workspace path ->
        Format.fprintf ppf "outside(%S)" (Spice_path.Abs.to_string path)
    | Unknown path -> Format.fprintf ppf "unknown(%S)" path
end

let check_protocol = function
  | `Other protocol -> reject_empty "network" "protocol name" protocol
  | `Http | `Https | `Ssh | `Tcp | `Udp -> ()

let check_port = function
  | None -> ()
  | Some port ->
      if port < 1 || port > 65_535 then
        invalid "network" "port must be between 1 and 65535"

let path_scope ~op scope = Path { op; scope }

let workspace_path_of_parts ~op ~root_key ~relative =
  path_scope ~op (workspace_scope_of_parts ~root_key ~relative)

let path ~op workspace_path =
  let root_key, relative = workspace_parts workspace_path in
  workspace_path_of_parts ~op ~root_key ~relative

let outside_workspace_path ~op path =
  path_scope ~op (outside_workspace_scope path)

let unknown_path ~op path_text = path_scope ~op (unknown_scope path_text)

module Command = struct
  type execution = command_execution = Enforced | External | Direct

  type t = command =
    | Shell of {
        text : string;
        cwd : path_scope;
        execution : execution;
      }
    | Argv of {
        program : string;
        args : string list;
        cwd : path_scope;
        execution : execution;
      }
    | Code of {
        language : string;
        source : string;
        cwd : path_scope;
        execution : execution;
      }

  let shell ~cwd ~execution text =
    reject_empty "Command.shell" "text" text;
    Shell { text; cwd; execution }

  let argv ~cwd ~execution ~program args =
    reject_empty "Command.argv" "program" program;
    Argv { program; args; cwd; execution }

  let code ~cwd ~execution ~language source =
    reject_empty "Command.code" "language" language;
    reject_empty "Command.code" "source" source;
    Code { language; source; cwd; execution }

  let execution = function
    | Shell { execution; _ }
    | Argv { execution; _ }
    | Code { execution; _ } ->
        execution

  let execution_to_string = function
    | Enforced -> "enforced"
    | External -> "external"
    | Direct -> "direct"

  let stable_scope = function
    | Workspace { root_key; relative } ->
        "workspace:"
        ^ stable_field (Spice_workspace.Root.Key.to_string root_key)
        ^ ":"
        ^ stable_field (Spice_path.Rel.to_string relative)
    | Outside_workspace path ->
        "outside:" ^ stable_field (Spice_path.Abs.to_string path)
    | Unknown path -> "unknown:" ^ stable_field path

  let stable_text = function
    | Shell { text; cwd; execution } ->
        "shell:" ^ execution_to_string execution ^ ":" ^ stable_field text ^ ":"
        ^ stable_scope cwd
    | Argv { program; args; cwd; execution } ->
        "argv:" ^ stable_field program ^ ":"
        ^ String.concat ":" (List.map stable_field args)
        ^ ":" ^ execution_to_string execution ^ ":"
        ^ stable_scope cwd
    | Code { language; source; cwd; execution } ->
        "code:" ^ stable_field language ^ ":" ^ stable_field source ^ ":"
        ^ execution_to_string execution ^ ":" ^ stable_scope cwd

  let pp_execution ppf execution =
    Format.pp_print_string ppf (execution_to_string execution)

  let pp ppf = function
    | Shell { text; cwd; execution } ->
        Format.fprintf ppf "shell(%S, cwd=%a, execution=%a)" text Path_scope.pp
          cwd pp_execution execution
    | Argv { program; args; cwd; execution } ->
        Format.fprintf ppf "argv(%S, %a, cwd=%a, execution=%a)" program
          (Format.pp_print_list
             ~pp_sep:(fun ppf () -> Format.pp_print_string ppf " ")
             (fun ppf arg -> Format.fprintf ppf "%S" arg))
          args Path_scope.pp cwd pp_execution execution
    | Code { language; source; cwd; execution } ->
        Format.fprintf ppf "code(language=%S, source=%S, cwd=%a, execution=%a)"
          language source Path_scope.pp cwd pp_execution execution
end

let command command = Command command
let shell ~cwd ~execution text = command (Command.shell ~cwd ~execution text)

let argv ~cwd ~execution ~program args =
  command (Command.argv ~cwd ~execution ~program args)

let code ~cwd ~execution ~language source =
  command (Command.code ~cwd ~execution ~language source)

let network ~protocol ?port ~host () =
  check_protocol protocol;
  reject_empty "network" "host" host;
  check_port port;
  Network { protocol; host; port }

let custom ?subject name =
  reject_empty "custom" "name" name;
  reject_empty_option "custom" "subject" subject;
  Custom { name; subject }

let kind = function
  | Path { op = `Read; _ } -> `Read
  | Path { op = `Create | `Modify | `Delete; _ } -> `Write
  | Command _ -> `Command
  | Network _ -> `Network
  | Custom _ -> `Custom

let equal a b = a = b
let compare a b = Stdlib.compare a b
let hash = Hashtbl.hash

module Set = Stdlib.Set.Make (struct
  type nonrec t = t

  let compare = compare
end)

module Map = Stdlib.Map.Make (struct
  type nonrec t = t

  let compare = compare
end)

let decode_relative_path path =
  match Spice_path.Rel.of_string path with
  | Ok path -> path
  | Error error ->
      decode_error
        ("invalid workspace relative path: " ^ Spice_path.Error.message error)

let decode_abs_path path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error ->
      decode_error ("invalid absolute path: " ^ Spice_path.Error.message error)

let decode_root_key key =
  match Spice_workspace.Root.Key.of_string key with
  | Ok key -> key
  | Error error ->
      decode_error
        ("invalid workspace root key: " ^ Spice_workspace.Root.Key.message error)

let stable_scope = function
  | Workspace { root_key; relative } ->
      "workspace:"
      ^ stable_field (Spice_workspace.Root.Key.to_string root_key)
      ^ ":"
      ^ stable_field (Spice_path.Rel.to_string relative)
  | Outside_workspace path ->
      "outside:" ^ stable_field (Spice_path.Abs.to_string path)
  | Unknown path -> "unknown:" ^ stable_field path

let stable_text = function
  | Path { op; scope } -> "path:" ^ stable_path_op op ^ ":" ^ stable_scope scope
  | Command command -> "command:" ^ stable_field (Command.stable_text command)
  | Network { protocol; host; port } ->
      "network:" ^ stable_protocol protocol ^ ":" ^ stable_field host ^ ":"
      ^ stable_option string_of_int port
  | Custom { name; subject } ->
      "custom:" ^ stable_field name ^ ":"
      ^ stable_option stable_field subject

let path_jsont =
  let make op scope path_value root_key relative =
    match (scope, path_value, root_key, relative) with
    | "workspace", None, Some root_key, Some relative ->
        decode_invalid_arg (fun () ->
            let root_key = decode_root_key root_key in
            let relative = decode_relative_path relative in
            workspace_path_of_parts ~op ~root_key ~relative)
    | "outside", Some path_text, None, None ->
        decode_invalid_arg (fun () ->
            outside_workspace_path ~op (decode_abs_path path_text))
    | "unknown", Some path_text, None, None ->
        decode_invalid_arg (fun () -> unknown_path ~op path_text)
    | "workspace", _, _, _ ->
        decode_error
          "workspace path requires root_key and relative and must not carry \
           path"
    | "outside", _, _, _ -> decode_error "outside path requires only path"
    | "unknown", _, _, _ -> decode_error "unknown path requires only path"
    | scope, _, _, _ -> decode_error ("unknown path scope: " ^ scope)
  in
  let op = function Path { op; _ } -> op | _ -> assert false in
  let scope = function
    | Path { scope = Workspace _; _ } -> "workspace"
    | Path { scope = Outside_workspace _; _ } -> "outside"
    | Path { scope = Unknown _; _ } -> "unknown"
    | _ -> assert false
  in
  let path = function
    | Path { scope = Outside_workspace path; _ } ->
        Some (Spice_path.Abs.to_string path)
    | Path { scope = Unknown path; _ } -> Some path
    | Path { scope = Workspace _; _ } -> None
    | _ -> assert false
  in
  let root_key = function
    | Path { scope = Workspace { root_key; _ }; _ } ->
        Some (Spice_workspace.Root.Key.to_string root_key)
    | Path { scope = Outside_workspace _ | Unknown _; _ } -> None
    | _ -> assert false
  in
  let relative = function
    | Path { scope = Workspace { relative; _ }; _ } ->
        Some (Spice_path.Rel.to_string relative)
    | Path { scope = Outside_workspace _ | Unknown _; _ } -> None
    | _ -> assert false
  in
  Jsont.Object.map ~kind:"path access" make
  |> Jsont.Object.mem "op" path_op_jsont ~enc:op
  |> Jsont.Object.mem "scope" Jsont.string ~enc:scope
  |> Jsont.Object.opt_mem "path" Jsont.string ~enc:path
  |> Jsont.Object.opt_mem "root_key" Jsont.string ~enc:root_key
  |> Jsont.Object.opt_mem "relative" Jsont.string ~enc:relative
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let path_scope_jsont =
  let make scope path root_key relative =
    match (scope, path, root_key, relative) with
    | "workspace", None, Some root_key, Some relative ->
        decode_invalid_arg (fun () ->
            let root_key = decode_root_key root_key in
            let relative = decode_relative_path relative in
            workspace_scope_of_parts ~root_key ~relative)
    | "outside", Some path, None, None ->
        decode_invalid_arg (fun () ->
            outside_workspace_scope (decode_abs_path path))
    | "unknown", Some path, None, None ->
        decode_invalid_arg (fun () -> unknown_scope path)
    | "workspace", _, _, _ ->
        decode_error
          "workspace path scope requires root_key and relative and must not \
           carry path"
    | "outside", _, _, _ -> decode_error "outside path scope requires only path"
    | "unknown", _, _, _ -> decode_error "unknown path scope requires only path"
    | scope, _, _, _ -> decode_error ("unknown path scope: " ^ scope)
  in
  let scope = function
    | Workspace _ -> "workspace"
    | Outside_workspace _ -> "outside"
    | Unknown _ -> "unknown"
  in
  let path = function
    | Outside_workspace path -> Some (Spice_path.Abs.to_string path)
    | Unknown path -> Some path
    | Workspace _ -> None
  in
  let root_key = function
    | Workspace { root_key; _ } ->
        Some (Spice_workspace.Root.Key.to_string root_key)
    | Outside_workspace _ | Unknown _ -> None
  in
  let relative = function
    | Workspace { relative; _ } -> Some (Spice_path.Rel.to_string relative)
    | Outside_workspace _ | Unknown _ -> None
  in
  Jsont.Object.map ~kind:"path scope" make
  |> Jsont.Object.mem "scope" Jsont.string ~enc:scope
  |> Jsont.Object.opt_mem "path" Jsont.string ~enc:path
  |> Jsont.Object.opt_mem "root_key" Jsont.string ~enc:root_key
  |> Jsont.Object.opt_mem "relative" Jsont.string ~enc:relative
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let command_execution_jsont =
  Jsont.enum
    [ ("enforced", Enforced); ("external", External); ("direct", Direct) ]

let command_jsont =
  let make kind text program args language source cwd execution =
    match (kind, text, program, args, language, source) with
    | "shell", Some text, None, None, None, None ->
        decode_invalid_arg (fun () ->
            command (Command.shell ~cwd ~execution text))
    | "argv", None, Some program, Some args, None, None ->
        decode_invalid_arg (fun () ->
            command (Command.argv ~cwd ~execution ~program args))
    | "code", None, None, None, Some language, Some source ->
        decode_invalid_arg (fun () ->
            command (Command.code ~cwd ~execution ~language source))
    | "shell", _, _, _, _, _ ->
        decode_error
          "shell command requires text and must not carry argv or code fields"
    | "argv", _, _, _, _, _ ->
        decode_error
          "argv command requires program and args and must not carry shell or \
           code fields"
    | "code", _, _, _, _, _ ->
        decode_error
          "code command requires language and source and must not carry shell \
           or argv fields"
    | kind, _, _, _, _, _ -> decode_error ("unknown command kind: " ^ kind)
  in
  let kind = function
    | Command (Shell _) -> "shell"
    | Command (Argv _) -> "argv"
    | Command (Code _) -> "code"
    | _ -> assert false
  in
  let text = function
    | Command (Shell { text; _ }) -> Some text
    | Command (Argv _ | Code _) -> None
    | _ -> assert false
  in
  let program = function
    | Command (Argv { program; _ }) -> Some program
    | Command (Shell _ | Code _) -> None
    | _ -> assert false
  in
  let args = function
    | Command (Argv { args; _ }) -> Some args
    | Command (Shell _ | Code _) -> None
    | _ -> assert false
  in
  let language = function
    | Command (Code { language; _ }) -> Some language
    | Command (Shell _ | Argv _) -> None
    | _ -> assert false
  in
  let source = function
    | Command (Code { source; _ }) -> Some source
    | Command (Shell _ | Argv _) -> None
    | _ -> assert false
  in
  let cwd = function
    | Command (Shell { cwd; _ } | Argv { cwd; _ } | Code { cwd; _ }) -> cwd
    | _ -> assert false
  in
  let execution = function
    | Command command -> Command.execution command
    | _ -> assert false
  in
  Jsont.Object.map ~kind:"command access" make
  |> Jsont.Object.mem "kind" Jsont.string ~enc:kind
  |> Jsont.Object.opt_mem "text" Jsont.string ~enc:text
  |> Jsont.Object.opt_mem "program" Jsont.string ~enc:program
  |> Jsont.Object.opt_mem "args" Jsont.(list string) ~enc:args
  |> Jsont.Object.opt_mem "language" Jsont.string ~enc:language
  |> Jsont.Object.opt_mem "source" Jsont.string ~enc:source
  |> Jsont.Object.mem "cwd" path_scope_jsont ~enc:cwd
  |> Jsont.Object.mem "execution" command_execution_jsont ~enc:execution
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let network_jsont =
  let make protocol host port =
    decode_invalid_arg (fun () -> network ~protocol ?port ~host ())
  in
  Jsont.Object.map ~kind:"network access" make
  |> Jsont.Object.mem "protocol" network_protocol_jsont ~enc:(function
    | Network { protocol; _ } -> protocol
    | _ -> assert false)
  |> Jsont.Object.mem "host" Jsont.string ~enc:(function
    | Network { host; _ } -> host
    | _ -> assert false)
  |> Jsont.Object.opt_mem "port" Jsont.int ~enc:(function
    | Network { port; _ } -> port
    | _ -> assert false)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let custom_jsont =
  let make name subject =
    decode_invalid_arg (fun () -> custom ?subject name)
  in
  Jsont.Object.map ~kind:"custom access" make
  |> Jsont.Object.mem "name" Jsont.string ~enc:(function
    | Custom { name; _ } -> name
    | _ -> assert false)
  |> Jsont.Object.opt_mem "subject" Jsont.string ~enc:(function
    | Custom { subject; _ } -> subject
    | _ -> assert false)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let jsont =
  let path_case = Jsont.Object.Case.map "path" path_jsont ~dec:Fun.id in
  let command_case =
    Jsont.Object.Case.map "command" command_jsont ~dec:Fun.id
  in
  let network_case =
    Jsont.Object.Case.map "network" network_jsont ~dec:Fun.id
  in
  let custom_case = Jsont.Object.Case.map "custom" custom_jsont ~dec:Fun.id in
  let enc_case = function
    | Path _ as access -> Jsont.Object.Case.value path_case access
    | Command _ as access -> Jsont.Object.Case.value command_case access
    | Network _ as access -> Jsont.Object.Case.value network_case access
    | Custom _ as access -> Jsont.Object.Case.value custom_case access
  in
  let cases =
    Jsont.Object.Case.
      [ make path_case; make command_case; make network_case; make custom_case ]
  in
  Jsont.Object.map ~kind:"permission access" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let pp_path_op ppf = function
  | `Read -> Format.pp_print_string ppf "read"
  | `Create -> Format.pp_print_string ppf "create"
  | `Modify -> Format.pp_print_string ppf "modify"
  | `Delete -> Format.pp_print_string ppf "delete"

let pp_scope ppf = function
  | Workspace { root_key; relative } ->
      Format.fprintf ppf "workspace(root_key=%S, relative=%S)"
        (Spice_workspace.Root.Key.to_string root_key)
        (Spice_path.Rel.to_string relative)
  | Outside_workspace path ->
      Format.fprintf ppf "outside(%S)" (Spice_path.Abs.to_string path)
  | Unknown path -> Format.fprintf ppf "unknown(%S)" path

let pp_protocol ppf = function
  | `Http -> Format.pp_print_string ppf "http"
  | `Https -> Format.pp_print_string ppf "https"
  | `Ssh -> Format.pp_print_string ppf "ssh"
  | `Tcp -> Format.pp_print_string ppf "tcp"
  | `Udp -> Format.pp_print_string ppf "udp"
  | `Other protocol -> Format.fprintf ppf "other(%S)" protocol

let pp_port ppf = function
  | None -> ()
  | Some port -> Format.fprintf ppf ":%d" port

let pp_subject ppf = function
  | None -> ()
  | Some subject -> Format.fprintf ppf ", subject=%S" subject

let pp ppf = function
  | Path { op; scope } ->
      Format.fprintf ppf "path(%a, %a)" pp_path_op op pp_scope scope
  | Command command -> Command.pp ppf command
  | Network { protocol; host; port } ->
      Format.fprintf ppf "network(%a://%s%a)" pp_protocol protocol host pp_port
        port
  | Custom { name; subject } ->
      Format.fprintf ppf "custom(%S%a)" name pp_subject subject
