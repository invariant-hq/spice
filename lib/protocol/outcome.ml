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
