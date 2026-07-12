(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "spice.host.producers" ~doc:"Run notice producers"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* One cell owns all repository-executing producer state. Workflow changes can
   enable or disable it without rebuilding the rest of the run. *)
type engagement = {
  mutable build_enabled : bool;
  mutable engaged : bool;
  mutable merlin_program : string list;
  mutable before_request : unit -> unit;
  mutable stop_dune_watcher : unit -> unit;
}

type t = {
  dune : Spice_ocaml_dune.Rpc.Instance.t ref;
  project_source : Spice_ocaml_dune.Project_source.t;
  engagement : engagement;
  set_build_enabled : bool -> unit;
  reprobe : unit -> unit;
  stop_fswatch : unit -> unit;
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

let prepare sandbox ~cwd ~argv =
  match argv with
  | [] -> Error "process argv is empty"
  | program :: args ->
      let argv = Spice_sandbox.Argv.make ~program args in
      Spice_sandbox.spawn sandbox ~cwd ~argv
      |> Result.map (fun spawn ->
          ( Spice_sandbox.Spawn.argv spawn |> Spice_sandbox.Argv.to_list,
            Spice_sandbox.Spawn.env spawn
            |> List.map (fun (name, value) -> name ^ "=" ^ value)
            |> Array.of_list ))
      |> Result.map_error Spice_sandbox.Error.message

let start ~sw ~stdenv host ~inbox ~on_fswatch ~workspace ~sandbox ~cwd ~root () =
  let config = Host.config host in
  let notices = Config.notices config in
  let trusted = Trust.is_trusted (Config.workspace_trust config) in
  let mutating = Sandbox.mutating_tools sandbox in
  let process_sandbox = Sandbox.Effective.sandbox sandbox in
  let process_env =
    Sandbox.Effective.policy sandbox |> Spice_sandbox.Policy.environment
    |> Spice_sandbox.Environment.bindings
  in
  let process_env name = List.assoc_opt name process_env in
  (* [workspace.tooling] gates the OCaml/Dune integration: when it does not
     engage — [off], or [auto] outside a Dune workspace — the [dune describe]
     capture, the Merlin resolution, and the [dune build --watch] instance are
     skipped. The probe re-reads the marker each call, so an [auto] workspace
     that grows a [dune-project] mid-session engages at the next {!reprobe};
     explicit [on]/[off] answer constantly. Filesystem and CR-comment notices
     are general host streams and remain governed by their own config flags. *)
  let tooling_engaged () =
    trusted
    && Config.Workspace.tooling_engaged (Config.workspace config) ~root
  in
  let dune_diagnostics = Config.Notices.dune_diagnostics notices in
  let dune_build = Config.Notices.dune_build notices in
  let make_instance ~engaged =
    (* The lazy build-watch start hook is armed only on an engaged instance: a
       disengaged one must stay a pure registry poller, because a diagnostics
       tool call could otherwise fire the hook and spawn a watch in a
       marker-less directory. *)
    let start =
      if engaged && mutating && (dune_diagnostics || dune_build) then
        Some
          (Spice_ocaml_dune.Rpc.Instance.Start.dune_build_watch ~sw
             ~prepare:(prepare process_sandbox)
             ~process_mgr:(Eio.Stdenv.process_mgr stdenv)
             ~cwd ())
      else None
    in
    Spice_ocaml_dune.Rpc.Instance.create ~fs:(Eio.Stdenv.fs stdenv)
      ~net:(Eio.Stdenv.net stdenv) ~workspace ?start
      ~env:process_env
      ~sleep:(Eio.Time.sleep (Eio.Stdenv.clock stdenv))
      ()
  in
  let dune = ref (make_instance ~engaged:false) in
  let project_source =
    Spice_ocaml_dune.Project_source.create
      ~refresh_status:(fun () ->
        match Spice_ocaml_dune.Rpc.Instance.refresh_status !dune with
        | Spice_ocaml_dune.Rpc.Instance.Found endpoint ->
            Spice_ocaml_dune.Project_source.Watch_endpoint
              (Spice_ocaml_dune.Rpc.Endpoint.to_string endpoint)
        | Spice_ocaml_dune.Rpc.Instance.Not_found
        | Spice_ocaml_dune.Rpc.Instance.Lookup_failed _ ->
            Spice_ocaml_dune.Project_source.No_watch)
      ~describe:(fun ~cancelled ->
        Spice_ocaml_dune.Describe.describe_project
          ~prepare:(prepare process_sandbox)
          ~process_mgr:(Eio.Stdenv.process_mgr stdenv)
          ~clock:(Eio.Stdenv.clock stdenv) ~cwd ~workspace ~cancelled ())
      ()
  in
  let engagement =
    {
      build_enabled = false;
      engaged = false;
      merlin_program = Spice_tools.Ocaml_merlin.default_program;
      before_request = ignore;
      stop_dune_watcher = ignore;
    }
  in
  (* The engagement sequence, shared by Build binding and {!reprobe}.
     Lock-free window:
     capture the project-shape snapshot and resolve the Merlin invocation to a
     lock-free argv BEFORE the Dune diagnostics watcher starts. That watcher
     lazily spawns [dune build --watch], which takes the build lock; a one-shot
     [dune describe] or a [dune tools exec] resolution engaged after the lock
     is held would fail fast. At boot the window is genuinely free; at a
     mid-session reprobe an external process (a backgrounded shell build) may
     already hold the lock, in which case capture degrades exactly like the
     boot path below — a warning and a structured blocked result, never a
     failed run. *)
  let engage () =
    let previous = !dune in
    dune := make_instance ~engaged:true;
    Spice_ocaml_dune.Rpc.Instance.stop previous;
    (match Spice_ocaml_dune.Project_source.capture project_source with
    | Ok () -> ()
    | Error error ->
        (* Degrade honestly: no snapshot (for instance a user-owned watch
           already held the lock). Describe-backed tools then serve a
           structured blocked result rather than a stale shape. Do not fail
           the run. *)
        Log.warn (fun m ->
            m "project-shape capture failed: %s"
              (Spice_ocaml_dune.Error.message error)));
    (engagement.merlin_program <-
       (let configured = Config.Ocaml.merlin_program (Config.ocaml config) in
        match
          Spice_tools.Ocaml_merlin.resolve_program ~sandbox:process_sandbox
            ~cwd:(Eio.Path.native_exn cwd) ~configured ()
        with
        | Ok argv -> argv
        | Error error ->
            (* Resolution is filesystem-first, so the default [ocamlmerlin]
               prefix resolves to dune's already-built dev-tool binary without
               engaging the engine; an [Error] is only reachable when an
               explicitly configured [dune tools exec] prefix had to be warmed
               and that warming failed. Fall back to plain [ocamlmerlin] on
               PATH — lock-free and honest, even if PATH lacks it (the Merlin
               tools then report Unavailable). *)
            Log.warn (fun m ->
                m "merlin program resolution failed: %s; falling back to %s"
                  (Spice_tools.Ocaml_merlin.resolution_error_message error)
                  (String.concat " " Spice_tools.Ocaml_merlin.default_program));
            Spice_tools.Ocaml_merlin.default_program));
    (if dune_diagnostics || dune_build then
       let watcher =
         Watchers.Dune_diagnostics.start ~diagnostics:dune_diagnostics
           ~build:dune_build ~sw ~clock:(Eio.Stdenv.clock stdenv) ~inbox
           ~dune:!dune ()
       in
       engagement.before_request <- (fun () ->
         Watchers.Dune_diagnostics.refresh watcher);
       engagement.stop_dune_watcher <- (fun () ->
         Watchers.Dune_diagnostics.stop watcher));
    engagement.engaged <- true
  in
  let disengage () =
    if engagement.engaged then begin
      engagement.before_request <- ignore;
      engagement.stop_dune_watcher ();
      engagement.stop_dune_watcher <- ignore;
      Spice_ocaml_dune.Rpc.Instance.stop !dune;
      dune := make_instance ~engaged:false;
      Spice_ocaml_dune.Project_source.clear project_source;
      engagement.merlin_program <- Spice_tools.Ocaml_merlin.default_program;
      engagement.engaged <- false
    end
  in
  let set_build_enabled enabled =
    if Bool.equal engagement.build_enabled enabled then ()
    else begin
      engagement.build_enabled <- enabled;
      if enabled then begin
        if tooling_engaged () then engage ()
      end
      else disengage ()
    end
  in
  let fswatch_notice = trusted && Config.Notices.fswatch notices in
  let cr_notice = trusted && Config.Notices.cr_comments notices in
  let stop_fswatch =
    if fswatch_notice || cr_notice then begin
      (* The drift consumer runs on every fswatch batch, alongside the CR-comment
         observer when it is enabled. NOTE: when neither the fswatch nor the
         cr_comments notice is on, the watcher does not start, so shape drift is
         never flagged and the boot snapshot serves without a [drifted] signal.
         Accepted v1 gap. *)
      let flag_drift events =
        if engagement.engaged && List.exists is_shape_drift events then
          Spice_ocaml_dune.Project_source.set_drifted project_source true
      in
      let on_events =
        let publish events = if fswatch_notice then on_fswatch events in
        if cr_notice then begin
          let cr_comments =
            Watchers.Cr_comments.create ~fs:(Eio.Stdenv.fs stdenv) ~root ~inbox
              ()
          in
          let observe = Watchers.Cr_comments.observe cr_comments in
          Some
            (fun events ->
              observe events;
              flag_drift events;
              publish events)
        end
        else
          Some
            (fun events ->
              flag_drift events;
              publish events)
      in
      Watchers.Fswatch.start ?on_events ~notice:false ~sw
        ~clock:(Eio.Stdenv.clock stdenv) ~inbox ~root ()
    end
    else ignore
  in
  (* Reprobe can engage only while Build owns repository execution. *)
  let reprobe () =
    if
      engagement.build_enabled && (not engagement.engaged)
      && tooling_engaged ()
    then engage ()
  in
  {
    dune;
    project_source;
    engagement;
    set_build_enabled;
    reprobe;
    stop_fswatch;
  }

let dune t = !(t.dune)
let project_source t = t.project_source
let merlin_program t = t.engagement.merlin_program

(* The returned closure reads the cell at call time: the request-boundary hook
   is captured once at run assembly, and must observe an engagement that
   happens after that. *)
let before_request t () = t.engagement.before_request ()
let set_build_enabled t enabled = t.set_build_enabled enabled
let reprobe t = t.reprobe ()

let stop t =
  set_build_enabled t false;
  t.stop_fswatch ();
  Spice_ocaml_dune.Rpc.Instance.stop !(t.dune)
