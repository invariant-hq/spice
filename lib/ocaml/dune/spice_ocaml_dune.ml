(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Ocaml = Spice_ocaml
module Workspace = Spice_workspace

let ( let* ) = Result.bind

let string_contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec loop i =
      if i > hl - nl then false
      else if String.equal (String.sub haystack i nl) needle then true
      else loop (i + 1)
    in
    loop 0

module Error = struct
  type source = Workspace_describe | Tests_describe | Rpc

  type t =
    | Command_failed of {
        argv : string list;
        cwd : string;
        status : int option;
        stderr : string;
      }
    | Parse_error of { source : source; offset : int option; message : string }
    | Path_error of { path : string; message : string }
    | Duplicate_library_uid of string
    | Unknown_library_uid of string
    | Invalid_state of { expected : string; actual : string }
    | Connection_failed of { endpoint : string; message : string }
    | Protocol_error of { message : string; payload : string option }

  let source_text = function
    | Workspace_describe -> "dune describe workspace"
    | Tests_describe -> "dune describe tests"
    | Rpc -> "dune rpc"

  let argv_text argv =
    String.concat " "
      (List.map
         (fun arg ->
           if
             String.exists
               (function ' ' | '\t' | '\n' -> true | _ -> false)
               arg
           then Filename.quote arg
           else arg)
         argv)

  let message = function
    | Command_failed { argv; cwd; status; stderr } ->
        let status =
          match status with
          | None -> "failed"
          | Some code -> "exited " ^ string_of_int code
        in
        let stderr = String.trim stderr in
        let suffix = if String.equal stderr "" then "" else ": " ^ stderr in
        "command " ^ argv_text argv ^ " in " ^ cwd ^ " " ^ status ^ suffix
    | Parse_error { source; offset; message } ->
        let where =
          match offset with
          | None -> ""
          | Some offset -> " at byte " ^ string_of_int offset
        in
        source_text source ^ " parse error" ^ where ^ ": " ^ message
    | Path_error { path; message } ->
        "invalid Dune path " ^ path ^ ": " ^ message
    | Duplicate_library_uid uid -> "duplicate Dune library uid " ^ uid
    | Unknown_library_uid uid -> "unknown Dune library uid " ^ uid
    | Invalid_state { expected; actual } ->
        "invalid Dune RPC session state: expected " ^ expected ^ ", got "
        ^ actual
    | Connection_failed { endpoint; message } ->
        "failed to connect to Dune RPC endpoint " ^ endpoint ^ ": " ^ message
    | Protocol_error { message; payload } -> (
        match payload with
        | None -> message
        | Some payload -> message ^ ": " ^ payload)

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Sexp = struct
  type t = Atom of string | List of t list

  let parse ~source input =
    let len = String.length input in
    let error ?offset message =
      Error
        (Error.Parse_error
           { source; offset = Some (Option.value offset ~default:0); message })
    in
    let rec skip i =
      if i >= len then i
      else
        match input.[i] with ' ' | '\t' | '\r' | '\n' -> skip (i + 1) | _ -> i
    in
    let rec quoted buffer i =
      if i >= len then error ~offset:i "unterminated string"
      else
        match input.[i] with
        | '"' -> Ok (Atom (Buffer.contents buffer), i + 1)
        | '\\' when i + 1 < len ->
            let char =
              match input.[i + 1] with
              | 'n' -> '\n'
              | 'r' -> '\r'
              | 't' -> '\t'
              | c -> c
            in
            Buffer.add_char buffer char;
            quoted buffer (i + 2)
        | '\\' -> error ~offset:i "unterminated escape"
        | c ->
            Buffer.add_char buffer c;
            quoted buffer (i + 1)
    in
    let atom i =
      let start = i in
      let rec loop i =
        if i >= len then i
        else
          match input.[i] with
          | ' ' | '\t' | '\r' | '\n' | '(' | ')' -> i
          | _ -> loop (i + 1)
      in
      let stop = loop i in
      if stop = start then error ~offset:start "expected atom"
      else Ok (Atom (String.sub input start (stop - start)), stop)
    in
    let rec one i =
      let i = skip i in
      if i >= len then error ~offset:i "expected s-expression"
      else
        match input.[i] with
        | '(' -> list [] (i + 1)
        | ')' -> error ~offset:i "unexpected ')'"
        | '"' -> quoted (Buffer.create 16) (i + 1)
        | _ -> atom i
    and list acc i =
      let i = skip i in
      if i >= len then error ~offset:i "unterminated list"
      else
        match input.[i] with
        | ')' -> Ok (List (List.rev acc), i + 1)
        | _ -> (
            match one i with
            | Error _ as error -> error
            | Ok (sexp, i) -> list (sexp :: acc) i)
    in
    match one 0 with
    | Error _ as error -> error
    | Ok (sexp, i) ->
        let i = skip i in
        if i = len then Ok sexp else error ~offset:i "trailing input"

  let atom = function Atom value -> Some value | List _ -> None
  let list = function List values -> Some values | Atom _ -> None
  let string_of_t = function Atom value -> value | List _ -> "<list>"
end

module Describe = struct
  module P = Ocaml.Project

  let log_src =
    Logs.Src.create "spice.ocaml.dune.describe" ~doc:"dune describe subprocess"

  module Log = (val Logs.src_log log_src : Logs.LOG)

  type component_acc = {
    component : P.Component.t;
    uid : string option;
    requires : string list option;
  }

  let workspace_args ?(with_deps = true) ?(recursive = true) () =
    let args = [ "dune"; "describe"; "workspace"; "--root"; "." ] in
    let args = if with_deps then args @ [ "--with-deps" ] else args in
    if recursive then args else args @ [ "--no-recursive" ]

  let tests_args ?context () =
    let args = [ "dune"; "describe"; "tests"; "--root"; "." ] in
    match context with None -> args | Some context -> args @ [ context ]

  let path_error path error =
    Error (Error.Path_error { path; message = Spice_path.Error.message error })

  let workspace_error path error =
    Error
      (Error.Path_error
         { path; message = Workspace.Resolve_error.message error })

  let parse_error source message =
    Error (Error.Parse_error { source; offset = None; message })

  let construct ~source f =
    try Ok (f ()) with Invalid_argument message -> parse_error source message

  let module_name ~source name =
    construct ~source (fun () -> Ocaml.Module_name.make name)

  let path_of_string workspace text =
    if String.equal text "" then
      Error
        (Error.Path_error { path = text; message = "path must not be empty" })
    else if String.starts_with ~prefix:"/" text then
      match Spice_path.Abs.of_string text with
      | Error error -> path_error text error
      | Ok abs -> (
          match Workspace.import_abs workspace abs with
          | Error error -> workspace_error text error
          | Ok path -> Ok path)
    else
      match Spice_path.Rel.of_string text with
      | Error error -> path_error text error
      | Ok rel -> Ok (Workspace.Path.append (Workspace.root_path workspace) rel)

  let workspace_path_of_string workspace text =
    if String.equal text "" then
      Error
        (Error.Path_error { path = text; message = "path must not be empty" })
    else if String.starts_with ~prefix:"/" text then
      match Spice_path.Abs.of_string text with
      | Error error -> path_error text error
      | Ok abs -> (
          match Workspace.import_abs workspace abs with
          | Ok path -> Ok (Some path)
          | Error (Workspace.Resolve_error.Outside_workspace _) -> Ok None
          | Error error -> workspace_error text error)
    else Result.map Option.some (path_of_string workspace text)

  let opt_path ?(external_paths = false) workspace = function
    | Sexp.List [] -> Ok None
    | Sexp.List [ Sexp.Atom path ] ->
        if external_paths then workspace_path_of_string workspace path
        else Result.map Option.some (path_of_string workspace path)
    | sexp -> (
        match Sexp.atom sexp with
        | None ->
            Error
              (Error.Parse_error
                 {
                   source = Error.Workspace_describe;
                   offset = None;
                   message = "expected path atom or empty option";
                 })
        | Some path ->
            if external_paths then workspace_path_of_string workspace path
            else Result.map Option.some (path_of_string workspace path))

  let record_fields ~source = function
    | Sexp.List fields ->
        let field = function
          | Sexp.List [ Sexp.Atom name; value ] -> Ok (name, value)
          | other ->
              Error
                (Error.Parse_error
                   {
                     source;
                     offset = None;
                     message =
                       "expected record field, got " ^ Sexp.string_of_t other;
                   })
        in
        List.fold_right
          (fun sexp acc ->
            match (field sexp, acc) with
            | Ok field, Ok fields -> Ok (field :: fields)
            | (Error _ as error), _ | _, (Error _ as error) -> error)
          fields (Ok [])
    | other ->
        Error
          (Error.Parse_error
             {
               source;
               offset = None;
               message = "expected record, got " ^ Sexp.string_of_t other;
             })

  let field fields name = List.assoc_opt name fields

  let required ~source fields name =
    match field fields name with
    | Some value -> Ok value
    | None ->
        Error
          (Error.Parse_error
             { source; offset = None; message = "missing field " ^ name })

  let atom_field ~source fields name =
    let* value = required ~source fields name in
    match Sexp.atom value with
    | Some value -> Ok value
    | None ->
        Error
          (Error.Parse_error
             {
               source;
               offset = None;
               message = "field " ^ name ^ " must be an atom";
             })

  let bool_field ~source fields name =
    let* value = atom_field ~source fields name in
    match value with
    | "true" -> Ok true
    | "false" -> Ok false
    | _ ->
        Error
          (Error.Parse_error
             {
               source;
               offset = None;
               message = "field " ^ name ^ " must be a bool";
             })

  let atoms_field ~source fields name =
    let* value = required ~source fields name in
    match Sexp.list value with
    | Some values ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | value :: values -> (
              match Sexp.atom value with
              | Some value -> loop (value :: acc) values
              | None ->
                  Error
                    (Error.Parse_error
                       {
                         source;
                         offset = None;
                         message = "field " ^ name ^ " must be an atom list";
                       }))
        in
        loop [] values
    | None ->
        Error
          (Error.Parse_error
             {
               source;
               offset = None;
               message = "field " ^ name ^ " must be a list";
             })

  let deps_field ~source fields name make =
    match field fields name with
    | None -> Ok P.Deps.Unknown
    | Some value -> (
        match Sexp.list value with
        | None ->
            Error
              (Error.Parse_error
                 {
                   source;
                   offset = None;
                   message = "field " ^ name ^ " must be a list";
                 })
        | Some values ->
            let rec loop acc = function
              | [] -> Ok (P.Deps.Known (List.rev acc))
              | value :: values -> (
                  match Sexp.atom value with
                  | Some value ->
                      let* value = make ~source value in
                      loop (value :: acc) values
                  | None ->
                      Error
                        (Error.Parse_error
                           {
                             source;
                             offset = None;
                             message = "field " ^ name ^ " must be an atom list";
                           }))
            in
            loop [] values)

  let module_deps fields =
    match field fields "module_deps" with
    | None -> Ok (P.Deps.Unknown, P.Deps.Unknown)
    | Some sexp ->
        let* fields = record_fields ~source:Error.Workspace_describe sexp in
        let* for_intf =
          deps_field ~source:Error.Workspace_describe fields "for_intf"
            module_name
        in
        let* for_impl =
          deps_field ~source:Error.Workspace_describe fields "for_impl"
            module_name
        in
        Ok (for_intf, for_impl)

  let compilation_unit ?(external_paths = false) workspace sexp =
    let* fields = record_fields ~source:Error.Workspace_describe sexp in
    let* name = atom_field ~source:Error.Workspace_describe fields "name" in
    let* impl = required ~source:Error.Workspace_describe fields "impl" in
    let* intf = required ~source:Error.Workspace_describe fields "intf" in
    let* impl = opt_path ~external_paths workspace impl in
    let* intf = opt_path ~external_paths workspace intf in
    let* interface_deps, implementation_deps = module_deps fields in
    let* name = module_name ~source:Error.Workspace_describe name in
    construct ~source:Error.Workspace_describe (fun () ->
        P.Compilation_unit.make ?impl ?intf ~interface_deps ~implementation_deps
          name)

  let compilation_units ?(external_paths = false) workspace fields =
    let* modules = required ~source:Error.Workspace_describe fields "modules" in
    match Sexp.list modules with
    | None ->
        Error
          (Error.Parse_error
             {
               source = Error.Workspace_describe;
               offset = None;
               message = "modules must be a list";
             })
    | Some modules ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | sexp :: rest -> (
              match compilation_unit ~external_paths workspace sexp with
              | Ok unit_ -> loop (unit_ :: acc) rest
              | Error _ as error -> error)
        in
        loop [] modules

  let library_component workspace fields =
    let* name = atom_field ~source:Error.Workspace_describe fields "name" in
    let* uid = atom_field ~source:Error.Workspace_describe fields "uid" in
    let* local = bool_field ~source:Error.Workspace_describe fields "local" in
    let* source_dir =
      atom_field ~source:Error.Workspace_describe fields "source_dir"
    in
    let* source_dir, units =
      if local then
        let* source_dir = path_of_string workspace source_dir in
        let* units = compilation_units workspace fields in
        Ok (Some source_dir, units)
      else
        let* source_dir = workspace_path_of_string workspace source_dir in
        let* units = compilation_units ~external_paths:true workspace fields in
        Ok (source_dir, units)
    in
    let* requires =
      atoms_field ~source:Error.Workspace_describe fields "requires"
    in
    let* component =
      construct ~source:Error.Workspace_describe (fun () ->
          if local then P.Component.local_library ?source_dir ~name ~units ()
          else P.Component.external_library ?source_dir ~name ~units ())
    in
    Ok { component; uid = Some uid; requires = Some requires }

  let executable_components workspace fields =
    let* names = atoms_field ~source:Error.Workspace_describe fields "names" in
    let* requires =
      atoms_field ~source:Error.Workspace_describe fields "requires"
    in
    let* units = compilation_units workspace fields in
    let source_dir =
      List.find_map
        (fun unit_ ->
          match P.Compilation_unit.impl unit_ with
          | Some path -> Workspace.Path.parent path
          | None ->
              Option.bind (P.Compilation_unit.intf unit_) Workspace.Path.parent)
        units
    in
    let source_dir =
      Option.value source_dir ~default:(Workspace.cwd workspace)
    in
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | name :: names ->
          let* component =
            construct ~source:Error.Workspace_describe (fun () ->
                P.Component.executable ~dir:source_dir ~name ~units ())
          in
          loop
            ({ component; uid = None; requires = Some requires } :: acc)
            names
    in
    loop [] names

  let item workspace = function
    | Sexp.List [ Sexp.Atom "root"; Sexp.Atom root ] ->
        let* root = path_of_string workspace root in
        Ok (`Root root)
    | Sexp.List [ Sexp.Atom "build_context"; Sexp.Atom build_context ] ->
        Ok (`Build_context build_context)
    | Sexp.List [ Sexp.Atom "library"; record ] ->
        let* fields = record_fields ~source:Error.Workspace_describe record in
        Result.map
          (fun component -> `Components [ component ])
          (library_component workspace fields)
    | Sexp.List [ Sexp.Atom "executables"; record ] ->
        let* fields = record_fields ~source:Error.Workspace_describe record in
        Result.map
          (fun components -> `Components components)
          (executable_components workspace fields)
    | sexp ->
        Error
          (Error.Parse_error
             {
               source = Error.Workspace_describe;
               offset = None;
               message = "unknown workspace item " ^ Sexp.string_of_t sexp;
             })

  let resolve_requires components =
    let uid_table = Hashtbl.create 17 in
    let add_uid acc =
      match acc.uid with
      | None -> Ok ()
      | Some uid -> (
          match Hashtbl.find_opt uid_table uid with
          | None ->
              Hashtbl.add uid_table uid (P.Component.id acc.component);
              Ok ()
          | Some _ -> Error (Error.Duplicate_library_uid uid))
    in
    let rec add_all = function
      | [] -> Ok ()
      | acc :: rest -> (
          match add_uid acc with
          | Ok () -> add_all rest
          | Error _ as error -> error)
    in
    let resolve uid =
      match Hashtbl.find_opt uid_table uid with
      | Some id -> Ok id
      | None -> Error (Error.Unknown_library_uid uid)
    in
    let rec map_requires acc = function
      | [] -> Ok (List.rev acc)
      | uid :: uids -> (
          match resolve uid with
          | Ok id -> map_requires (id :: acc) uids
          | Error _ as error -> error)
    in
    let component acc =
      match acc.requires with
      | None -> Ok acc.component
      | Some uids ->
          let* requires = map_requires [] uids in
          construct ~source:Error.Workspace_describe (fun () ->
              P.Component.with_requires (P.Deps.Known requires) acc.component)
    in
    let rec components_loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: items -> (
          match component item with
          | Ok component -> components_loop (component :: acc) items
          | Error _ as error -> error)
    in
    let* () = add_all components in
    components_loop [] components

  let of_workspace_output ~workspace output =
    let* sexp = Sexp.parse ~source:Error.Workspace_describe output in
    let values =
      match sexp with
      | Sexp.List values -> Ok values
      | Sexp.Atom _ ->
          Error
            (Error.Parse_error
               {
                 source = Error.Workspace_describe;
                 offset = None;
                 message = "expected item list";
               })
    in
    let* values = values in
    let rec loop root build_context components = function
      | [] ->
          let* components = resolve_requires (List.rev components) in
          construct ~source:Error.Workspace_describe (fun () ->
              P.make ?root ?build_context components)
      | sexp :: rest -> (
          match item workspace sexp with
          | Error _ as error -> error
          | Ok (`Root root) -> loop (Some root) build_context components rest
          | Ok (`Build_context build_context) ->
              loop root (Some build_context) components rest
          | Ok (`Components new_components) ->
              loop root build_context
                (List.rev_append new_components components)
                rest)
    in
    loop None None [] values

  let location_of_string workspace text =
    let split =
      match String.rindex_opt text ':' with
      | None -> None
      | Some col_sep -> (
          match String.rindex_from_opt text (col_sep - 1) ':' with
          | None -> None
          | Some line_sep -> Some (line_sep, col_sep))
    in
    match split with
    | None -> None
    | Some (line_sep, col_sep) -> (
        let path = String.sub text 0 line_sep in
        let line =
          String.sub text (line_sep + 1) (col_sep - line_sep - 1)
          |> int_of_string_opt
        in
        let column =
          String.drop_first (col_sep + 1) text |> int_of_string_opt
        in
        match (line, column, path_of_string workspace path) with
        | Some line, Some column, Ok path ->
            begin try
              let position = Ocaml.Position.make ~line ~column in
              Some
                (Ocaml.Location.make ~path ~range:(Ocaml.Range.point position))
            with Invalid_argument _ -> None
            end
        | _ -> None)

  let component_for_test project source_dir =
    P.components project
    |> List.find_opt (fun component ->
        match P.Component.source_dir component with
        | None -> false
        | Some dir -> Workspace.Path.equal dir source_dir)
    |> Option.map P.Component.id

  let test_of_sexp workspace project sexp =
    let* fields = record_fields ~source:Error.Tests_describe sexp in
    let* name = atom_field ~source:Error.Tests_describe fields "name" in
    let* source_dir =
      atom_field ~source:Error.Tests_describe fields "source_dir"
    in
    let* target = atom_field ~source:Error.Tests_describe fields "target" in
    let* enabled = bool_field ~source:Error.Tests_describe fields "enabled" in
    let* source_dir = path_of_string workspace source_dir in
    let package =
      match field fields "package" with
      | Some (Sexp.Atom package) -> Some package
      | Some (Sexp.List []) | None -> None
      | Some _ -> None
    in
    let location =
      match field fields "location" with
      | Some (Sexp.Atom location) -> location_of_string workspace location
      | Some _ | None -> None
    in
    let component = component_for_test project source_dir in
    construct ~source:Error.Tests_describe (fun () ->
        P.Test.make ?component ?package ?location ~name ~source_dir ~target
          ~enabled ())

  let of_tests_output ~workspace project output =
    let* sexp = Sexp.parse ~source:Error.Tests_describe output in
    let tests =
      match sexp with
      | Sexp.List values ->
          let rec loop acc = function
            | [] -> Ok (List.rev acc)
            | value :: values -> (
                match test_of_sexp workspace project value with
                | Ok test -> loop (test :: acc) values
                | Error _ as error -> error)
          in
          loop [] values
      | Sexp.Atom _ ->
          Error
            (Error.Parse_error
               {
                 source = Error.Tests_describe;
                 offset = None;
                 message = "expected test list";
               })
    in
    let* tests = tests in
    construct ~source:Error.Tests_describe (fun () ->
        P.make ?root:(P.root project) ?build_context:(P.build_context project)
          ~tests (P.components project))

  let of_outputs ~workspace ~workspace_output ~tests_output =
    let* project = of_workspace_output ~workspace workspace_output in
    of_tests_output ~workspace project tests_output

  let cwd_text cwd =
    Option.value (Eio.Path.native cwd)
      ~default:(Format.asprintf "%a" Eio.Path.pp cwd)

  let command_failed argv cwd ~stderr exn =
    let status =
      match exn with
      | Eio.Io (Eio.Process.E (Eio.Process.Child_error (`Exited code)), _) ->
          Some code
      | _ -> None
    in
    let stderr =
      let stderr = String.trim stderr in
      if String.equal stderr "" then Printexc.to_string exn else stderr
    in
    Error (Error.Command_failed { argv; cwd = cwd_text cwd; status; stderr })

  let command_timed_out argv cwd ~stderr timeout_s =
    let stderr = String.trim stderr in
    let stderr =
      if String.equal stderr "" then
        Printf.sprintf "timed out after %.0fs" timeout_s
      else Printf.sprintf "timed out after %.0fs: %s" timeout_s stderr
    in
    Error
      (Error.Command_failed { argv; cwd = cwd_text cwd; status = None; stderr })

  let default_describe_timeout_s = 30.0

  let run_describe ~process_mgr ~clock ?env cwd ~timeout_s argv =
    let stderr = Buffer.create 256 in
    try
      let run () =
        Eio.Process.parse_out process_mgr Eio.Buf_read.take_all
          ~stderr:(Eio.Flow.buffer_sink stderr)
          ?cwd:(Some cwd) ?env argv
      in
      let output = Eio.Time.with_timeout_exn clock timeout_s run in
      Log.debug (fun m ->
          m "dune describe finished command=%s bytes=%d" (Error.argv_text argv)
            (String.length output));
      Ok output
    with
    | Eio.Time.Timeout ->
        command_timed_out argv cwd ~stderr:(Buffer.contents stderr) timeout_s
    | exn -> command_failed argv cwd ~stderr:(Buffer.contents stderr) exn

  let describe_project ~process_mgr ~clock ~cwd ~workspace ?env
      ?(cancelled = fun () -> false) ?(timeout_s = default_describe_timeout_s)
      () =
    if cancelled () then
      Error
        (Error.Command_failed
           {
             argv = [];
             cwd = cwd_text cwd;
             status = None;
             stderr = "cancelled";
           })
    else
      let workspace_argv = workspace_args () in
      let tests_argv = tests_args () in
      let* workspace_output =
        run_describe ~process_mgr ~clock ?env cwd ~timeout_s workspace_argv
      in
      let* tests_output =
        run_describe ~process_mgr ~clock ?env cwd ~timeout_s tests_argv
      in
      of_outputs ~workspace ~workspace_output ~tests_output
