(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Session = Spice_session
module Store = Spice_session_store
module Llm = Spice_llm

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
    ~model ()

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

let session_document_path ~root_path id =
  let sessions = Eio.Path.( / ) root_path "sessions" in
  let session_dir = Eio.Path.( / ) sessions id in
  Eio.Path.( / ) session_dir "session.json"

let session_json id =
  Printf.sprintf
    "{\"version\":1,\"id\":%S,\"metadata\":{\"status\":\"active\",\
     \"cwd\":\"/workspace\",\"created_at\":1,\"updated_at\":1},\"events\":[]}\n"
    id

let doc_id document =
  Session.Id.to_string (Session.id (Store.Document.session document))

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
   id is a programmer error, not a recoverable conflict. *)
let save_rejects_id_mismatch () =
  with_store "mismatch" @@ fun ~root_path:_ store ->
  let document = ok_or_fail (Store.create store (make_session "a")) in
  raises_invalid_arg "session id b does not match document id a" (fun () ->
      Store.save store document (make_session "b"))

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
  let writers = 8 in
  let results = Array.make writers (Ok base) in
  Eio.Fiber.all
    (List.init writers (fun i () ->
         (* A fresh handle per fiber: exclusion must hold across handles, not
            just within one. *)
         let store = Store.make ~fs ~clock ~root in
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
      test "list filters lifecycle and applies limit"
        list_filters_lifecycle_and_limit;
      test "list reports corrupt entries without counting the limit"
        list_reports_corrupt_without_counting_limit;
      test "list reports a non-file document path"
        list_reports_non_file_document_path;
      test "list rejects an invalid session directory name"
        list_rejects_invalid_session_directory_name;
      test "stale writers conflict loudly" stale_writers_conflict_loudly;
      test "concurrent saves preserve the compare-and-set"
        concurrent_saves_preserve_the_cas;
      test "corrupt decode error is intentional"
        corrupt_decode_error_is_intentional;
    ]
