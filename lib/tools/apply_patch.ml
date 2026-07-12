(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Patch = Spice_patch

let name = "apply_patch"
let default_max_file_bytes = 1024 * 1024
let json_null = Json.null ()
let description = Spice_prompts.Tools.apply_patch

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

module Input = struct
  type t = { patch : string; operations : Patch.Operation.t list }

  let make ~patch =
    if String.is_empty patch then Error "patch must not be empty"
    else
      match Patch.parse patch with
      | Ok operations -> Ok { patch; operations }
      | Error error -> Error (Patch.Error.message error)

  let patch t = t.patch
  let operations t = t.operations

  let make_from_json patch =
    match make ~patch with
    | Ok input -> input
    | Error message -> invalid_arg message

  let codec =
    Jsont.Object.map ~kind:"apply_patch input" (fun patch ->
        decode_invalid_arg (fun () -> make_from_json patch))
    |> Jsont.Object.mem "patch" Jsont.string ~enc:patch
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "patch",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Complete Codex-style patch text. Patch paths must be \
                         workspace-root relative." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "patch" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Output = struct
  type kind = Create | Modify | Delete | Move of { from : Workspace.Path.t }
  type entry = { path : Workspace.Path.t; kind : kind; diff : string }

  let make_entry ~path ~kind ~diff = { path; kind; diff }
  let path t = t.path
  let kind t = t.kind

  let source_path t =
    match t.kind with
    | Move { from } -> Some from
    | Create | Modify | Delete -> None

  let entry_diff (t : entry) = t.diff

  type t = {
    entries : entry list;
    diff : string;
    edit : Edit.Result.t;
    created_directories : Workspace.Path.t list;
  }

  let make ~entries ~diff ~edit ~created_directories =
    { entries; diff; edit; created_directories }

  let entries t = t.entries
  let paths t = List.map path t.entries
  let diff (t : t) = t.diff

  let logical_change (entry : entry) =
    let kind =
      match entry.kind with
      | Create -> Receipt.Logical_change.Create
      | Modify -> Receipt.Logical_change.Modify
      | Delete -> Receipt.Logical_change.Delete
      | Move { from } -> Receipt.Logical_change.Move { from }
    in
    ({
       Receipt.Logical_change.path = entry.path;
       Receipt.Logical_change.kind;
       Receipt.Logical_change.diff = Some (entry_diff entry);
     }
      : Receipt.Logical_change.t)

  let receipt t =
    Receipt.make ~logical_changes:(List.map logical_change t.entries) t.edit

  let kind_to_string = function
    | Create -> "create"
    | Modify -> "modify"
    | Delete -> "delete"
    | Move _ -> "move"

  let summary_line t =
    match t.kind with
    | Create -> "create " ^ Workspace.Path.display t.path
    | Modify -> "modify " ^ Workspace.Path.display t.path
    | Delete -> "delete " ^ Workspace.Path.display t.path
    | Move { from } ->
        "move "
        ^ Workspace.Path.display from
        ^ " -> "
        ^ Workspace.Path.display t.path

  let text t =
    let lines =
      "Success. Updated the following files:" :: List.map summary_line t.entries
    in
    String.concat "\n" lines ^ "\n"

  let entry_json (t : entry) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display t.path));
        ("operation", Json.string (kind_to_string t.kind));
        ( "source_path",
          match source_path t with
          | None -> json_null
          | Some path -> Json.string (Workspace.Path.display path) );
        ("diff", Json.string (entry_diff t));
      ]

  let json t =
    json_obj
      [
        ("operation", Json.string "apply_patch");
        ( "paths",
          Json.list
            (List.map
               (fun path -> Json.string (Workspace.Path.display path))
               (paths t)) );
        ("changed_files", Json.list (List.map entry_json t.entries));
        ( "created_directories",
          Json.list
            (List.map
               (fun path -> Json.string (Workspace.Path.display path))
               t.created_directories) );
        ("diff", Json.string t.diff);
      ]

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

type plan_error = Fs of Fs.Error.t | Edit of Edit.Error.t | Patch of string

