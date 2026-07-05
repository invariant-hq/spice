(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The read-only vocabulary shared by modes and roles.

    A contract is what a product context — a turn {!Mode.t} or a child
    {!Subagent.Role.t} — lets a run do: the executable-tool restriction it
    imposes and the permission strengthening it applies. It is the one place the
    read-only workspace policy and read-only tool list live, so modes and roles
    spell them once and share them.

    A contract restricts tools two ways at once — by an allow-list applied to
    the concrete tool values ({!filter_tools}) and by a permission policy
    ({!policy}) — because the two guards defend different boundaries: the
    allow-list decides which tools the model is even offered, while the policy
    decides which protected operations are permitted when a tool runs.

    There are exactly three contracts: {!unrestricted}, {!read_only}, and
    {!checks}. They are constants, not a combinator space; nothing composes
    them. *)

type t
(** The type for a read-only contract. *)

val unrestricted : t
(** [unrestricted] imposes no tool restriction and no policy strengthening.

    {!filter_tools} is the identity and {!policy} returns its [configured]
    argument unchanged. It is the {!Mode.Build} contract. *)

val read_only : t
(** [read_only] restricts a run to workspace discovery.

    {!filter_tools} keeps only reading, listing, searching, and globbing the
    workspace plus the read-only skill load; {!policy} strengthens any
    configured policy to one that allows workspace reads and denies workspace
    creates, modifies, and deletes, regardless of [configured]. It is the
    {!Mode.Plan} and {!Mode.Review} contract and the {!Subagent.Role.Explore}
    and {!Subagent.Role.Review} contract. *)

val checks : t
(** [checks] allows read-only discovery plus shell, under the configured policy.

    {!filter_tools} keeps {!read_only}'s tools and the shell tool, so a run can
    execute checks; {!policy} returns its [configured] argument unchanged rather
    than strengthening it, so the caller's policy governs what those checks may
    do. It is the {!Subagent.Role.Verify} contract, allowed only where the
    parent mode permits command execution. *)

val filter_tools : t -> Spice_tool.t list -> Spice_tool.t list
(** [filter_tools t tools] keeps the tools [t] permits, in their original order.
    {!unrestricted} preserves [tools]. Membership is decided by
    {!Spice_tool.name}: the read-only tool set is owned here by stable
    model-visible tool name, so this module does not depend on the tool
    implementations. *)

val policy :
  t -> configured:Spice_permission.Policy.t -> Spice_permission.Policy.t
(** [policy t ~configured] is the effective permission policy [t] imposes over
    [configured].

    {!unrestricted} and {!checks} return [configured] unchanged. {!read_only}
    returns a read-only workspace policy regardless of [configured], so
    command-line permission overrides cannot weaken a read-only contract. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same contract. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] for diagnostics. *)
