(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Notice_queue = Spice_host.Notice_queue
module Notice = Spice_protocol.Notice
module Runner = Spice_host.Runner
module Host_session = Spice_host.Session
module Session = Spice_session
module Store = Spice_session_store
module Llm = Spice_llm

let provider = Llm.Provider.make "openai"

let model =
  Llm.Model.make ~provider ~api:(Llm.Model.Api.make "responses") ~id:"gpt-test"

let cwd = Spice_path.Abs.of_string_exn "/workspace"

let notice id key =
  Notice.make ~source:"test" ~severity:Notice.Severity.Info ~title:id
    ~body:("body " ^ id) ~key ()

let titles notices = List.map Notice.title notices
let drain queue = Notice_queue.(take queue |> notices)

let publish_drains_oldest_to_newest_and_coalesces () =
  Eio_main.run @@ fun _ ->
  let queue = Notice_queue.create () in
  Notice_queue.publish queue (notice "a" "same");
  Notice_queue.publish queue (notice "b" "other");
  Notice_queue.publish queue (notice "c" "same");
  equal (list string) ~msg:"newest same-key notice wins" [ "b"; "c" ]
    (drain queue |> titles);
  is_true ~msg:"drain empties the queue" (Notice_queue.is_empty queue)

let take_exposes_batch_and_commit_consumes_notices () =
  Eio_main.run @@ fun _ ->
  let queue = Notice_queue.create () in
  Notice_queue.publish queue (notice "a" "a");
  Notice_queue.publish queue (notice "b" "b");
  let batch = Notice_queue.take queue in
  equal (list string) ~msg:"batch notices are oldest to newest" [ "a"; "b" ]
    (Notice_queue.notices batch |> titles);
  is_true ~msg:"take empties the queue" (Notice_queue.is_empty queue);
  Notice_queue.commit batch;
  Notice_queue.rollback batch;
  is_true ~msg:"committed batch is not restored" (Notice_queue.is_empty queue)

let rollback_restores_batch_without_overwriting_newer_facts () =
  Eio_main.run @@ fun _ ->
  let queue = Notice_queue.create () in
  Notice_queue.publish queue (notice "a" "a");
  Notice_queue.publish queue (notice "b" "b");
  let batch = Notice_queue.take queue in
  Notice_queue.publish queue (notice "c" "c");
  Notice_queue.publish queue (notice "newer-a" "a");
  Notice_queue.rollback batch;
  Notice_queue.commit batch;
  equal (list string)
    ~msg:"rolled back notices are older and do not replace newer facts"
    [ "b"; "c"; "newer-a" ]
    (Notice_queue.take queue |> Notice_queue.notices |> titles)

let capacity_drops_oldest_notices () =
  Eio_main.run @@ fun _ ->
  let queue = Notice_queue.create ~capacity:2 () in
  Notice_queue.publish queue (notice "a" "a");
  Notice_queue.publish queue (notice "b" "b");
  Notice_queue.publish queue (notice "c" "c");
  equal (list string) ~msg:"publish enforces capacity" [ "b"; "c" ]
    (drain queue |> titles)

let title_only_notice_has_no_blank_body () =
  let notice =
    Notice.make ~source:"subagents" ~severity:Notice.Severity.Warning
      ~title:"subagent cancelled" ~key:"run:child" ()
  in
  equal (option string) ~msg:"title-only notice has no body" None
    (Notice.body notice);
  match Notice.to_message notice with
  | Spice_llm.Message.Developer text ->
      equal string ~msg:"title-only rendering ends at the title"
        "[spice notice]\nsource: subagents\nseverity: warning\ntitle: subagent cancelled"
        text
  | _ -> failf "notice should render as a developer message"

exception Model_failure

let raised_model_call_rolls_notices_back () =
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  let root = Filename.temp_dir "spice_notice_rollback" "" in
  let store =
    Store.make ~fs ~clock:(Eio.Stdenv.clock env)
      ~root:(Spice_path.Abs.of_string_exn root)
  in
  let session =
    Session.create ~id:(Session.Id.of_string "session-1") ~cwd
      ~created_at:(Session.Time.of_unix_ms 1L) ()
  in
  let document =
    match Store.create store session with
    | Ok document -> document
    | Error error -> failf "session create failed: %a" Store.Error.pp error
  in
  let queue = Notice_queue.create () in
  Notice_queue.publish queue (notice "durable" "durable");
  let client =
    Llm.Client.make ~provider
      ~run:(fun ~cancelled:_ _request -> raise Model_failure)
      ()
  in
  let run =
    Session.Run.Config.make ~tools:[]
      ~policy:Spice_permission.Policy.default ()
  in
  let hooks =
    Host_session.with_notices queue Host_session.no_hooks
  in
  let runner = Runner.make ~store ~client ~model ~mode:None ~run ~hooks () in
  let start =
    Spice_protocol.Command.Start.make
      ~id:(Session.Turn.Id.of_string "turn-1")
      ~input:(Session.Turn.Input.user_text "Continue.") ()
  in
  (match Runner.execute runner document (Spice_protocol.Command.Start start) with
  | _ -> failf "model failure must escape the interpreter"
  | exception Model_failure -> ());
  equal (list string) ~msg:"raised model call restores the prepared batch"
    [ "durable" ]
    (drain queue |> titles)

let () =
  run "spice.host.notice"
    [
      test "publish drains oldest to newest and coalesces"
        publish_drains_oldest_to_newest_and_coalesces;
      test "take exposes batch and commit consumes notices"
        take_exposes_batch_and_commit_consumes_notices;
      test "rollback restores batch without overwriting newer facts"
        rollback_restores_batch_without_overwriting_newer_facts;
      test "capacity drops oldest notices" capacity_drops_oldest_notices;
      test "title-only notice has no blank body"
        title_only_notice_has_no_blank_body;
      test "raised model call rolls notices back"
        raised_model_call_rolls_notices_back;
    ]
