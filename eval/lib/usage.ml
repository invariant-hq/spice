(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  input : int;
  output : int;
  cache_read : int;
  cache_write : int;
  reasoning : int;
}

let invalid fn message = invalid_arg ("Spice_eval.Usage." ^ fn ^ ": " ^ message)
let decode_error message = Jsont.Error.msg Jsont.Meta.none message

let decode_invalid_arg f =
  match f () with
  | value -> value
  | exception Invalid_argument message -> decode_error message

let non_negative fn field value =
  if value < 0 then invalid fn (field ^ " must be non-negative")

let make ?(input = 0) ?(output = 0) ?(cache_read = 0) ?(cache_write = 0)
    ?(reasoning = 0) () =
  non_negative "make" "input" input;
  non_negative "make" "output" output;
  non_negative "make" "cache_read" cache_read;
  non_negative "make" "cache_write" cache_write;
  non_negative "make" "reasoning" reasoning;
  { input; output; cache_read; cache_write; reasoning }

let input_total t = t.input + t.cache_read + t.cache_write
let output_total t = t.output + t.reasoning

let pp ppf t =
  Format.fprintf ppf
    "{ input = %d; output = %d; cache_read = %d; cache_write = %d; reasoning = \
     %d }"
    t.input t.output t.cache_read t.cache_write t.reasoning

let equal a b = a = b

let jsont =
  let make input output cache_read cache_write reasoning =
    decode_invalid_arg (fun () ->
        make ~input ~output ~cache_read ~cache_write ~reasoning ())
  in
  Jsont.Object.map ~kind:"eval usage" make
  |> Jsont.Object.mem "input" Jsont.int ~enc:(fun t -> t.input)
  |> Jsont.Object.mem "output" Jsont.int ~enc:(fun t -> t.output)
  |> Jsont.Object.mem "cache_read" Jsont.int ~enc:(fun t -> t.cache_read)
  |> Jsont.Object.mem "cache_write" Jsont.int ~enc:(fun t -> t.cache_write)
  |> Jsont.Object.mem "reasoning" Jsont.int ~enc:(fun t -> t.reasoning)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
