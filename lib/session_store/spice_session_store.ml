(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

let log_src =
  Logs.Src.create "spice.session_store" ~doc:"Persistent session storage"

module Log = (val Logs.src_log log_src : Logs.LOG)

let log_clip text =
  if String.length text <= 200 then text else String.sub text 0 200

type t = {
  fs : Eio.Fs.dir_ty Eio.Path.t;
  now : unit -> float;
  sleep : float -> unit;
  root : Spice_path.Abs.t;
  sessions_dir : string;
  canonical_sessions_dir : string option Atomic.t;
}

let make ~fs ~clock ~root =
  Log.debug (fun m -> m "store opened root=%s" (Spice_path.Abs.to_string root));
  {
    fs;
    now = (fun () -> Eio.Time.now clock);
    sleep = (fun seconds -> Eio.Time.sleep clock seconds);
    root;
    sessions_dir = Filename.concat (Spice_path.Abs.to_string root) "sessions";
    canonical_sessions_dir = Atomic.make None;
  }

let root t = t.root

(* A revision is the canonical content identity of the exact encoded document
   bytes. The store is the source of truth for real documents: it mints the
   token here from the SHA-256 identity, and revision equality reduces to the
   canonical-string equality of that identity. *)
let revision_of_bytes text =
  Spice_session.Revision.of_string
    (Spice_digest.Identity.to_string (Spice_digest.Identity.of_contents text))

module Document = struct
  type t = { session : Spice_session.t; revision : Spice_session.Revision.t }

  let make ~session ~revision = { session; revision }
  let id t = Spice_session.id t.session
  let session t = t.session
  let revision t = t.revision
end

module Corrupt = struct
  type t = { id : Spice_session.Id.t option; path : string; message : string }

  let make ?id ~path ~message () = { id; path; message }
  let id t = t.id
  let path t = t.path
  let message t = t.message
end

module Error = struct
  type t =
    | Not_found of Spice_session.Id.t
    | Already_exists of Spice_session.Id.t
    | Conflict of {
        id : Spice_session.Id.t;
        expected : Spice_session.Revision.t;
        actual : Spice_session.Revision.t;
      }
    | Corrupt of { path : string; message : string }
    | Session of { id : Spice_session.Id.t; error : Spice_session.Error.t }
    | Io of { path : string; message : string }

  let message (error : t) =
    match error with
    | Not_found id ->
        Format.asprintf "session not found: %a" Spice_session.Id.pp id
    | Already_exists id ->
        Format.asprintf "session already exists: %a" Spice_session.Id.pp id
    | Conflict { id; expected; actual } ->
        Format.asprintf
          "session conflict for %a: expected revision %a but found %a"
          Spice_session.Id.pp id Spice_session.Revision.pp expected
          Spice_session.Revision.pp actual
    | Corrupt { path; message } -> path ^ ": " ^ message
    | Session { error; _ } -> Spice_session.Error.message error
    | Io { path; message } -> path ^ ": " ^ message

  let pp ppf t = Format.pp_print_string ppf (message t)

  let diagnostic ?id = function
    | Corrupt { path; message } ->
        let subject =
          match id with
          | None -> "session document is invalid"
          | Some id ->
              Format.asprintf "session %a is invalid" Spice_session.Id.pp id
        in
        Spice_diagnostic.make ~context:(path ^ "\n" ^ message) subject
    | error -> Spice_diagnostic.make (message error)
end

let io_exception path = function
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Error.Io { path; message = Printexc.to_string exn })

let io path f =
  match f () with value -> Ok value | exception exn -> io_exception path exn

let fs_path t path = Eio.Path.( / ) t.fs path
let native_path t path = Eio.Path.native_exn (fs_path t path)
let sessions_dir t = t.sessions_dir
let document_filename = "session.json"
let hex = "0123456789ABCDEF"

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let escaped_component text =
  let buffer = Buffer.create (String.length text) in
  String.iter
    (fun c ->
      if is_unreserved c then Buffer.add_char buffer c
      else
        let code = Char.code c in
        Buffer.add_char buffer '%';
        Buffer.add_char buffer hex.[code lsr 4];
        Buffer.add_char buffer hex.[code land 0x0f])
    text;
  Buffer.contents buffer

let session_dir store id =
  Filename.concat (sessions_dir store)
    (escaped_component (Spice_session.Id.to_string id))

