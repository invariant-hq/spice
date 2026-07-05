(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type source = Git of { url : string; rev : string } | Dir of string

let invalid_source fn message =
  invalid_arg ("Spice_eval.Task." ^ fn ^ ": " ^ message)

let non_empty_source fn field value =
  if String.is_empty value then invalid_source fn (field ^ " must not be empty")

let git ~url ~rev =
  non_empty_source "git" "url" url;
  non_empty_source "git" "rev" rev;
  Git { url; rev }

let dir path =
  non_empty_source "dir" "path" path;
  Dir path

type limits = { timeout_s : float option; steps : int option }

type t = {
  id : string;
  source : source;
  setup : string list;
  prompt : string;
  checks : Check.t list;
  tags : string list;
  metadata : (string * string) list;
  limits : limits option;
}

let invalid fn message = invalid_arg ("Spice_eval.Task." ^ fn ^ ": " ^ message)

let non_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let non_empty_pair fn (name, value) =
  non_empty fn "metadata key" name;
  non_empty fn ("metadata value for " ^ name) value

let positive_int fn field = function
  | None -> ()
  | Some value when value > 0 -> ()
  | Some _ -> invalid fn (field ^ " must be positive")

let is_positive_finite value =
  match classify_float value with
  | FP_normal | FP_subnormal -> value > 0.
  | FP_zero | FP_infinite | FP_nan -> false

let positive_float fn field = function
  | None -> ()
  | Some value ->
      if not (is_positive_finite value) then
        invalid fn (field ^ " must be positive")

let validate_limits = function
  | None -> ()
  | Some limits ->
      positive_float "make" "timeout_s" limits.timeout_s;
      positive_int "make" "steps" limits.steps

let check_unique_names checks =
  let rec loop seen = function
    | [] -> ()
    | check :: rest ->
        let name = Check.name check in
        if List.exists (String.equal name) seen then
          invalid "make" ("duplicate check name: " ^ name);
        loop (name :: seen) rest
  in
  loop [] checks

let make ?(tags = []) ?(metadata = []) ?(setup = []) ?limits id ~source ~prompt
    checks =
  non_empty "make" "id" id;
  non_empty "make" "prompt" prompt;
  List.iter (non_empty "make" "tag") tags;
  List.iter (non_empty_pair "make") metadata;
  List.iter (non_empty "make" "setup command") setup;
  validate_limits limits;
  (match checks with
  | [] -> invalid "make" "checks must not be empty"
  | _ :: _ -> check_unique_names checks);
  { id; source; setup; prompt; checks; tags; metadata; limits }

let id t = t.id
let source t = t.source
let setup t = t.setup
let prompt t = t.prompt
let checks t = t.checks
let tags t = t.tags
let metadata t = t.metadata
let limits t = t.limits

let pp_source ppf = function
  | Git { url; rev } -> Format.fprintf ppf "git(%s@%s)" url rev
  | Dir path -> Format.fprintf ppf "dir(%s)" path

let pp ppf t = Format.fprintf ppf "%s checks=%d" t.id (List.length t.checks)
let equal a b = a = b
