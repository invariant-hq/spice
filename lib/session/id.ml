(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

include
  String_id.Make
    (struct
      let module_path = "Spice_session.Id"
      let kind = "session id"
    end)
    ()
