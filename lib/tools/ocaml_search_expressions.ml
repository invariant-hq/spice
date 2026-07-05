(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Ocaml = Spice_ocaml
module Grep = Spice_ocaml_grep

let name = "ocaml_search_expressions"

(* Half of {!Ocaml_find_references}'s default page: each finding carries its
   source snippet, so a page of findings is heavier than a page of one-line
   references. [max_limit] agrees across the family. *)
let default_limit = 100
let max_limit = 1_000
let max_source_bytes = 8 * 1024 * 1024
let max_line_bytes = 2_000
let description = Spice_prompts.Tools.ocaml_search_expressions

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
  type t = {
    pattern : string;
    paths : string list option;
    offset : int option;
    limit : int option;
  }

  let validate_path path =
    if String.is_empty path then
      invalid_arg "paths must not contain empty paths";
    if String.contains path '\000' then invalid_arg "paths must not contain NUL"

  let validate_paths = function
    | None -> ()
    | Some [] -> invalid_arg "paths must not be empty"
    | Some paths -> List.iter validate_path paths

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

  let make ?paths ?offset ?limit pattern =
    if String.is_empty pattern then invalid_arg "pattern must not be empty";
    if String.contains pattern '\000' then
      invalid_arg "pattern must not contain NUL";
    validate_paths paths;
    validate_pagination offset limit;
    { pattern; paths; offset; limit }

  let make_json pattern paths offset limit =
    decode_invalid_arg (fun () -> make ?paths ?offset ?limit pattern)

  let pattern t = t.pattern
  let paths t = t.paths
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
      |> optional_json_field "offset"
           (Option.map (fun value -> Json.int value) (offset t))
      |> optional_json_field "limit"
           (Option.map (fun value -> Json.int value) (limit t))
    in
    json_obj (List.rev fields)

  let codec =
    Jsont.Object.map ~kind:"ocaml_search_expressions input" make_json
    |> Jsont.Object.mem "pattern" Jsont.string ~enc:pattern
    |> Jsont.Object.opt_mem "paths" (Jsont.list Jsont.string) ~enc:paths
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
                        "OCaml expression pattern. __ matches any expression, \
                         __1/__2 are unification metavariables, f ?arg:PRESENT \
                         / f ?arg:MISSING constrain optional arguments, and \
                         match/record clauses match as sets." );
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
              ( "offset",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "1-based first finding to return. Defaults to 1." );
                  ] );
              ( "limit",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_limit);
                    ( "description",
                      Json.string
                        "Maximum number of findings to return. Defaults to 100."
                    );
                  ] );
            ] );
        ("required", Json.list [ Json.string "pattern" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

let input_text input = json_to_string (Input.to_json input)

module Output = struct
  type partial_reason = Limit
  type status = Complete | Partial of partial_reason

  type skipped_reason =
    | Binary
    | Invalid_utf8
    | Too_large
    | Syntax_error of string
    | Read_error of string

  type skipped = { skipped_path : Workspace.Path.t; reason : skipped_reason }

  type line = {
    number : int;
    text : string;
    truncated : bool;
    anchor : Anchor.t option;
  }

  type finding = { location : Ocaml.Location.t; lines : line list }

  type t = {
    pattern : string;
    roots : Workspace.Path.t list;
    offset : int;
    limit : int;
    returned_results : int;
    total_results : int;
    findings : finding list;
    status : status;
    next : Input.t option;
    skipped : skipped list;
    searched_files : int;
  }

  let make ~pattern ~roots ~offset ~limit ~returned_results ~total_results
      ~findings ~status ~next ~skipped ~searched_files =
    {
      pattern;
      roots;
      offset;
      limit;
      returned_results;
      total_results;
      findings;
      status;
      next;
      skipped;
      searched_files;
    }

  let pattern t = t.pattern
  let roots t = t.roots
  let offset t = t.offset
  let limit t = t.limit
  let returned_results t = t.returned_results
  let total_results t = t.total_results
  let findings t = t.findings
  let status t = t.status
  let next t = t.next
  let skipped t = t.skipped
  let searched_files t = t.searched_files
  let has_more t = match t.status with Complete -> false | Partial _ -> true

  type render = Plain | Anchored of Anchor.Source.t

  let plain = Plain
  let anchored ?(source = Anchor.Source.deterministic) () = Anchored source

  let anchor_source = function
    | Plain -> Anchor.Source.none
    | Anchored source -> source

  let renders_anchors = function Plain -> false | Anchored _ -> true

  let status_to_string = function
    | Complete -> "complete"
    | Partial Limit -> "partial"

  let skipped_reason_label = function
    | Binary -> "binary"
    | Invalid_utf8 -> "invalid_utf8"
    | Too_large -> "too_large"
    | Syntax_error _ -> "syntax_error"
    | Read_error _ -> "read_error"

  let skipped_reason_message = function
    | Binary | Invalid_utf8 | Too_large -> None
    | Syntax_error message | Read_error message -> Some message

  let line_json line =
    json_obj
      [
        ("number", Json.int line.number);
        ("text", Json.string line.text);
        ("truncated", Json.bool line.truncated);
        ( "anchor",
          match line.anchor with
          | None -> json_null
          | Some anchor -> Json.string (Anchor.to_string anchor) );
      ]

  let finding_json (finding : finding) =
    let range = Ocaml.Location.range finding.location in
    let start = Ocaml.Range.start range in
    let end_ = Ocaml.Range.end_ range in
    json_obj
      [
        ( "path",
          Json.string
            (Workspace.Path.display (Ocaml.Location.path finding.location)) );
        ("start_line", Json.int (Ocaml.Position.line start));
        ("start_column", Json.int (Ocaml.Position.column start));
        ("end_line", Json.int (Ocaml.Position.line end_));
        ("end_column", Json.int (Ocaml.Position.column end_));
        ("lines", Json.list (List.map line_json finding.lines));
      ]

  let skipped_json (skipped : skipped) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display skipped.skipped_path));
        ("reason", Json.string (skipped_reason_label skipped.reason));
        ( "message",
          match skipped_reason_message skipped.reason with
          | None -> json_null
          | Some message -> Json.string message );
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
        ("offset", Json.int (offset t));
        ("limit", Json.int (limit t));
        ("returned_results", Json.int (returned_results t));
        ("total_results", Json.int (total_results t));
        ("findings", Json.list (List.map finding_json (findings t)));
        ("status", Json.string (status_to_string (status t)));
        ("has_more", Json.bool (has_more t));
        ( "next",
          match next t with
          | None -> json_null
          | Some input -> Input.to_json input );
        ("searched_files", Json.int (searched_files t));
        ("skipped", Json.list (List.map skipped_json (skipped t)));
        ("skipped_count", Json.int (List.length (skipped t)));
      ]

  let add_header b t =
    Buffer.add_string b "ocaml_search_expressions pattern=";
    Buffer.add_string b (json_to_string (Json.string (pattern t)));
    Buffer.add_string b " results=";
    Buffer.add_string b (string_of_int (returned_results t));
    Buffer.add_char b '/';
    Buffer.add_string b (string_of_int (total_results t));
    Buffer.add_string b " offset=";
    Buffer.add_string b (string_of_int (offset t));
    Buffer.add_string b " limit=";
    Buffer.add_string b (string_of_int (limit t));
    Buffer.add_string b " status=";
    Buffer.add_string b (status_to_string (status t));
    Buffer.add_string b " searched_files=";
    Buffer.add_string b (string_of_int (searched_files t));
    Buffer.add_char b '\n'

  let add_line ~render b line =
    Buffer.add_string b "  ";
    Buffer.add_string b (string_of_int line.number);
    begin match (renders_anchors render, line.anchor) with
    | true, Some anchor ->
        Buffer.add_string b " #";
        Buffer.add_string b (Anchor.to_string anchor)
    | false, _ | true, None -> ()
    end;
    Buffer.add_string b ": ";
    Buffer.add_string b line.text;
    if line.truncated then Buffer.add_string b " [truncated]";
    Buffer.add_char b '\n'

  let add_finding ~render b (finding : finding) =
    Buffer.add_string b
      (Format.asprintf "%a" Ocaml.Location.pp finding.location);
    Buffer.add_char b '\n';
    List.iter (add_line ~render b) finding.lines

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
            Buffer.add_string b (skipped_reason_label skipped.reason);
            begin match skipped_reason_message skipped.reason with
            | None -> ()
            | Some message ->
                Buffer.add_char b ' ';
                Buffer.add_string b message
            end;
            Buffer.add_char b '\n')
          skipped

  let add_next b t =
    match next t with
    | None -> ()
    | Some input ->
        Buffer.add_string b "next: ocaml_search_expressions ";
        Buffer.add_string b (input_text input);
        Buffer.add_char b '\n'

  let text ?(render = Plain) t =
    let b = Buffer.create 512 in
    add_header b t;
    begin match findings t with
    | [] -> Buffer.add_string b "No matches\n"
    | findings -> List.iter (add_finding ~render b) findings
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

