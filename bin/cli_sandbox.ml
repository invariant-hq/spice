(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common
module Effective = Spice_host.Sandbox.Effective
module Status = Spice_host.Sandbox.Status
module Sandbox = Spice_sandbox
module Host_sandbox = Spice_host.Sandbox

(* [spice sandbox status|explain] report the posture [spice run] would
   resolve — same resolution, same fact vocabulary, rendered instead of
   executed. Neither command needs provider credentials or a session, and
   neither mutates anything. Unsupported backends are data (exit 0 for status),
   not failures. *)

(* Platform support is coarse status data. Enforcement truth comes from the
   resolved backend facts below. *)
let platform_facts () =
  if
    String.equal Sys.os_type "Unix" && Sys.file_exists "/proc/sys/kernel/ostype"
  then ("linux", true)
  else if Sys.file_exists Sandbox.Seatbelt.executable then ("macos", true)
  else if String.equal Sys.os_type "Win32" then ("windows", false)
  else ("unix", false)

(* One resolution feeds both status and explain. *)
let resolve_posture host =
  let open Result.Syntax in
  let* workspace =
    Spice_host.workspace host
    |> Result.map_error (fun error ->
        `Runtime (Spice_host.Host.Error.message error))
  in
  let effective =
    resolve_sandbox host ~workspace
      { sandbox_flag = None; require_sandbox = false }
  in
  Ok (workspace, effective)

let require_string host =
  Host_sandbox.Require.to_string
    (Spice_host.Config.Sandbox.require
       (Spice_host.Config.sandbox (Spice_host.Host.config host)))

(* The mode origin with config-source detail: where a configured value came
   from is part of the explain contract, credential-free. *)
let mode_origin_detail host effective =
  match (Effective.status effective).Status.origin with
  | (Status.Flag | Status.Default) as origin -> Status.origin_string origin
  | Status.Config -> (
      match
        Spice_host.Config.origin Spice_host.Config.Field.sandbox_mode
          (Spice_host.Host.config host)
      with
      | None -> "config"
      | Some origin -> (
          match Spice_host.Config.Origin.source origin with
          | Spice_host.Config.Source.User { path } ->
              "user " ^ Spice_path.Abs.to_string path
          | Spice_host.Config.Source.Project { path } ->
              "project " ^ Spice_path.Abs.to_string path
          | Spice_host.Config.Source.Project_local { path } ->
              "project-local " ^ Spice_path.Abs.to_string path
          | Spice_host.Config.Source.Extra_file { path } ->
              "extra " ^ Spice_path.Abs.to_string path
          | Spice_host.Config.Source.Env { name } -> "env " ^ name
          | Spice_host.Config.Source.Override -> "override"
          | Spice_host.Config.Source.Default _ -> "default"))

(* status *)

let print_status_text ~verbose host effective =
  let error_message = Sandbox.Error.message in
  let platform, supported = platform_facts () in
  let status = Effective.status effective in
  stdout_printf "mode=%s\n" (Host_sandbox.Mode.to_string status.Status.mode);
  stdout_printf "origin=%s\n" (Status.origin_string status.Status.origin);
  stdout_printf "require=%s\n" (require_string host);
  stdout_printf "platform=%s supported=%b\n" platform supported;
  let available = Status.available status in
  stdout_printf "backend=%s available=%b\n"
    (Sandbox.Backend.id (Effective.backend effective))
    available;
  stdout_printf "restricted=%b\n" available;
  if verbose then begin
    (match status.Status.enforcement with
    | Sandbox.Evidence.Refused reason ->
        stdout_printf "diagnostic: %s\n" (error_message reason)
    | Sandbox.Evidence.Enforced _ | Sandbox.Evidence.Not_requested
    | Sandbox.Evidence.Declared_external ->
        ());
    stdout_printf "network=%s\n" (Status.network_string status.Status.network);
    stdout_printf "enforcement=%s\n"
      (Status.enforcement_string status.Status.enforcement)
  end

let status_json host effective =
  let error_message = Sandbox.Error.message in
  let platform, supported = platform_facts () in
  let status = Effective.status effective in
  let diagnostics =
    match status.Status.enforcement with
    | Sandbox.Evidence.Refused reason ->
        [ Jsont.Json.string (error_message reason) ]
    | Sandbox.Evidence.Enforced _ | Sandbox.Evidence.Not_requested
    | Sandbox.Evidence.Declared_external ->
        []
  in
  let available = Status.available status in
  json_envelope ~type_:"sandbox_status"
    [
      ( "mode",
        Jsont.Json.string (Host_sandbox.Mode.to_string status.Status.mode) );
      ("origin", Jsont.Json.string (Status.origin_string status.Status.origin));
      ("require", Jsont.Json.string (require_string host));
      ( "platform",
        json_obj
          [
            ("id", Jsont.Json.string platform);
            ("supported", Jsont.Json.bool supported);
          ] );
      ( "backend",
        json_obj
          [
            ( "id",
              Jsont.Json.string
                (Sandbox.Backend.id (Effective.backend effective)) );
            ("available", Jsont.Json.bool available);
            ( "enforcement",
              Jsont.Json.string
                (Status.enforcement_string status.Status.enforcement) );
          ] );
      ("restricted_modes_available", Jsont.Json.bool available);
      ("diagnostics", json_list diagnostics);
    ]

let status json verbose overrides cwd =
  with_loaded_host ?cwd ~overrides @@ fun host ->
  match resolve_posture host with
  | Error (`Runtime message) -> Runtime_error message
  | Ok (_workspace, effective) ->
      if json then
        stdout_printf "%s\n" (json_string (status_json host effective))
      else print_status_text ~verbose host effective;
      Success

(* explain *)

(* Policy paths are realpath-canonicalized at resolution; compare against the
   canonicalized workspace root so the workspace renders as ".". *)
let display_path ~workspace path =
  let root =
    match Spice_workspace.roots workspace with
    | root :: _ -> Spice_workspace.Root.dir root
    | [] -> Spice_path.Abs.root
  in
  let root =
    match Unix.realpath (Spice_path.Abs.to_string root) with
    | real -> (
        match Spice_path.Abs.of_string real with
        | Ok real -> real
        | Error _ -> root)
    | exception Unix.Unix_error _ -> root
  in
  if Spice_path.Abs.equal path root then "."
  else
    match Spice_path.Abs.relativize ~root path with
    | Some rel -> "./" ^ Spice_path.Rel.to_string rel
    | None -> Spice_path.Abs.to_string path

let environment_counts effective =
  match Effective.spec effective with
  | Sandbox.Spec.Unconfined | Sandbox.Spec.Declared_external -> None
  | Sandbox.Spec.Confined _ ->
      let bindings = Spice_host.Env.current () |> Spice_host.Env.to_list in
      let kept, stripped = Sandbox.Env.partition bindings in
      Some (List.length kept, List.length stripped)

let policy_facts effective =
  match Effective.spec effective with
  | Sandbox.Spec.Confined policy -> Some policy
  | Sandbox.Spec.Unconfined | Sandbox.Spec.Declared_external -> None

(* The confined mount keeps the whole host readable (see [readable=] below), so
   a missing toolchain is never the sandbox's doing; this line shows where
   [dune] resolves from — or which rungs were checked — so the two failure
   classes are told apart at a glance. *)
let toolchain_status workspace =
  let workspace_root =
    match Spice_workspace.roots workspace with
    | root :: _ ->
        Some (Spice_path.Abs.to_string (Spice_workspace.Root.dir root))
    | [] -> None
  in
  let toolchain =
    Spice_ocaml_toolchain.discover ~env:(Unix.environment ()) ~workspace_root
  in
  Spice_ocaml_toolchain.describe toolchain ~program:"dune"

let explain_text host workspace effective =
  let status = Effective.status effective in
  stdout_printf "workspace=.\n";
  stdout_printf "mode=%s (%s)\n"
    (Host_sandbox.Mode.to_string status.Status.mode)
    (Status.origin_string status.Status.origin);
  stdout_printf "require=%s\n" (require_string host);
  stdout_printf "backend=%s %s\n" status.Status.backend
    (Status.enforcement_string status.Status.enforcement);
  stdout_printf "network=%s\n" (Status.network_string status.Status.network);
  (match policy_facts effective with
  | None -> ()
  | Some policy ->
      (* The confined mount is full read of the host root, not just the
         workspace, so a command can still read system files and the developer
         toolchain; only writes are scoped. *)
      stdout_printf "readable=/ (read-only)\n";
      stdout_printf "writable=%s\n"
        (match Sandbox.Confinement.writable_roots policy with
        | [] -> "(none)"
        | roots -> String.concat "," (List.map (display_path ~workspace) roots));
      stdout_printf "protected=%s\n"
        (String.concat ","
           (Sandbox.Confinement.protected_meta policy
           @ List.map (display_path ~workspace)
               (Sandbox.Confinement.protected_paths policy))));
  (match environment_counts effective with
  | None -> ()
  | Some (kept, stripped) ->
      stdout_printf "environment=inherited %d, stripped %d\n" kept stripped);
  stdout_printf "toolchain=%s\n" (toolchain_status workspace);
  stdout_printf "origin sandbox.mode=%s\n" (mode_origin_detail host effective)

let explain_json host workspace effective =
  let policy = policy_facts effective in
  let status = Effective.status effective in
  json_envelope ~type_:"sandbox_explain"
    [
      ( "workspace",
        json_obj
          [
            ( "root",
              Jsont.Json.string
                (match Spice_workspace.roots workspace with
                | root :: _ ->
                    Spice_path.Abs.to_string (Spice_workspace.Root.dir root)
                | [] -> "/") );
          ] );
      ( "mode",
        Jsont.Json.string (Host_sandbox.Mode.to_string status.Status.mode) );
      ("origin", Jsont.Json.string (Status.origin_string status.Status.origin));
      ("require", Jsont.Json.string (require_string host));
      ( "network",
        Jsont.Json.string (Status.network_string status.Status.network) );
      ( "backend",
        json_obj
          [
            ("id", Jsont.Json.string status.Status.backend);
            ( "enforcement",
              Jsont.Json.string
                (Status.enforcement_string status.Status.enforcement) );
          ] );
      ( "writable_roots",
        json_list
          (match policy with
          | None -> []
          | Some policy ->
              List.map
                (fun path -> Jsont.Json.string (Spice_path.Abs.to_string path))
                (Sandbox.Confinement.writable_roots policy)) );
      ( "protected_meta",
        json_list
          (match policy with
          | None -> []
          | Some policy ->
              List.map
                (fun value -> Jsont.Json.string value)
                (Sandbox.Confinement.protected_meta policy)) );
      ( "protected_paths",
        json_list
          (match policy with
          | None -> []
          | Some policy ->
              List.map
                (fun path -> Jsont.Json.string (Spice_path.Abs.to_string path))
                (Sandbox.Confinement.protected_paths policy)) );
      ( "environment",
        match environment_counts effective with
        | None -> json_null
        | Some (kept, stripped) ->
            json_obj
              [
                ("inherited_count", Jsont.Json.int kept);
                ("stripped_count", Jsont.Json.int stripped);
                ( "stripped_patterns",
                  json_list
                    (List.map
                       (fun value -> Jsont.Json.string value)
                       Sandbox.Env.stripped_patterns) );
              ] );
      ("toolchain", Jsont.Json.string (toolchain_status workspace));
      ( "origins",
        json_obj
          [
            ( "sandbox.mode",
              Jsont.Json.string (mode_origin_detail host effective) );
          ] );
    ]

let explain json overrides cwd =
  with_loaded_host ?cwd ~overrides @@ fun host ->
  match resolve_posture host with
  | Error (`Runtime message) -> Runtime_error message
  | Ok (workspace, effective) ->
      if json then
        stdout_printf "%s\n"
          (json_string (explain_json host workspace effective))
      else explain_text host workspace effective;
      Success

(* Commands *)

let json_flag = Cli_arg.json_flag ()

let verbose_flag =
  CArg.(
    value & flag
    & info [ "verbose" ] ~doc:"Include diagnostics and derived facts.")

let cwd_arg = Cli_arg.cwd ()

let status_command =
  CCmd.v
    (CCmd.info "status"
       ~doc:
         "Report sandbox platform support, backend availability, and the \
          effective mode without provider credentials or a session."
       ~exits)
    (exit_term
       CTerm.(
         const status $ json_flag $ verbose_flag $ Cli_arg.run_overrides
         $ cwd_arg))

let explain_command =
  CCmd.v
    (CCmd.info "explain"
       ~doc:
         "Report the sandbox policy Spice would apply to this workspace: mode, \
          backend, network, writable roots, protected entries, and environment \
          stripping."
       ~exits)
    (exit_term
       CTerm.(const explain $ json_flag $ Cli_arg.run_overrides $ cwd_arg))

let group =
  CCmd.group
    (CCmd.info "sandbox"
       ~doc:"Inspect command sandbox support, posture, and policy."
       ~docs:s_diagnostic_commands
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Reports the sandbox posture runs would use without loading \
              provider credentials or touching a session: $(b,status) for \
              platform and backend facts, $(b,explain) for the concrete policy \
              — writable roots, protected metadata names and concrete paths, \
              network, and environment stripping.";
           `P
             "For $(b,workspace-write), writable roots are shaped by the \
              workspace, temp roots, $(b,sandbox.writable_roots), and the \
              $(b,sandbox.toolchain_caches) preset. Network posture is shaped \
              by $(b,sandbox.network).";
         ]
       ~exits)
    [ status_command; explain_command ]
