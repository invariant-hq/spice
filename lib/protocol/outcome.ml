(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Waiting of { waiting : Spice_session.Waiting.t; call : Call.t option }
  | Finished of {
      turn : Spice_session.Turn.Id.t;
      outcome : Spice_session.Turn.Outcome.t;
    }

let of_waiting waiting =
  let call =
    match waiting with
    | Spice_session.Waiting.Host_tool host_tool ->
        Call.classify host_tool.Spice_session.Waiting.call
    | Spice_session.Waiting.Permission _ | Spice_session.Waiting.Tool_claim _ ->
        None
  in
  Waiting { waiting; call }

let finished ~turn ~outcome = Finished { turn; outcome }

let waiting = function
  | Waiting { waiting; _ } -> Some waiting
  | Finished _ -> None

let pp ppf = function
  | Waiting { waiting; call } ->
      Format.fprintf ppf "@[<hov>waiting { waiting = %a; call = %a }@]"
        Spice_session.Waiting.pp waiting
        (Format.pp_print_option Call.pp)
        call
  | Finished { turn; outcome } ->
      Format.fprintf ppf "@[<hov>finished { turn = %a; outcome = %a }@]"
        Spice_session.Turn.Id.pp turn Spice_session.Turn.Outcome.pp outcome
