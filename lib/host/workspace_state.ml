(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

type manifest = { version : int; root : string }

let manifest_jsont =
  Jsont.Object.map ~kind:"workspace state manifest" (fun version root ->
      { version; root })
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun t -> t.version)
  |> Jsont.Object.mem "root" Jsont.string ~enc:(fun t -> t.root)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let key root =
  Spice_digest.key ~length:24 ~domain:"spice.workspace-state.v1" [ root ]

let dir ~data_root ~root =
  Filename.concat (Filename.concat data_root "workspaces") (key root)

let manifest_path workspace_dir = Filename.concat workspace_dir "workspace.json"
let checkpoint_dir workspace_dir = Filename.concat workspace_dir "checkpoints.git"
let reviews_dir workspace_dir = Filename.concat workspace_dir "reviews"
let fs_path fs path = Eio.Path.( / ) fs path

let decode_manifest path text =
  Jsont_bytesrw.decode_string manifest_jsont text
  |> Result.map_error (fun message -> path ^ ": " ^ message)

let validate_manifest ~path ~root manifest =
  if manifest.version <> 1 then Error (path ^ ": unsupported workspace version")
  else if not (String.equal manifest.root root) then
    Error (path ^ ": workspace root does not match directory key")
  else Ok ()

let load_manifest ~fs ~path ~root =
  match Eio.Path.load (fs_path fs path) with
  | text ->
      let* manifest = decode_manifest path text in
      validate_manifest ~path ~root manifest
  | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn)

let ensure ~fs ~data_root ~root =
  let workspace_dir = dir ~data_root ~root in
  let path = manifest_path workspace_dir in
  match Eio.Path.kind ~follow:false (fs_path fs path) with
  | `Regular_file ->
      let* () = load_manifest ~fs ~path ~root in
      Ok workspace_dir
  | `Not_found -> (
      match
        Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path fs workspace_dir)
      with
      | exception exn -> Error (workspace_dir ^ ": " ^ Printexc.to_string exn)
      | () -> (
          let manifest = { version = 1; root } in
          match Jsont_bytesrw.encode_string manifest_jsont manifest with
          | Error message -> Error (path ^ ": " ^ message)
          | Ok text -> (
              match
                Eio.Path.save ~create:(`Exclusive 0o600) (fs_path fs path)
                  (text ^ "\n")
              with
              | () -> Ok workspace_dir
              | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
                  let* () = load_manifest ~fs ~path ~root in
                  Ok workspace_dir
              | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn))))
  | _ -> Error (path ^ ": is not a regular file")
  | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn)
