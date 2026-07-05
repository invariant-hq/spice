(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { program : string; args : string list }

let make ~program args =
  if String.equal program "" then
    invalid_arg "Spice_sandbox.Argv.make: program must not be empty";
  { program; args }

let program t = t.program
let args t = t.args
let to_list t = t.program :: t.args
