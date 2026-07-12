(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "search_text"
let default_limit = 100
let max_limit = 1_000
let max_context_lines = 5
let max_line_bytes = 2_000
let max_rg_stdout_bytes = 16 * 1024 * 1024
let max_rg_stderr_bytes = 64 * 1024
let max_rg_timeout_ms = 60_000
let description = Spice_prompts.Tools.search_text

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()

let optional_json_field name value fields =
  match value with None -> fields | Some value -> (name, value) :: fields

let json_to_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> invalid_arg ("could not encode JSON: " ^ message)

module Input = struct
  type case = Sensitive | Insensitive
  type mode = Files | Count | Matches

  type t = {
    pattern : string;
    paths : string list option;
    glob : string option;
    mode : mode;
    case : case;
    context_lines : int option;
    offset : int option;
    limit : int option;
  }

  let mode_to_string = function
    | Files -> "files"
    | Count -> "count"
    | Matches -> "matches"

  let mode_of_string = function
    | "files" -> Files
    | "count" -> Count
    | "matches" -> Matches
    | mode -> invalid_arg ("unknown mode: " ^ mode)

  let validate_path path =
    if String.is_empty path then
      invalid_arg "paths must not contain empty paths";
    if String.contains path '\000' then invalid_arg "paths must not contain NUL"

  let validate_paths = function
    | None -> ()
    | Some [] -> invalid_arg "paths must not be empty"
    | Some paths -> List.iter validate_path paths

  let validate_glob = function
    | None -> ()
    | Some glob ->
        if String.is_empty glob then invalid_arg "glob must not be empty";
        if String.contains glob '\000' then
          invalid_arg "glob must not contain NUL"

  let validate_context mode = function
    | None -> ()
    | Some context_lines ->
        if mode <> Matches then
          invalid_arg "context_lines is valid only in matches mode";
        if context_lines < 0 then
          invalid_arg "context_lines must be non-negative";
        if context_lines > max_context_lines then
          invalid_arg
            ("context_lines must be at most " ^ string_of_int max_context_lines)

  let validate_pagination offset limit =
    begin match offset with
    | Some offset when offset < 1 -> invalid_arg "offset must be at least 1"
    | Some _ | None -> ()
    end;
    match limit with
    | Some limit when limit < 1 -> invalid_arg "limit must be positive"
    | Some limit when limit > max_limit ->
        invalid_arg ("limit must be at most " ^ string_of_int max_limit)
    | Some _ | None -> ()

  let make ?paths ?glob ?(mode = Files) ?(case = Sensitive) ?context_lines
      ?offset ?limit pattern =
    if String.is_empty pattern then invalid_arg "pattern must not be empty";
    if String.contains pattern '\000' then
      invalid_arg "pattern must not contain NUL";
    validate_paths paths;
    validate_glob glob;
    validate_context mode context_lines;
    validate_pagination offset limit;
    { pattern; paths; glob; mode; case; context_lines; offset; limit }

  let make_json pattern paths glob mode case_insensitive context_lines offset
      limit =
    decode_invalid_arg (fun () ->
        let mode = Option.map mode_of_string mode in
        let case =
          match case_insensitive with
          | Some true -> Some Insensitive
          | Some false | None -> None
        in
        make ?paths ?glob ?mode ?case ?context_lines ?offset ?limit pattern)

  let pattern t = t.pattern
  let paths t = t.paths
  let glob t = t.glob
  let mode t = t.mode
  let case t = t.case
  let context_lines t = t.context_lines
  let offset t = t.offset
  let limit t = t.limit

  let to_json t =
    let fields =
      [ ("pattern", Json.string (pattern t)) ]
      |> optional_json_field "paths"
           (Option.map
              (fun paths ->
                Json.list (List.map (fun value -> Json.string value) paths))
              (paths t))
      |> optional_json_field "glob"
           (Option.map (fun value -> Json.string value) (glob t))
      |> optional_json_field "mode"
           (Some (Json.string (mode_to_string (mode t))))
      |> optional_json_field "case_insensitive"
           (Some
              (Json.bool
                 (match case t with Sensitive -> false | Insensitive -> true)))
      |> optional_json_field "context_lines"
           (Option.map (fun value -> Json.int value) (context_lines t))
      |> optional_json_field "offset"
           (Option.map (fun value -> Json.int value) (offset t))
      |> optional_json_field "limit"
           (Option.map (fun value -> Json.int value) (limit t))
    in
    json_obj (List.rev fields)

  let codec =
    Jsont.Object.map ~kind:"search_text input" make_json
    |> Jsont.Object.mem "pattern" Jsont.string ~enc:pattern
    |> Jsont.Object.opt_mem "paths" (Jsont.list Jsont.string) ~enc:paths
    |> Jsont.Object.opt_mem "glob" Jsont.string ~enc:glob
    |> Jsont.Object.opt_mem "mode" Jsont.string ~enc:(fun t ->
        Some (mode_to_string (mode t)))
    |> Jsont.Object.opt_mem "case_insensitive" Jsont.bool ~enc:(fun t ->
        Some (match case t with Sensitive -> false | Insensitive -> true))
    |> Jsont.Object.opt_mem "context_lines" Jsont.int ~enc:context_lines
    |> Jsont.Object.opt_mem "offset" Jsont.int ~enc:offset
    |> Jsont.Object.opt_mem "limit" Jsont.int ~enc:limit
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "pattern",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Ripgrep/Rust regular expression to search for in \
                         UTF-8 text files." );
                  ] );
              ( "paths",
                json_obj
                  [
                    ("type", Json.string "array");
                    ("items", json_obj [ ("type", Json.string "string") ]);
                    ("minItems", Json.int 1);
                    ( "description",
                      Json.string
                        "Workspace-relative or workspace-contained absolute \
                         file or directory roots. Defaults to the workspace \
                         current directory." );
                  ] );
              ( "glob",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Optional file glob filter, for example \"*.ml\" or \
                         \"**/*.ts\"." );
                  ] );
              ( "mode",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "files";
                          Json.string "count";
                          Json.string "matches";
                        ] );
                    ( "description",
                      Json.string
                        "Result mode. files returns paths, count returns \
                         per-file matching-line counts, matches returns line \
                         snippets. Defaults to files." );
                  ] );
              ( "case_insensitive",
                json_obj
                  [
                    ("type", Json.string "boolean");
                    ( "description",
                      Json.string
                        "Use case-insensitive regular-expression matching." );
                  ] );
              ( "context_lines",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ("maximum", Json.int max_context_lines);
                    ( "description",
                      Json.string
                        "Symmetric context lines around matches. Valid only in \
                         matches mode." );
                  ] );
              ( "offset",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "1-based first result entry to return. Defaults to 1."
                    );
                  ] );
              ( "limit",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_limit);
                    ( "description",
                      Json.string
                        "Maximum number of result entries to return. Defaults \
                         to 100." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "pattern" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Output = struct
  type total = Exact of int | Lower_bound of int | Unknown
  type partial_reason = Limit
  type status = Complete | Partial of partial_reason
  type count = { count_path : Workspace.Path.t; matching_lines : int }
  type line_kind = Match | Context
  type skipped_reason = Binary | Invalid_utf8
  type skipped = { skipped_path : Workspace.Path.t; reason : skipped_reason }

  type line = {
    number : int;
    text : string;
    kind : line_kind;
    truncated : bool;
    anchor : Anchor.t option;
  }

  type span = { span_path : Workspace.Path.t; lines : line list }
  type count_result = { files : count list; total_matching_lines : total }

  type result =
    | Files of Workspace.Path.t list
    | Count of count_result
    | Matches of span list

  type t = {
    pattern : string;
    roots : Workspace.Path.t list;
    glob : string option;
    mode : Input.mode;
    case : Input.case;
    context_lines : int;
    result : result;
    page : Input.t Pagination.Page.t;
    skipped : skipped list;
  }

  let make ~pattern ~roots ~glob ~mode ~case ~context_lines ~result ~page
      ~skipped =
    { pattern; roots; glob; mode; case; context_lines; result; page; skipped }

  let pattern t = t.pattern
  let roots t = t.roots
  let glob t = t.glob
  let mode t = t.mode
  let case t = t.case
  let context_lines t = t.context_lines
  let offset t = Pagination.Page.offset t.page
  let limit t = Pagination.Page.limit t.page
  let returned_results t = Pagination.Page.returned t.page

  (* The shared page count maps back to this tool's public precision type. *)
  let total_of_count = function
    | Pagination.Count.Exact n -> Exact n
    | Pagination.Count.Lower_bound n -> Lower_bound n
    | Pagination.Count.Unknown -> Unknown

  let total_results t = total_of_count (Pagination.Page.total t.page)
  let result t = t.result

  let status t =
    if Pagination.Page.is_complete t.page then Complete else Partial Limit

  let next t = Pagination.Page.next t.page
  let skipped t = t.skipped
  let has_more t = not (Pagination.Page.is_complete t.page)

  type render = Plain | Anchored of Anchor.Source.t

  let plain = Plain
  let anchored ?(source = Anchor.Source.deterministic) () = Anchored source

  let anchor_source = function
    | Plain -> Anchor.Source.none
    | Anchored source -> source

  let renders_anchors = function Plain -> false | Anchored _ -> true

  let total_json = function
    | Exact value ->
        json_obj [ ("kind", Json.string "exact"); ("value", Json.int value) ]
    | Lower_bound value ->
        json_obj
          [ ("kind", Json.string "lower_bound"); ("value", Json.int value) ]
    | Unknown -> json_obj [ ("kind", Json.string "unknown") ]

  let total_text = function
    | Exact value -> string_of_int value
    | Lower_bound value -> ">=" ^ string_of_int value
    | Unknown -> "unknown"

  let case_to_string = function
    | Input.Sensitive -> "sensitive"
    | Input.Insensitive -> "insensitive"

  let line_kind_to_string = function Match -> "match" | Context -> "context"

  let skipped_reason_to_string = function
    | Binary -> "binary"
    | Invalid_utf8 -> "invalid_utf8"

  let status_to_string = function
    | Complete -> "complete"
    | Partial Limit -> "partial"

  let count_json (count : count) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display count.count_path));
        ("matching_lines", Json.int count.matching_lines);
      ]

  let line_json line =
    json_obj
      [
        ("number", Json.int line.number);
        ("text", Json.string line.text);
        ("kind", Json.string (line_kind_to_string line.kind));
        ("truncated", Json.bool line.truncated);
        ( "anchor",
          match line.anchor with
          | None -> json_null
          | Some anchor -> Json.string (Anchor.to_string anchor) );
      ]

  let span_json (span : span) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display span.span_path));
        ("lines", Json.list (List.map line_json span.lines));
      ]

  let skipped_json (skipped : skipped) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display skipped.skipped_path));
        ("reason", Json.string (skipped_reason_to_string skipped.reason));
      ]

  let result_json = function
    | Files files ->
        json_obj
          [
            ("kind", Json.string "files");
            ( "files",
              Json.list
                (List.map
                   (fun path -> Json.string (Workspace.Path.display path))
                   files) );
          ]
    | Count count ->
        json_obj
          [
            ("kind", Json.string "count");
            ("files", Json.list (List.map count_json count.files));
            ("total_matching_lines", total_json count.total_matching_lines);
          ]
    | Matches spans ->
        json_obj
          [
            ("kind", Json.string "matches");
            ("spans", Json.list (List.map span_json spans));
          ]

  let json t =
    json_obj
      [
        ("pattern", Json.string (pattern t));
        ( "roots",
          Json.list
            (List.map
               (fun path -> Json.string (Workspace.Path.display path))
               (roots t)) );
        ( "glob",
          match glob t with None -> json_null | Some glob -> Json.string glob );
        ("mode", Json.string (Input.mode_to_string (mode t)));
        ("case", Json.string (case_to_string (case t)));
        ("context_lines", Json.int (context_lines t));
        ("offset", Json.int (offset t));
        ("limit", Json.int (limit t));
        ("returned_results", Json.int (returned_results t));
        ("total_results", total_json (total_results t));
        ("result", result_json (result t));
        ("status", Json.string (status_to_string (status t)));
        ("has_more", Json.bool (has_more t));
        ( "next",
          match next t with
          | None -> json_null
          | Some input -> Input.to_json input );
        ("skipped", Json.list (List.map skipped_json (skipped t)));
        ("skipped_count", Json.int (List.length (skipped t)));
      ]

  let add_header b t =
    Buffer.add_string b "pattern=";
    Buffer.add_string b (json_to_string (Json.string (pattern t)));
    Buffer.add_string b " mode=";
    Buffer.add_string b (Input.mode_to_string (mode t));
    Buffer.add_string b " results=";
    Buffer.add_string b (string_of_int (returned_results t));
    Buffer.add_char b '/';
    Buffer.add_string b (total_text (total_results t));
    Buffer.add_string b " offset=";
    Buffer.add_string b (string_of_int (offset t));
    Buffer.add_string b " limit=";
    Buffer.add_string b (string_of_int (limit t));
    Buffer.add_string b " status=";
    Buffer.add_string b (status_to_string (status t));
    Buffer.add_char b '\n'

  let add_next b t =
    match Pagination.Page.hint ~tool:name ~to_json:Input.to_json t.page with
    | None -> ()
    | Some line ->
        Buffer.add_string b line;
        Buffer.add_char b '\n'

  let add_skipped b t =
    match skipped t with
    | [] -> ()
    | skipped ->
        Buffer.add_string b "skipped:\n";
        List.iter
          (fun (skipped : skipped) ->
            Buffer.add_string b "  ";
            Buffer.add_string b (Workspace.Path.display skipped.skipped_path);
            Buffer.add_string b " reason=";
            Buffer.add_string b (skipped_reason_to_string skipped.reason);
            Buffer.add_char b '\n')
          skipped

  let add_line ~render b line =
    let marker = match line.kind with Match -> ':' | Context -> '-' in
    Buffer.add_string b "  ";
    Buffer.add_string b (string_of_int line.number);
    begin match (renders_anchors render, line.anchor) with
    | true, Some anchor ->
        Buffer.add_string b " #";
        Buffer.add_string b (Anchor.to_string anchor)
    | false, _ | true, None -> ()
    end;
    Buffer.add_char b marker;
    Buffer.add_char b ' ';
    Buffer.add_string b line.text;
    if line.truncated then Buffer.add_string b " [truncated]";
    Buffer.add_char b '\n'

  let text ?(render = Plain) t =
    let b = Buffer.create 512 in
    add_header b t;
    begin match result t with
    | Files [] | Count { files = []; _ } | Matches [] ->
        Buffer.add_string b "No matches\n"
    | Files files ->
        List.iter
          (fun path ->
            Buffer.add_string b (Workspace.Path.display path);
            Buffer.add_char b '\n')
          files
    | Count { files; _ } ->
        List.iter
          (fun (count : count) ->
            Buffer.add_string b (Workspace.Path.display count.count_path);
            Buffer.add_string b " matching_lines=";
            Buffer.add_string b (string_of_int count.matching_lines);
            Buffer.add_char b '\n')
          files
    | Matches spans ->
        List.iter
          (fun span ->
            Buffer.add_string b (Workspace.Path.display span.span_path);
            Buffer.add_char b '\n';
            List.iter (add_line ~render b) span.lines)
          spans
    end;
    add_skipped b t;
    add_next b t;
    Buffer.contents b

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode ?(render = Plain) t =
    Tool.Output.make ~text:(text ~render t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

type search_error =
  | Fs of Fs.Error.t
  | Rg_failed of { invalid_input : bool; message : string }
  | Sandbox_refused of Spice_sandbox.Error.t
  | Timed_out of { timeout_ms : int }
  | Cancelled

let default_cancelled () = false
let vcs_metadata_dirs = [ ".git"; ".svn"; ".hg"; ".bzr"; ".jj"; ".sl" ]
let display_paths paths = List.map Workspace.Path.display paths

let effective_paths input =
  match Input.paths input with None -> [ "." ] | Some paths -> paths

let effective_context input =
  match Input.mode input with
  | Input.Matches -> Option.value (Input.context_lines input) ~default:0
  | Input.Files | Input.Count -> 0

let effective_offset input = Option.value (Input.offset input) ~default:1

let effective_limit input =
  Option.value (Input.limit input) ~default:default_limit

let abs_path path = Spice_path.Abs.to_string (Workspace.Path.abs path)

let root_kind ~fs ~workspace path =
  match Fs.stat ~fs ~workspace ~follow_symlink:false path with
  | Error error -> Error (Fs error)
  | Ok None -> Error (Fs (Fs.Error.Not_found path))
  | Ok (Some stat) -> (
      match stat.Eio.File.Stat.kind with
      | `Regular_file -> (
          match Fs.regular ~fs ~workspace ~follow_symlink:false path with
          | Ok _ -> Ok `Regular_file
          | Error error -> Error (Fs error))
      | `Directory -> (
          match Fs.directory ~fs ~workspace ~follow_symlink:false path with
          | Ok _ -> Ok `Directory
          | Error error -> Error (Fs error))
      | kind ->
          Error
            (Fs
               (Fs.Error.Unexpected_kind
                  { path; expected = Fs.Regular_file; actual = kind })))

