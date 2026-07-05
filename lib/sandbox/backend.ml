(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid_arg' fn msg =
  invalid_arg ("Spice_sandbox.Backend." ^ fn ^ ": " ^ msg)

type prepared = { prefix : string list; profile : Spice_digest.t }

type t = {
  id : string;
  available : unit -> (unit, Error.t) result;
  prepare : Confinement.t -> (prepared, Error.t) result;
}

let make ~id ~available ~prepare () =
  if String.equal id "" then invalid_arg' "make" "id is empty";
  { id; available; prepare }

let prepared ~prefix ~profile = { prefix; profile }

let none ~reason =
  if String.equal reason "" then invalid_arg' "none" "reason is empty";
  let error = Error.unavailable reason in
  {
    id = "none";
    available = (fun () -> Error error);
    prepare = (fun _confinement -> Error error);
  }

let id t = t.id
let available t = t.available ()
let prepare t policy = t.prepare policy

let wrap { prefix; _ } ~argv =
  match prefix @ Argv.to_list argv with
  | [] -> assert false (* argv is non-empty by construction *)
  | program :: args -> Argv.make ~program args

let profile prepared = prepared.profile
