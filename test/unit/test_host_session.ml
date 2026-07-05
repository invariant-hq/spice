(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit tests for the public compactor surface: policy derivation from catalog
   facts and the context-pressure projection. The effectful compaction
   workflows are covered by blackbox tests through the spice binary. *)

open Windtrap
module Compactor = Spice_host.Compactor
module Llm = Spice_llm
module Session = Spice_session
module State = Spice_session.State

let provider = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let llm_model = Llm.Model.make ~provider ~api ~id:"gpt-test"

let catalog_model ?context_window ?max_output_tokens () =
  Spice_provider.Model.make llm_model ?context_window ?max_output_tokens ()

let transcript messages =
  match Llm.Transcript.of_list messages with
  | Ok transcript -> transcript
  | Error error ->
      failf "transcript construction failed: %a" Llm.Transcript.Error.pp error

let state events =
  match State.of_events events with
  | Ok state -> state
  | Error error -> failf "state reconstruction failed: %a" State.Error.pp error

let turn ?(id = "turn-1") ?(input = "Refactor.") () =
  Session.Turn.make
    ~id:(Session.Turn.Id.of_string id)
    ~input:(Session.Turn.Input.user_text input)
    ~model:llm_model ()

let response ?usage text =
  Llm.Response.make ~model:llm_model ?usage (Llm.Message.Assistant.text text)

(* Policy.of_model *)

let of_model_reserves_output_headroom () =
  let policy =
    Compactor.Policy.of_model
      (catalog_model ~context_window:400_000 ~max_output_tokens:128_000 ())
  in
  equal (option int) ~msg:"limit reserves 20k of output headroom" (Some 380_000)
    (Compactor.Policy.auto_limit policy);
  equal (option int) ~msg:"summary output capped at 4096" (Some 4096)
    (Compactor.Policy.summary_max_output_tokens policy);
  equal
    (option (testable ~pp:Llm.Model.pp ~equal:Llm.Model.equal ()))
    ~msg:"summary model is the request model" (Some llm_model)
    (Compactor.Policy.model policy)

let of_model_small_output_cap () =
  let policy =
    Compactor.Policy.of_model
      (catalog_model ~context_window:100_000 ~max_output_tokens:2_000 ())
  in
  equal (option int) ~msg:"headroom is the declared cap when smaller"
    (Some 98_000)
    (Compactor.Policy.auto_limit policy);
  equal (option int) ~msg:"summary cap is the declared cap when smaller"
    (Some 2_000)
    (Compactor.Policy.summary_max_output_tokens policy)

let of_model_unknown_window_disables_auto () =
  let policy =
    Compactor.Policy.of_model (catalog_model ~max_output_tokens:128_000 ())
  in
  equal (option int) ~msg:"unknown window disables the automatic limit" None
    (Compactor.Policy.auto_limit policy);
  equal (option int) ~msg:"no limit means no tail budget" None
    (Compactor.Policy.keep_tokens policy)

let of_model_tiny_window_disables_auto () =
  let policy =
    Compactor.Policy.of_model (catalog_model ~context_window:10_000 ())
  in
  equal (option int) ~msg:"window at or under headroom disables the limit" None
    (Compactor.Policy.auto_limit policy)

(* Pressure.of_state *)

let pressure_estimate_basis_without_usage () =
  let state = state [ Session.Event.turn_started (turn ()) ] in
  let pressure = Compactor.Pressure.of_state state in
  is_true ~msg:"no baseline means the estimate basis"
    (Compactor.Pressure.basis pressure = Spice_protocol.Event.Estimate);
  is_true ~msg:"the projection is positive"
    (Compactor.Pressure.projected_input pressure > 0);
  let prelude =
    match Llm.Request.Prelude.make [ Llm.Message.system "Big prelude." ] with
    | Ok prelude -> prelude
    | Error error ->
        failf "prelude construction failed: %a" Llm.Request.Error.pp error
  in
  let request =
    match
      Llm.Request.make ~model:llm_model ~prelude
        (transcript [ Llm.Message.user_text "Refactor." ])
    with
    | Ok request -> request
    | Error error ->
        failf "request construction failed: %a" Llm.Request.Error.pp error
  in
  let widened = Compactor.Pressure.of_state ~request state in
  is_true
    ~msg:"a pending request widens the estimate basis by prelude and tools"
    (Compactor.Pressure.projected_input widened
    > Compactor.Pressure.projected_input pressure)

let pressure_usage_basis_grounds_projection () =
  let usage = Llm.Usage.make ~input:100 ~output:7 () in
  let baseline =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended (response ~usage "Done.");
      ]
  in
  let pressure = Compactor.Pressure.of_state baseline in
  is_true ~msg:"a baseline means the usage basis"
    (Compactor.Pressure.basis pressure = Spice_protocol.Event.Usage);
  equal int ~msg:"projection is exactly the baseline totals with no growth" 107
    (Compactor.Pressure.projected_input pressure);
  let grown =
    state
      [
        Session.Event.turn_started (turn ());
        Session.Event.response_appended (response ~usage "Done.");
        Session.Event.turn_finished
          ~turn:(Session.Turn.Id.of_string "turn-1")
          Session.Turn.Outcome.completed;
        Session.Event.turn_started (turn ~id:"turn-2" ~input:"Continue." ());
      ]
  in
  let grown_pressure = Compactor.Pressure.of_state grown in
  is_true ~msg:"growth raises the projection above the baseline totals"
    (Compactor.Pressure.projected_input grown_pressure > 107)

let () =
  run "spice.host.session"
    [
      test "of_model reserves output headroom" of_model_reserves_output_headroom;
      test "of_model uses the declared output cap when smaller"
        of_model_small_output_cap;
      test "of_model without a window disables the automatic limit"
        of_model_unknown_window_disables_auto;
      test "of_model with a tiny window disables the automatic limit"
        of_model_tiny_window_disables_auto;
      test "pressure without usage is estimate-based"
        pressure_estimate_basis_without_usage;
      test "pressure with usage grounds the projection"
        pressure_usage_basis_grounds_projection;
    ]
