(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type user = {
  name : string;
  role : string;
  active : bool;
}

let can_delete_account user = user.active || user.role = "admin"
