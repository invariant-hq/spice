(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.sandbox.bubblewrap"
    ~doc:"Linux Bubblewrap availability and prefix generation"

module Log = (val Logs.src_log log_src : Logs.LOG)

let executable = "/usr/bin/bwrap"

type availability_error =
  | Wsl1_unsupported
  | Bubblewrap_not_found
  | Bubblewrap_probe_failed of string

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))

let is_linux () =
  String.equal Sys.os_type "Unix" && Sys.file_exists "/proc/sys/kernel/ostype"

let is_wsl1 () =
  if not (is_linux ()) then false
  else
    match read_file "/proc/version" with
    | version ->
        let version = String.lowercase_ascii version in
        String.includes ~affix:"microsoft" version
        && not (String.includes ~affix:"wsl2" version)
    | exception Sys_error _ -> false

let availability_error executable =
  if is_wsl1 () then Some Wsl1_unsupported
  else if not (Sys.file_exists executable) then Some Bubblewrap_not_found
  else None

let probe_argv executable =
  [|
    executable;
    "--unshare-user";
    "--unshare-pid";
    "--ro-bind";
    "/";
    "/";
    "--dev";
    "/dev";
    "--proc";
    "/proc";
    "--";
    "/bin/true";
  |]

let error_message executable = function
  | Wsl1_unsupported -> "Linux Bubblewrap unavailable: WSL1 is not supported"
  | Bubblewrap_not_found ->
      Printf.sprintf "Linux Bubblewrap unavailable: %s not found" executable
  | Bubblewrap_probe_failed reason ->
      "Linux Bubblewrap unavailable: probe failed: " ^ reason

let available ~executable ~probe () =
  match availability_error executable with
  | None -> (
      match probe ~executable ~argv:(probe_argv executable) with
      | Ok () ->
          Log.debug (fun m -> m "bubblewrap probe succeeded");
          Ok ()
      | Error reason ->
          Log.debug (fun m -> m "bubblewrap probe failed: %s" reason);
          Error
            (Error.unavailable
               (error_message executable (Bubblewrap_probe_failed reason))))
  | Some error -> Error (Error.unavailable (error_message executable error))

let path path = Spice_path.Abs.to_string path

(* Carveouts protect metadata (e.g. [.git]) that may not exist under a writable
   root — a fresh checkout, or a cache root added by config that has no such
   metadata. [--ro-bind] aborts the spawn on a missing source; the [-try]
   variant skips it, which is the right semantics: absent metadata needs no
   protection. The policy stays pure (it proves no existence); the backend
   tolerates absence at the platform boundary. *)
let bind_readable root = [ "--ro-bind"; path root; path root ]
let bind_protected root = [ "--ro-bind"; path root; path root ]
let bind_writable root = [ "--bind"; path root; path root ]

let filesystem_args policy =
  let read_args =
    match Policy.reads policy with
    | Some Policy.All -> [ "--ro-bind"; "/"; "/"; "--dev"; "/dev" ]
    | Some (Policy.Only roots) ->
        [ "--tmpfs"; "/"; "--dev"; "/dev" ]
        @ List.concat_map bind_readable roots
    | None -> assert false
  in
  let scratch = Policy.environment policy |> Environment.scratch in
  let roots = scratch :: Policy.writable_roots policy in
  let carveouts = Policy.protected_paths policy in
  read_args @ List.concat_map bind_writable roots
  @ List.concat_map bind_protected carveouts

let prefix policy =
  let namespace =
    [ "--new-session"; "--die-with-parent"; "--unshare-user"; "--unshare-pid" ]
  in
  let network =
    match Policy.network policy with
    | Some Policy.Network.Restricted -> [ "--unshare-net" ]
    | Some Policy.Network.Enabled -> []
    | None -> assert false
  in
  (executable :: namespace) @ filesystem_args policy @ network
  @ [ "--proc"; "/proc" ]

let prepare policy =
  let ( let* ) = Result.bind in
  let* () = Backend.validate_policy_paths policy in
  let prefix = prefix policy in
  Log.debug (fun m ->
      m "bubblewrap prefix built writable_roots=%d network=%s args=%d"
        (List.length (Policy.writable_roots policy))
        (match Policy.network policy with
        | Some Policy.Network.Restricted -> "restricted"
        | Some Policy.Network.Enabled -> "enabled"
        | None -> assert false)
        (List.length prefix));
  let hash_input = String.concat "\x00" prefix in
  Ok
    (Backend.prepared ~chdir:true ~prefix
       ~profile:(Spice_digest.string hash_input))

let make ~probe_executable ~probe () =
  Backend.make ~id:"linux-bubblewrap"
    ~available:(available ~executable:probe_executable ~probe)
    ~prepare ()
