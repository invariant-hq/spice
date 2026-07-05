(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "read_file"
let default_max_bytes = 65_536
let default_directory_limit = 200
let default_display_line_bytes = 2_000
let read_chunk_size = 16_384
let description = Spice_prompts.Tools.read_file

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()

let json_string_option = function
  | None -> json_null
  | Some value -> Json.string value

let optional_json_field name value fields =
  match value with None -> fields | Some value -> (name, value) :: fields

module Range = struct
  type t = All | Lines of { start_line : int; max_lines : int option }

  let all = All

  let lines ?max_lines ~start_line () =
    if start_line < 1 then invalid_arg "start_line must be at least 1";
    begin match max_lines with
    | Some max_lines when max_lines < 1 ->
        invalid_arg "max_lines must be positive"
    | Some _ | None -> ()
    end;
    Lines { start_line; max_lines }
end

module Input = struct
  type t = {
    path : string;
    range : Range.t;
    max_bytes : int option;
    if_identity : Spice_digest.Identity.t option;
  }

  let validate_if_identity ~range ~max_bytes = function
    | Some _
      when not (match range with Range.All -> true | Range.Lines _ -> false) ->
        invalid_arg
          "if_identity can only be used with an unwindowed complete-file read"
    | Some _ when Option.is_some max_bytes ->
        invalid_arg
          "if_identity can only be used with an unwindowed complete-file read"
    | Some _ | None -> ()

  let make ?(range = Range.All) ?max_bytes ?if_identity path =
    if String.is_empty path then invalid_arg "path must not be empty";
    begin match max_bytes with
    | Some max_bytes when max_bytes < 0 ->
        invalid_arg "max_bytes must be non-negative"
    | Some _ | None -> ()
    end;
    validate_if_identity ~range ~max_bytes if_identity;
    { path; range; max_bytes; if_identity }

  let path t = t.path
  let range t = t.range
  let max_bytes t = t.max_bytes
  let if_identity t = t.if_identity

  let range_from_json_fields offset limit =
    match (offset, limit) with
    | None, None -> Range.All
    | Some start_line, max_lines -> Range.lines ?max_lines ~start_line ()
    | None, Some max_lines -> Range.lines ~max_lines ~start_line:1 ()

  let make_from_json_fields path offset limit max_bytes if_identity =
    if String.is_empty path then invalid_arg "path must not be empty";
    begin match offset with
    | Some offset when offset < 1 -> invalid_arg "offset must be at least 1"
    | Some _ | None -> ()
    end;
    begin match limit with
    | Some limit when limit < 1 -> invalid_arg "limit must be positive"
    | Some _ | None -> ()
    end;
    begin match max_bytes with
    | Some max_bytes when max_bytes < 0 ->
        invalid_arg "max_bytes must be non-negative"
    | Some _ | None -> ()
    end;
    let range = range_from_json_fields offset limit in
    let if_identity =
      match if_identity with
      | None -> None
      | Some value -> (
          match Spice_digest.Identity.of_string value with
          | Ok identity -> Some identity
          | Error error ->
              invalid_arg
                ("if_identity is not a file identity: "
                ^ Spice_digest.Identity.Parse_error.message error))
    in
    make ?max_bytes ?if_identity ~range path

  let offset t =
    match range t with
    | Range.All -> None
    | Range.Lines { start_line; _ } -> Some start_line

  let limit t =
    match range t with
    | Range.All -> None
    | Range.Lines { max_lines; _ } -> max_lines

  let to_json t =
    let fields =
      [ ("path", Json.string (path t)) ]
      |> optional_json_field "max_bytes"
           (Option.map (fun value -> Json.int value) (max_bytes t))
      |> optional_json_field "if_identity"
           (Option.map
              (fun identity ->
                Json.string (Spice_digest.Identity.to_string identity))
              (if_identity t))
    in
    let fields =
      match range t with
      | Range.All -> fields
      | Range.Lines { start_line; max_lines } ->
          optional_json_field "limit"
            (Option.map (fun value -> Json.int value) max_lines)
            (("offset", Json.int start_line) :: fields)
    in
    json_obj (List.rev fields)

  let codec_with_conditional_read =
    Jsont.Object.map ~kind:"read_file input"
      (fun path offset limit max_bytes if_identity ->
        decode_invalid_arg (fun () ->
            make_from_json_fields path offset limit max_bytes if_identity))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.opt_mem "offset" Jsont.int ~enc:offset
    |> Jsont.Object.opt_mem "limit" Jsont.int ~enc:limit
    |> Jsont.Object.opt_mem "max_bytes" Jsont.int ~enc:max_bytes
    |> Jsont.Object.opt_mem "if_identity" Jsont.string ~enc:(fun t ->
        Option.map Spice_digest.Identity.to_string (if_identity t))
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let codec_without_conditional_read =
    Jsont.Object.map ~kind:"read_file input" (fun path offset limit max_bytes ->
        decode_invalid_arg (fun () ->
            make_from_json_fields path offset limit max_bytes None))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.opt_mem "offset" Jsont.int ~enc:offset
    |> Jsont.Object.opt_mem "limit" Jsont.int ~enc:limit
    |> Jsont.Object.opt_mem "max_bytes" Jsont.int ~enc:max_bytes
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema ~conditional_read =
    let properties =
      [
        ( "path",
          json_obj
            [
              ("type", Json.string "string");
              ( "description",
                Json.string
                  "Workspace-relative or workspace-contained absolute path to \
                   read (a file or a directory)." );
            ] );
        ( "offset",
          json_obj
            [
              ("type", Json.string "integer");
              ("minimum", Json.int 1);
              ( "description",
                Json.string
                  "1-based first line to return, or first directory entry. \
                   Defaults to the start." );
            ] );
        ( "limit",
          json_obj
            [
              ("type", Json.string "integer");
              ("minimum", Json.int 1);
              ( "description",
                Json.string
                  "Maximum lines to return, or directory entries. Defaults to \
                   the end of the file, or 200 entries." );
            ] );
        ( "max_bytes",
          json_obj
            [
              ("type", Json.string "integer");
              ("minimum", Json.int 0);
              ( "description",
                Json.string
                  "Maximum UTF-8 bytes to return. Applies to file reads only."
              );
            ] );
      ]
    in
    let properties =
      if conditional_read then
        ( "if_identity",
          json_obj
            [
              ("type", Json.string "string");
              ( "description",
                Json.string
                  "Complete-file identity from a previous read. When it still \
                   matches, the tool reports unchanged content. This can only \
                   be used without offset, limit, or max_bytes." );
            ] )
        :: properties
      else properties
    in
    json_obj
      [
        ("type", Json.string "object");
        ("properties", json_obj (List.rev properties));
        ("required", Json.list [ Json.string "path" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract ~conditional_read =
    let codec =
      if conditional_read then codec_with_conditional_read
      else codec_without_conditional_read
    in
    Tool.Input.make codec ~schema:(schema ~conditional_read)

  let decode ~conditional_read json =
    Tool.Input.decode (contract ~conditional_read) json
end

module Entry = struct
  type kind = Regular_file | Directory | Symlink | Other
  type t = { path : Workspace.Path.t; name : string; kind : kind }
end

module Fingerprint = struct
  type t = { size : int64; mtime_ns_approx : int64 option }

  let size t = t.size
  let mtime_ns_approx t = t.mtime_ns_approx
end

module Output = struct
  type line_count = Exact of int | Lower_bound of int | Unknown
  type partial_reason = Ranged | Byte_capped | Ranged_and_byte_capped
  type partial = { reason : partial_reason; next : Input.t option }
  type status = Complete of Spice_digest.Identity.t | Partial of partial

  type read = {
    read_path : Workspace.Path.t;
    contents : string;
    start_line : int;
    returned_lines : int;
    total_lines : line_count;
    status : status;
    read_fingerprint : Fingerprint.t option;
  }

  type unchanged = {
    unchanged_path : Workspace.Path.t;
    identity : Spice_digest.Identity.t;
    unchanged_fingerprint : Fingerprint.t option;
  }

  type listing = {
    listing_path : Workspace.Path.t;
    entries : Entry.t list;
    listing_offset : int;
    listing_limit : int;
    total_entries : int;
    listing_complete : bool;
    listing_next : Input.t option;
  }

  type t = Read of read | Unchanged of unchanged | Listing of listing

  let make ~path ~contents ~start_line ~returned_lines ~total_lines ~status
      ~fingerprint =
    Read
      {
        read_path = path;
        contents;
        start_line;
        returned_lines;
        total_lines;
        status;
        read_fingerprint = fingerprint;
      }

  let make_listing ~path ~entries ~offset ~limit ~total_entries ~complete ~next
      =
    Listing
      {
        listing_path = path;
        entries;
        listing_offset = offset;
        listing_limit = limit;
        total_entries;
        listing_complete = complete;
        listing_next = next;
      }

  let path = function
    | Read read -> read.read_path
    | Unchanged unchanged -> unchanged.unchanged_path
    | Listing listing -> listing.listing_path

  let identity = function
    | Read { status = Complete identity; _ } | Unchanged { identity; _ } ->
        Some identity
    | Read { status = Partial _; _ } | Listing _ -> None

  let fingerprint = function
    | Read read -> read.read_fingerprint
    | Unchanged unchanged -> unchanged.unchanged_fingerprint
    | Listing _ -> None

  let complete_identity = function
    | Read { status = Complete identity; _ } -> Some identity
    | Read { status = Partial _; _ } | Unchanged _ | Listing _ -> None

  let as_unchanged identity = function
    | Read read ->
        Unchanged
          {
            unchanged_path = read.read_path;
            identity;
            unchanged_fingerprint = read.read_fingerprint;
          }
    | (Unchanged _ | Listing _) as output -> output

  type render = Numbered | Anchored of Anchor.Source.t

  let numbered = Numbered
  let anchored ?(source = Anchor.Source.deterministic) () = Anchored source

  let line_count_json = function
    | Exact n ->
        json_obj [ ("kind", Json.string "exact"); ("value", Json.int n) ]
    | Lower_bound n ->
        json_obj [ ("kind", Json.string "lower_bound"); ("value", Json.int n) ]
    | Unknown -> json_obj [ ("kind", Json.string "unknown") ]

  let partial_reason_to_string = function
    | Ranged -> "ranged"
    | Byte_capped -> "byte_capped"
    | Ranged_and_byte_capped -> "ranged_and_byte_capped"

  let partial_reason_json reason = Json.string (partial_reason_to_string reason)

  let status_json = function
    | Complete identity ->
        json_obj
          [
            ("kind", Json.string "complete");
            ("identity", Json.string (Spice_digest.Identity.to_string identity));
          ]
    | Partial { reason; next } ->
        json_obj
          [
            ("kind", Json.string "partial");
            ("reason", partial_reason_json reason);
            ( "next",
              match next with
              | None -> json_null
              | Some next -> Input.to_json next );
          ]

  let identity_json = function
    | Complete identity ->
        Json.string (Spice_digest.Identity.to_string identity)
    | Partial _ -> json_null

  let partial_reason_option = function
    | Partial { reason; _ } -> Some reason
    | Complete _ -> None

  let byte_truncated = function
    | Partial { reason = Byte_capped | Ranged_and_byte_capped; _ } -> true
    | Partial { reason = Ranged; _ } | Complete _ -> false

  let complete = function Complete _ -> true | Partial _ -> false

  let fingerprint_json fingerprint =
    json_obj
      [
        ("size", Json.int64 (Fingerprint.size fingerprint));
        ( "mtime_ns",
          match Fingerprint.mtime_ns_approx fingerprint with
          | None -> json_null
          | Some mtime_ns -> Json.int64 mtime_ns );
      ]

  let logical_lines text =
    if String.is_empty text then []
    else
      let lines = String.split_on_char '\n' text in
      if Char.equal text.[String.length text - 1] '\n' then
        List.rev (List.tl (List.rev lines))
      else lines

  let display_line line =
    if String.length line <= default_display_line_bytes then line
    else
      Text_helpers.valid_utf8_prefix line default_display_line_bytes
      ^ " [line truncated]"

  let line_anchor source ~path ~line_number line =
    Anchor.Source.line source ~path ~number:line_number ~text:line
    |> Option.map Anchor.to_string

  let rendered_lines ~path ~offset ~render text =
    let b = Buffer.create (String.length text + 32) in
    List.iteri
      (fun i line ->
        let line_number = offset + i in
        let raw_line = Text_helpers.strip_trailing_cr line in
        let display_line = display_line raw_line in
        Buffer.add_string b (string_of_int line_number);
        begin match render with
        | Numbered -> ()
        | Anchored source ->
            begin match line_anchor source ~path ~line_number raw_line with
            | None -> ()
            | Some anchor ->
                Buffer.add_char b ' ';
                Buffer.add_string b anchor
            end
        end;
        Buffer.add_char b '\t';
        Buffer.add_string b display_line;
        Buffer.add_char b '\n')
      (logical_lines text);
    Buffer.contents b

  let line_range_text ~start_line ~returned_lines ~total_lines =
    if returned_lines = 0 then
      let empty = "empty at " ^ string_of_int start_line in
      match total_lines with
      | Exact total when start_line > total ->
          Printf.sprintf "%s (past EOF; file has %d lines)" empty total
      | Exact _ | Lower_bound _ | Unknown -> empty
    else
      let last_line = start_line + returned_lines - 1 in
      string_of_int start_line ^ "-" ^ string_of_int last_line

  let line_count_text = function
    | Exact n -> string_of_int n
    | Lower_bound n -> ">=" ^ string_of_int n
    | Unknown -> "unknown"

  (* The continuation is rendered through the shared pagination renderer so the
     [next:] escaping guarantee is proven once for every observer. The page
     carries only [next]; its other counts are unused by {!Pagination.Page.hint}.
     A byte-capped read with no line-range continuation renders no line; the
     advice to retry with a wider budget lives in the tool description. *)
  let continuation_hint (read : read) =
    match read.status with
    | Complete _ -> ""
    | Partial { next; _ } -> (
        let page =
          Pagination.Page.partial ~returned:read.returned_lines
            ~total:Pagination.Count.Unknown ~offset:read.start_line ~limit:0
            ~next
        in
        match Pagination.Page.hint ~tool:name ~to_json:Input.to_json page with
        | None -> ""
        | Some line -> line)

  let listing_status_word complete = if complete then "complete" else "partial"

  let entry_suffix = function
    | Entry.Regular_file -> ""
    | Entry.Directory -> "/"
    | Entry.Symlink -> "@"
    | Entry.Other -> "?"

  let entry_text (entry : Entry.t) =
    Workspace.Path.display entry.Entry.path ^ entry_suffix entry.Entry.kind

  let entry_kind_to_string = function
    | Entry.Regular_file -> "file"
    | Entry.Directory -> "directory"
    | Entry.Symlink -> "symlink"
    | Entry.Other -> "other"

  let listing_continuation_hint (listing : listing) =
    match listing.listing_next with
    | None -> ""
    | Some _ -> (
        let page =
          Pagination.Page.partial
            ~returned:(List.length listing.entries)
            ~total:(Pagination.Count.Exact listing.total_entries)
            ~offset:listing.listing_offset ~limit:listing.listing_limit
            ~next:listing.listing_next
        in
        match Pagination.Page.hint ~tool:name ~to_json:Input.to_json page with
        | None -> ""
        | Some line -> line)

  let listing_text (listing : listing) =
    let b = Buffer.create 256 in
    Buffer.add_string b (Workspace.Path.display listing.listing_path);
    Buffer.add_string b " entries=";
    Buffer.add_string b (string_of_int (List.length listing.entries));
    Buffer.add_char b '/';
    Buffer.add_string b (string_of_int listing.total_entries);
    Buffer.add_string b " offset=";
    Buffer.add_string b (string_of_int listing.listing_offset);
    Buffer.add_string b " limit=";
    Buffer.add_string b (string_of_int listing.listing_limit);
    Buffer.add_string b " status=";
    Buffer.add_string b (listing_status_word listing.listing_complete);
    Buffer.add_char b '\n';
    List.iter
      (fun entry ->
        Buffer.add_string b (entry_text entry);
        Buffer.add_char b '\n')
      listing.entries;
    let hint = listing_continuation_hint listing in
    if not (String.is_empty hint) then begin
      Buffer.add_string b hint;
      Buffer.add_char b '\n'
    end;
    Buffer.contents b

  let entry_json (entry : Entry.t) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display entry.Entry.path));
        ("name", Json.string entry.Entry.name);
        ("kind", Json.string (entry_kind_to_string entry.Entry.kind));
      ]

  let listing_json (listing : listing) =
    json_obj
      [
        ("kind", Json.string "listing");
        ("path", Json.string (Workspace.Path.display listing.listing_path));
        ("entries", Json.list (List.map entry_json listing.entries));
        ("offset", Json.int listing.listing_offset);
        ("limit", Json.int listing.listing_limit);
        ("returned_entries", Json.int (List.length listing.entries));
        ("total_entries", Json.int listing.total_entries);
        ("status", Json.string (listing_status_word listing.listing_complete));
        ( "next",
          match listing.listing_next with
          | None -> json_null
          | Some next -> Input.to_json next );
      ]

  let header ~render (read : read) =
    let range =
      line_range_text ~start_line:read.start_line
        ~returned_lines:read.returned_lines ~total_lines:read.total_lines
    in
    let total = line_count_text read.total_lines in
    let status_word = if complete read.status then "complete" else "partial" in
    let reason =
      match partial_reason_option read.status with
      | None -> ""
      | Some reason -> " reason=" ^ partial_reason_to_string reason
    in
    let identity =
      match read.status with
      | Complete identity ->
          " identity=" ^ Spice_digest.Identity.to_string identity
      | Partial _ -> ""
    in
    let anchors =
      match render with Numbered -> "" | Anchored _ -> " anchors=enabled"
    in
    Printf.sprintf "%s lines=%s returned=%d/%s status=%s%s%s%s"
      (Workspace.Path.display read.read_path)
      range read.returned_lines total status_word reason anchors identity

  let text ~render t =
    match t with
    | Listing listing -> listing_text listing
    | Unchanged { unchanged_path; identity; _ } ->
        Printf.sprintf "%s unchanged identity=%s\n"
          (Workspace.Path.display unchanged_path)
          (Spice_digest.Identity.to_string identity)
    | Read read ->
        if read.returned_lines = 0 then
          let hint = continuation_hint read in
          header ~render read
          ^ (if String.is_empty hint then "" else "\n" ^ hint)
          ^ "\n"
        else
          let hint = continuation_hint read in
          header ~render read ^ "\n"
          ^ rendered_lines ~path:read.read_path ~offset:read.start_line ~render
              read.contents
          ^ if String.is_empty hint then "" else hint ^ "\n"

  let read_json (read : read) =
    let status = read.status in
    json_obj
      [
        ("kind", Json.string "read");
        ("path", Json.string (Workspace.Path.display read.read_path));
        ("contents", Json.string read.contents);
        ("start_line", Json.int read.start_line);
        ("returned_lines", Json.int read.returned_lines);
        ("total_lines", line_count_json read.total_lines);
        ("status", status_json status);
        ("byte_truncated", Json.bool (byte_truncated status));
        ("complete", Json.bool (complete status));
        ("unchanged", Json.bool false);
        ( "partial_reason",
          json_string_option
            (Option.map partial_reason_to_string (partial_reason_option status))
        );
        ("identity", identity_json status);
        ( "fingerprint",
          match read.read_fingerprint with
          | None -> json_null
          | Some fingerprint -> fingerprint_json fingerprint );
      ]

  let unchanged_json unchanged =
    json_obj
      [
        ("kind", Json.string "unchanged");
        ("path", Json.string (Workspace.Path.display unchanged.unchanged_path));
        ( "status",
          json_obj
            [
              ("kind", Json.string "unchanged");
              ( "identity",
                Json.string (Spice_digest.Identity.to_string unchanged.identity)
              );
            ] );
        ("complete", Json.bool true);
        ("unchanged", Json.bool true);
        ( "identity",
          Json.string (Spice_digest.Identity.to_string unchanged.identity) );
        ( "fingerprint",
          match unchanged.unchanged_fingerprint with
          | None -> json_null
          | Some fingerprint -> fingerprint_json fingerprint );
      ]

  let json = function
    | Read read -> read_json read
    | Unchanged unchanged -> unchanged_json unchanged
    | Listing listing -> listing_json listing

  let truncated = function
    | Read { status; _ } -> byte_truncated status
    | Unchanged _ | Listing _ -> false

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode ?(render = Numbered) t =
    Tool.Output.make ~text:(text ~render t) ~json:(json t)
      ~truncated:(truncated t)
      ~value:(Tool.Output.pack type_id t)
      ()

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

  let int_field name json =
    Option.bind (json_field name json) (decode_json Jsont.int)

  let replay_root =
    Workspace.Root.make ~key:"session-replay" (Spice_path.Abs.of_string_exn "/")

  let path_of_json value =
    let parsed =
      if String.equal value "" then Ok Spice_path.Rel.root
      else Spice_path.Rel.of_string value
    in
    match parsed with
    | Ok rel -> Some (Workspace.Path.make ~root:replay_root rel)
    | Error _ -> None

  let identity_of_json value =
    match Spice_digest.Identity.of_string value with
    | Ok identity -> Some identity
    | Error _ -> None

  let line_count_of_json json =
    match string_field "kind" json with
    | Some "exact" ->
        Option.map (fun value -> Exact value) (int_field "value" json)
    | Some "lower_bound" ->
        Option.map (fun value -> Lower_bound value) (int_field "value" json)
    | Some "unknown" -> Some Unknown
    | Some _ | None -> None

  let partial_reason_of_json value =
    match value with
    | "ranged" -> Some Ranged
    | "byte_capped" -> Some Byte_capped
    | "ranged_and_byte_capped" -> Some Ranged_and_byte_capped
    | _ -> None

  let next_input_of_json json =
    match json_field "next" json with
    | None | Some (Jsont.Null _) -> Some None
    | Some next -> (
        match Input.decode ~conditional_read:true next with
        | Ok input -> Some (Some input)
        | Error _ -> None)

  let status_of_json json =
    match string_field "kind" json with
    | Some "complete" ->
        Option.bind (string_field "identity" json) identity_of_json
        |> Option.map (fun identity -> Complete identity)
    | Some "partial" -> (
        match (string_field "reason" json, next_input_of_json json) with
        | Some reason, Some next ->
            Option.map
              (fun reason -> Partial { reason; next })
              (partial_reason_of_json reason)
        | Some _, None | None, _ -> None)
    | Some _ | None -> None

  let read_of_json json =
    match
      ( string_field "path" json,
        string_field "contents" json,
        int_field "start_line" json,
        int_field "returned_lines" json,
        Option.bind (json_field "total_lines" json) line_count_of_json,
        Option.bind (json_field "status" json) status_of_json )
    with
    | ( Some path,
        Some contents,
        Some start_line,
        Some returned_lines,
        Some total_lines,
        Some status ) ->
        Option.map
          (fun path ->
            Read
              {
                read_path = path;
                contents;
                start_line;
                returned_lines;
                total_lines;
                status;
                read_fingerprint = None;
              })
          (path_of_json path)
    | _ -> None

  let unchanged_of_json json =
    match (string_field "path" json, string_field "identity" json) with
    | Some path, Some identity -> (
        match (path_of_json path, identity_of_json identity) with
        | Some path, Some identity ->
            Some
              (Unchanged
                 {
                   unchanged_path = path;
                   identity;
                   unchanged_fingerprint = None;
                 })
        | Some _, None | None, Some _ | None, None -> None)
    | Some _, None | None, Some _ | None, None -> None

  let entry_kind_of_json = function
    | "file" -> Some Entry.Regular_file
    | "directory" -> Some Entry.Directory
    | "symlink" -> Some Entry.Symlink
    | "other" -> Some Entry.Other
    | _ -> None

  let entry_of_json json =
    match
      ( string_field "path" json,
        string_field "name" json,
        string_field "kind" json )
    with
    | Some path, Some name, Some kind -> (
        match (path_of_json path, entry_kind_of_json kind) with
        | Some path, Some kind -> Some { Entry.path; name; kind }
        | Some _, None | None, _ -> None)
    | _ -> None

  let entries_of_json json =
    match json_field "entries" json with
    | Some (Jsont.Array (items, _)) ->
        List.fold_right
          (fun item acc ->
            match (acc, entry_of_json item) with
            | Some acc, Some entry -> Some (entry :: acc)
            | _ -> None)
          items (Some [])
    | Some _ | None -> None

  let listing_of_json json =
    match
      ( string_field "path" json,
        entries_of_json json,
        int_field "offset" json,
        int_field "limit" json,
        int_field "total_entries" json,
        string_field "status" json )
    with
    | ( Some path,
        Some entries,
        Some offset,
        Some limit,
        Some total_entries,
        Some status ) -> (
        match (path_of_json path, next_input_of_json json) with
        | Some path, Some next ->
            Some
              (Listing
                 {
                   listing_path = path;
                   entries;
                   listing_offset = offset;
                   listing_limit = limit;
                   total_entries;
                   listing_complete = String.equal status "complete";
                   listing_next = next;
                 })
        | Some _, None | None, _ -> None)
    | _ -> None

  let of_json json =
    match string_field "kind" json with
    | Some "read" -> read_of_json json
    | Some "unchanged" -> unchanged_of_json json
    | Some "listing" -> listing_of_json json
    | Some _ | None -> None

  let of_tool_output output =
    match Tool.Output.value type_id output with
    | Some output -> Some output
    | None -> Option.bind (Tool.Output.json output) of_json
end

type read_error =
  | Fs of Fs.Error.t
  | Not_found_with_suggestions of Workspace.Path.t * Workspace.Path.t list
  | Binary_file of Workspace.Path.t
  | Invalid_utf8 of Workspace.Path.t
  | Cancelled

exception Read_cancelled
exception Read_binary

let max_suggestion_distance text =
  let len = String.length text in
  if len <= 4 then 1 else if len <= 8 then 2 else 3

let path_suggestions ~fs ~workspace path =
  match (Workspace.Path.parent path, Workspace.Path.basename path) with
  | None, _ | _, None -> []
  | Some parent, Some wanted -> (
      match Fs.read_dir_names ~fs ~workspace parent with
      | Error _ -> []
      | Ok entries ->
          entries
          |> List.filter_map (fun name ->
              let distance = String.edit_distance wanted name in
              if distance > max_suggestion_distance wanted then None
              else
                match Fs.child parent name with
                | Error _ -> None
                | Ok path -> Some (distance, name, path))
          |> List.sort (fun (dist_a, name_a, _) (dist_b, name_b, _) ->
              match Int.compare dist_a dist_b with
              | 0 -> String.compare name_a name_b
              | order -> order)
          |> List.map (fun (_, _, path) -> path)
          |> List.to_seq |> Seq.take 3 |> List.of_seq)

let fs_error ~fs ~workspace = function
  | Fs.Error.Not_found path ->
      Not_found_with_suggestions (path, path_suggestions ~fs ~workspace path)
  | error -> Fs error

let classify_eio ?fs ?workspace ?path exn =
  match (workspace, Fs.eio_error ?path exn) with
  | Some workspace, error -> (
      match fs with
      | Some fs -> fs_error ~fs ~workspace error
      | None -> (
          match error with
          | Fs.Error.Not_found path -> Fs (Fs.Error.Not_found path)
          | error -> Fs error))
  | None, error -> Fs error

let regular_file ~workspace ~fs path =
  Fs.regular ~fs ~workspace ~follow_symlink:true path
  |> Result.map_error (fs_error ~fs ~workspace)

let read_at file ~file_offset ~len =
  if len = 0 then ""
  else
    let buf = Cstruct.create len in
    let read =
      Eio.File.pread file ~file_offset:(Optint.Int63.of_int file_offset) [ buf ]
    in
    if read = 0 then "" else Cstruct.to_string (Cstruct.sub buf 0 read)

let rec valid_prefix_from text i lower_bound =
  if i < lower_bound then None
  else
    let prefix = String.sub text 0 i in
    if String.is_valid_utf_8 prefix then Some prefix
    else valid_prefix_from text (i - 1) lower_bound

let valid_returned_text ~path ~byte_capped text =
  if String.is_valid_utf_8 text then Ok text
  else if byte_capped then
    let len = String.length text in
    let lower_bound = max 0 (len - 4) in
    match valid_prefix_from text len lower_bound with
    | Some text -> Ok text
    | None -> Error (Invalid_utf8 path)
  else Error (Invalid_utf8 path)

let total_lines ~bytes_seen ~newlines ~last_char =
  if bytes_seen = 0 then 0
  else
    match last_char with
    | Some '\n' -> newlines
    | Some _ -> newlines + 1
    | None -> 0

let file_identity = Spice_digest.Identity.of_contents

let partial_reason ~ranged ~byte_truncated =
  match (ranged, byte_truncated) with
  | false, false -> None
  | true, false -> Some Output.Ranged
  | false, true -> Some Output.Byte_capped
  | true, true -> Some Output.Ranged_and_byte_capped

let mtime_ns (stat : Eio.File.Stat.t) =
  if Float.is_finite stat.Eio.File.Stat.mtime && stat.Eio.File.Stat.mtime >= 0.0
  then Some (Int64.of_float (stat.Eio.File.Stat.mtime *. 1_000_000_000.0))
  else None

let file_fingerprint (stat : Eio.File.Stat.t) =
  Fingerprint.
    {
      size = Optint.Int63.to_int64 stat.Eio.File.Stat.size;
      mtime_ns_approx = mtime_ns stat;
    }

let next_ranged_input ~path ~input ~start_line ~returned_lines ~range_has_more =
  match Input.range input with
  | Range.All -> None
  | Range.Lines { max_lines = None; _ } -> None
  | Range.Lines { max_lines = Some max_lines; _ }
    when returned_lines > 0 && range_has_more ->
      Some
        (Input.make
           ~range:
             (Range.lines
                ~start_line:(start_line + returned_lines)
                ~max_lines ())
           ?max_bytes:(Input.max_bytes input)
           (Workspace.Path.display path))
  | Range.Lines _ -> None

let read_contents file ~size ~path ~input ~start_line ~ranged ~limit ~max_bytes
    ~cancelled ~fingerprint =
  let out = Buffer.create (min max_bytes 4096) in
  let bytes_seen = ref 0 in
  let newlines = ref 0 in
  let last_char = ref None in
  let current_line = ref 1 in
  let byte_truncated = ref false in
  let eof = ref false in
  let file_offset = ref 0 in
  let preflighted = ref false in
  let saw_after_range = ref false in
  let should_select line =
    line >= start_line
    && match limit with None -> true | Some limit -> line < start_line + limit
  in
  let passed_range line =
    match limit with None -> false | Some limit -> line >= start_line + limit
  in
  let add_char c =
    if Buffer.length out < max_bytes then Buffer.add_char out c
    else byte_truncated := true
  in
  let at_eof () =
    Optint.Int63.compare (Optint.Int63.of_int !file_offset) size >= 0
  in
  begin try
    while
      (not !eof) && (not !byte_truncated)
      && not (passed_range !current_line && ranged)
    do
      if cancelled () then raise Read_cancelled;
      if at_eof () then eof := true
      else begin
        let chunk =
          read_at file ~file_offset:!file_offset ~len:read_chunk_size
        in
        if String.is_empty chunk then eof := true
        else begin
          if not !preflighted then begin
            preflighted := true;
            if Text_helpers.looks_binary chunk then raise Read_binary
          end;
          file_offset := !file_offset + String.length chunk;
          String.iter
            (fun c ->
              if cancelled () then raise Read_cancelled;
              if !byte_truncated then ()
              else if passed_range !current_line && ranged then
                saw_after_range := true
              else begin
                incr bytes_seen;
                last_char := Some c;
                if should_select !current_line then add_char c;
                if Char.equal c '\n' then begin
                  incr newlines;
                  incr current_line
                end
              end)
            chunk
        end
      end
    done
  with Read_cancelled -> raise Read_cancelled
  end;
  let byte_capped = !byte_truncated in
  match valid_returned_text ~path ~byte_capped (Buffer.contents out) with
  | Error _ as error -> error
  | Ok contents ->
      let total_lines =
        total_lines ~bytes_seen:!bytes_seen ~newlines:!newlines
          ~last_char:!last_char
      in
      (* A read is complete when the returned contents are the entire file: it
         starts at line 1, nothing was byte-capped, and no file content exists
         beyond the selected range. A ranged read whose range covers the whole
         file is complete and carries the file identity; reporting it partial
         sends models into re-read loops. *)
      let remaining_after_range =
        (not !eof)
        && (!saw_after_range
           || Optint.Int63.compare (Optint.Int63.of_int !file_offset) size < 0)
      in
      let complete =
        start_line <= 1 && (not byte_capped) && not remaining_after_range
      in
      let total_lines =
        if !eof || complete then Output.Exact total_lines
        else Output.Lower_bound total_lines
      in
      let returned_lines = Text_helpers.logical_line_count contents in
      let status =
        if complete then Output.Complete (file_identity contents)
        else
          let reason =
            partial_reason ~ranged ~byte_truncated:byte_capped
            |> Option.value ~default:Output.Ranged
          in
          let range_has_more =
            ranged && passed_range !current_line
            && (!saw_after_range
               || Optint.Int63.compare (Optint.Int63.of_int !file_offset) size
                  < 0)
          in
          let next =
            next_ranged_input ~path ~input ~start_line ~returned_lines
              ~range_has_more
          in
          Output.Partial { Output.reason; Output.next }
      in
      Ok
        (Output.make ~path ~contents ~start_line ~returned_lines ~total_lines
           ~status ~fingerprint)

let range_start_limit input =
  match Input.range input with
  | Range.All -> (1, None, false)
  | Range.Lines { start_line; max_lines } -> (start_line, max_lines, true)

let read_text ~workspace ~fs ~path ~input ~max_bytes ~cancelled =
  let start_line, limit, ranged = range_start_limit input in
  match regular_file ~workspace ~fs path with
  | Error _ as error -> error
  | Ok stat -> (
      match
        Fs.with_regular_in ~fs ~workspace ~follow_symlink:true path
        @@ fun file ->
        read_contents file ~size:stat.Eio.File.Stat.size ~path ~input
          ~start_line ~ranged ~limit ~max_bytes ~cancelled
          ~fingerprint:(Some (file_fingerprint stat))
      with
      | Ok result -> result
      | Error error -> Error (Fs error)
      | exception Read_cancelled -> Error Cancelled
      | exception Read_binary -> Error (Binary_file path)
      | exception exn -> Error (classify_eio ~fs ~workspace ~path exn))

(* Directory listing, relocated from the retired list_directory tool. The
   dispatch in {!run} has already classified the target as a contained directory
   with [Fs.stat ~follow_symlink:true], so listing reads children directly and
   {!list_entries} follows a symlink directory root; child symlinks are reported
   without following. *)

let vcs_metadata_dirs = [ ".git"; ".svn"; ".hg"; ".bzr"; ".jj"; ".sl" ]
let is_vcs_metadata name = List.exists (String.equal name) vcs_metadata_dirs

let kind_of_stat (stat : Eio.File.Stat.t) =
  match stat.Eio.File.Stat.kind with
  | `Regular_file -> Entry.Regular_file
  | `Directory -> Entry.Directory
  | `Symbolic_link -> Entry.Symlink
  | `Unknown | `Fifo | `Character_special | `Block_device | `Socket ->
      Entry.Other

let kind_rank = function
  | Entry.Directory -> 0
  | Entry.Regular_file -> 1
  | Entry.Symlink -> 2
  | Entry.Other -> 3

let compare_entries (a : Entry.t) (b : Entry.t) =
  match Int.compare (kind_rank a.Entry.kind) (kind_rank b.Entry.kind) with
  | 0 -> String.compare a.Entry.name b.Entry.name
  | order -> order

let classify_entry ~fs ~workspace parent name =
  match Fs.child parent name with
  | Error error -> Error (Fs error)
  | Ok path -> (
      match Fs.stat ~fs ~workspace ~follow_symlink:false path with
      | Error error -> Error (Fs error)
      | Ok None -> Error (Fs (Fs.Error.Not_found path))
      | Ok (Some stat) -> Ok { Entry.path; name; kind = kind_of_stat stat })

let list_entries ~fs ~workspace ~cancelled path =
  match Fs.read_dir_names ~fs ~workspace ~follow_symlink:true path with
  | Error error -> Error (Fs error)
  | Ok names ->
      let rec loop acc = function
        | [] -> Ok (List.sort compare_entries acc)
        | name :: names -> (
            if cancelled () then Error Cancelled
            else if is_vcs_metadata name then loop acc names
            else
              match classify_entry ~fs ~workspace path name with
              | Error _ as error -> error
              | Ok entry -> loop (entry :: acc) names)
      in
      loop [] names

let listing_window = function
  | Range.All -> (1, default_directory_limit)
  | Range.Lines { start_line; max_lines = Some max_lines } ->
      (start_line, max_lines)
  | Range.Lines { start_line; max_lines = None } ->
      (start_line, default_directory_limit)

let build_listing ~path ~offset ~limit entries =
  let total_entries = List.length entries in
  let returned = entries |> List.drop (offset - 1) |> List.take limit in
  let returned_entries = List.length returned in
  let first_unreturned = offset + returned_entries in
  let has_unreturned =
    offset <= total_entries && first_unreturned <= total_entries
  in
  let next =
    if has_unreturned then
      Some
        (Input.make
           ~range:(Range.lines ~start_line:first_unreturned ~max_lines:limit ())
           (Workspace.Path.display path))
    else None
  in
  Output.make_listing ~path ~entries:returned ~offset ~limit ~total_entries
    ~complete:(not has_unreturned) ~next

let failure_of_error = function
  | Fs error -> Fs_error.failure error
  | Not_found_with_suggestions _ -> `Not_found
  | Binary_file _ | Invalid_utf8 _ -> `Invalid_input
  | Cancelled -> `Failed

let error_message = function
  | Fs (Fs.Error.Workspace error) -> Workspace.Resolve_error.message error
  | Fs (Fs.Error.Not_found path) ->
      Workspace.Path.display path ^ ": path does not exist"
  | Not_found_with_suggestions (path, suggestions) ->
      let message = Workspace.Path.display path ^ ": path does not exist" in
      if List.is_empty suggestions then message
      else
        message ^ ". Did you mean: "
        ^ String.concat ", " (List.map Workspace.Path.display suggestions)
        ^ "?"
  | Fs (Fs.Error.Escapes_workspace path) ->
      Workspace.Path.display path ^ ": path resolves outside workspace"
  | Fs (Fs.Error.Unexpected_kind { path; _ }) ->
      Workspace.Path.display path ^ ": not a regular text file"
  | Binary_file path -> Workspace.Path.display path ^ ": binary file"
  | Invalid_utf8 path -> Workspace.Path.display path ^ ": not valid UTF-8 text"
  | Fs (Fs.Error.Io (None, _)) -> "filesystem I/O error"
  | Fs (Fs.Error.Io (Some path, _)) ->
      Workspace.Path.display path ^ ": filesystem I/O error"
  | Cancelled -> "tool call cancelled"

let permissions ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ -> []
  | Ok path ->
      [
        Permission.Request.of_accesses ~source:name
          [ Permission.Access.path ~op:`Read path ];
      ]

