(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type choice = Untrusted | Trusted | Exit
type input = Up | Down | Digit of int | Enter | Escape | Eof
type t = { root : Spice_path.Abs.t; selected : int }

let make ~root = { root; selected = 0 }

let choice = function
  | 0 -> Untrusted
  | 1 -> Trusted
  | _ -> Exit

let update input t =
  match input with
  | Up -> ({ t with selected = (t.selected + 2) mod 3 }, None)
  | Down -> ({ t with selected = (t.selected + 1) mod 3 }, None)
  | Digit digit when digit >= 1 && digit <= 3 ->
      let selected = digit - 1 in
      ({ t with selected }, Some (choice selected))
  | Digit _ -> (t, None)
  | Enter -> (t, Some (choice t.selected))
  | Escape | Eof -> ({ t with selected = 2 }, Some Exit)

let selection_line t =
  match t.selected with
  | 0 -> "Selection: 1 — continue without project customization"
  | 1 -> "Selection: 2 — trust and enable project customization"
  | _ -> "Selection: 3 — exit without saving a decision"

let render t =
  String.concat "\n"
    ([
       "Spice workspace trust";
       "";
       "Workspace: " ^ Spice_path.Abs.to_string t.root;
       "";
       "This repository can provide project configuration, instructions, \
        skills,";
       "project notices, and built-in Dune/Merlin integration. Trust enables";
       "those inputs. It does not grant file, command, or network permission,";
       "and it does not weaken the sandbox.";
       "";
       "  1. Continue without project customization (remember this choice)";
       "     Project config, instructions, skills, notices, and tooling stay \
        disabled.";
       "  2. Trust and enable project customization (remember this choice)";
       "     Trusted project inputs activate under the current permission and \
        sandbox posture.";
       "  3. Exit";
       "     Save nothing and start no project process.";
       "";
       "Use ↑/↓ and Enter, or press 1–3. Escape or Ctrl+C exits.";
     ]
    @ [ ""; selection_line t ])

type 'a outcome = Continue of 'a | Exit_prompt

type failure =
  | Save_failed of string
  | Continue_failed of string
  | Activation_failed of { message : string; rollback_error : string option }

let write text =
  output_string stdout text;
  flush stdout

let read_byte () =
  let bytes = Bytes.create 1 in
  match Unix.read Unix.stdin bytes 0 1 with
  | 0 -> None
  | _ -> Some (Bytes.get bytes 0)

let next_byte () =
  match Unix.select [ Unix.stdin ] [] [] 0.05 with
  | [], _, _ -> None
  | _ -> read_byte ()

let rec read_input () =
  match read_byte () with
  | None | Some '\004' -> Eof
  | Some ('\003' | '\027') -> (
      match next_byte () with
      | Some '[' -> (
          match next_byte () with Some 'A' -> Up | Some 'B' -> Down | _ -> Escape)
      | _ -> Escape)
  | Some ('\r' | '\n') -> Enter
  | Some ('1' .. '9' as digit) -> Digit (Char.code digit - Char.code '0')
  | Some _ -> read_input ()

let with_raw_terminal f =
  let original = Unix.tcgetattr Unix.stdin in
  let open Unix in
  let raw =
    {
      original with
      c_icanon = false;
      c_echo = false;
      c_echoe = false;
      c_echok = false;
      c_echonl = false;
      c_isig = false;
      c_ixon = false;
      c_vmin = 1;
      c_vtime = 0;
    }
  in
  Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH raw;
  Fun.protect
    ~finally:(fun () -> Unix.tcsetattr Unix.stdin Unix.TCSANOW original)
    f

let redraw t = write ("\r\027[2K" ^ selection_line t)

let failure_message = function
  | Save_failed message -> "Could not save the decision: " ^ message
  | Continue_failed message ->
      "Decision saved, but Spice could not continue: " ^ message
  | Activation_failed { message; rollback_error = None } ->
      "Project customization could not be activated: " ^ message
      ^ "\nThe workspace was marked untrusted."
  | Activation_failed { message; rollback_error = Some rollback_error } ->
      "Project customization could not be activated: " ^ message
      ^ "\nSpice also could not mark the workspace untrusted: " ^ rollback_error

let run ~root ~decide =
  with_raw_terminal @@ fun () ->
  let rec loop t =
    let t, decision = update (read_input ()) t in
    redraw t;
    match decision with
    | None -> loop t
    | Some Exit ->
        write "\nExited without saving a workspace trust decision.\n";
        Exit_prompt
    | Some ((Untrusted | Trusted) as choice) -> (
        match decide choice with
        | Ok value ->
            let message =
              match choice with
              | Untrusted -> "Project customization remains disabled."
              | Trusted -> "Project customization is enabled."
              | Exit -> assert false
            in
            write ("\nDecision saved. " ^ message ^ "\n");
            Continue value
        | Error failure ->
            write ("\n" ^ failure_message failure ^ "\n");
            write (selection_line t);
            loop t)
  in
  let t = make ~root in
  write (render t);
  loop t
