(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Receipt = Spice_tools.Receipt
module Edit = Spice_edit
module W = Spice_workspace
module Path = Spice_path

let rel text = Path.Rel.of_string_exn text
let abs text = Path.Abs.of_string_exn text
let root = W.Root.make (abs "/workspace")

(* Receipt.changes: the one reconciliation of raw edit entries with a tool's
   optional semantic grouping. Result entries can only be produced by
   [Edit.apply], so each case builds a plan, applies it against an in-memory
   filesystem, wraps the result in a receipt, and checks the eliminator. *)

let wpath name = W.Path.make ~root (rel name)
let observed = testable ~pp:Edit.Observed.pp ~equal:Edit.Observed.equal ()

let edit_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %s" msg (Edit.Error.message error)

let result_of fs edit =
  let observed_at path =
    match List.assoc_opt (W.Path.display path) fs with
    | Some contents -> Edit.Observed.Text contents
    | None -> Edit.Observed.Missing
  in
  let io =
    {
      Edit.Apply.with_write_lock = (fun _ f -> f ());
      revalidate = (fun path -> Ok path);
      read = (fun path -> Ok (observed_at path));
      commit = (fun ~path:_ ~before:_ ~after:_ -> Ok ());
    }
  in
  match Edit.apply ~io ~workspace:(W.single root) edit with
  | Error error -> failf "result_of: %s" (Edit.Apply_error.message error)
  | Ok result -> result

let op_to_string : Receipt.op -> string = function
  | Receipt.Create -> "create"
  | Receipt.Modify -> "modify"
  | Receipt.Delete -> "delete"
  | Receipt.Move { from } -> "move:" ^ W.Path.display from

let check_change ~msg (c : Receipt.change) ~path ~op ~before ~after ~diff =
  equal string ~msg:(msg ^ " path") path (W.Path.display c.Receipt.path);
  equal string ~msg:(msg ^ " op") op (op_to_string c.Receipt.op);
  equal observed ~msg:(msg ^ " before") before c.Receipt.before;
  equal observed ~msg:(msg ^ " after") after c.Receipt.after;
  equal (option string) ~msg:(msg ^ " diff") diff c.Receipt.diff

let receipt_raw_changes () =
  let fs = [ ("bar.ml", "old\n"); ("baz.ml", "gone\n") ] in
  let plan =
    edit_ok "concat"
      (Edit.concat
         [
           edit_ok "create"
             (Edit.create ~path:(wpath "foo.ml") ~contents:"new\n");
           edit_ok "rewrite"
             (Edit.rewrite ~path:(wpath "bar.ml") ~before:"old\n"
                ~after:"fresh\n");
           edit_ok "delete"
             (Edit.delete ~path:(wpath "baz.ml") ~before:"gone\n");
         ])
  in
  let receipt = Receipt.make (result_of fs plan) in
  is_true ~msg:"non-empty receipt" (not (Receipt.is_empty receipt));
  equal (list string) ~msg:"paths are applied targets"
    [ "foo.ml"; "bar.ml"; "baz.ml" ]
    (List.map W.Path.display (Receipt.paths receipt));
  (match Receipt.changes receipt with
  | [ create; modify; delete ] ->
      check_change ~msg:"raw create" create ~path:"foo.ml" ~op:"create"
        ~before:Edit.Observed.Missing ~after:(Edit.Observed.Text "new\n")
        ~diff:None;
      check_change ~msg:"raw modify" modify ~path:"bar.ml" ~op:"modify"
        ~before:(Edit.Observed.Text "old\n")
        ~after:(Edit.Observed.Text "fresh\n") ~diff:None;
      check_change ~msg:"raw delete" delete ~path:"baz.ml" ~op:"delete"
        ~before:(Edit.Observed.Text "gone\n") ~after:Edit.Observed.Missing
        ~diff:None
  | changes -> failf "expected three raw changes, got %d" (List.length changes));
  is_true ~msg:"raw branch never emits Move"
    (List.for_all
       (fun (c : Receipt.change) ->
         match c.Receipt.op with Receipt.Move _ -> false | _ -> true)
       (Receipt.changes receipt))

let receipt_logical_kinds () =
  let fs = [ ("mod.ml", "before\n"); ("del.ml", "bye\n") ] in
  let plan =
    edit_ok "concat"
      (Edit.concat
         [
           edit_ok "create"
             (Edit.create ~path:(wpath "add.ml") ~contents:"hi\n");
           edit_ok "rewrite"
             (Edit.rewrite ~path:(wpath "mod.ml") ~before:"before\n"
                ~after:"after\n");
           edit_ok "delete" (Edit.delete ~path:(wpath "del.ml") ~before:"bye\n");
         ])
  in
  let logical =
    [
      {
        Receipt.Logical_change.path = wpath "add.ml";
        kind = Receipt.Logical_change.Create;
        diff = Some "d-add";
      };
      {
        Receipt.Logical_change.path = wpath "mod.ml";
        kind = Receipt.Logical_change.Modify;
        diff = None;
      };
      {
        Receipt.Logical_change.path = wpath "del.ml";
        kind = Receipt.Logical_change.Delete;
        diff = Some "d-del";
      };
      {
        Receipt.Logical_change.path = wpath "ghost.ml";
        kind = Receipt.Logical_change.Modify;
        diff = None;
      };
    ]
  in
  let receipt = Receipt.make ~logical_changes:logical (result_of fs plan) in
  match Receipt.changes receipt with
  | [ create; modify; delete; ghost ] ->
      (* Create: before is forced Missing, after and diff come from the tool. *)
      check_change ~msg:"logical create" create ~path:"add.ml" ~op:"create"
        ~before:Edit.Observed.Missing ~after:(Edit.Observed.Text "hi\n")
        ~diff:(Some "d-add");
      (* Modify with no tool diff keeps diff None; before/after looked up. *)
      check_change ~msg:"logical modify" modify ~path:"mod.ml" ~op:"modify"
        ~before:(Edit.Observed.Text "before\n")
        ~after:(Edit.Observed.Text "after\n") ~diff:None;
      (* Delete: after is forced Missing, before looked up. *)
      check_change ~msg:"logical delete" delete ~path:"del.ml" ~op:"delete"
        ~before:(Edit.Observed.Text "bye\n") ~after:Edit.Observed.Missing
        ~diff:(Some "d-del");
      (* A logical change whose path has no result entry looks up to Missing. *)
      check_change ~msg:"logical lookup miss" ghost ~path:"ghost.ml"
        ~op:"modify" ~before:Edit.Observed.Missing ~after:Edit.Observed.Missing
        ~diff:None
  | changes ->
      failf "expected four logical changes, got %d" (List.length changes)

let receipt_logical_move () =
  (* A patch move applies as delete(old) + create(new); the logical Move
     reconciles both raw entries into one change, before from [from]'s entry
     and after from the destination's entry. *)
  let fs = [ ("old.ml", "content\n") ] in
  let plan =
    edit_ok "concat"
      (Edit.concat
         [
           edit_ok "delete"
             (Edit.delete ~path:(wpath "old.ml") ~before:"content\n");
           edit_ok "create"
             (Edit.create ~path:(wpath "new.ml") ~contents:"content\n");
         ])
  in
  let logical =
    [
      {
        Receipt.Logical_change.path = wpath "new.ml";
        kind = Receipt.Logical_change.Move { from = wpath "old.ml" };
        diff = Some "d-move";
      };
    ]
  in
  let receipt = Receipt.make ~logical_changes:logical (result_of fs plan) in
  match Receipt.changes receipt with
  | [ move ] ->
      check_change ~msg:"logical move" move ~path:"new.ml" ~op:"move:old.ml"
        ~before:(Edit.Observed.Text "content\n")
        ~after:(Edit.Observed.Text "content\n") ~diff:(Some "d-move");
      equal (option string) ~msg:"move source path" (Some "old.ml")
        (Option.map W.Path.display
           (Receipt.Logical_change.source_path (List.hd logical)))
  | changes -> failf "expected one logical move, got %d" (List.length changes)

let receipt_empty () =
  is_true ~msg:"empty receipt is empty" (Receipt.is_empty Receipt.empty);
  equal int ~msg:"empty receipt has no changes" 0
    (List.length (Receipt.changes Receipt.empty));
  is_true ~msg:"receipt over empty result is empty"
    (Receipt.is_empty (Receipt.make Spice_edit.Result.empty))

let () =
  run "spice.tools.receipt"
    [
      test "receipt reconciles raw edit entries" receipt_raw_changes;
      test "receipt reconciles logical change kinds" receipt_logical_kinds;
      test "receipt reconciles a logical move" receipt_logical_move;
      test "receipt empty" receipt_empty;
    ]
