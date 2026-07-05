(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_llm.Error" fn message

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let reject_empty_option fn field = function
  | None -> ()
  | Some value -> reject_empty fn field value

let is_label_char c =
  Char.Ascii.is_lower c || Char.Ascii.is_digit c || Char.equal c '_'

let check_label fn label =
  if String.is_empty label then invalid fn "label must not be empty";
  if not (Char.Ascii.is_lower label.[0]) then
    invalid fn "label must start with a lowercase ASCII letter";
  for i = 1 to String.length label - 1 do
    if not (is_label_char label.[i]) then
      invalid fn
        "label must contain only lowercase ASCII letters, digits, or '_'"
  done

let reserved_kind_labels =
  [
    "cancelled";
    "auth";
    "quota";
    "rate_limited";
    "context_overflow";
    "invalid_request";
    "unsupported";
    "content_policy";
    "transport";
    "timeout";
    "decode";
    "malformed_stream";
    "provider";
  ]

let check_other_kind_label fn label =
  check_label fn label;
  if List.exists (String.equal label) reserved_kind_labels then
    invalid fn ("reserved error kind label: " ^ label)

type phase = Startup | Stream

type kind =
  | Cancelled
  | Auth
  | Quota
  | Rate_limited
  | Context_overflow
  | Invalid_request
  | Unsupported
  | Content_policy
  | Transport
  | Timeout
  | Decode
  | Malformed_stream
  | Provider
  | Other of string

type t = {
  kind : kind;
  phase : phase;
  provider : Provider.t option;
  status : int option;
  request_id : string option;
  redacted_body : string option;
  message : string;
}

let check_kind = function
  | Other label -> check_other_kind_label "make" label
  | Cancelled | Auth | Quota | Rate_limited | Context_overflow | Invalid_request
  | Unsupported | Content_policy | Transport | Timeout | Decode
  | Malformed_stream | Provider ->
      ()

let check_status = function
  | None -> ()
  | Some status ->
      if status < 100 || status > 599 then
        invalid "make" "status must be in the range 100..599"

let make ~kind ?(phase = Startup) ?provider ?status ?request_id ?redacted_body
    message =
  reject_empty "make" "message" message;
  check_kind kind;
  check_status status;
  reject_empty_option "make" "request_id" request_id;
  reject_empty_option "make" "redacted_body" redacted_body;
  { kind; phase; provider; status; request_id; redacted_body; message }

let kind t = t.kind
let phase t = t.phase
let message t = t.message
let provider t = t.provider
let status t = t.status
let request_id t = t.request_id
let redacted_body t = t.redacted_body

let label = function
  | Cancelled -> "cancelled"
  | Auth -> "auth"
  | Quota -> "quota"
  | Rate_limited -> "rate_limited"
  | Context_overflow -> "context_overflow"
  | Invalid_request -> "invalid_request"
  | Unsupported -> "unsupported"
  | Content_policy -> "content_policy"
  | Transport -> "transport"
  | Timeout -> "timeout"
  | Decode -> "decode"
  | Malformed_stream -> "malformed_stream"
  | Provider -> "provider"
  | Other label -> label

let equal a b = a = b

let pp ppf t =
  match t.provider with
  | None -> Format.fprintf ppf "%s: %s" (label t.kind) t.message
  | Some provider ->
      Format.fprintf ppf "%a:%s: %s" Provider.pp provider (label t.kind)
        t.message

let phase_label = function Startup -> "startup" | Stream -> "stream"

let phase_of_label = function
  | "startup" -> Some Startup
  | "stream" -> Some Stream
  | _ -> None

let phase_jsont =
  Jsont.map ~kind:"LLM error phase"
    ~dec:(fun label ->
      match phase_of_label label with
      | Some phase -> phase
      | None -> decode_error "invalid error phase")
    ~enc:phase_label Jsont.string

let kind_of_label = function
  | "cancelled" -> Some Cancelled
  | "auth" -> Some Auth
  | "quota" -> Some Quota
  | "rate_limited" -> Some Rate_limited
  | "context_overflow" -> Some Context_overflow
  | "invalid_request" -> Some Invalid_request
  | "unsupported" -> Some Unsupported
  | "content_policy" -> Some Content_policy
  | "transport" -> Some Transport
  | "timeout" -> Some Timeout
  | "decode" -> Some Decode
  | "malformed_stream" -> Some Malformed_stream
  | "provider" -> Some Provider
  | label -> (
      try
        check_other_kind_label "kind_of_label" label;
        Some (Other label)
      with Invalid_argument _ -> None)

let kind_jsont =
  Jsont.map ~kind:"LLM error kind"
    ~dec:(fun label ->
      match kind_of_label label with
      | Some kind -> kind
      | None -> decode_error "invalid error kind")
    ~enc:label Jsont.string

let jsont =
  let make kind phase provider status request_id redacted_body message =
    decode_invalid_arg (fun () ->
        make ~kind ~phase ?provider ?status ?request_id ?redacted_body message)
  in
  Jsont.Object.map ~kind:"LLM error" make
  |> Jsont.Object.mem "kind" kind_jsont ~enc:kind
  |> Jsont.Object.mem "phase" phase_jsont ~enc:phase
  |> Jsont.Object.opt_mem "provider" Provider.jsont ~enc:provider
  |> Jsont.Object.opt_mem "status" Jsont.int ~enc:status
  |> Jsont.Object.opt_mem "request_id" Jsont.string ~enc:request_id
  |> Jsont.Object.opt_mem "redacted_body" Jsont.string ~enc:redacted_body
  |> Jsont.Object.mem "message" Jsont.string ~enc:message
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
