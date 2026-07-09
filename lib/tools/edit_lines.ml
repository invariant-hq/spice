(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "edit_lines"
let default_max_file_bytes = 1024 * 1024
let json_null = Json.null ()
let description = Spice_prompts.Tools.edit_lines

(* The model-visible anchor delimiter, dirac's [§]. An edit names a line as
   ["AppleBanana§exact line text"]: the anchor word, the delimiter, then the
   line's current text. *)
let anchor_delimiter = "\xc2\xa7"

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let file_identity = Spice_digest.Identity.of_contents

let validate_text_arg name text =
  if not (String.is_valid_utf_8 text) then
    invalid_arg (name ^ " must be valid UTF-8")

module Input = struct
  type op = Replace | Insert_before | Insert_after

  let op_to_string = function
    | Replace -> "replace"
    | Insert_before -> "insert_before"
    | Insert_after -> "insert_after"

  let op_of_string = function
    | "replace" -> Replace
    | "insert_before" -> Insert_before
    | "insert_after" -> Insert_after
    | other ->
        invalid_arg
          ("unknown op: " ^ other
         ^ "; expected replace, insert_before, or insert_after")

  let validate_anchor field anchor =
    let anchor = Anchor.to_string anchor in
    if String.is_empty anchor then invalid_arg (field ^ " must not be empty");
    validate_text_arg field anchor;
    anchor

  module Range = struct
    type t = Line of Anchor.t | Between of Anchor.t * Anchor.t

    let line anchor =
      ignore (validate_anchor "anchor" anchor);
      Line anchor

    let between start finish =
      ignore (validate_anchor "anchor" start);
      ignore (validate_anchor "end_anchor" finish);
      Between (start, finish)
  end

  module Edit = struct
    type t =
      | Replace_edit of { range : Range.t; text : string }
      | Insert_before_edit of { anchor : Anchor.t; text : string }
      | Insert_after_edit of { anchor : Anchor.t; text : string }

    let validate_text text =
      validate_text_arg "text" text;
      text

    let replace range ~text = Replace_edit { range; text = validate_text text }

    let insert_before anchor ~text =
      ignore (validate_anchor "anchor" anchor);
      Insert_before_edit { anchor; text = validate_text text }

    let insert_after anchor ~text =
      ignore (validate_anchor "anchor" anchor);
      Insert_after_edit { anchor; text = validate_text text }

    let op = function
      | Replace_edit _ -> Replace
      | Insert_before_edit _ -> Insert_before
      | Insert_after_edit _ -> Insert_after

    let anchor = function
      | Replace_edit { range = Range.Line anchor; _ }
      | Replace_edit { range = Range.Between (anchor, _); _ }
      | Insert_before_edit { anchor; _ }
      | Insert_after_edit { anchor; _ } ->
          Anchor.to_string anchor

    let end_anchor = function
      | Replace_edit { range = Range.Line anchor; _ } ->
          Some (Anchor.to_string anchor)
      | Replace_edit { range = Range.Between (_, anchor); _ } ->
          Some (Anchor.to_string anchor)
      | Insert_before_edit _ | Insert_after_edit _ -> None

    let text = function
      | Replace_edit { text; _ }
      | Insert_before_edit { text; _ }
      | Insert_after_edit { text; _ } ->
          text

    let make_raw ~op ~anchor ?end_anchor ~text () =
      try
        let edit =
          if String.is_empty anchor then invalid_arg "anchor must not be empty";
          begin match (op, end_anchor) with
          | Replace, None -> invalid_arg "replace requires end_anchor"
          | Replace, Some end_anchor when String.is_empty end_anchor ->
              invalid_arg "end_anchor must not be empty"
          | (Insert_before | Insert_after), Some _ ->
              invalid_arg
                ("end_anchor is only valid for replace, not " ^ op_to_string op)
          | Replace, Some _ | (Insert_before | Insert_after), None -> ()
          end;
          validate_text_arg "anchor" anchor;
          Option.iter (validate_text_arg "end_anchor") end_anchor;
          let anchor = Anchor.of_string anchor in
          match op with
          | Replace ->
              let end_anchor =
                match end_anchor with
                | None -> assert false
                | Some end_anchor -> Anchor.of_string end_anchor
              in
              replace (Range.between anchor end_anchor) ~text
          | Insert_before -> insert_before anchor ~text
          | Insert_after -> insert_after anchor ~text
        in
        Ok edit
      with Invalid_argument message -> Error message

    let codec =
      Jsont.Object.map ~kind:"edit_lines edit" (fun op anchor end_anchor text ->
          decode_invalid_arg (fun () ->
              let op = op_of_string op in
              match make_raw ~op ~anchor ?end_anchor ~text () with
              | Ok edit -> edit
              | Error message -> invalid_arg message))
      |> Jsont.Object.mem "op" Jsont.string ~enc:(fun t -> op_to_string (op t))
      |> Jsont.Object.mem "anchor" Jsont.string ~enc:anchor
      |> Jsont.Object.opt_mem "end_anchor" Jsont.string ~enc:end_anchor
      |> Jsont.Object.mem "text" Jsont.string ~enc:text
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
  end

  type t = { path : string; edits : Edit.t list }

  let make ~path ~edits () =
    if String.is_empty path then invalid_arg "path must not be empty";
    if List.is_empty edits then invalid_arg "edits must not be empty";
    { path; edits }

  let path t = t.path
  let edits t = t.edits

  let codec =
    Jsont.Object.map ~kind:"edit_lines input" (fun path edits ->
        decode_invalid_arg (fun () -> make ~path ~edits ()))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.mem "edits" (Jsont.list Edit.codec) ~enc:edits
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
                         existing file path to edit." );
                  ] );
              ( "edits",
                json_obj
                  [
                    ("type", Json.string "array");
                    ( "description",
                      Json.string
                        "Non-overlapping anchored edits for this file, \
                         validated together and applied bottom-up." );
                    ( "items",
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
                                          ] );
                                      ( "description",
                                        Json.string "The edit operation." );
                                    ] );
                                ( "anchor",
                                  json_obj
                                    [
                                      ("type", Json.string "string");
                                      ( "description",
                                        Json.string
                                          "Anchor for the edited line or \
                                           insertion point, in the form \
                                           \"AppleBanana\xc2\xa7exact line \
                                           text\". Single line only." );
                                    ] );
                                ( "end_anchor",
                                  json_obj
                                    [
                                      ("type", Json.string "string");
                                      ( "description",
                                        Json.string
                                          "Anchor for the inclusive end of a \
                                           replace range, same form as anchor. \
                                           Required for replace, forbidden \
                                           otherwise." );
                                    ] );
                                ( "text",
                                  json_obj
                                    [
                                      ("type", Json.string "string");
                                      ( "description",
                                        Json.string
                                          "Replacement or inserted text. Use \
                                           \\n between lines. Empty text \
                                           deletes a replace range." );
                                    ] );
                              ] );
                          ( "required",
                            Json.list
                              [
                                Json.string "op";
                                Json.string "anchor";
                                Json.string "text";
                              ] );
                          ("additionalProperties", Json.bool false);
                        ] );
                  ] );
            ] );
        ("required", Json.list [ Json.string "path"; Json.string "edits" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Output = struct
  type status =
    | Modified of {
        before : Spice_digest.Identity.t;
        after : Spice_digest.Identity.t;
      }
    | Unchanged of Spice_digest.Identity.t

  type t = {
    path : Workspace.Path.t;
    status : status;
    edits : int;
    before_contents : string;
    after_contents : string;
    edit : Edit.Result.t option;
  }

  let make ~path ~status ~edits ~before_contents ~after_contents ~edit =
    { path; status; edits; before_contents; after_contents; edit }

  let path t = t.path
  let edits t = t.edits

  let identity t =
    match t.status with Modified { after; _ } | Unchanged after -> after

  let before_contents t = t.before_contents
  let after_contents t = t.after_contents

  let receipt t =
    Option.fold ~none:Receipt.empty ~some:(fun edit -> Receipt.make edit) t.edit

  let status_to_string = function
    | Modified _ -> "modify"
    | Unchanged _ -> "unchanged"

  let before_identity = function
    | Modified { before; _ } -> Some before
    | Unchanged _ -> None

  let text t =
    Printf.sprintf "%s: %s edits=%d identity=%s\n"
      (status_to_string t.status)
      (Workspace.Path.display t.path)
      t.edits
      (Spice_digest.Identity.to_string (identity t))

  let json t =
    let status = t.status in
    json_obj
      [
        ("path", Json.string (Workspace.Path.display t.path));
        ("operation", Json.string (status_to_string status));
        ("identity", Json.string (Spice_digest.Identity.to_string (identity t)));
        ("edits", Json.int t.edits);
        ( "before_identity",
          match before_identity status with
          | None -> json_null
          | Some identity ->
              Json.string (Spice_digest.Identity.to_string identity) );
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
    ~remove_error:"edit_lines cannot delete files" ()
  |> fst

let failed_edit = Edit_error.failed

let interrupted () =
  Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()

let apply ~fs ~workspace ~max_bytes plan =
  let io = edit_io ~fs ~workspace ~max_bytes () in
  Edit.apply ~io ~workspace plan
  |> Result.map_error (fun error -> failed_edit (Edit.Apply_error.error error))

(* Logical lines with per-line ending preservation: untouched lines keep
   their exact bytes when the file is reassembled. The dominant style ends
   inserted lines; a file is CRLF-styled iff it contains CRLF and no bare
   LF, mirroring [Edit_file]. *)

type line = { text : string; ending : string }

let dominant_ending content =
  let rec loop saw_crlf saw_lf i =
    if i >= String.length content then
      if saw_crlf && not saw_lf then "\r\n" else "\n"
    else if
      Char.equal content.[i] '\r'
      && i + 1 < String.length content
      && Char.equal content.[i + 1] '\n'
    then loop true saw_lf (i + 2)
    else if Char.equal content.[i] '\n' then loop saw_crlf true (i + 1)
    else loop saw_crlf saw_lf (i + 1)
  in
  loop false false 0

let split_lines content =
  let default = dominant_ending content in
  let raw = String.split_on_char '\n' content in
  let rec loop acc = function
    | [] -> (List.rev acc, true)
    | [ last ] ->
        if String.is_empty last then (List.rev acc, true)
        else (List.rev ({ text = last; ending = default } :: acc), false)
    | segment :: rest ->
        let line =
          let length = String.length segment in
          if length > 0 && Char.equal segment.[length - 1] '\r' then
            { text = String.sub segment 0 (length - 1); ending = "\r\n" }
          else { text = segment; ending = "\n" }
        in
        loop (line :: acc) rest
  in
  if String.is_empty content then ([], true) else loop [] raw

let join_lines lines ~ends_newline =
  let b = Buffer.create 1024 in
  let rec loop = function
    | [] -> ()
    | [ last ] ->
        Buffer.add_string b last.text;
        if ends_newline then Buffer.add_string b last.ending
    | line :: rest ->
        Buffer.add_string b line.text;
        Buffer.add_string b line.ending;
        loop rest
  in
  loop lines;
  Buffer.contents b

let text_lines ~ending text =
  if String.is_empty text then []
  else
    String.split_on_char '\n' text
    |> List.map (fun segment ->
        let length = String.length segment in
        let text =
          if length > 0 && Char.equal segment.[length - 1] '\r' then
            String.sub segment 0 (length - 1)
          else segment
        in
        { text; ending })

(* Anchor resolution. Every edit resolves through the resolver before any
   mutation; the batch is all-or-nothing. Anchor-not-found and line-text
   mismatches are stale failures carrying expected-versus-provided text and
   reread guidance; malformed anchors and overlapping ranges are invalid
   input. *)

type diagnostic = { stale : bool; message : string }

let is_anchor_word word =
  (not (String.is_empty word))
  && (match word.[0] with 'A' .. 'Z' -> true | _ -> false)
  && String.for_all
       (function 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false)
       word

let find_substring ~sub text =
  let sub_len = String.length sub in
  let text_len = String.length text in
  let rec loop i =
    if i + sub_len > text_len then None
    else if String.equal (String.sub text i sub_len) sub then Some i
    else loop (i + 1)
  in
  loop 0

let split_anchor raw =
  match find_substring ~sub:anchor_delimiter raw with
  | None -> (String.trim raw, None)
  | Some cut ->
      let content_start = cut + String.length anchor_delimiter in
      ( String.trim (String.sub raw 0 cut),
        Some (String.drop_first content_start raw) )

let resolve_anchor ~(resolver : Anchor.Resolver.t) ~path ~field raw =
  let word, content = split_anchor raw in
  if not (is_anchor_word word) then
    Error
      {
        stale = false;
        message =
          Printf.sprintf
            "%s %S is not a valid anchor: expected \"AnchorWord\xc2\xa7exact \
             line text\""
            field raw;
      }
  else
    let content = Option.value content ~default:"" in
    if String.contains content '\n' || String.contains content '\r' then
      Error
        {
          stale = false;
          message = Printf.sprintf "%s %S must name a single line" field word;
        }
    else
      match
        resolver.Anchor.Resolver.resolve ~path ~anchor:word ~expected:content
      with
      | Ok index -> Ok index
      | Error error ->
          Error
            {
              stale = true;
              message = field ^ ": " ^ Anchor.Resolver.error_message error;
            }

(* A resolved edit as a bottom-up line splice: [index] is the zero-based
   insertion point, [removed] the replaced line count, and [range] the
   inclusive one-based line span the edit claims for overlap checks. *)
type resolved = {
  index : int;
  removed : int;
  range : int * int;
  replacement : line list;
}

let resolve_edit ~resolver ~path ~ending spec =
  let replacement = text_lines ~ending (Input.Edit.text spec) in
  match
    resolve_anchor ~resolver ~path ~field:"anchor" (Input.Edit.anchor spec)
  with
  | Error _ as error -> error
  | Ok start -> (
      match Input.Edit.op spec with
      | Input.Insert_before ->
          Ok
            {
              index = start - 1;
              removed = 0;
              range = (start, start);
              replacement;
            }
      | Input.Insert_after ->
          Ok { index = start; removed = 0; range = (start, start); replacement }
      | Input.Replace -> (
          match
            resolve_anchor ~resolver ~path ~field:"end_anchor"
              (Option.get (Input.Edit.end_anchor spec))
          with
          | Error _ as error -> error
          | Ok finish ->
              if finish < start then
                Error
                  {
                    stale = false;
                    message =
                      Printf.sprintf
                        "range error: anchor (line %d) must not come after \
                         end_anchor (line %d)"
                        start finish;
                  }
              else
                Ok
                  {
                    index = start - 1;
                    removed = finish - start + 1;
                    range = (start, finish);
                    replacement;
                  }))

let overlap resolved =
  let ranges =
    List.stable_sort
      (fun a b -> Int.compare (fst a.range) (fst b.range))
      resolved
  in
  let rec loop = function
    | first :: (second :: _ as rest) ->
        if snd first.range >= fst second.range then
          Some (first.range, second.range)
        else loop rest
    | [ _ ] | [] -> None
  in
  loop ranges

let splice lines { index; removed; replacement; range = _ } =
  let rec loop i = function
    | rest when i = index -> replacement @ drop removed rest
    | line :: rest -> line :: loop (i + 1) rest
    | [] -> replacement
  and drop n rest =
    if n = 0 then rest
    else match rest with [] -> [] | _ :: rest -> drop (n - 1) rest
  in
  loop 0 lines

let apply_edits lines resolved =
  let rec reverse_equal_index_group index acc group = function
    | edit :: rest when edit.index = index ->
        reverse_equal_index_group index acc (edit :: group) rest
    | rest -> (List.rev_append group acc, rest)
  in
  let rec reverse_equal_index_groups acc = function
    | [] -> List.rev acc
    | edit :: rest ->
        let group, rest =
          reverse_equal_index_group edit.index acc [ edit ] rest
        in
        reverse_equal_index_groups group rest
  in
  let bottom_up =
    List.stable_sort (fun a b -> Int.compare b.index a.index) resolved
    |> reverse_equal_index_groups []
  in
  List.fold_left splice lines bottom_up

let resolution_failure diagnostics =
  let stale = List.exists (fun diagnostic -> diagnostic.stale) diagnostics in
  let message =
    String.concat "\n"
      (List.map (fun diagnostic -> diagnostic.message) diagnostics)
  in
  Tool.Result.failed (if stale then `Stale else `Invalid_input) message

let build_output ~path ~edits ~before_contents ~after_contents ~edit =
  let before = file_identity before_contents in
  let after = file_identity after_contents in
  let status =
    if String.equal before_contents after_contents then Output.Unchanged after
    else Output.Modified { before; after }
  in
  Output.make ~path ~status ~edits ~before_contents ~after_contents ~edit

let edit ~fs ~workspace ~(resolver : Anchor.Resolver.t) ~max_bytes ~cancelled
    path input current =
  let lines, ends_newline = split_lines current in
  let ending = dominant_ending current in
  resolver.Anchor.Resolver.reconcile ~path
    ~lines:(List.map (fun line -> line.text) lines);
  let resolved, diagnostics =
    List.fold_left
      (fun (resolved, diagnostics) spec ->
        match resolve_edit ~resolver ~path ~ending spec with
        | Ok edit -> (edit :: resolved, diagnostics)
        | Error diagnostic -> (resolved, diagnostic :: diagnostics))
      ([], []) (Input.edits input)
  in
  let resolved = List.rev resolved in
  match List.rev diagnostics with
  | _ :: _ as diagnostics -> resolution_failure diagnostics
  | [] -> (
      match overlap resolved with
      | Some ((a_start, a_end), (b_start, b_end)) ->
          Tool.Result.failed `Invalid_input
            (Printf.sprintf
               "overlapping edits: lines %d-%d and %d-%d; batch only \
                non-overlapping edits"
               a_start a_end b_start b_end)
      | None -> (
          let edits = List.length resolved in
          let after_lines = apply_edits lines resolved in
          let after_contents = join_lines after_lines ~ends_newline in
          if String.length after_contents > max_bytes then
            failed_edit
              (Edit.Error.too_large ~path
                 ~size:(Int64.of_int (String.length after_contents))
                 ~max_size:(Int64.of_int max_bytes))
          else if Text_helpers.looks_binary after_contents then
            failed_edit (Edit.Error.invalid_text ~path "binary file")
          else if String.equal current after_contents then
            Tool.Result.completed
              ~output:
                (build_output ~path ~edits ~before_contents:current
                   ~after_contents ~edit:None)
              ()
          else
            match Edit.rewrite ~path ~before:current ~after:after_contents with
            | Error error -> failed_edit error
            | Ok plan -> (
                if cancelled () then interrupted ()
                else
                  match apply ~fs ~workspace ~max_bytes plan with
                  | Error result -> result
                  | Ok edit ->
                      resolver.Anchor.Resolver.reconcile ~path
                        ~lines:(List.map (fun line -> line.text) after_lines);
                      Tool.Result.completed
                        ~output:
                          (build_output ~path ~edits ~before_contents:current
                             ~after_contents ~edit:(Some edit))
                        ())))

let permissions ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ -> []
  | Ok path ->
      let access = Permission.Access.path ~op:`Modify path in
      (* Input-only planned-change evidence: the provided anchor line texts
         stand for the replaced content and the edit texts for the new
         content. Planning never reads the file. *)
      let provided_lines spec =
        let _, anchor_content = split_anchor (Input.Edit.anchor spec) in
        let end_content =
          Option.map
            (fun raw -> snd (split_anchor raw))
            (Input.Edit.end_anchor spec)
        in
        List.filter_map Fun.id [ anchor_content; Option.join end_content ]
      in
      let before =
        String.concat "\n" (List.concat_map provided_lines (Input.edits input))
      in
      let after =
        String.concat "\n" (List.map Input.Edit.text (Input.edits input))
      in
      let evidence = Change_evidence.modify ~path ~before ~after in
      [
        Permission.Request.make ~source:name
          [ Permission.Request.Item.make ~change:evidence access ];
      ]

let default_cancelled () = false

let run ~fs ~workspace ~resolver ?(max_file_bytes = default_max_file_bytes)
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
        | Ok current ->
            edit ~fs ~workspace ~resolver ~max_bytes:max_file_bytes ~cancelled
              path input current)

let tool ~fs ~workspace ~resolver ?max_file_bytes () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ~resolver ?max_file_bytes
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
