(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Raw byte encodings for terminal input. Feed to {!Pty.send}; the driver
   never schedules writes, so these carry no timing. *)

let enter = "\r"
let linefeed = "\n"
let ctrl_c = "\003"
let ctrl_o = "\015"
let ctrl_r = "\018"
let ctrl_w = "\023"
let escape = "\027"
let up = "\027[A"
let down = "\027[B"
let left = "\027[D"
let backspace = "\127"
let tab = "\t"
let bracketed_paste text = "\027[200~" ^ text ^ "\027[201~"
