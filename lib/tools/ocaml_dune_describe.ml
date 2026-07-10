(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Dune = Spice_ocaml_dune
module Ocaml = Spice_ocaml

let name = "ocaml_dune_describe"
let description = Spice_prompts.Tools.ocaml_dune_describe

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()

let json_string_option = function
  | None -> json_null
  | Some value -> Json.string value

let access_cwd workspace =
  Permission.Access.Path_scope.workspace (Workspace.root_path workspace)

let read_root_request workspace =
  Permission.Request.of_accesses ~source:name
    [ Permission.Access.path ~op:`Read (Workspace.root_path workspace) ]

let exec_request ~argv workspace =
  match argv with
  | [] -> invalid_arg "argv must not be empty"
  | program :: args ->
      Permission.Request.of_accesses ~source:name
        [ Permission.Access.argv ~cwd:(access_cwd workspace) ~program args ]

let permissions workspace =
  [
    read_root_request workspace;
    exec_request ~argv:(Dune.Describe.workspace_args ()) workspace;
    exec_request ~argv:(Dune.Describe.tests_args ()) workspace;
  ]

let path_json path = Json.string (Workspace.Path.display path)

let location_json location =
  let position_json position =
    json_obj
      [
        ("line", Json.int (Ocaml.Position.line position));
        ("column", Json.int (Ocaml.Position.column position));
      ]
  in
  json_obj
    [
      ("path", path_json (Ocaml.Location.path location));
      ( "range",
        json_obj
          [
            ("start", position_json (Ocaml.Location.start location));
            ("end", position_json (Ocaml.Location.end_ location));
          ] );
    ]

let deps_json item_json deps =
  match deps with
  | Ocaml.Project.Deps.Unknown -> json_obj [ ("known", Json.bool false) ]
  | Ocaml.Project.Deps.Known items ->
      json_obj
        [
          ("known", Json.bool true);
          ("items", Json.list (List.map item_json items));
        ]

let module_name_json name = Json.string (Ocaml.Module_name.to_string name)

let compilation_unit_json unit =
  json_obj
    [
      ("name", module_name_json (Ocaml.Project.Compilation_unit.name unit));
      ( "impl",
        match Ocaml.Project.Compilation_unit.impl unit with
        | None -> json_null
        | Some path -> path_json path );
      ( "intf",
        match Ocaml.Project.Compilation_unit.intf unit with
        | None -> json_null
        | Some path -> path_json path );
      ( "interface_deps",
        deps_json module_name_json
          (Ocaml.Project.Compilation_unit.interface_deps unit) );
      ( "implementation_deps",
        deps_json module_name_json
          (Ocaml.Project.Compilation_unit.implementation_deps unit) );
    ]

let component_kind_text = function
  | Ocaml.Project.Component.Kind.Local_library -> "local library"
  | Ocaml.Project.Component.Kind.External_library -> "external library"
  | Ocaml.Project.Component.Kind.Executable -> "executable"

let component_id_json id = Json.string (Ocaml.Project.Component.Id.to_string id)

let component_json component =
  json_obj
    [
      ("id", component_id_json (Ocaml.Project.Component.id component));
      ("name", Json.string (Ocaml.Project.Component.name component));
      ( "kind",
        Json.string
          (component_kind_text (Ocaml.Project.Component.kind component)) );
      ( "source_dir",
        match Ocaml.Project.Component.source_dir component with
        | None -> json_null
        | Some path -> path_json path );
      ( "location",
        match Ocaml.Project.Component.location component with
        | None -> json_null
        | Some location -> location_json location );
      ( "units",
        Json.list
          (List.map compilation_unit_json
             (Ocaml.Project.Component.units component)) );
      ( "requires",
        deps_json component_id_json (Ocaml.Project.Component.requires component)
      );
    ]

let test_json test =
  json_obj
    [
      ("name", Json.string (Ocaml.Project.Test.name test));
      ("source_dir", path_json (Ocaml.Project.Test.source_dir test));
      ("target", Json.string (Ocaml.Project.Test.target test));
      ("enabled", Json.bool (Ocaml.Project.Test.enabled test));
      ("package", json_string_option (Ocaml.Project.Test.package test));
      ( "component",
        match Ocaml.Project.Test.component test with
        | None -> json_null
        | Some id -> component_id_json id );
      ( "location",
        match Ocaml.Project.Test.location test with
        | None -> json_null
        | Some location -> location_json location );
    ]

let freshness_json (freshness : Dune.Project_source.Freshness.t) =
  match freshness with
  | Dune.Project_source.Freshness.Fresh ->
      json_obj [ ("served_from", Json.string "fresh") ]
  | Dune.Project_source.Freshness.Snapshot { captured_at; drifted; endpoint } ->
      json_obj
        ([
           ("served_from", Json.string "snapshot");
           ("captured_at", Json.number captured_at);
           ("drifted", Json.bool drifted);
         ]
        @
        match endpoint with
        | None -> []
        | Some endpoint -> [ ("endpoint", Json.string endpoint) ])

let freshness_line (freshness : Dune.Project_source.Freshness.t) =
  match freshness with
  | Dune.Project_source.Freshness.Fresh -> "freshness: fresh"
  | Dune.Project_source.Freshness.Snapshot { captured_at; drifted; endpoint } ->
      Printf.sprintf "freshness: snapshot captured_at=%.0f drifted=%b%s"
        captured_at drifted
        (match endpoint with
        | None -> ""
        | Some endpoint -> " endpoint=" ^ endpoint)

let project_json ?freshness project =
  json_obj
    ([
       ( "root",
         match Ocaml.Project.root project with
         | None -> json_null
         | Some root -> path_json root );
       ( "build_context",
         json_string_option (Ocaml.Project.build_context project) );
       ( "components",
         Json.list (List.map component_json (Ocaml.Project.components project))
       );
       ("tests", Json.list (List.map test_json (Ocaml.Project.tests project)));
     ]
    @
    match freshness with
    | None -> []
    | Some freshness -> [ ("freshness", freshness_json freshness) ])

let component_line component =
  let id = Ocaml.Project.Component.id component in
  Printf.sprintf "- %s %s (id=%s)"
    (component_kind_text (Ocaml.Project.Component.kind component))
    (Ocaml.Project.Component.name component)
    (Ocaml.Project.Component.Id.to_string id)

let test_line test =
  let status =
    if Ocaml.Project.Test.enabled test then "enabled" else "disabled"
  in
  Printf.sprintf "- %s: %s in %s (%s)"
    (Ocaml.Project.Test.name test)
    (Ocaml.Project.Test.target test)
    (Workspace.Path.display (Ocaml.Project.Test.source_dir test))
    status

let project_text ?freshness project =
  let components = Ocaml.Project.components project in
  let local_components = Ocaml.Project.local_components project in
  let external_components = Ocaml.Project.external_components project in
  let tests = Ocaml.Project.tests project in
  let b = Buffer.create 512 in
  Buffer.add_string b "OCaml Dune project\n";
  Buffer.add_string b
    (Printf.sprintf "root: %s\n"
       (match Ocaml.Project.root project with
       | None -> "<unknown>"
       | Some root -> Workspace.Path.display root));
  Buffer.add_string b
    (Printf.sprintf "build_context: %s\n"
       (Option.value ~default:"<unknown>" (Ocaml.Project.build_context project)));
  Buffer.add_string b
    (Printf.sprintf "components: %d local=%d external=%d\n"
       (List.length components)
       (List.length local_components)
       (List.length external_components));
  Buffer.add_string b (Printf.sprintf "tests: %d\n" (List.length tests));
  begin match freshness with
  | None -> ()
  | Some freshness -> Buffer.add_string b (freshness_line freshness ^ "\n")
  end;
  begin match List.take 20 local_components with
  | [] -> ()
  | shown ->
      Buffer.add_string b "\nlocal components:\n";
      List.iter
        (fun component ->
          Buffer.add_string b (component_line component);
          Buffer.add_char b '\n')
        shown;
      if List.compare_length_with local_components (List.length shown) > 0 then
        Buffer.add_string b
          (Printf.sprintf "- ... %d more local component(s)\n"
             (List.length local_components - List.length shown))
  end;
  begin match List.take 20 tests with
  | [] -> ()
  | shown ->
      Buffer.add_string b "\ntests:\n";
      List.iter
        (fun test ->
          Buffer.add_string b (test_line test);
          Buffer.add_char b '\n')
        shown;
      if List.compare_length_with tests (List.length shown) > 0 then
        Buffer.add_string b
          (Printf.sprintf "- ... %d more test(s)\n"
             (List.length tests - List.length shown))
  end;
  String.trim (Buffer.contents b)

module Output = struct
  type t = {
    project : Ocaml.Project.t;
    freshness : Dune.Project_source.Freshness.t option;
  }

  let make ?freshness project = { project; freshness }
  let project t = t.project
  let freshness t = t.freshness
  let component_count t = List.length (Ocaml.Project.components t.project)
  let test_count t = List.length (Ocaml.Project.tests t.project)
  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make
      ~text:(project_text ?freshness:t.freshness t.project)
      ~json:(project_json ?freshness:t.freshness t.project)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let blocked_message endpoint =
  match endpoint with
  | Some endpoint ->
      Printf.sprintf
        "dune describe is blocked by a running Dune watch (endpoint: %s) and \
         no boot snapshot is available; run `dune describe` yourself or stop \
         the watch"
        endpoint
  | None ->
      "dune describe is blocked by a running Dune build holding the build lock \
       and no boot snapshot is available; run `dune describe` yourself or stop \
       the build"

let prepare sandbox ~argv ~env =
  Process.prepare ~sandbox ~env argv
  |> Result.map_error Spice_sandbox.Error.message

let run ~sandbox ~process_mgr ~clock ~cwd ~workspace ?project_source ctx () =
  if Tool.Context.cancelled ctx then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    let cancelled () = Tool.Context.cancelled ctx in
    match project_source with
    | None -> (
        match
          Dune.Describe.describe_project ~prepare:(prepare sandbox) ~process_mgr
            ~clock ~cwd ~workspace ~cancelled ()
        with
        | Ok project -> Tool.Result.completed ~output:(Output.make project) ()
        | Error error -> Tool.Result.failed `Failed (Dune.Error.message error))
    | Some source -> (
        match Dune.Project_source.get source ~cancelled () with
        | Ok (project, freshness) ->
            Tool.Result.completed ~output:(Output.make ~freshness project) ()
        | Error (Dune.Project_source.Blocked_by_watch { endpoint }) ->
            Tool.Result.failed `Unavailable (blocked_message endpoint)
        | Error (Dune.Project_source.Describe_error error) ->
            Tool.Result.failed `Failed (Dune.Error.message error))

let tool ~sandbox ~process_mgr ~clock ~cwd ~workspace ?project_source () =
  Tool.make ~name ~description ~input:Tool.Input.empty ~output:Output.encode
    ~permissions:(fun () -> permissions workspace)
    ~run:(run ~sandbox ~process_mgr ~clock ~cwd ~workspace ?project_source)
    ()
