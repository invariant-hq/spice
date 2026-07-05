(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common
open Result.Syntax

(* The goodbye styles the lockup unless [NO_COLOR] asks for plain text; the TUI
   only runs on a color-capable tty, so this is the sole color gate on the way
   out. *)
let use_color () =
  match Sys.getenv_opt "NO_COLOR" with Some s when s <> "" -> false | _ -> true

(* The parting frame, printed to the restored normal terminal after the TUI
   exits — the brand lockup and, once a session exists, how to resume it. *)
let print_goodbye stdenv (outcome : Spice_tui.outcome) =
  Eio.Flow.copy_string
    (Spice_tui.Goodbye.render ~color:(use_color ())
       ~session:outcome.Spice_tui.last_session)
    stdenv#stdout

let launch ~stdenv ?cwd ?mode ?session () =
  divert_logs_for_tui ();
  let startup = Spice_tui.Startup.make ?cwd ?mode ?session () in
  match Spice_tui.run ~stdenv ~startup () with
  | Ok outcome ->
      print_goodbye stdenv outcome;
      Success
  | Error error -> Runtime_error (Spice_tui.Error.message error)

let run ?session cwd mode =
  Eio_main.run @@ fun stdenv ->
  status
    (let* cwd_abs =
       optional_absolute_cwd stdenv cwd
       |> Result.map_error (fun message -> `Usage message)
     in
     let* mode =
       match mode with
       | None -> Ok None
       | Some raw ->
           Spice_protocol.Mode.of_string raw
           |> Result.map (fun m -> Some m)
           |> Result.map_error (fun _ ->
                  `Usage
                    ("unknown mode: " ^ raw ^ " (expected build, plan, or review)"))
     in
     Ok (launch ~stdenv ?cwd:cwd_abs ?mode ?session ()))

let cwd =
  Cli_arg.cwd ~short:true ~doc:"Run Spice from working directory $(docv)." ()

(* The initial turn mode, so the pty harness can raise a plan-approval dialog by
   starting in plan mode; the composer switches it thereafter. *)
let mode =
  let doc = "Start in turn mode $(docv) (build, plan, or review)." in
  CArg.(value & opt (some string) None & info [ "mode" ] ~docv:"MODE" ~doc)

let default_term = exit_term CTerm.(const (run ?session:None) $ cwd $ mode)

let resume_session =
  Cli_arg.session_pos
    ~doc:
      "Session id to resume. When absent, the TUI opens on the home stage, where \
       $(b,enter) on an empty composer resumes the newest session in this \
       working directory."
    ()

let resume_run session cwd mode = run ?session cwd mode

let resume_command =
  let man =
    [
      `S CManpage.s_description;
      `P
        "Opens the interactive TUI on a saved session's replayed transcript. \
         Without $(i,SESSION), opens the home stage, where $(b,enter) on an \
         empty composer resumes the newest session and $(b,/sessions) browses \
         the rest. To resume a session headlessly, use $(b,spice run resume) \
         instead.";
      `S CManpage.s_examples;
      `Pre "  spice resume";
      `Pre "  spice resume ses_123";
    ]
  in
  CCmd.v
    (CCmd.info "resume" ~doc:"Resume a saved session in the TUI."
       ~docs:s_run_commands ~man ~exits)
    (exit_term CTerm.(const resume_run $ resume_session $ cwd $ mode))

