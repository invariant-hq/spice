(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = Error
module Confinement = Confinement
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
let escalation = Run.escalation
let evidence = Run.evidence

module Spec = struct
  type t = Unconfined | Declared_external | Confined of Confinement.t

  let equal a b =
    match (a, b) with
    | Unconfined, Unconfined -> true
    | Declared_external, Declared_external -> true
    | Confined a, Confined b -> Confinement.equal a b
    | (Unconfined | Declared_external | Confined _), _ -> false

  let pp ppf = function
    | Unconfined -> Format.pp_print_string ppf "unconfined"
    | Declared_external -> Format.pp_print_string ppf "external"
    | Confined confinement ->
        Format.fprintf ppf "confined@ (%a)" Confinement.pp confinement
end

let seal ?backend = function
  | Spec.Unconfined -> Run.unconfined
  | Spec.Declared_external -> Run.external_
  | Spec.Confined confinement -> Run.confined ?backend confinement
