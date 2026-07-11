(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Health aggregation over surfaces that already exist elsewhere: strict
   config validation, passive auth readiness, sandbox posture, the session
   store scan, and workspace trust. Doctor never contacts a provider and
   never mutates anything; it is the command the terse one-line diagnostics
   elsewhere point at for full detail. *)

module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common

type verdict = Pass | Warn | Fail
type check = { name : string; verdict : verdict; details : string list }

let verdict_string = function Pass -> "ok" | Warn -> "warn" | Fail -> "fail"

let check_json check =
  json_obj
    [
      ("name", Jsont.Json.string check.name);
      ("status", Jsont.Json.string (verdict_string check.verdict));
      ( "details",
        json_list (List.map (fun line -> Jsont.Json.string line) check.details)
      );
    ]

let print_check check =
  stdout_printf "%s: %s\n" check.name (verdict_string check.verdict);
  List.iter (stdout_printf "  %s\n") check.details

let first_line text =
  match String.split_first ~sep:"\n" text with
  | Some (line, _) -> line
  | None -> text

(* Strict validation of the user file plus the [SPICE_CONFIG] overlay: the
   same selection [spice config validate] applies with no PATH. Strict
   findings are warnings — unknown fields do not break runs. *)
let config_check ~stdenv config =
  let module Config = Spice_host.Config in
  let validate path =
    Config.Config_file.validate_path ~stdenv ~strict:true path
  in
  let user =
    Config.Config_file.user (Config.files config) |> Spice_path.Abs.to_string
  in
  let errors =
    validate user
    @
    match Spice_host.Env.get (Config.process_env config) "SPICE_CONFIG" with
    | None | Some "" -> []
    | Some path -> validate path
  in
  match errors with
  | [] -> { name = "config"; verdict = Pass; details = [] }
  | errors ->
      {
        name = "config";
        verdict = Warn;
        details = List.map (fun error -> Config.Error.message error) errors;
      }

let storage_check config =
  let path accessor = accessor config |> Spice_path.Abs.to_string in
  {
    name = "storage";
    verdict = Pass;
    details =
      [
        "cwd=" ^ path Spice_host.Config.cwd;
        "project=" ^ path Spice_host.Config.project_root;
        "data=" ^ path Spice_host.Config.data_home;
        "state=" ^ path Spice_host.Config.state_home;
      ];
  }

let trust_check ~stdenv ~process_env ?cwd () =
  let store =
    Spice_host.User_dirs.trust_store_path (Spice_host.Env.get process_env)
  in
  let base details = ("store=" ^ store) :: details in
  match
    Spice_host.Config.Config_file.discover ~stdenv ~process_env ?cwd ()
  with
  | Error error ->
      {
        name = "workspace trust";
        verdict = Fail;
        details =
          base
            [ "valid=not checked"; Spice_host.Config.Error.message error ];
      }
  | Ok files ->
      let root = Spice_host.Config.Config_file.project_root files in
      let root_string = Spice_path.Abs.to_string root in
      match Spice_host.Trust.find ~stdenv ~process_env ~root () with
      | Error error ->
          {
            name = "workspace trust";
            verdict = Fail;
            details =
              base
                [
                  "valid=false";
                  "root=" ^ root_string;
                  Spice_host.Trust.Error.message error;
                ];
          }
      | Ok trust ->
          {
            name = "workspace trust";
            verdict = Pass;
            details =
              base
                [
                  "valid=true";
                  ("root="
                  ^ Spice_path.Abs.to_string (Spice_host.Trust.root trust));
                  ("status="
                  ^ Spice_host.Trust.status_to_string
                      (Spice_host.Trust.status trust));
                ];
          }

(* Passive readiness only: no provider request. The run-blocking case is a
   missing or blocked credential for the provider of the selected main
   model; other providers are informational. *)
