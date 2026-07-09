(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Notice = Spice_protocol.Notice
module Fsw = Spice_fswatch
module Dune = Spice_ocaml_dune
module Ocaml = Spice_ocaml

let log_src =
  Logs.Src.create "spice.host.watchers" ~doc:"Run notice watchers"

module Log = (val Logs.src_log log_src : Logs.LOG)

let enqueue inbox ~source ~severity ~title ~body ~key =
  Notice_queue.publish inbox
    (Notice.make ~source ~severity ~title ~body ~key ())

let take n list =
  let rec loop count acc = function
    | [] -> List.rev acc
    | _ :: _ when count = n -> List.rev acc
    | x :: xs -> loop (count + 1) (x :: acc) xs
  in
  loop 0 [] list

module Fswatch = struct
  let source = "fswatch"

  let default_ignore path =
    match Spice_path.Rel.to_string path with
    | "." -> false
    | text ->
        String.split_on_char '/' text
        |> List.exists (function
          | ".git" | "_build" | "_opam" | ".spice" -> true
          | _ -> false)

  let kind_text = function
    | Fsw.Event.Created -> "created"
    | Fsw.Event.Deleted -> "deleted"
    | Fsw.Event.Changed -> "changed"

  let event_text event =
    "- "
    ^ kind_text event.Fsw.Event.kind
    ^ " "
    ^ Spice_path.Rel.to_string event.Fsw.Event.path

  let event_key event =
    kind_text event.Fsw.Event.kind
    ^ ":"
    ^ Spice_path.Rel.to_string event.Fsw.Event.path

  let body events =
    let count = List.length events in
    let shown = take 20 events in
    let lines =
      [
        Printf.sprintf
          "%d workspace file change%s detected since the previous filesystem \
           watcher scan."
          count
          (if count = 1 then "" else "s");
      ]
      @ List.map event_text shown
      @
      if count > List.length shown then
        [ Printf.sprintf "- ... and %d more" (count - List.length shown) ]
      else []
    in
    String.concat "\n" lines

  let publish inbox ~root events =
    match events with
    | [] -> ()
    | _ :: _ ->
        let key =
          "fswatch\000" ^ root ^ "\000"
          ^ String.concat "\000" (List.map event_key events)
        in
        enqueue inbox ~source ~severity:Notice.Severity.Info
          ~title:"Workspace files changed" ~body:(body events) ~key

  let publish_failure inbox ~title error =
    let message = Fsw.Error.message error in
    enqueue inbox ~source ~severity:Notice.Severity.Warning ~title ~body:message
      ~key:("fswatch-error\000" ^ title ^ "\000" ^ message)

  let start ?(notice = true) ?on_events ~sw ~clock ~inbox ~root () =
    let on_events = Option.value on_events ~default:ignore in
    Fsw.watch ~sw ~clock ~ignore:default_ignore ~root
      ~f:(fun events ->
        if notice then publish inbox ~root events;
        on_events events)
      ~on_error:(fun error ->
        if notice then
          publish_failure inbox ~title:"Filesystem watcher stopped" error)
      ()
end

module Cr_comments = struct
  module Cr = Spice_cr

  type fs = Fs : _ Eio.Path.t -> fs

  type issue = {
    path : string;
    line : int;
    digest : string;
    summary : string;
    severity : Notice.Severity.t;
  }

  type t = {
    fs : fs;
    root : string;
    inbox : Notice_queue.t;
    by_path : (string, issue list) Hashtbl.t;
    mutable last_fingerprint : string;
  }

  let display_recipient = function
    | None -> ""
    | Some recipient -> " for " ^ Cr.Handle.to_string recipient

  let issue_of_occurrence occurrence =
    let path = Spice_path.Rel.to_string (Cr.Occurrence.path occurrence) in
    let line = Cr.Occurrence.line occurrence in
    let digest =
      Spice_digest.Identity.digest_hex (Cr.Occurrence.digest occurrence)
    in
    match Cr.Occurrence.comment occurrence with
    | Ok comment -> (
        match Cr.status comment with
        | Cr.Status.Resolved _ -> None
        | Cr.Status.Open priority ->
            let priority_text = Cr.Priority.to_string priority in
            let summary =
              Printf.sprintf "open %s CR%s: %s" priority_text
                (display_recipient (Cr.recipient comment))
                (Cr.body comment)
            in
            let severity =
              match priority with
              | Cr.Priority.Now -> Notice.Severity.Warning
              | Cr.Priority.Soon -> Notice.Severity.Info
            in
            Some { path; line; digest; summary; severity })
    | Error error ->
        Some
          {
            path;
            line;
            digest;
            summary = "malformed CR: " ^ Cr.Error.message error;
            severity = Notice.Severity.Warning;
          }

  let read_text t rel =
    let (Fs fs) = t.fs in
    try Ok (Eio.Path.load (Eio.Path.( / ) fs (Filename.concat t.root rel)))
    with exn -> Error exn

  let scan_file t path =
    let rel = Spice_path.Rel.to_string path in
    (* Guard on [of_path] before reading so non-source files are never loaded. *)
    if Option.is_none (Cr.Syntax.of_path path) then []
    else
      match read_text t rel with
      | Error _ -> []
      | Ok text ->
          Cr.scan_file ~path ~text |> List.filter_map issue_of_occurrence

  let max_initial_scan_entries = 50_000
  let max_initial_scan_source_files = 5_000

  let initial_scan_rel rel name =
    if String.equal rel "" then name else Filename.concat rel name

  let ignored_initial_scan_rel rel =
    let path = if String.equal rel "" then "." else rel in
    match Spice_path.Rel.of_string path with
    | Error _ -> true
    | Ok path -> Fswatch.default_ignore path

  let sorted_readdir path =
    try Sys.readdir path |> Array.to_list |> List.sort String.compare
    with Sys_error _ -> []

  let scan_initial t =
    let entries_seen = ref 0 in
    let source_files_seen = ref 0 in
    let can_read_entry () = !entries_seen < max_initial_scan_entries in
    let can_scan_source_file () =
      !source_files_seen < max_initial_scan_source_files
    in
    let rec walk rel abs =
      if can_read_entry () && not (ignored_initial_scan_rel rel) then
        match Unix.lstat abs with
        | exception Unix.Unix_error _ -> ()
        | stats -> (
            match stats.Unix.st_kind with
            | Unix.S_DIR ->
                sorted_readdir abs
                |> List.iter (fun name ->
                    if can_read_entry () then begin
                      incr entries_seen;
                      walk
                        (initial_scan_rel rel name)
                        (Filename.concat abs name)
                    end)
            | Unix.S_REG ->
                if can_scan_source_file () then begin
                  incr source_files_seen;
                  (* [rel] is a raw readdir path; validate it before scanning. *)
                  match Spice_path.Rel.of_string rel with
                  | Error _ -> ()
                  | Ok path -> (
                      if Option.is_some (Cr.Syntax.of_path path) then
                        match scan_file t path with
                        | [] -> ()
                        | issues -> Hashtbl.replace t.by_path rel issues)
                end
            | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK
              ->
                ())
    in
    walk "" t.root

  let issue_key issue =
    Printf.sprintf "%s:%d:%s:%s" issue.path issue.line issue.digest
      issue.summary

  let all_issues t =
    Hashtbl.to_seq_values t.by_path
    |> List.of_seq |> List.flatten
    |> List.sort (fun a b ->
        let order = String.compare a.path b.path in
        if order <> 0 then order else Int.compare a.line b.line)

  let fingerprint issues =
    "cr-comments\000" ^ String.concat "\000" (List.map issue_key issues)

  let notice_severity issues =
    if
      List.exists
        (fun issue ->
          Notice.Severity.equal issue.severity Notice.Severity.Warning)
        issues
    then Notice.Severity.Warning
    else Notice.Severity.Info

  let issue_line issue =
    Printf.sprintf "- %s:%d %s (%s)" issue.path issue.line issue.summary
      issue.digest

  let body issues =
    match issues with
    | [] -> "No open or malformed source CR comments are currently known."
    | _ :: _ ->
        let count = List.length issues in
        let shown = take 20 issues in
        String.concat "\n"
          (Printf.sprintf "%d source CR comment%s currently need attention."
             count
             (if count = 1 then "" else "s")
           :: List.map issue_line shown
          @
          if count > List.length shown then
            [ Printf.sprintf "- ... and %d more" (count - List.length shown) ]
          else [])

  let publish_if_changed t =
    let issues = all_issues t in
    let fingerprint = fingerprint issues in
    if not (String.equal t.last_fingerprint fingerprint) then begin
      t.last_fingerprint <- fingerprint;
      enqueue t.inbox ~source:"code-review-comments"
        ~severity:(notice_severity issues)
        ~title:
          (match issues with
          | [] -> "Code review comments cleared"
          | _ :: _ -> "Code review comments need attention")
        ~body:(body issues) ~key:fingerprint
    end

  let create ~fs ~root ~inbox () =
    let t =
      {
        fs = Fs fs;
        root;
        inbox;
        by_path = Hashtbl.create 16;
        last_fingerprint = "cr-comments\000";
      }
    in
    scan_initial t;
    t.last_fingerprint <- fingerprint (all_issues t);
    t

  let update_path t path kind =
    let rel = Spice_path.Rel.to_string path in
    match kind with
    | Fsw.Event.Deleted -> Hashtbl.remove t.by_path rel
    | Fsw.Event.Created | Fsw.Event.Changed ->
        let issues = scan_file t path in
        if issues = [] then Hashtbl.remove t.by_path rel
        else Hashtbl.replace t.by_path rel issues

  let observe t events =
    List.iter
      (fun event -> update_path t event.Fsw.Event.path event.Fsw.Event.kind)
      events;
    publish_if_changed t
end

module Dune_diagnostics = struct
  type refresh = unit -> unit

  let severity_rank diagnostic =
    match Ocaml.Diagnostic.severity diagnostic with
    | Ocaml.Diagnostic.Severity.Error -> 3
    | Ocaml.Diagnostic.Severity.Warning -> 2
    | Ocaml.Diagnostic.Severity.Information -> 1
    | Ocaml.Diagnostic.Severity.Hint -> 0

  let notice_severity diagnostics =
    if List.exists (fun (_, d) -> severity_rank d >= 3) diagnostics then
      Notice.Severity.Error
    else if List.exists (fun (_, d) -> severity_rank d >= 2) diagnostics then
      Notice.Severity.Warning
    else Notice.Severity.Info

  let location_text diagnostic =
    match Ocaml.Diagnostic.location diagnostic with
    | None -> "<workspace>"
    | Some location ->
        let range = Ocaml.Location.range location in
        let start = Ocaml.Range.start range in
        Printf.sprintf "%s:%d:%d"
          (Spice_workspace.Path.display (Ocaml.Location.path location))
          (Ocaml.Position.line start)
          (Ocaml.Position.column start)

  let severity_text diagnostic =
    Format.asprintf "%a" Ocaml.Diagnostic.Severity.pp
      (Ocaml.Diagnostic.severity diagnostic)

  let diagnostic_line (id, diagnostic) =
    Printf.sprintf "- [%s] %s: %s (%s)" (severity_text diagnostic)
      (location_text diagnostic)
      (Ocaml.Diagnostic.message diagnostic)
      (Dune.Rpc.Diagnostic.Id.to_string id)

  let diagnostics_body diagnostics =
    match diagnostics with
    | [] -> "Dune reports no current OCaml diagnostics."
    | _ :: _ ->
        let count = List.length diagnostics in
        let shown = take 20 diagnostics in
        String.concat "\n"
          (Printf.sprintf "Dune reports %d current OCaml diagnostic%s." count
             (if count = 1 then "" else "s")
           :: List.map diagnostic_line shown
          @
          if count > List.length shown then
            [ Printf.sprintf "- ... and %d more" (count - List.length shown) ]
          else [])

  let diagnostics_fingerprint diagnostics =
    "dune-diagnostics\000"
    ^ String.concat "\000"
        (List.map
           (fun (id, diagnostic) ->
             Dune.Rpc.Diagnostic.Id.to_string id
             ^ ":" ^ severity_text diagnostic ^ ":" ^ location_text diagnostic
             ^ ":"
             ^ Ocaml.Diagnostic.message diagnostic)
           diagnostics)

  let current_diagnostics dune =
    Dune.Rpc.Instance.diagnostics dune |> Dune.Rpc.Diagnostic.Store.to_list

  let publish_diagnostics inbox diagnostics =
    let fingerprint = diagnostics_fingerprint diagnostics in
    enqueue inbox ~source:"ocaml-dune-diagnostics"
      ~severity:(notice_severity diagnostics)
      ~title:
        (match diagnostics with
        | [] -> "OCaml diagnostics cleared"
        | _ :: _ -> "New OCaml diagnostics available")
      ~body:(diagnostics_body diagnostics)
      ~key:fingerprint

  let publish_diagnostics_if_changed inbox dune last_fingerprint =
    let diagnostics = current_diagnostics dune in
    let fingerprint = diagnostics_fingerprint diagnostics in
    if not (String.equal !last_fingerprint fingerprint) then begin
      last_fingerprint := fingerprint;
      publish_diagnostics inbox diagnostics
    end

  let build_progress_text = function
    | Dune.Rpc.Build.Waiting -> "waiting"
    | Dune.Rpc.Build.In_progress { complete; remaining; failed } ->
        Printf.sprintf "in progress: complete=%d remaining=%d failed=%d"
          complete remaining failed
    | Dune.Rpc.Build.Failed -> "failed"
    | Dune.Rpc.Build.Interrupted -> "interrupted"
    | Dune.Rpc.Build.Success -> "success"

  let build_notice_severity = function
    | Dune.Rpc.Build.Failed | Dune.Rpc.Build.Interrupted ->
        Some Notice.Severity.Warning
    | Dune.Rpc.Build.Success -> Some Notice.Severity.Info
    | Dune.Rpc.Build.Waiting | Dune.Rpc.Build.In_progress _ -> None

  let publish_build inbox progress =
    match build_notice_severity progress with
    | None -> ()
    | Some severity ->
        let status = build_progress_text progress in
        enqueue inbox ~source:"ocaml-dune-build" ~severity
          ~title:"Dune build status changed"
          ~body:("Dune build status is " ^ status ^ ".")
          ~key:("dune-build\000" ^ status)

  let publish_build_if_changed inbox last_status progress =
    let status = build_progress_text progress in
    if not (Option.equal String.equal !last_status (Some status)) then begin
      last_status := Some status;
      publish_build inbox progress
    end

  let publish_failure_if_changed inbox last_failure error =
    let message = Dune.Error.message error in
    if not (Option.equal String.equal !last_failure (Some message)) then begin
      last_failure := Some message;
      enqueue inbox ~source:"ocaml-dune-diagnostics"
        ~severity:Notice.Severity.Warning ~title:"Dune diagnostics unavailable"
        ~body:message
        ~key:("dune-diagnostics-error\000" ^ message)
    end

  let request_current_diagnostics ~diagnostics ~connected_once inbox dune
      last_diagnostics last_failure =
    if not diagnostics then Ok ()
    else
      match Dune.Rpc.Instance.request_diagnostics dune with
      | Ok _ ->
          connected_once := true;
          last_failure := None;
          publish_diagnostics_if_changed inbox dune last_diagnostics;
          Ok ()
      | Error error ->
          if !connected_once then
            publish_failure_if_changed inbox last_failure error;
          Error error

  type t = {
    diagnostics : bool;
    build : bool;
    inbox : Notice_queue.t;
    dune : Dune.Rpc.Instance.t;
    last_diagnostics : string ref;
    last_build : string option ref;
    last_failure : string option ref;
    connected_once : bool ref;
  }

  let make ?(diagnostics = true) ?(build = true) ~inbox ~dune () =
    {
      diagnostics;
      build;
      inbox;
      dune;
      last_diagnostics = ref (diagnostics_fingerprint []);
      last_build = ref None;
      last_failure = ref None;
      connected_once = ref false;
    }

  let refresh_current t =
    if t.diagnostics then
      ignore
        (request_current_diagnostics ~diagnostics:t.diagnostics
           ~connected_once:t.connected_once t.inbox t.dune t.last_diagnostics
           t.last_failure
          : (unit, Dune.Error.t) result)
    else ignore (Dune.Rpc.Instance.refresh t.dune)

  let refresh_visible t =
    match Dune.Rpc.Instance.refresh t.dune with
    | Error _ | Ok None -> ()
    | Ok (Some _) ->
        ignore
          (request_current_diagnostics ~diagnostics:t.diagnostics
             ~connected_once:t.connected_once t.inbox t.dune t.last_diagnostics
             t.last_failure
            : (unit, Dune.Error.t) result)

  let start ?(diagnostics = true) ?(build = true) ~sw ~clock ~inbox ~dune =
    let t = make ~diagnostics ~build ~inbox ~dune () in
    let bounded timeout_s f =
      match Eio.Time.with_timeout_exn clock timeout_s f with
      | () -> ()
      | exception Eio.Time.Timeout -> ()
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception exn ->
          (* This runs before every model request ([before_request]) and on the
             poll fibers; a probe fault must degrade the footer, never escape to
             fail the run's switch. *)
          Log.warn (fun m ->
              m "dune diagnostics probe raised, ignored: %s"
                (Printexc.to_string exn))
    in
    if t.diagnostics || t.build then
      Eio.Fiber.fork_daemon ~sw (fun () ->
          if t.diagnostics then
            Eio.Fiber.fork_daemon ~sw (fun () ->
                let rec loop () =
                  bounded 5.0 (fun () -> refresh_current t);
                  Eio.Time.sleep clock 0.25;
                  loop ()
                in
                loop ());
          let rec loop () =
            begin match Dune.Rpc.Instance.refresh t.dune with
            | Ok None | Error _ -> ()
            | Ok (Some _) -> (
                match
                  Dune.Rpc.Instance.run t.dune ~on_event:(function
                    | Dune.Rpc.Diagnostics _ ->
                        t.connected_once := true;
                        t.last_failure := None;
                        if t.diagnostics then
                          publish_diagnostics_if_changed t.inbox t.dune
                            t.last_diagnostics
                    | Dune.Rpc.Build_progress progress ->
                        t.connected_once := true;
                        t.last_failure := None;
                        if t.build then
                          publish_build_if_changed t.inbox t.last_build progress
                    | Dune.Rpc.Disconnected _ ->
                        if t.diagnostics then
                          publish_diagnostics_if_changed t.inbox t.dune
                            t.last_diagnostics)
                with
                | Ok () -> ()
                | Error error ->
                    if !(t.connected_once) then
                      publish_failure_if_changed t.inbox t.last_failure error)
            end;
            Eio.Time.sleep clock 2.0;
            loop ()
          in
          loop ());
    fun () -> bounded 1.0 (fun () -> refresh_visible t)
end
