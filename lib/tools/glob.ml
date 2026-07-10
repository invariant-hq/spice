(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let name = "glob"
let default_limit = 100
let max_limit = 1_000
let max_rg_stdout_bytes = 16 * 1024 * 1024
let description = Spice_prompts.Tools.glob

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
  type sort = Path | Modified

  type t = {
    pattern : string;
    path : string option;
    offset : int option;
    limit : int option;
    sort : sort;
  }

  let sort_to_string = function Path -> "path" | Modified -> "modified"

  let sort_of_string = function
    | "path" -> Path
    | "modified" -> Modified
    | sort -> invalid_arg ("unknown sort: " ^ sort)

  let validate_path = function
    | None -> ()
    | Some "" -> invalid_arg "path must not be empty"
    | Some path ->
        if String.contains path '\000' then
          invalid_arg "path must not contain NUL"

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

  let make ?path ?offset ?limit ?(sort = Path) pattern =
    if String.is_empty pattern then invalid_arg "pattern must not be empty";
    if String.contains pattern '\000' then
      invalid_arg "pattern must not contain NUL";
    validate_path path;
    validate_pagination offset limit;
    { pattern; path; offset; limit; sort }

  let make_json pattern path offset limit sort =
    decode_invalid_arg (fun () ->
        let path = match path with Some "" -> None | Some _ | None -> path in
        let sort = Option.map sort_of_string sort in
        make ?path ?offset ?limit ?sort pattern)

  let pattern t = t.pattern
  let path t = t.path
  let offset t = t.offset
  let limit t = t.limit
  let sort t = t.sort

  let to_json t =
    let fields =
      [ ("pattern", Json.string (pattern t)) ]
      |> optional_json_field "path"
           (Option.map (fun value -> Json.string value) (path t))
      |> optional_json_field "offset"
           (Option.map (fun value -> Json.int value) (offset t))
      |> optional_json_field "limit"
           (Option.map (fun value -> Json.int value) (limit t))
      |> optional_json_field "sort"
           (Some (Json.string (sort_to_string (sort t))))
    in
    json_obj (List.rev fields)

  let codec =
    Jsont.Object.map ~kind:"glob input" make_json
    |> Jsont.Object.mem "pattern" Jsont.string ~enc:pattern
    |> Jsont.Object.opt_mem "path" Jsont.string ~enc:path
    |> Jsont.Object.opt_mem "offset" Jsont.int ~enc:offset
    |> Jsont.Object.opt_mem "limit" Jsont.int ~enc:limit
    |> Jsont.Object.opt_mem "sort" Jsont.string ~enc:(fun t ->
        Some (sort_to_string (sort t)))
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
                        "Ripgrep glob pattern for workspace-relative file \
                         paths, for example \"**/*.ml\" or \"**/*.{ts,tsx}\"."
                    );
                  ] );
              ( "path",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "description",
                      Json.string
                        "Workspace-relative or workspace-contained absolute \
                         directory root. Defaults to the workspace root." );
                  ] );
              ( "offset",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string "1-based first file to return. Defaults to 1."
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
                        "Maximum number of files to return. Defaults to 100." );
                  ] );
              ( "sort",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list [ Json.string "path"; Json.string "modified" ]
                    );
                    ( "description",
                      Json.string
                        "Ordering policy. path is deterministic \
                         workspace-relative path order; modified is newest \
                         files first with path as tie-breaker." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "pattern" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

module Output = struct
  type partial_reason = Limit
  type status = Complete | Partial of partial_reason

  type t = {
    pattern : string;
    root : Workspace.Path.t;
    sort : Input.sort;
    files : Workspace.Path.t list;
    page : Input.t Pagination.Page.t;
  }

  let make ~pattern ~root ~sort ~files ~page =
    { pattern; root; sort; files; page }

  let pattern t = t.pattern
  let root t = t.root
  let sort t = t.sort
  let files t = t.files
  let offset t = Pagination.Page.offset t.page
  let limit t = Pagination.Page.limit t.page
  let returned_files t = List.length t.files

  (* Discovery always counts the full filtered set, so the page total is always
     [Exact]. *)
  let total_files t =
    match Pagination.Page.total t.page with
    | Pagination.Count.Exact n | Pagination.Count.Lower_bound n -> n
    | Pagination.Count.Unknown -> assert false

  let status t =
    if Pagination.Page.is_complete t.page then Complete else Partial Limit

  let next t = Pagination.Page.next t.page
  let has_more t = not (Pagination.Page.is_complete t.page)

  let status_to_string = function
    | Complete -> "complete"
    | Partial Limit -> "partial"

  let partial_reason_to_string = function Limit -> "limit"

  let json t =
    json_obj
      [
        ("pattern", Json.string (pattern t));
        ("root", Json.string (Workspace.Path.display (root t)));
        ("sort", Json.string (Input.sort_to_string (sort t)));
        ( "files",
          Json.list
            (List.map
               (fun path -> Json.string (Workspace.Path.display path))
               (files t)) );
        ("offset", Json.int (offset t));
        ("limit", Json.int (limit t));
        ("returned_files", Json.int (returned_files t));
        ("total_files", Json.int (total_files t));
        ("status", Json.string (status_to_string (status t)));
        ( "partial_reason",
          match status t with
          | Complete -> json_null
          | Partial reason -> Json.string (partial_reason_to_string reason) );
        ("has_more", Json.bool (has_more t));
        ( "next",
          match next t with
          | None -> json_null
          | Some input -> Input.to_json input );
      ]

  let text t =
    let b = Buffer.create 256 in
    Buffer.add_string b "pattern=";
    Buffer.add_string b (json_to_string (Json.string (pattern t)));
    Buffer.add_string b " root=";
    Buffer.add_string b (Workspace.Path.display (root t));
    Buffer.add_string b " files=";
    Buffer.add_string b (string_of_int (returned_files t));
    Buffer.add_char b '/';
    Buffer.add_string b (string_of_int (total_files t));
    Buffer.add_string b " offset=";
    Buffer.add_string b (string_of_int (offset t));
    Buffer.add_string b " limit=";
    Buffer.add_string b (string_of_int (limit t));
    Buffer.add_string b " sort=";
    Buffer.add_string b (Input.sort_to_string (sort t));
    Buffer.add_string b " status=";
    Buffer.add_string b (status_to_string (status t));
    Buffer.add_char b '\n';
    begin match files t with
    | [] -> Buffer.add_string b "No files\n"
    | files ->
        List.iter
          (fun path ->
            Buffer.add_string b (Workspace.Path.display path);
            Buffer.add_char b '\n')
          files
    end;
    begin match
      Pagination.Page.hint ~tool:name ~to_json:Input.to_json t.page
    with
    | None -> ()
    | Some line ->
        Buffer.add_string b line;
        Buffer.add_char b '\n'
    end;
    Buffer.contents b

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

type discovered = { path : Workspace.Path.t; mtime : float }

type glob_error =
  | Fs of Fs.Error.t
  | Rg_failed of { invalid_input : bool; message : string }
  | Sandbox_refused of Spice_sandbox.Error.t
  | Cancelled

let default_cancelled () = false
let effective_path input = Option.value (Input.path input) ~default:"."
let effective_offset input = Option.value (Input.offset input) ~default:1

let effective_limit input =
  Option.value (Input.limit input) ~default:default_limit

let vcs_metadata_dirs = [ ".git"; ".svn"; ".hg"; ".bzr"; ".jj"; ".sl" ]

let protected_vcs_globs =
  List.concat_map
    (fun name -> [ "!" ^ name ^ "/**"; "!**/" ^ name ^ "/**" ])
    vcs_metadata_dirs

let is_vcs_metadata component =
  List.exists (String.equal component) vcs_metadata_dirs

let has_vcs_metadata_component path =
  path |> Workspace.Path.rel |> Spice_path.Rel.components
  |> List.exists is_vcs_metadata

let root_arg root =
  if Workspace.Path.is_root root then []
  else [ Spice_path.Rel.to_string (Workspace.Path.rel root) ]

let rg_args ?pattern root =
  let args =
    [
      "rg";
      "--files";
      "--null";
      "--hidden";
      "--no-config";
      "--no-require-git";
      "--no-messages";
      "--color";
      "never";
    ]
  in
  let args =
    match pattern with
    | None -> args
    | Some pattern -> args @ [ "--glob"; pattern ]
  in
  let args =
    List.fold_left
      (fun args glob -> args @ [ "--glob"; glob ])
      args protected_vcs_globs
  in
  match root_arg root with [] -> args | path -> args @ [ "--" ] @ path

let split_nul text =
  let len = String.length text in
  let rec loop acc first index =
    if index = len then
      let acc =
        if first = len then acc else String.sub text first (len - first) :: acc
      in
      List.rev acc
    else if Char.equal text.[index] '\000' then
      let part = String.sub text first (index - first) in
      loop (part :: acc) (index + 1) (index + 1)
    else loop acc first (index + 1)
  in
  loop [] 0 0

let is_missing_executable message =
  String.includes ~affix:"No such file or directory" message
  || String.includes ~affix:"ENOENT" message
  || String.includes ~affix:"not found" message

let rg_error invalid_input stderr =
  let message = String.trim stderr in
  let message = if String.is_empty message then "ripgrep failed" else message in
  Rg_failed { invalid_input; message }

let normalize_rg_path ~workspace ~root line =
  match Workspace.resolve_string workspace line with
  | Error error -> Error (Fs (Fs.Error.Workspace error))
  | Ok path ->
      if Option.is_some (Workspace.Path.relativize ~root path) then
        Ok (Some path)
      else Ok None

let mtime (stat : Eio.File.Stat.t) = stat.Eio.File.Stat.mtime

let collect_file ~fs ~workspace ~root line =
  match normalize_rg_path ~workspace ~root line with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some path) -> (
      if has_vcs_metadata_component path then Ok None
      else
        match Fs.regular ~fs ~workspace ~follow_symlink:false path with
        | Error error -> Error (Fs error)
        | Ok stat -> Ok (Some { path; mtime = mtime stat }))

