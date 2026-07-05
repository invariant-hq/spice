(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Outside_workspace of Spice_path.Abs.t
  | Invalid_input of Spice_path.Error.t

let message = function
  | Outside_workspace path ->
      Format.asprintf "path is outside workspace: %a" Spice_path.Abs.pp path
  | Invalid_input error -> Spice_path.Error.message error

let equal a b =
  match (a, b) with
  | Outside_workspace a, Outside_workspace b -> Spice_path.Abs.equal a b
  | Invalid_input a, Invalid_input b -> Spice_path.Error.equal a b
  | (Outside_workspace _ | Invalid_input _), _ -> false

let pp ppf error = Format.pp_print_string ppf (message error)
