(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = Build | Plan | Review

let default = Build

type parse_error = { input : string; candidates : string list }

let to_string = function
  | Build -> "build"
  | Plan -> "plan"
  | Review -> "review"

let spellings = List.map to_string [ Build; Plan; Review ]

let of_string = function
  | "build" -> Ok Build
  | "plan" -> Ok Plan
  | "review" -> Ok Review
  | input -> Error { input; candidates = spellings }

let of_turn turn =
  match Spice_session.Turn.mode turn with
  | None -> default
  | Some raw -> (
      match of_string raw with
      | Ok mode -> mode
      | Error (_ : parse_error) -> default)

let equal a b = a = b
let pp ppf t = Format.pp_print_string ppf (to_string t)

let contract = function
  | Build -> Contract.unrestricted
  | Plan | Review -> Contract.read_only

let developer text = Spice_llm.Message.developer text

let prelude_messages = function
  | Build -> []
  | Plan -> [ developer Spice_prompts.Modes.plan ]
  | Review -> [ developer Spice_prompts.Modes.review ]

let host_tools = function
  | Build ->
      [
        Call.Kind.Question;
        Call.Kind.Todo;
        Call.Kind.Goal;
        Call.Kind.Subagent;
        Call.Kind.Subagent_wait;
        Call.Kind.Subagent_cancel;
        Call.Kind.Subagent_message;
      ]
  | Plan ->
      [
        Call.Kind.Question;
        Call.Kind.Plan;
        Call.Kind.Subagent;
        Call.Kind.Subagent_wait;
        Call.Kind.Subagent_cancel;
        Call.Kind.Subagent_message;
      ]
  | Review ->
      [
        Call.Kind.Question;
        Call.Kind.Subagent;
        Call.Kind.Subagent_wait;
        Call.Kind.Subagent_cancel;
        Call.Kind.Subagent_message;
      ]

let all_host_tools = List.map Call.Kind.tool Call.Kind.all

let allows_role mode role =
  match (mode, role) with
  | Build, (Subagent.Role.Explore | Subagent.Role.Review | Subagent.Role.Verify)
    ->
      true
  | (Plan | Review), Subagent.Role.Explore -> true
  | (Plan | Review), (Subagent.Role.Review | Subagent.Role.Verify) -> false
