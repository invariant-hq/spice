(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure permission modelling for agent operations.

    This library defines inert access facts, permission requests, reviewer
    answers, and pure policy evaluation for host-managed operations.

    The usual flow is: construct trusted {!Access.t} facts in host/tool code,
    group them with {!Request.of_accesses} or {!Request.make}, evaluate with
    {!Policy.decide}, and apply a reviewer answer with {!Review.resolve} when
    reviewer input is needed.

    Stable permission identity is carried by {!Access.t}. Display fields, prompt
    ids, reviewer messages, persistence, and runtime grants live outside access
    facts unless a submodule explicitly says otherwise.

    Permission is not sandboxing. An allowed request means the pure policy
    accepted the described accesses. Runtime confinement, process spawning,
    filesystem mutation, network enforcement, prompting, persistence, and audit
    remain the responsibility of host interpreters. *)

module Access = Access
(** Permission-relevant operation facts. *)

module Request = Request
(** Permission requests over access facts. *)

module Policy = Policy
(** Permission policy: matchers, rules, evaluation, grants, and reviews. *)

module Suggest = Suggest
(** Durable allow-rule suggestions generalizing a reviewed access to its family.
*)
