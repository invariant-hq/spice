(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type kind =
  | Invalid_scope
  | Invalid_cursor
  | Invalid_file
  | Busy
  | Stale_snapshot

type t = { kind : kind; message : string }

let make kind message = { kind; message }
let kind t = t.kind
let message t = t.message
let pp ppf t = Format.pp_print_string ppf t.message
