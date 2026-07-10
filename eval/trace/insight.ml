(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type severity = Info | Minor | Major

type t = {
  detector : string;
  severity : severity;
  steps : int * int;
  message : string;
  evidence : string;
  waste_tokens : int option;
}

let severity_to_string = function
  | Info -> "info"
  | Minor -> "minor"
  | Major -> "major"

let pp_severity ppf severity =
  Format.pp_print_string ppf (severity_to_string severity)

let severity_jsont =
  Jsont.enum ~kind:"severity"
    [ ("info", Info); ("minor", Minor); ("major", Major) ]

let steps_jsont =
  Jsont.Object.map ~kind:"steps" (fun first last -> (first, last))
  |> Jsont.Object.mem "first" Jsont.int ~enc:fst
  |> Jsont.Object.mem "last" Jsont.int ~enc:snd
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let jsont =
  Jsont.Object.map ~kind:"insight"
    (fun detector severity steps message evidence waste_tokens ->
      { detector; severity; steps; message; evidence; waste_tokens })
  |> Jsont.Object.mem "detector" Jsont.string ~enc:(fun t -> t.detector)
  |> Jsont.Object.mem "severity" severity_jsont ~enc:(fun t -> t.severity)
  |> Jsont.Object.mem "steps" steps_jsont ~enc:(fun t -> t.steps)
  |> Jsont.Object.mem "message" Jsont.string ~enc:(fun t -> t.message)
  |> Jsont.Object.mem "evidence" Jsont.string ~enc:(fun t -> t.evidence)
  |> Jsont.Object.opt_mem "waste_tokens" Jsont.int ~enc:(fun t ->
      t.waste_tokens)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

type detector = Trace.t -> t list

let step_range calls =
  match calls with
  | [] -> (0, 0)
  | first :: rest ->
      List.fold_left
        (fun (lo, hi) call ->
          let index = Trace.Call.step_index call in
          (min lo index, max hi index))
        (Trace.Call.step_index first, Trace.Call.step_index first)
        rest

let repeated_call trace =
  Trace.repeated_groups trace
  |> List.map (fun group ->
      let count = List.length group in
      let representative = List.hd group in
      let waste =
        match group with
        | [] -> 0
        | _ :: repeats ->
            List.fold_left
              (fun acc call -> acc + Trace.Call.result_bytes call)
              0 repeats
      in
      {
        detector = "repeated-call";
        severity = (if count >= 4 then Major else Minor);
        steps = step_range group;
        message =
          Printf.sprintf "%s called %d times with identical arguments"
            (Trace.Call.name representative)
            count;
        evidence =
          Printf.sprintf "%s %s"
            (Trace.Call.name representative)
            (Trace.Call.arguments_digest representative);
        waste_tokens = Some waste;
      })

let failure_streak trace =
  Trace.failure_streaks trace
  |> List.filter (fun streak -> List.length streak >= 3)
  |> List.map (fun streak ->
      let name = Trace.Call.name (List.hd streak) in
      {
        detector = "failure-streak";
        severity = Major;
        steps = step_range streak;
        message =
          Printf.sprintf "%s failed %d times in a row" name (List.length streak);
        evidence = Trace.Call.result_digest (List.hd streak);
        waste_tokens = None;
      })

let reread_unchanged trace =
  Trace.rereads trace
  |> List.map (fun (original, reread) ->
      let path = Option.value (Trace.Call.read_path reread) ~default:"?" in
      {
        detector = "reread-unchanged";
        severity = Minor;
        steps = (Trace.Call.step_index original, Trace.Call.step_index reread);
        message = Printf.sprintf "re-read %s with no intervening change" path;
        evidence = path;
        waste_tokens = Some (Trace.Call.result_bytes reread);
      })

let shell_family_histogram trace =
  match Trace.shell_families trace with
  | [] -> []
  | families ->
      let shell_calls =
        List.filter
          (fun call -> Trace.Call.name call = "shell")
          (Trace.calls trace)
      in
      let total =
        List.fold_left (fun acc (_, count) -> acc + count) 0 families
      in
      let evidence =
        String.concat "; "
          (List.map
             (fun (family, count) ->
               Printf.sprintf "%s \xc3\x97%d" family count)
             families)
      in
      [
        {
          detector = "shell-family-histogram";
          severity = Info;
          steps = step_range shell_calls;
          message =
            Printf.sprintf "%d shell calls across %d families" total
              (List.length families);
          evidence;
          waste_tokens = None;
        };
      ]

let builtin =
  [
    ("repeated-call", repeated_call);
    ("failure-streak", failure_streak);
    ("reread-unchanged", reread_unchanged);
    ("shell-family-histogram", shell_family_histogram);
  ]

let detect detectors trace =
  List.concat_map (fun (_, detector) -> detector trace) detectors