let collect_path_set ~workspace ~cancelled ~root stdout =
  let rec loop paths = function
    | [] -> Ok paths
    | line :: lines -> (
        if cancelled () then Error Cancelled
        else
          match normalize_rg_path ~workspace ~root line with
          | Error _ as error -> error
          | Ok None -> loop paths lines
          | Ok (Some path) ->
              let paths =
                if has_vcs_metadata_component path then paths
                else Workspace.Path.Set.add path paths
              in
              loop paths lines)
  in
  loop Workspace.Path.Set.empty (split_nul stdout)

let collect_files ~fs ~workspace ~cancelled ~root ~matching_paths stdout =
  let rec loop paths = function
    | [] -> Ok (Workspace.Path.Map.bindings paths |> List.map snd)
    | line :: lines -> (
        if cancelled () then Error Cancelled
        else
          match collect_file ~fs ~workspace ~root line with
          | Error _ as error -> error
          | Ok None -> loop paths lines
          | Ok (Some file) ->
              if Workspace.Path.Set.mem file.path matching_paths then
                loop (Workspace.Path.Map.add file.path file paths) lines
              else loop paths lines)
  in
  loop Workspace.Path.Map.empty (split_nul stdout)

let max_rg_timeout_ms = 60_000

let captured_text stream =
  match stream with
  | Process.Complete text -> Ok text
  | Process.Truncated _ ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message = "ripgrep stdout exceeded internal output limit";
           })

