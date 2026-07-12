(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** macOS Seatbelt backend.

    Lowers a confined {!Policy.t} to a [sandbox-exec] invocation: an SBPL profile
    string plus [-D] path parameters around the command argv. Profile generation
    is pure and canonical, so equal policies produce equal profiles and equal
    hashes; only the availability probe touches the host.

    The base profile is ported from the Codex reference agent's Seatbelt policy,
    which is production-proven against real build tools. [Policy.All] permits
    host-wide reads and executable mappings; [Policy.Only roots] admits both
    operations only beneath the resolved roots. Writes are denied except under
    writable roots, with concrete protected paths carved out; network is denied
    unless the policy enables it.

    Policy paths are used as given. Hosts canonicalize writable and
    protected paths (for example [/tmp] to [/private/tmp]) before building the
    policy; see {!Policy}. *)

val executable : string
(** [executable] is ["/usr/bin/sandbox-exec"]: the absolute path is fixed so a
    malicious [PATH] cannot inject a different binary. *)

val profile : Policy.t -> string * (string * string) list
(** [profile policy] is the SBPL profile text and the ordered [-D]
    parameters (key, absolute path) it references. Pure and deterministic. *)

val backend : Backend.t
(** [backend] is the Seatbelt backend. [available] checks that {!executable}
    exists; [wrap] assembles [sandbox-exec -p profile -Dkey=value... -- argv];
    [profile] digests the canonical profile and parameters with {!Spice_digest}.
*)
