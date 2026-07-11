(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Session = Spice_session
module Store = Spice_session_store
module Llm = Spice_llm

let lock_holder_mode = "--session-store-lock-holder"

(* A separate process is required here: POSIX record locks are per-process, so
   a descriptor locked by this test process would not exclude a store handle in
   another fiber. The helper locks every path before announcing readiness and
   retains ownership until its standard input is closed. *)
let () =
  if Array.length Sys.argv > 2 && String.equal Sys.argv.(1) lock_holder_mode then
    let paths = Array.to_list (Array.sub Sys.argv 2 (Array.length Sys.argv - 2)) in
    let descriptors =
      List.map
        (fun path ->
          let fd =
            Unix.openfile path [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
              0o600
          in
          Unix.lockf fd Unix.F_LOCK 0;
          fd)
        paths
    in
    print_endline "ready";
    (match input_char stdin with _ -> () | exception End_of_file -> ());
    List.iter
      (fun fd ->
        Unix.lockf fd Unix.F_ULOCK 0;
        Unix.close fd)
      descriptors;
    exit 0

(* The compare-and-set backstop. CLI commands load and save inside one process
   under the store lock, so a concurrent-writer conflict cannot be produced
   deterministically through the binary; the store is the layer that owns the
   revision comparison, and these tests pin it: a stale writer fails loudly
   with both revisions, and the winning document is untouched. *)

let ok_or_fail = function
  | Ok value -> value
  | Error error -> failf "unexpected store error: %a" Store.Error.pp error

let model =
  Llm.Model.make
    ~provider:(Llm.Provider.make "openai")
    ~api:(Llm.Model.Api.make "responses")
    ~id:"gpt-5"

let cwd = Spice_path.Abs.of_string_exn "/workspace"

let turn =
  Session.Turn.make
    ~id:(Session.Turn.Id.of_string "turn-1")
    ~input:(Session.Turn.Input.user_text "Continue.")
    ~model ~declarations:[] ~host_tools:[] ~max_steps:max_int ()

let revision_string document =
  Session.Revision.to_string (Store.Document.revision document)

let make_session id =
  Session.create ~id:(Session.Id.of_string id) ~cwd
    ~created_at:(Session.Time.of_unix_ms 1L)
    ()

(* Every test drives a fresh store rooted at a unique temporary directory, so
   the cases share no on-disk state and the suite is safe to re-run. [root_path]
   is the store root as an fs-relative Eio path for tests that need to plant
   files directly (such as a corrupt document). *)
let with_store name f =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let root_native = Filename.temp_dir ("spice_session_store_" ^ name) "" in
  let root = Spice_path.Abs.of_string_exn root_native in
  let root_path = Eio.Path.( / ) fs root_native in
  let store = Store.make ~fs ~clock:(Eio.Stdenv.clock env) ~root in
  f ~root_path store

(* Some tests mint several store handles over one root to exercise cross-handle
   behavior, so they need the raw [fs]/[clock]/[root] rather than a single
   pre-built store. *)
let with_store_env name f =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  let root_native = Filename.temp_dir ("spice_session_store_" ^ name) "" in
  let root = Spice_path.Abs.of_string_exn root_native in
  f ~fs ~clock ~root

type lock_holder = {
  input : in_channel;
  output : out_channel;
  mutable released : bool;
}

let release_lock_holder holder =
  if not holder.released then begin
    holder.released <- true;
    close_out_noerr holder.output;
    match Unix.close_process (holder.input, holder.output) with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED code -> failf "lock holder exited with status %d" code
    | Unix.WSIGNALED signal -> failf "lock holder got signal %d" signal
    | Unix.WSTOPPED signal -> failf "lock holder stopped on signal %d" signal
  end

let with_lock_holder paths f =
  let argv = Array.of_list (Sys.executable_name :: lock_holder_mode :: paths) in
  let input, output = Unix.open_process_args Sys.executable_name argv in
  let holder = { input; output; released = false } in
  Fun.protect
    ~finally:(fun () -> release_lock_holder holder)
    (fun () ->
      equal string ~msg:"lock holder readiness" "ready" (input_line input);
      f holder)

let session_document_path ~root_path id =
  let sessions = Eio.Path.( / ) root_path "sessions" in
  let session_dir = Eio.Path.( / ) sessions id in
  Eio.Path.( / ) session_dir "session.json"

let session_json id =
  Printf.sprintf
    "{\"version\":1,\"id\":%S,\"metadata\":{\"status\":\"active\",\"cwd\":\"/workspace\",\"created_at\":1,\"updated_at\":1},\"events\":[]}\n"
    id

let doc_id document = Session.Id.to_string (Store.Document.id document)

let listed_ids result =
  let documents, _corrupt = ok_or_fail result in
  List.sort String.compare (List.map doc_id documents)

let create_rejects_duplicate () =
  with_store "duplicate" @@ fun ~root_path:_ store ->
  let session = make_session "dup" in
  ignore (ok_or_fail (Store.create store session));
  match Store.create store session with
  | Ok _ -> failf "a second create for the same id must fail"
  | Error (Store.Error.Already_exists id) ->
      equal string ~msg:"already-exists carries the session id" "dup"
        (Session.Id.to_string id)
  | Error error -> failf "unexpected error: %a" Store.Error.pp error

let load_missing_is_not_found () =
  with_store "notfound" @@ fun ~root_path:_ store ->
  match Store.load store (Session.Id.of_string "ghost") with
  | Ok _ -> failf "loading an absent session must fail"
  | Error (Store.Error.Not_found id) ->
      equal string ~msg:"not-found carries the requested id" "ghost"
        (Session.Id.to_string id)
  | Error error -> failf "unexpected error: %a" Store.Error.pp error

let load_rejects_non_file_document_path () =
  with_store "load-non-file" @@ fun ~root_path store ->
  let id = Session.Id.of_string "doc" in
  ignore (ok_or_fail (Store.create store (make_session "doc")));
  let path = session_document_path ~root_path "doc" in
  Eio.Path.unlink path;
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 path;
  match Store.load store id with
  | Error (Store.Error.Corrupt { path; message }) ->
      is_true ~msg:"corrupt path names the document"
        (String.includes ~affix:"doc/session.json" path);
      equal string ~msg:"non-file document message" "is not a regular file"
        message
  | Ok _ -> failf "non-file session document should not load"
  | Error error -> failf "unexpected error: %a" Store.Error.pp error

(* R2: the removed [Invalid_limit] recoverable error is now a programmer-error
   exception. A non-positive limit is a caller bug, not a store outcome. *)
let list_rejects_non_positive_limit () =
  with_store "limit" @@ fun ~root_path:_ store ->
  ignore (ok_or_fail (Store.create store (make_session "one")));
  raises_invalid_arg "Spice_session_store.list: limit must be positive: 0"
    (fun () -> Store.list store ~limit:0 ());
  raises_invalid_arg "Spice_session_store.list: limit must be positive: -3"
    (fun () -> Store.list store ~limit:(-3) ())

(* [save] pairs a document with a session; supplying a session for a different
   id is a consistency fault, surfaced as an error rather than raised so a stray
   save never tears down its caller. *)
let save_rejects_id_mismatch () =
  with_store "mismatch" @@ fun ~root_path:_ store ->
  let document = ok_or_fail (Store.create store (make_session "a")) in
  match Store.save store document (make_session "b") with
  | Error (Store.Error.Corrupt { message; _ }) ->
      equal string ~msg:"the mismatch names both ids"
        "session id b does not match document id a" message
  | Ok _ -> failf "saving a mismatched session should fail"
  | Error error -> failf "unexpected error: %a" Store.Error.pp error

let save_after_removed_document_is_not_found () =
  with_store "save-removed" @@ fun ~root_path store ->
  let document = ok_or_fail (Store.create store (make_session "doc")) in
  let path = session_document_path ~root_path "doc" in
  Eio.Path.unlink path;
  let session =
    Session.set_title (Some "should-not-return")
      (Store.Document.session document)
  in
  match Store.save store document session with
  | Error (Store.Error.Not_found id) ->
      equal string ~msg:"not-found carries the document id" "doc"
        (Session.Id.to_string id);
      is_false ~msg:"stale save does not recreate the document"
        (Eio.Path.is_file path)
  | Ok _ -> failf "saving after the backing document disappeared should fail"
  | Error error -> failf "unexpected error: %a" Store.Error.pp error

let append_reports_session_errors () =
  with_store "append-session-error" @@ fun ~root_path:_ store ->
  let document = ok_or_fail (Store.create store (make_session "doc")) in
  let invalid =
    Session.Event.turn_finished
      ~turn:(Session.Turn.Id.of_string "missing")
      Session.Turn.Outcome.completed
  in
  match Store.append store document [ invalid ] with
  | Error
      (Store.Error.Session { id; error = Session.Error.Replay replay_error }) ->
      equal string ~msg:"session error carries the document id" "doc"
        (Session.Id.to_string id);
      equal int ~msg:"session error carries the event index" 0
        (Session.State.Replay_error.index replay_error);
      let loaded = ok_or_fail (Store.load store id) in
      equal string ~msg:"failed append leaves revision unchanged"
        (revision_string document) (revision_string loaded)
  | Ok _ -> failf "invalid append should fail"
  | Error error -> failf "unexpected error: %a" Store.Error.pp error

let list_filters_lifecycle_and_limit () =
  with_store "list" @@ fun ~root_path:_ store ->
  let active = ok_or_fail (Store.create store (make_session "active")) in
  let arch_doc = ok_or_fail (Store.create store (make_session "arch")) in
  let del_doc = ok_or_fail (Store.create store (make_session "del")) in
  ignore active;
  (* All three are active before any lifecycle transition: the limit truncates
     the result set without failing, corrupt-free. *)
  equal int ~msg:"limit truncates the listing" 2
    (List.length (fst (ok_or_fail (Store.list store ~limit:2 ()))));
  let lifecycle op doc =
    match op (Store.Document.session doc) with
    | Ok session -> ignore (ok_or_fail (Store.save store doc session))
    | Error error -> failf "lifecycle: %s" (Session.Error.message error)
  in
  lifecycle Session.archive arch_doc;
  lifecycle Session.delete del_doc;
  equal (list string) ~msg:"default listing hides archived and deleted"
    [ "active" ]
    (listed_ids (Store.list store ()));
  equal (list string) ~msg:"include_archived surfaces archived sessions"
    [ "active"; "arch" ]
    (listed_ids (Store.list store ~include_archived:true ()));
  equal (list string) ~msg:"include_deleted surfaces deleted sessions"
    [ "active"; "del" ]
    (listed_ids (Store.list store ~include_deleted:true ()));
  equal (list string) ~msg:"both flags surface every session"
    [ "active"; "arch"; "del" ]
    (listed_ids
       (Store.list store ~include_archived:true ~include_deleted:true ()))

let list_reports_corrupt_without_counting_limit () =
  with_store "list-corrupt" @@ fun ~root_path store ->
  ignore (ok_or_fail (Store.create store (make_session "good")));
  let bad_dir = Eio.Path.( / ) (Eio.Path.( / ) root_path "sessions") "bad" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 bad_dir;
  Eio.Path.save ~create:(`Or_truncate 0o600)
    (Eio.Path.( / ) bad_dir "session.json")
    "{";
  let documents, corrupt = ok_or_fail (Store.list store ~limit:1 ()) in
  (* The one good document fills the whole limit even though a corrupt entry
     was scanned: corrupt entries are reported as facts, not counted. *)
  equal (list string) ~msg:"good document is returned" [ "good" ]
    (List.sort String.compare (List.map doc_id documents));
  match corrupt with
  | [ entry ] ->
      equal (option string) ~msg:"corrupt entry carries its parsed id"
        (Some "bad")
        (Option.map Session.Id.to_string entry.Store.Corrupt.id);
      is_true ~msg:"corrupt entry names its path"
        (String.includes ~affix:"bad" entry.Store.Corrupt.path)
  | entries -> failf "expected one corrupt entry, got %d" (List.length entries)

let list_reports_non_file_document_path () =
  with_store "list-non-file" @@ fun ~root_path store ->
  ignore (ok_or_fail (Store.create store (make_session "doc")));
  let path = session_document_path ~root_path "doc" in
  Eio.Path.unlink path;
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 path;
  let documents, corrupt = ok_or_fail (Store.list store ()) in
  equal (list string) ~msg:"non-file document is not listed" []
    (List.map doc_id documents);
  match corrupt with
  | [ entry ] ->
      equal (option string) ~msg:"corrupt entry carries the parsed id"
        (Some "doc")
        (Option.map Session.Id.to_string entry.Store.Corrupt.id);
      equal string ~msg:"non-file document message" "is not a regular file"
        entry.Store.Corrupt.message
  | entries -> failf "expected one corrupt entry, got %d" (List.length entries)

let list_rejects_invalid_session_directory_name () =
  with_store "list-invalid-dir" @@ fun ~root_path store ->
  let bad_dir = Eio.Path.( / ) (Eio.Path.( / ) root_path "sessions") "%ZZ" in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 bad_dir;
  Eio.Path.save ~create:(`Exclusive 0o600)
    (Eio.Path.( / ) bad_dir "session.json")
    (session_json "doc");
  let documents, corrupt = ok_or_fail (Store.list store ()) in
  equal (list string) ~msg:"invalid path document is not listed" []
    (List.map doc_id documents);
  match corrupt with
  | [ entry ] ->
      equal (option string) ~msg:"invalid path has no parsed id" None
        (Option.map Session.Id.to_string entry.Store.Corrupt.id);
      equal string ~msg:"invalid session path message"
        "store path is not a valid session id" entry.Store.Corrupt.message
  | entries -> failf "expected one corrupt entry, got %d" (List.length entries)

let stale_writers_conflict_loudly () =
  with_store "conflict" @@ fun ~root_path:_ store ->
  let session = make_session "doc" in
  let stale = ok_or_fail (Store.create store session) in
  let winner =
    ok_or_fail
      (Store.save store stale (Session.set_title (Some "winner") session))
  in
  let expect_conflict msg result =
    match result with
    | Ok _ -> failf "%s with a stale revision must conflict" msg
    | Error (Store.Error.Conflict { id; expected; actual }) ->
        equal string
          ~msg:(msg ^ " conflict carries the session id")
          "doc" (Session.Id.to_string id);
        equal string
          ~msg:(msg ^ " conflict carries the stale revision")
          (revision_string stale)
          (Session.Revision.to_string expected);
        equal string
          ~msg:(msg ^ " conflict carries the persisted revision")
          (revision_string winner)
          (Session.Revision.to_string actual)
    | Error error -> failf "%s: unexpected error: %a" msg Store.Error.pp error
  in
  expect_conflict "save"
    (Store.save store stale (Session.set_title (Some "loser") session));
  expect_conflict "append"
    (Store.append store stale [ Session.Event.turn_started turn ]);
  let loaded = ok_or_fail (Store.load store (Session.Id.of_string "doc")) in
  equal string ~msg:"the winning revision is intact" (revision_string winner)
    (revision_string loaded);
  equal string ~msg:"the winning document content is intact" "winner"
    (Option.value ~default:"-"
       (Session.Metadata.title
          (Session.metadata (Store.Document.session loaded))))

let remove_is_revision_checked_and_allows_recreate () =
  with_store "remove" @@ fun ~root_path:_ store ->
  let session = make_session "removable" in
  let stale = ok_or_fail (Store.create store session) in
  let current =
    ok_or_fail
      (Store.save store stale (Session.set_title (Some "current") session))
  in
  (match Store.remove store stale with
  | Error (Store.Error.Conflict _) -> ()
  | Error error -> failf "stale remove returned: %a" Store.Error.pp error
  | Ok () -> failf "stale remove should conflict");
  ok_or_fail (Store.remove store current);
  (match Store.load store (Session.Id.of_string "removable") with
  | Error (Store.Error.Not_found _) -> ()
  | Error error ->
      failf "removed document load returned: %a" Store.Error.pp error
  | Ok _ -> failf "removed document should be absent");
  ignore (ok_or_fail (Store.create store session))

(* The revision check in [save] is a compare-and-set: at most one writer that
   observed a given revision may commit; the rest must see a [Conflict]. The
   cross-process advisory lock ([sessions/.lock]) alone does not enforce this
   between fibers of one process — a process never blocks on its own lock — so
   without intra-process serialization two same-process fibers can each re-read
   the revision, both find it current, and both write, silently losing one
   update. This drives that race: several fibers, each holding its own store
   handle over the same root (handles are minted per call in production), race
   [save] from one shared base document. Under a correct store exactly one
   commits and the others conflict; a lost update shows up as a second [Ok]. *)
let concurrent_saves_preserve_the_cas () =
  with_store_env "race" @@ fun ~fs ~clock ~root ->
  let base_store = Store.make ~fs ~clock ~root in
  let base = ok_or_fail (Store.create base_store (make_session "race")) in
  let root_native = Spice_path.Abs.to_string root in
  let alias_native = Filename.concat root_native "alias" in
  Unix.symlink "." alias_native;
  let alias = Spice_path.Abs.of_string_exn alias_native in
  let writers = 8 in
  let results = Array.make writers (Ok base) in
  Eio.Fiber.all
    (List.init writers (fun i () ->
         (* A fresh handle per fiber: exclusion must hold across handles, not
            just within one. Alternate writers address the same root through a
            symlink so lock identity must be canonical rather than textual. *)
         let writer_root = if i mod 2 = 0 then root else alias in
         let store = Store.make ~fs ~clock ~root:writer_root in
         let session =
           Session.set_title
             (Some (Printf.sprintf "writer-%d" i))
             (Store.Document.session base)
         in
         results.(i) <- Store.save store base session));
  let committed =
    Array.fold_left
      (fun n result -> match result with Ok _ -> n + 1 | Error _ -> n)
      0 results
  in
  Array.iter
    (function
      | Ok _ | Error (Store.Error.Conflict _) -> ()
      | Error error ->
          failf "a losing writer must conflict, not: %a" Store.Error.pp error)
    results;
  equal int ~msg:"exactly one racing writer commits under the CAS" 1 committed;
  (* The persisted document is one of the writers' documents, intact and
     loadable, with a title from the winning writer. *)
  let loaded =
    ok_or_fail (Store.load base_store (Session.Id.of_string "race"))
  in
  let title =
    Session.Metadata.title (Session.metadata (Store.Document.session loaded))
  in
  is_true ~msg:"the committed document carries a writer's title"
    (match title with
    | Some title -> String.starts_with ~prefix:"writer-" title
    | None -> false)

(* A durability stall belongs to the session being committed. The helper holds
   both the former root-wide lock and the new session lock so the same test is a
   failing-first reproduction on the old implementation: old code blocks both
   writers on [.lock], while per-session locking blocks only [locked]. *)
let a_stalled_session_does_not_block_another () =
  with_store_env "lock-scope" @@ fun ~fs ~clock ~root ->
  let store = Store.make ~fs ~clock ~root in
  let locked = ok_or_fail (Store.create store (make_session "locked")) in
  let independent =
    ok_or_fail (Store.create store (make_session "independent"))
  in
  let sessions = Filename.concat (Spice_path.Abs.to_string root) "sessions" in
  with_lock_holder
    [ Filename.concat sessions ".lock"; Filename.concat sessions "locked.lock" ]
  @@ fun holder ->
  Eio.Switch.run @@ fun sw ->
  let locked_save =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Store.save store locked
          (Session.set_title (Some "locked") (Store.Document.session locked)))
  in
  Eio.Time.sleep clock 0.02;
  let independent_save =
    Eio.Time.with_timeout clock 0.2 (fun () ->
        Ok
          (Store.save store independent
             (Session.set_title (Some "independent")
                (Store.Document.session independent))))
  in
  release_lock_holder holder;
  let locked_result =
    match Eio.Promise.await locked_save with
    | Ok result -> result
    | Error exn -> failf "locked save failed: %s" (Printexc.to_string exn)
  in
  ignore (ok_or_fail locked_result);
  match independent_save with
  | Ok result -> ignore (ok_or_fail result)
  | Error `Timeout ->
      failf "an unrelated session waited behind the stalled commit"

let cancelling_a_lock_wait_releases_process_ownership () =
  with_store_env "lock-cancel" @@ fun ~fs ~clock ~root ->
  let store = Store.make ~fs ~clock ~root in
  let document = ok_or_fail (Store.create store (make_session "locked")) in
  let sessions = Filename.concat (Spice_path.Abs.to_string root) "sessions" in
  with_lock_holder
    [ Filename.concat sessions ".lock"; Filename.concat sessions "locked.lock" ]
  @@ fun holder ->
  let started = Unix.gettimeofday () in
  let cancelled =
    Eio.Time.with_timeout clock 0.03 (fun () ->
        Ok
          (Store.save store document
             (Session.set_title (Some "cancelled")
                (Store.Document.session document))))
  in
  let elapsed = Unix.gettimeofday () -. started in
  (match cancelled with
  | Error `Timeout -> ()
  | Ok _ -> failf "the lock wait completed while another process owned it");
  is_true ~msg:"lock cancellation is bounded by the polling cadence"
    (elapsed < 0.2);
  release_lock_holder holder;
  let loaded = ok_or_fail (Store.load store (Session.Id.of_string "locked")) in
  equal string ~msg:"a cancelled waiter did not modify the document"
    (revision_string document) (revision_string loaded);
  ignore
    (ok_or_fail
       (Store.save store document
          (Session.set_title (Some "after-cancel")
             (Store.Document.session document))))

