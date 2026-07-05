(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t =
  | Not_requested
  | Enforced of { backend : string; profile : Spice_digest.t }
  | Refused of Error.t
  | Declared_external

let invalid_arg' fn msg =
  invalid_arg ("Spice_sandbox.Evidence." ^ fn ^ ": " ^ msg)

let not_requested = Not_requested
let declared_external = Declared_external

let enforced ~backend ~profile =
  if String.equal backend "" then invalid_arg' "enforced" "backend is empty";
  Enforced { backend; profile }

let refused error = Refused error

let equal a b =
  match (a, b) with
  | Not_requested, Not_requested -> true
  | Declared_external, Declared_external -> true
  | Enforced a, Enforced b ->
      String.equal a.backend b.backend && Spice_digest.equal a.profile b.profile
  | Refused a, Refused b -> Error.equal a b
  | (Not_requested | Enforced _ | Refused _ | Declared_external), _ -> false

let pp ppf = function
  | Not_requested -> Format.pp_print_string ppf "not requested"
  | Enforced { backend; profile } ->
      Format.fprintf ppf "enforced (%s %a)" backend Spice_digest.pp profile
  | Refused error -> Format.fprintf ppf "refused (%a)" Error.pp error
  | Declared_external -> Format.pp_print_string ppf "declared external"

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let to_json = function
  | Not_requested -> json_obj [ ("kind", Jsont.Json.string "not_requested") ]
  | Enforced { backend; profile } ->
      json_obj
        [
          ("kind", Jsont.Json.string "enforced");
          ("backend", Jsont.Json.string backend);
          ("profile_hash", Jsont.Json.string (Spice_digest.to_hex profile));
        ]
  | Refused error ->
      json_obj
        [
          ("kind", Jsont.Json.string "refused");
          ("reason", Jsont.Json.string (Error.message error));
          ("error", Error.to_json error);
        ]
  | Declared_external ->
      json_obj [ ("kind", Jsont.Json.string "declared_external") ]
