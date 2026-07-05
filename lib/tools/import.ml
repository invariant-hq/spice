(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Dependency vocabulary *)
module Json = Jsont.Json
module Edit = Spice_edit
module Permission = Spice_permission
module Tool = Spice_tool
module Workspace = Spice_workspace
module Fs = Spice_workspace_fs

(* House helpers — keep byte-identical across lib/*/import.ml copies. *)

let invalid_arg' m fn msg = invalid_arg (m ^ "." ^ fn ^ ": " ^ msg)
let decode_error message = Jsont.Error.msg Jsont.Meta.none message

let decode_invalid_arg f =
  match f () with
  | value -> value
  | exception Invalid_argument message -> decode_error message
