(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Spice_llm

let ( let* ) = Result.bind
let log_src = Logs.Src.create "spice.llm.artifact"

module Log = (val Logs.src_log log_src : Logs.LOG)

type phase = Checking | Downloading | Verifying | Installed

let error ?status ~provider kind message =
  Llm.Error.make ~kind ~phase:Llm.Error.Startup ~provider ?status message

let cancelled_error provider =
  error ~provider Llm.Error.Cancelled "model artifact download cancelled"

let transport_error ?status ~provider ~action ~path message =
  error ?status ~provider Llm.Error.Transport
    (Printf.sprintf "%s %s: %s" action path message)

let integrity_error ~provider ~path message =
  error ~provider (Llm.Error.Other "artifact_install")
    (Printf.sprintf "verify %s: %s" path message)

let exception_message = function
  | Unix.Unix_error (code, _, _) -> Unix.error_message code
  | Sys_error message -> message
  | exn -> Printexc.to_string exn

let io ~provider ~action ~path f =
  match f () with
  | value -> Ok value
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Eio.Io _ | Unix.Unix_error _ | Sys_error _) as exn) ->
      Error (transport_error ~provider ~action ~path (exception_message exn))

let network ~provider ~action ~path f =
  match f () with
  | value -> Ok value
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  (* Cohttp-eio uses [Failure] for peer EOF and malformed response syntax. *)
  | exception ((Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Failure _) as exn)
    ->
      Error (transport_error ~provider ~action ~path (Printexc.to_string exn))

let status_code response =
  Cohttp.Code.code_of_status (Cohttp.Response.status response)

let header response name =
  Cohttp.Header.get (Cohttp.Response.headers response) name

let rec download_response ~sw ~http ~provider ~path ~remaining uri =
  let* response, body =
    network ~provider ~action:"download" ~path (fun () ->
        Cohttp_eio.Client.call http ~sw `GET uri)
  in
  let status = status_code response in
  if status >= 300 && status < 400 then
    match header response "location" with
    | Some location when remaining > 0 ->
        download_response ~sw ~http ~provider ~path ~remaining:(remaining - 1)
          (Uri.of_string location)
    | Some _ ->
        Error
          (transport_error ~status ~provider ~action:"download" ~path
             "too many redirects")
    | None ->
        Error
          (transport_error ~status ~provider ~action:"download" ~path
             "redirect did not include Location")
  else if status >= 200 && status < 300 then Ok (response, body)
  else
    Error
      (transport_error ~status ~provider ~action:"download" ~path
         (Printf.sprintf "HTTP %d" status))

let candidate_prefix path = "." ^ Filename.basename path ^ "."

let open_candidate ~provider path =
  let dir = Filename.dirname path in
  io ~provider ~action:"create candidate for" ~path (fun () ->
      Filename.open_temp_file ~mode:[ Open_binary ] ~perms:0o600 ~temp_dir:dir
        (candidate_prefix path) ".part")

let cleanup_candidate path =
  match Unix.unlink path with
  | () -> ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | exception exn ->
      Log.warn (fun m ->
          m "failed to remove artifact candidate path=%s error=%s" path
            (Printexc.to_string exn))

let close_for_cleanup path output =
  match close_out output with
  | () -> ()
  | exception exn ->
      Log.warn (fun m ->
          m "failed to close artifact candidate path=%s error=%s" path
            (Printexc.to_string exn))

let verify_size ~provider path expected =
  let* stat =
    io ~provider ~action:"stat candidate" ~path (fun () -> Unix.stat path)
  in
  let actual = Int64.of_int stat.Unix.st_size in
  if Int64.equal actual expected then Ok ()
  else
    Error
      (integrity_error ~provider ~path
         (Printf.sprintf "expected %Ld bytes, got %Ld bytes" expected actual))

let read_chunk ~provider ~path body chunk =
  match Eio.Flow.single_read body chunk with
  | count -> Ok (Some count)
  | exception End_of_file -> Ok None
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Failure _) as exn)
    ->
      Error
        (transport_error ~provider ~action:"read response for" ~path
           (Printexc.to_string exn))

let write_body ~provider ~cancelled ~observe ~path ~total body output =
  let chunk = Cstruct.create 1_048_576 in
  let last_emit = ref 0L in
  let rec loop received digest =
    if cancelled () then Error (cancelled_error provider)
    else
      let* read = read_chunk ~provider ~path body chunk in
      match read with
      | None -> Ok (received, Digestif.SHA256.(to_hex (get digest)))
      | Some count ->
          let data = Cstruct.to_string (Cstruct.sub chunk 0 count) in
          let* () =
            io ~provider ~action:"write candidate for" ~path (fun () ->
                output_string output data)
          in
          let received = Int64.add received (Int64.of_int count) in
          let digest = Digestif.SHA256.feed_string digest data in
          if
            Int64.sub received !last_emit >= 64_000_000L
            || Option.exists (Int64.equal received) total
          then begin
            last_emit := received;
            observe Downloading ~received ~total
          end;
          loop received digest
  in
  loop 0L Digestif.SHA256.empty

let install ~env ~http ~provider ~cancelled ~observe ~url ~path ~size ~sha256 =
  Eio.Switch.run ~name:"artifact.install" @@ fun sw ->
  if cancelled () then Error (cancelled_error provider)
  else
    let dir = Filename.dirname path in
    let dir_path = Eio.Path.( / ) (Eio.Stdenv.fs env) dir in
    let* () =
      io ~provider ~action:"create model directory" ~path:dir (fun () ->
          Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 dir_path)
    in
    observe Checking ~received:0L ~total:(Some size);
    let* response, body =
      download_response ~sw ~http ~provider ~path ~remaining:8
        (Uri.of_string url)
    in
    let total =
      Option.bind (header response "content-length") Int64.of_string_opt
    in
    observe Downloading ~received:0L ~total;
    let* candidate, output = open_candidate ~provider path in
    let closed = ref false in
    Fun.protect
      ~finally:(fun () ->
        if not !closed then close_for_cleanup candidate output;
        cleanup_candidate candidate)
      (fun () ->
        let* received, digest =
          write_body ~provider ~cancelled ~observe ~path ~total body output
        in
        let* () =
          io ~provider ~action:"close candidate for" ~path (fun () ->
              close_out output)
        in
        closed := true;
        observe Verifying ~received ~total:(Some size);
        let* () = verify_size ~provider candidate size in
        let* () =
          if String.equal digest sha256 then Ok ()
          else
            Error
              (integrity_error ~provider ~path:candidate
                 (Printf.sprintf "expected SHA-256 %s, got %s" sha256 digest))
        in
        let* () =
          io ~provider ~action:"publish artifact" ~path (fun () ->
              Unix.rename candidate path)
        in
        observe Installed ~received:size ~total:(Some size);
        Ok ())
