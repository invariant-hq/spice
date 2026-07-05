(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "write_file"
let default_max_file_bytes = 1024 * 1024
let description = Spice_prompts.Tools.write_file

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()
let file_identity = Spice_digest.Identity.of_contents

let validate_text text =
  if not (String.is_valid_utf_8 text) then
    invalid_arg "contents must be valid UTF-8";
  if Text_helpers.looks_binary text then
    invalid_arg "contents must be UTF-8 text"

module Input = struct
  type precondition = Missing | Identity of Spice_digest.Identity.t
  type t = { path : string; contents : string; precondition : precondition }

  let validate_path path =
    if String.is_empty path then invalid_arg "path must not be empty"

  let make ~path ~precondition ~contents =
    validate_path path;
    validate_text contents;
    { path; contents; precondition }

  let path t = t.path
  let contents (t : t) = t.contents
  let precondition t = t.precondition

  let if_identity t =
    match t.precondition with
    | Missing -> None
    | Identity identity -> Some identity

  let make_from_json_fields path contents if_identity =
    match if_identity with
    | None -> make ~path ~precondition:Missing ~contents
    | Some value -> (
        match Spice_digest.Identity.of_string value with
        | Error error ->
            invalid_arg
              ("if_identity is not a file identity: "
              ^ Spice_digest.Identity.Parse_error.message error)
        | Ok if_identity ->
            make ~path ~precondition:(Identity if_identity) ~contents)

  let codec =
    Jsont.Object.map ~kind:"write_file input" (fun path contents if_identity ->
        decode_invalid_arg (fun () ->
            make_from_json_fields path contents if_identity))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.mem "contents" Jsont.string ~enc:contents
    |> Jsont.Object.opt_mem "if_identity" Jsont.string ~enc:(fun t ->
        Option.map Spice_digest.Identity.to_string (if_identity t))
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
                         file path to write." );
                  ] );
              ( "contents",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string "Complete UTF-8 file contents to write." );
                  ] );
              ( "if_identity",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Complete-file identity from a previous complete read. \
                         Required to replace an existing file. Omit only to \
                         create a missing file." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "path"; Json.string "contents" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Output = struct
  type stale_check = Fresh | Not_checked

  type status =
    | Created of Spice_digest.Identity.t
    | Modified of {
        before : Spice_digest.Identity.t;
        after : Spice_digest.Identity.t;
      }
    | Unchanged of Spice_digest.Identity.t

  type t = {
    path : Workspace.Path.t;
    contents : string;
    status : status;
    edit : Edit.Result.t option;
    created_directories : Workspace.Path.t list;
  }

  let make ~path ~contents ~status ~edit ~created_directories =
    { path; contents; status; edit; created_directories }

  let path t = t.path
  let contents (t : t) = t.contents

  let identity t =
    match t.status with
    | Created identity | Unchanged identity -> identity
    | Modified { after; _ } -> after

  let receipt t =
    Option.value
      (Option.map (fun edit -> Receipt.make edit) t.edit)
      ~default:Receipt.empty

  let status_to_operation = function
    | Created _ -> "create"
    | Modified _ -> "modify"
    | Unchanged _ -> "unchanged"

  let stale_check_to_string = function
    | Fresh -> "fresh"
    | Not_checked -> "not_checked"

  let before_identity = function
    | Modified { before; _ } -> Some before
    | Created _ | Unchanged _ -> None

  let text t =
    let path = Workspace.Path.display (path t) in
    match t.status with
    | Created identity ->
        Printf.sprintf "create: %s identity=%s\n" path
          (Spice_digest.Identity.to_string identity)
    | Modified { before; after } ->
        Printf.sprintf "modify: %s before=%s after=%s stale_check=fresh\n" path
          (Spice_digest.Identity.to_string before)
          (Spice_digest.Identity.to_string after)
    | Unchanged identity ->
        Printf.sprintf "unchanged: %s identity=%s stale_check=fresh\n" path
          (Spice_digest.Identity.to_string identity)

  let json t =
    let status = t.status in
    let stale_check =
      match t.status with
      | Created _ -> Not_checked
      | Modified _ | Unchanged _ -> Fresh
    in
    let fields =
      [
        ("path", Json.string (Workspace.Path.display (path t)));
        ("operation", Json.string (status_to_operation status));
        ("identity", Json.string (Spice_digest.Identity.to_string (identity t)));
        ("stale_check", Json.string (stale_check_to_string stale_check));
        ( "created_directories",
          Json.list
            (List.map
               (fun path -> Json.string (Workspace.Path.display path))
               t.created_directories) );
        ( "before_identity",
          match before_identity status with
          | None -> json_null
          | Some identity ->
              Json.string (Spice_digest.Identity.to_string identity) );
      ]
    in
    json_obj fields

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let utf8_bom = "\239\187\191"
let has_utf8_bom text = String.starts_with ~prefix:utf8_bom text

let preserve_bom current contents =
  if has_utf8_bom current && not (has_utf8_bom contents) then
    utf8_bom ^ contents
  else contents

let failed kind message = Tool.Result.failed kind message
let failed_edit = Edit_error.failed

let apply ~fs ~workspace ~max_bytes plan =
  let io, created_directories =
    Fs.Edit.io ~fs ~workspace ~max_bytes ~create_parent_dirs:true
      ~remove_error:"write_file cannot delete files" ()
  in
  Edit.apply ~io ~workspace plan
  |> Result.map (fun result -> (result, created_directories ()))
  |> Result.map_error (fun error -> failed_edit (Edit.Apply_error.error error))

let output_created ~path ~contents ~edit ~created_directories =
  let identity = file_identity contents in
  Output.make ~path ~contents ~status:(Output.Created identity)
    ~edit:(Some edit) ~created_directories

let output_modified ~path ~before ~contents ~edit =
  let before = file_identity before in
  let after = file_identity contents in
  Output.make ~path ~contents
    ~status:(Output.Modified { before; after })
    ~edit:(Some edit) ~created_directories:[]

let output_unchanged ~path ~contents =
  let identity = file_identity contents in
  Output.make ~path ~contents ~status:(Output.Unchanged identity) ~edit:None
    ~created_directories:[]

let create ~fs ~workspace ~max_bytes path contents =
  if String.length contents > max_bytes then
    failed_edit
      (Edit.Error.too_large ~path
         ~size:(Int64.of_int (String.length contents))
         ~max_size:(Int64.of_int max_bytes))
  else
    match Edit.create ~path ~contents with
    | Error error -> failed_edit error
    | Ok plan -> (
        match apply ~fs ~workspace ~max_bytes plan with
        | Error result -> result
        | Ok (edit, created_directories) ->
            Tool.Result.completed
              ~output:
                (output_created ~path ~contents ~edit ~created_directories)
              ())

let stale path =
  failed `Stale (Workspace.Path.display path ^ ": stale file identity")

let replace ~fs ~workspace ~max_bytes path expected contents =
  match Fs.Edit.read_text ~fs ~workspace ~max_bytes path with
  | Error (Edit.Error.State_mismatch { actual = `Missing; _ }) ->
      (* A replace precondition for a file that does not exist: the identity
         guard protects against overwriting contents the model has not seen,
         and a missing file has none, so honor the write as a create.
         Reference tools (Claude Code's Write, codex's apply_patch) are
         create-or-overwrite here. *)
      create ~fs ~workspace ~max_bytes path contents
  | Error error -> failed_edit error
  | Ok current -> (
      let actual = file_identity current in
      if not (Spice_digest.Identity.equal expected actual) then stale path
      else
        let contents = preserve_bom current contents in
        if String.equal current contents then
          Tool.Result.completed ~output:(output_unchanged ~path ~contents) ()
        else
          match Edit.rewrite ~path ~before:current ~after:contents with
          | Error error -> failed_edit error
          | Ok plan -> (
              match apply ~fs ~workspace ~max_bytes plan with
              | Error result -> result
              | Ok (edit, _) ->
                  Tool.Result.completed
                    ~output:
                      (output_modified ~path ~before:current ~contents ~edit)
                    ()))

