(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Ocaml = Spice_ocaml

let name = "ocaml_find_definitions"
let description = Spice_prompts.Tools.ocaml_find_definitions
let default_program = Ocaml_merlin.default_program
let max_source_bytes = 8 * 1024 * 1024

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let optional_json_field name value fields =
  match value with None -> fields | Some value -> (name, value) :: fields

module Input = struct
  module Kind = struct
    type t = Definition | Declaration | Type_definition

    let to_string = function
      | Definition -> "definition"
      | Declaration -> "declaration"
      | Type_definition -> "type-definition"

    let of_string = function
      | "definition" -> Definition
      | "declaration" -> Declaration
      | "type-definition" -> Type_definition
      | kind -> invalid_arg ("unknown kind: " ^ kind)

    let rank = function
      | Definition -> 0
      | Declaration -> 1
      | Type_definition -> 2

    let compare a b = Int.compare (rank a) (rank b)
    let equal a b = compare a b = 0
  end

  type t = {
    path : string;
    line : int;
    column : int;
    identifier : string option;
    kind : Kind.t;
  }

  let validate_identifier kind = function
    | None -> ()
    | Some "" -> invalid_arg "identifier must not be empty"
    | Some _ when Kind.equal kind Kind.Type_definition ->
        invalid_arg "identifier cannot be used with type-definition lookups"
    | Some _ -> ()

  let make ?identifier ?(kind = Kind.Definition) ~path ~line ~column () =
    if String.is_empty path then invalid_arg "path must not be empty";
    if line < 1 then invalid_arg "line must be at least 1";
    if column < 0 then invalid_arg "column must be non-negative";
    validate_identifier kind identifier;
    { path; line; column; identifier; kind }

  let make_json path line column identifier kind =
    decode_invalid_arg (fun () ->
        let kind =
          Option.value ~default:Kind.Definition (Option.map Kind.of_string kind)
        in
        make ?identifier ~kind ~path ~line ~column ())

  let path t = t.path
  let line t = t.line
  let column t = t.column
  let identifier t = t.identifier
  let kind t = t.kind

  let to_json t =
    [
      ("path", Json.string (path t));
      ("line", Json.int (line t));
      ("column", Json.int (column t));
      ("kind", Json.string (Kind.to_string (kind t)));
    ]
    |> optional_json_field "identifier"
         (Option.map (fun value -> Json.string value) (identifier t))
    |> List.rev |> json_obj

  let codec =
    Jsont.Object.map ~kind:"ocaml_find_definitions input" make_json
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.mem "line" Jsont.int ~enc:line
    |> Jsont.Object.mem "column" Jsont.int ~enc:column
    |> Jsont.Object.opt_mem "identifier" Jsont.string ~enc:identifier
    |> Jsont.Object.opt_mem "kind" Jsont.string ~enc:(fun t ->
        Some (Kind.to_string (kind t)))
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "path",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Workspace-relative or workspace-contained absolute \
                         OCaml source file path." );
                  ] );
              ( "line",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string "1-based source line of the lookup cursor." );
                  ] );
              ( "column",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ( "description",
                      Json.string
                        "0-based byte column in the source line, matching \
                         OCaml/Merlin locations." );
                  ] );
              ( "identifier",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Optional Merlin locate prefix. Omit this to locate \
                         the identifier under the cursor." );
                  ] );
              ( "kind",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "definition";
                          Json.string "declaration";
                          Json.string "type-definition";
                        ] );
                    ( "description",
                      Json.string
                        "Lookup kind. Defaults to definition. type-definition \
                         cannot be used with identifier." );
                  ] );
            ] );
        ( "required",
          Json.list
            [ Json.string "path"; Json.string "line"; Json.string "column" ] );
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Definition = struct
  module Target = struct
    type t =
      | Workspace of Ocaml.Location.t
      | External of { path : string; position : Ocaml.Position.t }

    let compare a b =
      match (a, b) with
      | Workspace a, Workspace b -> Ocaml.Location.compare a b
      | Workspace _, External _ -> -1
      | External _, Workspace _ -> 1
      | External a, External b -> (
          match String.compare a.path b.path with
          | 0 -> Ocaml.Position.compare a.position b.position
          | n -> n)

    let equal a b = compare a b = 0
  end

  type t = { target : Target.t }

  let make ~target () = { target }
  let target t = t.target
  let compare a b = Target.compare a.target b.target
  let equal a b = compare a b = 0
end

