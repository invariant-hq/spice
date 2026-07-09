(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type availability = Idle_only | Anytime
type settings_tab = Config | Status | Usage | Skills

type fate =
  | Clear_session
  | Fork_session
  | Compact_session
  | Rename_session
  | Open_model
  | Open_sessions
  | Open_settings of settings_tab
  | Open_review
  | Open_login
  | Open_logout
  | Switch_mode of Spice_protocol.Mode.t
  | Toggle_thinking
  | Toggle_verbose
  | Quit

(* A catalog entry is plain data; the slash is its identity (slashes are unique,
   so it keys {!equal}). *)
type t = {
  slash : string;
  title : string;
  description : string;
  argument_hint : string option;
  availability : availability;
  echoes : bool;
  fate : fate;
}

type parsed = Exact of t | With_argument of t * string

let entry ?argument_hint ~availability ~echoes ~fate slash title description =
  { slash; title; description; argument_hint; availability; echoes; fate }

(* The catalog, in palette display order. Gates and echo behavior are ported
   from lib/tui/app.ml ([command_allowed_while_working], [echoes_command]); the
   fate mirrors [run_command_action_now]'s per-command dispatch. /stats is
   dropped — the usage tab absorbs it (03-ia-screens-overlays.md §Settings) —
   and so is /fast: the model panel owns the effort choice, and a toggle that
   silently remapped to an effort preset would contradict that ownership
   (decided 2026-07-08). *)
let all =
  [
    entry "/clear" "Clear"
      "Start a new session with empty context; previous session stays on disk"
      ~availability:Idle_only ~echoes:false ~fate:Clear_session;
    entry "/fork" "Fork" "Fork current session" ~availability:Idle_only
      ~echoes:false ~fate:Fork_session;
    entry "/compact" "Compact"
      "Free up context by summarizing the conversation so far"
      ~availability:Idle_only ~echoes:false ~fate:Compact_session;
    entry "/model" "Model" "Select model and effort" ~availability:Anytime
      ~echoes:false ~fate:Open_model;
    entry "/thinking" "Thinking" "Toggle thinking summaries"
      ~availability:Anytime ~echoes:true ~fate:Toggle_thinking;
    entry "/verbose" "Verbose" "Expand or collapse tool output (ctrl+o)"
      ~availability:Anytime ~echoes:true ~fate:Toggle_verbose;
    entry "/plan" "Plan" "Switch to plan mode: propose before building"
      ~availability:Anytime ~echoes:true
      ~fate:(Switch_mode Spice_protocol.Mode.Plan);
    entry "/build" "Build" "Switch to build mode: full coding"
      ~availability:Anytime ~echoes:true
      ~fate:(Switch_mode Spice_protocol.Mode.Build);
    entry "/sessions" "Sessions" "Show recent sessions" ~availability:Idle_only
      ~echoes:false ~fate:Open_sessions;
    entry "/rename" "Rename" "Rename the active session"
      ~argument_hint:"<title>" ~availability:Idle_only ~echoes:false
      ~fate:Rename_session;
    entry "/skills" "Skills" "Inspect discovered skills" ~availability:Anytime
      ~echoes:false ~fate:(Open_settings Skills);
    entry "/settings" "Settings" "Open settings" ~availability:Anytime
      ~echoes:false ~fate:(Open_settings Config);
    entry "/status" "Status" "Show session and workspace status"
      ~availability:Anytime ~echoes:false ~fate:(Open_settings Status);
    entry "/config" "Config" "Show effective TUI configuration"
      ~availability:Anytime ~echoes:false ~fate:(Open_settings Config);
    entry "/usage" "Usage" "Show active session token usage"
      ~availability:Anytime ~echoes:false ~fate:(Open_settings Usage);
    entry "/review" "Review" "Review the worktree changes"
      ~argument_hint:"[target]" ~availability:Anytime ~echoes:false
      ~fate:Open_review;
    entry "/login" "Login" "Log in to a provider" ~argument_hint:"[provider]"
      ~availability:Anytime ~echoes:false ~fate:Open_login;
    entry "/logout" "Logout" "Log out of a provider" ~argument_hint:"[provider]"
      ~availability:Anytime ~echoes:false ~fate:Open_logout;
    entry "/quit" "Quit" "Exit Spice" ~availability:Anytime ~echoes:false
      ~fate:Quit;
  ]

let slash t = t.slash
let title t = t.title
let description t = t.description
let argument_hint t = t.argument_hint
let availability t = t.availability
let echoes t = t.echoes
let fate t = t.fate
let equal a b = String.equal a.slash b.slash

let is_substring ~affix s =
  let la = String.length affix and ls = String.length s in
  if la = 0 then true
  else if la > ls then false
  else
    let rec loop i =
      if i + la > ls then false
      else if String.equal (String.sub s i la) affix then true
      else loop (i + 1)
    in
    loop 0

let matches ~query t =
  is_substring ~affix:query (String.lowercase_ascii t.slash)
  || is_substring ~affix:query (String.lowercase_ascii t.title)

let filter ~query =
  let query = String.lowercase_ascii (String.trim query) in
  List.filter (matches ~query) all

(* [arg_after ~slash trimmed] is the trimmed argument when [trimmed] is [slash]
   followed by whitespace and then non-empty text, matching the slash
   case-insensitively while preserving the argument's case. *)
let arg_after ~slash trimmed =
  let sl = String.length slash in
  if
    String.length trimmed > sl
    && String.equal (String.lowercase_ascii (String.sub trimmed 0 sl)) slash
    && match trimmed.[sl] with ' ' | '\t' -> true | _ -> false
  then
    let arg =
      String.trim (String.sub trimmed sl (String.length trimmed - sl))
    in
    if String.equal arg "" then None else Some arg
  else None

let parse s =
  let trimmed = String.trim s in
  if String.equal trimmed "" then None
  else
    let lower = String.lowercase_ascii trimmed in
    match List.find_opt (fun t -> String.equal lower t.slash) all with
    | Some t -> Some (Exact t)
    | None ->
        List.find_map
          (fun t ->
            match t.argument_hint with
            | None -> None
            | Some _ ->
                Option.map
                  (fun arg -> With_argument (t, arg))
                  (arg_after ~slash:t.slash trimmed))
          all
