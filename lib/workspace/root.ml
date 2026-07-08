(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Key = struct
  type t = string
  type error = Empty

  let message = function Empty -> "root key must not be empty"
  let of_string key = if String.is_empty key then Error Empty else Ok key

  let of_string_exn key =
    match of_string key with
    | Ok key -> key
    | Error error ->
        invalid_arg
          (Format.asprintf "Spice_workspace.Root.Key.of_string_exn: %a"
             (fun ppf error -> Format.pp_print_string ppf (message error))
             error)

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf (to_string t)
  let pp_error ppf error = Format.pp_print_string ppf (message error)
end

type t = { key : Key.t; dir : Spice_path.Abs.t }

let make ?key dir =
  let key =
    Option.value key ~default:(Key.of_string_exn (Spice_path.Abs.to_string dir))
  in
  { key; dir }

let dir t = t.dir
let key t = t.key
let same_key a b = Key.equal a.key b.key
let equal a b = same_key a b && Spice_path.Abs.equal a.dir b.dir

let compare a b =
  match Key.compare a.key b.key with
  | 0 -> Spice_path.Abs.compare a.dir b.dir
  | order -> order

let pp ppf t = Spice_path.Abs.pp ppf t.dir