let resolve_roots ~fs ~workspace input =
  let rec loop seen acc = function
    | [] -> Ok (List.rev acc)
    | raw :: raws -> (
        match Fs.resolve ~workspace raw with
        | Error error -> Error (Fs error)
        | Ok path -> (
            if Workspace.Path.Set.mem path seen then loop seen acc raws
            else
              match root_kind ~fs ~workspace path with
              | Error _ as error -> error
              | Ok kind ->
                  loop
                    (Workspace.Path.Set.add path seen)
                    ((path, kind) :: acc) raws))
  in
  loop Workspace.Path.Set.empty [] (effective_paths input)

let strip_trailing_newline line =
  let len = String.length line in
  if len > 0 && Char.equal line.[len - 1] '\n' then
    String.sub line 0 (len - 1) |> Text_helpers.strip_trailing_cr
  else Text_helpers.strip_trailing_cr line

let line_text raw =
  let truncated = String.length raw > max_line_bytes in
  if not truncated then (raw, false)
  else (Text_helpers.valid_utf8_prefix raw max_line_bytes, true)

let anchor anchors path number raw =
  Anchor.Source.line anchors ~path ~number ~text:raw

let output_line anchors path kind number raw =
  let raw = strip_trailing_newline raw in
  let rendered_text, truncated = line_text raw in
  {
    Output.number;
    text = rendered_text;
    kind;
    truncated;
    anchor = anchor anchors path number raw;
  }

