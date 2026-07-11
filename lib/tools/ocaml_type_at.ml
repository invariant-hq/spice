(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Ocaml = Spice_ocaml

let name = "ocaml_type_at"
let description = Spice_prompts.Tools.ocaml_type_at
let default_program = Ocaml_merlin.default_program
let default_max_enclosings = 1
let max_enclosings_limit = 8
let max_verbosity = 3

(* Fixed so Merlin's type wrapping is deterministic regardless of terminal. *)
let printer_width = 80

(* Per-frame and per-doc output budgets, cut on a UTF-8 boundary. *)
let max_type_bytes = 4 * 1024
let max_doc_bytes = 8 * 1024
let max_source_bytes = 8 * 1024 * 1024

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let truncate_utf8 ~max_bytes s =
  if String.length s <= max_bytes then (s, false)
  else (Text_helpers.valid_utf8_prefix s max_bytes, true)

module Input = struct
  type t = {
    path : string;
    position : Ocaml.Position.t;
    max_enclosings : int;
    verbosity : int;
    documentation : bool;
  }

  let make ?(max_enclosings = default_max_enclosings) ?(verbosity = 0)
      ?(documentation = false) ~path ~line ~column () =
    if String.is_empty path then invalid_arg "path must not be empty";
    if line < 1 then invalid_arg "line must be at least 1";
    if column < 0 then invalid_arg "column must be non-negative";
    if max_enclosings < 1 then invalid_arg "max_enclosings must be at least 1";
    if max_enclosings > max_enclosings_limit then
      invalid_arg
        (Printf.sprintf "max_enclosings must be at most %d" max_enclosings_limit);
    if verbosity < 0 then invalid_arg "verbosity must be non-negative";
    if verbosity > max_verbosity then
      invalid_arg (Printf.sprintf "verbosity must be at most %d" max_verbosity);
    let position = Ocaml.Position.make ~line ~column in
    { path; position; max_enclosings; verbosity; documentation }

  let path t = t.path
  let position t = t.position
  let max_enclosings t = t.max_enclosings
  let verbosity t = t.verbosity
  let documentation t = t.documentation
  let line t = Ocaml.Position.line t.position
  let column t = Ocaml.Position.column t.position

  let make_from_json path line column max_enclosings verbosity documentation =
    decode_invalid_arg (fun () ->
        let max_enclosings =
          Option.value ~default:default_max_enclosings max_enclosings
        in
        let verbosity = Option.value ~default:0 verbosity in
        let documentation = Option.value ~default:false documentation in
        make ~max_enclosings ~verbosity ~documentation ~path ~line ~column ())

  let codec =
    Jsont.Object.map ~kind:"ocaml_type_at input" make_from_json
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.mem "line" Jsont.int ~enc:line
    |> Jsont.Object.mem "column" Jsont.int ~enc:column
    |> Jsont.Object.opt_mem "max_enclosings" Jsont.int ~enc:(fun t ->
        if max_enclosings t = default_max_enclosings then None
        else Some (max_enclosings t))
    |> Jsont.Object.opt_mem "verbosity" Jsont.int ~enc:(fun t ->
        if verbosity t = 0 then None else Some (verbosity t))
    |> Jsont.Object.opt_mem "documentation" Jsont.bool ~enc:(fun t ->
        if documentation t then Some true else None)
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
                      Json.string "1-based source line of the cursor." );
                  ] );
              ( "column",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ( "description",
                      Json.string
                        "0-based byte column in the source line, matching \
                         OCaml/Merlin locations and read_file." );
                  ] );
              ( "max_enclosings",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_enclosings_limit);
                    ( "description",
                      Json.string
                        "Number of enclosing type frames to return, \
                         innermost-first. Each frame past the first costs a \
                         full Merlin re-type, so the cap is deliberately low. \
                         Defaults to 1." );
                  ] );
              ( "verbosity",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ("maximum", Json.int max_verbosity);
                    ( "description",
                      Json.string
                        "Merlin alias/module-type expansion depth. Raise this \
                         to unfold an unhelpful type alias. Defaults to 0." );
                  ] );
              ( "documentation",
                json_obj
                  [
                    ("type", Json.string "boolean");
                    ( "description",
                      Json.string
                        "Also fetch the entity's odoc comment via Merlin \
                         document. Defaults to false." );
                  ] );
            ] );
        ( "required",
          Json.list
            [ Json.string "path"; Json.string "line"; Json.string "column" ] );
        ("additionalProperties", Json.bool false);
      ]

  let to_json t =
    json_obj
      ([
         ("path", Json.string (path t));
         ("line", Json.int (line t));
         ("column", Json.int (column t));
       ]
      @ (if max_enclosings t = default_max_enclosings then []
         else [ ("max_enclosings", Json.int (max_enclosings t)) ])
      @ (if verbosity t = 0 then []
         else [ ("verbosity", Json.int (verbosity t)) ])
      @ if documentation t then [ ("documentation", Json.bool true) ] else [])

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Frame = struct
  type t = {
    location : Ocaml.Location.t;
    type_string : string;
    truncated : bool;
  }

  let make ~location ~type_string ~truncated =
    { location; type_string; truncated }

  let location t = t.location
  let type_string t = t.type_string
  let truncated t = t.truncated

  let compare a b =
    match Ocaml.Location.compare a.location b.location with
    | 0 -> (
        match String.compare a.type_string b.type_string with
        | 0 -> Bool.compare a.truncated b.truncated
        | n -> n)
    | n -> n

  let equal a b = compare a b = 0
