(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Spice_llm
module Session = Spice_session
module Store = Spice_session_store

type measurement = {
  wall_seconds : float;
  cpu_seconds : float;
  minor_words : float;
  promoted_words : float;
  major_words : float;
}

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

let with_temp_dir name f =
  let path = Filename.temp_file ("spice-bench-" ^ name) ".tmp" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)

let ok_or_fail = function
  | Ok value -> value
  | Error error -> failwith (Store.Error.message error)

let model =
  Llm.Model.make
    ~provider:(Llm.Provider.make "openai")
    ~api:(Llm.Model.Api.make "responses")
    ~id:"gpt-5"

let cwd = Spice_path.Abs.of_string_exn "/workspace"

let make_session id =
  Session.create ~id:(Session.Id.of_string id) ~cwd
    ~created_at:(Session.Time.of_unix_ms 1L)
    ()

let events index =
  let id = Session.Turn.Id.of_string (Printf.sprintf "turn-%06d" index) in
  let turn =
    Session.Turn.make ~id
      ~input:(Session.Turn.Input.user_text "Continue.")
      ~model ~declarations:[] ~host_tools:[] ~max_steps:max_int ()
  in
  [
    Session.Event.turn_started turn;
    Session.Event.turn_finished ~turn:id Session.Turn.Outcome.completed;
  ]

let measure name ~iters f =
  ignore (Sys.opaque_identity (f 0));
  Gc.compact ();
  let gc_before = Gc.quick_stat () in
  let cpu_before = Sys.time () in
  let wall_before = Unix.gettimeofday () in
  for index = 1 to iters do
    ignore (Sys.opaque_identity (f index))
  done;
  let wall_after = Unix.gettimeofday () in
  let cpu_after = Sys.time () in
  let gc_after = Gc.quick_stat () in
  let result =
    {
      wall_seconds = wall_after -. wall_before;
      cpu_seconds = cpu_after -. cpu_before;
      minor_words = gc_after.Gc.minor_words -. gc_before.Gc.minor_words;
      promoted_words = gc_after.Gc.promoted_words -. gc_before.Gc.promoted_words;
      major_words = gc_after.Gc.major_words -. gc_before.Gc.major_words;
    }
  in
  let per_op value = value /. Float.of_int iters in
  Printf.printf
    "%-24s %5d ops wall %9.1fus cpu %9.1fus minor %10.1fw promoted %9.1fw major %10.1fw\n%!"
    name iters
    (per_op result.wall_seconds *. 1_000_000.)
    (per_op result.cpu_seconds *. 1_000_000.)
    (per_op result.minor_words)
    (per_op result.promoted_words)
    (per_op result.major_words)

let retained name ~iters f =
  ignore (Sys.opaque_identity (f 0));
  Gc.compact ();
  let before = (Gc.stat ()).Gc.live_words in
  for index = 1 to iters do
    ignore (Sys.opaque_identity (f index))
  done;
  Gc.compact ();
  let after = (Gc.stat ()).Gc.live_words in
  Printf.printf "%-24s retained %+d words\n%!" name (after - before)

let () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let clock = Eio.Stdenv.clock env in
  with_temp_dir "session-store" @@ fun root_native ->
  let root = Spice_path.Abs.of_string_exn root_native in
  let store = Store.make ~fs ~clock ~root in
  let document = ref (ok_or_fail (Store.create store (make_session "single"))) in
  measure "durable append" ~iters:24 (fun index ->
      let next = ok_or_fail (Store.append store !document (events index)) in
      document := next);
  let id = Session.Id.of_string "single" in
  measure "load" ~iters:500 (fun _ -> Store.load store id);
  let saved = ref (ok_or_fail (Store.create store (make_session "saved"))) in
  let save_with store index =
    let session =
      Session.set_title
        (Some (Printf.sprintf "title-%06d" index))
        (Store.Document.session !saved)
    in
    saved := ok_or_fail (Store.save store !saved session)
  in
  measure "durable save" ~iters:200 (save_with store);
  measure "new-handle save" ~iters:200 (fun index ->
      save_with (Store.make ~fs ~clock ~root) index);
  let left = ref (ok_or_fail (Store.create store (make_session "left"))) in
  let right = ref (ok_or_fail (Store.create store (make_session "right"))) in
  measure "two-session append" ~iters:12 (fun index ->
      Eio.Fiber.both
        (fun () ->
          left :=
            ok_or_fail (Store.append store !left (events (index * 2 + 10_000))))
        (fun () ->
          right :=
            ok_or_fail
              (Store.append store !right (events (index * 2 + 10_001)))));
  let create_cold_root index =
    with_temp_dir "session-store-retained" @@ fun retained_root ->
    let root = Spice_path.Abs.of_string_exn retained_root in
    let store = Store.make ~fs ~clock ~root in
    ignore
      (ok_or_fail
         (Store.create store
            (make_session (Printf.sprintf "retained-%06d" index))))
  in
  measure "cold-root create" ~iters:100 create_cold_root;
  retained "ephemeral sessions" ~iters:1_000 create_cold_root