let corrupt_decode_error_is_intentional () =
  with_store "corrupt" @@ fun ~root_path store ->
  let session_dir =
    Eio.Path.( / ) (Eio.Path.( / ) root_path "sessions") "doc"
  in
  Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 session_dir;
  Eio.Path.save ~create:(`Or_truncate 0o600)
    (Eio.Path.( / ) session_dir "session.json")
    "{";
  let id = Session.Id.of_string "doc" in
  match Store.load store id with
  | Error (Store.Error.Corrupt { path; message } as error) ->
      is_false ~msg:"store error preserves decoder message"
        (String.starts_with ~prefix:"session document is invalid" message);
      let diagnostic = Store.Error.diagnostic ~id error in
      let rendered = Spice_diagnostic.to_string diagnostic in
      is_true ~msg:"diagnostic has intentional headline"
        (String.includes ~affix:"session doc is invalid" rendered);
      is_true ~msg:"diagnostic includes path"
        (String.includes ~affix:path rendered);
      is_true ~msg:"diagnostic includes decoder detail"
        (String.includes ~affix:message rendered)
  | Ok _ -> failf "corrupt session should not load"
  | Error error -> failf "unexpected store error: %a" Store.Error.pp error

let () =
  run "spice.session_store"
    [
      test "create rejects a duplicate id" create_rejects_duplicate;
      test "load of a missing session is not found" load_missing_is_not_found;
      test "load rejects a non-file document path"
        load_rejects_non_file_document_path;
      test "list rejects a non-positive limit" list_rejects_non_positive_limit;
      test "save rejects a session id mismatch" save_rejects_id_mismatch;
      test "save after a removed document is not found"
        save_after_removed_document_is_not_found;
      test "append reports session errors" append_reports_session_errors;
      test "list filters lifecycle and applies limit"
        list_filters_lifecycle_and_limit;
      test "list reports corrupt entries without counting the limit"
        list_reports_corrupt_without_counting_limit;
      test "list reports a non-file document path"
        list_reports_non_file_document_path;
      test "list rejects an invalid session directory name"
        list_rejects_invalid_session_directory_name;
      test "stale writers conflict loudly" stale_writers_conflict_loudly;
      test "remove is revision checked and allows recreate"
        remove_is_revision_checked_and_allows_recreate;
      test "concurrent saves preserve the compare-and-set"
        concurrent_saves_preserve_the_cas;
      test "a stalled session does not block an unrelated session"
        a_stalled_session_does_not_block_another;
      test "cancelling a lock wait releases process ownership"
        cancelling_a_lock_wait_releases_process_ownership;
      test "corrupt decode error is intentional"
        corrupt_decode_error_is_intentional;
    ]