let captured_text_lossy = function
  | Process.Complete text -> text
  | Process.Truncated { head; tail; omitted_bytes } ->
      head ^ Printf.sprintf "\n... %d bytes omitted ...\n" omitted_bytes ^ tail

let run_rg_command ~sandbox ~cancelled root args =
  let cwd =
    Spice_path.Abs.to_string (Workspace.Root.dir (Workspace.Path.root root))
  in
  let result =
    Process.run_sandboxed_shell ~sandbox ~cwd ~env:(Unix.environment ())
      ~timeout_ms:max_rg_timeout_ms ~max_output_bytes:max_rg_stdout_bytes
      ~cancelled args
  in
  let stderr = captured_text_lossy result.Process.shell_stderr in
  match result.Process.shell_status with
  | Process.Shell_cancelled -> Error Cancelled
  | Process.Shell_refused error -> Error (Sandbox_refused error)
  | Process.Shell_failed_to_start message ->
      let message =
        if is_missing_executable message then
          "ripgrep executable not found; glob requires rg in PATH"
        else message
      in
      Error (Rg_failed { invalid_input = false; message })
  | Process.Shell_timed_out { timeout_ms } ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message =
               "ripgrep timed out after " ^ string_of_int timeout_ms ^ "ms";
           })
  | Process.Shell_signaled signal ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message = "ripgrep terminated by signal " ^ string_of_int signal;
           })
  | Process.Shell_exited (0 | 1) -> captured_text result.Process.shell_stdout
  | Process.Shell_exited 2 -> Error (rg_error true stderr)
  | Process.Shell_exited 127 when is_missing_executable stderr ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message = "ripgrep executable not found; glob requires rg in PATH";
           })
  | Process.Shell_exited code ->
      Error
        (Rg_failed
           {
             invalid_input = false;
             message =
               "ripgrep exited with status " ^ string_of_int code ^ ": "
               ^ String.trim stderr;
           })

