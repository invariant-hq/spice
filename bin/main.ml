(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Cmdliner

let version =
  match Build_info.V1.version () with
  | None -> "dev"
  | Some v -> Build_info.V1.Version.to_string v

let log_src = Logs.Src.create "spice.cli" ~doc:"CLI entry and exit"

module Log = (val Logs.src_log log_src : Logs.LOG)

let command =
  let man =
    [
      `S Manpage.s_description;
      `P
        "Spice is the OCaml coding agent for planning, editing, and reviewing \
         OCaml projects.";
      `P
        "Run $(b,spice) without a command to open the interactive TUI; \
         $(b,spice resume) reopens a saved session there. Use $(b,spice run) \
         for headless sessions.";
      `S Cli_common.s_run_commands;
      `S Cli_common.s_session_commands;
      `S Cli_common.s_config_commands;
      `S Cli_common.s_diagnostic_commands;
    ]
  in
  let envs =
    [
      Cmd.Env.info "SPICE_CONFIG_HOME"
        ~doc:
          "Base directory for Spice config files and the auth store. Defaults \
           to $(b,XDG_CONFIG_HOME/spice).";
      Cmd.Env.info "SPICE_CONFIG"
        ~doc:"Extra config file layered over the user config file.";
      Cmd.Env.info "SPICE_LOG"
        ~doc:
          "Diagnostics log level: $(b,quiet), $(b,error), $(b,warning), \
           $(b,info), or $(b,debug). Logging is disabled when unset.";
      Cmd.Env.info "SPICE_LOG_FILE"
        ~doc:
          "Append diagnostics to this file instead of stderr. The interactive \
           TUI defaults to $(b,spice.log) under the config home.";
      Cmd.Env.info "SPICE_MODEL"
        ~doc:"Model selector override, as $(b,provider/model).";
      Cmd.Env.info "SPICE_SMALL_MODEL"
        ~doc:"Auxiliary small-model selector override.";
      Cmd.Env.info "SPICE_REASONING" ~doc:"Reasoning effort override.";
      Cmd.Env.info "SPICE_MAX_STEPS" ~doc:"Maximum model/tool steps override.";
      Cmd.Env.info "SPICE_PERMISSION_MODE"
        ~doc:
          "Permission preset override. $(b,bypass) is rejected from the \
           environment.";
      Cmd.Env.info "SPICE_PERMISSION_UNATTENDED"
        ~doc:"Unattended permission policy override: $(b,block) or $(b,deny).";
      Cmd.Env.info "SPICE_SANDBOX_MODE" ~doc:"Sandbox mode override.";
      Cmd.Env.info "SPICE_SANDBOX_REQUIRE"
        ~doc:"Sandbox enforcement requirement override.";
      Cmd.Env.info "SPICE_SHELL" ~doc:"Shell used by the shell tool.";
    ]
  in
  Cmd.group ~default:Cli_tui.default_term
    (Cmd.info "spice" ~version ~doc:"The OCaml coding agent." ~man ~envs
       ~exits:Cli_common.exits)
    [
      Cli_config.group;
      Cli_models.group;
      Cli_auth.group;
      Cli_permission.group;
      Cli_trust.trust_command;
      Cli_trust.untrust_command;
      Cli_session.group;
      Cli_skills.group;
      Cli_run.group;
      Cli_tui.resume_command;
      Cli_tui.review_command;
      Cli_sandbox.group;
      Cli_doctor.command;
      Cli_completion.command;
      Cli_debug.group;
    ]

(* cmdliner resolves the first token after [run] as a subcommand name and
   never falls back to the group's default term, so a bare prompt would fail
   with "unknown command". Splice in the explicit [start] so [spice run
   PROMPT] works; option-led invocations already reach the default term, and
   [spice run -- PROMPT] stays available for prompts that collide with a
   subcommand name. *)
let rewrite_run argv =
  match Array.to_list argv with
  | exe :: "run" :: token :: rest
    when (not (List.mem token [ "start"; "resume"; "reply" ]))
         && (String.equal token "-"
            || not (String.starts_with ~prefix:"-" token)) ->
      Array.of_list (exe :: "run" :: "start" :: token :: rest)
  | _ -> argv

let () =
  (* Decoder diagnostics flow into stored-error messages, JSON envelopes, and
     cram goldens; terminal styling there is noise, not signal. *)
  Jsont.Error.disable_ansi_styler ();
  Cli_common.setup_log ();
  let argv = rewrite_run Sys.argv in
  (* Only the subcommand name: positional arguments can carry prompt text,
     which never belongs in a log or a crash report. *)
  let subcommand =
    if
      Array.length argv > 1
      && (not (String.starts_with ~prefix:"-" argv.(1)))
      && not (String.equal argv.(1) "")
    then argv.(1)
    else "(default)"
  in
  (* Own fault handling before any command runs: record backtraces and install
     the uncaught-exception handler that persists a crash report and exits with
     the internal-error status. Without this a fault leaves nothing behind — no
     backtrace, no file — which is how a Linux TUI session can die silently. *)
  Spice_crash.install
    ~report_dir:
      (Filename.concat (Spice_host.Config_home.path Sys.getenv_opt) "crashes")
    ~context:(Printf.sprintf "version: %s  command: %s" version subcommand);
  (* Diagnostic fault injection: raise before any command runs so the crash
     path (report file, breadcrumb, exit status) can be exercised end to end
     through the real binary. Inert unless the variable is set. *)
  (match Sys.getenv_opt "SPICE_DEBUG_CRASH" with
  | Some tag when tag <> "" -> failwith ("SPICE_DEBUG_CRASH=" ^ tag)
  | Some _ | None -> ());
  Log.info (fun m ->
      m "spice started version=%s command=%s" version subcommand);
  let code = Cmd.eval' ~argv command in
  Log.debug (fun m -> m "exiting status=%d" code);
  exit code
