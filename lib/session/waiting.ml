(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Permission of Permission.Requested.t
  | Tool_claim of Tool_claim.Started.t
  | Host_tool of host_tool

and host_tool = { turn : Turn.Id.t; call : Spice_llm.Tool.Call.t }

let permission request = Permission request
let tool_claim execution = Tool_claim execution
let host_tool ~turn call = Host_tool { turn; call }

let turn = function
  | Permission request -> Permission.Requested.turn request
  | Tool_claim execution -> Tool_claim.Started.turn execution
  | Host_tool waiting -> waiting.turn

let call = function
  | Permission request -> Permission.Requested.tool_call request
  | Tool_claim execution -> Tool_claim.Started.call execution
  | Host_tool waiting -> waiting.call

let equal a b =
  match (a, b) with
  | Permission a, Permission b -> Permission.Requested.equal a b
  | Tool_claim a, Tool_claim b -> Tool_claim.Started.equal a b
  | Host_tool a, Host_tool b ->
      Turn.Id.equal a.turn b.turn && Spice_llm.Tool.Call.equal a.call b.call
  | (Permission _ | Tool_claim _ | Host_tool _), _ -> false

let pp ppf = function
  | Permission request ->
      Format.fprintf ppf "@[<hov>permission(%a)@]" Permission.Requested.pp
        request
  | Tool_claim execution ->
      Format.fprintf ppf "@[<hov>tool-claim(%a)@]" Tool_claim.Started.pp
        execution
  | Host_tool { turn; call } ->
      Format.fprintf ppf "@[<hov>host-tool(turn=%a, call=%s/%s)@]" Turn.Id.pp
        turn
        (Spice_llm.Tool.Call.id call)
        (Spice_llm.Tool.Call.name call)