type planned = {
  edit : Edit.t;
  entries : Output.entry list;
  diff : string;
  create_parents : Workspace.Path.t list;
}

let abs_string path = Spice_path.Abs.to_string (Workspace.Path.abs path)
let path_key path = abs_string path
let utf8_bom = "\239\187\191"
let has_utf8_bom text = String.starts_with ~prefix:utf8_bom text
let drop_utf8_bom text = String.drop_first (String.length utf8_bom) text

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

let restore_line_endings style text =
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

let patch_contents contents =
  let bom, text =
    if has_utf8_bom contents then (`Preserve_bom, drop_utf8_bom contents)
    else (`Raw, contents)
  in
  let line_ending = target_line_ending text in
  (bom, line_ending, normalize_newlines_to_lf text)

let restore_patch_contents bom line_ending text =
  let text = restore_line_endings line_ending text in
  match bom with `Preserve_bom -> utf8_bom ^ text | `Raw -> text

let remove_dir_if_empty path =
  try Unix.rmdir (abs_string path) with Unix.Unix_error _ -> ()

let rollback_created_dirs dirs = List.iter remove_dir_if_empty (List.rev dirs)

(* [regular_opt] and [ensure_parent_dirs] can surface [Unexpected_kind], which
   apply_patch words by its own tool context rather than [Fs.Error.message]. *)