module Int_map = Map.Make (Int)

let spans_of_lines path lines =
  let bindings = Int_map.bindings lines in
  let finish_span spans current =
    match current with
    | [] -> spans
    | lines ->
        let lines = List.rev lines in
        if List.exists (fun line -> line.Output.kind = Output.Match) lines then
          Output.{ span_path = path; lines } :: spans
        else spans
  in
  let rec loop spans current previous_number = function
    | [] -> List.rev (finish_span spans current)
    | (number, line) :: lines ->
        if previous_number + 1 = number then
          loop spans (line :: current) number lines
        else
          let spans = finish_span spans current in
          loop spans [ line ] number lines
  in
  match bindings with
  | [] -> []
  | (number, line) :: bindings -> loop [] [ line ] number bindings

let result_page input roots ~offset ~limit ~returned ~total =
  let has_more = offset <= total && offset + returned <= total in
  let count = Pagination.Count.Exact total in
  if has_more then
    let paths = display_paths roots in
    let context_lines =
      match Input.mode input with
      | Input.Matches -> Some (effective_context input)
      | Input.Files | Input.Count -> None
    in
    let next =
      Some
        (Input.make ~paths ?glob:(Input.glob input) ~mode:(Input.mode input)
           ~case:(Input.case input) ?context_lines ~offset:(offset + returned)
           ~limit (Input.pattern input))
    in
    Pagination.Page.partial ~returned ~total:count ~offset ~limit ~next
  else Pagination.Page.complete ~returned ~total:count ~offset ~limit