type search_error = Fs of Fs.Error.t | Enumerate of string | Cancelled

let default_cancelled () = false
let display_paths paths = List.map Workspace.Path.display paths

let effective_paths input =
  match Input.paths input with None -> [ "." ] | Some paths -> paths

let effective_offset input = Option.value (Input.offset input) ~default:1

let effective_limit input =
  Option.value (Input.limit input) ~default:default_limit

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

(* Candidate .ml files come from the Glob tool so ignore-file and VCS
   metadata semantics stay identical to the other search tools. *)
let glob_page ~fs ~workspace ~cancelled input =
  let result = Glob.run ~fs ~workspace ~cancelled input in
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | Some output -> Ok (Glob.Output.files output, Glob.Output.next output)
      | None -> Error (Enumerate "file enumeration returned no output"))
  | Tool.Result.Failed { message; _ } -> Error (Enumerate message)
  | Tool.Result.Interrupted _ -> Error Cancelled

let enumerate_root ~fs ~workspace ~cancelled (path, kind) =
  match kind with
  | `Regular_file -> Ok [ path ]
  | `Directory ->
      let rec loop acc input =
        match glob_page ~fs ~workspace ~cancelled input with
        | Error _ as error -> error
        | Ok (files, next) -> (
            let acc = List.rev_append files acc in
            match next with
            | None -> Ok (List.rev acc)
            | Some next -> loop acc next)
      in
      loop []
        (Glob.Input.make
           ~path:(Workspace.Path.display path)
           ~limit:Glob.max_limit "**/*.ml")