let auth_check ~sw ~stdenv host =
  match Spice_host.Account.load ~stdenv host with
  | Error error ->
      {
        name = "auth";
        verdict = Fail;
        details = [ Spice_host.Account.Error.message error ];
      }
  | Ok accounts -> (
      match
        Cli_auth.status_rows ~sw ~stdenv host accounts ~refresh:false
          (Spice_host.Host.providers host)
      with
      | Error message ->
          { name = "auth"; verdict = Fail; details = [ message ] }
      | Ok rows ->
          let selected_provider =
            match
              Spice_host.Models.choose
                ~connected:(Spice_host.Account.connected accounts)
                host Spice_host.Models.Model_choice.Main
            with
            | Error _ -> None
            | Ok choice ->
                Some
                  (Spice_provider.Model.provider
                     (Spice_host.Models.Model_choice.model choice))
          in
          let selected_row row =
            match selected_provider with
            | None -> false
            | Some provider ->
                Spice_llm.Provider.equal
                  (Spice_provider.id row.Cli_auth.provider)
                  provider
          in
          let row_line row =
            let base =
              Cli_auth.row_provider_id row
              ^ ": "
              ^ Cli_auth.row_phase_string row
              ^ if selected_row row then " (selected model provider)" else ""
            in
            match Cli_auth.row_repair row with
            | None -> base
            | Some repair -> base ^ "; run `" ^ repair ^ "`"
          in
          let blocked row =
            match Cli_auth.row_phase row with
            | `Missing | `Blocked -> true
            | `Unchecked | `Ready | `Degraded -> false
          in
          let verdict =
            if List.exists (fun row -> selected_row row && blocked row) rows
            then Fail
            else Pass
          in
          { name = "auth"; verdict; details = List.map row_line rows })

(* The local provider is auth-ready by construction, which reads as "will
   work" even when no inference engine is installed. Resolve the binary
   without running it so the mismatch surfaces here instead of failing the
   first request. Warn, not fail: it only matters when a local model is
   selected. *)
let local_engine_check () =
  match Spice_llm_local.server_binary () with
  | Ok path ->
      {
        name = "local engine";
        verdict = Pass;
        details = [ "llama-server: " ^ path ];
      }
  | Error message ->
      { name = "local engine"; verdict = Warn; details = [ message ] }

(* The posture the next run would resolve, gated exactly like a run: a
   restricted requirement without an enforceable backend is the failure a
   user wants surfaced before they lose a prompt to it. *)
let sandbox_check host =
  match Spice_host.workspace host with
  | Error error ->
      {
        name = "sandbox";
        verdict = Fail;
        details = [ Spice_host.Host.Error.message error ];
      }
  | Ok workspace -> (
      let effective =
        resolve_sandbox host ~workspace
          { sandbox_flag = None; require_sandbox = false }
      in
      let module Effective = Spice_host.Sandbox.Effective in
      let module Status = Spice_host.Sandbox.Status in
      let status = Effective.status effective in
      let posture =
        Printf.sprintf "mode=%s origin=%s backend=%s %s network=%s"
          (Spice_host.Sandbox.Mode.to_string status.Status.mode)
          (Status.origin_string status.Status.origin)
          status.Status.backend
          (Status.enforcement_string status.Status.enforcement)
          (Status.network_string status.Status.network)
      in
      match gate_sandbox effective with
      | Ok () -> { name = "sandbox"; verdict = Pass; details = [ posture ] }
      | Error (`Runtime message) ->
          { name = "sandbox"; verdict = Fail; details = [ posture; message ] })

(* The full store scan: corrupt documents are reported here with their
   complete diagnostics; listings elsewhere print one line and point here. *)
let sessions_check ~stdenv host =
  let store = Spice_host.Session.store ~stdenv host in
  match
    Spice_session_store.list store ~include_archived:true ~include_deleted:true
      ()
  with
  | Error error ->
      {
        name = "sessions";
        verdict = Fail;
        details = [ Spice_session_store.Error.message error ];
      }
  | Ok (documents, corrupt) ->
      let count =
        Printf.sprintf "%d document%s" (List.length documents)
          (if List.length documents = 1 then "" else "s")
      in
      let corrupt_lines =
        List.concat_map
          (fun corrupt ->
            (Spice_session_store.Corrupt.path corrupt ^ ":")
            :: (Spice_session_store.Corrupt.message corrupt
               |> String.split_on_char '\n'
               |> List.map (fun line -> "  " ^ line)))
          corrupt
      in
      if List.is_empty corrupt then
        { name = "sessions"; verdict = Pass; details = [ count ] }
      else
        {
          name = "sessions";
          verdict = Warn;
          details =
            (count ^ Printf.sprintf ", %d corrupt" (List.length corrupt))
            :: corrupt_lines;
        }