module Rg_event = struct
  type kind = Match | Context

  type t = {
    kind : kind;
    path : Workspace.Path.t;
    line_number : int;
    text : string option;
  }
end

type rg_json_line =
  | Rg_event of Rg_event.t
  | Rg_skipped of Output.skipped
  | Rg_ignore

let json_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_string_field name json =
  match json_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let json_int_field name json =
  match json_field name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (int_of_float value)
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Object _ | Jsont.Array _ )
  | None ->
      None

let rg_text_field json =
  match json_field "text" json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let rg_path ~workspace path_json =
  match rg_text_field path_json with
  | None -> Ok None
  | Some path_text -> (
      match Workspace.resolve_string workspace path_text with
      | Error error -> Error (Fs (Fs.Error.Workspace error))
      | Ok path -> Ok (Some path))

let json_is_not_null = function
  | Jsont.Null _ -> false
  | Jsont.Bool _ | Jsont.Number _ | Jsont.String _ | Jsont.Object _
  | Jsont.Array _ ->
      true

let rg_event_of_json ~workspace json =
  match json_string_field "type" json with
  | Some (("match" | "context") as kind) -> (
      match json_field "data" json with
      | None -> Ok Rg_ignore
      | Some data -> (
          let kind =
            if String.equal kind "match" then Rg_event.Match
            else Rg_event.Context
          in
          match (json_field "path" data, json_field "lines" data) with
          | Some path_json, Some lines_json -> (
              match rg_path ~workspace path_json with
              | Error _ as error -> error
              | Ok None -> Ok Rg_ignore
              | Ok (Some path) -> (
                  match json_int_field "line_number" data with
                  | None -> Ok Rg_ignore
                  | Some line_number ->
                      Ok
                        (Rg_event
                           {
                             Rg_event.kind;
                             path;
                             line_number;
                             text = rg_text_field lines_json;
                           })))
          | (None | Some _), (None | Some _) -> Ok Rg_ignore))
  | Some "end" -> (
      match json_field "data" json with
      | None -> Ok Rg_ignore
      | Some data -> (
          match (json_field "path" data, json_field "binary_offset" data) with
          | Some path_json, Some binary_offset
            when json_is_not_null binary_offset -> (
              match rg_path ~workspace path_json with
              | Error _ as error -> error
              | Ok None -> Ok Rg_ignore
              | Ok (Some path) ->
                  Ok
                    (Rg_skipped Output.{ skipped_path = path; reason = Binary })
              )
          | Some _, Some _ | Some _, None | None, (None | Some _) ->
              Ok Rg_ignore))
  | Some _ | None -> Ok Rg_ignore

