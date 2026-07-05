(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "ocaml_ast_edit"
let default_max_file_bytes = 1024 * 1024
let json_null = Json.null ()
let description = Spice_prompts.Tools.ocaml_ast_edit

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let file_identity = Spice_digest.Identity.of_contents

type file_kind = Implementation | Interface

let file_kind_to_string = function
  | Implementation -> "implementation"
  | Interface -> "interface"

let file_kind_of_string = function
  | "implementation" | "ml" -> Ok Implementation
  | "interface" | "mli" -> Ok Interface
  | value ->
      Error
        ("file_kind must be implementation, interface, ml, or mli; got " ^ value)

let infer_file_kind path =
  if Filename.check_suffix path ".mli" then Ok Interface
  else if Filename.check_suffix path ".ml" then Ok Implementation
  else Error "file_kind is required for paths that do not end in .ml or .mli"

module Item_kind = struct
  type t =
    | Value
    | Type
    | Module
    | Module_type
    | Exception
    | External
    | Open
    | Include
    | Class
    | Class_type
    | Extension
    | Eval

  let equal (a : t) (b : t) = a = b

  let to_string = function
    | Value -> "value"
    | Type -> "type"
    | Module -> "module"
    | Module_type -> "module_type"
    | Exception -> "exception"
    | External -> "external"
    | Open -> "open"
    | Include -> "include"
    | Class -> "class"
    | Class_type -> "class_type"
    | Extension -> "extension"
    | Eval -> "eval"

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

let item_kind_of_string = function
  | "value" -> Ok Item_kind.Value
  | "type" -> Ok Item_kind.Type
  | "module" -> Ok Item_kind.Module
  | "module_type" -> Ok Item_kind.Module_type
  | "exception" -> Ok Item_kind.Exception
  | "external" -> Ok Item_kind.External
  | "open" -> Ok Item_kind.Open
  | "include" -> Ok Item_kind.Include
  | "class" -> Ok Item_kind.Class
  | "class_type" -> Ok Item_kind.Class_type
  | "extension" -> Ok Item_kind.Extension
  | "eval" -> Ok Item_kind.Eval
  | value -> Error ("unknown item_kind: " ^ value)

module Node_kind = struct
  type t = Item of Item_kind.t option | Expression | Type

  let equal a b =
    match (a, b) with
    | Item a, Item b -> Option.equal Item_kind.equal a b
    | Expression, Expression | Type, Type -> true
    | (Item _ | Expression | Type), _ -> false

  let pp ppf = function
    | Item None -> Format.pp_print_string ppf "item"
    | Item (Some kind) -> Format.fprintf ppf "%a item" Item_kind.pp kind
    | Expression -> Format.pp_print_string ppf "expression"
    | Type -> Format.pp_print_string ppf "type"
end

let node_kind_of_fields kind item_kind =
  match (kind, item_kind) with
  | "expression", None -> Ok Node_kind.Expression
  | "type", None -> Ok Node_kind.Type
  | "item", None -> Ok (Node_kind.Item None)
  | "item", Some item_kind -> (
      match item_kind_of_string item_kind with
      | Ok item_kind -> Ok (Node_kind.Item (Some item_kind))
      | Error _ as error -> error)
  | ("expression" | "type"), Some _ ->
      Error "item_kind is only valid when kind is item"
  | value, _ -> Error ("kind must be item, expression, or type; got " ^ value)

let node_kind_json kind =
  let kind, item_kind =
    match kind with
    | Node_kind.Expression -> ("expression", json_null)
    | Node_kind.Type -> ("type", json_null)
    | Node_kind.Item None -> ("item", json_null)
    | Node_kind.Item (Some item_kind) ->
        ("item", Json.string (Item_kind.to_string item_kind))
  in
  json_obj [ ("kind", Json.string kind); ("item_kind", item_kind) ]

module Selector = struct
  type t =
    | Item of {
        path : string list;
        kind : Item_kind.t option;
        occurrence : int;
      }
    | Enclosing of { kind : Node_kind.t; position : Spice_ocaml.Position.t }
    | Exact of { kind : Node_kind.t; range : Spice_ocaml.Range.t }

  let validate_path path =
    match path with
    | [] -> invalid_arg "Ocaml_ast_edit.Selector.item: path must not be empty"
    | components ->
        List.iter
          (function
            | "" ->
                invalid_arg
                  "Ocaml_ast_edit.Selector.item: path components must not be \
                   empty"
            | _ -> ())
          components

  let item ?kind ?(occurrence = 1) path =
    validate_path path;
    if occurrence < 1 then
      invalid_arg "Ocaml_ast_edit.Selector.item: occurrence must be >= 1";
    Item { path; kind; occurrence }

  let enclosing ~kind ~position = Enclosing { kind; position }
  let exact ~kind ~range = Exact { kind; range }
  let pp_path ppf path = Format.pp_print_string ppf (String.concat "." path)

  let pp ppf = function
    | Item { path; kind = None; occurrence } ->
        Format.fprintf ppf "@[<hov>item %a occurrence %d@]" pp_path path
          occurrence
    | Item { path; kind = Some kind; occurrence } ->
        Format.fprintf ppf "@[<hov>%a %a occurrence %d@]" Item_kind.pp kind
          pp_path path occurrence
    | Enclosing { kind; position } ->
        Format.fprintf ppf "@[<hov>enclosing %a at %a@]" Node_kind.pp kind
          Spice_ocaml.Position.pp position
    | Exact { kind; range } ->
        Format.fprintf ppf "@[<hov>exact %a at %a@]" Node_kind.pp kind
          Spice_ocaml.Range.pp range
end

module Edit = struct
  type op = Replace | Insert_before | Insert_after | Delete
  type t = { op : op; selector : Selector.t; text : string option }

  let make ~op ~selector ?text () =
    Option.iter
      (fun text ->
        if not (String.is_valid_utf_8 text) then
          invalid_arg "Ocaml_ast_edit.Edit.make: text must be valid UTF-8")
      text;
    begin match (op, text) with
    | Delete, _ -> ()
    | (Replace | Insert_before | Insert_after), Some text
      when not (String.is_empty text) ->
        ()
    | Replace, _ ->
        invalid_arg "Ocaml_ast_edit.Edit.make: replace requires non-empty text"
    | (Insert_before | Insert_after), _ ->
        invalid_arg
          "Ocaml_ast_edit.Edit.make: insertion requires non-empty text"
    end;
    { op; selector; text = (if op = Delete then None else text) }

  let op t = t.op
  let selector t = t.selector
  let text t = t.text
end

let edit_op_to_string = function
  | Edit.Replace -> "replace"
  | Edit.Insert_before -> "insert_before"
  | Edit.Insert_after -> "insert_after"
  | Edit.Delete -> "delete"

let edit_op_of_string = function
  | "replace" -> Ok Edit.Replace
  | "insert_before" -> Ok Edit.Insert_before
  | "insert_after" -> Ok Edit.Insert_after
  | "delete" -> Ok Edit.Delete
  | value ->
      Error
        ("op must be replace, insert_before, insert_after, or delete; got "
       ^ value)

module Input = struct
  type selector = Selector.t
  type edit = Edit.t

  type t = {
    path : string;
    file_kind : file_kind;
    edits : edit list;
    if_identity : Spice_digest.Identity.t option;
  }

  let path (t : t) = t.path
  let file_kind t = t.file_kind
  let edits t = t.edits
  let if_identity t = t.if_identity

  let position line column =
    if line < 1 then invalid_arg "line must be at least 1";
    if column < 0 then invalid_arg "column must be non-negative";
    Spice_ocaml.Position.make ~line ~column

  let range start_line start_column end_line end_column =
    let start = position start_line start_column in
    let end_ = position end_line end_column in
    Spice_ocaml.Range.make ~start ~end_

  let selector_from_json mode path item_kind occurrence kind item_kind_for_node
      line column start_line start_column end_line end_column =
    match mode with
    | "item" ->
        let path =
          match path with
          | Some path -> path
          | None -> invalid_arg "selector.path is required when mode is item"
        in
        let kind =
          match item_kind with
          | None -> None
          | Some item_kind -> (
              match item_kind_of_string item_kind with
              | Ok kind -> Some kind
              | Error message -> invalid_arg message)
        in
        Selector.item ?kind ?occurrence path
    | "enclosing" ->
        let kind =
          match kind with
          | None ->
              invalid_arg "selector.kind is required when mode is enclosing"
          | Some kind -> (
              match node_kind_of_fields kind item_kind_for_node with
              | Ok kind -> kind
              | Error message -> invalid_arg message)
        in
        let line =
          match line with
          | Some line -> line
          | None ->
              invalid_arg "selector.line is required when mode is enclosing"
        in
        let column =
          match column with
          | Some column -> column
          | None ->
              invalid_arg "selector.column is required when mode is enclosing"
        in
        Selector.enclosing ~kind ~position:(position line column)
    | "exact" ->
        let kind =
          match kind with
          | None -> invalid_arg "selector.kind is required when mode is exact"
          | Some kind -> (
              match node_kind_of_fields kind item_kind_for_node with
              | Ok kind -> kind
              | Error message -> invalid_arg message)
        in
        let start_line =
          match start_line with
          | Some line -> line
          | None ->
              invalid_arg "selector.start_line is required when mode is exact"
        in
        let start_column =
          match start_column with
          | Some column -> column
          | None ->
              invalid_arg "selector.start_column is required when mode is exact"
        in
        let end_line =
          match end_line with
          | Some line -> line
          | None ->
              invalid_arg "selector.end_line is required when mode is exact"
        in
        let end_column =
          match end_column with
          | Some column -> column
          | None ->
              invalid_arg "selector.end_column is required when mode is exact"
        in
        Selector.exact ~kind
          ~range:(range start_line start_column end_line end_column)
    | value ->
        invalid_arg
          ("selector.mode must be item, enclosing, or exact; got " ^ value)

  let selector_codec =
    Jsont.Object.map ~kind:"ocaml_ast_edit selector"
      (fun
        mode
        path
        item_kind
        occurrence
        kind
        item_kind_for_node
        line
        column
        start_line
        start_column
        end_line
        end_column
      ->
        decode_invalid_arg (fun () ->
            selector_from_json mode path item_kind occurrence kind
              item_kind_for_node line column start_line start_column end_line
              end_column))
    |> Jsont.Object.mem "mode" Jsont.string ~enc:(fun selector ->
        match selector with
        | Selector.Item _ -> "item"
        | Selector.Enclosing _ -> "enclosing"
        | Selector.Exact _ -> "exact")
    |> Jsont.Object.opt_mem "path" (Jsont.list Jsont.string) ~enc:(function
      | Selector.Item { path; _ } -> Some path
      | Selector.Enclosing _ | Selector.Exact _ -> None)
    |> Jsont.Object.opt_mem "item_kind" Jsont.string ~enc:(function
      | Selector.Item { kind = Some kind; _ } -> Some (Item_kind.to_string kind)
      | Selector.Item { kind = None; _ }
      | Selector.Enclosing _ | Selector.Exact _ ->
          None)
    |> Jsont.Object.opt_mem "occurrence" Jsont.int ~enc:(function
      | Selector.Item { occurrence; _ } when occurrence <> 1 -> Some occurrence
      | Selector.Item _ | Selector.Enclosing _ | Selector.Exact _ -> None)
    |> Jsont.Object.opt_mem "kind" Jsont.string ~enc:(function
      | Selector.Enclosing { kind; _ } | Selector.Exact { kind; _ } -> (
          match kind with
          | Node_kind.Expression -> Some "expression"
          | Node_kind.Type -> Some "type"
          | Node_kind.Item _ -> Some "item")
      | Selector.Item _ -> None)
    |> Jsont.Object.opt_mem "node_item_kind" Jsont.string ~enc:(function
      | Selector.Enclosing { kind = Node_kind.Item (Some kind); _ }
      | Selector.Exact { kind = Node_kind.Item (Some kind); _ } ->
          Some (Item_kind.to_string kind)
      | Selector.Item _ | Selector.Enclosing _ | Selector.Exact _ -> None)
    |> Jsont.Object.opt_mem "line" Jsont.int ~enc:(function
      | Selector.Enclosing { position; _ } ->
          Some (Spice_ocaml.Position.line position)
      | Selector.Item _ | Selector.Exact _ -> None)
    |> Jsont.Object.opt_mem "column" Jsont.int ~enc:(function
      | Selector.Enclosing { position; _ } ->
          Some (Spice_ocaml.Position.column position)
      | Selector.Item _ | Selector.Exact _ -> None)
    |> Jsont.Object.opt_mem "start_line" Jsont.int ~enc:(function
      | Selector.Exact { range; _ } ->
          Some (Spice_ocaml.Position.line (Spice_ocaml.Range.start range))
      | Selector.Item _ | Selector.Enclosing _ -> None)
    |> Jsont.Object.opt_mem "start_column" Jsont.int ~enc:(function
      | Selector.Exact { range; _ } ->
          Some (Spice_ocaml.Position.column (Spice_ocaml.Range.start range))
      | Selector.Item _ | Selector.Enclosing _ -> None)
    |> Jsont.Object.opt_mem "end_line" Jsont.int ~enc:(function
      | Selector.Exact { range; _ } ->
          Some (Spice_ocaml.Position.line (Spice_ocaml.Range.end_ range))
      | Selector.Item _ | Selector.Enclosing _ -> None)
    |> Jsont.Object.opt_mem "end_column" Jsont.int ~enc:(function
      | Selector.Exact { range; _ } ->
          Some (Spice_ocaml.Position.column (Spice_ocaml.Range.end_ range))
      | Selector.Item _ | Selector.Enclosing _ -> None)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let edit_from_json op selector text =
    match edit_op_of_string op with
    | Error message -> invalid_arg message
    | Ok op -> Edit.make ~op ~selector ?text ()

  let edit_codec =
    Jsont.Object.map ~kind:"ocaml_ast_edit edit" (fun op selector text ->
        decode_invalid_arg (fun () -> edit_from_json op selector text))
    |> Jsont.Object.mem "op" Jsont.string ~enc:(fun edit ->
        edit_op_to_string (Edit.op edit))
    |> Jsont.Object.mem "selector" selector_codec ~enc:Edit.selector
    |> Jsont.Object.opt_mem "text" Jsont.string ~enc:Edit.text
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let make ~path ?file_kind ?if_identity ~edits () =
    if String.is_empty path then invalid_arg "path must not be empty";
    let file_kind =
      match file_kind with
      | Some file_kind -> file_kind
      | None -> (
          match infer_file_kind path with
          | Ok file_kind -> file_kind
          | Error message -> invalid_arg message)
    in
    if List.is_empty edits then invalid_arg "edits must not be empty";
    { path; file_kind; edits; if_identity }

  let make_from_json_fields path file_kind if_identity edits =
    let file_kind =
      match file_kind with
      | None -> None
      | Some value -> (
          match file_kind_of_string value with
          | Ok file_kind -> Some file_kind
          | Error message -> invalid_arg message)
    in
    let if_identity =
      match if_identity with
      | None -> None
      | Some "" -> invalid_arg "if_identity must not be empty"
      | Some value -> (
          match Spice_digest.Identity.of_string value with
          | Error error ->
              invalid_arg
                ("if_identity is not a file identity: "
                ^ Spice_digest.Identity.Parse_error.message error)
          | Ok identity -> Some identity)
    in
    make ~path ?file_kind ?if_identity ~edits ()

  let codec =
    Jsont.Object.map ~kind:"ocaml_ast_edit input"
      (fun path file_kind if_identity edits ->
        decode_invalid_arg (fun () ->
            make_from_json_fields path file_kind if_identity edits))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.opt_mem "file_kind" Jsont.string ~enc:(fun t ->
        Some (file_kind_to_string t.file_kind))
    |> Jsont.Object.opt_mem "if_identity" Jsont.string ~enc:(fun t ->
        Option.map Spice_digest.Identity.to_string t.if_identity)
    |> Jsont.Object.mem "edits" (Jsont.list edit_codec) ~enc:edits
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let string_enum values =
    json_obj
      [
        ("type", Json.string "string");
        ("enum", Json.list (List.map (fun value -> Json.string value) values));
      ]

  let item_kind_schema =
    string_enum
      [
        "value";
        "type";
        "module";
        "module_type";
        "exception";
        "external";
        "open";
        "include";
        "class";
        "class_type";
        "extension";
        "eval";
      ]

  let selector_schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "mode",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "item";
                          Json.string "enclosing";
                          Json.string "exact";
                        ] );
                  ] );
              ( "path",
                json_obj
                  [
                    ("type", Json.string "array");
                    ("items", json_obj [ ("type", Json.string "string") ]);
                    ("minItems", Json.int 1);
                    ( "description",
                      Json.string
                        "Qualified item path components, for example \
                         [\"M\",\"answer\"]. Required when mode is item." );
                  ] );
              ( "item_kind",
                json_obj
                  [
                    ("allOf", Json.list [ item_kind_schema ]);
                    ( "description",
                      Json.string
                        "Optional item kind filter for item selectors." );
                  ] );
              ( "occurrence",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "1-based occurrence when an item path matches multiple \
                         declarations. Defaults to 1." );
                  ] );
              ( "kind",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "item";
                          Json.string "expression";
                          Json.string "type";
                        ] );
                    ( "description",
                      Json.string
                        "AST node kind for enclosing and exact selectors." );
                  ] );
              ( "node_item_kind",
                json_obj
                  [
                    ("allOf", Json.list [ item_kind_schema ]);
                    ( "description",
                      Json.string
                        "Optional item-kind filter when kind is item for \
                         enclosing or exact selectors." );
                  ] );
              ( "line",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string "1-based cursor line for enclosing selectors."
                    );
                  ] );
              ( "column",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ( "description",
                      Json.string
                        "0-based byte cursor column for enclosing selectors." );
                  ] );
              ( "start_line",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string "1-based exact range start line." );
                  ] );
              ( "start_column",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ( "description",
                      Json.string "0-based byte exact range start column." );
                  ] );
              ( "end_line",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("description", Json.string "1-based exact range end line.");
                  ] );
              ( "end_column",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ( "description",
                      Json.string "0-based byte exact range end column." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "mode" ]);
        ("additionalProperties", Json.bool false);
      ]

  let edit_schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "op",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "replace";
                          Json.string "insert_before";
                          Json.string "insert_after";
                          Json.string "delete";
                        ] );
                  ] );
              ("selector", selector_schema);
              ( "text",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "description",
                      Json.string
                        "Replacement or insertion OCaml fragment. Omit for \
                         delete." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "op"; Json.string "selector" ]);
        ("additionalProperties", Json.bool false);
      ]

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
                        "Workspace-relative or workspace-contained OCaml \
                         source path." );
                  ] );
              ( "file_kind",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "implementation";
                          Json.string "interface";
                          Json.string "ml";
                          Json.string "mli";
                        ] );
                    ( "description",
                      Json.string
                        "implementation/ml or interface/mli. Defaults from the \
                         file extension." );
                  ] );
              ( "if_identity",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "description",
                      Json.string
                        "Complete-file identity from a previous complete read."
                    );
                  ] );
              ( "edits",
                json_obj
                  [
                    ("type", Json.string "array");
                    ("items", edit_schema);
                    ("minItems", Json.int 1);
                  ] );
            ] );
        ("required", Json.list [ Json.string "path"; Json.string "edits" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Error = struct
  type t =
    | Invalid_text of string
    | Invalid_range of string
    | Parse_error of {
        phase : string;
        message : string;
        range : Spice_ocaml.Range.t option;
      }
    | Selection_not_found of Selector.t
    | Ambiguous_selection of {
        selector : Selector.t;
        matches : Spice_ocaml.Range.t list;
      }
    | Invalid_operation of string
    | Overlapping_edits of Spice_ocaml.Range.t * Spice_ocaml.Range.t
    | Edit_error of Spice_edit.Error.t

  let message = function
    | Invalid_text reason -> "invalid UTF-8 text: " ^ reason
    | Invalid_range reason -> "invalid source range: " ^ reason
    | Parse_error { phase; message; range = None } ->
        phase ^ " parse error: " ^ message
    | Parse_error { phase; message; range = Some range } ->
        Format.asprintf "%s parse error at %a: %s" phase Spice_ocaml.Range.pp
          range message
    | Selection_not_found selector ->
        Format.asprintf "AST selection not found: %a" Selector.pp selector
    | Ambiguous_selection { selector; matches } ->
        Format.asprintf "AST selection is ambiguous: %a matched %d ranges"
          Selector.pp selector (List.length matches)
    | Invalid_operation reason -> "invalid AST edit operation: " ^ reason
    | Overlapping_edits (a, b) ->
        Format.asprintf "AST edits overlap: %a and %a" Spice_ocaml.Range.pp a
          Spice_ocaml.Range.pp b
    | Edit_error error -> Spice_edit.Error.message error

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Resolved = struct
  type t = {
    selector : Selector.t;
    kind : Node_kind.t;
    range : Spice_ocaml.Range.t;
    selected_text : string;
  }

  let selector t = t.selector
  let kind t = t.kind
  let range t = t.range
  let selected_text t = t.selected_text
end

module Plan = struct
  type t = {
    path : Spice_workspace.Path.t;
    file_kind : file_kind;
    before_contents : string;
    after_contents : string;
    edit : Spice_edit.t;
    resolved : Resolved.t list;
  }

  let path (t : t) = t.path
  let file_kind t = t.file_kind
  let before_contents t = t.before_contents
  let after_contents t = t.after_contents
  let edit t = t.edit
  let resolved t = t.resolved
end

type parsed = Impl of Parsetree.structure | Intf of Parsetree.signature
type node = { kind : Node_kind.t; path : string list option; loc : Location.t }

type span = {
  start_offset : int;
  end_offset : int;
  range : Spice_ocaml.Range.t;
}

type selected = { node : node; span : span; text : string }

let lexbuf ?(filename = "") text =
  let lexbuf = Lexing.from_string text in
  lexbuf.Lexing.lex_curr_p <-
    {
      Lexing.pos_fname = filename;
      Lexing.pos_lnum = 1;
      Lexing.pos_bol = 0;
      Lexing.pos_cnum = 0;
    };
  lexbuf

let parse_error phase exn =
  let range =
    match exn with
    | Syntaxerr.Error error ->
        Some (Ocaml_position.range_of_loc (Syntaxerr.location_of_error error))
    | _ -> None
  in
  (* Render the compiler's own diagnostic. [main.txt] is the plain message
     document; colour is applied only by [Location.print_report], never here. *)
  let message =
    match Location.error_of_exn exn with
    | Some (`Ok report) ->
        Format.asprintf "%a" Format_doc.Doc.format
          report.Location.main.Location.txt
    | Some `Already_displayed | None -> Printexc.to_string exn
  in
  Error.Parse_error { phase; message; range }

let parse_file ~path ~file_kind contents =
  let filename = Spice_workspace.Path.display path in
  try
    match file_kind with
    | Implementation ->
        Ok (Impl (Parse.implementation (lexbuf ~filename contents)))
    | Interface -> Ok (Intf (Parse.interface (lexbuf ~filename contents)))
  with exn -> Error (parse_error "source" exn)

let parse_items ~file_kind text =
  try
    match file_kind with
    | Implementation ->
        ignore (Parse.implementation (lexbuf text) : Parsetree.structure);
        Ok ()
    | Interface ->
        ignore (Parse.interface (lexbuf text) : Parsetree.signature);
        Ok ()
  with exn -> Error (parse_error "replacement item" exn)

let parse_expression text =
  try
    ignore (Parse.expression (lexbuf text) : Parsetree.expression);
    Ok ()
  with exn -> Error (parse_error "replacement expression" exn)

let parse_type text =
  try
    ignore (Parse.core_type (lexbuf text) : Parsetree.core_type);
    Ok ()
  with exn -> Error (parse_error "replacement type" exn)

let line_starts text =
  let starts = ref [ 0 ] in
  String.iteri
    (fun index char ->
      if Char.equal char '\n' then starts := (index + 1) :: !starts)
    text;
  Array.of_list (List.rev !starts)

let offset_of_position starts text position =
  let line = Spice_ocaml.Position.line position in
  let column = Spice_ocaml.Position.column position in
  if line < 1 || line > Array.length starts then
    Error
      (Error.Invalid_range (Printf.sprintf "line %d is outside the file" line))
  else
    let start = starts.(line - 1) in
    let limit =
      if line = Array.length starts then String.length text
      else starts.(line) - 1
    in
    let offset = start + column in
    if offset > limit then
      Error
        (Error.Invalid_range
           (Printf.sprintf "column %d is outside line %d" column line))
    else Ok offset

let span_of_loc loc =
  let start_offset = loc.Location.loc_start.Lexing.pos_cnum in
  let end_offset = loc.Location.loc_end.Lexing.pos_cnum in
  let range = Ocaml_position.range_of_loc loc in
  { start_offset; end_offset; range }

let contains_offset span offset =
  span.start_offset <= offset && offset < span.end_offset

let span_size span = span.end_offset - span.start_offset

let loc_is_real loc =
  (not loc.Location.loc_ghost)
  && loc.Warnings.loc_start.Lexing.pos_cnum
     <= loc.Warnings.loc_end.Lexing.pos_cnum

let node_text contents span =
  String.sub contents span.start_offset (span.end_offset - span.start_offset)

let lid_name (lid : Longident.t Location.loc) =
  match lid.Location.txt with
  | Longident.Lident name -> Some name
  | Longident.Ldot (_, name) -> Some name.Location.txt
  | Longident.Lapply _ -> None

let module_expr_name (expr : Parsetree.module_expr) =
  match expr.Parsetree.pmod_desc with
  | Parsetree.Pmod_ident lid -> lid_name lid
  | Parsetree.Pmod_structure _ | Parsetree.Pmod_functor _
  | Parsetree.Pmod_apply _ | Parsetree.Pmod_constraint _
  | Parsetree.Pmod_apply_unit _ | Parsetree.Pmod_unpack _
  | Parsetree.Pmod_extension _ ->
      None

let pattern_names pattern =
  let names = ref [] in
  let iterator =
    {
      Ast_iterator.default_iterator with
      Ast_iterator.pat =
        (fun self pattern ->
          begin match pattern.Parsetree.ppat_desc with
          | Parsetree.Ppat_var { Location.txt = name; Location.loc } ->
              if not loc.Location.loc_ghost then names := name :: !names
          | _ -> ()
          end;
          Ast_iterator.default_iterator.Ast_iterator.pat self pattern);
    }
  in
  iterator.Ast_iterator.pat iterator pattern;
  List.rev !names

let add_node nodes kind path loc =
  if loc_is_real loc then { kind; path; loc } :: nodes else nodes

let add_item nodes kind path loc =
  add_node nodes (Node_kind.Item (Some kind)) (Some path) loc

let rec structure_nodes path nodes structure =
  List.fold_left (structure_item_nodes path) nodes structure

and structure_item_nodes path nodes item =
  let nodes =
    match item.Parsetree.pstr_desc with
    | Parsetree.Pstr_value (_, bindings) ->
        List.fold_left
          (fun nodes binding ->
            List.fold_left
              (fun nodes name ->
                add_item nodes Item_kind.Value (path @ [ name ])
                  item.Parsetree.pstr_loc)
              nodes
              (pattern_names binding.Parsetree.pvb_pat))
          nodes bindings
    | Parsetree.Pstr_type (_, declarations) ->
        List.fold_left
          (fun nodes declaration ->
            add_item nodes Item_kind.Type
              (path @ [ declaration.Parsetree.ptype_name.Location.txt ])
              item.Parsetree.pstr_loc)
          nodes declarations
    | Parsetree.Pstr_typext extension ->
        add_item nodes Item_kind.Type
          (path @ [ "type_extension" ])
          extension.Parsetree.ptyext_path.Location.loc
    | Parsetree.Pstr_exception extension ->
        add_item nodes Item_kind.Exception
          (path
          @ [
              extension.Parsetree.ptyexn_constructor.Parsetree.pext_name
                .Location.txt;
            ])
          item.Parsetree.pstr_loc
    | Parsetree.Pstr_module binding ->
        module_binding_node path nodes item.Parsetree.pstr_loc binding
    | Parsetree.Pstr_recmodule bindings ->
        List.fold_left
          (fun nodes binding ->
            module_binding_node path nodes item.Parsetree.pstr_loc binding)
          nodes bindings
    | Parsetree.Pstr_modtype declaration ->
        add_item nodes Item_kind.Module_type
          (path @ [ declaration.Parsetree.pmtd_name.Location.txt ])
          item.Parsetree.pstr_loc
    | Parsetree.Pstr_open open_declaration -> (
        match module_expr_name open_declaration.Parsetree.popen_expr with
        | None ->
            add_item nodes Item_kind.Open (path @ [ "open" ])
              item.Parsetree.pstr_loc
        | Some name ->
            add_item nodes Item_kind.Open (path @ [ name ])
              item.Parsetree.pstr_loc)
    | Parsetree.Pstr_include _ ->
        add_item nodes Item_kind.Include (path @ [ "include" ])
          item.Parsetree.pstr_loc
    | Parsetree.Pstr_primitive value ->
        add_item nodes Item_kind.External
          (path @ [ value.Parsetree.pval_name.Location.txt ])
          item.Parsetree.pstr_loc
    | Parsetree.Pstr_class declarations ->
        List.fold_left
          (fun nodes declaration ->
            add_item nodes Item_kind.Class
              (path @ [ declaration.Parsetree.pci_name.Location.txt ])
              item.Parsetree.pstr_loc)
          nodes declarations
    | Parsetree.Pstr_class_type declarations ->
        List.fold_left
          (fun nodes declaration ->
            add_item nodes Item_kind.Class_type
              (path @ [ declaration.Parsetree.pci_name.Location.txt ])
              item.Parsetree.pstr_loc)
          nodes declarations
    | Parsetree.Pstr_extension _ ->
        add_item nodes Item_kind.Extension (path @ [ "extension" ])
          item.Parsetree.pstr_loc
    | Parsetree.Pstr_eval _ ->
        add_item nodes Item_kind.Eval (path @ [ "eval" ])
          item.Parsetree.pstr_loc
    | Parsetree.Pstr_attribute _ -> nodes
  in
  let nodes_ref = ref nodes in
  let iterator =
    {
      Ast_iterator.default_iterator with
      Ast_iterator.expr =
        (fun self expr ->
          nodes_ref :=
            add_node !nodes_ref Node_kind.Expression None
              expr.Parsetree.pexp_loc;
          Ast_iterator.default_iterator.Ast_iterator.expr self expr);
      Ast_iterator.typ =
        (fun self typ ->
          nodes_ref :=
            add_node !nodes_ref Node_kind.Type None typ.Parsetree.ptyp_loc;
          Ast_iterator.default_iterator.Ast_iterator.typ self typ);
    }
  in
  iterator.Ast_iterator.structure_item iterator item;
  !nodes_ref

and module_binding_node path nodes item_loc binding =
  let name = binding.Parsetree.pmb_name.Location.txt in
  let nodes =
    match name with
    | None -> nodes
    | Some name -> add_item nodes Item_kind.Module (path @ [ name ]) item_loc
  in
  match (name, binding.Parsetree.pmb_expr.Parsetree.pmod_desc) with
  | Some name, Parsetree.Pmod_structure structure ->
      structure_nodes (path @ [ name ]) nodes structure
  | Some _, _ | None, _ -> nodes

let rec signature_nodes path nodes signature =
  List.fold_left (signature_item_nodes path) nodes signature

and signature_item_nodes path nodes item =
  let nodes =
    match item.Parsetree.psig_desc with
    | Parsetree.Psig_value value ->
        add_item nodes Item_kind.Value
          (path @ [ value.Parsetree.pval_name.Location.txt ])
          item.Parsetree.psig_loc
    | Parsetree.Psig_type (_, declarations) ->
        List.fold_left
          (fun nodes declaration ->
            add_item nodes Item_kind.Type
              (path @ [ declaration.Parsetree.ptype_name.Location.txt ])
              item.Parsetree.psig_loc)
          nodes declarations
    | Parsetree.Psig_typesubst declarations ->
        List.fold_left
          (fun nodes declaration ->
            add_item nodes Item_kind.Type
              (path @ [ declaration.Parsetree.ptype_name.Location.txt ])
              item.Parsetree.psig_loc)
          nodes declarations
    | Parsetree.Psig_typext extension ->
        add_item nodes Item_kind.Type
          (path @ [ "type_extension" ])
          extension.Parsetree.ptyext_path.Location.loc
    | Parsetree.Psig_exception extension ->
        add_item nodes Item_kind.Exception
          (path
          @ [
              extension.Parsetree.ptyexn_constructor.Parsetree.pext_name
                .Location.txt;
            ])
          item.Parsetree.psig_loc
    | Parsetree.Psig_module declaration ->
        module_declaration_node path nodes item.Parsetree.psig_loc declaration
    | Parsetree.Psig_recmodule declarations ->
        List.fold_left
          (fun nodes declaration ->
            module_declaration_node path nodes item.Parsetree.psig_loc
              declaration)
          nodes declarations
    | Parsetree.Psig_modtype declaration ->
        add_item nodes Item_kind.Module_type
          (path @ [ declaration.Parsetree.pmtd_name.Location.txt ])
          item.Parsetree.psig_loc
    | Parsetree.Psig_modtypesubst declaration ->
        add_item nodes Item_kind.Module_type
          (path @ [ declaration.Parsetree.pmtd_name.Location.txt ])
          item.Parsetree.psig_loc
    | Parsetree.Psig_modsubst substitution ->
        add_item nodes Item_kind.Module
          (path @ [ substitution.Parsetree.pms_name.Location.txt ])
          item.Parsetree.psig_loc
    | Parsetree.Psig_open open_description -> (
        match lid_name open_description.Parsetree.popen_expr with
        | None ->
            add_item nodes Item_kind.Open (path @ [ "open" ])
              item.Parsetree.psig_loc
        | Some name ->
            add_item nodes Item_kind.Open (path @ [ name ])
              item.Parsetree.psig_loc)
    | Parsetree.Psig_include _ ->
        add_item nodes Item_kind.Include (path @ [ "include" ])
          item.Parsetree.psig_loc
    | Parsetree.Psig_class descriptions ->
        List.fold_left
          (fun nodes description ->
            add_item nodes Item_kind.Class
              (path @ [ description.Parsetree.pci_name.Location.txt ])
              item.Parsetree.psig_loc)
          nodes descriptions
    | Parsetree.Psig_class_type descriptions ->
        List.fold_left
          (fun nodes description ->
            add_item nodes Item_kind.Class_type
              (path @ [ description.Parsetree.pci_name.Location.txt ])
              item.Parsetree.psig_loc)
          nodes descriptions
    | Parsetree.Psig_extension _ ->
        add_item nodes Item_kind.Extension (path @ [ "extension" ])
          item.Parsetree.psig_loc
    | Parsetree.Psig_attribute _ -> nodes
  in
  let nodes_ref = ref nodes in
  let iterator =
    {
      Ast_iterator.default_iterator with
      Ast_iterator.typ =
        (fun self typ ->
          nodes_ref :=
            add_node !nodes_ref Node_kind.Type None typ.Parsetree.ptyp_loc;
          Ast_iterator.default_iterator.Ast_iterator.typ self typ);
    }
  in
  iterator.Ast_iterator.signature_item iterator item;
  !nodes_ref

and module_declaration_node path nodes item_loc declaration =
  let name = declaration.Parsetree.pmd_name.Location.txt in
  let nodes =
    match name with
    | None -> nodes
    | Some name -> add_item nodes Item_kind.Module (path @ [ name ]) item_loc
  in
  match (name, declaration.Parsetree.pmd_type.Parsetree.pmty_desc) with
  | Some name, Parsetree.Pmty_signature signature ->
      signature_nodes (path @ [ name ]) nodes signature
  | Some _, _ | None, _ -> nodes

let nodes_of_parsed = function
  | Impl structure -> List.rev (structure_nodes [] [] structure)
  | Intf signature -> List.rev (signature_nodes [] [] signature)

let node_matches_kind requested node =
  match (requested, node.kind) with
  | Node_kind.Item None, Node_kind.Item _ -> true
  | Node_kind.Item None, (Node_kind.Expression | Node_kind.Type) -> false
  | Node_kind.Item (Some requested), Node_kind.Item (Some actual) ->
      Item_kind.equal requested actual
  | Node_kind.Expression, Node_kind.Expression | Node_kind.Type, Node_kind.Type
    ->
      true
  | (Node_kind.Item (Some _) | Node_kind.Expression | Node_kind.Type), _ ->
      false

let node_matches_exact_range requested_range node =
  Spice_ocaml.Range.equal requested_range (Ocaml_position.range_of_loc node.loc)

let select_item nodes path kind occurrence =
  let matches =
    List.filter
      (fun node ->
        match node.path with
        | Some node_path ->
            List.equal String.equal path node_path
            && node_matches_kind (Node_kind.Item kind) node
        | None -> false)
      nodes
  in
  let rec drop count values =
    if count = 0 then values
    else match values with [] -> [] | _ :: rest -> drop (count - 1) rest
  in
  match drop (occurrence - 1) matches with
  | node :: _ -> Ok node
  | [] -> Error None

let select_enclosing nodes contents kind position =
  let starts = line_starts contents in
  match offset_of_position starts contents position with
  | Error error -> Error (`Range error)
  | Ok offset ->
      let matches =
        nodes
        |> List.filter (fun node ->
            node_matches_kind kind node
            && contains_offset (span_of_loc node.loc) offset)
        |> List.sort (fun a b ->
            Int.compare
              (span_size (span_of_loc a.loc))
              (span_size (span_of_loc b.loc)))
      in
      begin match matches with node :: _ -> Ok node | [] -> Error `Not_found
      end

let select_exact nodes kind range =
  let matches =
    List.filter
      (fun node ->
        node_matches_kind kind node && node_matches_exact_range range node)
      nodes
  in
  match matches with
  | [ node ] -> Ok node
  | [] -> Error `Not_found
  | node :: rest
    when List.for_all
           (fun other ->
             Spice_ocaml.Range.equal
               (Ocaml_position.range_of_loc node.loc)
               (Ocaml_position.range_of_loc other.loc))
           rest ->
      Ok node
  | matches ->
      Error
        (`Ambiguous
           (List.map (fun node -> Ocaml_position.range_of_loc node.loc) matches))

let resolve_selector nodes contents selector =
  match selector with
  | Selector.Item { path; kind; occurrence } ->
      select_item nodes path kind occurrence
      |> Result.map_error (fun _ -> Error.Selection_not_found selector)
  | Selector.Enclosing { kind; position } -> (
      match select_enclosing nodes contents kind position with
      | Ok node -> Ok node
      | Error (`Range error) -> Error error
      | Error `Not_found -> Error (Error.Selection_not_found selector))
  | Selector.Exact { kind; range } -> (
      match select_exact nodes kind range with
      | Ok node -> Ok node
      | Error `Not_found -> Error (Error.Selection_not_found selector)
      | Error (`Ambiguous matches) ->
          Error (Error.Ambiguous_selection { selector; matches }))

let validate_replacement ~file_kind selected edit =
  match (Edit.op edit, selected.node.kind, Edit.text edit) with
  | Edit.Delete, _, None -> Ok ""
  | Edit.Replace, Node_kind.Item _, Some text ->
      parse_items ~file_kind text |> Result.map (fun () -> text)
  | Edit.Replace, Node_kind.Expression, Some text ->
      parse_expression text |> Result.map (fun () -> text)
  | Edit.Replace, Node_kind.Type, Some text ->
      parse_type text |> Result.map (fun () -> text)
  | (Edit.Insert_before | Edit.Insert_after), Node_kind.Item _, Some text ->
      parse_items ~file_kind text |> Result.map (fun () -> text)
  | ( (Edit.Insert_before | Edit.Insert_after),
      (Node_kind.Expression | Node_kind.Type),
      Some _ ) ->
      Error
        (Error.Invalid_operation
           "insert_before and insert_after are only valid around item \
            selections")
  | (Edit.Replace | Edit.Insert_before | Edit.Insert_after), _, None ->
      Error (Error.Invalid_operation "operation is missing replacement text")
  | Edit.Delete, _, Some _ -> Ok ""

type patch = {
  edit : Edit.t;
  selected : selected;
  replace_start : int;
  replace_end : int;
  replacement : string;
}

let resolve_edit nodes contents ~file_kind edit =
  let selector = Edit.selector edit in
  match resolve_selector nodes contents selector with
  | Error error -> Error error
  | Ok node -> (
      let span = span_of_loc node.loc in
      let selected = { node; span; text = node_text contents span } in
      match validate_replacement ~file_kind selected edit with
      | Error error -> Error error
      | Ok replacement ->
          let replace_start, replace_end =
            match Edit.op edit with
            | Edit.Replace | Edit.Delete -> (span.start_offset, span.end_offset)
            | Edit.Insert_before -> (span.start_offset, span.start_offset)
            | Edit.Insert_after -> (span.end_offset, span.end_offset)
          in
          Ok { edit; selected; replace_start; replace_end; replacement })

let patch_order a b =
  match Int.compare a.replace_start b.replace_start with
  | 0 -> Int.compare a.replace_end b.replace_end
  | order -> order

let check_overlaps patches =
  let sorted = List.sort patch_order patches in
  let rec loop = function
    | first :: (second :: _ as rest) ->
        if
          first.replace_end > second.replace_start
          || first.replace_start = second.replace_start
             && (first.replace_end > first.replace_start
                || second.replace_end > second.replace_start)
        then
          Error
            (Error.Overlapping_edits
               (first.selected.span.range, second.selected.span.range))
        else loop rest
    | [] | [ _ ] -> Ok ()
  in
  loop sorted

let apply_patches contents patches =
  let sorted =
    List.sort
      (fun a b ->
        match Int.compare b.replace_start a.replace_start with
        | 0 -> Int.compare b.replace_end a.replace_end
        | order -> order)
      patches
  in
  List.fold_left
    (fun contents patch ->
      String.sub contents 0 patch.replace_start
      ^ patch.replacement
      ^ String.sub contents patch.replace_end
          (String.length contents - patch.replace_end))
    contents sorted

let resolved_of_patch patch =
  {
    Resolved.selector = Edit.selector patch.edit;
    kind = patch.selected.node.kind;
    range = patch.selected.span.range;
    selected_text = patch.selected.text;
  }

let rec resolve_edits nodes contents file_kind acc = function
  | [] -> Ok (List.rev acc)
  | edit :: edits -> (
      match resolve_edit nodes contents ~file_kind edit with
      | Error error -> Error error
      | Ok patch -> resolve_edits nodes contents file_kind (patch :: acc) edits)

let plan ~path ~file_kind ~contents edits =
  if not (String.is_valid_utf_8 contents) then
    Error (Error.Invalid_text "source contents must be valid UTF-8")
  else if List.is_empty edits then
    Error (Error.Invalid_operation "at least one AST edit is required")
  else
    match parse_file ~path ~file_kind contents with
    | Error error -> Error error
    | Ok parsed -> (
        let nodes = nodes_of_parsed parsed in
        match resolve_edits nodes contents file_kind [] edits with
        | Error error -> Error error
        | Ok patches -> (
            match check_overlaps patches with
            | Error error -> Error error
            | Ok () -> (
                let after_contents = apply_patches contents patches in
                match parse_file ~path ~file_kind after_contents with
                | Error (Error.Parse_error { message; range; phase = _ }) ->
                    Error
                      (Error.Parse_error
                         { phase = "edited source"; message; range })
                | Error error -> Error error
                | Ok _ -> (
                    match
                      Spice_edit.rewrite ~path ~before:contents
                        ~after:after_contents
                    with
                    | Error error -> Error (Error.Edit_error error)
                    | Ok edit ->
                        Ok
                          {
                            Plan.path;
                            file_kind;
                            before_contents = contents;
                            after_contents;
                            edit;
                            resolved = List.map resolved_of_patch patches;
                          }))))

module Output = struct
  type status =
    | Modified of {
        before : Spice_digest.Identity.t;
        after : Spice_digest.Identity.t;
      }
    | Unchanged of Spice_digest.Identity.t

  type t = {
    path : Workspace.Path.t;
    file_kind : file_kind;
    status : status;
    before_contents : string;
    after_contents : string;
    resolved : Resolved.t list;
    edit : Spice_edit.Result.t option;
  }

  let make ~path ~file_kind ~status ~before_contents ~after_contents ~resolved
      ~edit =
    { path; file_kind; status; before_contents; after_contents; resolved; edit }

  let path (t : t) = t.path
  let file_kind t = t.file_kind
  let before_contents t = t.before_contents
  let after_contents t = t.after_contents
  let resolved t = t.resolved

  let receipt t =
    Option.fold ~none:Receipt.empty
      ~some:(fun edit -> Receipt.make edit)
      (t : t).edit

  let identity t =
    match t.status with Modified { after; _ } | Unchanged after -> after

  let operation = function
    | Modified _ -> "modified"
    | Unchanged _ -> "unchanged"

  let before_identity = function
    | Modified { before; _ } ->
        Json.string (Spice_digest.Identity.to_string before)
    | Unchanged _ -> json_null

  let position_json position =
    json_obj
      [
        ("line", Json.int (Spice_ocaml.Position.line position));
        ("column", Json.int (Spice_ocaml.Position.column position));
      ]

  let range_json range =
    json_obj
      [
        ("start", position_json (Spice_ocaml.Range.start range));
        ("end", position_json (Spice_ocaml.Range.end_ range));
      ]

  let resolved_json resolved =
    json_obj
      [
        ("kind", node_kind_json (Resolved.kind resolved));
        ("range", range_json (Resolved.range resolved));
        ("selected_text", Json.string (Resolved.selected_text resolved));
      ]

  let text t =
    Printf.sprintf "%s: %s ast_edits=%d identity=%s\n" (operation t.status)
      (Workspace.Path.display t.path)
      (List.length t.resolved)
      (Spice_digest.Identity.to_string (identity t))

  let json t =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display (t : t).path));
        ("file_kind", Json.string (file_kind_to_string t.file_kind));
        ("operation", Json.string (operation t.status));
        ("identity", Json.string (Spice_digest.Identity.to_string (identity t)));
        ("before_identity", before_identity t.status);
        ("edits", Json.int (List.length t.resolved));
        ("resolved", Json.list (List.map resolved_json t.resolved));
      ]

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let edit_io ~fs ~workspace ~max_bytes () =
  Fs.Edit.io ~fs ~workspace ~max_bytes
    ~remove_error:"ocaml_ast_edit cannot delete files" ()
  |> fst

