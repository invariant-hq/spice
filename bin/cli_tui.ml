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
  match Sys.getenv_opt "NO_COLOR" with
  | Some s when s <> "" -> false
  | _ -> true

(* The parting frame, printed to the restored normal terminal after the TUI
   exits — the brand lockup and, once a session exists, how to resume it. *)
let print_goodbye stdenv (outcome : Spice_tui.outcome) =
  Eio.Flow.copy_string
    (Spice_tui.Goodbye.render ~color:(use_color ())
       ~session:outcome.Spice_tui.last_session)
    stdenv#stdout

let launch ~stdenv ?cwd ?mode ?session ?input ?launch:surface ?sandbox () =
  divert_logs_for_tui ();
  let startup =
    Spice_tui.Startup.make ?cwd ?mode ?session ?input ?launch:surface ?sandbox
      ()
  in
  match Spice_tui.run ~stdenv ~startup () with
  | Ok outcome ->
      print_goodbye stdenv outcome;
      Success
  | Error error -> Runtime_error (Spice_tui.Error.message error)

let startup_input draft prompt =
  match (draft, prompt) with
  | None, None -> Ok Spice_tui.Startup.Empty
  | Some draft, None -> Ok (Spice_tui.Startup.Draft draft)
  | None, Some prompt -> Ok (Spice_tui.Startup.Submit prompt)
  | Some _, Some _ -> usage "choose only one of --draft or --prompt"

(* [--continue] resolves the newest session before the TUI starts, over the
   same host bootstrap the TUI performs afterwards; both loads see the same
   raw [--cwd] value, so they resolve the same workspace. *)
let run ?session cwd sandbox mode continue_ draft prompt =
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
     let* input = startup_input draft prompt in
     let* session =
       match (session, continue_) with
       | Some _, true -> usage "choose only one of --continue or --session"
       | Some session, false -> Ok (Some session)
       | None, true ->
           let* host = assembly (load_host ?cwd ~overrides:[] stdenv) in
           let* id = newest_session_in_cwd ~surface:`Tui ~stdenv host in
           Ok (Some id)
       | None, false -> Ok None
     in
     let* () =
       match (input, session) with
       | Spice_tui.Startup.Submit _, Some _ ->
           (* Submitting into a resumed session would race the replay; reject
              until the runtime orders the two. *)
           usage "--prompt starts a fresh session; drop --session/--continue"
       | ( ( Spice_tui.Startup.Empty | Spice_tui.Startup.Draft _
           | Spice_tui.Startup.Submit _ ),
           _ ) ->
           Ok ()
     in
     Ok (launch ~stdenv ?cwd:cwd_abs ?mode ?session ~input ?sandbox ()))

let cwd =
  Cli_arg.cwd ~short:true ~doc:"Run Spice from working directory $(docv)." ()

let sandbox =
  let modes =
    List.map
      (fun mode -> (Spice_host.Sandbox.Mode.to_string mode, mode))
      Spice_host.Sandbox.Mode.all
  in
  let doc =
    "Sandbox mode for TUI turns and shell commands: $(b,read-only), \
     $(b,workspace-write), $(b,danger-full-access), or $(b,external-sandbox). \
     When absent, $(b,sandbox.mode) config applies; without that, Spice uses \
     $(b,workspace-write). Restricted modes fail closed when no backend can \
     enforce them."
  in
  CArg.(
    value & opt (some (enum modes)) None & info [ "sandbox" ] ~docv:"MODE" ~doc)

(* The initial turn mode, so the pty harness can raise a plan-approval dialog by
   starting in plan mode; the composer switches it thereafter. *)
let mode =
  let doc = "Start in turn mode $(docv) (build, plan, or review)." in
  CArg.(value & opt (some string) None & info [ "mode" ] ~docv:"MODE" ~doc)

let continue_ =
  let doc =
    "Resume the newest session in this working directory. Note the case: \
     $(b,-c) continues a session, $(b,-C) sets the working directory."
  in
  CArg.(value & flag & info [ "c"; "continue" ] ~doc)

let session =
  let doc = "Open the TUI with session $(docv) loaded." in
  CArg.(
    value
    & opt (some Cli_arg.session_id) None
    & info [ "session" ] ~docv:"SESSION" ~doc)

let draft =
  let doc = "Open the TUI with text $(docv) in the composer." in
  CArg.(value & opt (some string) None & info [ "draft" ] ~docv:"TEXT" ~doc)

let prompt =
  let doc = "Submit prompt $(docv) as the first turn once the TUI is up." in
  CArg.(
    value & opt (some string) None & info [ "p"; "prompt" ] ~docv:"TEXT" ~doc)

let default_run session cwd sandbox mode continue_ draft prompt =
  run ?session cwd sandbox mode continue_ draft prompt

let default_term =
  exit_term
    CTerm.(
      const default_run $ session $ cwd $ sandbox $ mode $ continue_ $ draft
      $ prompt)

let resume_session =
  Cli_arg.session_pos
    ~doc:
      "Session id to resume. When absent, the TUI opens on the home stage, \
       where $(b,enter) on an empty composer resumes the newest session in \
       this working directory."
    ()

let last =
  let doc =
    "Resume the newest session in this working directory directly, skipping \
     the home stage."
  in
  CArg.(value & flag & info [ "last" ] ~doc)

let resume_run session cwd sandbox mode last draft prompt =
  if last && Option.is_some session then
    status (usage "choose SESSION or --last, not both")
  else run ?session cwd sandbox mode last draft prompt

let resume_command =
  let man =
    [
      `S CManpage.s_description;
      `P
        "Opens the interactive TUI on a saved session's replayed transcript. \
         Without $(i,SESSION), opens the home stage, where $(b,enter) on an \
         empty composer resumes the newest session and $(b,/sessions) browses \
         the rest; $(b,--last) resumes it directly. To resume a session \
         headlessly, use $(b,spice run resume) instead.";
      `S CManpage.s_examples;
      `Pre "  spice resume";
      `Pre "  spice resume ses_123";
      `Pre "  spice resume --last";
    ]
  in
  CCmd.v
    (CCmd.info "resume" ~doc:"Resume a saved session in the TUI."
       ~docs:s_run_commands ~man ~exits)
    (exit_term
       CTerm.(
         const resume_run $ resume_session $ cwd $ sandbox $ mode $ last $ draft
         $ prompt))

let review cwd sandbox base =
  Eio_main.run @@ fun stdenv ->
  status
    (let* cwd_abs =
       optional_absolute_cwd stdenv cwd
       |> Result.map_error (fun message -> `Usage message)
     in
     Ok
       (launch ~stdenv ?cwd:cwd_abs
          ~launch:(Spice_tui.Startup.Launch_review { base_spec = base })
          ?sandbox ()))

let review_base =
  let doc =
    "Base revision to review against. When absent, reviews the worktree \
     against $(b,HEAD)."
  in
  CArg.(value & pos 0 (some string) None & info [] ~docv:"BASE" ~doc)

let review_command =
  let man =
    [
      `S CManpage.s_description;
      `P
        "Opens the review screen directly: the worktree diff against $(i,BASE) \
         (default $(b,HEAD)) with the review queue, marks, and verdict. \
         Closing the screen exits. The same surface is available inside the \
         chat TUI as $(b,/review).";
      `S CManpage.s_examples;
      `Pre "  spice review";
      `Pre "  spice review main";
    ]
  in
  CCmd.v
    (CCmd.info "review" ~doc:"Review the worktree changes in the TUI."
       ~docs:s_run_commands ~man ~exits)
    (exit_term CTerm.(const review $ cwd $ sandbox $ review_base))
