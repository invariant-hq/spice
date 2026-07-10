(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Fswatch = Spice_fswatch
module Event = Fswatch.Event
module Error = Fswatch.Error
module Path = Spice_path

let fswatch_error = testable ~pp:Error.pp ~equal:( = ) ()
let event = testable ~pp:Event.pp ~equal:Event.equal ()

let expect_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Error.pp error

let expect_error msg result check =
  match result with
  | Ok value ->
      ignore value;
      failf "%s: expected error" msg
  | Error error -> check error

let expect_invalid_argument msg f =
  raises_match ~msg
    (function Invalid_argument _ -> true | _ -> false)
    (fun () -> ignore (f ()))

let rel path =
  match Path.Rel.of_string path with
  | Ok path -> path
  | Error error ->
      failf "invalid relative test path %S: %a" path Path.Error.pp error

let ev kind path = { Event.path = rel path; kind }

let events expected actual =
  equal (list event)
    (List.sort Event.compare expected)
    (List.sort Event.compare actual)

let path root rel = Filename.concat root rel

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stats -> (
      match stats.Unix.st_kind with
      | Unix.S_DIR ->
          Array.iter
            (fun name ->
              if (not (String.equal name ".")) && not (String.equal name "..")
              then rm_rf (Filename.concat path name))
            (Sys.readdir path);
          Unix.rmdir path
      | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Unix.unlink path)

let with_temp_dir f =
  let file = Filename.temp_file "spice-fswatch-" ".tmp" in
  Unix.unlink file;
  Unix.mkdir file 0o755;
  Fun.protect ~finally:(fun () -> rm_rf file) (fun () -> f file)

let mkdir_p dir =
  let rec loop dir =
    if Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  loop dir

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc contents;
      flush oc)

let touch_mtime path =
  let now = Unix.gettimeofday () +. 2.0 in
  Unix.utimes path now now

let rename src dst = Unix.rename src dst

let with_eio f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw -> f ~sw ~clock:(Eio.Stdenv.clock env)

let make ?backend ?(poll_interval = 0.01) ?(settle_delay = 0.01)
    ?(ignore = fun _ -> false) ~sw ~clock root =
  expect_ok "make watcher"
    (Fswatch.make ~sw ~clock ?backend ~poll_interval ~settle_delay ~ignore ~root
       ())

let poll watcher = expect_ok "poll watcher" (Fswatch.poll watcher)
let reset watcher = expect_ok "reset watcher" (Fswatch.reset watcher)
let fail_on_watch_error error = failf "watcher error: %a" Error.pp error

