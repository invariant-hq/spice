(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid_arg' fn msg =
  invalid_arg ("Spice_sandbox.Backend." ^ fn ^ ": " ^ msg)

type prepared = {
  prefix : string list;
  chdir : bool;
  profile : Spice_digest.t;
}

type t = {
  id : string;
  available : unit -> (unit, Error.t) result;
  prepare : Policy.t -> (prepared, Error.t) result;
}

let make ~id ~available ~prepare () =
  if String.equal id "" then invalid_arg' "make" "id is empty";
  { id; available; prepare }

let prepared ~chdir ~prefix ~profile =
  (match prefix with
  | "" :: _ -> invalid_arg' "prepared" "prefix program is empty"
  | _ -> ());
  { prefix; chdir; profile }

let none ~reason =
  if String.equal reason "" then invalid_arg' "none" "reason is empty";
  let error = Error.unavailable reason in
  {
    id = "none";
    available = (fun () -> Error error);
    prepare = (fun _policy -> Error error);
  }

let id t = t.id
let available t = t.available ()
let prepare t policy = t.prepare policy

let wrap { prefix; chdir; _ } ~cwd ~argv =
  let prefix =
    if chdir then
      prefix @ [ "--chdir"; Spice_path.Abs.to_string cwd; "--" ]
    else prefix
  in
  match prefix @ Argv.to_list argv with
  | [] -> assert false (* argv is non-empty by construction *)
  | program :: args -> Argv.make ~program args

let profile prepared = prepared.profile

let validate_policy_paths policy =
  match policy with
  | Policy.Direct _ | Policy.External _ -> Ok ()
  | Policy.Confined _ ->
      let readable =
        match Policy.reads policy with
        | Some (Policy.Only roots) -> roots
        | Some Policy.All | None -> []
      in
      let directories =
        Environment.scratch (Policy.environment policy)
        :: Policy.writable_roots policy
      in
      let entries = Policy.protected_paths policy in
      let rec validate ~directory = function
        | [] -> Ok ()
        | path :: rest -> (
            let spelling = Spice_path.Abs.to_string path in
            let inspect = if directory then Unix.stat else Unix.lstat in
            match inspect spelling with
            | stats
              when (not directory) || stats.Unix.st_kind = Unix.S_DIR ->
                validate ~directory rest
            | _ ->
                Error
                  (Error.stale_policy
                     (Printf.sprintf "sandbox root changed kind: %s" spelling))
            | exception Unix.Unix_error (error, _, _) ->
                Error
                  (Error.stale_policy
                     (Printf.sprintf "sandbox root is stale: %s: %s" spelling
                        (Unix.error_message error))))
      in
      match validate ~directory:false (readable @ entries) with
      | Error _ as error -> error
      | Ok () -> validate ~directory:true directories
