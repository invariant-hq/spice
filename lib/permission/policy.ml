(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
open Codec

let invalid fn message = invalid_arg' "Spice_permission.Policy" fn message

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let reject_empty_option fn field = Option.iter (reject_empty fn field)

let check_protocol fn = function
  | `Other protocol -> reject_empty fn "protocol name" protocol
  | `Http | `Https | `Ssh | `Tcp | `Udp -> ()

let check_port fn = function
  | None -> ()
  | Some port ->
      if port < 1 || port > 65_535 then
        invalid fn "port must be between 1 and 65535"

let workspace_parts path =
  let root = Spice_workspace.Path.root path in
  let root_key = Spice_workspace.Root.key root in
  let relative = Spice_workspace.Path.rel path in
  (root_key, relative)

module Path_match = struct
  type t =
    | Workspace_exact of {
        root_key : Spice_workspace.Root.Key.t;
        relative : Spice_path.Rel.t;
      }
    | Workspace_under of {
        root_key : Spice_workspace.Root.Key.t;
        relative : Spice_path.Rel.t;
      }
    | Relative_exact of { relative : Spice_path.Rel.t }
    | Relative_under of { relative : Spice_path.Rel.t }
    | Any_workspace
    | Any_outside_workspace
    | Any_unknown

  let exact_key ~root_key ~relative = Workspace_exact { root_key; relative }

  let exact path =
    let root_key, relative = workspace_parts path in
    exact_key ~root_key ~relative

  let under_key ~root_key ~relative = Workspace_under { root_key; relative }

  let under path =
    let root_key, relative = workspace_parts path in
    under_key ~root_key ~relative

  let exact_relative relative = Relative_exact { relative }
  let under_relative relative = Relative_under { relative }
  let workspace = Any_workspace
  let outside_workspace = Any_outside_workspace
  let unknown = Any_unknown

  let matches pattern scope =
    match (pattern, scope) with
    | Workspace_exact { root_key; relative }, Access.Path_scope.Workspace scope
      ->
        Spice_workspace.Root.Key.equal scope.root_key root_key
        && Spice_path.Rel.equal scope.relative relative
    | Workspace_under { root_key; relative }, Access.Path_scope.Workspace scope
      ->
        Spice_workspace.Root.Key.equal scope.root_key root_key
        && Option.is_some
             (Spice_path.Rel.relativize ~root:relative scope.relative)
    | Relative_exact { relative }, Access.Path_scope.Workspace scope ->
        Spice_path.Rel.equal scope.relative relative
    | Relative_under { relative }, Access.Path_scope.Workspace scope ->
        Option.is_some (Spice_path.Rel.relativize ~root:relative scope.relative)
    | Any_workspace, Access.Path_scope.Workspace _ -> true
    | Any_outside_workspace, Access.Path_scope.Outside_workspace _ -> true
    | Any_unknown, Access.Path_scope.Unknown _ -> true
    | ( ( Workspace_exact _ | Workspace_under _ | Relative_exact _
        | Relative_under _ | Any_workspace | Any_outside_workspace | Any_unknown
          ),
        _ ) ->
        false

  let stable_text = function
    | Workspace_exact { root_key; relative } ->
        "workspace-exact:"
        ^ stable_field (Spice_workspace.Root.Key.to_string root_key)
        ^ ":"
        ^ stable_field (Spice_path.Rel.to_string relative)
    | Workspace_under { root_key; relative } ->
        "workspace-under:"
        ^ stable_field (Spice_workspace.Root.Key.to_string root_key)
        ^ ":"
        ^ stable_field (Spice_path.Rel.to_string relative)
    | Relative_exact { relative } ->
        "relative-exact:" ^ stable_field (Spice_path.Rel.to_string relative)
    | Relative_under { relative } ->
        "relative-under:" ^ stable_field (Spice_path.Rel.to_string relative)
    | Any_workspace -> "workspace"
    | Any_outside_workspace -> "outside-workspace"
    | Any_unknown -> "unknown"

  let pp ppf = function
    | Workspace_exact { root_key; relative } ->
        Format.fprintf ppf "scope-exact(%S, %S)"
          (Spice_workspace.Root.Key.to_string root_key)
          (Spice_path.Rel.to_string relative)
    | Workspace_under { root_key; relative } ->
        Format.fprintf ppf "scope-under(%S, %S)"
          (Spice_workspace.Root.Key.to_string root_key)
          (Spice_path.Rel.to_string relative)
    | Relative_exact { relative } ->
        Format.fprintf ppf "scope-relative-exact(%S)"
          (Spice_path.Rel.to_string relative)
    | Relative_under { relative } ->
        Format.fprintf ppf "scope-relative-under(%S)"
          (Spice_path.Rel.to_string relative)
    | Any_workspace -> Format.pp_print_string ppf "workspace"
    | Any_outside_workspace -> Format.pp_print_string ppf "outside-workspace"
    | Any_unknown -> Format.pp_print_string ppf "unknown"
end

module Command_match = struct
  type t =
    | Any
    | Exact of Access.Command.t
    | Argv_prefix of {
        execution : Access.Command.execution;
        cwd : Path_match.t;
        program : string;
        args : string list;
      }
    | Execution of Access.Command.execution
    | Destructive

  let any = Any
  let exact command = Exact command
  let execution execution = Execution execution
  let destructive = Destructive

  let argv_prefix ~execution ~cwd ~program ~args () =
    reject_empty "Match.Command.argv_prefix" "program" program;
    Argv_prefix { execution; cwd; program; args }

  (* Programs and flag combinations that irreversibly delete or overwrite data
     the model never named, or escalate out of confinement. A workspace sandbox
     bounds where such a command writes but not whether the loss is
     recoverable, so {!Destructive} keeps them reviewable even under a posture
     that otherwise allows commands. The classifier inspects the already-parsed
     argv structurally; for the shell-text form it applies the same rules to a
     lenient token scan that ignores quoting and expansion — over-flagging
     rather than missing a destructive form a redirect or substitution hid. *)
  let shell_syntax = function
    | '\'' | '"' | '`' | '$' | '(' | ')' -> true
    | _ -> false

  let unquote token =
    let len = String.length token in
    let rec left i =
      if i < len && shell_syntax token.[i] then left (i + 1) else i
    in
    let rec right i =
      if i >= 0 && shell_syntax token.[i] then right (i - 1) else i
    in
    let first = left 0 in
    let last = right (len - 1) in
    if last < first then "" else String.sub token first (last - first + 1)

  let scan_words sub =
    String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) sub
    |> String.split_on_char ' '
    |> List.filter_map (fun raw ->
           match unquote raw with "" -> None | word -> Some word)

  let scan_subcommands command =
    let buf = Buffer.create (String.length command) in
    let acc = ref [] in
    let flush () =
      acc := Buffer.contents buf :: !acc;
      Buffer.clear buf
    in
    String.iter
      (function ';' | '|' | '&' | '\n' -> flush () | c -> Buffer.add_char buf c)
      command;
    flush ();
    List.rev !acc

  let is_env_assignment token =
    match String.index_opt token '=' with
    | None | Some 0 -> false
    | Some equals ->
        let name_char c =
          c = '_'
          || (c >= 'A' && c <= 'Z')
          || (c >= 'a' && c <= 'z')
          || (c >= '0' && c <= '9')
        in
        let ok = ref true in
        String.iteri
          (fun i c -> if i < equals && not (name_char c) then ok := false)
          token;
        !ok

  let pass_through_wrapper = function
    | "command" | "env" | "exec" | "xargs" | "nohup" | "stdbuf" -> true
    | _ -> false

  let rec program_and_args = function
    | token :: rest when is_env_assignment token -> program_and_args rest
    | token :: rest when pass_through_wrapper (Filename.basename token) ->
        program_and_args rest
    | token :: rest -> Some (Filename.basename token, rest)
    | [] -> None

  let short_flag has_char token =
    String.length token >= 2
    && token.[0] = '-'
    && token.[1] <> '-'
    && String.exists (Char.equal has_char) token

  let has_flag ~long ~short args =
    List.exists (fun t -> List.mem t long || short_flag short t) args

  let git_is_destructive args =
    match
      List.find_opt (fun t -> not (String.length t > 0 && t.[0] = '-')) args
    with
    | Some "push" ->
        has_flag ~long:[ "--force"; "--force-with-lease" ] ~short:'f' args
    | Some "reset" -> List.mem "--hard" args
    | Some "clean" -> has_flag ~long:[ "--force" ] ~short:'f' args
    | _ -> false

  let shell_program = function
    | "sh" | "bash" | "dash" | "zsh" | "ksh" -> true
    | _ -> false

  let command_string args =
    let rec loop = function
      | option :: command :: _
        when String.length option > 1 && option.[0] = '-'
             && String.contains option 'c' ->
          Some command
      | _ :: rest -> loop rest
      | [] -> None
    in
    loop args

  let opaque_substitution text =
    let rec has_dollar_paren i =
      i + 1 < String.length text
      &&
      if Char.equal text.[i] '$' && Char.equal text.[i + 1] '(' then true
      else has_dollar_paren (i + 1)
    in
    String.contains text '`' || has_dollar_paren 0

  let rec program_is_destructive program args =
    match program with
    | "sudo" | "doas" | "eval" | "source" | "." -> true
    | "dd" | "shred" | "mkfs" -> true
    | "rm" ->
        has_flag ~long:[ "--force"; "--recursive" ] ~short:'f' args
        || List.exists (short_flag 'r') args
        || List.exists (short_flag 'R') args
    | "git" -> git_is_destructive args
    | shell when shell_program shell -> (
        match command_string args with
        | None -> false
        | Some command ->
            opaque_substitution command || shell_text_is_destructive command)
    | _ ->
        String.length program > 5 && String.equal (String.sub program 0 5) "mkfs."

  and tokens_are_destructive tokens =
    match program_and_args tokens with
    | Some (program, args) -> program_is_destructive program args
    | None -> false

  and tokens_contain_destructive = function
    | [] -> false
    | (_ :: rest as tokens) ->
        tokens_are_destructive tokens || tokens_contain_destructive rest

  and shell_text_is_destructive text =
    opaque_substitution text
    || List.exists
         (fun sub -> tokens_contain_destructive (scan_words sub))
         (scan_subcommands text)

  let command_is_destructive = function
    | Access.Command.Argv { program; args; _ } ->
        tokens_contain_destructive (program :: args)
    | Access.Command.Shell { text; _ } -> shell_text_is_destructive text
    | Access.Command.Code _ -> false

  let list_has_prefix ~prefix values =
    let rec loop prefix values =
      match (prefix, values) with
      | [], _ -> true
      | value :: prefix, candidate :: values ->
          String.equal value candidate && loop prefix values
      | _ :: _, [] -> false
    in
    loop prefix values

  let matches pattern command =
    match (pattern, command) with
    | Any, _ -> true
    | Exact expected, command ->
        Access.Command.stable_text expected = Access.Command.stable_text command
    | ( Argv_prefix { execution; cwd; program; args },
        Access.Command.Argv
          {
            program = access_program;
            args = access_args;
            cwd = access_cwd;
            execution = access_execution;
          } )
      ->
        access_execution = execution
        && String.equal access_program program
        && list_has_prefix ~prefix:args access_args
        && Path_match.matches cwd access_cwd
    | Argv_prefix _, (Access.Command.Shell _ | Access.Command.Code _) -> false
    | Execution execution, command ->
        Access.Command.execution command = execution
    | Destructive, command -> command_is_destructive command

  let stable_text = function
    | Any -> "any"
    | Exact command ->
        "exact:" ^ stable_field (Access.Command.stable_text command)
    | Argv_prefix { execution; cwd; program; args } ->
        "argv-prefix:"
        ^ Access.Command.execution_to_string execution
        ^ ":" ^ stable_field program ^ ":"
        ^ String.concat ":" (List.map stable_field args)
        ^ ":" ^ Path_match.stable_text cwd
    | Execution execution ->
        "execution:" ^ Access.Command.execution_to_string execution
    | Destructive -> "destructive"

  let pp ppf = function
    | Any -> Format.pp_print_string ppf "any-command"
    | Execution execution ->
        Format.fprintf ppf "command-execution(%s)"
          (Access.Command.execution_to_string execution)
    | Destructive -> Format.pp_print_string ppf "destructive-command"
    | Exact command ->
        Format.fprintf ppf "command-exact(%a)" Access.Command.pp command
    | Argv_prefix { execution; cwd; program; args } ->
        Format.fprintf ppf "argv-prefix(%s, %S, %a, cwd=%a)"
          (Access.Command.execution_to_string execution) program
          (Format.pp_print_list
             ~pp_sep:(fun ppf () -> Format.pp_print_string ppf " ")
             (fun ppf arg -> Format.fprintf ppf "%S" arg))
          args Path_match.pp cwd