module Output = struct
  (* Merlin [locate] consults the project index to resolve cross-file targets,
     so a result may come from a stale index. [Not_applicable] is reserved for
     lookups that never touch the index (the cursor is already at the
     definition); every resolved target is [Unknown]. Mirrors the trust signal
     of {!Ocaml_find_references}. *)
  type index_status = Not_applicable | Unknown

  type t = {
    input : Input.t;
    definitions : Definition.t list;
    index_status : index_status;
  }

  let make ~input ~definitions ~index_status =
    { input; definitions; index_status }

  let input t = t.input
  let definitions t = t.definitions
  let definition_count t = List.length t.definitions
  let index_status t = t.index_status
  let type_id : t Type.Id.t = Type.Id.make ()

  let index_status_to_string = function
    | Not_applicable -> "not_applicable"
    | Unknown -> "unknown"

  let position_json position =
    json_obj
      [
        ("line", Json.int (Ocaml.Position.line position));
        ("column", Json.int (Ocaml.Position.column position));
      ]

  let range_json range =
    json_obj
      [
        ("start", position_json (Ocaml.Range.start range));
        ("end", position_json (Ocaml.Range.end_ range));
      ]

  let location_json location =
    json_obj
      [
        ( "path",
          Json.string (Workspace.Path.display (Ocaml.Location.path location)) );
        ("range", range_json (Ocaml.Location.range location));
      ]

  let target_json = function
    | Definition.Target.Workspace location ->
        json_obj
          [
            ("kind", Json.string "workspace");
            ("location", location_json location);
          ]
    | Definition.Target.External { path; position } ->
        json_obj
          [
            ("kind", Json.string "external");
            ("path", Json.string path);
            ("position", position_json position);
          ]

  let definition_json definition =
    json_obj [ ("target", target_json (Definition.target definition)) ]

  let json t =
    json_obj
      [
        ("input", Input.to_json t.input);
        ("index_status", Json.string (index_status_to_string t.index_status));
        ("definitions", Json.list (List.map definition_json t.definitions));
      ]

  let target_text = function
    | Definition.Target.Workspace location ->
        Format.asprintf "%a" Ocaml.Location.pp location
    | Definition.Target.External { path; position } ->
        Printf.sprintf "%s:%d:%d" path
          (Ocaml.Position.line position)
          (Ocaml.Position.column position)

  let text t =
    let b = Buffer.create 128 in
    (match t.definitions with
    | [] -> Buffer.add_string b "OCaml definitions: none\n"
    | definitions ->
        Buffer.add_string b
          (Printf.sprintf "OCaml definitions: %d\n" (List.length definitions));
        List.iter
          (fun definition ->
            Buffer.add_string b "- ";
            Buffer.add_string b (target_text (Definition.target definition));
            Buffer.add_char b '\n')
          definitions);
    Buffer.add_string b
      ("index_status: " ^ index_status_to_string t.index_status);
    Buffer.contents b

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

type merlin_found = { file : string option; position : Ocaml.Position.t }

type merlin_response =
  | Found of merlin_found
  | Not_found of string
  | Invalid_context of string
  | At_origin of string
  | Malformed of string

let json_field name json =
  match json with
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let decode_json codec json =
  match Json.decode codec json with Ok value -> Some value | Error _ -> None

let string_field name json =
  Option.bind (json_field name json) (decode_json Jsont.string)

let position_of_json json = Result.to_option (Ocaml_position.of_json json)

let merlin_response_of_value = function
  | Jsont.String (message, _) ->
      if String.equal message "Not a valid identifier" then
        Invalid_context message
      else if String.equal message "Already at definition point" then
        At_origin message
      else if String.starts_with ~prefix:"didn't manage to find " message then
        Not_found message
      else if String.ends_with ~suffix:" but could not be found" message then
        Not_found message
      else if String.starts_with ~prefix:"Not in environment" message then
        Not_found message
      else if String.contains message '\n' then Malformed message
      else Not_found message
  | Jsont.Object _ as json -> (
      match (json_field "pos" json, string_field "file" json) with
      | Some pos, file -> (
          match position_of_json pos with
          | Some position -> Found { file; position }
          | None -> Malformed "Merlin position is malformed")
      | None, _ -> Malformed "Merlin result object has no pos field")
  | _ -> Malformed "Merlin result is neither a string nor an object"

let absolute_path ~cwd path =
  match Spice_path.Abs.of_string cwd with
  | Error _ -> path
  | Ok base -> (
      match Spice_path.Abs.resolve_any ~base path with
      | Ok abs -> Spice_path.Abs.to_string abs
      | Error _ -> path)

let workspace_path_of_absolute workspace path =
  match Spice_path.Abs.of_string path with
  | Error _ -> None
  | Ok abs -> (
      match Workspace.import_abs workspace abs with
      | Ok path -> Some path
      | Error _ -> None)

