(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type phase = Checking | Downloading | Verifying | Ready

type status =
  | Installed of { path : string }
  | Missing of { path : string; size : int64 option; source : string option }
  | Unavailable of { message : string }

type progress = {
  provider : Spice_llm.Provider.t;
  model : string;
  label : string;
  path : string;
  received : int64;
  total : int64 option;
  phase : phase;
}

let bytes_text bytes =
  let value = Int64.to_float bytes in
  if value >= 1_000_000_000. then
    Printf.sprintf "%.1f GB" (value /. 1_000_000_000.)
  else if value >= 1_000_000. then Printf.sprintf "%.1f MB" (value /. 1_000_000.)
  else if value >= 1_000. then Printf.sprintf "%.1f KB" (value /. 1_000.)
  else Printf.sprintf "%Ld B" bytes

let summary (status : status) =
  match status with
  | Installed { path } -> "installed: " ^ path
  | Missing { size = None; _ } -> "missing - auto-download"
  | Missing { size = Some size; _ } ->
      "missing - auto-download " ^ bytes_text size
  | Unavailable { message } -> "unavailable: " ^ message

type download_outcome =
  | Already_installed of string
  | Not_downloadable
  | Downloaded
  | Refused of { message : string; force_hint : bool }
