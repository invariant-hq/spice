(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Workspace = Spice_workspace

let log_src =
  Logs.Src.create "spice.workspace_fs" ~doc:"Workspace filesystem access"

module Log = (val Logs.src_log log_src : Logs.LOG)

type expected = Regular_file | Directory

let expected_to_string = function
  | Regular_file -> "regular file"
  | Directory -> "directory"

let actual_to_string kind = Format.asprintf "%a" Eio.File.Stat.pp_kind kind

module Error = struct
  type t =
    | Workspace of Workspace.Resolve_error.t
    | Not_found of Workspace.Path.t
    | Escapes_workspace of Workspace.Path.t
    | Unexpected_kind of {
        path : Workspace.Path.t;
        expected : expected;
        actual : Eio.File.Stat.kind;
      }
    | Io of Workspace.Path.t option * string

  let message = function
    | Workspace error -> Workspace.Resolve_error.message error
    | Not_found path -> Workspace.Path.display path ^ ": path does not exist"
    | Escapes_workspace path ->
        Workspace.Path.display path ^ ": path resolves outside workspace"
    | Unexpected_kind { path; expected; actual } ->
        Printf.sprintf "%s: expected %s, found %s"
          (Workspace.Path.display path)
          (expected_to_string expected)
          (actual_to_string actual)
    | Io (None, _) -> "filesystem I/O error"
    | Io (Some path, _) ->
        Workspace.Path.display path ^ ": filesystem I/O error"
end

open Error

(* Top-level workspace metadata that tools must not modify. This is the
   write-side twin of the command sandbox's protected-meta carveouts
   (see [Spice_host.Sandbox]): the confined shell cannot write [.git] or
   [.spice] under a writable root, and the native edit tools must refuse the
   same, so neither path lets a run rewrite version-control or authority state.
   The two enforcement sites share this one list. *)
let protected_meta_names = [ ".git"; ".spice" ]

(* [Some name] when [path] is, or lies under, a [protected_meta_names] entry
   [name] at the top level of some workspace root. The check is lexical (it does
   not require the target to exist), matching the sandbox carveout computation
   and covering creation of a protected path that does not exist yet. *)
let protected_meta_component ~workspace path =
  let abs = Workspace.Path.abs path in
  List.find_map
    (fun root ->
      match
        Spice_path.Abs.relativize ~root:(Workspace.Root.dir root) abs
      with
      | None -> None
      | Some rel -> (
          match Spice_path.Rel.components rel with
          | first :: _ when List.mem first protected_meta_names -> Some first
          | _ -> None))
    (Workspace.roots workspace)

let resolve ~workspace input =
  match Workspace.resolve_string workspace input with
  | Ok path -> Ok path
  | Error error -> Error (Workspace error)

let abs_string path = Spice_path.Abs.to_string (Workspace.Path.abs path)
let eio_path ~fs workspace_path = Eio.Path.( / ) fs (abs_string workspace_path)

let is_under_real_root ~root path =
  String.equal path root
  || String.equal root Filename.dir_sep
  || String.starts_with ~prefix:(root ^ Filename.dir_sep) path

let realpath text =
  match Unix.realpath text with
  | path -> Ok path
  | exception exn -> Error (Printexc.to_string exn)

let contained ~workspace workspace_path =
  match realpath (abs_string workspace_path) with
  | Error message -> Error (Io (Some workspace_path, message))
  | Ok target ->
      let inside =
        List.exists
          (fun root ->
            match
              realpath (Spice_path.Abs.to_string (Workspace.Root.dir root))
            with
            | Error message ->
                Log.warn (fun m ->
                    m
                      "workspace root realpath failed, dropped from \
                       containment check root=%s error=%s"
                      (Spice_path.Abs.to_string (Workspace.Root.dir root))
                      message);
                false
            | Ok root -> is_under_real_root ~root target)
          (Workspace.roots workspace)
      in
      if inside then Ok () else Error (Escapes_workspace workspace_path)

let eio_error ?path = function
  | Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> (
      match path with
      | None -> Io (None, "not found")
      | Some path -> Error.Not_found path)
  | exn -> Io (path, Format.asprintf "%a" Eio.Exn.pp exn)

let is_not_directory_error exn =
  String.includes ~affix:"Not a directory" (Format.asprintf "%a" Eio.Exn.pp exn)

let stat ~fs ~workspace ?(follow_symlink = true) workspace_path =
  match Eio.Path.stat ~follow:follow_symlink (eio_path ~fs workspace_path) with
  | stat -> (
      if (not follow_symlink) && stat.Eio.File.Stat.kind = `Symbolic_link then
        Ok (Some stat)
      else
        match contained ~workspace workspace_path with
        | Ok () -> Ok (Some stat)
        | Error _ as error -> error)
  | exception Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok None
  | exception exn when is_not_directory_error exn ->
      Log.debug (fun m ->
          m
            "stat: path component is not a directory, treating as not-found \
             path=%s"
            (Workspace.Path.display workspace_path));
      Ok None
  | exception exn -> Error (eio_error ~path:workspace_path exn)

let kind_matches expected actual =
  match (expected, actual) with
  | Regular_file, `Regular_file | Directory, `Directory -> true
  | ( (Regular_file | Directory),
      ( `Unknown | `Fifo | `Character_special | `Directory | `Block_device
      | `Regular_file | `Symbolic_link | `Socket ) ) ->
      false

let expect_kind_opt ~fs ~workspace ~follow_symlink workspace_path expected =
  match stat ~fs ~workspace ~follow_symlink workspace_path with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some stat) ->
      if kind_matches expected stat.Eio.File.Stat.kind then Ok (Some stat)
      else
        Error
          (Unexpected_kind
             {
               path = workspace_path;
               expected;
               actual = stat.Eio.File.Stat.kind;
             })

let expect_kind ~fs ~workspace ~follow_symlink workspace_path expected =
  match
    expect_kind_opt ~fs ~workspace ~follow_symlink workspace_path expected
  with
  | Error _ as error -> error
  | Ok None -> Error (Error.Not_found workspace_path)
  | Ok (Some stat) -> Ok stat

let regular_opt ~fs ~workspace ?(follow_symlink = false) workspace_path =
  expect_kind_opt ~fs ~workspace ~follow_symlink workspace_path Regular_file

let regular ~fs ~workspace ?(follow_symlink = false) workspace_path =
  expect_kind ~fs ~workspace ~follow_symlink workspace_path Regular_file

let directory ~fs ~workspace ?(follow_symlink = false) workspace_path =
  expect_kind ~fs ~workspace ~follow_symlink workspace_path Directory

let child parent name =
  match Workspace.Path.add_component parent name with
  | Ok path -> Ok path
  | Error error ->
      Error (Workspace (Workspace.Resolve_error.Invalid_input error))

let read_dir_names ~fs ~workspace ?(follow_symlink = false) workspace_path =
  match directory ~fs ~workspace ~follow_symlink workspace_path with
  | Error _ as error -> error
  | Ok _ -> (
      match Eio.Path.read_dir (eio_path ~fs workspace_path) with
      | names -> Ok names
      | exception exn -> Error (eio_error ~path:workspace_path exn))

let load_regular ~fs ~workspace ?(follow_symlink = false) workspace_path =
  match regular ~fs ~workspace ~follow_symlink workspace_path with
  | Error _ as error -> error
  | Ok _ -> (
      match Eio.Path.load (eio_path ~fs workspace_path) with
      | contents -> Ok contents
      | exception exn -> Error (eio_error ~path:workspace_path exn))

let with_regular_in ~fs ~workspace ?(follow_symlink = false) workspace_path f =
  match regular ~fs ~workspace ~follow_symlink workspace_path with
  | Error _ as error -> error
  | Ok _ -> (
      Eio.Switch.run ~name:"workspace_fs.with_regular_in" @@ fun sw ->
      let path = eio_path ~fs workspace_path in
      match Eio.Path.open_in ~sw path with
      | exception exn -> Error (eio_error ~path:workspace_path exn)
      | file -> Ok (f file))

let rec missing_parent_dirs ~fs ~workspace acc dir =
  match directory ~fs ~workspace dir with
  | Ok _ -> Ok acc
  | Error (Error.Not_found _) -> (
      match Workspace.Path.parent dir with
      | None -> Error (Error.Not_found dir)
      | Some parent -> missing_parent_dirs ~fs ~workspace (dir :: acc) parent)
  | Error _ as error -> error

let ensure_parent_dirs ~fs ~workspace workspace_path =
  match Workspace.Path.parent workspace_path with
  | None -> Ok []
  | Some parent -> (
      match missing_parent_dirs ~fs ~workspace [] parent with
      | Error _ as error -> error
      | Ok dirs ->
          let rec loop created = function
            | [] -> Ok (List.rev created)
            | dir :: dirs -> (
                match Eio.Path.mkdir ~perm:0o777 (eio_path ~fs dir) with
                | () -> (
                    match contained ~workspace dir with
                    | Ok () -> loop (dir :: created) dirs
                    | Error _ as error -> error)
                | exception Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _)
                  -> (
                    match directory ~fs ~workspace dir with
                    | Ok _ -> loop created dirs
                    | Error _ as error -> error)
                | exception exn -> Error (eio_error ~path:dir exn))
          in
          loop [] dirs)

module Edit = struct
  module Edit = Spice_edit

  let binary_sample_bytes = 16_384
  let write_lock = Eio.Mutex.create ()
  let temp_counter = Atomic.make 0

  type error =
    | Fs of Error.t
    | Too_large of Workspace.Path.t * int64 * int64
    | Binary_file of Workspace.Path.t
    | Invalid_utf8 of Workspace.Path.t

  let classify_eio ?path exn = Fs (eio_error ?path exn)

  let is_text_control = function
    | '\t' | '\n' | '\r' | '\x0c' -> true
    | _ -> false

  let is_control_byte c = Char.Ascii.is_control c && not (is_text_control c)

  let looks_binary text =
    if String.contains text '\x00' then true
    else
      let controls = ref 0 in
      String.iter (fun c -> if is_control_byte c then incr controls) text;
      !controls * 10 > String.length text

  let check_size ~max_bytes workspace_path (stat : Eio.File.Stat.t) =
    let size = Optint.Int63.to_int64 stat.Eio.File.Stat.size in
    if Int64.compare size (Int64.of_int max_bytes) > 0 then
      Error (Too_large (workspace_path, size, Int64.of_int max_bytes))
    else Ok ()

  let check_contents_size ~max_bytes workspace_path contents =
    let size = String.length contents in
    if size > max_bytes then
      Error
        (Too_large (workspace_path, Int64.of_int size, Int64.of_int max_bytes))
    else Ok ()

  let read_at file ~file_offset ~len =
    if len = 0 then ""
    else
      let buf = Cstruct.create len in
      let read =
        Eio.File.pread file
          ~file_offset:(Optint.Int63.of_int file_offset)
          [ buf ]
      in
      if read = 0 then "" else Cstruct.to_string (Cstruct.sub buf 0 read)

  let binary_sample_length (stat : Eio.File.Stat.t) =
    let size = Optint.Int63.to_int64 stat.Eio.File.Stat.size in
    if Int64.compare size (Int64.of_int binary_sample_bytes) < 0 then
      Int64.to_int size
    else binary_sample_bytes

  let check_binary_sample ~fs workspace_path stat =
    let len = binary_sample_length stat in
    match
      Eio.Path.with_open_in
        (eio_path ~fs workspace_path)
        (read_at ~file_offset:0 ~len)
    with
    | exception exn -> Error (classify_eio ~path:workspace_path exn)
    | sample ->
        if looks_binary sample then Error (Binary_file workspace_path)
        else Ok ()

  let read_existing_text ~fs ~max_bytes workspace_path stat =
    match check_size ~max_bytes workspace_path stat with
    | Error _ as error -> error
    | Ok () -> (
        match check_binary_sample ~fs workspace_path stat with
        | Error _ as error -> error
        | Ok () -> (
            match Eio.Path.load (eio_path ~fs workspace_path) with
            | exception exn -> Error (classify_eio ~path:workspace_path exn)
            | contents -> (
                match
                  check_contents_size ~max_bytes workspace_path contents
                with
                | Error _ as error -> error
                | Ok () when not (String.is_valid_utf_8 contents) ->
                    Error (Invalid_utf8 workspace_path)
                | Ok () when looks_binary contents ->
                    Error (Binary_file workspace_path)
                | Ok () -> Ok contents)))

  let to_edit_error = function
    | Fs (Error.Workspace error) -> Edit.Error.workspace error
    | Fs (Error.Not_found path) ->
        Edit.Error.state_mismatch ~path ~expected:`Text ~actual:`Missing
    | Fs (Error.Unexpected_kind { path; actual = `Symbolic_link; _ }) ->
        Edit.Error.invalid_text ~path "symlink targets are not supported"
    | Fs (Error.Unexpected_kind { path; expected = Directory; _ }) ->
        Edit.Error.invalid_text ~path "not a directory"
    | Fs (Error.Unexpected_kind { path; _ }) ->
        Edit.Error.invalid_text ~path "not a regular file"
    | Fs (Error.Escapes_workspace path) ->
        Edit.Error.workspace ~path
          (Workspace.Resolve_error.Outside_workspace (Workspace.Path.abs path))
    | Fs (Error.Io (path, message)) -> Edit.Error.io ?path message
    | Too_large (path, size, max_size) ->
        Edit.Error.too_large ~path ~size ~max_size
    | Binary_file path -> Edit.Error.invalid_text ~path "binary file"
    | Invalid_utf8 path -> Edit.Error.invalid_text ~path "not valid UTF-8 text"

  let read_text ~fs ~workspace ~max_bytes ?(follow_symlink = false)
      workspace_path =
    (match regular ~fs ~workspace ~follow_symlink workspace_path with
      | Error error -> Error (Fs error)
      | Ok stat -> read_existing_text ~fs ~max_bytes workspace_path stat)
    |> Result.map_error to_edit_error

  let target ~fs ~workspace ~max_bytes ?(follow_symlink = false) workspace_path
      =
    match regular_opt ~fs ~workspace ~follow_symlink workspace_path with
    | Error (Unexpected_kind _) -> Ok Edit.Observed.Other
    | Error error -> Error (to_edit_error (Fs error))
    | Ok None -> Ok Edit.Observed.Missing
    | Ok (Some stat) -> (
        match read_existing_text ~fs ~max_bytes workspace_path stat with
        | Error (Binary_file _ | Invalid_utf8 _) -> Ok Edit.Observed.Other
        | Error error -> Error (to_edit_error error)
        | Ok contents -> Ok (Edit.Observed.Text contents))

  let remove_if_present fs path =
    match Eio.Path.unlink (Eio.Path.( / ) fs path) with
    | () -> ()
    | exception (Eio.Exn.Io _ as exn) ->
        Log.debug (fun m ->
            m "failed to remove temp file after rename error path=%s error=%s"
              path (Printexc.to_string exn))

  let remove_dir_if_empty path =
    try Unix.rmdir (abs_string path) with Unix.Unix_error _ -> ()

  let rollback_created_dirs dirs = List.iter remove_dir_if_empty (List.rev dirs)

  let file_perm workspace_path =
    match Unix.stat (abs_string workspace_path) with
    | stat -> stat.Unix.st_perm land 0o7777
    | exception Unix.Unix_error (error, fn, arg) ->
        raise (Unix.Unix_error (error, fn, arg))

  let temp_path workspace_path =
    let counter = Atomic.fetch_and_add temp_counter 1 in
    abs_string workspace_path ^ ".spice-" ^ string_of_int counter ^ ".tmp"

  let save_create fs workspace_path contents =
    match
      Eio.Path.save ~create:(`Exclusive 0o666)
        (eio_path ~fs workspace_path)
        contents
    with
    | () -> Ok ()
    | exception Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
        Error
          (Edit.Error.state_mismatch ~path:workspace_path ~expected:`Missing
             ~actual:`Other)
    | exception exn ->
        Error
          (Edit.Error.io ~path:workspace_path
             (Format.asprintf "%a" Eio.Exn.pp exn))

  let save_replace fs workspace_path contents =
    let perm =
      match file_perm workspace_path with
      | perm -> Ok perm
      | exception Unix.Unix_error (error, fn, arg) ->
          Error
            (Edit.Error.io ~path:workspace_path
               (Unix.error_message error ^ " in " ^ fn ^ "(" ^ arg ^ ")"))
    in
    match perm with
    | Error _ as error -> error
    | Ok perm ->
        let rec loop attempts =
          if attempts = 0 then
            Error
              (Edit.Error.io ~path:workspace_path
                 "could not allocate a temporary path for atomic write")
          else
            let tmp = temp_path workspace_path in
            match
              Eio.Path.save ~create:(`Exclusive perm) (Eio.Path.( / ) fs tmp)
                contents
            with
            | exception Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) ->
                Log.debug (fun m ->
                    m
                      "atomic write temp path collision, retrying path=%s \
                       attempts_left=%d"
                      (Workspace.Path.display workspace_path)
                      (attempts - 1));
                loop (attempts - 1)
            | exception exn ->
                Error
                  (Edit.Error.io ~path:workspace_path
                     (Format.asprintf "%a" Eio.Exn.pp exn))
            | () -> (
                begin match Unix.chmod tmp perm with
                | () -> ()
                | exception Unix.Unix_error _ -> ()
                end;
                match
                  Eio.Path.rename (Eio.Path.( / ) fs tmp)
                    (eio_path ~fs workspace_path)
                with
                | () -> Ok ()
                | exception exn ->
                    remove_if_present fs tmp;
                    Error
                      (Edit.Error.io ~path:workspace_path
                         (Format.asprintf "%a" Eio.Exn.pp exn)))
        in
        loop 32

  let create_text ~fs ~workspace ~max_bytes ~create_parent_dirs ~created
      workspace_path contents =
    if String.length contents > max_bytes then
      Error
        (Edit.Error.too_large ~path:workspace_path
           ~size:(Int64.of_int (String.length contents))
           ~max_size:(Int64.of_int max_bytes))
    else if create_parent_dirs then
      match ensure_parent_dirs ~fs ~workspace workspace_path with
      | Error error -> Error (to_edit_error (Fs error))
      | Ok dirs ->
          begin match save_create fs workspace_path contents with
          | Ok () ->
              created := List.rev_append dirs !created;
              Ok ()
          | Error _ as error ->
              rollback_created_dirs dirs;
              error
          end
    else save_create fs workspace_path contents

  let read_target ~fs ~workspace ~max_bytes workspace_path =
    target ~fs ~workspace ~max_bytes workspace_path

  let remove_file fs workspace_path =
    match Eio.Path.unlink (eio_path ~fs workspace_path) with
    | () -> Ok ()
    | exception Eio.Exn.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) ->
        Error
          (Edit.Error.state_mismatch ~path:workspace_path ~expected:`Text
             ~actual:`Missing)
    | exception exn ->
        Error
          (Edit.Error.io ~path:workspace_path
             (Format.asprintf "%a" Eio.Exn.pp exn))

  let io ~fs ~workspace ~max_bytes ?(create_parent_dirs = false)
      ?(allow_remove = false) ?(remove_error = "delete is not supported") () =
    let created = ref [] in
    (* One process-global write lock. A single-process agent has no benefit from
       per-path locking, so [paths] is intentionally ignored. *)
    let with_write_lock _paths f =
      Eio.Mutex.use_rw ~protect:true write_lock f
    in
    (* Containment revalidation is delegated to [read]: [commit] runs under the
       same write lock and [read] re-checks containment (target -> regular_opt ->
       stat -> contained), so a separate containment check here would only
       duplicate it. The protected-meta guard is the exception: it is the single
       write-side chokepoint refusing edits to [.git]/[.spice] before any
       transition commits, for every tool built on this IO. *)
    let revalidate workspace_path =
      match protected_meta_component ~workspace workspace_path with
      | Some name ->
          Error (Edit.Error.protected_path ~path:workspace_path ~name)
      | None -> Ok workspace_path
    in
    let remove workspace_path =
      if allow_remove then remove_file fs workspace_path
      else Error (Edit.Error.io ~path:workspace_path remove_error)
    in
    let commit ~path ~before ~after =
      match (before, after) with
      | Edit.State.Missing, Edit.State.Text contents ->
          create_text ~fs ~workspace ~max_bytes ~create_parent_dirs ~created
            path contents
      | Edit.State.Text _, Edit.State.Text contents ->
          if String.length contents > max_bytes then
            Error
              (Edit.Error.too_large ~path
                 ~size:(Int64.of_int (String.length contents))
                 ~max_size:(Int64.of_int max_bytes))
          else save_replace fs path contents
      | Edit.State.Text _, Edit.State.Missing -> remove path
      | Edit.State.Missing, Edit.State.Missing ->
          Error (Edit.Error.io ~path "empty edit transition")
    in
    ( {
        Edit.Apply.with_write_lock;
        revalidate;
        read = read_target ~fs ~workspace ~max_bytes;
        commit;
      },
      fun () -> List.rev !created )
end
