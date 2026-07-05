(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  version : string;
  model : string;
  effort : string option;
  cwd : Spice_path.Abs.t;
  context_window : int option;
  permission : string option;
  sandbox : string option;
}

let with_effort model effort =
  match effort with Some effort -> model ^ " " ^ effort | None -> model

let model_line t = with_effort t.model t.effort

(* The footer keeps only the model's leaf, the last ["/"] segment: at footer
   widths the provider prefix is redundant with the banner's full form. *)
let model_leaf model =
  match String.rindex_opt model '/' with
  | None -> model
  | Some slash -> String.sub model (slash + 1) (String.length model - slash - 1)

let model_line_compact t = with_effort (model_leaf t.model) t.effort