let run_rg ~sandbox ~fs ~workspace ~cancelled input root =
  match
    run_rg_command ~sandbox ~cancelled root
      (rg_args ~pattern:(Input.pattern input) root)
  with
  | Error _ as error -> error
  | Ok matching_stdout -> (
      match collect_path_set ~workspace ~cancelled ~root matching_stdout with
      | Error _ as error -> error
      | Ok matching_paths -> (
          if Workspace.Path.Set.is_empty matching_paths then Ok []
          else
            match run_rg_command ~sandbox ~cancelled root (rg_args root) with
            | Error _ as error -> error
            | Ok stdout ->
                collect_files ~fs ~workspace ~cancelled ~root ~matching_paths
                  stdout))

let compare_path a b = Workspace.Path.compare a.path b.path

let compare_modified a b =
  match Float.compare b.mtime a.mtime with
  | 0 -> compare_path a b
  | order -> order

let sort_files sort files =
  let compare =
    match sort with
    | Input.Path -> compare_path
    | Input.Modified -> compare_modified
  in
  List.sort compare files

let output input root files =
  let offset = effective_offset input in
  let limit = effective_limit input in
  let files = sort_files (Input.sort input) files in
  let total_files = List.length files in
  let page = files |> List.drop (offset - 1) |> List.take limit in
  let returned = List.length page in
  let has_more = offset <= total_files && offset + returned <= total_files in
  let total = Pagination.Count.Exact total_files in
  let page_evidence =
    if has_more then
      let next =
        Input.make
          ~path:(Workspace.Path.display root)
          ~offset:(offset + returned) ~limit ~sort:(Input.sort input)
          (Input.pattern input)
      in
      Pagination.Page.partial ~returned ~total ~offset ~limit ~next:(Some next)
    else Pagination.Page.complete ~returned ~total ~offset ~limit
  in
  Output.make ~pattern:(Input.pattern input) ~root ~sort:(Input.sort input)
    ~files:(List.map (fun file -> file.path) page)
    ~page:page_evidence

let error_kind = function
  | Fs error -> Fs_error.failure error
  | Rg_failed { invalid_input; _ } ->
      if invalid_input then `Invalid_input else `Failed
  | Sandbox_refused _ -> `Unavailable
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
      Workspace.Path.display path ^ ": not a directory"
  | Fs (Fs.Error.Io (None, _)) -> "filesystem I/O error"
  | Fs (Fs.Error.Io (Some path, _)) ->
      Workspace.Path.display path ^ ": filesystem I/O error"
  | Rg_failed { message; _ } -> message
  | Sandbox_refused error -> Spice_sandbox.Error.message error
  | Cancelled -> "tool call cancelled"

let failed error = Tool.Result.failed (error_kind error) (error_message error)

let permissions ~workspace input =
  match Workspace.resolve_string workspace (effective_path input) with
  | Error _ -> []
  | Ok path ->
      [
        Permission.Request.of_accesses ~source:name
          [ Permission.Access.path ~op:`Read path ];
      ]

let run ~sandbox ~fs ~workspace ?(cancelled = default_cancelled) input =
  if cancelled () then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Fs.resolve ~workspace (effective_path input) with
    | Error error -> failed (Fs error)
    | Ok root -> (
        match Fs.directory ~fs ~workspace ~follow_symlink:false root with
        | Error error -> failed (Fs error)
        | Ok _ -> (
            match run_rg ~sandbox ~fs ~workspace ~cancelled input root with
            | Error Cancelled ->
                Tool.Result.interrupted ~reason:"tool call cancelled"
                  ~cancelled:true ()
            | Error error -> failed error
            | Ok files ->
                Tool.Result.completed ~output:(output input root files) ()))

let tool ~sandbox ~fs ~workspace () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~sandbox ~fs ~workspace
        ~cancelled:(fun () -> Tool.Context.cancelled ctx)
        input)
    ()