end

module Documentation = struct
  type t =
    | Not_requested
    | Not_available of string
    | Available of { text : string; truncated : bool }

  let rank = function
    | Not_requested -> 0
    | Not_available _ -> 1
    | Available _ -> 2

  let compare a b =
    match (a, b) with
    | Not_requested, Not_requested -> 0
    | Not_available a, Not_available b -> String.compare a b
    | Available a, Available b -> (
        match String.compare a.text b.text with
        | 0 -> Bool.compare a.truncated b.truncated
        | n -> n)
    | _ -> Int.compare (rank a) (rank b)

  let equal a b = compare a b = 0
end

module Output = struct
  type t = {
    query : Input.t;
    path : Workspace.Path.t;
    frames : Frame.t list;
    documentation : Documentation.t;
    verbosity : int;
    backend : string;
  }

  let make ~query ~path ~frames ~documentation ~verbosity ~backend =
    { query; path; frames; documentation; verbosity; backend }

  let query t = t.query
  let path t = t.path
  let frames t = t.frames
  let innermost t = List.hd t.frames
  let documentation t = t.documentation
  let verbosity t = t.verbosity
  let backend t = t.backend
  let type_id : t Type.Id.t = Type.Id.make ()

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

  let frame_json frame =
    let location = Frame.location frame in
    json_obj
      [
        ( "path",
          Json.string (Workspace.Path.display (Ocaml.Location.path location)) );
        ("range", range_json (Ocaml.Location.range location));
        ("type", Json.string (Frame.type_string frame));
        ("truncated", Json.bool (Frame.truncated frame));
      ]

  let documentation_json = function
    | Documentation.Not_requested ->
        json_obj [ ("status", Json.string "not_requested") ]
    | Documentation.Not_available reason ->
        json_obj
          [
            ("status", Json.string "not_available");
            ("reason", Json.string reason);
          ]
    | Documentation.Available { text; truncated } ->
        json_obj
          [
            ("status", Json.string "available");
            ("text", Json.string text);
            ("truncated", Json.bool truncated);
          ]

  let json t =
    json_obj
      [
        ("query", Input.to_json t.query);
        ("path", Json.string (Workspace.Path.display t.path));
        ("backend", Json.string t.backend);
        ("verbosity", Json.int t.verbosity);
        ("frames", Json.list (List.map frame_json t.frames));
        ("documentation", documentation_json t.documentation);
      ]

  let frame_line frame =
    let location = Frame.location frame in
    let start = Ocaml.Location.start location in
    Printf.sprintf "- %s:%d:%d  %s%s"
      (Workspace.Path.display (Ocaml.Location.path location))
      (Ocaml.Position.line start)
      (Ocaml.Position.column start)
      (Frame.type_string frame)
      (if Frame.truncated frame then " (truncated)" else "")

  let text t =
    let position = Input.position t.query in
    let b = Buffer.create 256 in
    Buffer.add_string b
      (Printf.sprintf "OCaml type at %s:%d:%d\n"
         (Workspace.Path.display t.path)
         (Ocaml.Position.line position)
         (Ocaml.Position.column position));
    List.iter
      (fun frame ->
        Buffer.add_string b (frame_line frame);
        Buffer.add_char b '\n')
      t.frames;
    (match t.documentation with
    | Documentation.Not_requested -> ()
    | Documentation.Not_available reason ->
        Buffer.add_string b
          (Printf.sprintf "documentation: unavailable (%s)\n" reason)
    | Documentation.Available { text; truncated } ->
        Buffer.add_string b
          (Printf.sprintf "documentation: %s%s\n" text
             (if truncated then " (truncated)" else "")));
    Buffer.add_string b ("backend: " ^ t.backend);
    String.trim (Buffer.contents b)

  let encode t =
    let truncated =
      List.exists Frame.truncated t.frames
      ||
      match t.documentation with
      | Documentation.Available { truncated; _ } -> truncated
      | Documentation.Not_requested | Documentation.Not_available _ -> false
    in
    Tool.Output.make ~text:(text t) ~json:(json t) ~truncated
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