let permissions ~workspace input =
  match Workspace.resolve_string workspace (Input.path input) with
  | Error _ -> []
  | Ok path ->
      let op, evidence =
        match Input.precondition input with
        | Input.Missing ->
            (`Create, Change_evidence.creation ~path (Input.contents input))
        | Input.Identity _ ->
            (`Modify, Change_evidence.replacement ~path (Input.contents input))
      in
      let access = Permission.Access.path ~op path in
      [
        Permission.Request.make ~source:name
          [ Permission.Request.Item.make ~change:evidence access ];
      ]

let default_cancelled () = false

let run ~fs ~workspace ?(max_file_bytes = default_max_file_bytes)
    ?(cancelled = default_cancelled) input =
  if max_file_bytes < 0 then invalid_arg "max_file_bytes must be non-negative";
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Fs.resolve ~workspace (Input.path input) with
    | Error error -> Fs_error.failed ~message:(Fs.Error.message error) error
    | Ok path -> (
        match Input.precondition input with
        | Input.Missing ->
            create ~fs ~workspace ~max_bytes:max_file_bytes path
              (Input.contents input)
        | Input.Identity expected ->
            replace ~fs ~workspace ~max_bytes:max_file_bytes path expected
              (Input.contents input))

let tool ~fs ~workspace ?max_file_bytes () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ?max_file_bytes
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
