(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Json = Jsont.Json
module Llm = Spice_llm
module Permission = Spice_permission
module Session = Spice_session
module Run = Spice_session_run

type result = {
  operations : int;
  seconds : float;
  minor_words : float;
  promoted_words : float;
  major_words : float;
}

let ok label = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%s: %a" label Run.Error.pp error)

let ok_session label = function
  | Ok value -> value
  | Error error ->
      failwith (Format.asprintf "%s: %a" label Session.Error.pp error)

let bench name ~iters f =
  Gc.compact ();
  ignore (Sys.opaque_identity (f ()));
  Gc.compact ();
  let before = Gc.quick_stat () in
  let started = Sys.time () in
  for _ = 1 to iters do
    ignore (Sys.opaque_identity (f ()))
  done;
  let seconds = Sys.time () -. started in
  let after = Gc.quick_stat () in
  let result =
    {
      operations = iters;
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
    (per_op result.major_words);
  result

let print_ratio label smaller larger =
  let per_op result value = value /. float result.operations in
  Printf.printf "%-28s time %5.2fx  minor %5.2fx\n%!" label
    (per_op larger larger.seconds /. per_op smaller smaller.seconds)
    (per_op larger larger.minor_words /. per_op smaller smaller.minor_words)

let model =
  Llm.Model.make
    ~provider:(Llm.Provider.make "openai")
    ~api:(Llm.Model.Api.make "responses")
    ~id:"benchmark"

let config =
  Run.Config.make ~tools:[] ~policy:Permission.Policy.default ()

let base_session =
  let cwd = Spice_path.Abs.of_string_exn "/benchmark" in
  let session =
    Session.create ~id:(Session.Id.of_string "bench-session") ~cwd
      ~created_at:(Session.Time.of_unix_ms 0L) ()
  in
  Run.start config ~id:(Session.Turn.Id.of_string "bench-turn")
    ~input:(Session.Turn.Input.user_text "Reject the calls.") ~model session
  |> ok "start" |> Run.Step.session

let response call_count =
  let parts =
    List.init call_count (fun index ->
        let call =
          Llm.Tool.Call.make ~id:("call-" ^ string_of_int index)
            ~name:"missing_tool" ~input:(Json.object' []) ()
        in
        Llm.Message.Assistant.tool_call call)
  in
  Llm.Response.make ~model (Llm.Message.Assistant.make parts)

let automatic_rejections call_count =
  let response = response call_count in
  fun () ->
    Run.accept_response config response base_session |> ok "accept_response"

let idle_session =
  Session.create ~id:(Session.Id.of_string "append-session")
    ~cwd:(Spice_path.Abs.of_string_exn "/benchmark")
    ~created_at:(Session.Time.of_unix_ms 0L) ()

let append_events count =
  List.init count (fun _ ->
      Session.Event.message_appended (Llm.Message.developer "benchmark"))

let append_batch count =
  let events = append_events count in
  fun () -> Session.Log.append_all events idle_session |> ok_session "append_all"

let append_incrementally count =
  let events = append_events count in
  fun () ->
    List.fold_left
      (fun session event ->
        Session.Log.append event session |> ok_session "append")
      idle_session events

let () =
  Printf.printf "\nSession benchmarks\n";
  ignore (bench "reject 100 calls" ~iters:100 (automatic_rejections 100));
  ignore (bench "reject 500 calls" ~iters:10 (automatic_rejections 500));
  ignore (bench "reject 1000 calls" ~iters:3 (automatic_rejections 1_000));
  ignore (bench "reject 2000 calls" ~iters:1 (automatic_rejections 2_000));
  let batch_2500 = bench "append_all 2500" ~iters:20 (append_batch 2_500) in
  let batch_5000 = bench "append_all 5000" ~iters:10 (append_batch 5_000) in
  let batch_10000 =
    bench "append_all 10000" ~iters:5 (append_batch 10_000)
  in
  print_ratio "append_all 5k / 2.5k" batch_2500 batch_5000;
  print_ratio "append_all 10k / 5k" batch_5000 batch_10000;
  let one_2500 =
    bench "append 2500" ~iters:20 (append_incrementally 2_500)
  in
  let one_5000 = bench "append 5000" ~iters:10 (append_incrementally 5_000) in
  let one_10000 =
    bench "append 10000" ~iters:5 (append_incrementally 10_000)
  in
  print_ratio "append 5k / 2.5k" one_2500 one_5000;
  print_ratio "append 10k / 5k" one_5000 one_10000