let failed_edit = Edit_error.failed
let failed_plan error = Tool.Result.failed `Invalid_input (Error.message error)

let stale path =
  Tool.Result.failed `Stale
    (Workspace.Path.display path ^ ": stale file identity")

let interrupted () =
  Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()

let output_of_plan ?edit plan =
  let before_contents = Plan.before_contents plan in
  let after_contents = Plan.after_contents plan in
  let before = file_identity before_contents in
  let after = file_identity after_contents in
  let status =
    if String.equal before_contents after_contents then Output.Unchanged after
    else Output.Modified { before; after }
  in
  Output.make ~path:(Plan.path plan) ~file_kind:(Plan.file_kind plan) ~status
    ~before_contents ~after_contents ~resolved:(Plan.resolved plan) ~edit

let apply ~fs ~workspace ~max_bytes plan =
  if Spice_edit.is_empty (Plan.edit plan) then Ok None
  else
    let io = edit_io ~fs ~workspace ~max_bytes () in
    Spice_edit.apply ~io ~workspace (Plan.edit plan)
    |> Result.map (fun result -> Some result)
    |> Result.map_error (fun error ->
        failed_edit (Spice_edit.Apply_error.error error))

let run_planned ~fs ~workspace ~max_bytes ~cancelled input path contents =
  let before_identity = file_identity contents in
  match Input.if_identity input with
  | Some expected
    when not (Spice_digest.Identity.equal expected before_identity) ->
      stale path
  | None | Some _ -> (
      match
        plan ~path ~file_kind:(Input.file_kind input) ~contents
          (Input.edits input)
      with
      | Error error -> failed_plan error
      | Ok plan -> (
          if cancelled () then interrupted ()
          else
            match apply ~fs ~workspace ~max_bytes plan with
            | Error result -> result
            | Ok edit ->
                Tool.Result.completed ~output:(output_of_plan ?edit plan) ()))

let default_cancelled () = false

let run ~fs ~workspace ?(max_file_bytes = default_max_file_bytes)
    ?(cancelled = default_cancelled) input =
  if max_file_bytes < 0 then invalid_arg "max_file_bytes must be non-negative";
  if cancelled () then interrupted ()
  else
    match Fs.resolve ~workspace (Input.path input) with
    | Error error -> Fs_error.failed ~message:(Fs.Error.message error) error
    | Ok path -> (
        match
          Fs.Edit.read_text ~fs ~workspace ~max_bytes:max_file_bytes path
        with
        | Error error -> failed_edit error
        | Ok contents ->
            run_planned ~fs ~workspace ~max_bytes:max_file_bytes ~cancelled
              input path contents)

let permissions ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ -> []
  | Ok path ->
      let access = Permission.Access.path ~op:`Modify path in
      [ Permission.Request.of_accesses ~source:name [ access ] ]

let tool ~fs ~workspace ?max_file_bytes () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ?max_file_bytes
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
