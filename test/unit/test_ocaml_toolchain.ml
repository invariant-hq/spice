(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Toolchain = Spice_ocaml_toolchain

let contains ~affix s =
  let al = String.length affix and sl = String.length s in
  let rec loop i =
    if i + al > sl then false
    else if String.equal (String.sub s i al) affix then true
    else loop (i + 1)
  in
  al = 0 || loop 0

let env_path env =
  Array.find_map
    (fun b ->
      match String.index_opt b '=' with
      | Some i when String.sub b 0 i = "PATH" ->
          Some (String.sub b (i + 1) (String.length b - i - 1))
      | _ -> None)
    env

(* Real switch layouts on disk: resolution is filesystem-touching, so the
   ladder is exercised against actual executables rather than a mocked view. *)
let make_exe dir name =
  let exe = Filename.concat dir name in
  let oc = open_out exe in
  output_string oc "#!/bin/sh\n";
  close_out oc;
  Unix.chmod exe 0o755;
  exe

let rec remove_tree path =
  if Sys.is_directory path then (
    Array.iter
      (fun e -> remove_tree (Filename.concat path e))
      (Sys.readdir path);
    Unix.rmdir path)
  else Sys.remove path

let with_layout f =
  let root = Filename.temp_dir "spice_tc" "" in
  let mkdir_p dir =
    ignore
      (List.fold_left
         (fun acc part ->
           let acc = Filename.concat acc part in
           (match Unix.mkdir acc 0o755 with
           | () -> ()
           | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ());
           acc)
         root
         (String.split_on_char '/' dir))
  in
  mkdir_p "path_bin";
  mkdir_p "switch/bin";
  mkdir_p "project/_opam/bin";
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      f
        ~path_bin:(Filename.concat root "path_bin")
        ~switch:(Filename.concat root "switch")
        ~project:(Filename.concat root "project"))

let discover ?(bindings = []) ?workspace_root () =
  Toolchain.discover
    ~env:(Array.of_list (List.map (fun (n, v) -> n ^ "=" ^ v) bindings))
    ~workspace_root

let ladder_order () =
  with_layout @@ fun ~path_bin ~switch ~project ->
  let on_path = make_exe path_bin "faketool" in
  let in_switch = make_exe (Filename.concat switch "bin") "faketool" in
  let in_local =
    make_exe
      (Filename.concat (Filename.concat project "_opam") "bin")
      "faketool"
  in
  let all =
    discover
      ~bindings:[ ("PATH", path_bin); ("OPAM_SWITCH_PREFIX", switch) ]
      ~workspace_root:project ()
  in
  equal
    (option (pair string string))
    ~msg:"PATH wins over both opam rungs"
    (Some (on_path, "PATH"))
    (Toolchain.find all "faketool"
    |> Option.map (fun (exe, s) -> (exe, Toolchain.Source.to_string s)));
  let no_path =
    discover
      ~bindings:[ ("PATH", "/no/such/dir"); ("OPAM_SWITCH_PREFIX", switch) ]
      ~workspace_root:project ()
  in
  equal
    (option (pair string string))
    ~msg:"OPAM_SWITCH_PREFIX wins over the local switch"
    (Some (in_switch, "OPAM_SWITCH_PREFIX"))
    (Toolchain.find no_path "faketool"
    |> Option.map (fun (exe, s) -> (exe, Toolchain.Source.to_string s)));
  let local_only =
    discover ~bindings:[ ("PATH", "/no/such/dir") ] ~workspace_root:project ()
  in
  equal
    (option (pair string string))
    ~msg:"the local _opam switch is the last rung"
    (Some (in_local, "local _opam switch"))
    (Toolchain.find local_only "faketool"
    |> Option.map (fun (exe, s) -> (exe, Toolchain.Source.to_string s)));
  let nothing = discover ~bindings:[ ("PATH", "/no/such/dir") ] () in
  equal (option string) ~msg:"no rung, no resolution" None
    (Toolchain.find nothing "faketool" |> Option.map fst)

let explicit_override () =
  with_layout @@ fun ~path_bin ~switch:_ ~project:_ ->
  let on_path = make_exe path_bin "faketool" in
  let custom = make_exe path_bin "custom-faketool" in
  let t =
    discover ~bindings:[ ("PATH", path_bin); ("SPICE_FAKETOOL", custom) ] ()
  in
  equal (option string) ~msg:"the override wins over a PATH resolution"
    (Some custom)
    (Toolchain.find t "faketool" |> Option.map fst);
  let broken =
    discover
      ~bindings:
        [ ("PATH", path_bin); ("SPICE_FAKETOOL", "/no/such/executable") ]
      ()
  in
  equal (option string)
    ~msg:"a broken override fails loudly instead of falling through" None
    (Toolchain.find broken "faketool" |> Option.map fst);
  is_true ~msg:"the hint names the broken override"
    (contains ~affix:"SPICE_FAKETOOL is set to /no/such/executable"
       (Toolchain.unreachable_hint broken ~program:"faketool"));
  ignore on_path

