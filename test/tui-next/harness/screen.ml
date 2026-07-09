(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Golden-frame normalization. Time never needs scrubbing here — the clock is
   virtual — so only machine-dependent content is rewritten: session ids and
   the temp project root. *)

let normalize_session_ids text =
  let len = String.length text in
  let out = Buffer.create len in
  let rec loop index =
    if index >= len then ()
    else if index + 4 <= len && String.equal (String.sub text index 4) "ses_"
    then (
      Buffer.add_string out "ses_$ID";
      let rec skip index =
        if index < len then
          match text.[index] with
          | '0' .. '9' | '_' -> skip (index + 1)
          | _ -> index
        else index
      in
      loop (skip (index + 4)))
    else (
      Buffer.add_char out text.[index];
      loop (index + 1))
  in
  loop 0;
  Buffer.contents out

let ellipsis = "…"

(* The footer squeezes the cwd until it renders truncated: a prefix of the
   project root followed by an ellipsis. The exact-root replacement misses
   those, so replace any root prefix followed by the ellipsis too, keeping
   goldens machine-independent. *)
let normalize_truncated_root root text =
  let min_len = 12 in
  let rec loop len text =
    if len < min_len then text
    else
      loop (len - 1)
        (Util.replace_all
           ~pattern:(String.sub root 0 len ^ ellipsis)
           ~with_:("$PROJECT" ^ ellipsis) text)
  in
  loop (String.length root - 1) text

let normalize ~project screen =
  let root = Project.root project in
  Util.replace_all ~pattern:root ~with_:"$PROJECT" screen
  |> normalize_truncated_root root
  |> normalize_session_ids

let print ~project screen =
  normalize ~project screen |> String.split_on_char '\n'
  |> List.iteri (fun index line ->
         Printf.printf "%02d | %s\n" (index + 1) (Util.rstrip line))
