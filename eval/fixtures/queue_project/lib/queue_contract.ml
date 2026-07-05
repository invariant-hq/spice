(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type 'a t = 'a list

let empty = []
let enqueue t x = t @ [ x ]

let dequeue = function
  | [] -> None
  | x :: xs -> Some (x, xs)
