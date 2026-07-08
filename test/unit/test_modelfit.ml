(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Fit = Spice_modelfit

let mib = 1024 * 1024
let gib = 1024 * mib
let verdict = testable ~pp:Fit.Verdict.pp ~equal:Fit.Verdict.equal ()

let gguf_error =
  testable ~pp:Fit.Gguf.Error.pp
    ~equal:(fun a b ->
      match (a, b) with
      | Fit.Gguf.Error.Truncated, Fit.Gguf.Error.Truncated -> true
      | Fit.Gguf.Error.Malformed a, Fit.Gguf.Error.Malformed b ->
          String.equal a b
      | (Fit.Gguf.Error.Truncated | Fit.Gguf.Error.Malformed _), _ -> false)
    ()

let gguf_model_error =
  testable ~pp:Fit.Gguf.Model_error.pp
    ~equal:(fun a b ->
      match (a, b) with
      | Fit.Gguf.Model_error.Missing_metadata { key = a },
        Fit.Gguf.Model_error.Missing_metadata { key = b } ->
          String.equal a b
      | Fit.Gguf.Model_error.Missing_any_metadata { keys = a },
        Fit.Gguf.Model_error.Missing_any_metadata { keys = b } ->
          List.equal String.equal a b
      | Fit.Gguf.Model_error.Invalid_metadata { key = a },
        Fit.Gguf.Model_error.Invalid_metadata { key = b } ->
          String.equal a b
      | Fit.Gguf.Model_error.Invalid_head_dimensions { architecture = a },
        Fit.Gguf.Model_error.Invalid_head_dimensions { architecture = b } ->
          String.equal a b
      | ( Fit.Gguf.Model_error.Missing_metadata _
        | Fit.Gguf.Model_error.Missing_any_metadata _
        | Fit.Gguf.Model_error.Invalid_metadata _
        | Fit.Gguf.Model_error.Invalid_head_dimensions _ ),
        _ ->
          false)
    ()

(* A reference shape: 32 layers, 8 KV heads, head dim 128. At a 32768-token
   f16 cache this is exactly 4 GiB of KV. *)
let reference ?(weights_bytes = 8 * gib) ?(max_context = 131072) () =
  Fit.Model.make ~weights_bytes ~n_layers:32 ~n_kv_heads:8 ~head_dim:128
    ~max_context

(* Machine *)

let machine_budget () =
  let plain = Fit.Machine.make ~os:Fit.Machine.Macos ~ram_bytes:(32 * gib) () in
  equal int ~msg:"default budget is 75% of RAM" (24 * gib)
    (Fit.Machine.budget plain);
  equal int ~msg:"ram is observable" (32 * gib) (Fit.Machine.ram_bytes plain);
  let raised =
    Fit.Machine.make ~os:Fit.Machine.Macos ~ram_bytes:(32 * gib)
      ~wired_limit_bytes:(28 * gib) ()
  in
  equal int ~msg:"wired limit overrides the macos budget" (28 * gib)
    (Fit.Machine.budget raised);
  let linux =
    Fit.Machine.make ~os:Fit.Machine.Linux ~ram_bytes:(32 * gib)
      ~wired_limit_bytes:(28 * gib) ()
  in
  equal int ~msg:"wired limit is macos-only" (24 * gib)
    (Fit.Machine.budget linux)

let machine_detect () =
  (* Effectful probe; macOS and Linux, the supported platforms, always
     expose physical memory. *)
  match Fit.Machine.detect () with
  | Some machine ->
      check "detected ram is positive" (Fit.Machine.ram_bytes machine > 0);
      check "budget does not exceed ram"
        (Fit.Machine.budget machine <= Fit.Machine.ram_bytes machine)
  | None -> failf "expected to detect machine memory"

let machine_validation () =
  expect_invalid_arg "ram must be positive" (fun () ->
      Fit.Machine.make ~os:Fit.Machine.Other ~ram_bytes:0 ());
  expect_invalid_arg "wired limit must be positive" (fun () ->
      Fit.Machine.make ~os:Fit.Machine.Macos ~ram_bytes:gib ~wired_limit_bytes:0
        ())

(* Estimates *)

let estimate_decomposition () =
  let model = reference () in
  let est = Fit.estimate ~context:32768 model in
  equal int ~msg:"weights pass through" (8 * gib) est.Fit.Estimate.weights_bytes;
  equal int ~msg:"f16 kv cache" (4 * gib) est.Fit.Estimate.kv_cache_bytes;
  equal int ~msg:"overhead is graph plus safety margin"
    (gib + (640 * mib))
    est.Fit.Estimate.overhead_bytes;
  equal int ~msg:"total sums the parts"
    ((12 * gib) + gib + (640 * mib))
    (Fit.Estimate.total_bytes est)

let estimate_kv_dtypes () =
  let model = reference () in
  let kv dtype =
    (Fit.estimate ~kv_dtype:dtype ~context:32768 model)
      .Fit.Estimate.kv_cache_bytes
  in
  equal int ~msg:"q8_0 cache is 34/64 of f16" (4 * gib * 17 / 32) (kv Fit.Q8_0);
  equal int ~msg:"q4_0 cache is 18/64 of f16" (4 * gib * 9 / 32) (kv Fit.Q4_0)

let estimate_clamps_context () =
  let model = reference ~max_context:16384 () in
  equal int ~msg:"context clamps to the model maximum"
    (Fit.estimate ~context:16384 model).Fit.Estimate.kv_cache_bytes
    (Fit.estimate ~context:131072 model).Fit.Estimate.kv_cache_bytes;
  expect_invalid_arg "context must be positive" (fun () ->
      Fit.estimate ~context:0 model)

(* Verdicts *)

let overhead =
  (Fit.estimate ~context:1 (reference ())).Fit.Estimate.overhead_bytes

(* Budget that fits the reference model's weights, overhead, and exactly
   [tokens] of f16 KV cache (128 KiB per token). *)
let budget_for_tokens tokens = (8 * gib) + overhead + (tokens * 128 * 1024)

let max_context_boundaries () =
  let model = reference () in
  equal (option int) ~msg:"weights alone over budget" None
    (Fit.max_context ~budget:(8 * gib) model);
  equal (option int) ~msg:"exact budget for 16k tokens" (Some 16384)
    (Fit.max_context ~budget:(budget_for_tokens 16384) model);
  equal (option int) ~msg:"clamps to the model maximum" (Some 131072)
    (Fit.max_context ~budget:(budget_for_tokens 999999) model)

let verdict_boundaries () =
  let model = reference () in
  equal verdict ~msg:"ample budget fits" Fit.Verdict.Fits
    (Fit.verdict ~budget:(budget_for_tokens 32768) model);
  equal verdict ~msg:"between minimum and requested is tight"
    (Fit.Verdict.Tight { max_context = 16384 })
    (Fit.verdict ~budget:(budget_for_tokens 16384) model);
  equal verdict ~msg:"below the useful minimum won't run" Fit.Verdict.Wont_run
    (Fit.verdict ~budget:(budget_for_tokens 4096) model);
  equal verdict ~msg:"weights alone over budget won't run" Fit.Verdict.Wont_run
    (Fit.verdict ~budget:gib model);
  equal verdict ~msg:"a small-context model can still fit" Fit.Verdict.Fits
    (Fit.verdict ~budget:(budget_for_tokens 4096)
       (reference ~max_context:4096 ()));
  expect_invalid_arg "context must be positive" (fun () ->
      Fit.verdict ~context:0 ~budget:gib model)

(* GGUF headers *)

let b_u32 buf v = Buffer.add_int32_le buf (Int32.of_int v)
let b_u64 buf v = Buffer.add_int64_le buf (Int64.of_int v)

let b_str buf s =
  b_u64 buf (String.length s);
  Buffer.add_string buf s

let kv_string buf key v =
  b_str buf key;
  b_u32 buf 8;
  b_str buf v

let kv_u32 buf key v =
  b_str buf key;
  b_u32 buf 4;
  b_u32 buf v

let kv_u64 buf key v =
  b_str buf key;
  b_u32 buf 10;
  b_u64 buf v

let kv_u32_array buf key vs =
  b_str buf key;
  b_u32 buf 9;
  b_u32 buf 4;
  b_u64 buf (List.length vs);
  List.iter (b_u32 buf) vs

let gguf ?(version = 3) ?kv_count kvs =
  let body = Buffer.create 256 in
  List.iter (fun kv -> kv body) kvs;
  let buf = Buffer.create 256 in
  Buffer.add_string buf "GGUF";
  b_u32 buf version;
  b_u64 buf 0;
  b_u64 buf (Option.value kv_count ~default:(List.length kvs));
  Buffer.add_buffer buf body;
  Buffer.contents buf

let qwen_kvs =
  [
    (fun b -> kv_string b "general.architecture" "qwen3moe");
    (fun b -> kv_string b "general.name" "Qwen3 Coder 30B");
    (fun b -> kv_u32 b "qwen3moe.block_count" 48);
    (fun b -> kv_u64 b "qwen3moe.context_length" 262144);
    (fun b -> kv_u32 b "qwen3moe.embedding_length" 2048);
    (fun b -> kv_u32 b "qwen3moe.attention.head_count" 32);
    (fun b -> kv_u32 b "qwen3moe.attention.head_count_kv" 4);
  ]

let expect_gguf data =
  match Fit.Gguf.of_prefix data with
  | Ok gguf -> gguf
  | Error error -> failf "unexpected parse error: %a" Fit.Gguf.Error.pp error

let expect_model ~weights_bytes gguf =
  match Fit.Gguf.model ~weights_bytes gguf with
  | Ok model -> model
  | Error error ->
      failf "unexpected model error: %a" Fit.Gguf.Model_error.pp error

let gguf_parses_metadata () =
  let parsed = expect_gguf (gguf qwen_kvs) in
  equal string ~msg:"architecture" "qwen3moe" (Fit.Gguf.architecture parsed);
  equal (option string) ~msg:"name" (Some "Qwen3 Coder 30B")
    (Fit.Gguf.name parsed);
  let model = expect_model ~weights_bytes:(19 * gib) parsed in
  equal int ~msg:"layers" 48 (Fit.Model.n_layers model);
  equal int ~msg:"kv heads" 4 (Fit.Model.n_kv_heads model);
  equal int ~msg:"head dim from embedding/head_count" 64
    (Fit.Model.head_dim model);
  equal int ~msg:"max context" 262144 (Fit.Model.max_context model);
  equal int ~msg:"weights" (19 * gib) (Fit.Model.weights_bytes model)

let gguf_head_dim_overrides () =
  let with_lengths =
    qwen_kvs
    @ [
        (fun b -> kv_u32 b "qwen3moe.attention.key_length" 128);
        (fun b -> kv_u32 b "qwen3moe.attention.value_length" 96);
      ]
  in
  let model =
    expect_model ~weights_bytes:gib (expect_gguf (gguf with_lengths))
  in
  equal int ~msg:"head dim is the mean of key and value lengths" 112
    (Fit.Model.head_dim model)

let gguf_per_layer_kv_heads () =
  let kvs =
    List.filteri (fun i _ -> i <> 6) qwen_kvs
    @ [
        (fun b -> kv_u32_array b "qwen3moe.attention.head_count_kv" [ 2; 8; 4 ]);
      ]
  in
  let model = expect_model ~weights_bytes:gib (expect_gguf (gguf kvs)) in
  equal int ~msg:"per-layer kv heads reduce to their maximum" 8
    (Fit.Model.n_kv_heads model)

let gguf_stops_before_tokenizer () =
  (* The tokenizer value is declared but absent: parsing must stop at the
     boundary once the guard inputs are derivable, and never read it. *)
  let data =
    gguf ~kv_count:8 (qwen_kvs @ [ (fun b -> b_str b "tokenizer.ggml.tokens") ])
  in
  let model = expect_model ~weights_bytes:gib (expect_gguf data) in
  equal int ~msg:"metadata before the tokenizer is enough" 48
    (Fit.Model.n_layers model)

let gguf_truncation_and_malformed () =
  let whole = gguf qwen_kvs in
  equal
    (result (option string) gguf_error)
    ~msg:"mid-metadata cut" (Error Fit.Gguf.Error.Truncated)
    (Result.map Fit.Gguf.name
       (Fit.Gguf.of_prefix (String.sub whole 0 (String.length whole - 9))));
  equal
    (result (option string) gguf_error)
    ~msg:"bad magic" (Error (Fit.Gguf.Error.Malformed "bad magic"))
    (Result.map Fit.Gguf.name (Fit.Gguf.of_prefix "GGML garbage"));
  equal
    (result (option string) gguf_error)
    ~msg:"unsupported version"
    (Error (Fit.Gguf.Error.Malformed "unsupported GGUF version 1"))
    (Result.map Fit.Gguf.name (Fit.Gguf.of_prefix (gguf ~version:1 qwen_kvs)));
  equal
    (result (option string) gguf_error)
    ~msg:"missing architecture"
    (Error (Fit.Gguf.Error.Malformed "missing general.architecture"))
    (Result.map Fit.Gguf.name
       (Fit.Gguf.of_prefix (gguf [ (fun b -> kv_u32 b "some.key" 1) ])))

let gguf_missing_keys () =
  let no_layers = List.filteri (fun i _ -> i <> 2) qwen_kvs in
  equal (result int gguf_model_error) ~msg:"missing block_count"
    (Error
       (Fit.Gguf.Model_error.Missing_metadata
          { key = "qwen3moe.block_count" }))
    (Result.map Fit.Model.n_layers
       (Fit.Gguf.model ~weights_bytes:gib (expect_gguf (gguf no_layers))));
  expect_invalid_arg "weights must be positive" (fun () ->
      Fit.Gguf.model ~weights_bytes:0 (expect_gguf (gguf qwen_kvs)))

let () =
  run "spice.modelfit"
    [
      group "machine"
        [
          test "budget heuristics" machine_budget;
          test "detects this machine" machine_detect;
          test "validates construction" machine_validation;
        ];
      group "estimate"
        [
          test "decomposes weights, kv, overhead" estimate_decomposition;
          test "scales with kv cache dtype" estimate_kv_dtypes;
          test "clamps context to the model maximum" estimate_clamps_context;
        ];
      group "verdict"
        [
          test "max context boundaries" max_context_boundaries;
          test "fits, tight, and won't run" verdict_boundaries;
        ];
      group "gguf"
        [
          test "parses fit metadata" gguf_parses_metadata;
          test "key/value lengths override head dim" gguf_head_dim_overrides;
          test "per-layer kv heads take the maximum" gguf_per_layer_kv_heads;
          test "stops at the tokenizer boundary" gguf_stops_before_tokenizer;
          test "reports truncated and malformed input"
            gguf_truncation_and_malformed;
          test "reports missing keys" gguf_missing_keys;
        ];
    ]
