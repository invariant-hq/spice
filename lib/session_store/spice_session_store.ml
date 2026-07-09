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
}

let make ~fs ~clock ~root =
  Log.debug (fun m -> m "store opened root=%s" (Spice_path.Abs.to_string root));
  {
    fs;
    now = (fun () -> Eio.Time.now clock);
    sleep = (fun seconds -> Eio.Time.sleep clock seconds);
    root;
  }

let root t = t.root
let root_string t = Spice_path.Abs.to_string t.root

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
let sessions_dir t = Filename.concat (root_string t) "sessions"
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

let lock_path store = Filename.concat (sessions_dir store) ".lock"
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

(* Intra-process serialization for the compare-and-set write path. The advisory
   lock in [with_lock_path] excludes other processes but never excludes a
   process from itself: POSIX record locks are per-process, so two fibers on
   distinct handles over one root each acquire the lock and interleave their
   re-read-check-write across the Eio suspension points inside [load_path] and
   [write_document], losing an update. This table maps a root's canonical path
   to the single mutex every same-process writer on that root contends for.
   Handles are minted per call, so the mutex cannot live on [t]; it is
   process-global and keyed by canonical path so handles opened on the same
   directory through different spellings or symlinks share one mutex.
   [Stdlib.Mutex] guards the table so lookups stay safe even if writes ever
   arrive from more than one domain. *)
let write_mutexes : (string, Eio.Mutex.t) Hashtbl.t = Hashtbl.create 8
let write_mutexes_guard = Mutex.create ()

let write_mutex_for key =
  Mutex.protect write_mutexes_guard (fun () ->
      match Hashtbl.find_opt write_mutexes key with
      | Some mutex -> mutex
      | None ->
          let mutex = Eio.Mutex.create () in
          Hashtbl.replace write_mutexes key mutex;
          mutex)

let with_sessions_lock store f =
  let dir = sessions_dir store in
  let* () = mkdir_p store dir in
  let path = lock_path store in
  match native_path store path with
  | exception exn -> io_exception path exn
  | native -> (
      (* [dir] exists after [mkdir_p], so canonicalizing it cannot fail under
         normal operation; fall back to the raw path so a same-spelling handle
         still serializes if it somehow does. [use_ro] unlocks rather than
         poisons on exception, keeping the cached mutex usable across calls. *)
      let key =
        try Unix.realpath (Filename.dirname native) with _ -> native
      in
      let mutex = write_mutex_for key in
      match
        Eio.Mutex.use_ro mutex (fun () -> with_lock_path store.sleep native f)
      with
      | result -> result
      | exception exn -> io_exception path exn)

let tmp_counter = ref 0

let tmp_path store path =
  incr tmp_counter;
  let stamp = store.now () |> Int64.bits_of_float |> Int64.to_string in
  path ^ ".tmp."
  ^ string_of_int (Unix.getpid ())
  ^ "." ^ stamp ^ "." ^ string_of_int !tmp_counter

let cleanup_tmp store tmp =
  try Eio.Path.unlink (fs_path store tmp)
  with exn ->
    Log.debug (fun m ->
        m "tmp cleanup failed path=%s exn=%s" tmp (Printexc.to_string exn))

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

let fsync_path store path =
  match native_path store path with
  | exception exn -> io_exception path exn
  | native -> (
      match Unix.openfile native [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
      | exception Unix.Unix_error (error, _, _) ->
          Error (Error.Io { path; message = Unix.error_message error })
      | fd ->
          Fun.protect
            ~finally:(fun () -> Unix.close fd)
            (fun () ->
              match Unix.fsync fd with
              | () -> Ok ()
              | exception Unix.Unix_error (Unix.EINVAL, _, _) -> Ok ()
              | exception Unix.Unix_error (error, _, _) ->
                  Error (Error.Io { path; message = Unix.error_message error }))
      )

let write_document store path text =
  let dir = Filename.dirname path in
  let* () = mkdir_p store dir in
  let tmp = tmp_path store path in
  match Eio.Path.save ~create:(`Exclusive 0o600) (fs_path store tmp) text with
  | exception exn -> io_exception path exn
  | () -> (
      match fsync_path store tmp with
      | Error _ as error ->
          cleanup_tmp store tmp;
          error
      | Ok () -> (
          match Eio.Path.rename (fs_path store tmp) (fs_path store path) with
          | () -> fsync_path store dir
          | exception exn ->
              cleanup_tmp store tmp;
              io_exception path exn))

let create store session =
  with_sessions_lock store (fun () ->
      let id = Spice_session.id session in
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

let check_document_session document session =
  let document_id = Document.id document in
  let session_id = Spice_session.id session in
  if Spice_session.Id.equal document_id session_id then ()
  else
    invalid_arg
      (Format.asprintf "session id %a does not match document id %a"
         Spice_session.Id.pp session_id Spice_session.Id.pp document_id)

let save store document session =
  check_document_session document session;
  with_sessions_lock store (fun () ->
      let id = Spice_session.id session in
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
            let* session = touch_for_save store path session in
            let* text = encode_session session in
            let* () = write_document store path text in
            Log.debug (fun m ->
                m "session saved id=%a status=%a" Spice_session.Id.pp id
                  Spice_session.Metadata.Status.pp
                  (Spice_session.Metadata.status
                     (Spice_session.metadata session)));
            Ok (Document.make ~session ~revision:(revision_of_bytes text)))

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
