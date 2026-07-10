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
   protection. Confinement stays pure (it proves no existence); the backend
   tolerates absence at the platform boundary. *)
let bind_read_only root = [ "--ro-bind-try"; path root; path root ]
let bind_writable root = [ "--bind"; path root; path root ]
let existing root = Sys.file_exists (path root)

(* The whole host root is bound read-only, so every [PATH] directory — including
   a [$HOME]-based toolchain such as [~/.opam/<switch>/bin] — is readable and its
   binaries are executable inside the sandbox. This full-read policy is what keeps
   a user's [dune]/[ocamlmerlin] reachable under confinement. A future restricted
   read mode must preserve the principle it rests on: any [PATH] directory holding
   a required toolchain binary has to be a readable root, or confined commands
   lose the toolchain. *)
let filesystem_args policy =
  let roots = List.filter existing (Confinement.writable_roots policy) in
  let carveouts = Confinement.write_carveouts policy in
  [ "--ro-bind"; "/"; "/"; "--dev"; "/dev" ]
  @ List.concat_map bind_writable roots
  @ List.concat_map bind_read_only carveouts

let prefix policy =
  let namespace =
    [ "--new-session"; "--die-with-parent"; "--unshare-user"; "--unshare-pid" ]
  in
  let network =
    match Confinement.network_state policy with
    | Confinement.Restricted -> [ "--unshare-net" ]
    | Confinement.Enabled -> []
  in
  (executable :: namespace) @ filesystem_args policy @ network
  @ [ "--proc"; "/proc"; "--" ]

let prepare policy =
  let prefix = prefix policy in
  Log.debug (fun m ->
      m "bubblewrap prefix built writable_roots=%d network=%s args=%d"
        (List.length (Confinement.writable_roots policy))
        (match Confinement.network_state policy with
        | Confinement.Restricted -> "restricted"
        | Confinement.Enabled -> "enabled")
        (List.length prefix));
  let hash_input = String.concat "\x00" prefix in
  Ok (Backend.prepared ~prefix ~profile:(Spice_digest.string hash_input))

let make ~probe_executable ~probe () =
  Backend.make ~id:"linux-bubblewrap"
    ~available:(available ~executable:probe_executable ~probe)
    ~prepare ()
