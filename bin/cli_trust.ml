(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common

let workspace = CArg.(value & pos 0 string "." & info [] ~docv:"DIR")
let trust_error error = Spice_host.Trust.Error.message error

let update action label workspace =
  Eio_main.run @@ fun stdenv ->
  let process_env = Spice_host.Env.current () in
  match
    Spice_host.Config.Config_file.discover ~stdenv ~process_env ~cwd:workspace
      ()
  with
  | Error error -> Runtime_error (Spice_host.Config.Error.message error)
  | Ok files -> (
      let root = Spice_host.Config.Config_file.project_root files in
      match action ~stdenv ~process_env ~root () with
      | Error error -> Runtime_error (trust_error error)
      | Ok trust ->
          stdout_printf "%s %s\n" label
            (Spice_host.Trust.root trust |> Spice_path.Abs.to_string);
          Success)

let trust workspace =
  update
    (fun ~stdenv ~process_env ~root () ->
      Spice_host.Trust.trust ~stdenv ~process_env ~root ())
    "trusted" workspace

let untrust workspace =
  update
    (fun ~stdenv ~process_env ~root () ->
      Spice_host.Trust.untrust ~stdenv ~process_env ~root ())
    "untrusted" workspace

let trust_command =
  CCmd.v
    (CCmd.info "trust" ~doc:"Trust project config for a workspace."
       ~docs:s_config_commands
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Records a workspace trust decision user-side, never in the \
              workspace; $(b,untrust) records an explicit refusal. The nearest \
              enclosing project root is used, so invoking the command from a \
              project subdirectory updates the same decision.";
         ]
       ~exits)
    (exit_term CTerm.(const trust $ workspace))

let untrust_command =
  CCmd.v
    (CCmd.info "untrust" ~doc:"Stop trusting project config for a workspace."
       ~docs:s_config_commands ~exits)
    (exit_term CTerm.(const untrust $ workspace))