let enumerate_candidates ~fs ~workspace ~cancelled roots =
  let rec loop seen acc = function
    | [] -> Ok (List.rev acc)
    | root :: roots -> (
        match enumerate_root ~fs ~workspace ~cancelled root with
        | Error _ as error -> error
        | Ok files ->
            let seen, acc =
              List.fold_left
                (fun (seen, acc) file ->
                  if Workspace.Path.Set.mem file seen then (seen, acc)
                  else (Workspace.Path.Set.add file seen, file :: acc))
                (seen, acc) files
            in
            loop seen acc roots)
  in
  loop Workspace.Path.Set.empty [] roots

let read_source ~fs ~workspace path =
  match Fs.regular ~fs ~workspace ~follow_symlink:false path with
  | Error error -> Error (Output.Read_error (Fs.Error.message error))
  | Ok stat -> (
      let size = Optint.Int63.to_int64 stat.Eio.File.Stat.size in
      if Int64.compare size (Int64.of_int max_source_bytes) > 0 then
        Error Output.Too_large
      else
        match Fs.load_regular ~fs ~workspace ~follow_symlink:false path with
        | Error error -> Error (Output.Read_error (Fs.Error.message error))
        | Ok contents ->
            if Text_helpers.looks_binary contents then Error Output.Binary
            else if not (String.is_valid_utf_8 contents) then
              Error Output.Invalid_utf8
            else Ok contents)

let bounded_line raw =
  let truncated = String.length raw > max_line_bytes in
  if not truncated then (raw, false)
  else (Text_helpers.valid_utf8_prefix raw max_line_bytes, true)

