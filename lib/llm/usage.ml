(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

type t = {
  input : int;
  output : int;
  reasoning : int;
  cache_read : int;
  cache_write : int;
}

let invalid fn message = invalid_arg' "Spice_llm.Usage" fn message

let check_non_negative field value =
  if value < 0 then invalid "make" (field ^ " must be non-negative")

let add_checked fn a b =
  if a > max_int - b then invalid fn "overflow" else a + b

let make ~input ~output ?(reasoning = 0) ?(cache_read = 0) ?(cache_write = 0) ()
    =
  check_non_negative "input" input;
  check_non_negative "output" output;
  check_non_negative "reasoning" reasoning;
  check_non_negative "cache_read" cache_read;
  check_non_negative "cache_write" cache_write;
  { input; output; reasoning; cache_read; cache_write }

let zero =
  { input = 0; output = 0; reasoning = 0; cache_read = 0; cache_write = 0 }

let add a b =
  make
    ~input:(add_checked "add" a.input b.input)
    ~output:(add_checked "add" a.output b.output)
    ~reasoning:(add_checked "add" a.reasoning b.reasoning)
    ~cache_read:(add_checked "add" a.cache_read b.cache_read)
    ~cache_write:(add_checked "add" a.cache_write b.cache_write)
    ()

let input_total t =
  add_checked "input_total"
    (add_checked "input_total" t.input t.cache_read)
    t.cache_write

let output_total t = add_checked "output_total" t.output t.reasoning
let sum_lanes t = add_checked "sum_lanes" (input_total t) (output_total t)
let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf
    "{ input = %d; output = %d; reasoning = %d; cache_read = %d; cache_write = \
     %d }"
    t.input t.output t.reasoning t.cache_read t.cache_write

let jsont =
  let make input output reasoning cache_read cache_write =
    decode_invalid_arg (fun () ->
        make ~input ~output ~reasoning ~cache_read ~cache_write ())
  in
  Jsont.Object.map ~kind:"LLM usage" make
  |> Jsont.Object.mem "input" Jsont.int ~enc:(fun t -> t.input)
  |> Jsont.Object.mem "output" Jsont.int ~enc:(fun t -> t.output)
  |> Jsont.Object.mem "reasoning" Jsont.int ~enc:(fun t -> t.reasoning)
  |> Jsont.Object.mem "cache_read" Jsont.int ~enc:(fun t -> t.cache_read)
  |> Jsont.Object.mem "cache_write" Jsont.int ~enc:(fun t -> t.cache_write)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish
