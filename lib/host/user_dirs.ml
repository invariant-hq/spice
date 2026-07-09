(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type getenv = string -> string option

module Error = struct
  type t = { variable : string; value : string; message : string }

  let make ~variable ~value message = { variable; value; message }
  let variable t = t.variable
  let value t = t.value
  let message t = t.message
  let pp ppf t = Format.pp_print_string ppf t.message
end

let is_absolute path = not (Filename.is_relative path)
let ( / ) = Filename.concat
let spice base = base / "spice"

let home getenv =
  match getenv "HOME" with
  | Some home when is_absolute home -> Some home
  | Some _ | None -> None

let config_fallback getenv =
  match home getenv with
  | Some home -> spice (home / ".config")
  | None -> "." / ".config" / "spice"

let config_home getenv =
  match getenv "SPICE_CONFIG_HOME" with
  | Some path when is_absolute path -> path
  | Some _ | None -> (
      if String.equal Filename.dir_sep "\\" then
        match getenv "APPDATA" with
        | Some path when is_absolute path -> spice path
        | Some _ | None -> config_fallback getenv
      else
        match getenv "XDG_CONFIG_HOME" with
        | Some path when is_absolute path -> spice path
        | Some _ | None -> config_fallback getenv)

let invalid_override variable value =
  Error
    (Error.make ~variable ~value
       (Printf.sprintf "%s must be an absolute path: %s" variable value))

let missing_home ~kind ~override =
  Error
    (Error.make ~variable:"HOME" ~value:""
       (Printf.sprintf
          "cannot determine Spice %s home; set %s or an absolute HOME" kind
          override))

let data_home getenv =
  match getenv "SPICE_DATA_HOME" with
  | Some path when is_absolute path -> Ok path
  | Some path -> invalid_override "SPICE_DATA_HOME" path
  | None -> (
      if String.equal Filename.dir_sep "\\" then
        match getenv "LOCALAPPDATA" with
        | Some path when is_absolute path -> Ok (spice path)
        | Some path -> invalid_override "LOCALAPPDATA" path
        | None -> (
            match getenv "APPDATA" with
            | Some path when is_absolute path -> Ok (path / "spice" / "data")
            | Some path -> invalid_override "APPDATA" path
            | None -> (
                match home getenv with
                | Some home -> Ok (home / ".local" / "share" / "spice")
                | None -> missing_home ~kind:"data" ~override:"SPICE_DATA_HOME")
            )
      else
        match getenv "XDG_DATA_HOME" with
        | Some path when is_absolute path -> Ok (spice path)
        | Some path -> invalid_override "XDG_DATA_HOME" path
        | None -> (
            match home getenv with
            | Some home -> Ok (home / ".local" / "share" / "spice")
            | None -> missing_home ~kind:"data" ~override:"SPICE_DATA_HOME"))

let state_home getenv =
  match getenv "SPICE_STATE_HOME" with
  | Some path when is_absolute path -> Ok path
  | Some path -> invalid_override "SPICE_STATE_HOME" path
  | None -> (
      if String.equal Filename.dir_sep "\\" then
        match getenv "LOCALAPPDATA" with
        | Some path when is_absolute path -> Ok (path / "spice" / "state")
        | Some path -> invalid_override "LOCALAPPDATA" path
        | None -> (
            match getenv "APPDATA" with
            | Some path when is_absolute path -> Ok (path / "spice" / "state")
            | Some path -> invalid_override "APPDATA" path
            | None -> (
                match home getenv with
                | Some home -> Ok (home / ".local" / "state" / "spice")
                | None ->
                    missing_home ~kind:"state" ~override:"SPICE_STATE_HOME"))
      else
        match getenv "XDG_STATE_HOME" with
        | Some path when is_absolute path -> Ok (spice path)
        | Some path -> invalid_override "XDG_STATE_HOME" path
        | None -> (
            match home getenv with
            | Some home -> Ok (home / ".local" / "state" / "spice")
            | None -> missing_home ~kind:"state" ~override:"SPICE_STATE_HOME"))

let config_path getenv = config_home getenv / "config.json"
let auth_store_path getenv = config_home getenv / "auth.json"
let trust_store_path getenv = config_home getenv / "trust.json"
