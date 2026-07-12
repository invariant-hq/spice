(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Claim_id = Spice_session.Tool_claim.Id
module Claim_set = Set.Make (Claim_id)
module Path_set = Set.Make (Spice_path.Rel)

type t = {
  publish : Spice_fswatch.Event.t list -> unit;
  mutex : Eio.Mutex.t;
  mutable active : Claim_set.t;
  mutable own_paths : Path_set.t;
  mutable buffered_rev : Spice_fswatch.Event.t list list;
}

let create ~publish () =
  {
    publish;
    mutex = Eio.Mutex.create ();
    active = Claim_set.empty;
    own_paths = Path_set.empty;
    buffered_rev = [];
  }

let with_state t f = Eio.Mutex.use_rw ~protect:true t.mutex f

let observe t events =
  let publish =
    with_state t (fun () ->
        if Claim_set.is_empty t.active then Some events
        else begin
          t.buffered_rev <- events :: t.buffered_rev;
          None
        end)
  in
  Option.iter t.publish publish

let claim_started t id =
  with_state t (fun () -> t.active <- Claim_set.add id t.active)

let residual_events own_paths buffered_rev =
  List.rev buffered_rev |> List.flatten
  |> List.filter (fun (event : Spice_fswatch.Event.t) ->
      not (Path_set.mem event.Spice_fswatch.Event.path own_paths))

let claim_settled t id own_paths =
  let residual =
    with_state t (fun () ->
        t.active <- Claim_set.remove id t.active;
        t.own_paths <-
          List.fold_left
            (fun paths path -> Path_set.add path paths)
            t.own_paths own_paths;
        if Claim_set.is_empty t.active then begin
          let residual = residual_events t.own_paths t.buffered_rev in
          t.own_paths <- Path_set.empty;
          t.buffered_rev <- [];
          Some residual
        end
        else None)
  in
  Option.iter
    (function [] -> () | events -> t.publish events)
    residual

let receipt_paths result =
  match Spice_tool.Result.output result with
  | None -> []
  | Some output -> (
      match Spice_tools.Evidence.mutation output with
      | None -> []
      | Some receipt ->
          Spice_tools.Receipt.paths receipt |> List.map Spice_workspace.Path.rel
      )

let around_tool ~shell_changes t ~observe:_ _document execution finish_previous
    =
  let call = Spice_session.Tool_claim.Started.call execution in
  let tool = Spice_llm.Tool.Call.name call in
  if not (Spice_tools.mutating_tool tool) then finish_previous
  else
    let finish_shell =
      if String.equal tool "shell" then Some (shell_changes ()) else None
    in
    let id = Spice_session.Tool_claim.Started.id execution in
    claim_started t id;
    fun result ->
      let own_paths =
        receipt_paths result
        @ Option.fold ~none:[] ~some:(fun finish -> finish ()) finish_shell
      in
      match finish_previous result with
      | () -> claim_settled t id own_paths
      | exception exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          claim_settled t id own_paths;
          Printexc.raise_with_backtrace exn backtrace

let hook ~shell_changes t hooks =
  Session.with_around_tool (around_tool ~shell_changes t) hooks
