(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid_arg' fn message =
  invalid_arg ("Spice_sandbox.Policy." ^ fn ^ ": " ^ message)

module Network = struct
  type t = Restricted | Enabled

  let all = [ Restricted; Enabled ]

  let of_string = function
    | "restricted" -> Some Restricted
    | "enabled" -> Some Enabled
    | _ -> None

  let to_string = function Restricted -> "restricted" | Enabled -> "enabled"

  let equal a b =
    match a, b with
    | Restricted, Restricted | Enabled, Enabled -> true
    | (Restricted | Enabled), _ -> false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

type reads = All | Only of Spice_path.Abs.t list

type t =
  | Confined of {
      reads : reads;
      writable_roots : Spice_path.Abs.t list;
      protected_meta : string list;
      protected_paths : Spice_path.Abs.t list;
      network : Network.t;
      environment : Environment.t;
    }
  | Direct of Environment.t
  | External of Environment.t

let canonical_paths paths = List.sort_uniq Spice_path.Abs.compare paths
let canonical_names names = List.sort_uniq String.compare names

let confined ~reads ~writable_roots ~protected_meta ~protected_paths ~network
    ~environment =
  List.iter
    (fun name ->
      if not (Spice_path.Rel.is_component name) then
        invalid_arg' "confined"
          (Printf.sprintf "%S is not a valid protected metadata component" name))
    protected_meta;
  let writable_roots = canonical_paths writable_roots in
  let reads =
    match reads with
    | All -> All
    | Only roots -> Only (canonical_paths (writable_roots @ roots))
  in
  Confined
    {
      reads;
      writable_roots;
      protected_meta = canonical_names protected_meta;
      protected_paths = canonical_paths protected_paths;
      network;
      environment;
    }

let direct ~environment = Direct environment
let external_ ~environment = External environment

let environment = function
  | Confined { environment; _ } | Direct environment | External environment ->
      environment

let reads = function
  | Confined { reads; _ } -> Some reads
  | Direct _ | External _ -> None

let writable_roots = function
  | Confined { writable_roots; _ } -> writable_roots
  | Direct _ | External _ -> []

let protected_meta = function
  | Confined { protected_meta; _ } -> protected_meta
  | Direct _ | External _ -> []

let protected_paths = function
  | Confined { protected_paths; _ } -> protected_paths
  | Direct _ | External _ -> []

let write_carveouts t =
  let writable_roots = writable_roots t in
  let from_meta =
    List.concat_map
      (fun root ->
        List.filter_map
          (fun name ->
            Result.to_option (Spice_path.Abs.add_component root name))
          (protected_meta t))
      writable_roots
  in
  let protected =
    List.filter
      (fun path ->
        List.exists
          (fun root -> Option.is_some (Spice_path.Abs.relativize ~root path))
          writable_roots)
      (protected_paths t)
  in
  canonical_paths (from_meta @ protected)

let network = function
  | Confined { network; _ } -> Some network
  | Direct _ | External _ -> None

let reads_equal a b =
  match a, b with
  | All, All -> true
  | Only a, Only b -> List.equal Spice_path.Abs.equal a b
  | (All | Only _), _ -> false

let equal a b =
  match a, b with
  | Direct a, Direct b | External a, External b -> Environment.equal a b
  | Confined a, Confined b ->
      reads_equal a.reads b.reads
      && List.equal Spice_path.Abs.equal a.writable_roots b.writable_roots
      && List.equal String.equal a.protected_meta b.protected_meta
      && List.equal Spice_path.Abs.equal a.protected_paths b.protected_paths
      && Network.equal a.network b.network
      && Environment.equal a.environment b.environment
  | (Direct _ | External _ | Confined _), _ -> false

let pp_paths ppf paths =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
    Spice_path.Abs.pp ppf paths

let pp_names ppf names =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
    Format.pp_print_string ppf names

let pp_reads ppf = function
  | All -> Format.pp_print_string ppf "all"
  | Only roots -> Format.fprintf ppf "only [%a]" pp_paths roots

let pp ppf = function
  | Direct environment ->
      Format.fprintf ppf "direct (environment: %a)" Environment.pp_names environment
  | External environment ->
      Format.fprintf ppf "external (environment: %a)" Environment.pp_names environment
  | Confined policy ->
      Format.fprintf ppf
        "@[<v>confined@,reads: %a@,writable: %a@,protected meta: %a@,protected: \
         %a@,network: %a@,environment: %a@]"
        pp_reads policy.reads pp_paths policy.writable_roots pp_names
        policy.protected_meta pp_paths policy.protected_paths Network.pp
        policy.network Environment.pp_names policy.environment
