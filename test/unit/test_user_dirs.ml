(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module User_dirs = Spice_host.User_dirs

let getenv bindings name = List.assoc_opt name bindings

let path_result =
  testable
    ~pp:(fun ppf -> function
      | Ok path -> Format.fprintf ppf "Ok %S" path
      | Error error ->
          Format.fprintf ppf "Error %S" (User_dirs.Error.message error))
    ~equal:(fun left right ->
      match (left, right) with
      | Ok left, Ok right -> String.equal left right
      | Error left, Error right ->
          String.equal
            (User_dirs.Error.message left)
            (User_dirs.Error.message right)
      | Ok _, Error _ | Error _, Ok _ -> false)
    ()

let unix_xdg () =
  if String.equal Filename.dir_sep "\\" then ()
  else begin
    let env =
      getenv
        [
          ("HOME", "/home/test");
          ("XDG_DATA_HOME", "/var/data");
          ("XDG_STATE_HOME", "/var/state");
        ]
    in
    equal path_result ~msg:"XDG data" (Ok "/var/data/spice")
      (User_dirs.data_home env);
    equal path_result ~msg:"XDG state" (Ok "/var/state/spice")
      (User_dirs.state_home env)
  end

let home_fallback () =
  if String.equal Filename.dir_sep "\\" then ()
  else begin
    let env = getenv [ ("HOME", "/home/test") ] in
    equal path_result ~msg:"HOME data" (Ok "/home/test/.local/share/spice")
      (User_dirs.data_home env);
    equal path_result ~msg:"HOME state" (Ok "/home/test/.local/state/spice")
      (User_dirs.state_home env)
  end

let overrides () =
  let env =
    getenv
      [
        ("SPICE_DATA_HOME", "/custom/data");
        ("SPICE_STATE_HOME", "/custom/state");
      ]
  in
  equal path_result ~msg:"data override" (Ok "/custom/data")
    (User_dirs.data_home env);
  equal path_result ~msg:"state override" (Ok "/custom/state")
    (User_dirs.state_home env)

let config_roots () =
  let absolute = getenv [ ("SPICE_CONFIG_HOME", "/custom/config") ] in
  equal path_result ~msg:"config override" (Ok "/custom/config")
    (User_dirs.config_home absolute);
  if not (String.equal Filename.dir_sep "\\") then begin
    let xdg = getenv [ ("XDG_CONFIG_HOME", "/var/config") ] in
    equal path_result ~msg:"XDG config" (Ok "/var/config/spice")
      (User_dirs.config_home xdg);
    let home = getenv [ ("HOME", "/home/test") ] in
    equal path_result ~msg:"HOME config" (Ok "/home/test/.config/spice")
      (User_dirs.config_home home)
  end

let relative_override_rejected () =
  let env = getenv [ ("SPICE_DATA_HOME", "relative") ] in
  match User_dirs.data_home env with
  | Ok path -> failf "relative data override resolved to %S" path
  | Error error ->
      equal string ~msg:"responsible variable" "SPICE_DATA_HOME"
        (User_dirs.Error.variable error)

let relative_config_override_rejected () =
  let env =
    getenv
      [
        ("SPICE_CONFIG_HOME", "relative");
        ("XDG_CONFIG_HOME", "/otherwise-valid");
        ("HOME", "/home/test");
      ]
  in
  match User_dirs.config_home env with
  | Ok path -> failf "relative config override resolved to %S" path
  | Error error ->
      equal string ~msg:"responsible variable" "SPICE_CONFIG_HOME"
        (User_dirs.Error.variable error)

let missing_config_home_rejected () =
  if String.equal Filename.dir_sep "\\" then ()
  else
    match User_dirs.config_home (getenv []) with
    | Ok path -> failf "missing config HOME resolved to %S" path
    | Error error ->
        equal string ~msg:"responsible variable" "HOME"
          (User_dirs.Error.variable error)

let missing_home_rejected () =
  if String.equal Filename.dir_sep "\\" then ()
  else
    match User_dirs.state_home (getenv []) with
    | Ok path -> failf "missing HOME resolved to %S" path
    | Error error ->
        equal string ~msg:"responsible variable" "HOME"
          (User_dirs.Error.variable error)

let () =
  run "spice.host.user_dirs"
    [
      test "Unix XDG roots" unix_xdg;
      test "HOME fallbacks" home_fallback;
      test "absolute Spice overrides" overrides;
      test "config roots" config_roots;
      test "relative override is rejected" relative_override_rejected;
      test "relative config override is rejected"
        relative_config_override_rejected;
      test "missing fallback HOME is rejected" missing_home_rejected;
      test "missing config HOME is rejected" missing_config_home_rejected;
    ]
