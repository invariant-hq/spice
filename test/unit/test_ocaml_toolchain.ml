(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Toolchain = Spice_ocaml_toolchain

let lookup_of pairs name = List.assoc_opt name pairs

let contains ~affix s =
  let al = String.length affix and sl = String.length s in
  let rec loop i =
    if i + al > sl then false
    else if String.equal (String.sub s i al) affix then true
    else loop (i + 1)
  in
  al = 0 || loop 0

let bin_dir_recovery () =
  equal (option string) ~msg:"DUNE_OCAML_STDLIB yields <prefix>/bin"
    (Some (Filename.concat "/opt/sw" "bin"))
    (Toolchain.bin_dir
       ~lookup:(lookup_of [ ("DUNE_OCAML_STDLIB", "/opt/sw/lib/ocaml") ]));
  equal (option string) ~msg:"OPAM_SWITCH_PREFIX yields <prefix>/bin"
    (Some (Filename.concat "/opt/sw" "bin"))
    (Toolchain.bin_dir
       ~lookup:(lookup_of [ ("OPAM_SWITCH_PREFIX", "/opt/sw") ]));
  equal (option string) ~msg:"DUNE_OCAML_STDLIB wins over OPAM_SWITCH_PREFIX"
    (Some (Filename.concat "/dune" "bin"))
    (Toolchain.bin_dir
       ~lookup:
         (lookup_of
            [
              ("DUNE_OCAML_STDLIB", "/dune/lib/ocaml");
              ("OPAM_SWITCH_PREFIX", "/opam");
            ]));
  equal (option string) ~msg:"no locators, no recovery" None
    (Toolchain.bin_dir ~lookup:(lookup_of []));
  equal (option string) ~msg:"empty values do not recover" None
    (Toolchain.bin_dir
       ~lookup:(lookup_of [ ("DUNE_OCAML_STDLIB", ""); ("OPAM_SWITCH_PREFIX", "") ]))

(* A directory with one executable, used to exercise the filesystem-touching
   resolution against real files rather than a mocked layout. *)
let with_toolchain_bin f =
  let root = Filename.temp_dir "spice_tc" "" in
  let bin = Filename.concat root "bin" in
  Unix.mkdir bin 0o755;
  let tool = Filename.concat bin "faketool" in
  let oc = open_out tool in
  output_string oc "#!/bin/sh\n";
  close_out oc;
  Unix.chmod tool 0o755;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove tool;
      Unix.rmdir bin;
      Unix.rmdir root)
    (fun () -> f ~root ~bin ~tool)

let resolution () =
  with_toolchain_bin @@ fun ~root ~bin ~tool ->
  is_true ~msg:"resolves on its own dir"
    (Toolchain.resolves_on_path ~path:bin "faketool");
  is_true ~msg:"does not resolve on an empty PATH"
    (not (Toolchain.resolves_on_path ~path:"/no/such/dir" "faketool"));
  is_true ~msg:"missing program does not resolve"
    (not (Toolchain.resolves_on_path ~path:bin "absent"));
  ignore root;
  ignore tool

let augment_prepends_recovered_bin () =
  with_toolchain_bin @@ fun ~root ~bin ~tool ->
  (* [faketool] is not on this PATH, but the switch prefix is recoverable, so
     [augment] prepends its [bin]. *)
  let env = [| "PATH=/no/such/dir"; "OPAM_SWITCH_PREFIX=" ^ root |] in
  let augmented = Toolchain.augment env ~program:"faketool" in
  let path =
    Array.find_map
      (fun b ->
        match String.index_opt b '=' with
        | Some i when String.sub b 0 i = "PATH" ->
            Some (String.sub b (i + 1) (String.length b - i - 1))
        | _ -> None)
      augmented
  in
  equal (option string) ~msg:"recovered bin prepended to PATH"
    (Some (bin ^ ":/no/such/dir"))
    path;
  ignore tool

let augment_is_noop_when_reachable () =
  with_toolchain_bin @@ fun ~root ~bin ~tool ->
  (* Already on PATH: [augment] must not touch the environment, so it can never
     shadow a reachable toolchain. *)
  let env = [| "PATH=" ^ bin; "OPAM_SWITCH_PREFIX=/other" |] in
  let augmented = Toolchain.augment env ~program:"faketool" in
  is_true ~msg:"env unchanged when program already resolves" (env == augmented);
  ignore root;
  ignore tool

let locate_pins_absolute () =
  with_toolchain_bin @@ fun ~root ~bin ~tool ->
  let env = [| "PATH=/no/such/dir"; "OPAM_SWITCH_PREFIX=" ^ root |] in
  let _, exe = Toolchain.locate env ~program:"faketool" in
  equal (option string) ~msg:"locate pins the absolute recovered path"
    (Some tool) exe;
  let _, absent = Toolchain.locate env ~program:"absent" in
  equal (option string) ~msg:"unresolvable program has no absolute path" None
    absent;
  let _, with_sep = Toolchain.locate env ~program:"/bin/faketool" in
  equal (option string) ~msg:"a program with a separator is left to the caller"
    None with_sep;
  ignore bin

let hint_names_the_program () =
  let hint = Toolchain.unreachable_hint ~program:"dune" in
  is_true ~msg:"hint names the program"
    (contains ~affix:"dune" hint && contains ~affix:"PATH" hint)

let () =
  run "spice.ocaml.toolchain"
    [
      test "bin_dir recovery precedence" bin_dir_recovery;
      test "resolution on PATH" resolution;
      test "augment prepends recovered bin" augment_prepends_recovered_bin;
      test "augment is a no-op when reachable" augment_is_noop_when_reachable;
      test "locate pins the absolute path" locate_pins_absolute;
      test "unreachable hint names the program" hint_names_the_program;
    ]
