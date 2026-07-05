(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

type t = int64

let invalid message = invalid_arg ("Spice_session.Time: " ^ message)

let of_unix_ms ms =
  if ms < 0L then invalid "timestamp must not be negative";
  ms

let of_unix_seconds_float seconds =
  if (not (Float.is_finite seconds)) || seconds < 0.0 then
    invalid "timestamp must be finite and non-negative";
  let ms = seconds *. 1_000.0 in
  if ms > Int64.to_float Int64.max_int then invalid "timestamp is too large";
  of_unix_ms (Int64.of_float ms)

let to_unix_ms t = t
let equal = Int64.equal
let compare = Int64.compare
let pp ppf t = Format.fprintf ppf "%Ld" t

let jsont =
  Jsont.map ~kind:"session time"
    ~dec:(fun ms ->
      if ms < 0L then decode_error "session time must not be negative" else ms)
    ~enc:to_unix_ms Jsont.int64
