(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Permission of Spice_session.Permission.Requested.t
  | Plan of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      proposal : Plan.Proposal.t;
    }
  | Question of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      question : Question.Request.t;
    }
  | Host_tool of {
      turn : Spice_session.Turn.Id.t;
      call_id : string;
      call : Call.t;
    }

let of_outcome (o : Outcome.t) =
  match o with
  | Outcome.Finished _ -> None
  | Outcome.Waiting { waiting; call } -> (
      match waiting with
      | Spice_session.Waiting.Permission request -> Some (Permission request)
      | Spice_session.Waiting.Tool_claim _ -> None
      | Spice_session.Waiting.Host_tool _ -> (
          let turn = Spice_session.Waiting.turn waiting in
          let call_id =
            Spice_llm.Tool.Call.id (Spice_session.Waiting.call waiting)
          in
          (* [call] is [Call.classify] of this same host-tool call, pre-applied
             by [Outcome]. Reading it rather than re-classifying keeps the two
             truths from drifting; [None] is the replay-only case of a call the
             current vocabulary does not recognize, which has no dialog. *)
          match call with
          | Some (Call.Plan proposal) -> Some (Plan { turn; call_id; proposal })
          | Some (Call.Question question) ->
              Some (Question { turn; call_id; question })
          | Some call -> Some (Host_tool { turn; call_id; call })
          | None -> None))

let turn = function
  | Permission request -> Spice_session.Permission.Requested.turn request
  | Plan { turn; _ } | Question { turn; _ } | Host_tool { turn; _ } -> turn

let call_id = function
  | Permission _ -> None
  | Plan { call_id; _ } | Question { call_id; _ } | Host_tool { call_id; _ } ->
      Some call_id