let finding_of_location anchors source_lines path location =
  let range = Ocaml.Location.range location in
  let start_line = Ocaml.Position.line (Ocaml.Range.start range) in
  let end_line = Ocaml.Position.line (Ocaml.Range.end_ range) in
  let count = Array.length source_lines in
  let first = max 1 (min count start_line) in
  let last = max first (min count end_line) in
  let line number =
    let raw = Text_helpers.strip_trailing_cr source_lines.(number - 1) in
    let text, truncated = bounded_line raw in
    {
      Output.number;
      text;
      truncated;
      anchor = Anchor.Source.line anchors ~path ~number ~text:raw;
    }
  in
  {
    Output.location;
    lines = List.init (last - first + 1) (fun k -> line (first + k));
  }

let search_file ~fs ~workspace ~anchors pattern path =
  match read_source ~fs ~workspace path with
  | Error reason -> Error { Output.skipped_path = path; reason }
  | Ok source -> (
      let filename = Workspace.Path.display path in
      match Grep.parse_implementation ~filename source with
      | Error message ->
          Error
            { Output.skipped_path = path; reason = Output.Syntax_error message }
      | Ok structure -> (
          match Grep.search pattern ~path structure with
          | [] -> Ok []
          | locations ->
              let source_lines =
                Array.of_list (String.split_on_char '\n' source)
              in
              Ok
                (List.map
                   (finding_of_location anchors source_lines path)
                   locations)))

let error_kind = function
  | Fs error -> Fs_error.failure error
  | Enumerate _ -> `Failed
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
  | Enumerate message -> "file enumeration failed: " ^ message
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

let compare_findings (a : Output.finding) (b : Output.finding) =
  Ocaml.Location.compare a.Output.location b.Output.location

let assemble input roots ~findings ~skipped ~searched_files =
  let findings = List.sort compare_findings findings in
  let total = List.length findings in
  let offset = effective_offset input in
  let limit = effective_limit input in
  let page = findings |> List.drop (offset - 1) |> List.take limit in
  let returned = List.length page in
  let has_more = offset <= total && offset + returned <= total in
  let status =
    if has_more then Output.Partial Output.Limit else Output.Complete
  in
  let next =
    if has_more then
      Some
        (Input.make ~paths:(display_paths roots) ~offset:(offset + returned)
           ~limit (Input.pattern input))
    else None
  in
  Output.make ~pattern:(Input.pattern input) ~roots ~offset ~limit
    ~returned_results:returned ~total_results:total ~findings:page ~status ~next
    ~skipped ~searched_files

let run ~fs ~workspace ?(anchors = Anchor.Source.deterministic)
    ?(cancelled = default_cancelled) input =
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Grep.Pattern.parse (Input.pattern input) with
    | Error error ->
        Tool.Result.failed `Invalid_input (Grep.Pattern.error_message error)
    | Ok pattern -> (
        match resolve_roots ~fs ~workspace input with
        | Error error -> failed error
        | Ok roots -> (
            let root_paths = List.map fst roots in
            match enumerate_candidates ~fs ~workspace ~cancelled roots with
            | Error Cancelled ->
                Tool.Result.interrupted ~reason:"tool call cancelled"
                  ~cancelled:true ()
            | Error ((Fs _ | Enumerate _) as error) -> failed error
            | Ok candidates ->
                let rec loop findings skipped searched = function
                  | [] ->
                      Tool.Result.completed
                        ~output:
                          (assemble input root_paths ~findings
                             ~skipped:(List.rev skipped)
                             ~searched_files:searched)
                        ()
                  | path :: paths -> (
                      if cancelled () then
                        Tool.Result.interrupted ~reason:"tool call cancelled"
                          ~cancelled:true ()
                      else
                        match
                          search_file ~fs ~workspace ~anchors pattern path
                        with
                        | Error skip ->
                            loop findings (skip :: skipped) searched paths
                        | Ok file_findings ->
                            loop
                              (List.rev_append file_findings findings)
                              skipped (searched + 1) paths)
                in
                loop [] [] 0 candidates))

let tool ~fs ~workspace ?(render = Output.plain) () =
  let anchors = Output.anchor_source render in
  Tool.make ~name ~description ~input:Input.contract
    ~output:(Output.encode ~render)
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ~anchors
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
