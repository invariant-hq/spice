(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Notice_queue = Spice_host.Notice_queue
module Notice = Spice_protocol.Notice

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
    ]
