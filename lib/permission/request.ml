(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

module Change = struct
  type t = {
    diff : string option;
    additions : int option;
    removals : int option;
  }

  let invalid = invalid_arg' "Spice_permission.Request.Change" "make"

  let make ?diff ?additions ?removals () =
    Option.iter
      (fun diff ->
        if String.is_empty diff then invalid "diff must not be empty")
      diff;
    Option.iter
      (fun additions ->
        if additions < 0 then invalid "additions must be non-negative")
      additions;
    Option.iter
      (fun removals ->
        if removals < 0 then invalid "removals must be non-negative")
      removals;
    if
      Option.is_none diff && Option.is_none additions && Option.is_none removals
    then invalid "change must contain at least one field";
    { diff; additions; removals }

  let diff t = t.diff
  let additions t = t.additions
  let removals t = t.removals
  let equal a b = a = b

  let pp ppf { diff; additions; removals } =
    let pp_count ppf = function
      | None -> Format.pp_print_string ppf "?"
      | Some count -> Format.pp_print_int ppf count
    in
    Format.fprintf ppf "change(+%a -%a%s)" pp_count additions pp_count removals
      (if Option.is_some diff then ", diff" else "")

  let jsont =
    let decode diff additions removals =
      decode_invalid_arg (fun () -> make ?diff ?additions ?removals ())
    in
    Jsont.Object.map ~kind:"permission request change" decode
    |> Jsont.Object.opt_mem "diff" Jsont.string ~enc:diff
    |> Jsont.Object.opt_mem "additions" Jsont.int ~enc:additions
    |> Jsont.Object.opt_mem "removals" Jsont.int ~enc:removals
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Item = struct
  type t = {
    access : Access.t;
    display : string option;
    change : Change.t option;
  }

  let invalid = invalid_arg' "Spice_permission.Request.Item" "make"

  let make ?display ?change access =
    Option.iter
      (fun display ->
        if String.is_empty display then invalid "display must not be empty")
      display;
    { access; display; change }

  let access t = t.access
  let display t = t.display
  let change t = t.change
  let equal a b = a = b

  let pp ppf item =
    let pp_display ppf = function
      | None -> ()
      | Some display -> Format.fprintf ppf ", display=%S" display
    in
    let pp_change ppf = function
      | None -> ()
      | Some change -> Format.fprintf ppf ", change=%a" Change.pp change
    in
    Format.fprintf ppf "item(%a%a%a)" Access.pp item.access pp_display
      item.display pp_change item.change

  let jsont =
    let decode access display change =
      decode_invalid_arg (fun () -> make ?display ?change access)
    in
    Jsont.Object.map ~kind:"permission request item" decode
    |> Jsont.Object.mem "access" Access.jsont ~enc:access
    |> Jsont.Object.opt_mem "display" Jsont.string ~enc:display
    |> Jsont.Object.opt_mem "change" Change.jsont ~enc:change
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = {
  source : string option;
  display : string option;
  items : Item.t list;
}

let invalid_make = invalid_arg' "Spice_permission.Request" "make"
let invalid_of_accesses = invalid_arg' "Spice_permission.Request" "of_accesses"

let unique_accesses_of_accesses accesses =
  List.fold_left
    (fun accesses access -> Access.Set.add access accesses)
    Access.Set.empty accesses

let make ?source ?display items =
  if List.is_empty items then invalid_make "items must not be empty";
  Option.iter
    (fun source ->
      if String.is_empty source then invalid_make "source must not be empty")
    source;
  Option.iter
    (fun display ->
      if String.is_empty display then invalid_make "display must not be empty")
    display;
  { source; display; items }

let of_accesses ?source ?display accesses =
  if List.is_empty accesses then
    invalid_of_accesses "accesses must not be empty";
  make ?source ?display (List.map (fun access -> Item.make access) accesses)

let source t = t.source
let display t = t.display
let items t = t.items
let accesses t = List.map Item.access t.items

let items_for_access t access =
  List.filter (fun item -> Access.equal (Item.access item) access) t.items

let changes_for_access t access =
  items_for_access t access |> List.filter_map Item.change

let normalized_accesses t =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | access :: accesses ->
        if Access.Set.mem access seen then loop seen acc accesses
        else loop (Access.Set.add access seen) (access :: acc) accesses
  in
  loop Access.Set.empty [] (accesses t)

let unique_accesses t = unique_accesses_of_accesses (accesses t)

let equal a b =
  Option.equal String.equal a.source b.source
  && Option.equal String.equal a.display b.display
  && List.equal Item.equal a.items b.items

let pp_accesses ppf accesses =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
    Access.pp ppf accesses

let pp ppf request =
  let change_count =
    List.fold_left
      (fun count item ->
        if Option.is_some (Item.change item) then count + 1 else count)
      0 request.items
  in
  let changes ppf count =
    if count <> 0 then Format.fprintf ppf ", changes=%d" count
  in
  let accesses = accesses request in
  let metadata =
    List.filter_map Fun.id
      [
        Option.map (fun source -> Printf.sprintf "source=%S" source)
          request.source;
        Option.map (fun display -> Printf.sprintf "display=%S" display)
          request.display;
      ]
  in
  match metadata with
  | [] ->
      Format.fprintf ppf "request([%a]%a)" pp_accesses accesses changes
        change_count
  | metadata ->
      Format.fprintf ppf "request(%s, [%a]%a)" (String.concat ", " metadata)
        pp_accesses accesses changes change_count

let jsont =
  let decode version source display items =
    if version <> 4 then
      decode_error
        ("unknown permission request version: " ^ string_of_int version);
    decode_invalid_arg (fun () ->
        make ?source ?display items)
  in
  Jsont.Object.map ~kind:"permission request" decode
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun _ -> 4)
  |> Jsont.Object.opt_mem "source" Jsont.string ~enc:source
  |> Jsont.Object.opt_mem "display" Jsont.string ~enc:display
  |> Jsont.Object.mem "items" Jsont.(list Item.jsont) ~enc:items
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
