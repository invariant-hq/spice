(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type state = Reviewed | Unreviewed
type t = { scope : Scope.t; state : state; evidence : Spice_digest.Identity.t }

let make ~scope ~state ~evidence = { scope; state; evidence }
let scope t = t.scope
let state t = t.state
let evidence t = t.evidence

let state_equal a b =
  match (a, b) with
  | Reviewed, Reviewed | Unreviewed, Unreviewed -> true
  | _ -> false

let equal a b =
  Scope.equal a.scope b.scope
  && state_equal a.state b.state
  && Spice_digest.Identity.equal a.evidence b.evidence

let pp ppf t =
  Format.fprintf ppf "%s %a"
    (match t.state with Reviewed -> "reviewed" | Unreviewed -> "unreviewed")
    Scope.pp t.scope
