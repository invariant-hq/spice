(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type source =
  | Config of Config.Source.t
  | Explicit of string
  | Derived of string

type t =
  | Configured of Config.Origin.t
  | Explained of { source : source; shadowed : source list }

let configured origin = Configured origin
let explicit label = Explained { source = Explicit label; shadowed = [] }
let derived label = Explained { source = Derived label; shadowed = [] }

let source = function
  | Configured origin -> Config (Config.Origin.source origin)
  | Explained { source; _ } -> source

let shadowed = function
  | Configured origin ->
      List.map (fun source -> Config source) (Config.Origin.shadowed origin)
  | Explained { shadowed; _ } -> shadowed

let config_origin = function
  | Configured origin -> Some origin
  | Explained _ -> None

let source_to_string = function
  | Config _ -> "configured"
  | Explicit label | Derived label -> label

let to_string t = source_to_string (source t)
let pp ppf t = Format.pp_print_string ppf (to_string t)
