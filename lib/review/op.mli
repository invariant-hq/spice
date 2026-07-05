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
      (** Insert [cr] anchored before [line] of [path]. *)
  | Replace of { occurrence : Spice_cr.Occurrence.t; cr : Spice_cr.t }
      (** Rewrite [occurrence] in place with [cr] (edit or resolve). *)
  | Remove of { occurrence : Spice_cr.Occurrence.t }
      (** Delete [occurrence] from its source file. *)

val path : t -> Spice_path.Rel.t
(** [path op] is the worktree-relative file [op] edits. *)
