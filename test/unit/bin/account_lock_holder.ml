(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let rec lockf fd command =
  match Unix.lockf fd command 0 with
  | () -> ()
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> lockf fd command

let touch path =
  let channel = open_out_bin path in
  close_out channel

let rec await_release path =
  if Sys.file_exists path then ()
  else (
    Unix.sleepf 0.01;
    await_release path)

let () =
  match Array.to_list Sys.argv with
  | [ _; lock_path; ready_path; release_path ] ->
      let fd =
        Unix.openfile lock_path
          [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
          0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close fd)
        (fun () ->
          lockf fd Unix.F_LOCK;
          Fun.protect
            ~finally:(fun () -> lockf fd Unix.F_ULOCK)
            (fun () ->
              touch ready_path;
              await_release release_path))
  | _ ->
      prerr_endline
        "usage: account_lock_holder LOCK_PATH READY_PATH RELEASE_PATH";
      exit 2
