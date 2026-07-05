(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = invalid_arg ("Spice_diagnostic." ^ fn ^ ": " ^ message)

let check_non_empty fn what s =
  if String.length s = 0 then invalid fn (what ^ " is empty")

(* Diagnostics *)

type t = { message : string; context : string option; hints : string list }

let make ?context ?(hints = []) message =
  check_non_empty "make" "message" message;
  Option.iter (check_non_empty "make" "context") context;
  List.iter (check_non_empty "make" "hint") hints;
  { message; context; hints }

(* Hints *)

let max_suggestion_distance = 2

(* As found here http://rosettacode.org/wiki/Levenshtein_distance#OCaml,
   matching dune's [User_message.did_you_mean] behavior. *)
let levenshtein_distance s t =
  let m = String.length s and n = String.length t in
  (* for all i and j, d.(i).(j) holds the Levenshtein distance between the
     first i characters of s and the first j characters of t *)
  let d = Array.make_matrix (m + 1) (n + 1) 0 in
  for i = 0 to m do
    d.(i).(0) <- i
  done;
  for j = 0 to n do
    d.(0).(j) <- j
  done;
  for j = 1 to n do
    for i = 1 to m do
      if Char.equal s.[i - 1] t.[j - 1] then d.(i).(j) <- d.(i - 1).(j - 1)
      else
        d.(i).(j) <-
          min
            (d.(i - 1).(j) + 1) (* a deletion *)
            (min
               (d.(i).(j - 1) + 1) (* an insertion *)
               (d.(i - 1).(j - 1) + 1) (* a substitution *))
    done
  done;
  d.(m).(n)

let enumerate_or candidates =
  let rec loop = function
    | [] -> []
    | [ x ] -> [ x ]
    | [ x; y ] -> [ x; " or "; y ]
    | x :: rest -> x :: ", " :: loop rest
  in
  String.concat "" (loop candidates)

let suggest = function
  | [] -> []
  | candidates ->
      List.iter (check_non_empty "suggest" "candidate") candidates;
      [ "did you mean " ^ enumerate_or candidates ^ "?" ]

let closest s ~candidates =
  let close candidate =
    let distance = levenshtein_distance s candidate in
    0 < distance && distance <= max_suggestion_distance
  in
  List.filter close candidates

let did_you_mean s ~candidates = suggest (closest s ~candidates)

(* Formatting *)

let pp ppf t =
  Format.pp_print_string ppf t.message;
  Option.iter (fun context -> Format.fprintf ppf "@\n%s" context) t.context;
  List.iter (fun hint -> Format.fprintf ppf "@\nHint: %s" hint) t.hints

let to_string t = Format.asprintf "%a" pp t
