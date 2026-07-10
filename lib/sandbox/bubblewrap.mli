(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Linux Bubblewrap backend.

    This module owns Linux backend identity, availability diagnostics, and pure
    argv lowering. Hosts select this backend by default on Linux. *)

val executable : string
(** [executable] is the system Bubblewrap path Spice will use. It is absolute so
    a workspace-local [bwrap] on [PATH] cannot be selected. *)

val make :
  probe_executable:string ->
  probe:(executable:string -> argv:string array -> (unit, string) result) ->
  unit ->
  Backend.t
(** [make ~probe_executable ~probe ()] is a Linux Bubblewrap backend.
    [probe] runs the fixed namespace probe through [probe_executable] and
    returns a diagnostic reason when it cannot complete successfully. Prepared
    commands always use {!executable}; overriding the probe cannot alter the
    enforcement prefix. *)
