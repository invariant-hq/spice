(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Id =
  String_id.Make
    (struct
      let module_path = "Spice_session.Tool_claim.Id"
      let kind = "tool claim id"
    end)
    ()

module Started = struct
  type t = { id : Id.t; turn : Turn.Id.t; call : Spice_llm.Tool.Call.t }

  let make ~id ~turn ~call = { id; turn; call }
  let id t = t.id
  let turn t = t.turn
  let call t = t.call

  let equal a b =
    Id.equal a.id b.id
    && Turn.Id.equal a.turn b.turn
    && Spice_llm.Tool.Call.equal a.call b.call

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ id = %a; turn = %a; call = %s }@]" Id.pp t.id
      Turn.Id.pp t.turn
      (Spice_llm.Tool.Call.id t.call)

  let jsont =
    Jsont.Object.map ~kind:"started tool claim" (fun id turn call ->
        make ~id ~turn ~call)
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.mem "turn" Turn.Id.jsont ~enc:turn
    |> Jsont.Object.mem "call" Spice_llm.Tool.Call.jsont ~enc:call
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Finished = struct
  type t = {
    id : Id.t;
    result : Spice_llm.Tool.Result.t;
    output : Spice_tool.Output.t option;
  }

  let make ~id ~output result = { id; result; output }
  let id t = t.id
  let result t = t.result
  let output t = t.output

  let equal a b =
    Id.equal a.id b.id
    && Spice_llm.Tool.Result.equal a.result b.result
    && Option.equal
         (fun left right ->
           match
             ( Jsont.Json.encode Spice_tool.Output.jsont left,
               Jsont.Json.encode Spice_tool.Output.jsont right )
           with
           | Ok left, Ok right -> Jsont.Json.equal left right
           | _ -> false)
         a.output b.output

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ id = %a; result = %s }@]" Id.pp t.id
      (Spice_llm.Tool.Result.call_id t.result)

  let jsont =
    Jsont.Object.map ~kind:"finished tool claim" (fun id result output ->
        make ~id ~output result)
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.mem "result" Spice_llm.Tool.Result.jsont ~enc:result
    |> Jsont.Object.mem "output"
         (Jsont.option Spice_tool.Output.jsont)
         ~enc:output
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let matches started finished =
  Id.equal (Started.id started) (Finished.id finished)
