(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Access = Spice_permission.Access
module Sandbox = Spice_sandbox

let confinement policy =
  match policy with
  | Sandbox.Policy.Confined { reads; writable_roots; network; _ } ->
      let read =
        match reads with
        | Sandbox.Policy.Only _ -> Access.Command.Confinement.Project
        | Sandbox.Policy.All -> Access.Command.Confinement.All
      in
      let write =
        match writable_roots with
        | [] -> Access.Command.Confinement.Read_only
        | _ :: _ -> Access.Command.Confinement.Workspace
      in
      let network =
        match network with
        | Sandbox.Policy.Network.Restricted ->
            Access.Command.Confinement.Restricted
        | Sandbox.Policy.Network.Enabled -> Access.Command.Confinement.Enabled
      in
      Access.Command.Confinement.{ read; write; network }
  | Sandbox.Policy.Direct _ | Sandbox.Policy.External _ ->
      invalid_arg
        "Spice_tools.Command_permission.confinement: policy is not confined"

let execution sandbox =
  match Sandbox.evidence sandbox, Sandbox.policy sandbox with
  | Sandbox.Evidence.Enforced _, (Sandbox.Policy.Confined _ as policy) ->
      Ok (Access.Command.Enforced (confinement policy))
  | Sandbox.Evidence.Declared_external, Sandbox.Policy.External _ ->
      Ok Access.Command.External
  | Sandbox.Evidence.Not_requested, Sandbox.Policy.Direct _ ->
      Ok Access.Command.Direct
  | Sandbox.Evidence.Refused error, Sandbox.Policy.Confined _ -> Error error
  | _ ->
      invalid_arg
        "Spice_tools.Command_permission.execution: sealed sandbox evidence and \
         policy disagree"

let escalated_execution sandbox =
  match Sandbox.escalation sandbox with
  | Sandbox.Available -> Access.Command.Direct
  | Sandbox.Denied _ | Sandbox.Ignored ->
      invalid_arg
        "Spice_tools.Command_permission.escalated_execution: sandbox does not \
         permit escalation"
