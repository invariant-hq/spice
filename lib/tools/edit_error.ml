(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Maps edit errors onto the shared tool failure classes.

   The edit-backed tools lower to [Spice_edit] and must surface its
   [Edit.Error.t] values through one [Tool.Result] shape. [failure] classifies
   each error as [`Stale], [`Not_found], [`Invalid_input], or [`Failed];
   [message] renders its user-facing text; [failed] combines the two. This keeps
   failure reporting identical across the edit and patch tools. *)

open Import

let failure (error : Edit.Error.t) =
  match error with
  | Edit.Error.Conflict _ -> `Stale
  | Edit.Error.State_mismatch { expected = `Text; actual = `Missing; _ } ->
      `Not_found
  | Edit.Error.State_mismatch _ | Edit.Error.Invalid_text _
  | Edit.Error.Duplicate_path _ | Edit.Error.Too_large _ ->
      `Invalid_input
  | Edit.Error.Workspace
      ( _,
        ( Workspace.Resolve_error.Outside_workspace _
        | Workspace.Resolve_error.Invalid_input _ ) ) ->
      `Invalid_input
  | Edit.Error.Out_of_workspace _ -> `Failed
  | Edit.Error.Protected_path _ -> `Invalid_input
  | Edit.Error.Io _ -> `Failed

let target_kind = function
  | `Missing -> "missing"
  | `Text -> "text"
  | `Other -> "other"

let message (error : Edit.Error.t) =
  match error with
  | Edit.Error.Invalid_text (None, reason) -> reason
  | Edit.Error.Invalid_text (Some path, reason) ->
      Workspace.Path.display path ^ ": " ^ reason
  | Edit.Error.Duplicate_path path ->
      Workspace.Path.display path ^ ": duplicate edit target"
  | Edit.Error.State_mismatch { path; expected = `Text; actual = `Missing; _ }
    ->
      Workspace.Path.display path ^ ": path does not exist"
  | Edit.Error.State_mismatch { path; expected; actual } ->
      Printf.sprintf "%s: expected %s, found %s"
        (Workspace.Path.display path)
        (target_kind expected) (target_kind actual)
  | Edit.Error.Too_large { path; size; max_size } ->
      Printf.sprintf "%s: file is too large (%Ld bytes, max %Ld)"
        (Workspace.Path.display path)
        size max_size
  | Edit.Error.Conflict { path; expected = _; actual = _ } ->
      Workspace.Path.display path ^ ": stale write"
  | Edit.Error.Workspace (None, error) -> Workspace.Resolve_error.message error
  | Edit.Error.Workspace (Some path, error) ->
      Workspace.Path.display path ^ ": " ^ Workspace.Resolve_error.message error
  | Edit.Error.Out_of_workspace path ->
      Workspace.Path.display path
      ^ ": edit target is no longer inside the workspace"
  | Edit.Error.Protected_path (path, name) ->
      Printf.sprintf
        "%s: %s is protected workspace metadata and cannot be modified by \
         tools; change sandbox and workspace policy through configuration or \
         the CLI instead"
        (Workspace.Path.display path)
        name
  | Edit.Error.Io (None, _) -> "filesystem I/O error"
  | Edit.Error.Io (Some path, _) ->
      Workspace.Path.display path ^ ": filesystem I/O error"

let failed error = Tool.Result.failed (failure error) (message error)
