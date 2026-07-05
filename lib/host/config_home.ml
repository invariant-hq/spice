(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type getenv = string -> string option

(* Only absolute overrides are honoured; a relative [SPICE_CONFIG_HOME],
   [APPDATA], or [XDG_CONFIG_HOME] falls through to the next source. *)
let is_absolute path = not (Filename.is_relative path)
let of_home home = Filename.concat (Filename.concat home ".config") "spice"

let fallback getenv =
  match getenv "HOME" with
  | Some home -> of_home home
  | None -> Filename.concat (Filename.concat "." ".config") "spice"

let platform getenv =
  if String.equal Filename.dir_sep "\\" then
    match getenv "APPDATA" with
    | Some path when is_absolute path -> Filename.concat path "spice"
    | Some _ | None -> fallback getenv
  else
    match getenv "XDG_CONFIG_HOME" with
    | Some path when is_absolute path -> Filename.concat path "spice"
    | Some _ | None -> fallback getenv

let path getenv =
  match getenv "SPICE_CONFIG_HOME" with
  | Some path when is_absolute path -> path
  | Some _ | None -> platform getenv

let config_path getenv = Filename.concat (path getenv) "config.json"
let auth_store_path getenv = Filename.concat (path getenv) "auth.json"
let trust_store_path getenv = Filename.concat (path getenv) "trust.json"
