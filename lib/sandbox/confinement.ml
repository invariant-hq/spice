(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid_arg' fn message =
  invalid_arg ("Spice_sandbox.Confinement." ^ fn ^ ": " ^ message)

type network = Restricted | Enabled

type t = {
  writable : Spice_path.Abs.t list;
  meta : string list;
  protected : Spice_path.Abs.t list;
  network : network;
}

let canonical_paths paths = List.sort_uniq Spice_path.Abs.compare paths
let canonical_names names = List.sort_uniq String.compare names

let read_only =
  { writable = []; meta = []; protected = []; network = Restricted }

let writable roots t =
  { t with writable = canonical_paths (roots @ t.writable) }

let protect_meta names t =
  List.iter
    (fun name ->
      if not (Spice_path.Rel.is_component name) then
        invalid_arg' "protect_meta"
          (Printf.sprintf "%S is not a valid path component" name))
    names;
  { t with meta = canonical_names (names @ t.meta) }

let protect paths t =
  { t with protected = canonical_paths (paths @ t.protected) }

let network state t = { t with network = state }
let writable_roots t = t.writable
let protected_meta t = t.meta
let protected_paths t = t.protected

let write_carveouts t =
  let from_meta =
    List.concat_map
      (fun root ->
        List.filter_map
          (fun name ->
            Result.to_option (Spice_path.Abs.add_component root name))
          t.meta)
      t.writable
  in
  let protected =
    List.filter
      (fun path ->
        List.exists
          (fun root -> Option.is_some (Spice_path.Abs.relativize ~root path))
          t.writable)
      t.protected
  in
  canonical_paths (from_meta @ protected)

let network_state t = t.network

let network_equal a b =
  match (a, b) with
  | Restricted, Restricted | Enabled, Enabled -> true
  | (Restricted | Enabled), _ -> false

let equal a b =
  List.equal Spice_path.Abs.equal a.writable b.writable
  && List.equal String.equal a.meta b.meta
  && List.equal Spice_path.Abs.equal a.protected b.protected
  && network_equal a.network b.network

let pp_network ppf = function
  | Restricted -> Format.pp_print_string ppf "restricted"
  | Enabled -> Format.pp_print_string ppf "enabled"

let pp ppf t =
  Format.fprintf ppf
    "@[<v>writable: %a@,protected meta: %a@,protected: %a@,network: %a@]"
    (Format.pp_print_list
       ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
       Spice_path.Abs.pp)
    t.writable
    (Format.pp_print_list
       ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
       Format.pp_print_string)
    t.meta
    (Format.pp_print_list
       ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
       Spice_path.Abs.pp)
    t.protected pp_network t.network
