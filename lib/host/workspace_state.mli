(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Global state owned by one canonical workspace root. *)

val key : string -> string
(** [key root] is the stable opaque directory key for canonical [root]. *)

val dir : data_root:string -> root:string -> string
(** [dir ~data_root ~root] is [workspaces/<key>] below [data_root]. *)

val manifest_path : string -> string
(** [manifest_path dir] is [dir/workspace.json]. *)

val checkpoint_dir : string -> string
(** [checkpoint_dir dir] is the bare shadow Git directory below [dir]. *)

val reviews_dir : string -> string
(** [reviews_dir dir] is the review-record directory below [dir]. *)

val ensure :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  data_root:string ->
  root:string ->
  (string, string) result
(** [ensure ~fs ~data_root ~root] validates or exclusively creates the
    restrictive workspace manifest and returns its directory. Existing
    manifests with another root or version fail loudly. *)