(* Merlin [type-enclosing] response decoding. The [value] payload is an array of
   frame objects sorted innermost-first; each carries a [start]/[end] range and
   a [type] that is a printed string at the queried [-index] and either a bare
   integer typedtree index or a pre-printed reconstructed string elsewhere. *)

type type_field = Printed of string | Index_ref | Absent
type raw_frame = { range : Ocaml.Range.t; type_field : type_field }

let member name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let int_member name json =
  match member name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (int_of_float value)
  | _ -> None

let parse_position json =
  match (int_member "line" json, int_member "col" json) with
  | Some line, Some column -> (
      try Some (Ocaml.Position.make ~line ~column)
      with Invalid_argument _ -> None)
  | _ -> None

let type_field_of_json = function
  | Some (Jsont.String (value, _)) -> Printed value
  | Some (Jsont.Number (value, _)) when Float.is_integer value -> Index_ref
  | _ -> Absent

let parse_frame json =
  match (member "start" json, member "end" json) with
  | Some start_json, Some end_json -> (
      match (parse_position start_json, parse_position end_json) with
      | Some start, Some end_ -> (
          try
            let range = Ocaml.Range.make ~start ~end_ in
            Some { range; type_field = type_field_of_json (member "type" json) }
          with Invalid_argument _ -> None)
      | _ -> None)
  | _ -> None

let parse_frames value =
  match value with
  | Jsont.Array (items, _) ->
      let rec loop acc = function
        | [] -> Some (List.rev acc)
        | item :: rest -> (
            match parse_frame item with
            | Some frame -> loop (frame :: acc) rest
            | None -> None)
      in
      loop [] items
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Object _ ->
      None