end

module Rule = struct
  type matcher =
    | Any
    | Kind of Access.kind
    | Exact of Access.t
    | Path_scope of { op : Access.path_op option; scope : Path_match.t }
    | Command of Command_match.t
    | Network_host of {
        protocol : Access.network_protocol option;
        host : string;
        port : int option;
      }
    | Custom of { name : string; subject : string option }

  type action = Allow | Review | Deny
  type t = { action : action; matcher : matcher }

  let kind kind = Kind kind
  let exact key = Exact key
  let path ?op scope = Path_scope { op; scope }
  let command pattern = Command pattern

  let network_host ?protocol ?port ~host () =
    let fn = "Rule.network_host" in
    Option.iter (check_protocol fn) protocol;
    reject_empty fn "host" host;
    check_port fn port;
    Network_host { protocol; host; port }

  let custom ?subject name =
    let fn = "Rule.custom" in
    reject_empty fn "name" name;
    reject_empty_option fn "subject" subject;
    Custom { name; subject }

  let allow matcher = { action = Allow; matcher }
  let review matcher = { action = Review; matcher }
  let deny matcher = { action = Deny; matcher }
  let make action matcher = { action; matcher }
  let always_review = review Any
  let deny_all = deny Any
  let allow_all_dangerously = allow Any
  let equal a b = a = b
  let action t = t.action
  let matcher t = t.matcher

  let matcher_matches matcher access =
    match matcher with
    | Any -> true
    | Kind kind -> Access.kind access = kind
    | Exact expected -> Access.equal expected access
    | Path_scope { op; scope } -> (
        match access with
        | Access.Path { op = access_op; scope = access_scope } ->
            Option.for_all (( = ) access_op) op
            && Path_match.matches scope access_scope
        | Access.Command _ | Access.Network _ | Access.Custom _ -> false)
    | Command pattern -> (
        match access with
        | Access.Command command -> Command_match.matches pattern command
        | Access.Path _ | Access.Network _ | Access.Custom _ -> false)
    | Network_host { protocol; host; port } -> (
        match access with
        | Access.Network
            {
              protocol = access_protocol;
              host = access_host;
              port = access_port;
            } -> (
            Option.for_all (( = ) access_protocol) protocol
            && String.equal access_host host
            &&
            match port with
            | None -> true
            | Some port -> (
                match access_port with
                | Some access_port -> Int.equal access_port port
                | None -> false))
        | Access.Path _ | Access.Command _ | Access.Custom _ -> false)
    | Custom { name; subject } -> (
        match access with
        | Access.Custom { name = access_name; subject = access_subject } -> (
            String.equal access_name name
            &&
            match subject with
            | None -> true
            | Some subject -> (
                match access_subject with
                | Some access_subject -> String.equal access_subject subject
                | None -> false))
        | Access.Path _ | Access.Command _ | Access.Network _ -> false)

  let stable_matcher = function
    | Any -> "any"
    | Kind kind -> "kind:" ^ stable_kind kind
    | Exact access -> "exact:" ^ stable_field (Access.stable_text access)
    | Path_scope { op; scope } ->
        "path:"
        ^ stable_option stable_path_op op
        ^ ":"
        ^ Path_match.stable_text scope
    | Command pattern ->
        "command:" ^ stable_field (Command_match.stable_text pattern)
    | Network_host { protocol; host; port } ->
        "network-host:"
        ^ stable_option stable_protocol protocol
        ^ ":" ^ stable_field host ^ ":"
        ^ stable_option string_of_int port
    | Custom { name; subject } ->
        "custom:" ^ stable_field name ^ ":"
        ^ stable_option stable_field subject

  let stable_action = function
    | Allow -> "allow"
    | Review -> "review"
    | Deny -> "deny"

  let stable_text t = stable_action t.action ^ ":" ^ stable_matcher t.matcher

  let pp_kind ppf = function
    | `Read -> Format.pp_print_string ppf "read"
    | `Write -> Format.pp_print_string ppf "write"
    | `Command -> Format.pp_print_string ppf "command"
    | `Network -> Format.pp_print_string ppf "network"
    | `Custom -> Format.pp_print_string ppf "custom"

  let pp_path_op ppf = function
    | `Read -> Format.pp_print_string ppf "read"
    | `Create -> Format.pp_print_string ppf "create"
    | `Modify -> Format.pp_print_string ppf "modify"
    | `Delete -> Format.pp_print_string ppf "delete"

  let pp_protocol ppf = function
    | `Http -> Format.pp_print_string ppf "http"
    | `Https -> Format.pp_print_string ppf "https"
    | `Ssh -> Format.pp_print_string ppf "ssh"
    | `Tcp -> Format.pp_print_string ppf "tcp"
    | `Udp -> Format.pp_print_string ppf "udp"
    | `Other protocol -> Format.fprintf ppf "other(%S)" protocol

  let pp_matcher ppf = function
    | Any -> Format.pp_print_string ppf "any"
    | Kind kind -> Format.fprintf ppf "kind:%a" pp_kind kind
    | Exact access -> Format.fprintf ppf "exact:%a" Access.pp access
    | Path_scope { op; scope } ->
        Format.fprintf ppf "path(%a%a)"
          (fun ppf -> function
            | None -> () | Some op -> Format.fprintf ppf "%a, " pp_path_op op)
          op Path_match.pp scope
    | Command pattern ->
        Format.fprintf ppf "command(%a)" Command_match.pp pattern
    | Network_host { protocol; host; port } ->
        Format.fprintf ppf "network-host(%a%s%a)"
          (fun ppf -> function
            | None -> ()
            | Some protocol -> Format.fprintf ppf "%a://" pp_protocol protocol)
          protocol host
          (fun ppf -> function
            | None -> () | Some port -> Format.fprintf ppf ":%d" port)
          port
    | Custom { name; subject } ->
        Format.fprintf ppf "custom(%S%a)" name
          (fun ppf -> function
            | None -> ()
            | Some subject -> Format.fprintf ppf ", subject=%S" subject)
          subject

  let pp_action ppf = function
    | Allow -> Format.pp_print_string ppf "allow"
    | Review -> Format.pp_print_string ppf "review"
    | Deny -> Format.pp_print_string ppf "deny"

  let pp ppf t =
    Format.fprintf ppf "%a(%a)" pp_action t.action pp_matcher t.matcher

  let action_jsont =
    Jsont.enum ~kind:"permission rule action"
      [ ("allow", Allow); ("review", Review); ("deny", Deny) ]

  let decode_scope_relative relative =
    match Spice_path.Rel.of_string relative with
    | Ok relative -> relative
    | Error error ->
        decode_error
          ("invalid scope relative path: " ^ Spice_path.Error.message error)

  let decode_root_key root_key =
    match Spice_workspace.Root.Key.of_string root_key with
    | Ok root_key -> root_key
    | Error error ->
        decode_error
          ("invalid workspace root key: "
          ^ Spice_workspace.Root.Key.message error)

  let any_matcher_jsont =
    Jsont.Object.map ~kind:"any permission matcher" Any
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let kind_matcher_jsont =
    Jsont.Object.map ~kind:"kind permission matcher" (fun access_kind ->
        kind access_kind)
    |> Jsont.Object.mem "kind" kind_jsont ~enc:(function
      | Kind kind -> kind
      | Any | Exact _ | Path_scope _ | Command _ | Network_host _ | Custom _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let exact_matcher_jsont =
    Jsont.Object.map ~kind:"exact permission matcher" (fun access ->
        exact access)
    |> Jsont.Object.mem "access" Access.jsont ~enc:(function
      | Exact access -> access
      | Any | Kind _ | Path_scope _ | Command _ | Network_host _ | Custom _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  (* The seven flat [path-*] matcher wire cases collapse to three shapes keyed
     by scope arity (workspace root+relative, relative-only, empty). The shared
     projections below extract fields from a matcher that [matcher_jsont]'s
     [enc_case] has already routed to the matching case; [assert false] marks
     states that routing rules out. Tags, members, and member order are
     unchanged, so the persisted wire is identical. *)

  let path_scope_op = function
    | Path_scope { op; _ } -> op
    | Any | Kind _ | Exact _ | Command _ | Network_host _ | Custom _ ->
        assert false

  let path_workspace_root_key = function
    | Path_scope
        {
          scope =
            ( Path_match.Workspace_exact { root_key; _ }
            | Path_match.Workspace_under { root_key; _ } );
          _;
        } ->
        Spice_workspace.Root.Key.to_string root_key
    | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Network_host _
    | Custom _ ->
        assert false

  let path_workspace_relative = function
    | Path_scope
        {
          scope =
            ( Path_match.Workspace_exact { relative; _ }
            | Path_match.Workspace_under { relative; _ } );
          _;
        } ->
        Spice_path.Rel.to_string relative
    | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Network_host _
    | Custom _ ->
        assert false

  let path_relative_relative = function
    | Path_scope
        {
          scope =
            ( Path_match.Relative_exact { relative }
            | Path_match.Relative_under { relative } );
          _;
        } ->
        Spice_path.Rel.to_string relative
    | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Network_host _
    | Custom _ ->
        assert false

  let workspace_path_matcher_jsont ~kind make_scope =
    let make op root_key relative =
      decode_invalid_arg (fun () ->
          let root_key = decode_root_key root_key in
          let relative = decode_scope_relative relative in
          path ?op (make_scope ~root_key ~relative))
    in
    Jsont.Object.map ~kind make
    |> Jsont.Object.opt_mem "op" path_op_jsont ~enc:path_scope_op
    |> Jsont.Object.mem "root_key" Jsont.string ~enc:path_workspace_root_key
    |> Jsont.Object.mem "relative" Jsont.string ~enc:path_workspace_relative
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let relative_path_matcher_jsont ~kind make_scope =
    let make op relative =
      decode_invalid_arg (fun () ->
          path ?op (make_scope (decode_scope_relative relative)))
    in
    Jsont.Object.map ~kind make
    |> Jsont.Object.opt_mem "op" path_op_jsont ~enc:path_scope_op
    |> Jsont.Object.mem "relative" Jsont.string ~enc:path_relative_relative
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let empty_path_matcher_jsont ~kind scope =
    Jsont.Object.map ~kind (fun op -> path ?op scope)
    |> Jsont.Object.opt_mem "op" path_op_jsont ~enc:path_scope_op
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let path_exact_matcher_jsont =
    workspace_path_matcher_jsont ~kind:"path exact permission matcher"
      Path_match.exact_key

  let path_under_matcher_jsont =
    workspace_path_matcher_jsont ~kind:"path under permission matcher"
      Path_match.under_key

  let path_exact_relative_matcher_jsont =
    relative_path_matcher_jsont ~kind:"path exact relative permission matcher"
      Path_match.exact_relative

  let path_under_relative_matcher_jsont =
    relative_path_matcher_jsont ~kind:"path under relative permission matcher"
      Path_match.under_relative

  let path_workspace_matcher_jsont =
    empty_path_matcher_jsont ~kind:"workspace path permission matcher"
      Path_match.workspace

  let path_outside_workspace_matcher_jsont =
    empty_path_matcher_jsont ~kind:"outside workspace path permission matcher"
      Path_match.outside_workspace

  let path_unknown_matcher_jsont =
    empty_path_matcher_jsont ~kind:"unknown path permission matcher"
      Path_match.unknown

  let scope_workspace_matcher_jsont kind make =
    let decode root_key relative =
      decode_invalid_arg (fun () ->
          let root_key = decode_root_key root_key in
          let relative = decode_scope_relative relative in
          make ~root_key ~relative)
    in
    Jsont.Object.map ~kind decode
    |> Jsont.Object.mem "root_key" Jsont.string ~enc:(function
      | Path_match.Workspace_exact { root_key; _ }
      | Path_match.Workspace_under { root_key; _ } ->
          Spice_workspace.Root.Key.to_string root_key
      | Path_match.Relative_exact _ | Path_match.Relative_under _
      | Path_match.Any_workspace | Path_match.Any_outside_workspace
      | Path_match.Any_unknown ->
          assert false)
    |> Jsont.Object.mem "relative" Jsont.string ~enc:(function
      | Path_match.Workspace_exact { relative; _ }
      | Path_match.Workspace_under { relative; _ } ->
          Spice_path.Rel.to_string relative
      | Path_match.Relative_exact _ | Path_match.Relative_under _
      | Path_match.Any_workspace | Path_match.Any_outside_workspace
      | Path_match.Any_unknown ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let scope_relative_matcher_jsont kind make =
    let decode relative =
      decode_invalid_arg (fun () -> make (decode_scope_relative relative))
    in
    Jsont.Object.map ~kind decode
    |> Jsont.Object.mem "relative" Jsont.string ~enc:(function
      | Path_match.Relative_exact { relative }
      | Path_match.Relative_under { relative } ->
          Spice_path.Rel.to_string relative
      | Path_match.Workspace_exact _ | Path_match.Workspace_under _
      | Path_match.Any_workspace | Path_match.Any_outside_workspace
      | Path_match.Any_unknown ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let empty_scope_matcher_jsont kind matcher =
    Jsont.Object.map ~kind matcher
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let scope_jsont =
    let workspace_exact_case =
      Jsont.Object.Case.map "workspace-exact"
        (scope_workspace_matcher_jsont "workspace exact scope"
           (fun ~root_key ~relative -> Path_match.exact_key ~root_key ~relative))
        ~dec:Fun.id
    in
    let workspace_under_case =
      Jsont.Object.Case.map "workspace-under"
        (scope_workspace_matcher_jsont "workspace under scope"
           (fun ~root_key ~relative -> Path_match.under_key ~root_key ~relative))
        ~dec:Fun.id
    in
    let relative_exact_case =
      Jsont.Object.Case.map "relative-exact"
        (scope_relative_matcher_jsont "relative exact scope"
           Path_match.exact_relative)
        ~dec:Fun.id
    in
    let relative_under_case =
      Jsont.Object.Case.map "relative-under"
        (scope_relative_matcher_jsont "relative under scope"
           Path_match.under_relative)
        ~dec:Fun.id
    in
    let outside_case =
      Jsont.Object.Case.map "outside-workspace"
        (empty_scope_matcher_jsont "outside workspace scope"
           Path_match.outside_workspace)
        ~dec:Fun.id
    in
    let workspace_case =
      Jsont.Object.Case.map "workspace"
        (empty_scope_matcher_jsont "workspace scope" Path_match.workspace)
        ~dec:Fun.id
    in
    let unknown_case =
      Jsont.Object.Case.map "unknown"
        (empty_scope_matcher_jsont "unknown scope" Path_match.unknown)
        ~dec:Fun.id
    in
    let enc_case = function
      | Path_match.Workspace_exact _ as scope ->
          Jsont.Object.Case.value workspace_exact_case scope
      | Path_match.Workspace_under _ as scope ->
          Jsont.Object.Case.value workspace_under_case scope
      | Path_match.Relative_exact _ as scope ->
          Jsont.Object.Case.value relative_exact_case scope
      | Path_match.Relative_under _ as scope ->
          Jsont.Object.Case.value relative_under_case scope
      | Path_match.Any_workspace as scope ->
          Jsont.Object.Case.value workspace_case scope
      | Path_match.Any_outside_workspace as scope ->
          Jsont.Object.Case.value outside_case scope
      | Path_match.Any_unknown as scope ->
          Jsont.Object.Case.value unknown_case scope
    in
    let cases =
      [
        Jsont.Object.Case.make workspace_exact_case;
        Jsont.Object.Case.make workspace_under_case;
        Jsont.Object.Case.make relative_exact_case;
        Jsont.Object.Case.make relative_under_case;
        Jsont.Object.Case.make workspace_case;
        Jsont.Object.Case.make outside_case;
        Jsont.Object.Case.make unknown_case;
      ]
    in
    Jsont.Object.map ~kind:"scope matcher" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let command_any_pattern_jsont =
    Jsont.Object.map ~kind:"any command matcher" Command_match.any
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let command_destructive_pattern_jsont =
    Jsont.Object.map ~kind:"destructive command matcher" Command_match.destructive
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let command_execution_jsont =
    Jsont.enum
      [
        ("enforced", Access.Command.Enforced);
        ("external", Access.Command.External);
        ("direct", Access.Command.Direct);
      ]

  let command_execution_pattern_jsont =
    Jsont.Object.map ~kind:"command execution matcher" Command_match.execution
    |> Jsont.Object.mem "execution" command_execution_jsont ~enc:(function
      | Command_match.Execution execution -> execution
      | Command_match.Any | Command_match.Exact _
      | Command_match.Argv_prefix _ | Command_match.Destructive ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let command_exact_pattern_jsont =
    let make access =
      match access with
      | Access.Command command -> Command_match.exact command
      | Access.Path _ | Access.Network _ | Access.Custom _ ->
          decode_error "command exact pattern requires command access"
    in
    Jsont.Object.map ~kind:"exact command matcher" make
    |> Jsont.Object.mem "access" Access.jsont ~enc:(function
      | Command_match.Exact command -> Access.command command
      | Command_match.Any | Command_match.Argv_prefix _
      | Command_match.Execution _ | Command_match.Destructive ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let command_argv_prefix_pattern_jsont =
    let make execution cwd program args =
      decode_invalid_arg (fun () ->
          Command_match.argv_prefix ~execution ~cwd ~program ~args ())
    in
    Jsont.Object.map ~kind:"argv prefix command matcher" make
    |> Jsont.Object.mem "execution" command_execution_jsont ~enc:(function
      | Command_match.Argv_prefix { execution; _ } -> execution
      | Command_match.Any | Command_match.Exact _
      | Command_match.Execution _ | Command_match.Destructive ->
          assert false)
    |> Jsont.Object.mem "cwd" scope_jsont ~enc:(function
      | Command_match.Argv_prefix { cwd; _ } -> cwd
      | Command_match.Any | Command_match.Exact _
      | Command_match.Execution _ | Command_match.Destructive ->
          assert false)
    |> Jsont.Object.mem "program" Jsont.string ~enc:(function
      | Command_match.Argv_prefix { program; _ } -> program
      | Command_match.Any | Command_match.Exact _ | Command_match.Execution _
      | Command_match.Destructive ->
          assert false)
    |> Jsont.Object.mem "args"
         Jsont.(list string)
         ~enc:(function
           | Command_match.Argv_prefix { args; _ } -> args
           | Command_match.Any | Command_match.Exact _
           | Command_match.Execution _ | Command_match.Destructive ->
               assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let command_pattern_jsont =
    let any_case =
      Jsont.Object.Case.map "any" command_any_pattern_jsont ~dec:Fun.id
    in
    let destructive_case =
      Jsont.Object.Case.map "destructive" command_destructive_pattern_jsont
        ~dec:Fun.id
    in
    let execution_case =
      Jsont.Object.Case.map "execution" command_execution_pattern_jsont
        ~dec:Fun.id
    in
    let exact_case =
      Jsont.Object.Case.map "exact" command_exact_pattern_jsont ~dec:Fun.id
    in
    let argv_prefix_case =
      Jsont.Object.Case.map "argv-prefix" command_argv_prefix_pattern_jsont
        ~dec:Fun.id
    in
    let enc_case = function
      | Command_match.Any as pattern -> Jsont.Object.Case.value any_case pattern
      | Command_match.Destructive as pattern ->
          Jsont.Object.Case.value destructive_case pattern
      | Command_match.Execution _ as pattern ->
          Jsont.Object.Case.value execution_case pattern
      | Command_match.Exact _ as pattern ->
          Jsont.Object.Case.value exact_case pattern
      | Command_match.Argv_prefix _ as pattern ->
          Jsont.Object.Case.value argv_prefix_case pattern
    in
    let cases =
      [
        Jsont.Object.Case.make any_case;
        Jsont.Object.Case.make destructive_case;
        Jsont.Object.Case.make execution_case;
        Jsont.Object.Case.make exact_case;
        Jsont.Object.Case.make argv_prefix_case;
      ]
    in
    Jsont.Object.map ~kind:"command matcher pattern" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let command_matcher_jsont =
    Jsont.Object.map ~kind:"command permission matcher" command
    |> Jsont.Object.mem "pattern" command_pattern_jsont ~enc:(function
      | Command pattern -> pattern
      | Any | Kind _ | Exact _ | Path_scope _ | Network_host _ | Custom _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let network_host_matcher_jsont =
    let make protocol host port =
      decode_invalid_arg (fun () -> network_host ?protocol ?port ~host ())
    in
    Jsont.Object.map ~kind:"network host permission matcher" make
    |> Jsont.Object.opt_mem "protocol" network_protocol_jsont ~enc:(function
      | Network_host { protocol; _ } -> protocol
      | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Custom _ ->
          assert false)
    |> Jsont.Object.mem "host" Jsont.string ~enc:(function
      | Network_host { host; _ } -> host
      | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Custom _ ->
          assert false)
    |> Jsont.Object.opt_mem "port" Jsont.int ~enc:(function
      | Network_host { port; _ } -> port
      | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Custom _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let custom_matcher_jsont =
    let make name subject =
      decode_invalid_arg (fun () -> custom ?subject name)
    in
    Jsont.Object.map ~kind:"custom permission matcher" make
    |> Jsont.Object.mem "name" Jsont.string ~enc:(function
      | Custom { name; _ } -> name
      | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Network_host _ ->
          assert false)
    |> Jsont.Object.opt_mem "subject" Jsont.string ~enc:(function
      | Custom { subject; _ } -> subject
      | Any | Kind _ | Exact _ | Path_scope _ | Command _ | Network_host _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let matcher_jsont =
    let any_case = Jsont.Object.Case.map "any" any_matcher_jsont ~dec:Fun.id in
    let kind_case =
      Jsont.Object.Case.map "kind" kind_matcher_jsont ~dec:Fun.id
    in
    let exact_case =
      Jsont.Object.Case.map "exact" exact_matcher_jsont ~dec:Fun.id
    in
    let path_exact_case =
      Jsont.Object.Case.map "path-exact" path_exact_matcher_jsont ~dec:Fun.id
    in
    let path_under_case =
      Jsont.Object.Case.map "path-under" path_under_matcher_jsont ~dec:Fun.id
    in
    let path_exact_relative_case =
      Jsont.Object.Case.map "path-exact-relative"
        path_exact_relative_matcher_jsont ~dec:Fun.id
    in
    let path_under_relative_case =
      Jsont.Object.Case.map "path-under-relative"
        path_under_relative_matcher_jsont ~dec:Fun.id
    in
    let path_workspace_case =
      Jsont.Object.Case.map "path-workspace" path_workspace_matcher_jsont
        ~dec:Fun.id
    in
    let path_outside_workspace_case =
      Jsont.Object.Case.map "path-outside-workspace"
        path_outside_workspace_matcher_jsont ~dec:Fun.id
    in
    let path_unknown_case =
      Jsont.Object.Case.map "path-unknown" path_unknown_matcher_jsont
        ~dec:Fun.id
    in
    let command_case =
      Jsont.Object.Case.map "command" command_matcher_jsont ~dec:Fun.id
    in
    let network_host_case =
      Jsont.Object.Case.map "network-host" network_host_matcher_jsont
        ~dec:Fun.id
    in
    let custom_case =
      Jsont.Object.Case.map "custom" custom_matcher_jsont ~dec:Fun.id
    in
    let enc_case = function
      | Any as matcher -> Jsont.Object.Case.value any_case matcher
      | Kind _ as matcher -> Jsont.Object.Case.value kind_case matcher
      | Exact _ as matcher -> Jsont.Object.Case.value exact_case matcher
      | Path_scope { scope = Path_match.Workspace_exact _; _ } as matcher ->
          Jsont.Object.Case.value path_exact_case matcher
      | Path_scope { scope = Path_match.Workspace_under _; _ } as matcher ->
          Jsont.Object.Case.value path_under_case matcher
      | Path_scope { scope = Path_match.Relative_exact _; _ } as matcher ->
          Jsont.Object.Case.value path_exact_relative_case matcher
      | Path_scope { scope = Path_match.Relative_under _; _ } as matcher ->
          Jsont.Object.Case.value path_under_relative_case matcher
      | Path_scope { scope = Path_match.Any_workspace; _ } as matcher ->
          Jsont.Object.Case.value path_workspace_case matcher
      | Path_scope { scope = Path_match.Any_outside_workspace; _ } as matcher ->
          Jsont.Object.Case.value path_outside_workspace_case matcher
      | Path_scope { scope = Path_match.Any_unknown; _ } as matcher ->
          Jsont.Object.Case.value path_unknown_case matcher
      | Command _ as matcher -> Jsont.Object.Case.value command_case matcher
      | Network_host _ as matcher ->
          Jsont.Object.Case.value network_host_case matcher
      | Custom _ as matcher -> Jsont.Object.Case.value custom_case matcher
    in
    let cases =
      [
        Jsont.Object.Case.make any_case;
        Jsont.Object.Case.make kind_case;
        Jsont.Object.Case.make exact_case;
        Jsont.Object.Case.make path_exact_case;
        Jsont.Object.Case.make path_under_case;
        Jsont.Object.Case.make path_exact_relative_case;
        Jsont.Object.Case.make path_under_relative_case;
        Jsont.Object.Case.make path_workspace_case;
        Jsont.Object.Case.make path_outside_workspace_case;
        Jsont.Object.Case.make path_unknown_case;
        Jsont.Object.Case.make command_case;
        Jsont.Object.Case.make network_host_case;
        Jsont.Object.Case.make custom_case;
      ]
    in
    Jsont.Object.map ~kind:"permission matcher" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont =
    let make action matcher =
      match action with
      | Allow -> allow matcher
      | Review -> review matcher
      | Deny -> deny matcher
    in
    Jsont.Object.map ~kind:"permission rule" make
    |> Jsont.Object.mem "action" action_jsont ~enc:(fun rule -> rule.action)
    |> Jsont.Object.mem "matcher" matcher_jsont ~enc:(fun rule -> rule.matcher)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Match = struct
  type t = Rule.matcher

  let any = Rule.Any
  let kind = Rule.kind
  let exact = Rule.exact

  module Path = struct
    type t = Path_match.t

    let exact = Path_match.exact
    let exact_key = Path_match.exact_key
    let under = Path_match.under
    let under_key = Path_match.under_key
    let exact_relative = Path_match.exact_relative
    let under_relative = Path_match.under_relative
    let workspace = Path_match.workspace
    let outside_workspace = Path_match.outside_workspace
    let unknown = Path_match.unknown
  end

  let path = Rule.path

  module Command = struct
    type t = Command_match.t

    let any = Command_match.any
    let destructive = Command_match.destructive
    let execution = Command_match.execution
    let exact = Command_match.exact
    let argv_prefix = Command_match.argv_prefix
  end

  let command = Rule.command
  let network_host = Rule.network_host
  let custom = Rule.custom
  let matches = Rule.matcher_matches
  let pp = Rule.pp_matcher
  let jsont = Rule.matcher_jsont
end

type t = Rule.t list

module Grants = struct
  type t = Access.Set.t

  let empty = Access.Set.empty
  let allows grants access = Access.Set.mem access grants
  let add_access grants access = Access.Set.add access grants
  let add_accesses accesses grants = List.fold_left add_access grants accesses
  let equal = Access.Set.equal

  let pp ppf grants =
    Format.fprintf ppf "grants[%a]"
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         Access.pp)
      (Access.Set.to_list grants)
end

module Review = struct
  type reason = Unmatched | By_rule of Rule.t
  type t = { request : Request.t; reasons : (Access.t * reason) list }
  type restore_error = Empty_accesses | Access_not_in_request of Access.t

  let access_set_of_list accesses =
    List.fold_left
      (fun set access -> Access.Set.add access set)
      Access.Set.empty accesses

  let access_of_reason (access, _) = access

  let normalize_reasons request reasons =
    Request.normalized_accesses request
    |> List.filter_map (fun access ->
        List.find_opt
          (fun (candidate, _) -> Access.equal access candidate)
          reasons)

  let restore request reasons =
    if List.is_empty reasons then Error Empty_accesses
    else
      let request_accesses = Request.accesses request in
      let request_accesses_set = access_set_of_list request_accesses in
      match
        List.find_map
          (fun (access, _) ->
            if Access.Set.mem access request_accesses_set then None
            else Some access)
          reasons
      with
      | Some access -> Error (Access_not_in_request access)
      | None -> Ok { request; reasons = normalize_reasons request reasons }

  let of_reasons request reasons =
    match restore request reasons with
    | Ok review -> review
    | Error Empty_accesses ->
        invalid "Review.of_reasons" "reasons must not be empty"
    | Error (Access_not_in_request _) ->
        invalid "Review.of_reasons" "accesses must belong to request"

  let request t = t.request
  let reasons t = t.reasons
  let accesses t = List.map access_of_reason t.reasons
  let access_set t = access_set_of_list (accesses t)

  let items t =
    let accesses = access_set t in
    Request.items t.request
    |> List.filter (fun item ->
        Access.Set.mem (Request.Item.access item) accesses)

  let changes t = items t |> List.filter_map Request.Item.change

  let remember review grants = Grants.add_accesses (accesses review) grants
end

module Denial = struct
  type t = { request : Request.t; access : Access.t; rule : Rule.t }

  let request t = t.request
  let access t = t.access
  let rule t = t.rule
end

module Decision = struct
  type t = Allowed | Review of Review.t | Denied of Denial.t * Denial.t list
end

type explanation =
  | Allowed_by_rule of Rule.t
  | Allowed_by_grant
  | Needs_review
  | Needs_review_by_rule of Rule.t
  | Denied_by_rule of Rule.t

let default = []
let make rules = rules
let matches = Rule.matcher_matches

let explanation_of_rule rule =
  match rule.Rule.action with
  | Rule.Allow -> Allowed_by_rule rule
  | Rule.Review -> Needs_review_by_rule rule
  | Rule.Deny -> Denied_by_rule rule

let explain ?(grants = Grants.empty) policy access =
  let rec loop = function
    | [] ->
        if Grants.allows grants access then Allowed_by_grant else Needs_review
    | rule :: rules ->
        if matches rule.Rule.matcher access then explanation_of_rule rule
        else loop rules
  in
  loop policy

let decide ?(grants = Grants.empty) policy request =
  let rec loop denials review_reasons = function
    | [] -> (
        match List.rev denials with
        | first :: rest -> Decision.Denied (first, rest)
        | [] -> (
            match List.rev review_reasons with
            | [] -> Decision.Allowed
            | reasons -> Decision.Review (Review.of_reasons request reasons))
        )
    | access :: accesses -> (
        match explain ~grants policy access with
        | Denied_by_rule rule ->
            loop
              ({ Denial.request; Denial.access; Denial.rule } :: denials)
              review_reasons accesses
        | Allowed_by_rule _ | Allowed_by_grant ->
            loop denials review_reasons accesses
        | Needs_review ->
            loop denials ((access, Review.Unmatched) :: review_reasons) accesses
        | Needs_review_by_rule rule ->
            loop denials
              ((access, Review.By_rule rule) :: review_reasons)
              accesses)
  in
  loop [] [] (Request.normalized_accesses request)

let equal a b = a = b

let pp ppf rules =
  Format.fprintf ppf "policy[%a]"
    (Format.pp_print_list
       ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
       Rule.pp)
    rules

let jsont =
  let decode version rules =
    if version <> 1 then
      decode_error
        ("unknown permission policy version: " ^ string_of_int version);
    make rules
  in
  Jsont.Object.map ~kind:"permission policy" decode
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun _ -> 1)
  |> Jsont.Object.mem "rules" Jsont.(list Rule.jsont) ~enc:Fun.id
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
