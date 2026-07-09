(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** CR mutations a review surface requests.

    An op names one pure {!Spice_cr} edit against a worktree file. The surface
    constructs ops; a performer applies the edit, writes the file, and reloads
    the snapshot. *)

type t =
  | Add of { path : Spice_path.Rel.t; line : int; cr : Spice_cr.t }
      (** Request {!Spice_cr.add_before_line} for [cr] before one-based [line]
          of [path]. Performers may fail when [path] has no conventional
          comment syntax, [line] is outside the current file, or [cr] cannot be
          rendered in that syntax. *)
  | Replace of { occurrence : Spice_cr.Occurrence.t; cr : Spice_cr.t }
      (** Request {!Spice_cr.replace}: rewrite [occurrence] in place with [cr]
          using the occurrence's scanned syntax and stale-source check. *)
  | Remove of { occurrence : Spice_cr.Occurrence.t }
      (** Request {!Spice_cr.remove}: delete [occurrence] from its source file,
          removing whole comment lines when the occurrence is alone on them and
          only the raw occurrence span otherwise. *)

val path : t -> Spice_path.Rel.t
(** [path op] is the worktree-relative file [op] edits. *)
