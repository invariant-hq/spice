(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "spice.host.producers" ~doc:"Run notice producers"

module Log = (val Logs.src_log log_src : Logs.LOG)

type t = {
  dune : Spice_ocaml_dune.Rpc.Instance.t;
  project_source : Spice_ocaml_dune.Project_source.t;
  merlin_program : string list;
  stop_fswatch : unit -> unit;
  before_request : unit -> unit;
}

(* A filesystem event that can change the Dune describe shape: a change to a
   [dune]/[dune-project]/[dune-workspace] file, or the addition or removal of a
   [.ml]/[.mli] source. Editing a source body does not change the project shape
   a describe reports, so [Changed] on a source file is not drift. *)
let is_shape_drift (event : Spice_fswatch.Event.t) =
  match Spice_path.Rel.basename event.Spice_fswatch.Event.path with
  | Some ("dune" | "dune-project" | "dune-workspace") -> true
  | Some name -> (
      match Filename.extension name with
      | ".ml" | ".mli" -> (
          match event.Spice_fswatch.Event.kind with
          | Spice_fswatch.Event.Created | Spice_fswatch.Event.Deleted -> true
          | Spice_fswatch.Event.Changed -> false)
      | _ -> false)
  | None -> false

let start ~sw ~stdenv host ~inbox ~workspace ~cwd ~root () =
  let config = Host.config host in
  let notices = Config.notices config in
  let dune_diagnostics = Config.Notices.dune_diagnostics notices in
  let dune_build = Config.Notices.dune_build notices in
  let dune =
    let start =
      if dune_diagnostics || dune_build then
        Some
          (Spice_ocaml_dune.Rpc.Instance.Start.dune_build_watch ~sw
             ~process_mgr:(Eio.Stdenv.process_mgr stdenv)
             ~cwd ())
      else None
    in
    Spice_ocaml_dune.Rpc.Instance.create ~fs:(Eio.Stdenv.fs stdenv)
      ~net:(Eio.Stdenv.net stdenv) ~workspace ?start
      ~sleep:(Eio.Time.sleep (Eio.Stdenv.clock stdenv))
      ()
  in
  (* Boot lock-free window: capture the project-shape snapshot and resolve the
     Merlin invocation to a lock-free argv here, BEFORE the Dune diagnostics
     watcher is started below. That watcher lazily spawns [dune build --watch],
     which takes the build lock; a one-shot [dune describe] or a [dune tools
     exec] resolution engaged after the lock is held would fail fast. The [dune]
     instance is already created but its lazy build-watch [start] hook has not
     run yet — only the watcher's first poll triggers it. *)
  let project_source =
    Spice_ocaml_dune.Project_source.create
      ~refresh_status:(fun () ->
        match Spice_ocaml_dune.Rpc.Instance.refresh_status dune with
        | Spice_ocaml_dune.Rpc.Instance.Found endpoint ->
            Spice_ocaml_dune.Project_source.Watch_endpoint
              (Spice_ocaml_dune.Rpc.Endpoint.to_string endpoint)
        | Spice_ocaml_dune.Rpc.Instance.Not_found
        | Spice_ocaml_dune.Rpc.Instance.Lookup_failed _ ->
            Spice_ocaml_dune.Project_source.No_watch)
      ~describe:(fun ~cancelled ->
        Spice_ocaml_dune.Describe.describe_project
          ~process_mgr:(Eio.Stdenv.process_mgr stdenv)
          ~clock:(Eio.Stdenv.clock stdenv) ~cwd ~workspace ~cancelled ())
      ()
  in
  (match Spice_ocaml_dune.Project_source.capture project_source with
  | Ok () -> ()
  | Error error ->
      (* Degrade honestly: no boot snapshot (for instance a user-owned watch
         already held the lock at boot). Describe-backed tools then serve a
         structured blocked result rather than a stale shape. Do not fail the
         run. *)
      Log.warn (fun m ->
          m "project-shape boot capture failed: %s"
            (Spice_ocaml_dune.Error.message error)));
  let merlin_program =
    let configured = Config.Ocaml.merlin_program (Config.ocaml config) in
    match
      Spice_tools.Ocaml_merlin.resolve_program ~cwd:(Eio.Path.native_exn cwd)
        ~configured ()
    with
    | Ok argv -> argv
    | Error error ->
        (* Resolution is filesystem-first, so the default [ocamlmerlin] prefix
           resolves to dune's already-built dev-tool binary without engaging the
           engine; an [Error] is only reachable when an explicitly configured
           [dune tools exec] prefix had to be warmed and that warming failed.
           Fall back to plain [ocamlmerlin] on PATH — lock-free and honest, even
           if PATH lacks it (the Merlin tools then report Unavailable). *)
        Log.warn (fun m ->
            m "merlin program resolution failed: %s; falling back to %s"
              (Spice_tools.Ocaml_merlin.resolution_error_message error)
              (String.concat " " Spice_tools.Ocaml_merlin.default_program));
        Spice_tools.Ocaml_merlin.default_program
  in
  let fswatch_notice = Config.Notices.fswatch notices in
  let cr_notice = Config.Notices.cr_comments notices in
  let stop_fswatch =
    if fswatch_notice || cr_notice then begin
      (* The drift consumer runs on every fswatch batch, alongside the CR-comment
         observer when it is enabled. NOTE: when neither the fswatch nor the
         cr_comments notice is on, the watcher does not start, so shape drift is
         never flagged and the boot snapshot serves without a [drifted] signal.
         Accepted v1 gap. *)
      let flag_drift events =
        if List.exists is_shape_drift events then
          Spice_ocaml_dune.Project_source.set_drifted project_source true
      in
      let on_events =
        if cr_notice then begin
          let cr_comments =
            Watchers.Cr_comments.create ~fs:(Eio.Stdenv.fs stdenv) ~root ~inbox
              ()
          in
          let observe = Watchers.Cr_comments.observe cr_comments in
          Some
            (fun events ->
              observe events;
              flag_drift events)
        end
        else Some flag_drift
      in
      Watchers.Fswatch.start ?on_events ~notice:fswatch_notice ~sw
        ~clock:(Eio.Stdenv.clock stdenv) ~inbox ~root ()
    end
    else ignore
  in
  let before_request =
    if dune_diagnostics || dune_build then
      Watchers.Dune_diagnostics.start ~diagnostics:dune_diagnostics
        ~build:dune_build ~sw ~clock:(Eio.Stdenv.clock stdenv) ~inbox ~dune
    else ignore
  in
  {
    dune;
    project_source;
    merlin_program;
    stop_fswatch;
    before_request;
  }

let dune t = t.dune
let project_source t = t.project_source
let merlin_program t = t.merlin_program
let before_request t = t.before_request

let stop t =
  t.stop_fswatch ();
  Spice_ocaml_dune.Rpc.Instance.stop t.dune
