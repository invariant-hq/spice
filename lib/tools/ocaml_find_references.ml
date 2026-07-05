(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Ocaml = Spice_ocaml

let name = "ocaml_find_references"
let default_limit = 200
let max_limit = 1_000
let default_program = Ocaml_merlin.default_program
let description = Spice_prompts.Tools.ocaml_find_references

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

module Scope = struct
  type t = Buffer | Project | Renaming

  let to_string = function
    | Buffer -> "buffer"
    | Project -> "project"
    | Renaming -> "renaming"

  let of_string = function
    | "buffer" -> Some Buffer
    | "project" -> Some Project
    | "renaming" -> Some Renaming
    | _ -> None

  let rank = function Buffer -> 0 | Project -> 1 | Renaming -> 2
  let compare a b = Int.compare (rank a) (rank b)
  let equal a b = compare a b = 0
  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Input = struct
  type t = {
    path : string;
    position : Ocaml.Position.t;
    scope : Scope.t;
    include_stale : bool;
    offset : int option;
    limit : int;
  }

  let make ?(scope = Scope.Project) ?(include_stale = false) ?offset
      ?(limit = default_limit) ~path ~line ~column () =
    if String.is_empty path then invalid_arg "path must not be empty";
    (match offset with
    | Some offset when offset < 1 -> invalid_arg "offset must be at least 1"
    | _ -> ());
    if limit < 1 then invalid_arg "limit must be positive";
    if limit > max_limit then invalid_arg "limit exceeds max_limit";
    let position = Ocaml.Position.make ~line ~column in
    { path; position; scope; include_stale; offset; limit }

  let path t = t.path
  let position t = t.position
  let scope t = t.scope
  let include_stale t = t.include_stale
  let offset t = t.offset
  let limit t = t.limit
  let line t = Ocaml.Position.line t.position
  let column t = Ocaml.Position.column t.position

  let make_from_json_fields path line column scope include_stale offset limit =
    let scope =
      match scope with
      | None -> Scope.Project
      | Some scope -> (
          match Scope.of_string scope with
          | Some scope -> scope
          | None ->
              invalid_arg "scope must be one of buffer, project, or renaming")
    in
    let include_stale = Option.value ~default:false include_stale in
    let limit = Option.value ~default:default_limit limit in
    make ~scope ~include_stale ?offset ~limit ~path ~line ~column ()

  let codec =
    Jsont.Object.map ~kind:"ocaml_find_references input"
      (fun path line column scope include_stale offset limit ->
        decode_invalid_arg (fun () ->
            make_from_json_fields path line column scope include_stale offset
              limit))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.mem "line" Jsont.int ~enc:line
    |> Jsont.Object.mem "column" Jsont.int ~enc:column
    |> Jsont.Object.opt_mem "scope" Jsont.string ~enc:(fun t ->
        Some (Scope.to_string (scope t)))
    |> Jsont.Object.opt_mem "include_stale" Jsont.bool ~enc:(fun t ->
        Some (include_stale t))
    |> Jsont.Object.opt_mem "offset" Jsont.int ~enc:offset
    |> Jsont.Object.opt_mem "limit" Jsont.int ~enc:(fun t -> Some (limit t))
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
                    ("minLength", Json.int 1);
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
                      Json.string
                        "1-based source line of the identifier cursor." );
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
              ( "scope",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "buffer";
                          Json.string "project";
                          Json.string "renaming";
                        ] );
                    ( "description",
                      Json.string
                        "Merlin occurrence scope. Defaults to project. buffer \
                         is current-file only; project and renaming depend on \
                         Merlin/Dune occurrence indexes." );
                  ] );
              ( "include_stale",
                json_obj
                  [
                    ("type", Json.string "boolean");
                    ( "description",
                      Json.string
                        "Include stale occurrences reported by Merlin. \
                         Defaults to false so outdated index hits are skipped."
                    );
                  ] );
              ( "offset",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "1-based index of the first reference to return within \
                         the fresh result set. Defaults to 1. Use the [next:] \
                         continuation to page through more references." );
                  ] );
              ( "limit",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_limit);
                    ( "description",
                      Json.string
                        "Maximum returned references after stale filtering. \
                         Defaults to 200." );
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

