(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "edit_file"
let default_max_file_bytes = 1024 * 1024
let utf8_bom = "\239\187\191"
let json_null = Json.null ()
let description = Spice_prompts.Tools.edit_file

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let file_identity = Spice_digest.Identity.of_contents

let validate_text_arg name text =
  if not (String.is_valid_utf_8 text) then
    invalid_arg (name ^ " must be valid UTF-8");
  if Text_helpers.looks_binary text then
    invalid_arg (name ^ " must be UTF-8 text")

module Input = struct
  type occurrence = Once | All

  type t = {
    path : string;
    old_string : string;
    new_string : string;
    occurrence : occurrence;
    if_identity : Spice_digest.Identity.t option;
  }

  let replace ~path ~old_string ~new_string ?(occurrence = Once) ?if_identity ()
      =
    if String.is_empty path then invalid_arg "path must not be empty";
    if String.is_empty old_string then
      invalid_arg "old_string must not be empty";
    if String.equal old_string new_string then
      invalid_arg "old_string and new_string must differ";
    validate_text_arg "old_string" old_string;
    validate_text_arg "new_string" new_string;
    { path; old_string; new_string; occurrence; if_identity }

  let path t = t.path
  let old_string t = t.old_string
  let new_string t = t.new_string
  let occurrence t = t.occurrence
  let if_identity t = t.if_identity
  let all_occurrences t = match t.occurrence with Once -> false | All -> true
  let occurrence_to_string = function Once -> "once" | All -> "all"

  let occurrence_of_string = function
    | "once" -> Once
    | "all" -> All
    | value -> invalid_arg ("occurrence must be \"once\" or \"all\": " ^ value)

  let make_from_json_fields path old_string new_string occurrence if_identity =
    let occurrence = Option.map occurrence_of_string occurrence in
    let if_identity =
      match if_identity with
      | None -> None
      | Some "" ->
          invalid_arg
            "if_identity must be the identity from a complete read_file \
             result; omit it when no identity is known"
      | Some value -> (
          match Spice_digest.Identity.of_string value with
          | Error error ->
              invalid_arg
                ("if_identity is not a file identity: "
                ^ Spice_digest.Identity.Parse_error.message error
                ^ "; copy the identity string from a complete read_file result \
                   verbatim, or omit it")
          | Ok identity -> Some identity)
    in
    replace ~path ~old_string ~new_string ?occurrence ?if_identity ()

  let codec =
    Jsont.Object.map ~kind:"edit_file input"
      (fun path old_string new_string occurrence if_identity ->
        decode_invalid_arg (fun () ->
            make_from_json_fields path old_string new_string occurrence
              if_identity))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.mem "old_string" Jsont.string ~enc:old_string
    |> Jsont.Object.mem "new_string" Jsont.string ~enc:new_string
    |> Jsont.Object.opt_mem "occurrence" Jsont.string ~enc:(fun t ->
        match t.occurrence with Once -> None | All -> Some "all")
    |> Jsont.Object.opt_mem "if_identity" Jsont.string ~enc:(fun t ->
        Option.map Spice_digest.Identity.to_string t.if_identity)
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
              ( "old_string",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Exact non-empty text to replace. By default it must \
                         occur exactly once." );
                  ] );
              ( "new_string",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Replacement text. It must differ from old_string and \
                         may be empty." );
                  ] );
              ( "occurrence",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("enum", Json.list [ Json.string "once"; Json.string "all" ]);
                    ( "description",
                      Json.string
                        "Replacement multiplicity. Defaults to once; all \
                         replaces every non-overlapping occurrence." );
                  ] );
              ( "if_identity",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Complete-file identity from a previous complete \
                         read_file observation." );
                  ] );
            ] );
        ( "required",
          Json.list
            [
              Json.string "path";
              Json.string "old_string";
              Json.string "new_string";
            ] );
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Output = struct
  type stale_check = Fresh of Spice_digest.Identity.t | Not_checked

  type status =
    | Modified of {
        before : Spice_digest.Identity.t;
        after : Spice_digest.Identity.t;
      }
    | Unchanged of Spice_digest.Identity.t

  type t = {
    path : Workspace.Path.t;
    status : status;
    stale_check : stale_check;
    replacements : int;
    occurrence : Input.occurrence;
    before_contents : string;
    after_contents : string;
    edit : Edit.Result.t option;
  }

  let make ~path ~status ~stale_check ~replacements ~occurrence ~before_contents
      ~after_contents ~edit =
    {
      path;
      status;
      stale_check;
      replacements;
      occurrence;
      before_contents;
      after_contents;
      edit;
    }

  let path t = t.path
  let replacements t = t.replacements
  let occurrence t = t.occurrence

  let identity t =
    match t.status with Modified { after; _ } | Unchanged after -> after

  let before_contents t = t.before_contents
  let after_contents t = t.after_contents

  let receipt t =
    Option.fold ~none:Receipt.empty ~some:(fun edit -> Receipt.make edit) t.edit

  let status_to_string = function
    | Modified _ -> "modify"
    | Unchanged _ -> "unchanged"

  let stale_check_to_string = function
    | Fresh _ -> "fresh"
    | Not_checked -> "not_checked"

  let before_identity = function
    | Modified { before; _ } -> Some before
    | Unchanged _ -> None

  let text t =
    Printf.sprintf "%s: %s replacements=%d identity=%s stale_check=%s\n"
      (status_to_string t.status)
      (Workspace.Path.display t.path)
      t.replacements
      (Spice_digest.Identity.to_string (identity t))
      (stale_check_to_string t.stale_check)

  let json t =
    let status = t.status in
    json_obj
      [
        ("path", Json.string (Workspace.Path.display t.path));
        ("operation", Json.string (status_to_string status));
        ("identity", Json.string (Spice_digest.Identity.to_string (identity t)));
        ("replacements", Json.int t.replacements);
        ("occurrence", Json.string (Input.occurrence_to_string t.occurrence));
        ("stale_check", Json.string (stale_check_to_string t.stale_check));
        ( "checked_identity",
          match t.stale_check with
          | Fresh identity ->
              Json.string (Spice_digest.Identity.to_string identity)
          | Not_checked -> json_null );
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
    ~remove_error:"edit_file cannot delete files" ()
  |> fst

let has_utf8_bom text = String.starts_with ~prefix:utf8_bom text
let drop_utf8_bom text = String.drop_first (String.length utf8_bom) text
let strip_utf8_bom text = if has_utf8_bom text then drop_utf8_bom text else text

type line_ending = Lf | Crlf

let target_line_ending text =
  let rec loop saw_crlf saw_lf i =
    if i >= String.length text then if saw_crlf && not saw_lf then Crlf else Lf
    else if
      Char.equal text.[i] '\r'
      && i + 1 < String.length text
      && Char.equal text.[i + 1] '\n'
    then loop true saw_lf (i + 2)
    else if Char.equal text.[i] '\n' then loop saw_crlf true (i + 1)
    else loop saw_crlf saw_lf (i + 1)
  in
  loop false false 0

let normalize_newlines_to_lf text =
  let b = Buffer.create (String.length text) in
  let rec loop i =
    if i = String.length text then Buffer.contents b
    else if Char.equal text.[i] '\r' then begin
      Buffer.add_char b '\n';
      if i + 1 < String.length text && Char.equal text.[i + 1] '\n' then
        loop (i + 2)
      else loop (i + 1)
    end
    else begin
      Buffer.add_char b text.[i];
      loop (i + 1)
    end
  in
  loop 0

let normalize_line_endings style text =
  let text = normalize_newlines_to_lf text in
  match style with
  | Lf -> text
  | Crlf ->
      let b = Buffer.create (String.length text) in
      String.iter
        (fun c ->
          if Char.equal c '\n' then Buffer.add_string b "\r\n"
          else Buffer.add_char b c)
        text;
      Buffer.contents b

let matching_contents contents =
  if has_utf8_bom contents then (`Preserve_bom, drop_utf8_bom contents)
  else (`Raw, contents)

let restore_contents mode contents =
  match mode with
  | `Preserve_bom ->
      if has_utf8_bom contents then contents else utf8_bom ^ contents
  | `Raw -> contents

let count_non_overlapping ~pattern text =
  let pattern_len = String.length pattern in
  let text_len = String.length text in
  let rec loop count i =
    if i + pattern_len > text_len then count
    else if String.equal (String.sub text i pattern_len) pattern then
      loop (count + 1) (i + pattern_len)
    else loop count (i + 1)
  in
  loop 0 0

let replace_non_overlapping ~all ~old_string ~new_string text =
  let old_len = String.length old_string in
  let text_len = String.length text in
  let b = Buffer.create (text_len + String.length new_string) in
  let rec loop replaced i =
    if i = text_len then (Buffer.contents b, replaced)
    else if
      (all || replaced = 0)
      && i + old_len <= text_len
      && String.equal (String.sub text i old_len) old_string
    then begin
      Buffer.add_string b new_string;
      loop (replaced + 1) (i + old_len)
    end
    else begin
      Buffer.add_char b text.[i];
      loop replaced (i + 1)
    end
  in
  loop 0 0

let failed_edit = Edit_error.failed

let stale path =
  Tool.Result.failed `Stale
    (Workspace.Path.display path ^ ": stale file identity")

let replacement_failure path ~occurrence matches =
  let message =
    if Int.equal matches 0 then
      Workspace.Path.display path ^ ": old_string was not found"
    else
      Printf.sprintf
        "%s: old_string matched %d times; provide more context or set \
         occurrence=all"
        (Workspace.Path.display path)
        matches
  in
  let metadata =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display path));
        ("matches", Json.int matches);
        ("occurrence", Json.string (Input.occurrence_to_string occurrence));
      ]
  in
  Tool.Result.failed ~metadata `Invalid_input message

let apply ~fs ~workspace ~max_bytes plan =
  let io = edit_io ~fs ~workspace ~max_bytes () in
  Edit.apply ~io ~workspace plan
  |> Result.map_error (fun error -> failed_edit (Edit.Apply_error.error error))

let build_output ~path ~before_contents ~after_contents ~replacements
    ~occurrence ~stale_check ~edit =
  let before = file_identity before_contents in
  let after = file_identity after_contents in
  let status =
    if String.equal before_contents after_contents then Output.Unchanged after
    else Output.Modified { before; after }
  in
  Output.make ~path ~status ~stale_check ~replacements ~occurrence
    ~before_contents ~after_contents ~edit

let interrupted () =
  Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()

let edit ~fs ~workspace ~max_bytes ~cancelled path input current =
  let before_identity = file_identity current in
  let stale_check =
    match Input.if_identity input with
    | None -> Ok Output.Not_checked
    | Some expected ->
        if Spice_digest.Identity.equal expected before_identity then
          Ok (Output.Fresh expected)
        else Error ()
  in
  match stale_check with
  | Error () -> stale path
  | Ok stale_check -> (
      let mode, match_contents = matching_contents current in
      let line_ending = target_line_ending match_contents in
      let old_argument, new_argument =
        match mode with
        | `Raw -> (Input.old_string input, Input.new_string input)
        | `Preserve_bom ->
            ( strip_utf8_bom (Input.old_string input),
              strip_utf8_bom (Input.new_string input) )
      in
      let old_string = normalize_line_endings line_ending old_argument in
      let new_string = normalize_line_endings line_ending new_argument in
      let occurrence = Input.occurrence input in
      let all_occurrences = Input.all_occurrences input in
      let matches = count_non_overlapping ~pattern:old_string match_contents in
      if matches = 0 || ((not all_occurrences) && matches <> 1) then
        replacement_failure path ~occurrence matches
      else
        let after_match_contents, replacements =
          replace_non_overlapping ~all:all_occurrences ~old_string ~new_string
            match_contents
        in
        let after_contents = restore_contents mode after_match_contents in
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
              (build_output ~path ~before_contents:current ~after_contents
                 ~replacements ~occurrence ~stale_check ~edit:None)
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
                    Tool.Result.completed
                      ~output:
                        (build_output ~path ~before_contents:current
                           ~after_contents ~replacements ~occurrence
                           ~stale_check ~edit:(Some edit))
                      ()))

let permissions ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ -> []
  | Ok path ->
      let access = Permission.Access.path ~op:`Modify path in
      let evidence =
        Change_evidence.modify ~path ~before:(Input.old_string input)
          ~after:(Input.new_string input)
      in
      [
        Permission.Request.make ~source:name
          [ Permission.Request.Item.make ~change:evidence access ];
      ]

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
        | Ok current ->
            edit ~fs ~workspace ~max_bytes:max_file_bytes ~cancelled path input
              current)

let tool ~fs ~workspace ?max_file_bytes () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ?max_file_bytes
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