let fs_error_message = function
  | Fs.Error.Unexpected_kind { path; actual = `Symbolic_link; _ } ->
      Workspace.Path.display path ^ ": symlink targets are not supported"
  | Fs.Error.Unexpected_kind { path; _ } ->
      Workspace.Path.display path ^ ": not a regular file"
  | ( Fs.Error.Workspace _ | Fs.Error.Not_found _ | Fs.Error.Escapes_workspace _
    | Fs.Error.Io _ ) as error ->
      Fs.Error.message error

let failed_edit = Edit_error.failed

let failed_plan = function
  | Fs error -> Fs_error.failed ~message:(fs_error_message error) error
  | Edit error -> failed_edit error
  | Patch message -> Tool.Result.failed `Invalid_input message

let is_strict_ancestor ~parent path =
  let parent = path_key parent in
  let path = path_key path in
  (not (String.equal parent path))
  && (String.equal parent Filename.dir_sep
     || String.starts_with ~prefix:(parent ^ Filename.dir_sep) path)

let operation_paths workspace operation =
  let source =
    Workspace.path_at_cwd_root workspace (Patch.Operation.path operation)
  in
  let output =
    Workspace.path_at_cwd_root workspace (Patch.Operation.output_path operation)
  in
  if Workspace.Path.equal source output then [ source ] else [ source; output ]

let nested_path_conflict operations workspace =
  let paths = List.concat_map (operation_paths workspace) operations in
  let rec check_path path = function
    | [] -> None
    | candidate :: candidates ->
        if is_strict_ancestor ~parent:path candidate then Some (path, candidate)
        else if is_strict_ancestor ~parent:candidate path then
          Some (candidate, path)
        else check_path path candidates
  in
  let rec loop = function
    | [] -> None
    | path :: paths -> (
        match check_path path paths with
        | Some _ as conflict -> conflict
        | None -> loop paths)
  in
  loop paths

let nested_path_conflict_message (parent, child) =
  Printf.sprintf "%s: patch path conflicts with nested path %s"
    (Workspace.Path.display parent)
    (Workspace.Path.display child)

let check_missing ~fs ~workspace path =
  match Fs.regular_opt ~fs ~workspace path with
  | Error error -> Error (Fs error)
  | Ok None -> Ok ()
  | Ok (Some _) ->
      Error
        (Edit (Edit.Error.state_mismatch ~path ~expected:`Missing ~actual:`Text))

let check_new_contents ~max_bytes path contents =
  if not (String.is_valid_utf_8 contents) then
    Error (Edit (Edit.Error.invalid_text ~path "invalid UTF-8"))
  else if String.length contents > max_bytes then
    Error
      (Edit
         (Edit.Error.too_large ~path
            ~size:(Int64.of_int (String.length contents))
            ~max_size:(Int64.of_int max_bytes)))
  else if Text_helpers.looks_binary contents then
    Error (Edit (Edit.Error.invalid_text ~path "binary file"))
  else Ok ()

let patch_apply_error path error =
  Patch
    (Printf.sprintf "%s: %s"
       (Workspace.Path.display path)
       (Patch.Update.Error.message error))

type operation_kind = Add | Delete | Update | Move
type operation_ref = { index : int; kind : operation_kind }
type virtual_text = { contents : string; origin : Workspace.Path.t option }
type virtual_state = Missing | Text of virtual_text

type virtual_file = {
  original : Edit.State.t;
  current : virtual_state;
  last_operation : operation_ref option;
}

type virtual_files = {
  files : virtual_file Workspace.Path.Map.t;
  reverse_order : Workspace.Path.t list;
}

let empty_virtual_files =
  { files = Workspace.Path.Map.empty; reverse_order = [] }

let operation_ref index = function
  | Patch.Operation.Add _ -> { index; kind = Add }
  | Patch.Operation.Delete _ -> { index; kind = Delete }
  | Patch.Operation.Update { move_to = None; _ } -> { index; kind = Update }
  | Patch.Operation.Update { move_to = Some _; _ } -> { index; kind = Move }

let operation_kind_name = function
  | Add -> "Add"
  | Delete -> "Delete"
  | Update -> "Update"
  | Move -> "Move"

let add_initial path file state =
  {
    files = Workspace.Path.Map.add path file state.files;
    reverse_order = path :: state.reverse_order;
  }

let replace_file path file state =
  { state with files = Workspace.Path.Map.add path file state.files }

let virtual_kind = function Missing -> "missing" | Text _ -> "text"

let sequential_conflict path operation file expected =
  let previous =
    match file.last_operation with
    | Some previous ->
        Printf.sprintf "operation %d (%s)" previous.index
          (operation_kind_name previous.kind)
    | None -> "the original filesystem state"
  in
  Error
    (Patch
       (Printf.sprintf
          "%s: operation %d (%s) conflicts with %s: expected %s, found %s"
          (Workspace.Path.display path)
          operation.index
          (operation_kind_name operation.kind)
          previous expected
          (virtual_kind file.current)))

let require_missing ~fs ~workspace path operation state =
  match Workspace.Path.Map.find_opt path state.files with
  | Some ({ current = Missing; _ } as file) -> Ok (state, file)
  | Some file -> sequential_conflict path operation file "missing"
  | None -> (
      match check_missing ~fs ~workspace path with
      | Error _ as error -> error
      | Ok () ->
          let file =
            {
              original = Edit.State.Missing;
              current = Missing;
              last_operation = None;
            }
          in
          Ok (add_initial path file state, file))

let require_text ~fs ~workspace ~max_bytes path operation state =
  match Workspace.Path.Map.find_opt path state.files with
  | Some ({ current = Text text; _ } as file) -> Ok (state, file, text)
  | Some file -> sequential_conflict path operation file "text"
  | None -> (
      match Fs.Edit.read_text ~fs ~workspace ~max_bytes path with
      | Error error -> Error (Edit error)
      | Ok contents ->
          let text = { contents; origin = Some path } in
          let file =
            {
              original = Edit.State.Text contents;
              current = Text text;
              last_operation = None;
            }
          in
          Ok (add_initial path file state, file, text))

let set_current path file current operation state =
  replace_file path { file with current; last_operation = Some operation } state

let apply_update path update before =
  let bom, line_ending, patch_before = patch_contents before in
  match Patch.Update.apply update patch_before with
  | Error error -> Error (patch_apply_error path error)
  | Ok after -> Ok (restore_patch_contents bom line_ending after)

let same_move_path_error path operation =
  Error
    (Patch
       (Printf.sprintf "%s: operation %d (Move) has the same source and output"
          (Workspace.Path.display path)
          operation.index))

let plan_operation ~fs ~workspace ~max_bytes state index operation =
  let operation_ref = operation_ref index operation in
  match operation with
  | Patch.Operation.Add { path; contents } ->
      let path = Workspace.path_at_cwd_root workspace path in
      begin match check_new_contents ~max_bytes path contents with
      | Error _ as error -> error
      | Ok () -> (
          match require_missing ~fs ~workspace path operation_ref state with
          | Error _ as error -> error
          | Ok (state, file) ->
              Ok
                (set_current path file
                   (Text { contents; origin = None })
                   operation_ref state))
      end
  | Patch.Operation.Delete { path } ->
      let path = Workspace.path_at_cwd_root workspace path in
      begin match
        require_text ~fs ~workspace ~max_bytes path operation_ref state
      with
      | Error _ as error -> error
      | Ok (state, file, _) ->
          Ok (set_current path file Missing operation_ref state)
      end
  | Patch.Operation.Update { path; move_to; update } ->
      let path = Workspace.path_at_cwd_root workspace path in
      begin match
        require_text ~fs ~workspace ~max_bytes path operation_ref state
      with
      | Error _ as error -> error
      | Ok (state, file, before) -> (
          match apply_update path update before.contents with
          | Error _ as error -> error
          | Ok contents -> (
              let output_path =
                Option.fold ~none:path
                  ~some:(Workspace.path_at_cwd_root workspace)
                  move_to
              in
              match check_new_contents ~max_bytes output_path contents with
              | Error _ as error -> error
              | Ok () -> (
                  match move_to with
                  | None ->
                      Ok
                        (set_current path file
                           (Text { before with contents })
                           operation_ref state)
                  | Some _ when Workspace.Path.equal path output_path ->
                      same_move_path_error path operation_ref
                  | Some _ -> (
                      match
                        require_missing ~fs ~workspace output_path operation_ref
                          state
                      with
                      | Error _ as error -> error
                      | Ok (state, output_file) ->
                          let state =
                            set_current path file Missing operation_ref state
                          in
                          Ok
                            (set_current output_path output_file
                               (Text { contents; origin = before.origin })
                               operation_ref state)))))
      end

type final_change = {
  path : Workspace.Path.t;
  file : virtual_file;
  final_edit : Edit.t;
  final_diff : string;
}

let current_edit_state = function
  | Missing -> Edit.State.Missing
  | Text text -> Edit.State.Text text.contents

let edit_for_transition path before after =
  match (before, after) with
  | Edit.State.Missing, Edit.State.Missing -> Ok Edit.empty
  | Edit.State.Missing, Edit.State.Text contents -> Edit.create ~path ~contents
  | Edit.State.Text before, Edit.State.Missing -> Edit.delete ~path ~before
  | Edit.State.Text before, Edit.State.Text after ->
      Edit.rewrite ~path ~before ~after

let final_changes state =
  let rec loop changes = function
    | [] -> Ok (List.rev changes)
    | path :: paths ->
        let file = Workspace.Path.Map.find path state.files in
        begin match
          edit_for_transition path file.original
            (current_edit_state file.current)
        with
        | Error error -> Error (Edit error)
        | Ok edit when Edit.is_empty edit -> loop changes paths
        | Ok edit ->
            let diff = Edit.diff edit |> Spice_diff.to_string in
            loop
              ({ path; file; final_edit = edit; final_diff = diff } :: changes)
              paths
        end
  in
  loop [] (List.rev state.reverse_order)

let moved_source files change =
  match change.file.current with
  | Missing | Text { origin = None; _ } -> None
  | Text { origin = Some source; _ }
    when Workspace.Path.equal source change.path ->
      None
  | Text { origin = Some source; _ } -> (
      match Workspace.Path.Map.find_opt source files with
      | Some
          {
            original = Edit.State.Text _;
            current = Missing;
            last_operation = _;
          } ->
          Some source
      | None
      | Some { original = Edit.State.Missing; current = _; last_operation = _ }
      | Some
          { original = Edit.State.Text _; current = Text _; last_operation = _ }
        ->
          None)

let output_entries files changes =
  let by_path =
    List.fold_left
      (fun map change -> Workspace.Path.Map.add change.path change map)
      Workspace.Path.Map.empty changes
  in
  let moves, suppressed =
    List.fold_left
      (fun (moves, suppressed) change ->
        match moved_source files change with
        | None -> (moves, suppressed)
        | Some source ->
            ( Workspace.Path.Map.add change.path source moves,
              Workspace.Path.Set.add source suppressed ))
      (Workspace.Path.Map.empty, Workspace.Path.Set.empty)
      changes
  in
  List.filter_map
    (fun change ->
      if Workspace.Path.Set.mem change.path suppressed then None
      else
        let kind, diff =
          match Workspace.Path.Map.find_opt change.path moves with
          | Some source ->
              let source_change = Workspace.Path.Map.find source by_path in
              ( Output.Move { from = source },
                source_change.final_diff ^ change.final_diff )
          | None ->
              let kind =
                match (change.file.original, change.file.current) with
                | Edit.State.Missing, Text _ -> Output.Create
                | Edit.State.Text _, Text _ -> Output.Modify
                | Edit.State.Text _, Missing -> Output.Delete
                | Edit.State.Missing, Missing -> assert false
              in
              (kind, change.final_diff)
        in
        Some (Output.make_entry ~path:change.path ~kind ~diff))
    changes

let create_parent_targets changes =
  List.filter_map
    (fun change ->
      match (change.file.original, change.file.current) with
      | Edit.State.Missing, Text _ -> Some change.path
      | Edit.State.Missing, Missing
      | Edit.State.Text _, Missing
      | Edit.State.Text _, Text _ ->
          None)
    changes

let plan ~fs ~workspace ~max_bytes input =
  let operations = Input.operations input in
  match nested_path_conflict operations workspace with
  | Some conflict -> Error (Patch (nested_path_conflict_message conflict))
  | None ->
      let rec loop state index = function
        | [] -> (
            match final_changes state with
            | Error _ as error -> error
            | Ok changes -> (
                match
                  Edit.concat
                    (List.map (fun change -> change.final_edit) changes)
                with
                | Error error -> Error (Edit error)
                | Ok edit ->
                    let entries = output_entries state.files changes in
                    Ok
                      ({
                         edit;
                         entries;
                         diff =
                           String.concat "" (List.map Output.entry_diff entries);
                         create_parents = create_parent_targets changes;
                       }
                        : planned)))
        | operation :: operations -> (
            match
              plan_operation ~fs ~workspace ~max_bytes state index operation
            with
            | Error _ as error -> error
            | Ok state -> loop state (index + 1) operations)
      in
      loop empty_virtual_files 1 operations

(* Evidence renders the parsed input operations, never the planned change
   texts: an edit plan's before/after images contain file contents read from
   disk during planning, which the input-only evidence rule forbids. Hunk
   context lines are model-supplied patch input, so they are safe to render. *)
let evidence_of_operation ~path = function
  | Patch.Operation.Add { contents; _ } ->
      Some (Change_evidence.creation ~path contents)
  | Patch.Operation.Update { update; _ } ->
      let chunks = Patch.Update.chunks update in
      let side f =
        String.concat "\n"
          (List.concat_map (fun (chunk : Patch.Update.chunk) -> f chunk) chunks)
      in
      Some
        (Change_evidence.modify ~path
           ~before:(side (fun chunk -> chunk.Patch.Update.old_lines))
           ~after:(side (fun chunk -> chunk.Patch.Update.new_lines)))
  | Patch.Operation.Delete _ ->
      (* The removed contents are unknowable from input alone. *)
      None

(* Permission review is conservative and syntactic: an add may overwrite and a
   move is reviewed as source delete plus destination create. Planning after
   approval performs the precise stale-safe checks. *)
let access_evidence_of_operation ~workspace operation =
  let access op rel =
    let path = Workspace.path_at_cwd_root workspace rel in
    (Permission.Access.path ~op path, path)
  in
  match operation with
  | Patch.Operation.Add { path; _ } ->
      let access, path = access `Create path in
      [ (access, evidence_of_operation ~path operation) ]
  | Patch.Operation.Delete { path } ->
      let access =
        Permission.Access.path ~op:`Delete
          (Workspace.path_at_cwd_root workspace path)
      in
      [ (access, None) ]
  | Patch.Operation.Update { path; move_to = None; _ } ->
      let access, path = access `Modify path in
      [ (access, evidence_of_operation ~path operation) ]
  | Patch.Operation.Update { path; move_to = Some destination; _ } ->
      let delete_access =
        Permission.Access.path ~op:`Delete
          (Workspace.path_at_cwd_root workspace path)
      in
      let create_access, destination = access `Create destination in
      [
        (delete_access, None);
        (create_access, evidence_of_operation ~path:destination operation);
      ]

let syntactic_accesses ~workspace input =
  List.concat_map
    (access_evidence_of_operation ~workspace)
    (Input.operations input)

let permissions ~workspace input =
  match syntactic_accesses ~workspace input with
  | [] -> []
  | pairs ->
      [
        Permission.Request.make ~source:name
          (List.map
             (fun (access, change) ->
               Permission.Request.Item.make ?change access)
             pairs);
      ]

let ensure_parent_dirs ~fs ~workspace targets =
  let rec loop created = function
    | [] -> Ok (List.rev created)
    | path :: paths -> (
        match Fs.ensure_parent_dirs ~fs ~workspace path with
        | Error error ->
            rollback_created_dirs created;
            Error (Fs error)
        | Ok dirs -> loop (List.rev_append dirs created) paths)
  in
  loop [] targets

let apply ~fs ~workspace ~max_bytes plan =
  let io, created_directories =
    Fs.Edit.io ~fs ~workspace ~max_bytes ~create_parent_dirs:true
      ~allow_remove:true ()
  in
  match Edit.apply ~io ~workspace plan with
  | Ok result -> Ok (result, created_directories ())
  | Error error -> Error error

let failed_apply_error (error : Edit.Apply_error.t) =
  failed_edit (Edit.Apply_error.error error)

let rollback_precreated_dirs_on_preapply_error precreated
    (error : Edit.Apply_error.t) =
  match (Edit.Apply_error.applied error, Edit.Apply_error.error error) with
  | ( [],
      ( Edit.Error.Conflict _ | Edit.Error.State_mismatch _
      | Edit.Error.Duplicate_path _ | Edit.Error.Invalid_text _
      | Edit.Error.Too_large _ | Edit.Error.Workspace _
      | Edit.Error.Out_of_workspace _ | Edit.Error.Protected_path _ ) ) ->
      rollback_created_dirs precreated
  | [], Edit.Error.Io _ | _ :: _, _ -> ()

let default_cancelled () = false

let run ~fs ~workspace ?(max_file_bytes = default_max_file_bytes)
    ?(cancelled = default_cancelled) input =
  if max_file_bytes < 0 then invalid_arg "max_file_bytes must be non-negative";
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match plan ~fs ~workspace ~max_bytes:max_file_bytes input with
    | Error error -> failed_plan error
    | Ok (planned : planned) -> (
        if cancelled () then
          Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true
            ()
        else
          match ensure_parent_dirs ~fs ~workspace planned.create_parents with
          | Error error -> failed_plan error
          | Ok precreated -> (
              if cancelled () then (
                rollback_created_dirs precreated;
                Tool.Result.interrupted ~reason:"tool call cancelled"
                  ~cancelled:true ())
              else
                match
                  apply ~fs ~workspace ~max_bytes:max_file_bytes planned.edit
                with
                | Error error ->
                    rollback_precreated_dirs_on_preapply_error precreated error;
                    failed_apply_error error
                | Ok (edit, io_created) ->
                    Tool.Result.completed
                      ~output:
                        (Output.make ~entries:planned.entries ~diff:planned.diff
                           ~edit ~created_directories:(precreated @ io_created))
                      ()))

let tool ~fs ~workspace ?max_file_bytes () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ?max_file_bytes
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