(* Drop adjacent frames with equal range, keeping the first (innermost,
   reconstructed) — Merlin defers this dedup to clients. Original indices are
   preserved so a kept frame's printed type can be re-fetched by [-index]. *)
let dedup_adjacent frames =
  let indexed = List.mapi (fun index frame -> (index, frame)) frames in
  let rec loop acc = function
    | [] -> List.rev acc
    | first :: rest -> (
        match acc with
        | (_, prev) :: _ when Ocaml.Range.equal prev.range (snd first).range ->
            loop acc rest
        | _ -> loop (first :: acc) rest)
  in
  loop [] indexed

(* Merlin [document] sentinels: a non-return payload string that is a "no doc"
   marker rather than documentation text. See query_json.ml:505-517. *)
let document_sentinel s =
  String.equal s "No documentation available"
  || String.equal s "Not a valid identifier"
  || String.starts_with ~prefix:"didn't manage to find" s
  || String.ends_with ~suffix:"is a builtin, no documentation is available" s
  || String.starts_with ~prefix:"Not in environment" s
  || String.ends_with ~suffix:" but could not be found" s

module Merlin = Ocaml_merlin

let type_enclosing_args ~abs_path ~position ~index ~verbosity =
  let base =
    [
      "-position";
      Printf.sprintf "%d:%d"
        (Ocaml.Position.line position)
        (Ocaml.Position.column position);
      "-index";
      string_of_int index;
      "-printer-width";
      string_of_int printer_width;
      "-filename";
      abs_path;
    ]
  in
  (* [verbosity = 0] omits the flag to inherit Merlin's default level, which is
     not the same as integer 0 (§2). *)
  if verbosity > 0 then base @ [ "-verbosity"; string_of_int verbosity ]
  else base

let document_args ~abs_path ~position =
  [
    "-position";
    Printf.sprintf "%d:%d"
      (Ocaml.Position.line position)
      (Ocaml.Position.column position);
    "-filename";
    abs_path;
  ]

let merlin_exec_access ~program ~workspace =
  let cwd =
    Permission.Access.Path_scope.workspace (Workspace.root_path workspace)
  in
  match program with
  | [] -> invalid_arg "program prefix must not be empty"
  | argv_program :: args ->
      Permission.Access.argv ~cwd
        ~execution:Permission.Access.Command.Sandboxed ~program:argv_program
        args

let permissions ?(program = default_program) ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ ->
      [
        Permission.Request.of_accesses ~source:name
          [
            Permission.Access.unknown_path ~op:`Read (Input.path input);
            merlin_exec_access ~program ~workspace;
          ];
      ]
  | Ok path ->
      [
        Permission.Request.of_accesses ~source:name
          [
            Permission.Access.path ~op:`Read path;
            merlin_exec_access ~program ~workspace;
          ];
      ]

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

(* Outcome of one [type-enclosing] subprocess, shared by the primary [-index 0]
   call and every targeted per-frame re-type. *)
type type_enclosing =
  | Te_cancelled
  | Te_error of Tool.Result.failure * string
  | Te_frames of raw_frame list

let run_type_enclosing ~sandbox ~program ~cwd ~abs_path ~position ~verbosity ~source
    ~cancelled ~index =
  match
    Merlin.run ~sandbox ~program ~cwd ~command:"type-enclosing"
      ~args:(type_enclosing_args ~abs_path ~position ~index ~verbosity)
      ~source ~cancelled ()
  with
  | Error Merlin.Cancelled -> Te_cancelled
  | Error (Merlin.Unavailable _ as error) ->
      Te_error (`Unavailable, Merlin.error_message error)
  | Error (Merlin.Timed_out _ as error) ->
      Te_error (`Timed_out, Merlin.error_message error)
  | Error error -> Te_error (`Failed, Merlin.error_message error)
  | Ok value -> (
      match parse_frames value with
      | None -> Te_error (`Failed, "malformed type-enclosing response")
      | Some frames -> Te_frames frames)

let printed_type_at ~index frames =
  match List.nth_opt frames index with
  | Some { type_field = Printed value; _ } -> Some value
  | Some _ | None -> None

let build_frame ~path ~range ~type_string =
  let type_string, truncated =
    truncate_utf8 ~max_bytes:max_type_bytes type_string
  in
  let location = Ocaml.Location.make ~path ~range in
  Frame.make ~location ~type_string ~truncated

(* Documentation: one extra [document] subprocess. A failure never fails the
   call — it becomes a {!Documentation.Not_available} slot. *)
