(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = Unrestricted | Read_only | Checks

let unrestricted = Unrestricted
let read_only = Read_only
let checks = Checks

let read_only_policy =
  let open Spice_permission in
  Policy.make
    [
      Policy.Rule.allow
        (Policy.Match.path ~op:`Read Policy.Match.Path.workspace);
      Policy.Rule.deny (Policy.Match.kind `Write);
      Policy.Rule.deny (Policy.Match.kind `Command);
    ]

(* The read-only tool set, owned here by stable model-visible tool name so this
   module does not depend on the tool implementations. The skill tool is a
   read-only load of host-discovered guidance. *)
let read_only_tool_names = [ "read_file"; "search_text"; "glob"; "skill" ]
let checks_tool_names = read_only_tool_names @ [ "shell" ]

let allowed_tool_names = function
  | Unrestricted -> None
  | Read_only -> Some read_only_tool_names
  | Checks -> Some checks_tool_names

let filter_tools t tools =
  match allowed_tool_names t with
  | None -> tools
  | Some names ->
      List.filter (fun tool -> List.mem (Spice_tool.name tool) names) tools

let policy t ~configured =
  match t with
  | Unrestricted | Checks -> configured
  | Read_only -> read_only_policy

let equal a b = a = b

let to_string = function
  | Unrestricted -> "unrestricted"
  | Read_only -> "read_only"
  | Checks -> "checks"

let pp ppf t = Format.pp_print_string ppf (to_string t)
