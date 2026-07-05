(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Policy = struct
  type t = {
    model : Spice_llm.Model.t option;
    prelude : Spice_llm.Request.Prelude.t option;
    auto_limit : int option;
    keep_turns : int;
    keep_tokens : int option;
    summary_max_output_tokens : int option;
  }

  let invalid parameter value =
    invalid_arg
      (Printf.sprintf "Compactor.Policy.make: %s, got %d" parameter value)

  let require_positive parameter = function
    | Some value when value <= 0 ->
        invalid (parameter ^ " must be positive") value
    | Some _ | None -> ()

  let require_non_negative parameter = function
    | Some value when value < 0 ->
        invalid (parameter ^ " must be non-negative") value
    | Some _ | None -> ()

  let make ?model ?prelude ?auto_limit ?(keep_turns = 2) ?keep_tokens
      ?summary_max_output_tokens () =
    require_positive "auto_limit" auto_limit;
    if keep_turns < 0 then invalid "keep_turns must be non-negative" keep_turns;
    require_non_negative "keep_tokens" keep_tokens;
    require_positive "summary_max_output_tokens" summary_max_output_tokens;
    {
      model;
      prelude;
      auto_limit;
      keep_turns;
      keep_tokens;
      summary_max_output_tokens;
    }

  let default =
    {
      model = None;
      prelude = None;
      auto_limit = None;
      keep_turns = 2;
      keep_tokens = None;
      summary_max_output_tokens = None;
    }

  let model t = t.model
  let prelude t = t.prelude
  let auto_limit t = t.auto_limit
  let keep_turns t = t.keep_turns
  let keep_tokens t = t.keep_tokens
  let summary_max_output_tokens t = t.summary_max_output_tokens

  (* The automatic limit reserves an output buffer under the declared context
     window, capped at 20_000 tokens. A window that cannot fund a buffer
     disables automatic compaction. *)
  let auto_limit_of_model model =
    match Spice_provider.Model.context_window model with
    | None -> None
    | Some context_window ->
        let buffer =
          match Spice_provider.Model.max_output_tokens model with
          | None -> 20_000
          | Some value -> min 20_000 value
        in
        if context_window > buffer then Some (context_window - buffer) else None

  let auto_limit_reason model =
    match auto_limit_of_model model with
    | Some limit ->
        Printf.sprintf "auto limit %d from the declared context window" limit
    | None -> (
        match Spice_provider.Model.context_window model with
        | None -> "no declared context window; automatic compaction disabled"
        | Some _ ->
            "declared context window too small for an output buffer; automatic \
             compaction disabled")

  let of_model ?prelude model =
    let summary_max_output_tokens =
      match Spice_provider.Model.max_output_tokens model with
      | None -> 4096
      | Some value -> min value 4096
    in
    let auto_limit = auto_limit_of_model model in
    let keep_tokens =
      Option.map (fun limit -> min 8_000 (max 2_000 (limit / 4))) auto_limit
    in
    make
      ~model:(Spice_provider.Model.llm model)
      ?prelude ?auto_limit ?keep_tokens ~summary_max_output_tokens ()
end

module Pressure = struct
  type t = { projected_input : int; basis : Spice_protocol.Event.basis }

  (* A usage-grounded projection sums the reported replay usage and the estimate
     of messages appended since that baseline; without a baseline it estimates
     the full pending request, or the current transcript when none is given. *)
  let of_state ?request state =
    let projected_input, basis =
      match Spice_session.State.replay_usage state with
      | Some (usage, growth) ->
          ( Spice_llm.Usage.input_total usage
            + Spice_llm.Usage.output_total usage
            + Token_heuristic.messages growth,
            Spice_protocol.Event.Usage )
      | None -> (
          match request with
          | Some request ->
              (Token_heuristic.request request, Spice_protocol.Event.Estimate)
          | None ->
              ( Token_heuristic.messages
                  (Spice_llm.Transcript.messages
                     (Spice_session.State.transcript state)),
                Spice_protocol.Event.Estimate ))
    in
    { projected_input; basis }

  let projected_input t = t.projected_input
  let basis t = t.basis
end

type result = {
  document : Spice_session_store.Document.t;
  compaction : Spice_session.Compaction.t;
}
