(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Diff = Spice_diff

type result = {
  seconds : float;
  minor_words : float;
  promoted_words : float;
  major_words : float;
}

let bench name ~iters f =
  Gc.compact ();
  ignore (Sys.opaque_identity (f 0));
  Gc.compact ();
  let before = Gc.quick_stat () in
  let started = Sys.time () in
  for i = 1 to iters do
    ignore (Sys.opaque_identity (f i))
  done;
  let seconds = Sys.time () -. started in
  let after = Gc.quick_stat () in
  let result =
    {
      seconds;
      minor_words = after.Gc.minor_words -. before.Gc.minor_words;
      promoted_words = after.Gc.promoted_words -. before.Gc.promoted_words;
      major_words = after.Gc.major_words -. before.Gc.major_words;
    }
  in
  let per_op words = words /. float iters in
  Printf.printf
    "%-28s %9d ops  %8.3fs  %9.3fus/op  minor %9.1fw/op  promoted %7.2fw/op  \
     major %9.1fw/op\n\
     %!"
    name iters result.seconds
    (result.seconds *. 1_000_000. /. float iters)
    (per_op result.minor_words)
    (per_op result.promoted_words)
    (per_op result.major_words)

let make_text ~lines ~changed =
  let buffer = Buffer.create (lines * 12) in
  for i = 1 to lines do
    if i = changed then Buffer.add_string buffer "changed line\n"
    else begin
      Buffer.add_string buffer "line ";
      Buffer.add_string buffer (string_of_int i);
      Buffer.add_char buffer '\n'
    end
  done;
  Buffer.contents buffer

let diff_label name = Diff.Label.of_string name

let small_change =
  Diff.File_change.modify ~label:(diff_label "small.txt") ~before:"a\nb\nc\n"
    ~after:"a\nB\nc\n"

let medium_before = make_text ~lines:200 ~changed:80
let medium_after = make_text ~lines:200 ~changed:120

let medium_change =
  Diff.File_change.modify ~label:(diff_label "medium.txt") ~before:medium_before
    ~after:medium_after

let multi_changes =
  let rec loop acc i =
    if i = 0 then acc
    else
      let label = diff_label ("file-" ^ string_of_int i ^ ".txt") in
      let before = make_text ~lines:80 ~changed:(10 + (i mod 20)) in
      let after = make_text ~lines:80 ~changed:(40 + (i mod 20)) in
      loop (Diff.File_change.modify ~label ~before ~after :: acc) (i - 1)
  in
  loop [] 20

let () =
  Printf.printf "\nDiff benchmarks\n";
  bench "Diff.render small" ~iters:50_000 (fun _ ->
      Diff.render [ small_change ] |> Diff.to_string |> String.length);
  bench "Diff.render medium" ~iters:5_000 (fun _ ->
      Diff.render [ medium_change ] |> Diff.to_string |> String.length);
  bench "Diff.render 20 files" ~iters:1_000 (fun _ ->
      Diff.render multi_changes |> Diff.to_string |> String.length);
  bench "Diff.stats_of_changes 20 files" ~iters:2_000 (fun _ ->
      (Diff.stats_of_changes multi_changes).Diff.additions)
