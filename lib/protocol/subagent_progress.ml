(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  run : Spice_session.Id.t;
  parent : Spice_session.Id.t;
  role : Subagent.Role.t;
  depth : int;
  event : Event.t;
}
