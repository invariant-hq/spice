(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let fail message =
  prerr_endline ("spice_trust_probe: " ^ message);
  exit 2

let abs path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error -> fail (Spice_path.Error.message error)

let status = function
  | Ok trust ->
      Spice_host.Trust.status trust |> Spice_host.Trust.status_to_string
  | Error error -> fail (Spice_host.Trust.Error.message error)

let concurrent first second =
  Eio_main.run @@ fun stdenv ->
  let first_status = ref None in
  let second_status = ref None in
  Eio.Fiber.both
    (fun () ->
      first_status :=
        Some
          (Spice_host.Trust.trust ~stdenv ~root:(abs first) () |> status))
    (fun () ->
      second_status :=
        Some
          (Spice_host.Trust.untrust ~stdenv ~root:(abs second) () |> status));
  match (!first_status, !second_status) with
  | Some first, Some second ->
      Printf.printf "first=%s second=%s\n" first second
  | None, _ | _, None -> fail "concurrent writer did not settle"

let hold lock_path ready_path =
  let fd =
    Unix.openfile lock_path
      [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
      0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      let ready = open_out_bin ready_path in
      output_string ready "ready\n";
      close_out ready;
      Unix.sleep 30)

let cancel root =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let context, context_resolver = Eio.Promise.create () in
  let result =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun context ->
        Eio.Promise.resolve context_resolver context;
        Spice_host.Trust.trust ~stdenv ~root:(abs root) ())
  in
  let cancel_context = Eio.Promise.await context in
  Eio.Time.sleep (Eio.Stdenv.clock stdenv) 0.05;
  Eio.Cancel.cancel cancel_context (Failure "test cancellation");
  match Eio.Promise.await_exn result with
  | exception Eio.Cancel.Cancelled _ -> print_endline "cancelled"
  | Ok _ -> fail "lock waiter completed before cancellation"
  | Error error ->
      fail
        ("cancellation became a trust error: "
        ^ Spice_host.Trust.Error.message error)

let () =
  match Array.to_list Sys.argv with
  | [ _; "concurrent"; first; second ] -> concurrent first second
  | [ _; "hold"; lock_path; ready_path ] -> hold lock_path ready_path
  | [ _; "cancel"; root ] -> cancel root
  | _ -> fail "expected concurrent ROOT ROOT, hold LOCK READY, or cancel ROOT"
