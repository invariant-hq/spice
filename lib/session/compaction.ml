(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_session.Compaction" fn message

module Reason = struct
  type t =
    | User_requested
    | Context_pressure
    | Context_overflow
    | Model_downshift

  let equal a b = a = b

  let to_string = function
    | User_requested -> "user_requested"
    | Context_pressure -> "context_pressure"
    | Context_overflow -> "context_overflow"
    | Model_downshift -> "model_downshift"

  let pp ppf reason = Format.pp_print_string ppf (to_string reason)

  let jsont =
    Jsont.enum ~kind:"compaction reason"
      [
        ("user_requested", User_requested);
        ("context_pressure", Context_pressure);
        ("context_overflow", Context_overflow);
        ("model_downshift", Model_downshift);
      ]
end

let check_non_negative fn field = function
  | Some value when value < 0 -> invalid fn (field ^ " must be non-negative")
  | Some _ | None -> ()

module Token_estimate = struct
  type t = {
    before : int option;
    after : int option;
    summary_input : int option;
    summary_output : int option;
  }

  let make ?before ?after ?summary_input ?summary_output () =
    if
      Option.is_none before && Option.is_none after
      && Option.is_none summary_input
      && Option.is_none summary_output
    then invalid "Token_estimate.make" "at least one token count is required";
    check_non_negative "Token_estimate.make" "before" before;
    check_non_negative "Token_estimate.make" "after" after;
    check_non_negative "Token_estimate.make" "summary_input" summary_input;
    check_non_negative "Token_estimate.make" "summary_output" summary_output;
    { before; after; summary_input; summary_output }

  let before t = t.before
  let after t = t.after
  let summary_input t = t.summary_input
  let summary_output t = t.summary_output
  let equal a b = a = b

  let pp ppf t =
    Format.fprintf ppf
      "{ before = %a; after = %a; summary_input = %a; summary_output = %a }"
      (Format.pp_print_option Format.pp_print_int)
      t.before
      (Format.pp_print_option Format.pp_print_int)
      t.after
      (Format.pp_print_option Format.pp_print_int)
      t.summary_input
      (Format.pp_print_option Format.pp_print_int)
      t.summary_output

  let jsont =
    let make before after summary_input summary_output =
      decode_invalid_arg (fun () ->
          make ?before ?after ?summary_input ?summary_output ())
    in
    Jsont.Object.map ~kind:"compaction token estimate" make
    |> Jsont.Object.opt_mem "before" Jsont.int ~enc:before
    |> Jsont.Object.opt_mem "after" Jsont.int ~enc:after
    |> Jsont.Object.opt_mem "summary_input" Jsont.int ~enc:summary_input
    |> Jsont.Object.opt_mem "summary_output" Jsont.int ~enc:summary_output
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Range = struct
  type t = { summarized_messages : int; retained_tail_messages : int }

  let make ~summarized_messages ~retained_tail_messages =
    if summarized_messages < 0 then
      invalid "Range.make" "summarized_messages must be non-negative";
    if retained_tail_messages < 0 then
      invalid "Range.make" "retained_tail_messages must be non-negative";
    { summarized_messages; retained_tail_messages }

  let summarized_messages t = t.summarized_messages
  let retained_tail_messages t = t.retained_tail_messages
  let equal a b = a = b

  let pp ppf t =
    Format.fprintf ppf
      "{ summarized_messages = %d; retained_tail_messages = %d }"
      t.summarized_messages t.retained_tail_messages

  let jsont =
    let make summarized_messages retained_tail_messages =
      decode_invalid_arg (fun () ->
          make ~summarized_messages ~retained_tail_messages)
    in
    Jsont.Object.map ~kind:"compaction range" make
    |> Jsont.Object.mem "summarized_messages" Jsont.int ~enc:summarized_messages
    |> Jsont.Object.mem "retained_tail_messages" Jsont.int
         ~enc:retained_tail_messages
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  reason : Reason.t;
  summary : string;
  transcript : Spice_llm.Transcript.t;
  model : Spice_llm.Model.t option;
  tokens : Token_estimate.t option;
  range : Range.t option;
}

let make ~reason ~summary ~transcript ?model ?tokens ?range () =
  if String.is_empty summary then invalid "make" "summary must not be empty";
  begin match Spice_llm.Transcript.require_ready transcript with
  | Ok () -> ()
  | Error error ->
      invalid "make"
        (Format.asprintf "transcript must be request-ready: %a"
           Spice_llm.Transcript.Error.pp error)
  end;
  { reason; summary; transcript; model; tokens; range }

let reason t = t.reason
let summary t = t.summary
let transcript t = t.transcript
let model t = t.model
let tokens t = t.tokens
let range t = t.range
let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf "compaction(reason=%a, summary=%S)" Reason.pp t.reason
    t.summary

let jsont =
  Jsont.Object.map ~kind:"compaction"
    (fun reason summary transcript model tokens range ->
      decode_invalid_arg (fun () ->
          make ~reason ~summary ~transcript ?model ?tokens ?range ()))
  |> Jsont.Object.mem "reason" Reason.jsont ~enc:reason
  |> Jsont.Object.mem "summary" Jsont.string ~enc:summary
  |> Jsont.Object.mem "transcript" Spice_llm.Transcript.jsont ~enc:transcript
  |> Jsont.Object.opt_mem "model" Spice_llm.Model.jsont ~enc:model
  |> Jsont.Object.opt_mem "tokens" Token_estimate.jsont ~enc:tokens
  |> Jsont.Object.opt_mem "range" Range.jsont ~enc:range
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