let parse_rg_json_line ~workspace line =
  match Jsont_bytesrw.decode_string Jsont.json line with
  | Error message ->
      Error
        (Rg_failed { invalid_input = false; message = "rg JSON: " ^ message })
  | Ok json -> (
      match rg_event_of_json ~workspace json with
      | Ok Rg_ignore
        when String.includes ~affix:"\"binary_offset\":" line
             && not (String.includes ~affix:"\"binary_offset\":null" line) -> (
          match json_field "data" json with
          | Some data -> (
              match json_field "path" data with
              | Some path_json -> (
                  match rg_path ~workspace path_json with
                  | Error _ as error -> error
                  | Ok None -> Ok Rg_ignore
                  | Ok (Some path) ->
                      Ok
                        (Rg_skipped
                           Output.{ skipped_path = path; reason = Binary }))
              | None -> Ok Rg_ignore)
          | None -> Ok Rg_ignore)
      | Ok Rg_ignore -> Ok Rg_ignore
      | Ok (Rg_event _ | Rg_skipped _) as result -> result
      | Error _ as result -> result)

let parse_rg_events ~workspace stdout =
  let add_skipped (skipped : Output.skipped) skipped_paths =
    Workspace.Path.Map.add skipped.Output.skipped_path skipped skipped_paths
  in
  let rec loop skipped_paths events = function
    | [] ->
        let skipped =
          Workspace.Path.Map.bindings skipped_paths
          |> List.map (fun (_, skipped) -> skipped)
        in
        Ok (skipped, List.rev events)
    | "" :: lines -> loop skipped_paths events lines
    | line :: lines -> (
        match parse_rg_json_line ~workspace line with
        | Error _ as error -> error
        | Ok Rg_ignore -> loop skipped_paths events lines
        | Ok (Rg_skipped skipped) ->
            loop (add_skipped skipped skipped_paths) events lines
        | Ok (Rg_event event) -> (
            match event.Rg_event.text with
            | None ->
                loop
                  (add_skipped
                     Output.
                       {
                         skipped_path = event.Rg_event.path;
                         reason = Invalid_utf8;
                       }
                     skipped_paths)
                  events lines
            | Some text when String.contains text '\000' ->
                loop
                  (add_skipped
                     Output.
                       {
                         skipped_path = event.Rg_event.path;
                         reason = Invalid_utf8;
                       }
                     skipped_paths)
                  events lines
            | Some _ -> loop skipped_paths (event :: events) lines))
  in
  loop Workspace.Path.Map.empty [] (String.split_on_char '\n' stdout)

