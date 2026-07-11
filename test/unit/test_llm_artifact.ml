(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Artifact = Spice_llm_artifact
module Llm = Spice_llm

let provider = Llm.Provider.make "artifact-test"
let sha256 text = Digestif.SHA256.(to_hex (get (feed_string empty text)))

let with_temp_dir f =
  let dir = Filename.temp_file "spice-artifact-test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name ->
          let path = Filename.concat dir name in
          match Unix.unlink path with
          | () -> ()
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () -> f dir)

let rec write_all fd bytes offset length =
  if length > 0 then
    match Unix.write fd bytes offset length with
    | count -> write_all fd bytes (offset + count) (length - count)
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
        write_all fd bytes offset length

let write_byte fd = write_all fd (Bytes.make 1 '\x00') 0 1

let read_byte fd =
  let byte = Bytes.create 1 in
  let rec read () =
    match Unix.read fd byte 0 1 with
    | 1 -> ()
    | 0 -> failwith "barrier closed"
    | _ -> assert false
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
  in
  read ()

let read_request fd =
  let byte = Bytes.create 1 in
  let rec loop matched =
    let count = Unix.read fd byte 0 1 in
    if count = 0 then failwith "request ended before its headers"
    else
      let char = Bytes.get byte 0 in
      let matched =
        match (matched, char) with
        | 0, '\r' -> 1
        | 1, '\n' -> 2
        | 2, '\r' -> 3
        | 3, '\n' -> 4
        | _, '\r' -> 1
        | _ -> 0
      in
      if matched < 4 then loop matched
  in
  loop 0

let rec accept socket =
  match Unix.accept socket with
  | client, address ->
      ignore address;
      client
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> accept socket

let serve socket ~requests body =
  let response =
    Printf.sprintf
      "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      (String.length body) body
    |> Bytes.of_string
  in
  for _request = 1 to requests do
    let client = accept socket in
    Fun.protect
      ~finally:(fun () -> Unix.close client)
      (fun () ->
        read_request client;
        write_all client response 0 (Bytes.length response))
  done

let start_server ~requests body =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt socket Unix.SO_REUSEADDR true;
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen socket requests;
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (address, port) ->
        ignore address;
        port
    | Unix.ADDR_UNIX path -> failwith ("unexpected Unix socket " ^ path)
  in
  match Unix.fork () with
  | 0 -> (
      match serve socket ~requests body with
      | () ->
          Unix.close socket;
          exit 0
      | exception exn ->
          prerr_endline (Printexc.to_string exn);
          exit 2)
  | pid ->
      Unix.close socket;
      (pid, Printf.sprintf "http://127.0.0.1:%d/artifact" port)

let rec waitpid pid =
  match Unix.waitpid [] pid with
  | _, status -> status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> waitpid pid

let expect_exit_zero label pid =
  match waitpid pid with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> failf "%s exited %d" label code
  | Unix.WSIGNALED signal -> failf "%s was signalled %d" label signal
  | Unix.WSTOPPED signal -> failf "%s stopped on signal %d" label signal

let terminate pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> (
      match Unix.kill pid Sys.sigterm with
      | () -> ignore (waitpid pid : Unix.process_status)
      | exception Unix.Unix_error (Unix.ESRCH, _, _) -> ())
  | _ -> ()
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()

type barrier_phase = Downloading | Verifying
type expected = Success | Cancelled
type child = { pid : int; ready : Unix.file_descr; release : Unix.file_descr }

let spawn_install ~url ~path ~body ~cancel_path ~barrier_phase ~expected =
  let ready_read, ready_write = Unix.pipe () in
  let release_read, release_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close ready_read;
      Unix.close release_write;
      let barrier_crossed = ref false in
      let observe phase ~received ~total =
        ignore total;
        let reached =
          match (barrier_phase, phase) with
          | Downloading, Artifact.Downloading -> Int64.compare received 0L > 0
          | Verifying, Artifact.Verifying -> true
          | ( (Downloading | Verifying),
              ( Artifact.Checking | Artifact.Downloading | Artifact.Verifying
              | Artifact.Installed ) ) ->
              false
        in
        if reached && not !barrier_crossed then begin
          barrier_crossed := true;
          write_byte ready_write;
          read_byte release_read
        end
      in
      let result =
        Eio_main.run @@ fun env ->
        let http = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
        Artifact.install ~env ~http ~provider
          ~cancelled:(fun () -> Sys.file_exists cancel_path)
          ~observe ~url ~path
          ~size:(Int64.of_int (String.length body))
          ~sha256:(sha256 body)
      in
      Unix.close ready_write;
      Unix.close release_read;
      begin match (expected, result) with
      | Success, Ok () -> exit 0
      | Cancelled, Error error when Llm.Error.kind error = Llm.Error.Cancelled
        ->
          exit 0
      | (Success | Cancelled), Error error ->
          Format.eprintf "%a@." Llm.Error.pp error;
          exit 3
      | Cancelled, Ok () -> exit 4
      end
  | pid ->
      Unix.close ready_write;
      Unix.close release_read;
      { pid; ready = ready_read; release = release_write }

