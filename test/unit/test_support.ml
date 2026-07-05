(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Shared helpers for the unit-test suite. Admission rule: a helper moves
   here only once it is already duplicated in three or more test files. *)

open Windtrap
module Json = Jsont.Json

let expect_invalid_arg ?expected msg f =
  match expected with
  | Some expected -> raises_invalid_arg ~msg expected (fun () -> ignore (f ()))
  | None -> (
      match f () with
      | _ -> failf "%s: expected Invalid_argument" msg
      | exception Invalid_argument _ -> ())

let check msg predicate = is_true ~msg predicate

let json_object fields =
  fields
  |> List.map (fun (name, value) -> Json.mem (Json.name name) value)
  |> Json.object'

let json_array values = Json.list values

let decode codec json =
  match Json.decode codec json with
  | Ok value -> value
  | Error message -> failf "decode failed: %s" message

let encode codec value =
  match Json.encode codec value with
  | Ok json -> json
  | Error message -> failf "encode failed: %s" message