end

module Rpc = struct
  module Drpc = Dune_rpc.Private

  let log_src =
    Logs.Src.create "spice.ocaml.dune.rpc" ~doc:"Dune RPC connection lifecycle"

  module Log = (val Logs.src_log log_src : Logs.LOG)

  module Dune_rpc_fiber = struct
    type 'a t = 'a

    let return x = x

    let fork_and_join_unit f g =
      let result = ref None in
      Eio.Fiber.both f (fun () -> result := Some (g ()));
      match !result with
      | Some value -> value
      | None -> invalid_arg "second fiber did not return"

    let parallel_iter next ~f =
      let rec loop () =
        match next () with
        | None -> ()
        | Some value ->
            f value;
            loop ()
      in
      loop ()

    let finalize f ~finally =
      match f () with
      | value ->
          finally ();
          value
      | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          finally ();
          Printexc.raise_with_backtrace exn backtrace

    let collect_errors f = try Ok (f ()) with exn -> Error [ exn ]

    module O = struct
      let ( let* ) value f = f value
      let ( let+ ) value f = f value
    end

    module Ivar = struct
      type 'a t = 'a Eio.Promise.t * 'a Eio.Promise.u

      let create () = Eio.Promise.create ()

      let read (promise, resolver) =
        ignore resolver;
        Eio.Promise.await promise

      let fill (promise, resolver) value =
        ignore promise;
        Eio.Promise.resolve resolver value
    end
  end

  module Dune_rpc_chan = struct
    type t =
      | Chan : { flow : _ Eio.Net.stream_socket; reader : Eio.Buf_read.t } -> t

    let of_flow flow =
      Chan { flow; reader = Eio.Buf_read.of_flow ~max_size:16_777_216 flow }

    let write (Chan { flow; reader }) sexps =
      ignore reader;
      List.iter
        (fun sexp -> Eio.Flow.copy_string (Csexp.to_string sexp) flow)
        sexps

    let close (Chan { flow; reader }) =
      ignore reader;
      Eio.Flow.close flow

    (* One csexp per call, consumed incrementally from the shared buffered
       reader with Csexp's streaming lexer. Csexp is length-prefixed, so an
       atom body is taken in a single bulk read; the message costs O(size)
       rather than the quadratic re-parse of the whole accumulated buffer per
       byte, and each [Buf_read] refill is a scheduler yield, so a large
       message (e.g. a big Dune diagnostic set) never stalls the domain nor
       outruns a wrapping timeout. Only this sexp's bytes are consumed; any
       trailing bytes stay buffered for the next call. *)
    let read (Chan { flow; reader }) =
      ignore flow;
      let module Parser = Csexp.Parser in
      let lexer = Parser.Lexer.create () in
      let rec loop stack =
        match Parser.Lexer.feed lexer (Eio.Buf_read.any_char reader) with
        | Parser.Lexer.Atom length ->
            let atom = Eio.Buf_read.take length reader in
            settle (Parser.Stack.add_atom atom stack)
        | (Parser.Lexer.Await | Parser.Lexer.Lparen | Parser.Lexer.Rparen) as
          token ->
            settle (Parser.Stack.add_token token stack)
      and settle stack =
        match stack with
        | Parser.Stack.Sexp (sexp, Parser.Stack.Empty) -> Some sexp
        | stack -> loop stack
      in
      try loop Parser.Stack.Empty with End_of_file -> None
  end

  module Dune_rpc_client = Drpc.Client.Make (Dune_rpc_fiber) (Dune_rpc_chan)

  let csexp_text sexp = Csexp.to_string sexp

  let protocol_error ?payload message =
    Error
      (Error.Protocol_error { message; payload = Option.map csexp_text payload })

  let response_error error =
    Error
      (Error.Protocol_error
         {
           message = Drpc.Response.Error.message error;
           payload = Option.map csexp_text (Drpc.Response.Error.payload error);
         })

  let version_error error =
    Error
      (Error.Protocol_error
         {
           message = Drpc.Version_error.message error;
           payload = Option.map csexp_text (Drpc.Version_error.payload error);
         })

  module Endpoint = struct
    type address = Unix of string | Tcp of { host : string; port : int }
    type t = { root : string; address : address }

    let make ~root address =
      if String.equal root "" then invalid_arg "root must not be empty";
      { root; address }

    let root t = t.root
    let address t = t.address

    let to_string t =
      match t.address with
      | Unix path -> t.root ^ " unix://" ^ path
      | Tcp { host; port } ->
          t.root ^ " tcp://" ^ host ^ ":" ^ string_of_int port

    let equal a b =
      String.equal a.root b.root
      &&
      match (a.address, b.address) with
      | Unix a, Unix b -> String.equal a b
      | Tcp a, Tcp b -> String.equal a.host b.host && Int.equal a.port b.port
      | (Unix _ | Tcp _), _ -> false

    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end

  module Registry = struct
    module Dune_registry = Drpc.Registry

    type t = {
      config : Dune_registry.Config.t;
      mutable registry : Dune_registry.t;
    }

    exception Missing_registry_dir

    module Registry_fiber = struct
      include Dune_rpc_fiber

      let parallel_map xs ~f = List.map f xs
    end

    let create ~env () =
      let config = Dune_registry.Config.create (Xdg.create ~env ()) in
      { config; registry = Dune_registry.create config }

    let reset t = t.registry <- Dune_registry.create t.config
    let current t = Dune_registry.current t.registry
    let root = Dune_registry.Dune.root
    let pid = Dune_registry.Dune.pid

    let endpoint entry =
      let address =
        match Dune_registry.Dune.where entry with
        | `Unix path -> Endpoint.Unix path
        | `Ip (`Host host, `Port port) -> Endpoint.Tcp { host; port }
      in
      Endpoint.make ~root:(root entry) address

    let poll ~fs t =
      let module Poll =
        Dune_registry.Poll
          (Registry_fiber)
          (struct
            let with_error f = try Ok (f ()) with exn -> Error exn
            let path raw = Eio.Path.( / ) fs raw

            let scandir raw =
              Dune_rpc_fiber.return
                (match Eio.Path.kind ~follow:true (path raw) with
                | `Not_found -> Ok []
                | _ -> with_error (fun () -> Eio.Path.read_dir (path raw)))

            let stat raw =
              Dune_rpc_fiber.return
                (match Eio.Path.kind ~follow:true (path raw) with
                | `Not_found -> Error Missing_registry_dir
                | _ ->
                    with_error (fun () ->
                        `Mtime
                          (Eio.Path.stat ~follow:true (path raw))
                            .Eio.File.Stat.mtime))

            let read_file raw =
              Dune_rpc_fiber.return
                (with_error (fun () -> Eio.Path.load (path raw)))
          end) in
      reset t;
      match Poll.poll t.registry with
      | Ok refresh -> (
          match Dune_registry.Refresh.errored refresh with
          | [] -> Ok (current t)
          | (path, exn) :: remaining ->
              Error
                (Error.Connection_failed
                   {
                     endpoint = path;
                     message =
                       Printexc.to_string exn ^ " ("
                       ^ string_of_int (List.length remaining + 1)
                       ^ " registry error(s))";
                   }))
      | Error Missing_registry_dir -> Ok (current t)
      | Error exn ->
          Error
            (Error.Connection_failed
               {
                 endpoint = "dune rpc registry";
                 message = Printexc.to_string exn;
               })
  end

  module Build = struct
    type progress =
      | Waiting
      | In_progress of { complete : int; remaining : int; failed : int }
      | Failed
      | Interrupted
      | Success

    type t = { progress : progress }

    let empty = { progress = Waiting }
    let progress t = t.progress

    let running t =
      match t.progress with
      | Waiting | In_progress _ -> true
      | Failed | Interrupted | Success -> false

    let update progress _ = { progress }
  end

  module Diagnostic = struct
    module Id = struct
      type t = string

      let of_string value =
        if String.equal value "" then
          invalid_arg "diagnostic id must not be empty";
        value

      let to_string t = t
      let equal = String.equal
      let compare = String.compare
      let pp ppf t = Format.pp_print_string ppf t
    end

    type id = Id.t
    type event = Add of id * Ocaml.Diagnostic.t | Remove of id

    module Store = struct
      type t = (id * Ocaml.Diagnostic.t) list

      let empty = []

      let apply event t =
        match event with
        | Add (id, diagnostic) -> (id, diagnostic) :: List.remove_assoc id t
        | Remove id -> List.remove_assoc id t

      let apply_many events t =
        List.fold_left (fun t event -> apply event t) t events

      let to_list t = List.rev t
      let find id t = List.assoc_opt id t
      let clear _ = empty
    end
  end

  type event =
    | Build_progress of Build.progress
    | Diagnostics of Diagnostic.event list
    | Disconnected of string option

  module Connection = struct
    type connection = Connection : _ Eio.Net.stream_socket -> connection

    type t = {
      endpoint : Endpoint.t;
      workspace : Workspace.t option;
      client : Dune_rpc_client.t;
      mutable build : Build.t;
      mutable diagnostics : Diagnostic.Store.t;
      connection : connection;
      mutable stopped : bool;
    }

    exception Payload_error of Error.t

    let make ~client ~connection ?workspace endpoint =
      {
        endpoint;
        workspace;
        client;
        build = Build.empty;
        diagnostics = Diagnostic.Store.empty;
        connection;
        stopped = false;
      }

    let endpoint t = t.endpoint
    let workspace t = t.workspace
    let build t = t.build
    let diagnostics t = t.diagnostics

    let init_request =
      Drpc.Initialize.Request.create
        ~id:
          (Drpc.Id.make
             (Csexp.List [ Csexp.Atom "spice"; Csexp.Atom "ocaml-dune" ]))

    let unix_socket_path_limit = 100

    let is_dir path =
      match Sys.is_directory path with
      | true -> true
      | false -> false
      | exception Sys_error _ -> false

    let temp_dir () =
      if is_dir "/tmp" then "/tmp" else Filename.get_temp_dir_name ()

    let realpath path =
      match Unix.realpath path with
      | path -> Some path
      | exception Unix.Unix_error _ -> None

    let normalize_dir path =
      match Filename.chop_suffix_opt ~suffix:Filename.dir_sep path with
      | Some path -> path
      | None -> path

    let drop_root ~root path =
      let root = normalize_dir root in
      if String.equal path root then Some ""
      else
        let prefix = root ^ Filename.dir_sep in
        if String.starts_with ~prefix path then
          Some (String.drop_first (String.length prefix) path)
        else None

    let realpath_with_basename path =
      let dir = Filename.dirname path in
      let base = Filename.basename path in
      Option.map (fun dir -> Filename.concat dir base) (realpath dir)

    let workspace_relative_socket endpoint path =
      let roots =
        Endpoint.root endpoint
        :: Option.to_list (realpath (Endpoint.root endpoint))
      in
      let paths = path :: Option.to_list (realpath_with_basename path) in
      List.find_map
        (fun root ->
          List.find_map
            (fun path ->
              Option.map (fun rel -> (root, rel)) (drop_root ~root path))
            paths)
        roots

    let with_short_workspace_socket endpoint path f =
      match workspace_relative_socket endpoint path with
      | None -> f path
      | Some (root, rel) -> (
          let link =
            Filename.temp_file ~temp_dir:(temp_dir ()) "spice-dune-rpc-" ""
          in
          match
            Unix.unlink link;
            Unix.symlink root link
          with
          | () ->
              Fun.protect
                ~finally:(fun () ->
                  match Unix.unlink link with
                  | () -> ()
                  | exception Unix.Unix_error _ -> ())
                (fun () -> f (Filename.concat link rel))
          | exception Unix.Unix_error _ -> f path)

    let connect_unix ~sw net endpoint path f =
      if String.length path <= unix_socket_path_limit then
        let flow = Eio.Net.connect ~sw net (`Unix path) in
        f flow
      else
        with_short_workspace_socket endpoint path @@ fun path ->
        let flow = Eio.Net.connect ~sw net (`Unix path) in
        f flow

    let connect_flow ~sw ~net endpoint f =
      match Endpoint.address endpoint with
      | Endpoint.Unix path -> connect_unix ~sw net endpoint path f
      | Endpoint.Tcp { host; port } ->
          Eio.Net.with_tcp_connect ~host ~service:(string_of_int port) net f

    let with_connection ~sw ~net ?workspace endpoint ~f =
      let endpoint_text = Endpoint.to_string endpoint in
      try
        connect_flow ~sw ~net endpoint @@ fun flow ->
        let connection = Connection flow in
        let chan = Dune_rpc_chan.of_flow flow in
        Dune_rpc_client.connect chan init_request ~f:(fun client ->
            let t = make ~client ~connection ?workspace endpoint in
            f t)
      with
      | Drpc.Response.Error.E error -> response_error error
      | Drpc.Version_error.E error -> version_error error
      | exn ->
          Error
            (Error.Connection_failed
               { endpoint = endpoint_text; message = Printexc.to_string exn })

    let prepare_request client request =
      match Dune_rpc_client.Versioned.prepare_request client request with
      | Ok request -> Ok request
      | Error error -> version_error error

    let request ?id client request params =
      let* request = prepare_request client request in
      match Dune_rpc_client.request ?id client request params with
      | Ok value -> Ok value
      | Error error -> response_error error

    let build_dir t = request t.client Drpc.Public.Request.build_dir ()
    let pp_text pp = String.trim (Format.asprintf "%a@." Drpc.Pp.to_fmt pp)

    let severity diagnostic =
      match Drpc.Diagnostic.severity diagnostic with
      | Some Drpc.Diagnostic.Error -> Ocaml.Diagnostic.Severity.Error
      | Some Drpc.Diagnostic.Warning -> Ocaml.Diagnostic.Severity.Warning
      | None -> Ocaml.Diagnostic.Severity.Information

    let diagnostic_payload_error message =
      protocol_error ("invalid Dune RPC diagnostic payload: " ^ message)

    let construct_diagnostic f =
      try Ok (f ())
      with Invalid_argument message -> diagnostic_payload_error message

    let position (position : Lexing.position) =
      let column = max 0 (position.Lexing.pos_cnum - position.Lexing.pos_bol) in
      Ocaml.Position.make ~line:(max 1 position.Lexing.pos_lnum) ~column

    let location_of_dune t loc =
      let path = loc.Drpc.Loc.start.Lexing.pos_fname in
      match t.workspace with
      | None -> Ok None
      | Some workspace -> (
          match Workspace.resolve_string workspace path with
          | Ok path ->
              let start = position (Drpc.Loc.start loc) in
              let end_ = position (Drpc.Loc.stop loc) in
              construct_diagnostic (fun () ->
                  Some
                    (Ocaml.Location.make ~path
                       ~range:(Ocaml.Range.make ~start ~end_)))
          | Error _ -> Ok None)

    let related_of_dune t related =
      let* location =
        location_of_dune t (Drpc.Diagnostic.Related.loc related)
      in
      construct_diagnostic (fun () ->
          Ocaml.Diagnostic.Related.make ?location
            (pp_text (Drpc.Diagnostic.Related.message related)))

    let diagnostic_of_dune t diagnostic =
      let message = pp_text (Drpc.Diagnostic.message diagnostic) in
      let rec related_loop acc = function
        | [] -> Ok (List.rev acc)
        | related :: rest -> (
            match related_of_dune t related with
            | Ok related -> related_loop (related :: acc) rest
            | Error _ as error -> error)
      in
      let* related = related_loop [] (Drpc.Diagnostic.related diagnostic) in
      let* location =
        match Drpc.Diagnostic.loc diagnostic with
        | None -> Ok None
        | Some location -> location_of_dune t location
      in
      construct_diagnostic (fun () ->
          Ocaml.Diagnostic.make ?location ~related
            ~source:Ocaml.Diagnostic.Source.dune ~severity:(severity diagnostic)
            message)

    let diagnostic_id diagnostic =
      Drpc.Diagnostic.id diagnostic
      |> Drpc.Diagnostic.Id.hash |> string_of_int |> Diagnostic.Id.of_string

    let diagnostic_event_of_dune t = function
      | Drpc.Diagnostic.Event.Add dune_diagnostic ->
          let* diagnostic = diagnostic_of_dune t dune_diagnostic in
          Ok (Diagnostic.Add (diagnostic_id dune_diagnostic, diagnostic))
      | Drpc.Diagnostic.Event.Remove dune_diagnostic ->
          Ok (Diagnostic.Remove (diagnostic_id dune_diagnostic))

    let diagnostic_events_of_dune t events =
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | event :: events -> (
            match diagnostic_event_of_dune t event with
            | Ok event -> loop (event :: acc) events
            | Error _ as error -> error)
      in
      loop [] events

    let progress_of_dune = function
      | Drpc.Progress.Waiting -> Build.Waiting
      | Drpc.Progress.In_progress { complete; remaining; failed } ->
          Build.In_progress { complete; remaining; failed }
      | Drpc.Progress.Failed -> Build.Failed
      | Drpc.Progress.Interrupted -> Build.Interrupted
      | Drpc.Progress.Success -> Build.Success

    let request_diagnostics t =
      let* diagnostics = request t.client Drpc.Public.Request.diagnostics () in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | dune_diagnostic :: diagnostics -> (
            match diagnostic_of_dune t dune_diagnostic with
            | Ok diagnostic ->
                loop
                  (Diagnostic.Add (diagnostic_id dune_diagnostic, diagnostic)
                  :: acc)
                  diagnostics
            | Error _ as error -> error)
      in
      let* events = loop [] diagnostics in
      let store = Diagnostic.Store.apply_many events Diagnostic.Store.empty in
      t.diagnostics <- store;
      Log.debug (fun m ->
          m "fetched dune diagnostics count=%d" (List.length events));
      Ok store

    let apply t event =
      begin match event with
      | Build_progress progress -> t.build <- Build.update progress t.build
      | Diagnostics events ->
          t.diagnostics <- Diagnostic.Store.apply_many events t.diagnostics
      | Disconnected _ ->
          t.diagnostics <- Diagnostic.Store.clear t.diagnostics;
          t.stopped <- true
      end

    let rec poll_stream stream ~map_event ~on_event =
      match Dune_rpc_client.Stream.next stream with
      | None -> ()
      | Some value ->
          let events = map_event value in
          List.iter on_event events;
          poll_stream stream ~map_event ~on_event

    let poll_subscription client sub =
      match Dune_rpc_client.poll client sub with
      | Ok stream -> Ok stream
      | Error error -> version_error error

    let run t ~on_event =
      let handle event =
        apply t event;
        on_event event
      in
      let* progress = poll_subscription t.client Drpc.Public.Sub.progress in
      let* diagnostics =
        poll_subscription t.client Drpc.Public.Sub.diagnostic
      in
      let run_progress () =
        poll_stream progress
          ~map_event:(fun progress ->
            [ Build_progress (progress_of_dune progress) ])
          ~on_event:handle
      in
      let run_diagnostics () =
        poll_stream diagnostics
          ~map_event:(fun events ->
            match diagnostic_events_of_dune t events with
            | Ok events -> [ Diagnostics events ]
            | Error error -> raise (Payload_error error))
          ~on_event:handle
      in
      try
        Eio.Fiber.both run_progress run_diagnostics;
        handle (Disconnected None);
        Ok ()
      with
      | Payload_error error -> Error error
      | exn -> protocol_error (Printexc.to_string exn)

    let stop t =
      if not t.stopped then (
        t.stopped <- true;
        let (Connection flow) = t.connection in
        Eio.Flow.close flow)
  end

  module Instance = struct
    type fs = Fs : _ Eio.Path.t -> fs
    type net = Net : _ Eio.Net.t -> net

    module Start = struct
      type t = {
        run : unit -> (unit, Error.t) result;
        status : unit -> string option;
        stop : unit -> unit;
      }

      let make ?status ?stop run =
        {
          run;
          status = Option.value status ~default:(fun () -> None);
          stop = Option.value stop ~default:ignore;
        }

      let run t = t.run ()
      let status t = t.status ()
      let stop t = t.stop ()

      let process_status status =
        Format.asprintf "dune build --root <cwd> --watch @all exited with %a"
          Eio.Process.pp_status status

      let dune_build_watch ~sw ~process_mgr ~cwd () =
        let latest_status = ref None in
        let process_ref = ref None in
        let stop () =
          match !process_ref with
          | None -> ()
          | Some process -> (
              match Eio.Process.signal process Sys.sigkill with
              | () -> (
                  match Unix.kill (Eio.Process.pid process) Sys.sigkill with
                  | () -> ()
                  | exception Unix.Unix_error _ -> ())
              | exception _ -> ())
        in
        let run () =
          let root = Eio.Path.native_exn cwd in
          let command =
            [
              "/bin/sh";
              "-c";
              "exec dune build --root \"$1\" --watch @all >/dev/null 2>&1";
              "sh";
              root;
            ]
          in
          try
            let process =
              Eio.Process.spawn ~sw process_mgr ~cwd
                ~stdin:(Eio.Flow.string_source "")
                command
            in
            process_ref := Some process;
            Eio.Switch.on_release sw stop;
            Eio.Fiber.fork_daemon ~sw (fun () ->
                Fun.protect ~finally:stop (fun () ->
                    let status = Eio.Process.await process in
                    latest_status := Some (process_status status);
                    Log.info (fun m ->
                        m "dune build --watch exited status=%a"
                          Eio.Process.pp_status status));
                `Stop_daemon);
            Ok ()
          with exn ->
            let message = Printexc.to_string exn in
            latest_status :=
              Some
                ("failed to start dune build --root <cwd> --watch @all:\n"
               ^ message);
            Error
              (Error.Connection_failed
                 { endpoint = "dune build --root <cwd> --watch @all"; message })
        in
        make ~status:(fun () -> !latest_status) ~stop run
    end

    type start = Start.t
    type status = Found of Endpoint.t | Not_found | Lookup_failed of Error.t

    type t = {
      fs : fs;
      net : net;
      workspace : Workspace.t;
      registry : Registry.t;
      start : start option;
      sleep : (float -> unit) option;
      startup_timeout : float;
      mutex : Eio.Mutex.t;
      mutable endpoint : Endpoint.t option;
      mutable diagnostics : Diagnostic.Store.t;
      mutable start_attempted : bool;
    }

    let create ~fs ~net ~workspace ?(env = Sys.getenv_opt) ?start ?sleep
        ?(startup_timeout = 3.0) () =
      if Float.compare startup_timeout 0.0 < 0 then
        invalid_arg "Dune RPC startup_timeout must be non-negative";
      {
        fs = Fs fs;
        net = Net net;
        workspace;
        registry = Registry.create ~env ();
        start;
        sleep;
        startup_timeout;
        mutex = Eio.Mutex.create ();
        endpoint = None;
        diagnostics = Diagnostic.Store.empty;
        start_attempted = false;
      }

    let with_lock t f = Eio.Mutex.use_rw ~protect:true t.mutex f
    let workspace t = t.workspace
    let endpoint t = with_lock t (fun () -> t.endpoint)
    let diagnostics t = with_lock t (fun () -> t.diagnostics)
    let stop t = Option.iter Start.stop t.start

    let workspace_root_strings workspace =
      List.map
        (fun root -> Spice_path.Abs.to_string (Workspace.Root.dir root))
        (Workspace.roots workspace)

    let normalize_abs path =
      match Spice_path.Abs.of_string path with
      | Ok abs ->
          let path = Spice_path.Abs.to_string abs in
          Some
            (match Unix.realpath path with
            | path -> path
            | exception Unix.Unix_error _ -> path)
      | Error _ -> None

    let same_root a b =
      String.equal a b
      ||
      match (normalize_abs a, normalize_abs b) with
      | Some a, Some b -> String.equal a b
      | Some _, None | None, Some _ | None, None -> false

    let process_alive pid =
      if pid <= 0 then false
      else
        match Unix.kill pid 0 with
        | () -> true
        | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
        | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
        | exception Unix.Unix_error _ -> false

    let choose_registry_entry ~workspace entries =
      let roots = workspace_root_strings workspace in
      List.find_opt
        (fun entry ->
          process_alive (Registry.pid entry)
          && List.exists (same_root (Registry.root entry)) roots)
        entries

    let refresh_unlocked t =
      let (Fs fs) = t.fs in
      let previous = t.endpoint in
      let note_lost () =
        if Option.is_some previous then
          Log.info (fun m -> m "dune rpc endpoint lost")
      in
      let* entries = Registry.poll ~fs t.registry in
      match choose_registry_entry ~workspace:t.workspace entries with
      | None ->
          note_lost ();
          t.endpoint <- None;
          Ok None
      | Some entry ->
          let endpoint = Registry.endpoint entry in
          (match previous with
          | Some prev
            when String.equal (Endpoint.to_string prev)
                   (Endpoint.to_string endpoint) ->
              ()
          | _ ->
              Log.info (fun m ->
                  m "dune rpc endpoint found endpoint=%a" Endpoint.pp endpoint));
          t.endpoint <- Some endpoint;
          Ok (Some endpoint)

    let refresh t =
      Eio.Mutex.use_rw ~protect:true t.mutex (fun () -> refresh_unlocked t)

    let refresh_status t =
      match refresh t with
      | Ok (Some endpoint) -> Found endpoint
      | Ok None -> Not_found
      | Error error -> Lookup_failed error

    let maybe_start t =
      match t.start with
      | None -> Ok false
      | Some start ->
          let should_start =
            with_lock t (fun () ->
                if t.start_attempted then false
                else (
                  t.start_attempted <- true;
                  true))
          in
          if not should_start then Ok false
          else begin
            Log.info (fun m -> m "starting dune build --watch");
            Start.run start |> Result.map (fun () -> true)
          end

    let wait_for_endpoint t =
      let interval = 0.1 in
      let attempts =
        match t.sleep with
        | None -> 0
        | Some _ -> int_of_float (ceil (t.startup_timeout /. interval)) |> max 0
      in
      let rec loop remaining =
        match refresh t with
        | Ok None when remaining > 0 -> (
            match t.sleep with
            | None -> Ok None
            | Some sleep ->
                sleep interval;
                loop (remaining - 1))
        | result -> result
      in
      loop attempts

    let missing_endpoint_error t =
      let message =
        match t.start with
        | None ->
            "no running Dune RPC instance was found; start one with dune build \
             --watch or another Dune command that enables RPC"
        | Some _ ->
            let base =
              "no Dune RPC instance became available for this workspace; Spice \
               tried to start dune build --root <cwd> --watch @all"
            in
            begin match Option.bind t.start Start.status with
            | None -> base
            | Some status -> base ^ "\n\n" ^ status
            end
      in
      Error
        (Error.Connection_failed { endpoint = "dune rpc registry"; message })

    let missing_visible_endpoint_error () =
      Error
        (Error.Connection_failed
           {
             endpoint = "dune rpc registry";
             message =
               "no running Dune RPC instance was found for this workspace";
           })

    let select_endpoint t =
      match refresh t with
      | Error _ as error -> error
      | Ok (Some endpoint) -> Ok endpoint
      | Ok None -> (
          let* _started = maybe_start t in
          match wait_for_endpoint t with
          | Error _ as error -> error
          | Ok (Some endpoint) -> Ok endpoint
          | Ok None -> missing_endpoint_error t)

    let connection_attempts t =
      let interval = 0.1 in
      let attempts =
        match t.sleep with
        | None -> 0
        | Some _ -> int_of_float (ceil (t.startup_timeout /. interval)) |> max 0
      in
      (attempts, interval)

    let with_connection t ~sw ~f =
      let attempts, interval = connection_attempts t in
      let (Net net) = t.net in
      let rec loop remaining =
        match select_endpoint t with
        | Error _ as error -> error
        | Ok endpoint -> (
            match
              Connection.with_connection ~sw ~net ~workspace:t.workspace
                endpoint ~f
            with
            | Ok _ as ok -> ok
            | Error _ as error when remaining <= 0 -> error
            | Error error ->
                Log.warn (fun m ->
                    m
                      "dune rpc connection failed, retrying attempts_left=%d: \
                       %s"
                      (remaining - 1) (Error.message error));
                with_lock t (fun () -> t.endpoint <- None);
                begin match t.sleep with
                | None -> ()
                | Some sleep -> sleep interval
                end;
                loop (remaining - 1))
      in
      loop attempts

    let disconnect_unlocked t =
      t.endpoint <- None;
      t.diagnostics <- Diagnostic.Store.clear t.diagnostics

    let apply_unlocked t event =
      match event with
      | Build_progress _ -> ()
      | Diagnostics events ->
          t.diagnostics <- Diagnostic.Store.apply_many events t.diagnostics
      | Disconnected _ -> disconnect_unlocked t

    let apply t event = with_lock t (fun () -> apply_unlocked t event)

    let request_diagnostics t =
      Eio.Switch.run @@ fun sw ->
      with_connection t ~sw ~f:(fun connection ->
          let* store = Connection.request_diagnostics connection in
          let endpoint = Connection.endpoint connection in
          with_lock t (fun () ->
              t.endpoint <- Some endpoint;
              t.diagnostics <- store);
          Ok (endpoint, store))

    let request_visible_diagnostics t =
      Eio.Switch.run @@ fun sw ->
      match refresh t with
      | Error _ as error -> error
      | Ok None -> missing_visible_endpoint_error ()
      | Ok (Some endpoint) ->
          let (Net net) = t.net in
          Connection.with_connection ~sw ~net ~workspace:t.workspace endpoint
            ~f:(fun connection ->
              let* store = Connection.request_diagnostics connection in
              with_lock t (fun () ->
                  t.endpoint <- Some endpoint;
                  t.diagnostics <- store);
              Ok (endpoint, store))

    module Health = struct
      type t = Disconnected | Clean | Failing of int | Unknown

      let equal (a : t) (b : t) =
        match (a, b) with
        | Disconnected, Disconnected | Clean, Clean | Unknown, Unknown -> true
        | Failing a, Failing b -> Int.equal a b
        | (Disconnected | Clean | Failing _ | Unknown), _ -> false

      let pp ppf : t -> unit = function
        | Disconnected -> Format.pp_print_string ppf "disconnected"
        | Clean -> Format.pp_print_string ppf "clean"
        | Failing n -> Format.fprintf ppf "failing %d" n
        | Unknown -> Format.pp_print_string ppf "unknown"
    end

    (* A registry-first, no-spawn health probe: [refresh] never runs the lazy
       starter, and the current-diagnostics request is bounded so a slow Dune
       build cannot stall a frontend at launch. A found endpoint whose request
       times out or fails is still connected — {!Health.Unknown}, not
       {!Health.Disconnected}. *)
    let build_health t ~clock ?(timeout_s = 0.5) () =
      match refresh t with
      | Error _ | Ok None -> Health.Disconnected
      | Ok (Some endpoint) -> (
          let (Net net) = t.net in
          let query () =
            Eio.Switch.run @@ fun sw ->
            Connection.with_connection ~sw ~net ~workspace:t.workspace endpoint
              ~f:(fun connection -> Connection.request_diagnostics connection)
          in
          match Eio.Time.with_timeout_exn clock timeout_s query with
          | exception Eio.Time.Timeout -> Health.Unknown
          | Error _ -> Health.Unknown
          | Ok store ->
              with_lock t (fun () ->
                  t.endpoint <- Some endpoint;
                  t.diagnostics <- store);
              let count = List.length (Diagnostic.Store.to_list store) in
              if count = 0 then Health.Clean else Health.Failing count)

    let run t ~on_event =
      let disconnect message =
        let event = Disconnected message in
        apply t event;
        on_event event
      in
      Eio.Switch.run @@ fun sw ->
      match
        with_connection t ~sw ~f:(fun connection ->
            Connection.run connection ~on_event:(fun event ->
                apply t event;
                on_event event))
      with
      | Ok () -> Ok ()
      | Error error ->
          disconnect (Some (Error.message error));
          Error error
  end
end

module Project_source = struct
  type watch = Watch_endpoint of string | No_watch

  module Freshness = struct
    type t =
      | Fresh
      | Snapshot of {
          captured_at : float;
          drifted : bool;
          endpoint : string option;
        }
  end

  type blocked =
    | Blocked_by_watch of { endpoint : string option }
    | Describe_error of Error.t

  type snapshot = { project : Ocaml.Project.t; captured_at : float }

  type t = {
    refresh_status : unit -> watch;
    describe : cancelled:(unit -> bool) -> (Ocaml.Project.t, Error.t) result;
    now : unit -> float;
    mutex : Mutex.t;
    mutable snapshot : snapshot option;
    mutable drifted : bool;
  }

  let create ~refresh_status ~describe ?(now = Unix.gettimeofday) () =
    {
      refresh_status;
      describe;
      now;
      mutex = Mutex.create ();
      snapshot = None;
      drifted = false;
    }

  (* The critical sections only read or write the in-memory snapshot/drift
     fields and never suspend, so a stdlib mutex is sufficient — it keeps the
     module usable both inside Eio fibers and from a plain fswatch callback, and
     needs no Eio scheduler context. The describe subprocess in {!get} runs
     outside the lock. *)
  let with_lock t f =
    Mutex.lock t.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

  let store_snapshot t project =
    with_lock t (fun () ->
        t.snapshot <- Some { project; captured_at = t.now () };
        t.drifted <- false)

  let capture t =
    match t.describe ~cancelled:(fun () -> false) with
    | Ok project ->
        store_snapshot t project;
        Ok ()
    | Error _ as error -> error

  let set_drifted t drifted = with_lock t (fun () -> t.drifted <- drifted)

  (* Dune's build lock is advisory and non-blocking: a one-shot [dune describe]
     under a held lock fails fast with this stable [User_error] fragment. It is
     the authoritative discriminator for both an RPC watch and a bare non-RPC
     [dune build] (which the registry cannot see). *)
  let lock_error_marker = "has locked the build directory"

  let is_lock_error = function
    | Error.Command_failed { stderr; _ } ->
        string_contains ~needle:lock_error_marker stderr
    | Error.Parse_error _ | Error.Path_error _ | Error.Duplicate_library_uid _
    | Error.Unknown_library_uid _ | Error.Invalid_state _
    | Error.Connection_failed _ | Error.Protocol_error _ ->
        false

  let serve_snapshot t ~endpoint =
    match with_lock t (fun () -> (t.snapshot, t.drifted)) with
    | Some { project; captured_at }, drifted ->
        Ok (project, Freshness.Snapshot { captured_at; drifted; endpoint })
    | None, _ -> Error (Blocked_by_watch { endpoint })

  let get t ?(cancelled = fun () -> false) () =
    match t.refresh_status () with
    | Watch_endpoint endpoint -> serve_snapshot t ~endpoint:(Some endpoint)
    | No_watch -> (
        match t.describe ~cancelled with
        | Ok project ->
            store_snapshot t project;
            Ok (project, Freshness.Fresh)
        | Error error when is_lock_error error ->
            serve_snapshot t ~endpoint:None
        | Error error -> Error (Describe_error error))
end