let next_timeout ~clock ?(timeout = 2.0) watcher =
  match
    Eio.Time.with_timeout clock timeout (fun () ->
        match Fswatch.next watcher with
        | Ok value -> Ok value
        | Error error -> Error (`Watcher error))
  with
  | Ok value -> value
  | Error `Timeout -> failf "timed out waiting for watcher"
  | Error (`Watcher error) -> failf "watcher error: %a" Error.pp error

let stream_take ~clock ?(timeout = 2.0) stream =
  match
    Eio.Time.with_timeout clock timeout (fun () -> Ok (Eio.Stream.take stream))
  with
  | Ok value -> value
  | Error `Timeout -> failf "timed out waiting on watch stream"

let event_values () =
  let a = ev Event.Created "a" in
  let b = ev Event.Changed "b" in
  let a_deleted = ev Event.Deleted "a" in
  equal event ~msg:"record fields preserve event" a
    { Event.path = a.Event.path; kind = a.Event.kind };
  is_true ~msg:"path orders before kind" (Event.compare a b < 0);
  is_true ~msg:"kind orders stable at same path" (Event.compare a a_deleted < 0)

let construction_rejects_invalid_roots () =
  with_eio @@ fun ~sw ~clock ->
  expect_error "empty root"
    (Fswatch.make ~sw ~clock ~backend:`Polling ~root:"" ()) (fun error ->
      equal fswatch_error
        (Error.Invalid_root
           { root = ""; reason = "root must not be empty or contain NUL" })
        error);
  expect_error "relative root"
    (Fswatch.make ~sw ~clock ~backend:`Polling ~root:"relative" ())
    (fun error ->
      equal fswatch_error
        (Error.Invalid_root
           { root = "relative"; reason = "root must be absolute" })
        error);
  with_temp_dir @@ fun root ->
  let file = path root "file" in
  write_file file "x";
  expect_error "file root"
    (Fswatch.make ~sw ~clock ~backend:`Polling ~root:file ()) (fun error ->
      equal fswatch_error
        (Error.Invalid_root
           { root = Unix.realpath file; reason = "root is not a directory" })
        error);
  expect_error "missing root"
    (Fswatch.make ~sw ~clock ~backend:`Polling ~root:(path root "missing") ())
    (function
      | Error.Invalid_root { reason = "root does not exist"; _ } -> ()
      | error -> failf "unexpected error: %a" Error.pp error)

let construction_rejects_invalid_timing_values () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  List.iter
    (fun poll_interval ->
      expect_invalid_argument "invalid poll interval" (fun () ->
          Fswatch.make ~sw ~clock ~backend:`Polling ~poll_interval ~root ()))
    [ 0.0; -1.0; infinity; nan ];
  expect_invalid_argument "invalid settle delay" (fun () ->
      Fswatch.make ~sw ~clock ~backend:`Polling ~settle_delay:0.0 ~root ())

let watch_rejects_invalid_timing_values () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  List.iter
    (fun poll_interval ->
      expect_invalid_argument "invalid watch poll interval" (fun () ->
          Fswatch.watch ~sw ~clock ~backend:`Polling ~poll_interval
            ~on_error:fail_on_watch_error ~root ~f:ignore ()))
    [ 0.0; -1.0; infinity; nan ];
  expect_invalid_argument "invalid watch settle delay" (fun () ->
      Fswatch.watch ~sw ~clock ~backend:`Polling ~settle_delay:0.0
        ~on_error:fail_on_watch_error ~root ~f:ignore ())

let polling_initial_snapshot_is_baseline () =
  with_temp_dir @@ fun root ->
  write_file (path root "a") "a";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  events [] (poll watcher)

let polling_create_modify_delete () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  write_file (path root "a") "one";
  events [ ev Event.Created "a" ] (poll watcher);
  write_file (path root "a") "two";
  touch_mtime (path root "a");
  events [ ev Event.Changed "a" ] (poll watcher);
  Unix.chmod (path root "a") 0o600;
  events [ ev Event.Changed "a" ] (poll watcher);
  Unix.unlink (path root "a");
  events [ ev Event.Deleted "a" ] (poll watcher)

let polling_same_size_rewrite_changes_file () =
  with_temp_dir @@ fun root ->
  write_file (path root "a") "one";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  write_file (path root "a") "two";
  events [ ev Event.Changed "a" ] (poll watcher)

let polling_nested_trees () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  mkdir_p (path root "dir/sub");
  write_file (path root "dir/sub/a") "a";
  events
    [
      ev Event.Created "dir";
      ev Event.Created "dir/sub";
      ev Event.Created "dir/sub/a";
    ]
    (poll watcher);
  rm_rf (path root "dir");
  events
    [
      ev Event.Deleted "dir";
      ev Event.Deleted "dir/sub";
      ev Event.Deleted "dir/sub/a";
    ]
    (poll watcher)

let polling_renames_are_delete_plus_create () =
  with_temp_dir @@ fun root ->
  write_file (path root "a") "a";
  mkdir_p (path root "dir");
  write_file (path root "dir/file") "file";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  rename (path root "a") (path root "b");
  events [ ev Event.Deleted "a"; ev Event.Created "b" ] (poll watcher);
  rename (path root "dir") (path root "renamed");
  events
    [
      ev Event.Deleted "dir";
      ev Event.Deleted "dir/file";
      ev Event.Created "renamed";
      ev Event.Created "renamed/file";
    ]
    (poll watcher)

let polling_symlinks_are_not_followed () =
  if Sys.win32 then skip ~reason:"symlink test is Unix-specific" ();
  with_temp_dir @@ fun root ->
  write_file (path root "target-a") "a";
  write_file (path root "target-b") "b";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  Unix.symlink "target-a" (path root "link");
  events [ ev Event.Created "link" ] (poll watcher);
  Unix.unlink (path root "link");
  Unix.symlink "target-b" (path root "link");
  events [ ev Event.Changed "link" ] (poll watcher);
  write_file (path root "target-b") "changed";
  touch_mtime (path root "target-b");
  events [ ev Event.Changed "target-b" ] (poll watcher);
  Unix.unlink (path root "link");
  events [ ev Event.Deleted "link" ] (poll watcher)

let polling_replacement_kinds_change_stable_path () =
  with_temp_dir @@ fun root ->
  write_file (path root "file-to-dir") "file";
  mkdir_p (path root "dir-to-file");
  write_file (path root "dir-to-file/child") "child";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  Unix.unlink (path root "file-to-dir");
  Unix.mkdir (path root "file-to-dir") 0o755;
  write_file (path root "file-to-dir/child") "child";
  events
    [ ev Event.Changed "file-to-dir"; ev Event.Created "file-to-dir/child" ]
    (poll watcher);
  rm_rf (path root "dir-to-file");
  write_file (path root "dir-to-file") "file";
  events
    [ ev Event.Changed "dir-to-file"; ev Event.Deleted "dir-to-file/child" ]
    (poll watcher)

let polling_symlink_replacements_change_stable_path () =
  if Sys.win32 then skip ~reason:"symlink test is Unix-specific" ();
  with_temp_dir @@ fun root ->
  write_file (path root "target") "target";
  write_file (path root "file-to-link") "file";
  Unix.symlink "target" (path root "link-to-file");
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  Unix.unlink (path root "file-to-link");
  Unix.symlink "target" (path root "file-to-link");
  events [ ev Event.Changed "file-to-link" ] (poll watcher);
  Unix.unlink (path root "link-to-file");
  write_file (path root "link-to-file") "file";
  events [ ev Event.Changed "link-to-file" ] (poll watcher)

let polling_respects_ignore_predicate () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let ignore path =
    match Path.Rel.to_string path with
    | "ignored" | "ignored-file" -> true
    | value -> String.starts_with ~prefix:"ignored/" value
  in
  let watcher = make ~backend:`Polling ~ignore ~sw ~clock root in
  write_file (path root "kept") "kept";
  write_file (path root "ignored-file") "ignored";
  mkdir_p (path root "ignored");
  write_file (path root "ignored/a") "ignored";
  events [ ev Event.Created "kept" ] (poll watcher);
  write_file (path root "ignored/a") "changed";
  touch_mtime (path root "ignored/a");
  events [] (poll watcher)

let polling_ignores_watched_root () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let ignore path = Path.Rel.equal path Path.Rel.root in
  let watcher = make ~backend:`Polling ~ignore ~sw ~clock root in
  write_file (path root "a") "a";
  events [] (poll watcher);
  write_file (path root "a") "changed";
  touch_mtime (path root "a");
  events [] (poll watcher)

let polling_does_not_emit_spurious_events () =
  with_temp_dir @@ fun root ->
  write_file (path root "a") "a";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  events [] (poll watcher);
  events [] (poll watcher);
  Unix.chmod root 0o700;
  events [ ev Event.Changed "." ] (poll watcher);
  events [] (poll watcher)

let polling_coalesces_by_snapshot_diff () =
  with_temp_dir @@ fun root ->
  write_file (path root "existing") "before";
  write_file (path root "replace") "old";
  write_file (path root "a") "a";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  write_file (path root "transient") "x";
  Unix.unlink (path root "transient");
  events [] (poll watcher);
  write_file (path root "created") "one";
  write_file (path root "created") "two";
  touch_mtime (path root "created");
  events [ ev Event.Created "created" ] (poll watcher);
  write_file (path root "existing") "changed";
  touch_mtime (path root "existing");
  Unix.unlink (path root "existing");
  events [ ev Event.Deleted "existing" ] (poll watcher);
  Unix.unlink (path root "replace");
  write_file (path root "replace") "new";
  touch_mtime (path root "replace");
  events [ ev Event.Changed "replace" ] (poll watcher);
  rename (path root "a") (path root "b");
  rename (path root "b") (path root "c");
  events [ ev Event.Deleted "a"; ev Event.Created "c" ] (poll watcher);
  mkdir_p (path root "dir");
  write_file (path root "dir/file") "file";
  rm_rf (path root "dir");
  events [] (poll watcher)

let reset_replaces_baseline () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  write_file (path root "a") "a";
  reset watcher;
  events [] (poll watcher);
  write_file (path root "a") "b";
  touch_mtime (path root "a");
  events [ ev Event.Changed "a" ] (poll watcher)

let polling_root_delete_recreate () =
  with_temp_dir @@ fun parent ->
  let root = path parent "root" in
  Unix.mkdir root 0o755;
  write_file (path root "a") "a";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  rm_rf root;
  events [ ev Event.Deleted "."; ev Event.Deleted "a" ] (poll watcher);
  Unix.mkdir root 0o755;
  write_file (path root "b") "b";
  events [ ev Event.Created "."; ev Event.Created "b" ] (poll watcher)

let polling_root_delete_is_not_reported_twice () =
  with_temp_dir @@ fun parent ->
  let root = path parent "root" in
  Unix.mkdir root 0o755;
  write_file (path root "a") "a";
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  rm_rf root;
  events [ ev Event.Deleted "."; ev Event.Deleted "a" ] (poll watcher);
  events [] (poll watcher)

let slow_large_tree_create_delete () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  let count = 250 in
  Unix.mkdir (path root "many") 0o755;
  for i = 1 to count do
    write_file (path root (Printf.sprintf "many/%03d.txt" i)) "x"
  done;
  let created =
    ev Event.Created "many"
    :: List.init count (fun i ->
        ev Event.Created (Printf.sprintf "many/%03d.txt" (i + 1)))
  in
  events created (poll watcher);
  rm_rf (path root "many");
  let deleted =
    ev Event.Deleted "many"
    :: List.init count (fun i ->
        ev Event.Deleted (Printf.sprintf "many/%03d.txt" (i + 1)))
  in
  events deleted (poll watcher)

let slow_large_tree_rename () =
  with_temp_dir @@ fun root ->
  Unix.mkdir (path root "old") 0o755;
  let count = 200 in
  for i = 1 to count do
    write_file (path root (Printf.sprintf "old/%03d.txt" i)) "x"
  done;
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  rename (path root "old") (path root "new");
  let expected =
    [ ev Event.Deleted "old"; ev Event.Created "new" ]
    @ List.init count (fun i ->
        ev Event.Deleted (Printf.sprintf "old/%03d.txt" (i + 1)))
    @ List.init count (fun i ->
        ev Event.Created (Printf.sprintf "new/%03d.txt" (i + 1)))
  in
  events expected (poll watcher)

let next_polling_observes_changes () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~poll_interval:0.01 ~sw ~clock root in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.05;
      write_file (path root "a") "a");
  match next_timeout ~clock watcher with
  | Some actual -> events [ ev Event.Created "a" ] actual
  | None -> failf "watcher closed unexpectedly"

let close_wakes_polling_next () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~poll_interval:10.0 ~sw ~clock root in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.05;
      Fswatch.close watcher);
  equal
    (option (list event))
    ~msg:"closed watcher returns None" None
    (next_timeout ~clock watcher)

let closed_watcher_operations_return_empty () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~sw ~clock root in
  Fswatch.close watcher;
  Fswatch.close watcher;
  write_file (path root "a") "a";
  events [] (poll watcher);
  reset watcher;
  equal
    (option (list event))
    ~msg:"closed watcher returns None" None
    (next_timeout ~clock watcher)

let iter_stops_on_close () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~poll_interval:0.01 ~sw ~clock root in
  let batches = ref 0 in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.05;
      write_file (path root "a") "a";
      Eio.Time.sleep clock 0.05;
      Fswatch.close watcher);
  expect_ok "iter"
    (Fswatch.iter watcher ~f:(fun actual ->
         incr batches;
         events [ ev Event.Created "a" ] actual));
  equal int ~msg:"one batch observed before close" 1 !batches

exception Iter_callback_failure

let iter_propagates_callback_exceptions () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Polling ~poll_interval:0.01 ~sw ~clock root in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.05;
      write_file (path root "a") "a");
  raises_match ~msg:"callback exception escapes"
    (function Iter_callback_failure -> true | _ -> false)
    (fun () ->
      ignore
        (Fswatch.iter watcher ~f:(fun actual ->
             events [ ev Event.Created "a" ] actual;
             raise Iter_callback_failure)))

let watch_delivers_batches_until_stopped () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let events = Eio.Stream.create max_int in
  let ready = Eio.Stream.create max_int in
  let stop =
    Fswatch.watch ~sw ~clock ~backend:`Polling ~poll_interval:0.01 ~root
      ~on_ready:(fun _ -> Eio.Stream.add ready ())
      ~on_error:fail_on_watch_error
      ~f:(fun batch -> List.iter (Eio.Stream.add events) batch)
      ()
  in
  ignore (stream_take ~clock ready);
  write_file (path root "a") "a";
  equal event ~msg:"watch delivers the create batch" (ev Event.Created "a")
    (stream_take ~clock events);
  stop ();
  write_file (path root "b") "b";
  Eio.Time.sleep clock 0.1;
  equal int ~msg:"no batches delivered after stop" 0 (Eio.Stream.length events)

let watch_stop_is_idempotent () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let events = Eio.Stream.create max_int in
  let stop =
    Fswatch.watch ~sw ~clock ~backend:`Polling ~poll_interval:0.01 ~root
      ~on_error:fail_on_watch_error
      ~f:(fun batch -> List.iter (Eio.Stream.add events) batch)
      ()
  in
  (* Stopping immediately also exercises the stop-before-construction race that
     the fork-before-make guard is there to close. *)
  stop ();
  stop ();
  write_file (path root "a") "a";
  Eio.Time.sleep clock 0.1;
  equal int ~msg:"repeated stop stays stopped and delivers nothing" 0
    (Eio.Stream.length events)

let watch_stop_during_callback () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let events = Eio.Stream.create max_int in
  let ready = Eio.Stream.create max_int in
  let stop_ref = ref (fun () -> ()) in
  let batches = ref 0 in
  let stop =
    Fswatch.watch ~sw ~clock ~backend:`Polling ~poll_interval:0.01 ~root
      ~on_ready:(fun _ -> Eio.Stream.add ready ())
      ~on_error:fail_on_watch_error
      ~f:(fun batch ->
        incr batches;
        List.iter (Eio.Stream.add events) batch;
        !stop_ref ())
      ()
  in
  stop_ref := stop;
  ignore (stream_take ~clock ready);
  write_file (path root "a") "a";
  equal event ~msg:"first batch is delivered" (ev Event.Created "a")
    (stream_take ~clock events);
  write_file (path root "b") "b";
  Eio.Time.sleep clock 0.1;
  equal int ~msg:"stopping inside the callback stops after that batch" 1
    !batches

let watch_reports_construction_failure () =
  with_eio @@ fun ~sw ~clock ->
  let errors = Eio.Stream.create max_int in
  let _stop =
    Fswatch.watch ~sw ~clock ~backend:`Polling ~root:"relative"
      ~on_error:(fun error -> Eio.Stream.add errors error)
      ~f:(fun _ -> ())
      ()
  in
  match stream_take ~clock errors with
  | Error.Invalid_root { root = "relative"; _ } -> ()
  | error -> failf "unexpected construction error: %a" Error.pp error

let watch_stops_when_switch_released () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw:_ ~clock ->
  let events = Eio.Stream.create max_int in
  let ready = Eio.Stream.create max_int in
  Eio.Switch.run (fun child ->
      let _stop =
        Fswatch.watch ~sw:child ~clock ~backend:`Polling ~poll_interval:0.01
          ~root
          ~on_ready:(fun _ -> Eio.Stream.add ready ())
          ~on_error:fail_on_watch_error
          ~f:(fun batch -> List.iter (Eio.Stream.add events) batch)
          ()
      in
      ignore (stream_take ~clock ready);
      write_file (path root "a") "a";
      ignore (stream_take ~clock events));
  write_file (path root "b") "b";
  Eio.Time.sleep clock 0.1;
  equal int ~msg:"no batches after the switch is released" 0
    (Eio.Stream.length events)

let best_backend_constructs () =
  with_temp_dir @@ fun root ->
  with_eio @@ fun ~sw ~clock ->
  let watcher = make ~backend:`Best ~sw ~clock root in
  match Fswatch.backend watcher with `Native | `Polling -> ()

let with_native_watcher ?(poll_interval = 0.01) root f =
  with_eio @@ fun ~sw ~clock ->
  match Fswatch.make ~sw ~clock ~backend:`Native ~poll_interval ~root () with
  | Ok watcher -> f ~sw ~clock watcher
  | Error (Error.Backend_unavailable _) ->
      skip ~reason:"native backend unavailable" ()
  | Error error -> failf "native watcher failed: %a" Error.pp error

let native_idle_close_joins_reader () =
  with_temp_dir @@ fun root ->
  with_native_watcher root @@ fun ~sw ~clock watcher ->
  (* On Linux, leaving [with_eio] joins the inotify reader as well as returning
     [None] from [next]. The timeout therefore covers the idle blocked-reader
     teardown contract, not only the public stream wakeup. *)
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Time.sleep clock 0.05;
      Fswatch.close watcher);
  equal
    (option (list event))
    ~msg:"closed native watcher returns None" None
    (next_timeout ~clock watcher)

let native_wakeup_observes_create () =
  with_temp_dir @@ fun root ->
  with_native_watcher ~poll_interval:5.0 root @@ fun ~sw:_ ~clock watcher ->
  write_file (path root "a") "a";
  match next_timeout ~clock ~timeout:1.0 watcher with
  | Some actual -> events [ ev Event.Created "a" ] actual
  | None -> failf "native watcher closed unexpectedly"

let native_wakeup_observes_nested_create () =
  with_temp_dir @@ fun root ->
  with_native_watcher ~poll_interval:5.0 root @@ fun ~sw:_ ~clock watcher ->
  Unix.mkdir (path root "dir") 0o755;
  write_file (path root "dir/file") "file";
  match next_timeout ~clock ~timeout:1.0 watcher with
  | Some actual ->
      events [ ev Event.Created "dir"; ev Event.Created "dir/file" ] actual
  | None -> failf "native watcher closed unexpectedly"

let () =
  run "spice.fswatch"
    [
      group "values" [ test "event fields and ordering" event_values ];
      group "construction"
        [
          test "rejects invalid roots" construction_rejects_invalid_roots;
          test "rejects invalid timing values"
            construction_rejects_invalid_timing_values;
          test "watch rejects invalid timing values"
            watch_rejects_invalid_timing_values;
        ];
      group "polling"
        [
          test "initial snapshot is baseline"
            polling_initial_snapshot_is_baseline;
          test "create modify delete" polling_create_modify_delete;
          test "same-size rewrite changes file"
            polling_same_size_rewrite_changes_file;
          test "nested trees" polling_nested_trees;
          test "renames are delete plus create"
            polling_renames_are_delete_plus_create;
          test "symlinks are not followed" polling_symlinks_are_not_followed;
          test "replacement kinds change stable path"
            polling_replacement_kinds_change_stable_path;
          test "symlink replacements change stable path"
            polling_symlink_replacements_change_stable_path;
          test "respects ignore predicate" polling_respects_ignore_predicate;
          test "ignores watched root" polling_ignores_watched_root;
          test "does not emit spurious events"
            polling_does_not_emit_spurious_events;
          test "coalesces by snapshot diff" polling_coalesces_by_snapshot_diff;
          test "reset replaces baseline" reset_replaces_baseline;
          test "root delete recreate" polling_root_delete_recreate;
          test "root delete is not reported twice"
            polling_root_delete_is_not_reported_twice;
        ];
      group "next and iter"
        [
          test ~timeout:3.0 "polling next observes changes"
            next_polling_observes_changes;
          test ~timeout:3.0 "close wakes polling next" close_wakes_polling_next;
          test ~timeout:3.0 "closed watcher operations return empty"
            closed_watcher_operations_return_empty;
          test ~timeout:3.0 "iter stops on close" iter_stops_on_close;
          test ~timeout:3.0 "iter propagates callback exceptions"
            iter_propagates_callback_exceptions;
        ];
      group "watch"
        [
          test ~timeout:3.0 "delivers batches until stopped"
            watch_delivers_batches_until_stopped;
          test ~timeout:3.0 "stop is idempotent" watch_stop_is_idempotent;
          test ~timeout:3.0 "stop during callback" watch_stop_during_callback;
          test ~timeout:3.0 "reports construction failure to on_error"
            watch_reports_construction_failure;
          test ~timeout:3.0 "stops when the switch is released"
            watch_stops_when_switch_released;
        ];
      group "native"
        [
          test "best backend constructs" best_backend_constructs;
          test ~timeout:4.0 "native idle close joins reader"
            native_idle_close_joins_reader;
          test ~timeout:2.0 "native wakeup observes create"
            native_wakeup_observes_create;
          test ~timeout:2.0 "native wakeup observes nested create"
            native_wakeup_observes_nested_create;
        ];
      group "slow"
        [
          slow "large tree create delete" slow_large_tree_create_delete;
          slow "large tree rename" slow_large_tree_rename;
        ];
    ]
