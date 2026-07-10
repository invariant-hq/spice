(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type hit = { term : string; context : string }

let denylist = [ "eval"; "benchmark"; "grader"; "rubric" ]

let scan ?(deny = denylist) text =
  let deny =
    List.map
      (fun term ->
        if String.is_empty term then
          invalid_arg "Spice_eval.Markers.scan: empty denylist term";
        (term, String.lowercase_ascii term))
      deny
  in
  String.split_on_char '\n' text
  |> List.concat_map (fun line ->
      let lowered = String.lowercase_ascii line in
      List.filter_map
        (fun (term, needle) ->
          if String.includes ~affix:needle lowered then
            Some { term; context = String.trim line }
          else None)
        deny)

let pp_hit ppf hit = Format.fprintf ppf "%S in %S" hit.term hit.context