let fetch_documentation ~sandbox ~program ~cwd ~abs_path ~position ~source ~cancelled =
  match
    Merlin.run ~sandbox ~program ~cwd ~command:"document"
      ~args:(document_args ~abs_path ~position)
      ~source ~cancelled ()
  with
  | Error Merlin.Cancelled -> `Interrupt
  | Error _ -> `Slot (Documentation.Not_available "documentation lookup failed")
  | Ok (Jsont.String (text, _)) ->
      if document_sentinel text then `Slot (Documentation.Not_available text)
      else
        let text, truncated = truncate_utf8 ~max_bytes:max_doc_bytes text in
        `Slot (Documentation.Available { text; truncated })
  | Ok _ -> `Slot (Documentation.Not_available "documentation lookup failed")

let run ~sandbox ?(program = default_program) ~fs ~workspace ctx input =
  let cancelled () = Tool.Context.cancelled ctx in
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match request_source_file ~fs ~workspace input with
    | Error error -> Tool.Result.failed `Not_found (Fs.Error.message error)
    | Ok (source_path, source) -> (
        let root = Workspace.root_path workspace in
        let cwd = Workspace.Path.to_string root in
        let abs_path = Workspace.Path.to_string source_path in
        let position = Input.position input in
        let verbosity = Input.verbosity input in
        let interrupted () =
          Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true
            ()
        in
        (* Primary subprocess: [-index 0] both prints frame 0's type and reveals
           every frame's range, so one process already yields the whole stack
           shape (§2). *)
        match
          run_type_enclosing ~sandbox ~program ~cwd ~abs_path ~position ~verbosity
            ~source ~cancelled ~index:0
        with
        | Te_cancelled -> interrupted ()
        | Te_error (kind, message) -> Tool.Result.failed kind message
        | Te_frames raw_frames -> (
            let deduped = dedup_adjacent raw_frames in
            match deduped with
            | [] ->
                Tool.Result.failed `Not_found
                  (Printf.sprintf "no type at position %d:%d"
                     (Ocaml.Position.line position)
                     (Ocaml.Position.column position))
            | _ -> (
                let wanted =
                  min (Input.max_enclosings input) (List.length deduped)
                in
                let selected = List.filteri (fun i _ -> i < wanted) deduped in
                (* Frame 0's printed type is already in [raw_frames]; every
                   later kept frame costs one targeted [-index] re-type. *)
                let rec build acc = function
                  | [] -> `Frames (List.rev acc)
                  | (orig_index, raw) :: rest -> (
                      let type_string =
                        if orig_index = 0 then
                          match printed_type_at ~index:0 raw_frames with
                          | Some value -> `Type value
                          | None ->
                              `Fail (`Failed, "frame 0 has no printed type")
                        else if cancelled () then `Interrupt
                        else
                          match
                            run_type_enclosing ~sandbox ~program ~cwd ~abs_path ~position
                              ~verbosity ~source ~cancelled ~index:orig_index
                          with
                          | Te_cancelled -> `Interrupt
                          | Te_error (kind, message) -> `Fail (kind, message)
                          | Te_frames frames -> (
                              match
                                printed_type_at ~index:orig_index frames
                              with
                              | Some value -> `Type value
                              | None ->
                                  `Fail
                                    ( `Failed,
                                      Printf.sprintf
                                        "frame %d has no printed type"
                                        orig_index ))
                      in
                      match type_string with
                      | `Type value ->
                          build
                            (build_frame ~path:source_path ~range:raw.range
                               ~type_string:value
                            :: acc)
                            rest
                      | `Fail (kind, message) -> `Fail (kind, message)
                      | `Interrupt -> `Interrupt)
                in
                match build [] selected with
                | `Interrupt -> interrupted ()
                | `Fail (kind, message) -> Tool.Result.failed kind message
                | `Frames frames -> (
                    let documentation_slot =
                      if not (Input.documentation input) then
                        `Slot Documentation.Not_requested
                      else if cancelled () then `Interrupt
                      else
                        fetch_documentation ~sandbox ~program ~cwd ~abs_path ~position
                          ~source ~cancelled
                    in
                    match documentation_slot with
                    | `Interrupt -> interrupted ()
                    | `Slot documentation ->
                        Tool.Result.completed
                          ~output:
                            (Output.make ~query:input ~path:source_path ~frames
                               ~documentation ~verbosity ~backend:"ocamlmerlin")
                          ()))))

let tool ~sandbox ?program ~fs ~workspace () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(permissions ?program ~workspace)
    ~run:(run ~sandbox ?program ~fs ~workspace)
    ()