let release child =
  write_byte child.release;
  Unix.close child.release;
  Unix.close child.ready

let candidate_names dir target =
  let prefix = "." ^ Filename.basename target ^ "." in
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun name ->
      String.starts_with ~prefix name && String.ends_with ~suffix:".part" name)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let concurrent_publishers_use_private_candidates () =
  with_temp_dir @@ fun dir ->
  let body = String.init 65_537 (fun i -> Char.chr (i mod 251)) in
  let path = Filename.concat dir "model.gguf" in
  let cancel_path = Filename.concat dir "cancel" in
  let server, url = start_server ~requests:2 body in
  let first =
    spawn_install ~url ~path ~body ~cancel_path ~barrier_phase:Verifying
      ~expected:Success
  in
  let second =
    spawn_install ~url ~path ~body ~cancel_path ~barrier_phase:Verifying
      ~expected:Success
  in
  Fun.protect
    ~finally:(fun () ->
      terminate first.pid;
      terminate second.pid;
      terminate server)
    (fun () ->
      read_byte first.ready;
      read_byte second.ready;
      is_false ~msg:"final path stays absent before verification"
        (Sys.file_exists path);
      let candidates = candidate_names dir path in
      equal int ~msg:"one candidate per process" 2 (List.length candidates);
      List.iter
        (fun name ->
          let stat = Unix.stat (Filename.concat dir name) in
          equal int ~msg:"candidate permission" 0o600
            (stat.Unix.st_perm land 0o777))
        candidates;
      release first;
      release second;
      expect_exit_zero "first installer" first.pid;
      expect_exit_zero "second installer" second.pid;
      expect_exit_zero "artifact server" server;
      equal string ~msg:"published artifact" body (read_file path);
      equal int ~msg:"published artifact permission" 0o600
        ((Unix.stat path).Unix.st_perm land 0o777);
      equal (list string) ~msg:"candidates removed" []
        (candidate_names dir path))

let cancellation_removes_owned_candidate () =
  with_temp_dir @@ fun dir ->
  let body = String.init 32_769 (fun i -> Char.chr (i mod 239)) in
  let path = Filename.concat dir "cancelled.gguf" in
  let cancel_path = Filename.concat dir "cancel" in
  let server, url = start_server ~requests:1 body in
  let child =
    spawn_install ~url ~path ~body ~cancel_path ~barrier_phase:Downloading
      ~expected:Cancelled
  in
  Fun.protect
    ~finally:(fun () ->
      terminate child.pid;
      terminate server)
    (fun () ->
      read_byte child.ready;
      equal int ~msg:"candidate exists during transfer" 1
        (List.length (candidate_names dir path));
      Out_channel.with_open_bin cancel_path (fun output ->
          Out_channel.output_string output "cancel");
      release child;
      expect_exit_zero "cancelled installer" child.pid;
      expect_exit_zero "artifact server" server;
      is_false ~msg:"cancelled install did not publish" (Sys.file_exists path);
      equal (list string) ~msg:"cancelled candidate removed" []
        (candidate_names dir path))

let integrity_failure_is_structured_and_cleans_up () =
  with_temp_dir @@ fun dir ->
  let body = "verified bytes" in
  let path = Filename.concat dir "invalid.gguf" in
  let server, url = start_server ~requests:1 body in
  Fun.protect
    ~finally:(fun () -> terminate server)
    (fun () ->
      let result =
        Eio_main.run @@ fun env ->
        let http = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
        Artifact.install ~env ~http ~provider
          ~cancelled:(fun () -> false)
          ~observe:(fun phase ~received ~total ->
            ignore phase;
            ignore received;
            ignore total)
          ~url ~path
          ~size:(Int64.of_int (String.length body))
          ~sha256:(String.make 64 '0')
      in
      begin match result with
      | Ok () -> failf "expected digest verification to fail"
      | Error error -> (
          match Llm.Error.kind error with
          | Llm.Error.Other label ->
              equal string ~msg:"integrity error kind" "artifact_install" label
          | kind ->
              failf "expected artifact_install, got %s" (Llm.Error.label kind))
      end;
      expect_exit_zero "artifact server" server;
      is_false ~msg:"invalid artifact was not published" (Sys.file_exists path);
      equal (list string) ~msg:"invalid candidate removed" []
        (candidate_names dir path))

let () =
  run "spice.llm.artifact"
    [
      test "concurrent publishers use private candidates"
        concurrent_publishers_use_private_candidates;
      test "cancellation removes the owned candidate"
        cancellation_removes_owned_candidate;
      test "integrity failure is structured and cleans up"
        integrity_failure_is_structured_and_cleans_up;
    ]