let default_cancelled () = false

let run_file ~fs ~workspace ~cancelled ~path input =
  let max_bytes =
    Option.value (Input.max_bytes input) ~default:default_max_bytes
  in
  match read_text ~workspace ~fs ~path ~input ~max_bytes ~cancelled with
  | Error Cancelled ->
      Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  | Error error ->
      Tool.Result.failed (failure_of_error error) (error_message error)
  | Ok output -> (
      match (Input.if_identity input, Output.complete_identity output) with
      | Some requested, Some actual
        when Spice_digest.Identity.equal requested actual ->
          Tool.Result.completed ~output:(Output.as_unchanged actual output) ()
      | Some _, _ | None, _ -> Tool.Result.completed ~output ())

let run_listing ~fs ~workspace ~cancelled ~path input =
  match Input.if_identity input with
  | Some _ ->
      Tool.Result.failed `Invalid_input
        (Workspace.Path.display path
        ^ ": if_identity cannot be used with a directory")
  | None -> (
      match list_entries ~fs ~workspace ~cancelled path with
      | Error Cancelled ->
          Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true
            ()
      | Error error ->
          Tool.Result.failed (failure_of_error error) (error_message error)
      | Ok entries ->
          let offset, limit = listing_window (Input.range input) in
          Tool.Result.completed
            ~output:(build_listing ~path ~offset ~limit entries)
            ())

let run ~fs ~workspace ?(cancelled = default_cancelled) input =
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Fs.resolve ~workspace (Input.path input) with
    | Error error ->
        let error = fs_error ~fs ~workspace error in
        Tool.Result.failed (failure_of_error error) (error_message error)
    | Ok path -> (
        match Fs.stat ~fs ~workspace ~follow_symlink:true path with
        | Error error ->
            let error = fs_error ~fs ~workspace error in
            Tool.Result.failed (failure_of_error error) (error_message error)
        | Ok None ->
            let error =
              Not_found_with_suggestions
                (path, path_suggestions ~fs ~workspace path)
            in
            Tool.Result.failed (failure_of_error error) (error_message error)
        | Ok (Some stat) -> (
            match stat.Eio.File.Stat.kind with
            | `Directory -> run_listing ~fs ~workspace ~cancelled ~path input
            | `Regular_file -> run_file ~fs ~workspace ~cancelled ~path input
            | `Symbolic_link | `Unknown | `Fifo | `Character_special
            | `Block_device | `Socket ->
                Tool.Result.failed `Invalid_input
                  (Workspace.Path.display path
                  ^ ": not a readable file or directory")))

let tool ~fs ~workspace ?(conditional_read = false) ?(render = Output.numbered)
    () =
  Tool.make ~name ~description
    ~input:(Input.contract ~conditional_read)
    ~output:(Output.encode ~render)
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ~cancelled:(fun () -> Tool.Context.cancelled ctx) input)
    ()