let session_path store id =
  Filename.concat (session_dir store id) document_filename

let lock_path store id =
  Filename.concat (sessions_dir store)
    (escaped_component (Spice_session.Id.to_string id) ^ ".lock")

let dir_exists store path = Eio.Path.is_directory (fs_path store path)

let path_kind store path =
  match Eio.Path.kind ~follow:true (fs_path store path) with
  | `Not_found -> Ok `Missing
  | `Regular_file -> Ok `File
  | `Directory -> Ok `Directory
  | _ -> Ok `Other
  | exception exn -> io_exception path exn

let non_file_document path =
  Error (Error.Corrupt { path; message = "is not a regular file" })

let mkdir_p store dir =
  if String.is_empty dir || String.equal dir "." then Ok ()
  else
    io dir (fun () ->
        Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path store dir))

let with_lock_path sleep path f =
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
      (* Acquire the cross-process advisory lock without an uncancellable wait.
         [F_TLOCK] is a non-blocking fcntl, so no systhread parks on it: the
         [sleep] between tries is the only wait, and it is an Eio cancellation
         point. A blocked [F_LOCK] in a systhread would ignore cancellation
         until the peer released the lock. *)
      let rec acquire backoff =
        match Unix.lockf fd Unix.F_TLOCK 0 with
        | () -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> acquire backoff
        | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
            sleep backoff;
            acquire (Float.min (backoff *. 2.) 0.1)
      in
      acquire 0.001;
      Fun.protect ~finally:(fun () -> lockf fd Unix.F_ULOCK) f)

(* POSIX record locks exclude other processes but not other fibers in this
   process. Store handles are minted independently, so same-session writers
   share a process registry keyed by the canonical lock path. [users] counts
   owners and waiters before either can block; the last one removes the entry,
   keeping the registry proportional to live transactions rather than every
   session or root the process has ever touched. *)
type session_mutex = { mutex : Eio.Mutex.t; mutable users : int }

let session_mutexes : (string, session_mutex) Hashtbl.t = Hashtbl.create 8
let session_mutexes_guard = Mutex.create ()

type canonical_session_dir = { source : string; canonical : string }

(* Store handles cache their own identity. This small process memo lets newly
   minted handles over a recent root reuse it without another realpath
   round-trip, while path churn can retain at most eight entries. *)
let canonical_session_dirs : canonical_session_dir option array =
  Array.make 8 None

let canonical_session_dirs_guard = Mutex.create ()
let next_canonical_session_dir = ref 0

let find_canonical_session_dir source =
  let rec loop index =
    if index = Array.length canonical_session_dirs then None
    else
      match canonical_session_dirs.(index) with
      | Some entry when String.equal source entry.source -> Some entry.canonical
      | Some _ | None -> loop (index + 1)
  in
  loop 0

let remember_canonical_session_dir source candidate =
  match find_canonical_session_dir source with
  | Some canonical -> canonical
  | None ->
      let index = !next_canonical_session_dir in
      canonical_session_dirs.(index) <- Some { source; canonical = candidate };
      next_canonical_session_dir :=
        (index + 1) mod Array.length canonical_session_dirs;
      candidate

let acquire_session_mutex key =
  Mutex.protect session_mutexes_guard (fun () ->
      match Hashtbl.find_opt session_mutexes key with
      | Some entry ->
          entry.users <- entry.users + 1;
          entry
      | None ->
          let entry = { mutex = Eio.Mutex.create (); users = 1 } in
          Hashtbl.add session_mutexes key entry;
          entry)

let release_session_mutex key entry =
  Mutex.protect session_mutexes_guard (fun () ->
      match Hashtbl.find_opt session_mutexes key with
      | Some current when current == entry ->
          assert (entry.users > 0);
          entry.users <- entry.users - 1;
          if entry.users = 0 then Hashtbl.remove session_mutexes key
      | Some _ | None -> assert false)

let canonical_sessions_dir store native =
  match Atomic.get store.canonical_sessions_dir with
  | Some canonical -> canonical
  | None -> (
      match
        Mutex.protect canonical_session_dirs_guard (fun () ->
            find_canonical_session_dir store.sessions_dir)
      with
      | Some canonical ->
          Atomic.set store.canonical_sessions_dir (Some canonical);
          canonical
      | None ->
          let candidate =
            Eio_unix.run_in_systhread ~label:"session store realpath" (fun () ->
                Unix.realpath native)
          in
          let canonical =
            Mutex.protect canonical_session_dirs_guard (fun () ->
                remember_canonical_session_dir store.sessions_dir candidate)
          in
          Atomic.set store.canonical_sessions_dir (Some canonical);
          canonical)

let with_session_lock store id f =
  let dir = sessions_dir store in
  let* () = mkdir_p store dir in
  let path = lock_path store id in
  match (native_path store dir, native_path store path) with
  | exception exn -> io_exception path exn
  | native_dir, native -> (
      match
        let canonical_dir = canonical_sessions_dir store native_dir in
        let key = Filename.concat canonical_dir (Filename.basename native) in
        let entry = acquire_session_mutex key in
        Fun.protect
          ~finally:(fun () -> release_session_mutex key entry)
          (fun () ->
            Eio.Mutex.use_ro entry.mutex (fun () ->
                with_lock_path store.sleep native f))
      with
      | result -> result
      | exception exn -> io_exception path exn)

let tmp_counter = Atomic.make 0

let tmp_path store path =
  let counter = Atomic.fetch_and_add tmp_counter 1 + 1 in
  let stamp = store.now () |> Int64.bits_of_float |> Int64.to_string in
  path ^ ".tmp."
  ^ string_of_int (Unix.getpid ())
  ^ "." ^ stamp ^ "." ^ string_of_int counter

let now store = store.now () |> Spice_session.Time.of_unix_seconds_float

let touch_for_save store path session =
  match Spice_session.touch (now store) session with
  | session -> Ok session
  | exception Invalid_argument message ->
      Error (Error.Corrupt { path; message })

let encode_session session =
  match Jsont_bytesrw.encode_string Spice_session.jsont session with
  | Ok text -> Ok (text ^ "\n")
  | Error message ->
      Error
        (Error.Corrupt
           {
             path = "<memory>";
             message = "session document encode failed: " ^ message;
           })

let decode_session path text =
  match Jsont_bytesrw.decode_string Spice_session.jsont text with
  | Ok session -> Ok session
  | Error message -> Error (Error.Corrupt { path; message })

let document_of_bytes path text =
  let* session = decode_session path text in
  Ok (Document.make ~session ~revision:(revision_of_bytes text))

let load_path store path =
  let* text = io path (fun () -> Eio.Path.load (fs_path store path)) in
  document_of_bytes path text

let load store id =
  let path = session_path store id in
  match path_kind store path with
  | Error _ as error -> error
  | Ok `Missing -> Error (Error.Not_found id)
  | Ok (`Directory | `Other) -> non_file_document path
  | Ok `File ->
      let* document = load_path store path in
      let actual = Spice_session.id (Document.session document) in
      if Spice_session.Id.equal id actual then Ok document
      else
        Error
          (Error.Corrupt
             {
               path;
               message =
                 Format.asprintf "document id %a does not match requested id %a"
                   Spice_session.Id.pp actual Spice_session.Id.pp id;
             })

let rec fsync fd =
  match Unix.fsync fd with
  | () -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> fsync fd
  | exception Unix.Unix_error (Unix.EINVAL, _, _) -> ()

let rec write_all fd text offset =
  if offset < String.length text then
    match Unix.write_substring fd text offset (String.length text - offset) with
    | 0 -> raise (Unix.Unix_error (Unix.EIO, "write", ""))
    | written -> write_all fd text (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write_all fd text offset

let sync_directory native =
  let fd = Unix.openfile native [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> fsync fd)

let write_document store path text =
  let dir = Filename.dirname path in
  let* () = mkdir_p store dir in
  let tmp = tmp_path store path in
  match
    (native_path store path, native_path store tmp, native_path store dir)
  with
  | exception exn -> io_exception path exn
  | native, native_tmp, native_dir -> (
      match
        Eio_unix.run_in_systhread ~label:"session store durable replace"
          (fun () ->
            let renamed = ref false in
            Fun.protect
              ~finally:(fun () ->
                if not !renamed then
                  try Unix.unlink native_tmp
                  with Unix.Unix_error _ -> ())
              (fun () ->
                let fd =
                  Unix.openfile native_tmp
                    [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY; Unix.O_CLOEXEC ]
                    0o600
                in
                Fun.protect
                  ~finally:(fun () -> Unix.close fd)
                  (fun () ->
                    write_all fd text 0;
                    fsync fd);
                Unix.rename native_tmp native;
                renamed := true;
                sync_directory native_dir))
      with
      | () -> Ok ()
      | exception exn -> io_exception path exn)

let remove_document store path =
  let dir = Filename.dirname path in
  match (native_path store path, native_path store dir) with
  | exception exn -> io_exception path exn
  | native, native_dir -> (
      match
        Eio_unix.run_in_systhread ~label:"session store durable remove"
          (fun () ->
            Unix.unlink native;
            sync_directory native_dir)
      with
      | () -> Ok ()
      | exception exn -> io_exception path exn)

let create store session =
  let id = Spice_session.id session in
  with_session_lock store id (fun () ->
      let path = session_path store id in
      match path_kind store path with
      | Error _ as error -> error
      | Ok `File -> Error (Error.Already_exists id)
      | Ok (`Directory | `Other) -> non_file_document path
      | Ok `Missing ->
          let* text = encode_session session in
          let* () = write_document store path text in
          Log.debug (fun m -> m "session created id=%a" Spice_session.Id.pp id);
          Ok (Document.make ~session ~revision:(revision_of_bytes text)))

let check_document_session ~path document session =
  let document_id = Document.id document in
  let session_id = Spice_session.id session in
  if Spice_session.Id.equal document_id session_id then Ok ()
  else
    (* An id mismatch means the in-memory document and the session it should
       carry have diverged — a consistency fault, reported as an error rather
       than raised so a stray save cannot tear down its caller. *)
    Error
      (Error.Corrupt
         {
           path;
           message =
             Format.asprintf "session id %a does not match document id %a"
               Spice_session.Id.pp session_id Spice_session.Id.pp document_id;
         })

let save store document session =
  let id = Spice_session.id session in
  with_session_lock store id (fun () ->
      let path = session_path store id in
      let* () = check_document_session ~path document session in
      match path_kind store path with
      | Error _ as error -> error
      | Ok `Missing -> Error (Error.Not_found id)
      | Ok (`Directory | `Other) -> non_file_document path
      | Ok `File ->
          let* actual = load_path store path |> Result.map Document.revision in
          let expected = Document.revision document in
          if not (Spice_session.Revision.equal expected actual) then
            Error (Error.Conflict { id; expected; actual })
          else
            let* session = touch_for_save store path session in
            let* text = encode_session session in
            let* () = write_document store path text in
            Log.debug (fun m ->
                m "session saved id=%a status=%a" Spice_session.Id.pp id
                  Spice_session.Metadata.Status.pp
                  (Spice_session.Metadata.status
                     (Spice_session.metadata session)));
            Ok (Document.make ~session ~revision:(revision_of_bytes text)))

let remove store document =
  let id = Document.id document in
  with_session_lock store id (fun () ->
      let path = session_path store id in
      match path_kind store path with
      | Error _ as error -> error
      | Ok `Missing -> Error (Error.Not_found id)
      | Ok (`Directory | `Other) -> non_file_document path
      | Ok `File ->
          let* actual = load_path store path |> Result.map Document.revision in
          let expected = Document.revision document in
          if not (Spice_session.Revision.equal expected actual) then
            Error (Error.Conflict { id; expected; actual })
          else
            let* () = remove_document store path in
            Log.debug (fun m ->
                m "session removed id=%a" Spice_session.Id.pp id);
            Ok ())

let append store document events =
  match Spice_session.Log.append_all events (Document.session document) with
  | Error error -> Error (Error.Session { id = Document.id document; error })
  | Ok session -> save store document session

let session_document_path dir = Filename.concat dir document_filename
let directory_names store path = Eio.Path.read_dir (fs_path store path)

let include_document ~include_archived ~include_deleted document =
  let session = Document.session document in
  match Spice_session.Metadata.status (Spice_session.metadata session) with
  | Spice_session.Metadata.Status.Active -> true
  | Spice_session.Metadata.Status.Archived -> include_archived
  | Spice_session.Metadata.Status.Deleted -> include_deleted

let compare_documents_newest a b =
  let session_a = Document.session a in
  let session_b = Document.session b in
  let metadata_a = Spice_session.metadata session_a in
  let metadata_b = Spice_session.metadata session_b in
  match
    Spice_session.Time.compare
      (Spice_session.Metadata.updated_at metadata_b)
      (Spice_session.Metadata.updated_at metadata_a)
  with
  | 0 ->
      Spice_session.Id.compare
        (Spice_session.id session_b)
        (Spice_session.id session_a)
  | order -> order

let hex_value c =
  if Char.Ascii.is_hex_digit c then Some (Char.Ascii.hex_digit_to_int c)
  else None

let id_of_directory_name name =
  let len = String.length name in
  let buffer = Buffer.create len in
  let rec loop index =
    if index >= len then
      match Spice_session.Id.of_string (Buffer.contents buffer) with
      | id -> Some id
      | exception Invalid_argument _ -> None
    else
      match name.[index] with
      | '%' when index + 2 < len -> (
          match (hex_value name.[index + 1], hex_value name.[index + 2]) with
          | Some high, Some low ->
              Buffer.add_char buffer (Char.chr ((high lsl 4) lor low));
              loop (index + 3)
          | _ -> None)
      | '%' -> None
      | c ->
          Buffer.add_char buffer c;
          loop (index + 1)
  in
  loop 0

let list store ?(include_archived = false) ?(include_deleted = false) ?filter
    ?limit () =
  (match limit with
  | Some limit when limit <= 0 ->
      invalid_arg
        ("Spice_session_store.list: limit must be positive: "
       ^ string_of_int limit)
  | Some _ | None -> ());
  let dir = sessions_dir store in
  match path_kind store dir with
  | Error _ as error -> error
  | Ok `Missing -> Ok ([], [])
  | Ok (`File | `Other) ->
      Error (Error.Io { path = dir; message = "is not a directory" })
  | Ok `Directory ->
      let* names = io dir (fun () -> directory_names store dir) in
      let include_candidate document =
        include_document ~include_archived ~include_deleted document
        && match filter with None -> true | Some f -> f document
      in
      let rec collect documents corrupt = function
        | [] -> Ok (List.rev documents, List.rev corrupt)
        | name :: names -> (
            let child_dir = Filename.concat dir name in
            let path = session_document_path child_dir in
            let path_id = id_of_directory_name name in
            if not (dir_exists store child_dir) then
              collect documents corrupt names
            else
              match path_kind store path with
              | Error error -> Error error
              | Ok `Missing -> collect documents corrupt names
              | Ok (`Directory | `Other) ->
                  collect documents
                    (Corrupt.make ?id:path_id ~path
                       ~message:"is not a regular file" ()
                    :: corrupt)
                    names
              | Ok `File -> (
                  match path_id with
                  | None ->
                      collect documents
                        (Corrupt.make ~path
                           ~message:"store path is not a valid session id" ()
                        :: corrupt)
                        names
                  | Some expected -> (
                      (* [load_path] fails only with [Corrupt] (decode) or [Io]. *)
                      match load_path store path with
                      | Error (Error.Corrupt { path; message }) ->
                          let entry =
                            Corrupt.make ~id:expected ~path ~message ()
                          in
                          Log.warn (fun m ->
                              m "skipped corrupt session path=%s message=%s"
                                (Corrupt.path entry)
                                (log_clip (Corrupt.message entry)));
                          collect documents (entry :: corrupt) names
                      | Error error -> Error error
                      | Ok document ->
                          let actual =
                            Spice_session.id (Document.session document)
                          in
                          if not (Spice_session.Id.equal expected actual) then (
                            let message =
                              Format.asprintf
                                "document id %a does not match store path id %a"
                                Spice_session.Id.pp actual Spice_session.Id.pp
                                expected
                            in
                            Log.warn (fun m ->
                                m "skipped session with mismatched id path=%s"
                                  path);
                            collect documents
                              (Corrupt.make ~id:expected ~path ~message ()
                              :: corrupt)
                              names)
                          else if include_candidate document then
                            collect (document :: documents) corrupt names
                          else collect documents corrupt names)))
      in
      let* documents, corrupt =
        collect [] [] (List.sort String.compare names)
      in
      let documents = List.sort compare_documents_newest documents in
      Ok
        ( (match limit with
          | None -> documents
          | Some limit -> List.take limit documents),
          corrupt )