let protected_vcs_globs =
  List.concat_map
    (fun name -> [ "!" ^ name ^ "/**"; "!**/" ^ name ^ "/**" ])
    vcs_metadata_dirs

let rg_args input roots =
  let context = effective_context input in
  let args =
    [
      "rg";
      "--json";
      "--hidden";
      "--no-config";
      "--no-require-git";
      "--no-messages";
      "--color";
      "never";
      "--line-number";
      "--with-filename";
    ]
  in
  let args =
    match Input.case input with
    | Input.Sensitive -> args
    | Input.Insensitive -> args @ [ "--ignore-case" ]
  in
  let args =
    if context = 0 then args else args @ [ "--context"; string_of_int context ]
  in
  let args =
    List.fold_left
      (fun args glob -> args @ [ "--glob"; glob ])
      args protected_vcs_globs
  in
  let args =
    match Input.glob input with
    | None -> args
    | Some glob -> args @ [ "--glob"; glob ]
  in
  args @ [ "--"; Input.pattern input ] @ List.map abs_path roots

let rg_error invalid_input stderr =
  let message = String.trim stderr in
  let message = if String.is_empty message then "ripgrep failed" else message in
  Rg_failed { invalid_input; message }

let is_missing_executable message =
  String.includes ~affix:"No such file or directory" message
  || String.includes ~affix:"ENOENT" message

let run_rg ~sandbox ~workspace ~cancelled input roots =
  let result =
    Process.run_sandboxed ~sandbox ~stdout_limit:max_rg_stdout_bytes
      ~stderr_limit:max_rg_stderr_bytes
      ~cwd:(Workspace.Path.abs (Workspace.cwd workspace))
      ~timeout_ms:max_rg_timeout_ms ~cancelled
      (rg_args input roots)
  in
  match result.Process.status with
  | Process.Cancelled -> Error Cancelled
  | Process.Refused error -> Error (Sandbox_refused error)
  | Process.Timed_out { timeout_ms } -> Error (Timed_out { timeout_ms })
  | Process.Failed message ->
      let message =
        if is_missing_executable message then
          "ripgrep executable not found; search_text requires rg in PATH"
        else message
      in
      Error (Rg_failed { invalid_input = false; message })
  | Process.Output_exceeded stream ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message = "ripgrep " ^ stream ^ " exceeded internal output limit";
           })
  | Process.Signaled signal ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message = "ripgrep terminated by signal " ^ string_of_int signal;
           })
  | Process.Exited (0 | 1) -> parse_rg_events ~workspace result.Process.stdout
  | Process.Exited 2 -> Error (rg_error true result.Process.stderr)
  | Process.Exited code ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message =
               "ripgrep exited with status " ^ string_of_int code ^ ": "
               ^ String.trim result.Process.stderr;
           })

let skipped_path_set (skipped : Output.skipped list) =
  List.fold_left
    (fun paths (skipped : Output.skipped) ->
      Workspace.Path.Set.add skipped.Output.skipped_path paths)
    Workspace.Path.Set.empty skipped

let filtered_events (skipped : Output.skipped list) events =
  let skipped_paths = skipped_path_set skipped in
  List.filter
    (fun event ->
      not (Workspace.Path.Set.mem event.Rg_event.path skipped_paths))
    events

let sorted_unique_paths paths =
  paths
  |> List.fold_left
       (fun set path -> Workspace.Path.Set.add path set)
       Workspace.Path.Set.empty
  |> Workspace.Path.Set.elements

