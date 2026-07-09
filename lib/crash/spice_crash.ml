(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The exit status for an uncaught fault: Cmdliner's [Cmd.Exit.cli_error] and
   the "unexpected internal error" status spice documents, kept as a literal so
   this module carries no cmdliner dependency. *)
let exit_internal_error = 125

type target = { report_dir : string; context : string }

let target : target option ref = ref None
let installed = ref false

let timestamp () =
  let now = Unix.gettimeofday () in
  let tm = Unix.localtime now in
  let ms = int_of_float (Float.rem now 1. *. 1000.) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec ms

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let record ~fault ~detail =
  match !target with
  | None -> None
  | Some { report_dir; context } -> (
      let pid = Unix.getpid () in
      let path =
        Filename.concat report_dir
          (Printf.sprintf "crash-%d-%.0f.log" pid (Unix.gettimeofday ()))
      in
      try
        mkdir_p report_dir;
        let oc = open_out_gen [ Open_append; Open_creat ] 0o600 path in
        Fun.protect
          ~finally:(fun () -> close_out_noerr oc)
          (fun () ->
            Printf.fprintf oc
              "spice crash report\n%s\ntime: %s\npid: %d\nfault: %s\n\n%s\n"
              context (timestamp ()) pid fault detail);
        Some path
      with _ -> None)

(* Printed to [stderr], so only sound once the terminal is no longer UI-owned.
   The report file carries the detail; [stderr] gets a one-line summary and the
   path, falling back to the detail inline when no file could be written. *)
let print_breadcrumb ~fault ~detail ~report_path =
  Printf.eprintf "spice crashed: %s\n" fault;
  (match report_path with
  | Some path -> Printf.eprintf "crash report written to %s\n" path
  | None -> if detail <> "" then Printf.eprintf "%s\n" detail);
  flush stderr

let uncaught_handler exn raw_backtrace =
  let fault = Printexc.to_string exn in
  let detail = Printexc.raw_backtrace_to_string raw_backtrace in
  (* By the time an exception reaches the top level the frontend's Eio switch
     has already left the alternate screen, so the breadcrumb lands on the
     restored terminal rather than the discarded alt screen. *)
  let report_path = record ~fault ~detail in
  print_breadcrumb ~fault ~detail ~report_path;
  exit exit_internal_error

let install ~report_dir ~context =
  if not !installed then begin
    installed := true;
    target := Some { report_dir; context };
    Printexc.record_backtrace true;
    Printexc.set_uncaught_exception_handler uncaught_handler
  end

let signal_name signum =
  if signum = Sys.sigint then "SIGINT"
  else if signum = Sys.sigterm then "SIGTERM"
  else if signum = Sys.sigquit then "SIGQUIT"
  else if signum = Sys.sighup then "SIGHUP"
  else if signum = Sys.sigabrt then "SIGABRT"
  else Printf.sprintf "signal %d" signum

let install_signal_breadcrumbs ~on_restore =
  match !target with
  | None -> ()
  | Some _ ->
      let handle signum =
        (try on_restore () with _ -> ());
        let fault = signal_name signum in
        (* The signal interrupted execution rather than an exception unwinding,
           so the current call stack — not a backtrace — is the best trace. *)
        let detail =
          try Printexc.raw_backtrace_to_string (Printexc.get_callstack 64)
          with _ -> ""
        in
        let report_path = record ~fault ~detail in
        print_breadcrumb ~fault ~detail ~report_path;
        exit (128 + signum)
      in
      let set signum =
        try Sys.set_signal signum (Sys.Signal_handle handle)
        with Invalid_argument _ -> ()
      in
      List.iter set
        [ Sys.sigint; Sys.sigterm; Sys.sigquit; Sys.sighup; Sys.sigabrt ]
