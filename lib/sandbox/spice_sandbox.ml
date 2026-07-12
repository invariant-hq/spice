(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = Error
module Policy = Policy
module Env = Env
module Evidence = Evidence
module Argv = Argv
module Backend = Backend
module Spawn = Run.Spawn

type t = Run.t

module Seatbelt = Seatbelt
module Bubblewrap = Bubblewrap

type escalation = Run.escalation = Available | Denied of Error.t | Ignored

let spawn = Run.spawn
let policy = Run.policy
let escalation = Run.escalation
let evidence = Run.evidence
let seal = Run.seal