module Reference = struct
  type t = { location : Ocaml.Location.t; stale : bool }

  let make ~location ~stale = { location; stale }
  let location t = t.location
  let stale t = t.stale

  let compare a b =
    match Ocaml.Location.compare a.location b.location with
    | 0 -> Bool.compare a.stale b.stale
    | n -> n

  let equal a b = compare a b = 0

  let pp ppf t =
    Format.fprintf ppf "%a%s" Ocaml.Location.pp t.location
      (if t.stale then " stale" else "")
end

(* Argv for the [occurrences] query. The [single] selector and program prefix
   are threaded by {!Ocaml_merlin}. *)
let occurrences_args ~file ~position ~scope =
  [
    "-identifier-at";
    Printf.sprintf "%d:%d"
      (Ocaml.Position.line position)
      (Ocaml.Position.column position);
    "-scope";
    Scope.to_string scope;
    "-filename";
    file;
  ]

let occurrences_argv ~program ~file ~position ~scope =
  Ocaml_merlin.argv ~program ~command:"occurrences"
    ~args:(occurrences_args ~file ~position ~scope)

type parse_error =
  | Invalid_response of string
  | Location_outside_workspace of string * string

let parse_error_message = function
  | Invalid_response message -> "unexpected ocamlmerlin response: " ^ message
  | Location_outside_workspace (path, message) ->
      "ocamlmerlin returned path outside workspace " ^ path ^ ": " ^ message

let member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_member name json =
  match member name json with
  | Some (Jsont.String (value, _)) -> Some value
  | _ -> None

let bool_member name json =
  match member name json with
  | Some (Jsont.Bool (value, _)) -> Some value
  | _ -> None

let require_member name json =
  match member name json with
  | Some value -> Ok value
  | None -> Error (Invalid_response ("missing member " ^ name))

let parse_position json =
  Result.map_error
    (fun message -> Invalid_response message)
    (Ocaml_position.of_json json)

let parse_location ~workspace ~default_path json =
  let raw_path = Option.value ~default:"" (string_member "file" json) in
  let path_result =
    if String.is_empty raw_path then Ok default_path
    else Workspace.resolve_string workspace raw_path
  in
  match path_result with
  | Error error ->
      Error
        (Location_outside_workspace
           (raw_path, Workspace.Resolve_error.message error))
  | Ok path -> (
      match (require_member "start" json, require_member "end" json) with
      | Ok start_json, Ok end_json -> (
          match (parse_position start_json, parse_position end_json) with
          | Ok start, Ok end_ -> (
              match Ocaml.Range.make ~start ~end_ with
              | range -> Ok (Ocaml.Location.make ~path ~range)
              | exception Invalid_argument message ->
                  Error (Invalid_response message))
          | Error error, Ok _ | Ok _, Error error | Error error, Error _ ->
              Error error)
      | Error error, Ok _ | Ok _, Error error | Error error, Error _ ->
          Error error)

let references_of_value ~workspace ~default_path value =
  match value with
  | Jsont.Array (items, _) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest -> (
            match parse_location ~workspace ~default_path item with
            | Error error -> Error error
            | Ok location ->
                let stale =
                  Option.value ~default:false (bool_member "stale" item)
                in
                loop (Reference.make ~location ~stale :: acc) rest)
      in
      loop [] items
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Object _ ->
      Error (Invalid_response "occurrences value is not a list")

let access_cwd workspace =
  Permission.Access.Path_scope.workspace (Workspace.root_path workspace)

let exec_request ~program ~file ~position ~scope workspace =
  match occurrences_argv ~program ~file ~position ~scope with
  | [] -> invalid_arg "argv must not be empty"
  | argv_program :: args ->
      Permission.Request.of_accesses ~source:name
        [
          Permission.Access.argv ~cwd:(access_cwd workspace)
            ~program:argv_program args;
        ]

let permissions ?(program = default_program) ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ -> []
  | Ok path ->
      let root = Workspace.root_path workspace in
      let abs = Spice_path.Abs.to_string (Workspace.Path.abs path) in
      [
        Permission.Request.of_accesses ~source:name
          [ Permission.Access.path ~op:`Read root ];
        Permission.Request.of_accesses ~source:name
          [ Permission.Access.path ~op:`Read path ];
        exec_request ~program ~file:abs ~position:(Input.position input)
          ~scope:(Input.scope input) workspace;
      ]

let location_json location =
  let range = Ocaml.Location.range location in
  let position_json position =
    json_obj
      [
        ("line", Json.int (Ocaml.Position.line position));
        ("column", Json.int (Ocaml.Position.column position));
      ]
  in
  json_obj
    [
      ( "path",
        Json.string (Workspace.Path.display (Ocaml.Location.path location)) );
      ( "range",
        json_obj
          [
            ("start", position_json (Ocaml.Range.start range));
            ("end", position_json (Ocaml.Range.end_ range));
          ] );
    ]