let event_text event = Option.value event.Rg_event.text ~default:""

let search_files (skipped : Output.skipped list) events =
  events |> filtered_events skipped
  |> List.filter_map (fun event ->
      match event.Rg_event.kind with
      | Rg_event.Match -> Some event.Rg_event.path
      | Rg_event.Context -> None)
  |> sorted_unique_paths

let search_counts (skipped : Output.skipped list) events =
  let skipped_paths = skipped_path_set skipped in
  let add counts event =
    if Workspace.Path.Set.mem event.Rg_event.path skipped_paths then counts
    else
      match event.Rg_event.kind with
      | Rg_event.Context -> counts
      | Rg_event.Match ->
          let current =
            Option.value
              (Workspace.Path.Map.find_opt event.Rg_event.path counts)
              ~default:0
          in
          Workspace.Path.Map.add event.Rg_event.path (current + 1) counts
  in
  let counts = List.fold_left add Workspace.Path.Map.empty events in
  Workspace.Path.Map.bindings counts
  |> List.map (fun (path, matching_lines) ->
      Output.{ count_path = path; matching_lines })

let event_order left right =
  let path = Workspace.Path.compare left.Rg_event.path right.Rg_event.path in
  if path <> 0 then path
  else
    let line =
      Int.compare left.Rg_event.line_number right.Rg_event.line_number
    in
    if line <> 0 then line
    else
      match (left.Rg_event.kind, right.Rg_event.kind) with
      | Rg_event.Match, Rg_event.Context -> -1
      | Rg_event.Context, Rg_event.Match -> 1
      | Rg_event.Match, Rg_event.Match | Rg_event.Context, Rg_event.Context -> 0

let matching_events (skipped : Output.skipped list) events =
  events |> filtered_events skipped
  |> List.filter (fun event -> event.Rg_event.kind = Rg_event.Match)
  |> List.sort event_order

let add_span_line lines line =
  match Int_map.find_opt line.Output.number lines with
  | Some existing when existing.Output.kind = Output.Match -> lines
  | _ -> Int_map.add line.Output.number line lines

let context_for_page_matches ~context page_matches event =
  context > 0
  && event.Rg_event.kind = Rg_event.Context
  && List.exists
       (fun match_event ->
         Workspace.Path.equal event.Rg_event.path match_event.Rg_event.path
         && abs (event.Rg_event.line_number - match_event.Rg_event.line_number)
            <= context)
       page_matches

let search_matches anchors (skipped : Output.skipped list) events ~context
    ~offset ~limit =
  let matches = matching_events skipped events in
  let total = List.length matches in
  let page_matches = matches |> List.drop (offset - 1) |> List.take limit in
  let page_match_keys =
    List.fold_left
      (fun keys event ->
        (event.Rg_event.path, event.Rg_event.line_number) :: keys)
      [] page_matches
  in
  let is_page_match event =
    List.exists
      (fun (path, line_number) ->
        Workspace.Path.equal path event.Rg_event.path
        && Int.equal line_number event.Rg_event.line_number)
      page_match_keys
  in
  let add_event spans event =
    let include_event =
      is_page_match event
      || context_for_page_matches ~context page_matches event
    in
    if not include_event then spans
    else
      let kind =
        match event.Rg_event.kind with
        | Rg_event.Match -> Output.Match
        | Rg_event.Context -> Output.Context
      in
      let line =
        output_line anchors event.Rg_event.path kind event.Rg_event.line_number
          (event_text event)
      in
      let lines =
        Option.value
          (Workspace.Path.Map.find_opt event.Rg_event.path spans)
          ~default:Int_map.empty
      in
      Workspace.Path.Map.add event.Rg_event.path (add_span_line lines line)
        spans
  in
  let spans =
    events |> filtered_events skipped |> List.sort event_order
    |> List.fold_left add_event Workspace.Path.Map.empty
    |> Workspace.Path.Map.bindings
    |> List.concat_map (fun (path, lines) -> spans_of_lines path lines)
  in
  (spans, total, List.length page_matches)

let output_files input roots ~skipped files =
  let offset = effective_offset input in
  let limit = effective_limit input in
  let total = List.length files in
  let returned = files |> List.drop (offset - 1) |> List.take limit in
  let returned_results = List.length returned in
  let page =
    result_page input roots ~offset ~limit ~returned:returned_results ~total
  in
  Output.make ~pattern:(Input.pattern input) ~roots ~glob:(Input.glob input)
    ~mode:(Input.mode input) ~case:(Input.case input)
    ~context_lines:(effective_context input) ~result:(Output.Files returned)
    ~page ~skipped