let dune_ocaml_stdlib_is_not_consulted () =
  with_layout @@ fun ~path_bin:_ ~switch ~project:_ ->
  let _ = make_exe (Filename.concat switch "bin") "faketool" in
  let t =
    discover
      ~bindings:
        [
          ("PATH", "/no/such/dir");
          ("DUNE_OCAML_STDLIB", Filename.concat switch "lib/ocaml");
        ]
      ()
  in
  equal (option string)
    ~msg:"the private dune-site variable is not a discovery rung" None
    (Toolchain.find t "faketool" |> Option.map fst)

let env_adjustment () =
  with_layout @@ fun ~path_bin ~switch ~project:_ ->
  let _ = make_exe path_bin "faketool" in
  let _ = make_exe (Filename.concat switch "bin") "faketool" in
  let reachable =
    discover ~bindings:[ ("PATH", path_bin); ("OPAM_SWITCH_PREFIX", switch) ] ()
  in
  let env = [| "PATH=" ^ path_bin; "OPAM_SWITCH_PREFIX=" ^ switch |] in
  let t = Toolchain.discover ~env ~workspace_root:None in
  is_true ~msg:"env is physically unchanged when PATH already resolves"
    (Toolchain.env t ~program:"faketool" == env);
  ignore reachable;
  let recovered =
    discover
      ~bindings:[ ("PATH", "/no/such/dir"); ("OPAM_SWITCH_PREFIX", switch) ]
      ()
  in
  equal (option string) ~msg:"the resolving rung's directory is prepended"
    (Some (Filename.concat switch "bin" ^ ":/no/such/dir"))
    (env_path (Toolchain.env recovered ~program:"faketool"));
  let unresolvable = discover ~bindings:[ ("PATH", "/no/such/dir") ] () in
  equal (option string) ~msg:"env is unchanged when nothing resolves"
    (Some "/no/such/dir")
    (env_path (Toolchain.env unresolvable ~program:"faketool"))

let separators_are_the_callers () =
  with_layout @@ fun ~path_bin ~switch:_ ~project:_ ->
  let exe = make_exe path_bin "faketool" in
  let t = discover ~bindings:[ ("PATH", path_bin) ] () in
  equal (option string) ~msg:"a program with a separator is left to the caller"
    None
    (Toolchain.find t exe |> Option.map fst)

let diagnostics_name_the_rungs () =
  with_layout @@ fun ~path_bin ~switch ~project ->
  let t =
    discover
      ~bindings:[ ("PATH", "/no/such/dir"); ("OPAM_SWITCH_PREFIX", switch) ]
      ~workspace_root:project ()
  in
  let hint = Toolchain.unreachable_hint t ~program:"dune" in
  is_true ~msg:"hint keeps the launch-context lead"
    (contains ~affix:"dune is not on Spice's PATH" hint);
  is_true ~msg:"hint enumerates the override rung"
    (contains ~affix:"SPICE_DUNE unset" hint);
  is_true ~msg:"hint enumerates the opam rung"
    (contains ~affix:(Filename.concat switch "bin") hint);
  is_true ~msg:"hint enumerates the local-switch rung"
    (contains ~affix:"_opam" hint);
  let found = make_exe path_bin "dune" in
  let resolving =
    discover ~bindings:[ ("PATH", path_bin) ] ~workspace_root:project ()
  in
  equal string ~msg:"describe shows the resolution and its source"
    (Printf.sprintf "dune: %s (via PATH)" found)
    (Toolchain.describe resolving ~program:"dune");
  is_true ~msg:"describe shows the rungs when nothing resolves"
    (contains ~affix:"dune: not found (" (Toolchain.describe t ~program:"dune"))

let () =
  run "spice.ocaml.toolchain"
    [
      test "ladder order" ladder_order;
      test "explicit override" explicit_override;
      test "DUNE_OCAML_STDLIB is not consulted"
        dune_ocaml_stdlib_is_not_consulted;
      test "env adjustment" env_adjustment;
      test "separators are the caller's" separators_are_the_callers;
      test "diagnostics name the rungs" diagnostics_name_the_rungs;
    ]
