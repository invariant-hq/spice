(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Logical_change = struct
  type kind =
    | Create
    | Modify
    | Delete
    | Move of { from : Spice_workspace.Path.t }

  type t = { path : Spice_workspace.Path.t; kind : kind; diff : string option }

  let source_path t =
    match t.kind with
    | Move { from } -> Some from
    | Create | Modify | Delete -> None
end

type t = {
  result : Spice_edit.Result.t;
  logical_changes : Logical_change.t list;
}

type op = Create | Modify | Delete | Move of { from : Spice_workspace.Path.t }

type change = {
  path : Spice_workspace.Path.t;
  op : op;
  before : Spice_edit.Observed.t;
  after : Spice_edit.Observed.t;
  diff : string option;
}

let make ?(logical_changes = []) result = { result; logical_changes }
let empty = make Spice_edit.Result.empty
let is_empty t = Spice_edit.Result.is_empty t.result

let paths t =
  List.map
    (fun (entry : Spice_edit.Result.Entry.t) ->
      Spice_edit.Result.Entry.target_path entry)
    (Spice_edit.Result.entries t.result)

let op_of_edit_kind = function
  | `Create -> Create
  | `Modify -> Modify
  | `Delete -> Delete

(* The one reconciliation of raw edit entries with the tool's optional
   semantic grouping. Formerly duplicated across the host and every renderer;
   defined and tested here once. *)
let changes t =
  match t.logical_changes with
  | [] ->
      List.map
        (fun (entry : Spice_edit.Result.Entry.t) ->
          {
            path = Spice_edit.Result.Entry.target_path entry;
            op = op_of_edit_kind (Spice_edit.Result.Entry.kind entry);
            before = Spice_edit.Result.Entry.before entry;
            after = Spice_edit.Result.Entry.after entry;
            diff = None;
          })
        (Spice_edit.Result.entries t.result)
  | _ :: _ ->
      let applied path =
        List.find_opt
          (fun (entry : Spice_edit.Result.Entry.t) ->
            Spice_path.Rel.equal
              (Spice_workspace.Path.rel
                 (Spice_edit.Result.Entry.target_path entry))
              path)
          (Spice_edit.Result.entries t.result)
      in
      let target_of selector path =
        match applied path with
        | None -> Spice_edit.Observed.Missing
        | Some entry -> selector entry
      in
      let before_of = target_of Spice_edit.Result.Entry.before in
      let after_of = target_of Spice_edit.Result.Entry.after in
      List.map
        (fun (logical : Logical_change.t) ->
          let path_rel = Spice_workspace.Path.rel logical.Logical_change.path in
          match logical.Logical_change.kind with
          | Logical_change.Create ->
              {
                path = logical.Logical_change.path;
                op = Create;
                before = Spice_edit.Observed.Missing;
                after = after_of path_rel;
                diff = logical.Logical_change.diff;
              }
          | Logical_change.Modify ->
              {
                path = logical.Logical_change.path;
                op = Modify;
                before = before_of path_rel;
                after = after_of path_rel;
                diff = logical.Logical_change.diff;
              }
          | Logical_change.Delete ->
              {
                path = logical.Logical_change.path;
                op = Delete;
                before = before_of path_rel;
                after = Spice_edit.Observed.Missing;
                diff = logical.Logical_change.diff;
              }
          | Logical_change.Move { from } ->
              {
                path = logical.Logical_change.path;
                op = Move { from };
                before = before_of (Spice_workspace.Path.rel from);
                after = after_of path_rel;
                diff = logical.Logical_change.diff;
              })
        t.logical_changes
