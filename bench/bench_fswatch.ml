(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Fswatch = Spice_fswatch

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

let write_empty path =
  let fd = Unix.openfile path [ Unix.O_CREAT; Unix.O_WRONLY ] 0o644 in
  Unix.close fd

let make_shallow root =
  for i = 1 to 128 do
    write_empty (Filename.concat root (Printf.sprintf "file-%04d" i))
  done

let make_deep root =
  let rec loop parent depth =
    if depth > 0 then begin
      for i = 1 to 4 do
        write_empty (Filename.concat parent (Printf.sprintf "file-%02d" i))
      done;
      let child = Filename.concat parent "nested" in
      Unix.mkdir child 0o755;
      loop child (depth - 1)
    end
  in
  loop root 32

let make_large root =
  for dir = 1 to 128 do
    let directory = Filename.concat root (Printf.sprintf "dir-%04d" dir) in
    Unix.mkdir directory 0o755;
    for file = 1 to 64 do
      write_empty
        (Filename.concat directory (Printf.sprintf "file-%04d" file))
    done
  done

let make_watcher ~sw ~clock root =
  match Fswatch.make ~sw ~clock ~backend:`Polling ~root () with
  | Ok watcher -> watcher
  | Error error -> failwith (Fswatch.Error.message error)

let poll watcher =
  match Fswatch.poll watcher with
  | Ok events -> events
  | Error error -> failwith (Fswatch.Error.message error)

let measure name ~iters f =
  ignore (Sys.opaque_identity (f 0));
  Gc.compact ();
  let gc_before = Gc.quick_stat () in
  let cpu_before = Sys.time () in
  let wall_before = Unix.gettimeofday () in
  for i = 1 to iters do
    ignore (Sys.opaque_identity (f i))
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
  for i = 1 to iters do
    ignore (Sys.opaque_identity (f i))
  done;
  Gc.compact ();
  let after = (Gc.stat ()).Gc.live_words in
  Printf.printf "%-24s retained %+d words\n%!" name (after - before)

let construction ~clock name root iters =
  let construct _ =
    Eio.Switch.run @@ fun sw ->
    let watcher = make_watcher ~sw ~clock root in
    Fswatch.close watcher
  in
  measure ("construct " ^ name) ~iters construct;
  retained ("closed " ^ name) ~iters construct

let unchanged ~sw ~clock name root iters =
  let watcher = make_watcher ~sw ~clock root in
  measure ("unchanged " ^ name) ~iters (fun _ -> List.length (poll watcher));
  Fswatch.close watcher

let changed ~sw ~clock root files iters =
  let watcher = make_watcher ~sw ~clock root in
  measure "changed large/128" ~iters (fun iteration ->
      let timestamp = Float.of_int (1_700_000_000 + iteration) in
      Array.iter (fun file -> Unix.utimes file timestamp timestamp) files;
      List.length (poll watcher));
  Fswatch.close watcher

let () =
  with_temp_dir "shallow" @@ fun shallow ->
  with_temp_dir "deep" @@ fun deep ->
  with_temp_dir "large" @@ fun large ->
  make_shallow shallow;
  make_deep deep;
  make_large large;
  let changed_files =
    Array.init 128 (fun i ->
        let index = i + 1 in
        Filename.concat large
          (Printf.sprintf "dir-%04d/file-%04d" index 1))
  in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  construction ~clock "shallow" shallow 30;
  construction ~clock "deep" deep 20;
  construction ~clock "large" large 5;
  Eio.Switch.run @@ fun sw ->
  unchanged ~sw ~clock "shallow" shallow 100;
  unchanged ~sw ~clock "deep" deep 50;
  unchanged ~sw ~clock "large" large 10;
  changed ~sw ~clock large changed_files 10