let reference_json reference =
  json_obj
    [
      ("location", location_json (Reference.location reference));
      ("stale", Json.bool (Reference.stale reference));
    ]

let input_json input =
  let fields =
    [
      ("path", Json.string (Input.path input));
      ("line", Json.int (Ocaml.Position.line (Input.position input)));
      ("column", Json.int (Ocaml.Position.column (Input.position input)));
      ("scope", Json.string (Scope.to_string (Input.scope input)));
      ("include_stale", Json.bool (Input.include_stale input));
      ("limit", Json.int (Input.limit input));
    ]
  in
  let fields =
    match Input.offset input with
    | None -> fields
    | Some offset -> fields @ [ ("offset", Json.int offset) ]
  in
  json_obj fields

module Output = struct
  type index_status = Not_applicable | Unknown
  type status = Complete | Partial

  type t = {
    query : Input.t;
    path : Workspace.Path.t;
    references : Reference.t list;
    total_count : int;
    stale_skipped : int;
    page : Input.t Pagination.Page.t;
    index_status : index_status;
    backend : string;
  }

  let make ~query ~path ~references ~total_count ~stale_skipped ~page
      ~index_status ~backend =
    {
      query;
      path;
      references;
      total_count;
      stale_skipped;
      page;
      index_status;
      backend;
    }

  let query t = t.query
  let path t = t.path
  let references t = t.references
  let returned_count t = List.length t.references
  let offset t = Pagination.Page.offset t.page

  let status t =
    if Pagination.Page.is_complete t.page then Complete else Partial

  let next t = Pagination.Page.next t.page
  let has_more t = not (Pagination.Page.is_complete t.page)
  let total_count t = t.total_count
  let stale_skipped t = t.stale_skipped
  let index_status t = t.index_status
  let backend t = t.backend
  let type_id : t Type.Id.t = Type.Id.make ()

  let index_status_to_string = function
    | Not_applicable -> "not_applicable"
    | Unknown -> "unknown"

  let status_to_string = function
    | Complete -> "complete"
    | Partial -> "partial"

  let json t =
    json_obj
      [
        ("query", input_json t.query);
        ("path", Json.string (Workspace.Path.display t.path));
        ("backend", Json.string t.backend);
        ("returned_count", Json.int (returned_count t));
        ("total_count", Json.int t.total_count);
        ("stale_skipped", Json.int t.stale_skipped);
        ("offset", Json.int (offset t));
        ("limit", Json.int (Input.limit t.query));
        ("status", Json.string (status_to_string (status t)));
        ( "next",
          match next t with
          | None -> Json.null ()
          | Some next -> input_json next );
        ("index_status", Json.string (index_status_to_string t.index_status));
        ("references", Json.list (List.map reference_json t.references));
      ]

  let reference_line reference =
    let location = Reference.location reference in
    let suffix = if Reference.stale reference then " stale" else "" in
    Format.asprintf "- %a%s" Ocaml.Location.pp location suffix

  let text t =
    let position = Input.position t.query in
    let b = Buffer.create 512 in
    Buffer.add_string b
      (Printf.sprintf "OCaml references for %s:%d:%d\n"
         (Workspace.Path.display t.path)
         (Ocaml.Position.line position)
         (Ocaml.Position.column position));
    Buffer.add_string b
      (Printf.sprintf "scope: %s\n" (Scope.to_string (Input.scope t.query)));
    Buffer.add_string b
      (Printf.sprintf "references: %d returned of %d" (returned_count t)
         t.total_count);
    if t.stale_skipped > 0 then
      Buffer.add_string b (Printf.sprintf ", %d stale skipped" t.stale_skipped);
    Buffer.add_string b
      (Printf.sprintf ", offset %d, status %s" (offset t)
         (status_to_string (status t)));
    Buffer.add_char b '\n';
    Buffer.add_string b
      ("index_status: " ^ index_status_to_string t.index_status ^ "\n");
    Buffer.add_string b ("backend: " ^ t.backend);
    List.iter
      (fun reference ->
        Buffer.add_char b '\n';
        Buffer.add_string b (reference_line reference))
      t.references;
    begin match Pagination.Page.hint ~tool:name ~to_json:input_json t.page with
    | None -> ()
    | Some hint ->
        Buffer.add_char b '\n';
        Buffer.add_string b hint
    end;
    if t.stale_skipped > 0 && not (Input.include_stale t.query) then begin
      Buffer.add_char b '\n';
      Buffer.add_string b
        "stale note: rebuild the project index, for Dune usually `dune build \
         @ocaml-index`."
    end;
    String.trim (Buffer.contents b)

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t) ~truncated:(has_more t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let read_source ~fs ~workspace path =
  match Fs.load_regular ~fs ~workspace path with
  | Ok source -> Ok source
  | Error error -> Error (Fs.Error.message error)

let index_status_of_scope : Scope.t -> Output.index_status = function
  | Scope.Buffer -> Output.Not_applicable
  | Scope.Project | Scope.Renaming -> Output.Unknown

let effective_offset input = Option.value (Input.offset input) ~default:1

(* Page over the fresh (post-stale-filter) reference set. [total] is that set's
   size; [returned] the rows in this window. *)
let reference_page input ~offset ~limit ~returned ~total =
  let count = Pagination.Count.Exact total in
  let has_more = offset <= total && offset + returned <= total in
  if has_more then
    let next =
      Input.make ~scope:(Input.scope input)
        ~include_stale:(Input.include_stale input)
        ~offset:(offset + returned) ~limit ~path:(Input.path input)
        ~line:(Input.line input) ~column:(Input.column input) ()
    in
    Pagination.Page.partial ~returned ~total:count ~offset ~limit
      ~next:(Some next)
  else Pagination.Page.complete ~returned ~total:count ~offset ~limit

let run ?(program = default_program) ~fs ~workspace ctx input =
  if Tool.Context.cancelled ctx then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Workspace.resolve_string workspace (Input.path input) with
    | Error error ->
        Tool.Result.failed `Invalid_input
          (Workspace.Resolve_error.message error)
    | Ok path -> (
        match read_source ~fs ~workspace path with
        | Error message -> Tool.Result.failed `Not_found message
        | Ok source -> (
            let root = Workspace.root_path workspace in
            let cwd = Spice_path.Abs.to_string (Workspace.Path.abs root) in
            let file = Spice_path.Abs.to_string (Workspace.Path.abs path) in
            let args =
              occurrences_args ~file ~position:(Input.position input)
                ~scope:(Input.scope input)
            in
            match
              Ocaml_merlin.run ~program ~cwd ~command:"occurrences" ~args
                ~source
                ~cancelled:(fun () -> Tool.Context.cancelled ctx)
                ()
            with
            | Error Ocaml_merlin.Cancelled ->
                Tool.Result.interrupted ~reason:"tool call cancelled"
                  ~cancelled:true ()
            | Error (Ocaml_merlin.Unavailable _ as error) ->
                Tool.Result.failed `Unavailable
                  (Ocaml_merlin.error_message error)
            | Error (Ocaml_merlin.Timed_out _ as error) ->
                Tool.Result.failed `Timed_out (Ocaml_merlin.error_message error)
            | Error error ->
                Tool.Result.failed `Failed (Ocaml_merlin.error_message error)
            | Ok value -> (
                match
                  references_of_value ~workspace ~default_path:path value
                with
                | Error error ->
                    Tool.Result.failed `Failed (parse_error_message error)
                | Ok references ->
                    let total_count = List.length references in
                    let references, stale_skipped =
                      if Input.include_stale input then (references, 0)
                      else
                        let fresh =
                          List.filter
                            (fun reference -> not (Reference.stale reference))
                            references
                        in
                        (fresh, total_count - List.length fresh)
                    in
                    let references = List.sort Reference.compare references in
                    let fresh_total = List.length references in
                    let offset = effective_offset input in
                    let limit = Input.limit input in
                    let references =
                      references |> List.drop (offset - 1) |> List.take limit
                    in
                    let returned = List.length references in
                    let page =
                      reference_page input ~offset ~limit ~returned
                        ~total:fresh_total
                    in
                    Tool.Result.completed
                      ~output:
                        (Output.make ~query:input ~path ~references ~total_count
                           ~stale_skipped ~page
                           ~index_status:
                             (index_status_of_scope (Input.scope input))
                           ~backend:"ocamlmerlin")
                      ())))

let tool ?program ~fs ~workspace () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ?program ~workspace input)
    ~run:(run ?program ~fs ~workspace)
    ()
