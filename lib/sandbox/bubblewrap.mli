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

val backend : Backend.t
(** [backend] is the Linux Bubblewrap backend value. *)