let definition_of_merlin_found ~workspace ~cwd ~source_path found =
  let path = Option.value found.file ~default:source_path in
  let path = absolute_path ~cwd path in
  let target =
    match workspace_path_of_absolute workspace path with
    | Some path ->
        let range = Ocaml.Range.point found.position in
        Definition.Target.Workspace (Ocaml.Location.make ~path ~range)
    | None -> Definition.Target.External { path; position = found.position }
  in
  Definition.make ~target ()

(* Merlin [single] command and its arguments; the [single] selector and program
   prefix are threaded by {!Ocaml_merlin}. *)
let merlin_command_args ~path input =
  let position =
    Printf.sprintf "%d:%d" (Input.line input) (Input.column input)
  in
  match Input.kind input with
  | Input.Kind.Type_definition ->
      ("locate-type", [ "-position"; position; "-filename"; path ])
  | Input.Kind.Definition | Input.Kind.Declaration ->
      let look_for =
        match Input.kind input with
        | Input.Kind.Definition -> "implementation"
        | Input.Kind.Declaration -> "interface"
        | Input.Kind.Type_definition -> assert false
      in
      let args =
        [ "-position"; position; "-look-for"; look_for; "-filename"; path ]
      in
      let args =
        match Input.identifier input with
        | None -> args
        | Some identifier -> args @ [ "-prefix"; identifier ]
      in
      ("locate", args)

let request_source_file ~fs ~workspace input =
  match Fs.resolve ~workspace (Input.path input) with
  | Error _ as error -> error
  | Ok path -> (
      match Fs.regular ~fs ~workspace path with
      | Error _ as error -> error
      | Ok stats -> (
          if
            Int64.compare
              (Optint.Int63.to_int64 stats.Eio.File.Stat.size)
              (Int64.of_int max_source_bytes)
            > 0
          then
            Error
              (Fs.Error.Io
                 (Some path, "source file is too large for Merlin lookup"))
          else
            match Fs.load_regular ~fs ~workspace path with
            | Ok contents -> Ok (path, contents)
            | Error _ as error -> error))

let permissions ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ ->
      [
        Permission.Request.of_accesses ~source:name
          [
            Permission.Access.unknown_path ~op:`Read (Input.path input);
          ];
      ]
  | Ok path ->
      [
        Permission.Request.of_accesses ~source:name
          [
            Permission.Access.path ~op:`Read path;
          ];
      ]

let output_of_response ~workspace ~cwd ~source_path input = function
  | Found found ->
      let definition =
        definition_of_merlin_found ~workspace ~cwd ~source_path found
      in
      Tool.Result.completed
        ~output:
          (Output.make ~input ~definitions:[ definition ]
             ~index_status:Output.Unknown)
        ()
  | At_origin _ ->
      let found =
        {
          file = None;
          position =
            Ocaml.Position.make ~line:(Input.line input)
              ~column:(Input.column input);
        }
      in
      let definition =
        definition_of_merlin_found ~workspace ~cwd ~source_path found
      in
      Tool.Result.completed
        ~output:
          (Output.make ~input ~definitions:[ definition ]
             ~index_status:Output.Not_applicable)
        ()
  | Not_found message | Invalid_context message ->
      Tool.Result.failed `Not_found message
  | Malformed message -> Tool.Result.failed `Failed message

let run ~sandbox ?(program = default_program) ~fs ~workspace ctx input =
  if Tool.Context.cancelled ctx then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match request_source_file ~fs ~workspace input with
    | Error error -> Tool.Result.failed `Not_found (Fs.Error.message error)
    | Ok (source_path, source) -> (
        let root = Workspace.root_path workspace in
        let cwd = Workspace.Path.to_string root in
        let source_abs = Workspace.Path.to_string source_path in
        let command, args = merlin_command_args ~path:source_abs input in
        match
          Ocaml_merlin.run ~sandbox ~program ~cwd ~command ~args ~source
            ~cancelled:(fun () -> Tool.Context.cancelled ctx)
            ()
        with
        | Error Ocaml_merlin.Cancelled ->
            Tool.Result.interrupted ~reason:"tool call cancelled"
              ~cancelled:true ()
        | Error (Ocaml_merlin.Unavailable _ as error) ->
            Tool.Result.failed `Unavailable (Ocaml_merlin.error_message error)
        | Error (Ocaml_merlin.Timed_out _ as error) ->
            Tool.Result.failed `Timed_out (Ocaml_merlin.error_message error)
        | Error error ->
            Tool.Result.failed `Failed (Ocaml_merlin.error_message error)
        | Ok value ->
            output_of_response ~workspace ~cwd ~source_path:source_abs input
              (merlin_response_of_value value))

let tool ~sandbox ?program ~fs ~workspace () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(permissions ~workspace)
    ~run:(run ~sandbox ?program ~fs ~workspace)
    ()
