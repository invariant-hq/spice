(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module String_map = Map.Make (String)

type t = string String_map.t

let empty = String_map.empty

let of_list bindings =
  List.fold_left
    (fun env (name, value) -> String_map.add name value env)
    empty bindings

let binding env = String.split_first ~sep:"=" env

let current () =
  Array.fold_left
    (fun env raw ->
      match binding raw with
      | None -> env
      | Some (name, value) -> String_map.add name value env)
    empty (Unix.environment ())

let get t name = String_map.find_opt name t
let to_list t = String_map.bindings t
