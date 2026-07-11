(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

let log_src = Logs.Src.create "spice.host.trust" ~doc:"Workspace trust store"

module Log = (val Logs.src_log log_src : Logs.LOG)

type status = Unknown | Untrusted | Trusted

module Error = struct
  type operation = Read | Decode | Lock | Write

  type t =
    | Invalid_root of { root : string; message : string }
    | User_directory of User_dirs.Error.t
    | Store of { operation : operation; path : string; message : string }

  let operation = function
    | Read -> "could not read"
    | Decode -> "could not decode"
    | Lock -> "could not lock"
    | Write -> "could not write"

  let message = function
    | Invalid_root { root; message } -> root ^ ": " ^ message
    | User_directory error -> User_dirs.Error.message error
    | Store { operation = op; path; message } ->
        Printf.sprintf "%s workspace trust store %s: %s" (operation op) path
          message

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module String_map = Map.Make (String)

type t = { root : Spice_path.Abs.t; status : status }

let root t = t.root
let status t = t.status
let is_trusted t = match t.status with Trusted -> true | Unknown | Untrusted -> false

let status_to_string = function
  | Unknown -> "unknown"
  | Untrusted -> "untrusted"
  | Trusted -> "trusted"

let fs_path stdenv path = Eio.Path.( / ) (Eio.Stdenv.fs stdenv) path

let invalid_root root message =
  Error
    (Error.Invalid_root
       { root = Spice_path.Abs.to_string root; message })

let canonical_root ~stdenv root =
  let raw = Spice_path.Abs.to_string root in
  match Unix.realpath raw with
  | exception Unix.Unix_error (error, _, _) ->
      invalid_root root (Unix.error_message error)
  | canonical -> (
      match Eio.Path.kind ~follow:true (fs_path stdenv canonical) with
      | `Directory -> (
          match Spice_path.Abs.of_string canonical with
          | Ok canonical -> Ok canonical
          | Error error -> invalid_root root (Spice_path.Error.message error))
      | `Not_found -> invalid_root root "workspace root does not exist"
      | `Regular_file | `Symbolic_link | `Socket | `Fifo | `Character_special
      | `Block_device | `Unknown ->
          invalid_root root "workspace root is not a directory"
      | exception exn -> invalid_root root (Printexc.to_string exn))

let store_error operation path message =
  Error (Error.Store { operation; path; message })

let io_error operation path = function
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> store_error operation path (Printexc.to_string exn)

let store_path process_env =
  User_dirs.trust_store_path (Env.get process_env)
  |> Result.map_error (fun error -> Error.User_directory error)

let json_mem name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let version_of_json path json =
  match json_mem "version" json with
  | Some (Jsont.Number (version, _))
    when Float.is_integer version && Int.equal (int_of_float version) 2 ->
      Ok ()
  | Some (Jsont.Number (version, _)) when Float.is_integer version ->
      store_error Error.Decode path
        (Printf.sprintf "unsupported version %d; expected version 2"
           (int_of_float version))
  | Some _ | None ->
      store_error Error.Decode path "version must be the integer 2"

let status_of_json path workspace = function
  | Jsont.String ("trusted", _) -> Ok Trusted
  | Jsont.String ("untrusted", _) -> Ok Untrusted
  | Jsont.String (status, _) ->
      store_error Error.Decode path
        (Printf.sprintf "workspace %S has unknown status %S" workspace status)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
  | Jsont.Array _ ->
      store_error Error.Decode path
        (Printf.sprintf "workspace %S status must be a string" workspace)

let store_of_json path json =
  match json with
  | Jsont.Object _ ->
      let* () = version_of_json path json in
      begin match json_mem "workspaces" json with
      | Some (Jsont.Object (fields, _)) ->
          let rec decode store = function
            | [] -> Ok store
            | ((workspace, _), value) :: fields ->
                let* status = status_of_json path workspace value in
                decode (String_map.add workspace status store) fields
          in
          decode String_map.empty fields
      | Some _ | None ->
          store_error Error.Decode path "workspaces must be an object"
      end
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      store_error Error.Decode path "top-level value must be an object"

let load_store stdenv path =
  match Eio.Path.kind ~follow:true (fs_path stdenv path) with
  | `Not_found -> Ok String_map.empty
  | `Regular_file -> (
      match Eio.Path.load (fs_path stdenv path) with
      | exception exn -> io_error Error.Read path exn
      | text -> (
          match Jsont_bytesrw.decode_string Jsont.json text with
          | Error message -> store_error Error.Decode path message
          | Ok json -> store_of_json path json))
  | `Directory | `Symbolic_link | `Socket | `Fifo | `Character_special
  | `Block_device | `Unknown ->
      store_error Error.Read path "path is not a regular file"
  | exception exn -> io_error Error.Read path exn

let resolution root store =
  let key = Spice_path.Abs.to_string root in
  let status = Option.value (String_map.find_opt key store) ~default:Unknown in
  { root; status }

let find ~stdenv ?process_env ~root () =
  let process_env = Option.value process_env ~default:(Env.current ()) in
  let* root = canonical_root ~stdenv root in
  let* path = store_path process_env in
  let* store = load_store stdenv path in
  Ok (resolution root store)

let make_mem name value = Jsont.Json.mem (Jsont.Json.name name) value

let encode_store store =
  let workspaces =
    store |> String_map.bindings
    |> List.map (fun (root, status) ->
        make_mem root (Jsont.Json.string (status_to_string status)))
    |> Jsont.Json.object'
  in
  Jsont.Json.object'
    [ make_mem "version" (Jsont.Json.int 2); make_mem "workspaces" workspaces ]

let mkdir_p stdenv dir =
  if String.is_empty dir || String.equal dir "." then Ok ()
  else
    match Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path stdenv dir) with
    | () -> Ok ()
    | exception exn -> io_error Error.Write dir exn

let write_mutexes : (string, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 8
let write_mutexes_guard = Mutex.create ()

(* POSIX record locks are process-scoped, so two fibers can both appear to hold
   the same file lock. Every spelling of one store therefore shares this
   process-local mutex; the table guard also keeps lookup safe across domains. *)
let write_mutex_for key =
  Mutex.protect write_mutexes_guard (fun () ->
      match Hashtbl.find_opt write_mutexes key with
      | Some mutex -> mutex
      | None ->
          let mutex = Eio.Mutex.create () in
          Hashtbl.replace write_mutexes key mutex;
          mutex)

let with_file_lock stdenv path f =
  let rec lockf fd command =
    match Unix.lockf fd command 0 with
    | () -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> lockf fd command
  in
  let fd =
    Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let rec acquire backoff =
        match Unix.lockf fd Unix.F_TLOCK 0 with
        | () -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> acquire backoff
        | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
            (* The non-blocking lock plus an Eio sleep keeps cancellation
               responsive while another process owns the store. *)
            Eio.Time.sleep (Eio.Stdenv.clock stdenv) backoff;
            acquire (Float.min (backoff *. 2.) 0.1)
      in
      acquire 0.001;
      Fun.protect ~finally:(fun () -> lockf fd Unix.F_ULOCK) f)

let with_store_lock stdenv path f =
  let* () = mkdir_p stdenv (Filename.dirname path) in
  let lock_path = path ^ ".lock" in
  let key =
    try Unix.realpath (Filename.dirname path) ^ "/" ^ Filename.basename path
    with Unix.Unix_error _ -> path
  in
  let mutex = write_mutex_for key in
  match
    Eio.Mutex.use_ro mutex (fun () -> with_file_lock stdenv lock_path f)
  with
  | result -> result
  | exception exn -> io_error Error.Lock lock_path exn

let tmp_counter = Atomic.make 0

let tmp_path stdenv path =
  let counter = Atomic.fetch_and_add tmp_counter 1 in
  let stamp =
    Eio.Time.now (Eio.Stdenv.clock stdenv)
    |> Int64.bits_of_float |> Int64.to_string
  in
  Printf.sprintf "%s.tmp.%d.%s.%d" path (Unix.getpid ()) stamp counter

let cleanup_tmp stdenv tmp =
  match Eio.Path.unlink (fs_path stdenv tmp) with
  | () -> ()
  | exception exn ->
      Log.debug (fun m ->
          m "trust store temp cleanup failed path=%s exn=%s" tmp
            (Printexc.to_string exn))

let write_store stdenv path store =
  match Jsont_bytesrw.encode_string Jsont.json (encode_store store) with
  | Error message -> store_error Error.Write path message
  | Ok encoded ->
      let tmp = tmp_path stdenv path in
      begin match
        Eio.Path.save ~create:(`Exclusive 0o600) (fs_path stdenv tmp)
          (encoded ^ "\n")
      with
      | exception exn ->
          cleanup_tmp stdenv tmp;
          io_error Error.Write tmp exn
      | () -> (
          match Eio.Path.rename (fs_path stdenv tmp) (fs_path stdenv path) with
          | () -> Ok ()
          | exception exn ->
              cleanup_tmp stdenv tmp;
              io_error Error.Write path exn)
      end

let set ~stdenv ?process_env ~root status =
  let process_env = Option.value process_env ~default:(Env.current ()) in
  let* root = canonical_root ~stdenv root in
  let* path = store_path process_env in
  with_store_lock stdenv path (fun () ->
      let* store = load_store stdenv path in
      let key = Spice_path.Abs.to_string root in
      let updated = String_map.add key status store in
      let* () =
        if String_map.equal ( = ) store updated then Ok ()
        else write_store stdenv path updated
      in
      Log.debug (fun m ->
          m "workspace trust updated root=%s status=%s" key
            (status_to_string status));
      Ok { root; status })

let trust ~stdenv ?process_env ~root () =
  set ~stdenv ?process_env ~root Trusted

let untrust ~stdenv ?process_env ~root () =
  set ~stdenv ?process_env ~root Untrusted
