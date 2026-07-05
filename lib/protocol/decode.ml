(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let error message = Jsont.Error.msg Jsont.Meta.none message
let or_error = function Ok value -> value | Error message -> error message
