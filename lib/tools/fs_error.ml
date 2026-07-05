(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Shares the one byte-identical piece of workspace-observation failure
   reporting: the map from [Fs.Error.t] to a [Tool.Result] failure class.

   Every read-side tool classifies workspace filesystem failures the same way
   ([Not_found] is not-found, everything else is caller error except I/O, which
   is a run failure). Only that classification is shared; each tool keeps its own
   contextual message, since the [Unexpected_kind] wording is deliberately
   tool-specific. *)

open Import

let failure (error : Fs.Error.t) =
  match error with
  | Fs.Error.Workspace
      ( Workspace.Resolve_error.Outside_workspace _
      | Workspace.Resolve_error.Invalid_input _ ) ->
      `Invalid_input
  | Fs.Error.Not_found _ -> `Not_found
  | Fs.Error.Unexpected_kind _ | Fs.Error.Escapes_workspace _ -> `Invalid_input
  | Fs.Error.Io _ -> `Failed

(* Unlike [Edit_error], this module deliberately exposes no shared [message]:
   the [Unexpected_kind] wording is per-tool, so [failed] takes the caller's
   [message] rather than deriving one. The classification is the only shared
   piece. *)
let failed ~message error = Tool.Result.failed (failure error) message
