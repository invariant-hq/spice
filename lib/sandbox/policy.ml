(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

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
      protected_paths : Spice_path.Abs.t list;
      network : Network.t;
      environment : Environment.t;
    }
  | Direct of Environment.t
  | External of Environment.t

let canonical_paths paths = List.sort_uniq Spice_path.Abs.compare paths
let under roots path =
  List.exists
    (fun root -> Option.is_some (Spice_path.Abs.relativize ~root path))
    roots

let proper_ancestor ~ancestor path =
  (not (Spice_path.Abs.equal ancestor path))
  && Option.is_some (Spice_path.Abs.relativize ~root:ancestor path)

let normalize_roots roots =
  let roots = canonical_paths roots in
  List.filter
    (fun root ->
      not
        (List.exists
           (fun candidate -> proper_ancestor ~ancestor:candidate root)
           roots))
    roots

let confined ~reads ~writable_roots ~protected_paths ~network ~environment =
  let writable_roots = normalize_roots writable_roots in
  let reads =
    match reads with
    | All -> All
    | Only roots ->
        Only
          (normalize_roots
             (Environment.scratch environment :: writable_roots @ roots))
  in
  let protected_paths =
    protected_paths |> List.filter (under writable_roots) |> canonical_paths
  in
  Confined
    {
      reads;
      writable_roots;
      protected_paths;
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

let protected_paths = function
  | Confined { protected_paths; _ } -> protected_paths
  | Direct _ | External _ -> []

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
      && List.equal Spice_path.Abs.equal a.protected_paths b.protected_paths
      && Network.equal a.network b.network
      && Environment.equal a.environment b.environment
  | (Direct _ | External _ | Confined _), _ -> false

let pp_paths ppf paths =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
    Spice_path.Abs.pp ppf paths

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
        "@[<v>confined@,reads: %a@,writable: %a@,protected: %a@,network: \
         %a@,environment: %a@]"
        pp_reads policy.reads pp_paths policy.writable_roots pp_paths
        policy.protected_paths Network.pp
        policy.network Environment.pp_names policy.environment
