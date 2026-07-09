(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* The resume verb the hint names: [spice resume ID] reopens the session through
   the CLI's resume command (bin/cli_tui.ml). The [tui-next] preview subcommand
   carries no session flag, so this is the honest, working path to continue a
   conversation started here. *)
let resume_command id = "spice resume " ^ Spice_session.Id.to_string id

(* One column of left margin so the lockup breathes off the terminal edge, with
   the resume line hanging under it. *)
let indent = " "

(* One styled line: the SGR-wrapped text when color is on, the bare text
   otherwise. [Mosaic.Ansi.render] emits the minimal SGR prefix and a closing
   reset, so each line stands alone. *)
let line ~color style s = if color then Mosaic.Ansi.render [ (style, s) ] else s

let render ~color ~session =
  let lockup =
    List.map (fun row -> line ~color Theme.accent (indent ^ row)) Theme.lockup
  in
  let resume =
    match session with
    | None -> []
    | Some id ->
        [
          ""; line ~color Theme.muted (indent ^ "continue  " ^ resume_command id);
        ]
  in
  "\n" ^ String.concat "\n" (lockup @ resume) ^ "\n\n"
