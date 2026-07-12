(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.sandbox.seatbelt"
    ~doc:"macOS Seatbelt profile generation"

module Log = (val Logs.src_log log_src : Logs.LOG)

let executable = "/usr/bin/sandbox-exec"

(* Ported from the Codex reference agent's seatbelt_base_policy.sbpl, itself
   derived from Chrome's macOS sandbox policy. Production-proven base
   allowances: process exec/fork, /dev/null, sysctls, PTYs, and read-only
   user preferences. *)
let base_policy =
  {|(version 1)

; start with closed-by-default
(deny default)

; allow read-only file operations
(allow file-read*)

; child processes inherit the policy of their parent
(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))

; process-info
(allow process-info* (target same-sandbox))

(allow file-write-data
  (require-all
    (path "/dev/null")
    (vnode-type CHARACTER-DEVICE)))

; sysctls permitted.
(allow sysctl-read
  (sysctl-name "hw.activecpu")
  (sysctl-name "hw.busfrequency_compat")
  (sysctl-name "hw.byteorder")
  (sysctl-name "hw.cacheconfig")
  (sysctl-name "hw.cachelinesize_compat")
  (sysctl-name "hw.cpufamily")
  (sysctl-name "hw.cpufrequency_compat")
  (sysctl-name "hw.cputype")
  (sysctl-name "hw.l1dcachesize_compat")
  (sysctl-name "hw.l1icachesize_compat")
  (sysctl-name "hw.l2cachesize_compat")
  (sysctl-name "hw.l3cachesize_compat")
  (sysctl-name "hw.logicalcpu_max")
  (sysctl-name "hw.machine")
  (sysctl-name "hw.model")
  (sysctl-name "hw.memsize")
  (sysctl-name "hw.ncpu")
  (sysctl-name "hw.nperflevels")
  (sysctl-name-prefix "hw.optional.arm.")
  (sysctl-name-prefix "hw.optional.armv8_")
  (sysctl-name "hw.packages")
  (sysctl-name "hw.pagesize_compat")
  (sysctl-name "hw.pagesize")
  (sysctl-name "hw.physicalcpu")
  (sysctl-name "hw.physicalcpu_max")
  (sysctl-name "hw.logicalcpu")
  (sysctl-name "hw.cpufrequency")
  (sysctl-name "hw.tbfrequency_compat")
  (sysctl-name "hw.vectorunit")
  (sysctl-name "machdep.cpu.brand_string")
  (sysctl-name "kern.argmax")
  (sysctl-name "kern.hostname")
  (sysctl-name "kern.maxfilesperproc")
  (sysctl-name "kern.maxproc")
  (sysctl-name "kern.osproductversion")
  (sysctl-name "kern.osrelease")
  (sysctl-name "kern.ostype")
  (sysctl-name "kern.osvariant_status")
  (sysctl-name "kern.osversion")
  (sysctl-name "kern.secure_kernel")
  (sysctl-name "kern.usrstack64")
  (sysctl-name "kern.version")
  (sysctl-name "sysctl.proc_cputype")
  (sysctl-name "vm.loadavg")
  (sysctl-name-prefix "hw.perflevel")
  (sysctl-name-prefix "kern.proc.pgrp.")
  (sysctl-name-prefix "kern.proc.pid.")
  (sysctl-name-prefix "net.routetable.")
)

; Allow Java to read some CPU info. This is misclassified as a "write" because
; userspace passes a memory buffer to the sysctl, but conceptually it is a read.
(allow sysctl-write
  (sysctl-name "kern.grade_cputype"))

; IOKit
(allow iokit-open
  (iokit-registry-entry-class "RootDomainUserClient")
)

; needed to look up user info
(allow mach-lookup
  (global-name "com.apple.system.opendirectoryd.libinfo")
)

; Needed for python multiprocessing on MacOS for the SemLock
(allow ipc-posix-sem)

; Needed for PyTorch/libomp on macOS to register OpenMP runtimes.
(allow ipc-posix-shm-read-data
  ipc-posix-shm-write-create
  ipc-posix-shm-write-unlink
  (ipc-posix-name-regex #"^/__KMP_REGISTERED_LIB_[0-9]+$"))

(allow mach-lookup
  (global-name "com.apple.PowerManagement.control")
)

; allow openpty()
(allow pseudo-tty)
(allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
(allow file-read* file-write*
  (require-all
    (regex #"^/dev/ttys[0-9]+")
    (extension "com.apple.sandbox.pty")))
; PTYs created before entering seatbelt may lack the extension; allow ioctl
; on those slave ttys so interactive shells detect a TTY and remain functional.
(allow file-ioctl (regex #"^/dev/ttys[0-9]+"))

; allow readonly user preferences
(allow ipc-posix-shm-read* (ipc-posix-name-prefix "apple.cfprefs."))
(allow mach-lookup
  (global-name "com.apple.cfprefsd.daemon")
  (global-name "com.apple.cfprefsd.agent")
  (local-name "com.apple.cfprefsd.agent"))
(allow user-preference-read)|}

(* Ported from the Codex reference agent's seatbelt_network_policy.sbpl:
   platform services TLS, DNS, and network configuration need beyond raw
   socket access when the policy enables network. *)
let network_policy =
  {|; allow only safe AF_SYSTEM sockets used for local platform services.
(allow system-socket
  (require-all
    (socket-domain AF_SYSTEM)
    (socket-protocol 2)
  )
)

(allow mach-lookup
    ; Used by platform helpers that resolve user directory locations.
    (global-name "com.apple.bsd.dirhelper")
    (global-name "com.apple.system.opendirectoryd.membership")

    ; Communicate with the security server for TLS certificate information.
    (global-name "com.apple.SecurityServer")
    (global-name "com.apple.networkd")
    (global-name "com.apple.ocspd")
    (global-name "com.apple.trustd.agent")

    ; Read network configuration.
    (global-name "com.apple.SystemConfiguration.DNSConfiguration")
    (global-name "com.apple.SystemConfiguration.configd")
)

(allow sysctl-read
  (sysctl-name-regex #"^net.routetable")
)|}

let writable_param index = Printf.sprintf "WRITABLE_ROOT_%d" index

let excluded_param index excluded_index =
  Printf.sprintf "WRITABLE_ROOT_%d_EXCLUDED_%d" index excluded_index

let file_write_policy policy =
  match Policy.writable_roots policy with
  | [] -> ("", [])
  | roots ->
      let carveouts = Policy.write_carveouts policy in
      let components, params =
        List.fold_left
          (fun (components, params) root ->
            let index = List.length components in
            let root_param = writable_param index in
            let params =
              (root_param, Spice_path.Abs.to_string root) :: params
            in
            let excluded =
              List.filter
                (fun path ->
                  Option.is_some (Spice_path.Abs.relativize ~root path))
                carveouts
            in
            let excluded_parts, params =
              List.fold_left
                (fun (parts, params) path ->
                  let param = excluded_param index (List.length parts / 2) in
                  let params =
                    (param, Spice_path.Abs.to_string path) :: params
                  in
                  ( parts
                    @ [
                        Printf.sprintf "(require-not (literal (param \"%s\")))"
                          param;
                        Printf.sprintf "(require-not (subpath (param \"%s\")))"
                          param;
                      ],
                    params ))
                ([], params) excluded
            in
            let parts =
              Printf.sprintf "(subpath (param \"%s\"))" root_param
              :: excluded_parts
            in
            let component =
              match parts with
              | [ only ] -> only
              | parts ->
                  Printf.sprintf "(require-all %s )" (String.concat " " parts)
            in
            (components @ [ component ], params))
          ([], []) roots
      in
      ( Printf.sprintf "(allow file-write*\n%s\n)" (String.concat " " components),
        List.rev params )

let network_section policy =
  match Policy.network policy with
  | Some Policy.Network.Restricted -> ""
  | Some Policy.Network.Enabled ->
      Printf.sprintf "(allow network-outbound)\n(allow network-inbound)\n%s"
        network_policy
  | None -> assert false

let profile policy =
  let write_policy, params = file_write_policy policy in
  let sections =
    List.filter
      (fun section -> not (String.equal section ""))
      [ base_policy; write_policy; network_section policy ]
  in
  (String.concat "\n" sections, params)

let unavailable_reason () =
  if Sys.file_exists executable then None
  else
    Some (Printf.sprintf "macOS Seatbelt unavailable: %s not found" executable)

let available () =
  match unavailable_reason () with
  | None -> Ok ()
  | Some reason -> Error (Error.unavailable reason)

(* The profile is generated exactly once per preparation; the wrapper is a
   pure prefix application, and the hash digests the same generated text the
   commands run under. *)
let prepare policy =
  match unavailable_reason () with
  | Some reason -> Error (Error.unavailable reason)
  | None ->
      let profile, params = profile policy in
      Log.debug (fun m ->
          m
            "seatbelt profile generated writable_roots=%d network=%s bytes=%d \
             params=%d"
            (List.length (Policy.writable_roots policy))
            (match Policy.network policy with
            | Some Policy.Network.Restricted -> "restricted"
            | Some Policy.Network.Enabled -> "enabled"
            | None -> assert false)
            (String.length profile) (List.length params));
      let prefix =
        (executable :: [ "-p"; profile ])
        @ List.map (fun (key, value) -> "-D" ^ key ^ "=" ^ value) params
        @ [ "--" ]
      in
      let canonical =
        String.concat "\x00"
          (profile :: List.map (fun (key, value) -> key ^ "=" ^ value) params)
      in
      Ok (Backend.prepared ~prefix ~profile:(Spice_digest.string canonical))

let backend = Backend.make ~id:"macos-seatbelt" ~available ~prepare ()
