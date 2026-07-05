(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Path = Spice_path

type result = {
  seconds : float;
  minor_words : float;
  promoted_words : float;
  major_words : float;
}

let ok label = function
  | Ok value -> value
  | Error error -> failwith (label ^ ": " ^ Path.Error.message error)

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

let pick inputs i = Array.unsafe_get inputs (i mod Array.length inputs)

let rel_inputs =
  [|
    "lib/path/../diff/spice_diff.ml";
    "./test//test_diff.ml";
    "src/a/./b/../c/d.ml";
    "doc/design/../design/path.md";
    "a/b/c/d/e/f/../../g";
  |]

let abs_inputs =
  [|
    "/workspace/spice/lib/path/../diff/spice_diff.ml";
    "/tmp//spice/./test/test_diff.ml";
    "/a/b/c/../../d/e";
    "/../workspace/spice";
  |]

let rel_root = ok "rel root" (Path.Rel.of_string "workspace/src/lib")
let abs_root = ok "abs root" (Path.Abs.of_string "/workspace/spice/lib")
let rel_target = ok "rel target" (Path.Rel.of_string "workspace/test/a.ml")
let rel_from = ok "rel from" (Path.Rel.of_string "workspace/src/lib")

let () =
  Printf.printf "\nPath benchmarks\n";
  bench "Rel.of_string" ~iters:200_000 (fun i ->
      Path.Rel.of_string (pick rel_inputs i) |> ok "rel" |> Path.Rel.hash);
  bench "Rel.resolve" ~iters:200_000 (fun i ->
      Path.Rel.resolve rel_root (pick rel_inputs i)
      |> ok "resolve" |> Path.Rel.hash);
  bench "Abs.of_string" ~iters:200_000 (fun i ->
      Path.Abs.of_string (pick abs_inputs i) |> ok "abs" |> Path.Abs.hash);
  bench "Abs.resolve" ~iters:200_000 (fun i ->
      Path.Abs.resolve abs_root (pick rel_inputs i)
      |> ok "abs resolve" |> Path.Abs.hash);
  bench "Abs.resolve_any" ~iters:200_000 (fun i ->
      (* Alternate absolute and relative inputs to exercise both branches. *)
      let input =
        if i land 1 = 0 then pick abs_inputs i else pick rel_inputs i
      in
      Path.Abs.resolve_any ~base:abs_root input
      |> ok "abs resolve_any" |> Path.Abs.hash);
  bench "Rel.reach" ~iters:500_000 (fun _ ->
      String.length (Path.Rel.reach ~from:rel_from rel_target))
