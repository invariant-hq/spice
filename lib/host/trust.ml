(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

let log_src = Logs.Src.create "spice.host.trust" ~doc:"Workspace trust store"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Error = struct
  type t = string

  let message t = t
  let pp ppf t = Format.pp_print_string ppf t
end

let error message = Error message

module String_map = Map.Make (String)

type t = { path : string; store : int String_map.t }

let fs_path env path = Eio.Path.( / ) (Eio.Stdenv.fs env) path

(* Grant and revoke resolve through [realpath] so symlinked spellings (for
   example macOS [/tmp]) and [..] segments cannot split one workspace into two
   trust identities. *)
let canonical_path ~stdenv path =
  if String.is_empty path then error "workspace path must not be empty"
  else
    match Unix.realpath path with
    | exception Unix.Unix_error _ ->
        error ("workspace path is not a directory: " ^ path)
    | real ->
        if Eio.Path.is_directory (fs_path stdenv real) then Ok real
        else error ("workspace path is not a directory: " ^ path)

let decode_json_file stdenv path =
  match Eio.Path.load (fs_path stdenv path) with
  | exception exn -> error (path ^ ": " ^ Printexc.to_string exn)
  | text -> (
      match Jsont_bytesrw.decode_string Jsont.json text with
      | Ok json -> Ok json
      | Error message -> error (path ^ ": " ^ message))

let json_object_fields = function
  | Jsont.Object (fields, _) -> Some fields
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_mem name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let granted_at_of_json value =
  match json_mem "granted_at" value with
  | Some (Jsont.Number (granted_at, _)) when Float.is_integer granted_at ->
      int_of_float granted_at
  | Some _ | None -> 0

let store_of_json path json =
  match json_object_fields json with
  | None -> error (path ^ " must contain a JSON object")
  | Some _ -> (
      match json_mem "workspaces" json with
      | None -> Ok String_map.empty
      | Some (Jsont.Object (fields, _)) ->
          Ok
            (List.fold_left
               (fun store ((name, _), value) ->
                 String_map.add name (granted_at_of_json value) store)
               String_map.empty fields)
      | Some _ -> error (path ^ " workspaces must be an object"))

let load_store stdenv path =
  if not (Eio.Path.is_file (fs_path stdenv path)) then Ok String_map.empty
  else
    let* json = decode_json_file stdenv path in
    store_of_json path json

let load ~stdenv ?process_env () =
  let process_env = Option.value process_env ~default:(Env.current ()) in
  let getenv = Env.get process_env in
  let path = User_dirs.trust_store_path getenv in
  let* store = load_store stdenv path in
  Ok { path; store }

let make_mem name value = Jsont.Json.mem (Jsont.Json.name name) value
let json_object fields = Jsont.Json.object' fields

let encode_store store =
  let workspaces =
    store |> String_map.bindings
    |> List.map (fun (path, granted_at) ->
        make_mem path
          (json_object [ make_mem "granted_at" (Jsont.Json.int granted_at) ]))
    |> json_object
  in
  json_object
    [ make_mem "version" (Jsont.Json.int 1); make_mem "workspaces" workspaces ]

let mkdir_p stdenv dir =
  if String.is_empty dir || String.equal dir "." then Ok ()
  else
    match Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path stdenv dir) with
    | () -> Ok ()
    | exception exn -> error (Printexc.to_string exn)

let tmp_counter = ref 0

let tmp_path stdenv path =
  incr tmp_counter;
  let stamp =
    Eio.Time.now (Eio.Stdenv.clock stdenv)
    |> Int64.bits_of_float |> Int64.to_string
  in
  path ^ ".tmp."
  ^ string_of_int (Unix.getpid ())
  ^ "." ^ stamp ^ "." ^ string_of_int !tmp_counter

let write_store stdenv path store =
  let json = encode_store store in
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Error message -> error message
  | Ok encoded -> (
      let* () = mkdir_p stdenv (Filename.dirname path) in
      let tmp = tmp_path stdenv path in
      match
        Eio.Path.save ~create:(`Exclusive 0o600) (fs_path stdenv tmp)
          (encoded ^ "\n")
      with
      | exception exn -> error (Printexc.to_string exn)
      | () -> (
          match Eio.Path.rename (fs_path stdenv tmp) (fs_path stdenv path) with
          | () -> Ok ()
          | exception exn ->
              let () =
                try Eio.Path.unlink (fs_path stdenv tmp)
                with cleanup ->
                  Log.debug (fun m ->
                      m "trust store temp cleanup failed: %s"
                        (Printexc.to_string cleanup))
              in
              error (path ^ ": " ^ Printexc.to_string exn)))

let grant ~stdenv t ~workspace =
  let* workspace = canonical_path ~stdenv workspace in
  if String_map.mem workspace t.store then Ok workspace
  else
    let granted_at =
      Eio.Time.now (Eio.Stdenv.clock stdenv) |> Float.floor |> int_of_float
    in
    let* () =
      write_store stdenv t.path (String_map.add workspace granted_at t.store)
    in
    Log.debug (fun m -> m "workspace trust granted workspace=%s" workspace);
    Ok workspace

let revoke ~stdenv t ~workspace =
  let* workspace = canonical_path ~stdenv workspace in
  if not (String_map.mem workspace t.store) then Ok workspace
  else
    let* () = write_store stdenv t.path (String_map.remove workspace t.store) in
    Log.debug (fun m -> m "workspace trust revoked workspace=%s" workspace);
    Ok workspace
