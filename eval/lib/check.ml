(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type test =
  | Shell of string
  | Diff_within of string list
  | Diff_touches_any of string list
  | Diff_touches_all of string list
  | Diff_free_of of string

type kind = [ `Gate | `Penalty of float | `Judge of float ]

type t =
  | Gate of { name : string; test : test }
  | Penalty of { name : string; points : float; test : test }
  | Judge of { name : string; weight : float; criterion : string }

let invalid fn message = invalid_arg ("Spice_eval.Check." ^ fn ^ ": " ^ message)
let decode_error message = Jsont.Error.msg Jsont.Meta.none message

let decode_invalid_arg f =
  match f () with
  | value -> value
  | exception Invalid_argument message -> decode_error message

let non_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let non_empty_list fn field values =
  match values with
  | [] -> invalid fn (field ^ " must not be empty")
  | _ :: _ -> List.iter (non_empty fn field) values

let is_positive_finite value =
  match classify_float value with
  | FP_normal | FP_subnormal -> value > 0.
  | FP_zero | FP_infinite | FP_nan -> false

let positive_float fn field value =
  if not (is_positive_finite value) then invalid fn (field ^ " must be positive")

let shell command =
  non_empty "shell" "command" command;
  Shell command

let diff_within globs =
  non_empty_list "diff_within" "glob" globs;
  Diff_within globs

let diff_touches_any globs =
  non_empty_list "diff_touches_any" "glob" globs;
  Diff_touches_any globs

let diff_touches_all globs =
  non_empty_list "diff_touches_all" "glob" globs;
  Diff_touches_all globs

let diff_free_of regex =
  non_empty "diff_free_of" "regex" regex;
  Diff_free_of regex

let gate name test =
  non_empty "gate" "name" name;
  Gate { name; test }

let penalty name ~points test =
  non_empty "penalty" "name" name;
  positive_float "penalty" "points" points;
  Penalty { name; points; test }

let judge name ?(weight = 1.) ~criterion () =
  non_empty "judge" "name" name;
  positive_float "judge" "weight" weight;
  non_empty "judge" "criterion" criterion;
  Judge { name; weight; criterion }

let name = function
  | Gate { name; _ } | Penalty { name; _ } | Judge { name; _ } -> name

let kind = function
  | Gate _ -> `Gate
  | Penalty { points; _ } -> `Penalty points
  | Judge { weight; _ } -> `Judge weight

let pp_string_list ppf values =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
    Format.pp_print_string ppf values

let pp_test ppf = function
  | Shell command -> Format.fprintf ppf "shell %S" command
  | Diff_within globs ->
      Format.fprintf ppf "diff within [%a]" pp_string_list globs
  | Diff_touches_any globs ->
      Format.fprintf ppf "diff touches any [%a]" pp_string_list globs
  | Diff_touches_all globs ->
      Format.fprintf ppf "diff touches all [%a]" pp_string_list globs
  | Diff_free_of regex -> Format.fprintf ppf "diff free of %S" regex

let pp ppf = function
  | Gate { name; test } -> Format.fprintf ppf "%s (gate: %a)" name pp_test test
  | Penalty { name; points; test } ->
      Format.fprintf ppf "%s (penalty %.3g: %a)" name points pp_test test
  | Judge { name; weight; criterion } ->
      Format.fprintf ppf "%s (judge %.3g: %s)" name weight criterion

let equal a b = a = b

let test_jsont =
  let shell_case =
    Jsont.Object.map ~kind:"shell check test" (fun command ->
        decode_invalid_arg (fun () -> shell command))
    |> Jsont.Object.mem "command" Jsont.string ~enc:(function
      | Shell command -> command
      | Diff_within _ | Diff_touches_any _ | Diff_touches_all _ | Diff_free_of _
        ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "shell" ~dec:Fun.id
  in
  let diff_within_case =
    Jsont.Object.map ~kind:"diff-within check test" (fun globs ->
        decode_invalid_arg (fun () -> diff_within globs))
    |> Jsont.Object.mem "globs" (Jsont.list Jsont.string) ~enc:(function
      | Diff_within globs -> globs
      | Shell _ | Diff_touches_any _ | Diff_touches_all _ | Diff_free_of _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "diff_within" ~dec:Fun.id
  in
  let diff_touches_any_case =
    Jsont.Object.map ~kind:"diff-touches-any check test" (fun globs ->
        decode_invalid_arg (fun () -> diff_touches_any globs))
    |> Jsont.Object.mem "globs" (Jsont.list Jsont.string) ~enc:(function
      | Diff_touches_any globs -> globs
      | Shell _ | Diff_within _ | Diff_touches_all _ | Diff_free_of _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "diff_touches_any" ~dec:Fun.id
  in
  let diff_touches_all_case =
    Jsont.Object.map ~kind:"diff-touches-all check test" (fun globs ->
        decode_invalid_arg (fun () -> diff_touches_all globs))
    |> Jsont.Object.mem "globs" (Jsont.list Jsont.string) ~enc:(function
      | Diff_touches_all globs -> globs
      | Shell _ | Diff_within _ | Diff_touches_any _ | Diff_free_of _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "diff_touches_all" ~dec:Fun.id
  in
  let diff_free_of_case =
    Jsont.Object.map ~kind:"diff-free-of check test" (fun regex ->
        decode_invalid_arg (fun () -> diff_free_of regex))
    |> Jsont.Object.mem "regex" Jsont.string ~enc:(function
      | Diff_free_of regex -> regex
      | Shell _ | Diff_within _ | Diff_touches_any _ | Diff_touches_all _ ->
          assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "diff_free_of" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [
        shell_case;
        diff_within_case;
        diff_touches_any_case;
        diff_touches_all_case;
        diff_free_of_case;
      ]
  in
  let enc_case = function
    | Shell _ as test -> Jsont.Object.Case.value shell_case test
    | Diff_within _ as test -> Jsont.Object.Case.value diff_within_case test
    | Diff_touches_any _ as test ->
        Jsont.Object.Case.value diff_touches_any_case test
    | Diff_touches_all _ as test ->
        Jsont.Object.Case.value diff_touches_all_case test
    | Diff_free_of _ as test -> Jsont.Object.Case.value diff_free_of_case test
  in
  Jsont.Object.map ~kind:"check test" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let jsont =
  let gate_case =
    Jsont.Object.map ~kind:"gate check" (fun name test ->
        decode_invalid_arg (fun () -> gate name test))
    |> Jsont.Object.mem "name" Jsont.string ~enc:(function
      | Gate { name; _ } -> name
      | Penalty _ | Judge _ -> assert false)
    |> Jsont.Object.mem "test" test_jsont ~enc:(function
      | Gate { test; _ } -> test
      | Penalty _ | Judge _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "gate" ~dec:Fun.id
  in
  let penalty_case =
    Jsont.Object.map ~kind:"penalty check" (fun name points test ->
        decode_invalid_arg (fun () -> penalty name ~points test))
    |> Jsont.Object.mem "name" Jsont.string ~enc:(function
      | Penalty { name; _ } -> name
      | Gate _ | Judge _ -> assert false)
    |> Jsont.Object.mem "points" Jsont.number ~enc:(function
      | Penalty { points; _ } -> points
      | Gate _ | Judge _ -> assert false)
    |> Jsont.Object.mem "test" test_jsont ~enc:(function
      | Penalty { test; _ } -> test
      | Gate _ | Judge _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "penalty" ~dec:Fun.id
  in
  let judge_case =
    Jsont.Object.map ~kind:"judge check" (fun name weight criterion ->
        decode_invalid_arg (fun () -> judge name ~weight ~criterion ()))
    |> Jsont.Object.mem "name" Jsont.string ~enc:(function
      | Judge { name; _ } -> name
      | Gate _ | Penalty _ -> assert false)
    |> Jsont.Object.mem "weight" Jsont.number ~enc:(function
      | Judge { weight; _ } -> weight
      | Gate _ | Penalty _ -> assert false)
    |> Jsont.Object.mem "criterion" Jsont.string ~enc:(function
      | Judge { criterion; _ } -> criterion
      | Gate _ | Penalty _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "judge" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make [ gate_case; penalty_case; judge_case ]
  in
  let enc_case = function
    | Gate _ as check -> Jsont.Object.Case.value gate_case check
    | Penalty _ as check -> Jsont.Object.Case.value penalty_case check
    | Judge _ as check -> Jsont.Object.Case.value judge_case check
  in
  Jsont.Object.map ~kind:"eval check" Fun.id
  |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
