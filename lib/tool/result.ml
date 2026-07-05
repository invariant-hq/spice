(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = invalid_arg ("Spice_tool.Result." ^ fn ^ ": " ^ message)

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

type failure =
  [ `Invalid_input
  | `Permission_denied
  | `Not_found
  | `Stale
  | `Unavailable
  | `Timed_out
  | `Failed ]

type status =
  | Completed
  | Failed of { kind : failure; message : string; metadata : Jsont.json option }
  | Interrupted of { reason : string; cancelled : bool }

type 'a t = { status : status; output : 'a option }

let completed ~output () = { status = Completed; output = Some output }

let failed ?output ?metadata kind message =
  reject_empty "failed" "message" message;
  { status = Failed { kind; message; metadata }; output }

let interrupted ?output ~reason ~cancelled () =
  reject_empty "interrupted" "reason" reason;
  { status = Interrupted { reason; cancelled }; output }

let status t = t.status
let output t = t.output

let message t =
  match t.status with
  | Completed -> None
  | Failed { message; kind = _; metadata = _ } -> Some message
  | Interrupted { reason; cancelled = _ } -> Some reason

let failure_to_string = function
  | `Invalid_input -> "invalid_input"
  | `Permission_denied -> "permission_denied"
  | `Not_found -> "not_found"
  | `Stale -> "stale"
  | `Unavailable -> "unavailable"
  | `Timed_out -> "timed_out"
  | `Failed -> "failed"

let failure_of_string = function
  | "invalid_input" -> Some `Invalid_input
  | "permission_denied" -> Some `Permission_denied
  | "not_found" -> Some `Not_found
  | "stale" -> Some `Stale
  | "unavailable" -> Some `Unavailable
  | "timed_out" -> Some `Timed_out
  | "failed" -> Some `Failed
  | _ -> None