(* The OCaml tools spawn [dune] from the inherited environment; surfacing its
   resolution (or the rungs checked) here catches a launch context that lost
   the toolchain before a session trips over it. Absence is a warning, not a
   failure: spice serves non-OCaml projects too. *)
let toolchain_check host =
  let workspace_root =
    match Spice_host.workspace host with
    | Error _ -> None
    | Ok workspace -> (
        match Spice_workspace.roots workspace with
        | root :: _ ->
            Some (Spice_path.Abs.to_string (Spice_workspace.Root.dir root))
        | [] -> None)
  in
  let toolchain =
    Spice_ocaml_toolchain.discover ~env:(Unix.environment ()) ~workspace_root
  in
  let detail = Spice_ocaml_toolchain.describe toolchain ~program:"dune" in
  let verdict =
    match Spice_ocaml_toolchain.find toolchain "dune" with
    | Some _ -> Pass
    | None -> Warn
  in
  { name = "ocaml toolchain"; verdict; details = [ detail ] }

let project_config_check host =
  let config = Spice_host.Host.config host in
  let trust = Spice_host.Config.workspace_trust config in
  if not (Spice_host.Trust.is_trusted trust) then
    {
      name = "project config";
      verdict = Pass;
      details =
        [
          "disabled: workspace trust is "
          ^ Spice_host.Trust.status_to_string (Spice_host.Trust.status trust);
        ];
    }
  else
    match Spice_host.Config.warnings config with
    | [] ->
        {
          name = "project config";
          verdict = Pass;
          details = [ "workspace config applied" ];
        }
    | diagnostics ->
        {
          name = "project config";
          verdict = Warn;
          details =
            List.map
              (fun diagnostic ->
                Format.asprintf "%a" Spice_host.Config.Warning.pp diagnostic)
              diagnostics;
        }

let doctor json cwd =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let process_env = Spice_host.Env.current () in
  let trust = trust_check ~stdenv ~process_env ?cwd () in
  let checks =
    match load_host ?cwd ~overrides:[] stdenv with
    | Error error ->
        (* A host that cannot assemble is itself the diagnosis; report the
           config failure rather than erroring out of doctor. *)
        [
          trust;
          {
            name = "config";
            verdict = Fail;
            details =
              [
                Spice_diagnostic.to_string
                  (Spice_host.Host.Error.diagnostic error);
              ];
          };
        ]
    | Ok host ->
        [
          config_check ~stdenv (Spice_host.Host.config host);
          storage_check (Spice_host.Host.config host);
          trust;
          auth_check ~sw ~stdenv host;
          local_engine_check ();
          toolchain_check host;
          sandbox_check host;
          sessions_check ~stdenv host;
          project_config_check host;
        ]
  in
  let failed =
    List.exists
      (fun check -> match check.verdict with Fail -> true | _ -> false)
      checks
  in
  if json then
    stdout_printf "%s\n"
      (json_string
         (json_envelope ~type_:"doctor"
            [
              ("checks", json_list (List.map check_json checks));
              ("ok", Jsont.Json.bool (not failed));
            ]))
  else List.iter print_check checks;
  if failed then Failed else Success

let json_flag = Cli_arg.json_flag ()
let cwd = Cli_arg.cwd ~short:true ()

let command =
  let man =
    [
      `S CManpage.s_description;
      `P
        "Checks local Spice health without contacting a provider or mutating \
         anything: strict config validation, credential readiness for the \
         selected model, the sandbox posture the next run would use, a full \
         session-store scan including corrupt documents, and workspace trust.";
      `P
        "Exits non-zero only when a check fails outright; warnings (such as \
         unknown config fields or corrupt session documents) leave the exit \
         code at zero so scripts can distinguish broken from untidy.";
      `S CManpage.s_examples;
      `Pre "  spice doctor";
      `Pre "  spice doctor --json | jq '.checks[] | select(.status != \"ok\")'";
    ]
  in
  let envs =
    [
      CCmd.Env.info "SPICE_CONFIG"
        ~doc:"Extra config file validated alongside the user config file.";
      CCmd.Env.info "SPICE_CONFIG_HOME"
        ~doc:"Base directory for Spice config files and the auth store.";
    ]
  in
  CCmd.v
    (CCmd.info "doctor" ~doc:"Check local Spice health."
       ~docs:s_diagnostic_commands ~man ~envs ~exits)
    (exit_term CTerm.(const doctor $ json_flag $ cwd))
