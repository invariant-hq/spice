(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = invalid_arg ("Spice_diagnostic." ^ fn ^ ": " ^ message)

let check_non_empty fn what s =
  if String.length s = 0 then invalid fn (what ^ " is empty")

let check_single_line fn what s =
  if String.exists (function '\n' | '\r' -> true | _ -> false) s then
    invalid fn (what ^ " must be a single line")

let check_candidate fn candidate =
  check_non_empty fn "candidate" candidate;
  check_single_line fn "candidate" candidate

(* Diagnostics *)

type t = { message : string; context : string option; hints : string list }

let make ?context ?(hints = []) message =
  check_non_empty "make" "message" message;
  check_single_line "make" "message" message;
  Option.iter (check_non_empty "make" "context") context;
  List.iter
    (fun hint ->
      check_non_empty "make" "hint" hint;
      check_single_line "make" "hint" hint)
    hints;
  { message; context; hints }

let first_line_break text =
  let rec loop i =
    if i = String.length text then None
    else match text.[i] with '\n' | '\r' -> Some i | _ -> loop (i + 1)
  in
  loop 0

let after_line_break text index =
  match text.[index] with
  | '\r' when index + 1 < String.length text && Char.equal text.[index + 1] '\n'
    ->
      index + 2
  | '\n' | '\r' -> index + 1
  | _ -> assert false

let of_text ?(hints = []) text =
  check_non_empty "of_text" "text" text;
  match first_line_break text with
  | None -> make ~hints text
  | Some index ->
      let message = String.sub text 0 index in
      let context_start = after_line_break text index in
      let context =
        String.sub text context_start (String.length text - context_start)
      in
      if String.is_empty context then make ~hints message
      else make ~context ~hints message

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
      List.iter (check_candidate "suggest") candidates;
      [ "did you mean " ^ enumerate_or candidates ^ "?" ]

let closest s ~candidates =
  let input_length = String.length s in
  let close candidate =
    let candidate_length = String.length candidate in
    if abs (input_length - candidate_length) > max_suggestion_distance then
      false
    else
      let distance = levenshtein_distance s candidate in
      0 < distance && distance <= max_suggestion_distance
  in
  List.filter close candidates

let did_you_mean s ~candidates =
  List.iter (check_candidate "did_you_mean") candidates;
  suggest (closest s ~candidates)

(* Formatting *)

let pp ppf t =
  Format.pp_print_string ppf t.message;
  Option.iter (fun context -> Format.fprintf ppf "@\n%s" context) t.context;
  List.iter (fun hint -> Format.fprintf ppf "@\nHint: %s" hint) t.hints

let to_string t = Format.asprintf "%a" pp t