let output_count input roots ~skipped counts total_matching_lines =
  let offset = effective_offset input in
  let limit = effective_limit input in
  let total = List.length counts in
  let returned = counts |> List.drop (offset - 1) |> List.take limit in
  let returned_results = List.length returned in
  let page =
    result_page input roots ~offset ~limit ~returned:returned_results ~total
  in
  Output.make ~pattern:(Input.pattern input) ~roots ~glob:(Input.glob input)
    ~mode:(Input.mode input) ~case:(Input.case input)
    ~context_lines:(effective_context input)
    ~result:
      (Output.Count
         {
           Output.files = returned;
           Output.total_matching_lines = Output.Exact total_matching_lines;
         })
    ~page ~skipped

let output_matches input roots ~skipped spans total returned =
  let offset = effective_offset input in
  let limit = effective_limit input in
  let page = result_page input roots ~offset ~limit ~returned ~total in
  Output.make ~pattern:(Input.pattern input) ~roots ~glob:(Input.glob input)
    ~mode:(Input.mode input) ~case:(Input.case input)
    ~context_lines:(effective_context input) ~result:(Output.Matches spans)
    ~page ~skipped

let error_kind = function
  | Fs error -> Fs_error.failure error
  | Rg_failed { invalid_input; _ } ->
      if invalid_input then `Invalid_input else `Failed
  | Sandbox_refused _ -> `Unavailable
  | Timed_out _ -> `Timed_out
  | Cancelled -> `Failed

let error_message = function
  | Fs (Fs.Error.Workspace error) -> Workspace.Resolve_error.message error
  | Fs (Fs.Error.Not_found path) ->
      Workspace.Path.display path ^ ": path does not exist"
  | Fs (Fs.Error.Escapes_workspace path) ->
      Workspace.Path.display path ^ ": path resolves outside workspace"
  | Fs (Fs.Error.Unexpected_kind { path; actual = `Symbolic_link; _ }) ->
      Workspace.Path.display path ^ ": symlink search roots are not supported"
  | Fs (Fs.Error.Unexpected_kind { path; _ }) ->
      Workspace.Path.display path ^ ": expected a regular file or directory"
  | Fs (Fs.Error.Io (None, _)) -> "filesystem I/O error"
  | Fs (Fs.Error.Io (Some path, _)) ->
      Workspace.Path.display path ^ ": filesystem I/O error"
  | Rg_failed { message; _ } -> message
  | Sandbox_refused error -> Spice_sandbox.Error.message error
  | Timed_out { timeout_ms } ->
      "ripgrep timed out after " ^ string_of_int timeout_ms ^ "ms"
  | Cancelled -> "tool call cancelled"

let failed error = Tool.Result.failed (error_kind error) (error_message error)

let permissions ~workspace input =
  let rec loop acc = function
    | [] -> List.rev acc
    | raw :: raws -> (
        match Workspace.resolve_string workspace raw with
        | Error _ -> loop acc raws
        | Ok path ->
            let request =
              Permission.Request.of_accesses ~source:name
                [ Permission.Access.path ~op:`Read path ]
            in
            loop (request :: acc) raws)
  in
  loop [] (effective_paths input)

let run ~sandbox ~fs ~workspace ?(anchors = Anchor.Source.deterministic)
    ?(cancelled = default_cancelled) input =
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match resolve_roots ~fs ~workspace input with
    | Error Cancelled ->
        Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
    | Error ((Fs _ | Rg_failed _ | Sandbox_refused _ | Timed_out _) as error) ->
        failed error
    | Ok roots -> (
        let root_paths = List.map fst roots in
        match run_rg ~sandbox ~workspace ~cancelled input root_paths with
        | Error Cancelled ->
            Tool.Result.interrupted ~reason:"tool call cancelled"
              ~cancelled:true ()
        | Error ((Fs _ | Rg_failed _ | Sandbox_refused _ | Timed_out _) as error)
          -> failed error
        | Ok (skipped, events) -> (
            match Input.mode input with
            | Input.Files ->
                let files = search_files skipped events in
                Tool.Result.completed
                  ~output:(output_files input root_paths ~skipped files)
                  ()
            | Input.Count ->
                let counts = search_counts skipped events in
                let total_matching_lines =
                  List.fold_left
                    (fun total (count : Output.count) ->
                      total + count.Output.matching_lines)
                    0 counts
                in
                Tool.Result.completed
                  ~output:
                    (output_count input root_paths ~skipped counts
                       total_matching_lines)
                  ()
            | Input.Matches ->
                let context = effective_context input in
                let offset = effective_offset input in
                let limit = effective_limit input in
                let spans, total, returned =
                  search_matches anchors skipped events ~context ~offset ~limit
                in
                Tool.Result.completed
                  ~output:
                    (output_matches input root_paths ~skipped spans total
                       returned)
                  ()))

let tool ~sandbox ~fs ~workspace ?(render = Output.plain) () =
  let anchors = Output.anchor_source render in
  Tool.make ~name ~description ~input:Input.contract
    ~output:(Output.encode ~render)
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~sandbox ~fs ~workspace ~anchors
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
