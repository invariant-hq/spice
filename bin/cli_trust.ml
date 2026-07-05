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

let dormant_note =
  "note: trust currently gates nothing; project config always loads with \
   workspace-safe filtering. The decision is recorded for future trust-gated \
   features."

let update action label workspace =
  Eio_main.run @@ fun stdenv ->
  let process_env = Spice_host.Env.current () in
  match Spice_host.Trust.load ~stdenv ~process_env () with
  | Error error -> Runtime_error (trust_error error)
  | Ok trust -> (
      match action ~stdenv trust ~workspace with
      | Error error -> Runtime_error (trust_error error)
      | Ok path ->
          stdout_printf "%s %s\n%s\n" label path dormant_note;
          Success)

let trust workspace = update Spice_host.Trust.grant "trusted" workspace
let untrust workspace = update Spice_host.Trust.revoke "untrusted" workspace

let trust_command =
  CCmd.v
    (CCmd.info "trust" ~doc:"Trust project config for a workspace."
       ~docs:s_config_commands
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Records a workspace trust decision user-side, never in the \
              workspace; $(b,untrust) revokes it. The decision currently gates \
              nothing: project config always loads, reduced to workspace-safe \
              inputs by construction. It is kept for future trust-gated \
              features that load workspace-authored authority (hooks, project \
              permission rules).";
         ]
       ~exits)
    (exit_term CTerm.(const trust $ workspace))

let untrust_command =
  CCmd.v
    (CCmd.info "untrust" ~doc:"Stop trusting project config for a workspace."
       ~docs:s_config_commands ~exits)
    (exit_term CTerm.(const untrust $ workspace))
