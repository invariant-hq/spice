(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Model_choice = Spice_host.Models.Model_choice

let log_src = Logs.Src.create "spice.tui.runtime" ~doc:"TUI runtime"

module Log = (val Logs.src_log log_src : Logs.LOG)

let ( let* ) = Result.bind

type outcome = { last_session : Spice_session.Id.t option }

let term_is_supported () =
  match Sys.getenv_opt "TERM" with
  | Some "dumb" | Some "" -> false
  | Some _ -> true
  | None -> false

let is_interactive () =
  Unix.isatty Unix.stdin && Unix.isatty Unix.stdout && term_is_supported ()

let reduced_motion () =
  match Sys.getenv_opt "SPICE_REDUCED_MOTION" with
  | Some ("1" | "true") -> true
  | _ -> false

let host_error error =
  Spice_diagnostic.to_string (Spice_host.Host.Error.diagnostic error)

let load_host ~stdenv ?process_env (startup : App.startup) =
  let process_env =
    match process_env with Some env -> env | None -> Spice_host.Env.current ()
  in
  let cwd = Option.map Spice_path.Abs.to_string startup.App.cwd in
  match Spice_host.Config.load ~stdenv ~process_env ?cwd () with
  | Error error -> Error (host_error (Spice_host.Host.Error.Config error))
  | Ok config -> (
      match
        Spice_host.Host.load ~stdenv ~registry:Spice_host_builtin.registry
          ~config ()
      with
      | Ok host -> Ok host
      | Error error -> Error (host_error error))

let version () =
  match Build_info.V1.version () with
  | None -> "dev"
  | Some version -> "v" ^ Build_info.V1.Version.to_string version

let model_label model =
  let llm = Spice_provider.Model.llm model in
  Spice_llm.Provider.id (Spice_llm.Model.provider llm)
  ^ "/" ^ Spice_llm.Model.id llm

let model_effort config choice =
  let effort =
    match
      Spice_host.Config.Models.reasoning (Spice_host.Config.models config)
    with
    | Some effort -> Some effort
    | None -> Spice_provider.Model.default_reasoning (Model_choice.model choice)
  in
  Option.map Spice_llm.Request.Options.Reasoning_effort.to_string effort

(* Non-default permission posture as the compact record's hanging label; the
   default ask-first posture stays silent (04-header-footer.md §1). *)
let permission_label config =
  match
    Spice_host.Config.Permissions.mode (Spice_host.Config.permissions config)
  with
  | Spice_host.Permission.Preset.Default -> None
  | Spice_host.Permission.Preset.Accept_edits -> Some "auto edits"
  | Spice_host.Permission.Preset.Plan -> Some "plan mode"
  | Spice_host.Permission.Preset.Bypass -> Some "never ask"

let permission_bypassed config =
  match
    Spice_host.Config.Permissions.mode (Spice_host.Config.permissions config)
  with
  | Spice_host.Permission.Preset.Bypass -> true
  | _ -> false

(* The sandbox mode and its origin, labelled for the record; unset means no
   sandbox line. [flag] is the per-run [--sandbox] override — it wins over the
   config mode with the same precedence {!Spice_host.Sandbox.resolve} applies,
   so the record and the resolve cannot disagree. *)
let sandbox_mode ?flag config =
  match flag with
  | Some mode -> Some (mode, "flag")
  | None ->
      Option.map
        (fun mode -> (mode, "config"))
        (Spice_host.Config.Sandbox.mode (Spice_host.Config.sandbox config))

let sandbox_string (mode, origin) =
  Spice_host.Sandbox.Mode.to_string mode ^ " (" ^ origin ^ ")"

let sandbox_label ?flag config =
  Option.map sandbox_string (sandbox_mode ?flag config)

let config_warning ?flag config =
  let trust = Spice_host.Config.workspace_trust config in
  if not (Spice_host.Trust.is_trusted trust) then
    Some
      ("project customization disabled: workspace trust is "
      ^ Spice_host.Trust.status_to_string (Spice_host.Trust.status trust))
  else
    match sandbox_mode ?flag config with
    | Some ((Spice_host.Sandbox.Mode.Danger_full_access, _) as sandbox) ->
        Some ("sandbox: " ^ sandbox_string sandbox)
    | Some _ | None ->
        if permission_bypassed config then Some "permission: never ask"
        else None

(* Whether no provider is connected (09-auth.md §9): at least one provider
   requires auth yet no provider — optional-auth ones included — has a
   credential. A store failure, or a setup with no required-auth provider,
   reads as connected so the nudge never fires without cause. Mirrors the
   model panel's lock test via {!Spice_host.Account.connected}; drives the
   home account line and the footer nudge (12-home.md §States). *)
let account_absent ~stdenv host =
  let requires_auth decl =
    Spice_provider.Auth.required (Spice_provider.auth decl)
  in
  match List.filter requires_auth (Spice_host.Host.providers host) with
  | [] -> false
  | _ :: _ -> (
      match Spice_host.Account.load ~stdenv host with
      | Error _ -> false
      | Ok accounts ->
          not
            (List.exists
               (fun decl ->
                 Spice_host.Account.connected accounts (Spice_provider.id decl))
               (Spice_host.Host.providers host)))

let build_snapshot ?sandbox_flag ~stdenv host =
  let config = Spice_host.Host.config host in
  let choice =
    Spice_host.Models.choose
      ~connected:(Spice_host.Account.connectivity ~stdenv host)
      host Model_choice.Main
  in
  let model, effort, context_window =
    match choice with
    | Ok choice ->
        ( model_label (Model_choice.model choice),
          model_effort config choice,
          Spice_provider.Model.context_window (Model_choice.model choice) )
    | Error _ -> ("(model unavailable)", None, None)
  in
  {
    Snapshot.version = version ();
    model;
    effort;
    cwd = Spice_host.Config.cwd config;
    context_window;
    permission = permission_label config;
    sandbox = sandbox_label ?flag:sandbox_flag config;
  }

(* The CR handle the home brief counts toward: CRs addressed to the spice agent
   (12-home.md §Layout, "N open · M addressed to spice"). The literal is a valid
   handle. *)
let spice_handle =
  match Spice_cr.Handle.of_string "spice" with
  | Ok handle -> handle
  | Error _ -> assert false

(* A worktree glance handle plus a resolved base, when the cwd is a repository
   with a HEAD. A fresh repo (no HEAD) yields no worktree/CR lines. *)
let discover_repo ~run ~stdenv ~cwd =
  let fs = Eio.Stdenv.fs stdenv in
  match Spice_review_git.discover ~run ~fs ~cwd:(Spice_path.Abs.to_string cwd) with
  | Error _ -> None
  | Ok repo -> (
      match Spice_review_git.resolve_base repo "HEAD" with
      | Error _ -> None
      | Ok base -> Some (repo, base))

(* Whether the workspace's Dune tooling engages, probed fresh per call and
   latched on first engagement: [auto] notices a dune-project that appears
   mid-session (a scaffold turn) at the next tick, while explicit on/off are
   constant either way. Until the latch sets, a probe costs two
   [Sys.file_exists]; after it, nothing. There is no mid-session disengage —
   the run's own watch lives until exit, so the readers match it. *)
let tooling_probe ~trusted ~host ~cwd =
  let latched = ref false in
  fun () ->
    !latched
    ||
    let engaged =
      trusted
      && Spice_host.Config.Workspace.tooling_engaged
           (Spice_host.Config.workspace (Spice_host.Host.config host))
           ~root:(Spice_path.Abs.to_string cwd)
    in
    if engaged then latched := true;
    engaged

(* The brief loader: cheap host probes assembled into a {!Home.Brief.t}. The worktree
   glance short-circuits on an unchanged fingerprint so an idle worktree costs
   one probe per tick; the derived lines are cached against it. *)
let make_brief_loader ?sandbox_flag ~git_run ~trusted ~stdenv ~clock ~host ~cwd
    () =
  let config = Spice_host.Host.config host in
  let warning = config_warning ?flag:sandbox_flag config in
  let workspace = Spice_workspace.single (Spice_workspace.Root.make cwd) in
  (* The Dune build-health probe reads a live watch's endpoint; it never spawns
     one ([build_health] never triggers a lazy starter). While tooling is
     disengaged there is no watch to read, so the probe is skipped and the
     footer reports [Disconnected] rather than polling the registry each
     tick. *)
  let dune_health =
    let engaged = tooling_probe ~trusted ~host ~cwd in
    let dune =
      lazy
        (Spice_ocaml_dune.Rpc.Instance.create ~fs:(Eio.Stdenv.fs stdenv)
           ~net:(Eio.Stdenv.net stdenv) ~workspace
           ~sleep:(Eio.Time.sleep clock) ())
    in
    fun () ->
      if engaged () then
        Spice_ocaml_dune.Rpc.Instance.build_health (Lazy.force dune) ~clock ()
      else Spice_ocaml_dune.Rpc.Instance.Health.Disconnected
  in
  (* Lazy: the git spawn belongs to the first (asynchronous) brief load, not
     the boot critical path before the first frame. *)
  let repo =
    lazy (if trusted then discover_repo ~run:git_run ~stdenv ~cwd else None)
  in
  let store = Spice_host.Session.store ~stdenv host in
  let known = ref None in
  let cached_worktree = ref None in
  let cached_crs = ref None in
  let glance () =
    match Lazy.force repo with
    | None -> (None, None)
    | Some (repo, base) -> (
        match Spice_review_git.glance_if_changed repo ~base ~known:!known with
        | Ok `Unchanged -> (!cached_worktree, !cached_crs)
        | Ok (`Loaded glance) ->
            known := Some glance.Spice_review_git.fingerprint;
            let worktree =
              if glance.Spice_review_git.stats.Spice_diff.files > 0 then
                Some glance.Spice_review_git.stats
              else None
            in
            let counts =
              Spice_cr.Occurrence.counts ~handle:spice_handle
                glance.Spice_review_git.crs
            in
            let crs =
              if counts.Spice_cr.Occurrence.open_ > 0 then Some counts else None
            in
            cached_worktree := worktree;
            cached_crs := crs;
            (worktree, crs)
        (* A transient git error keeps the last known worktree/CR facts rather
           than reverting to empties: the block must not flicker out on a slow
           or racing probe (12-home.md §Workspace block). *)
        | Error _ -> (!cached_worktree, !cached_crs))
  in
  (* The newest resumable session becomes the [session] fact: its title, or the
     first-prompt preview, or "untitled" — never the raw id (12-home.md
     §Workspace block). The host query keeps its subagent-child filter; the home
     takes only the head. *)
  let session_of ~now (summary : Spice_protocol.Session_summary.t) =
    let title =
      match summary.Spice_protocol.Session_summary.title with
      | Some t when String.trim t <> "" -> t
      | _ -> (
          match summary.Spice_protocol.Session_summary.preview with
          | Some p -> p
          | None -> "untitled")
    in
    {
      Home.Brief.id = summary.Spice_protocol.Session_summary.id;
      title;
      age =
        Home.Brief.relative_age ~now
          summary.Spice_protocol.Session_summary.updated_at;
    }
  in
  let cached_session = ref None in
  let load_session () =
    match
      Spice_host.Session.recent_in_cwd store ~fs:(Eio.Stdenv.fs stdenv) ~cwd
        ~limit:1
    with
    | Ok (summary :: _, _) ->
        let now =
          Spice_session.Time.of_unix_seconds_float (Eio.Time.now clock)
        in
        cached_session := Some (session_of ~now summary)
    | Ok ([], _) -> cached_session := None
    (* Transient store error: keep the last known session. *)
    | Error _ -> ()
  in
  (* The session query is a store scan with no change token, and only moves on
     out-of-band activity, so it refreshes every fifth tick (~10s) rather than
     every 2s tick; the worktree/dune facts stay per-tick. *)
  let tick = ref 0 in
  let session () =
    if !tick mod 5 = 0 then load_session ();
    !cached_session
  in
  fun () ->
    let worktree, crs = glance () in
    let session = session () in
    incr tick;
    {
      Home.Brief.dune = dune_health ();
      worktree;
      crs;
      session;
      (* Recomputed each tick, not memoized like [warning], so a [/login] while
         the stage is up clears the nudge within a tick. *)
      account_absent = account_absent ~stdenv host;
      warning;
    }

(* The chat-phase Dune health watcher (01-transcript.md §Data notices, dune): a
   workspace RPC instance polled off its own tick, since the brief tick that
   feeds the footer stops at the drop. [build_health] is the same one-shot probe
   the brief loader runs, so a poll costs one registry lookup and a short-lived
   connection and spawns no watch (it never triggers the lazy starter). After a
   FAILING verdict the instance's diagnostic store names the file to blame,
   preferring an error's location over a warning's; the count itself is
   [build_health]'s. Polling mirrors the old TUI's live footer (which polled
   [refresh_status] every 2s) — the RPC layer does expose a change subscription
   ([Rpc.Instance.run ~on_event]), but that is a blocking stream needing a
   bespoke reconnecting fiber, where this fits the poll-and-render loop the shell
   already runs for the brief. *)
let failing_file dune =
  let entries =
    Spice_ocaml_dune.Rpc.Diagnostic.Store.to_list
      (Spice_ocaml_dune.Rpc.Instance.diagnostics dune)
  in
  let located (_, d) =
    Option.map
      (fun loc ->
        Spice_path.Rel.to_string
          (Spice_workspace.Path.rel (Spice_ocaml.Location.path loc)))
      (Spice_ocaml.Diagnostic.location d)
  in
  let is_error (_, d) =
    match Spice_ocaml.Diagnostic.severity d with
    | Spice_ocaml.Diagnostic.Severity.Error -> true
    | Spice_ocaml.Diagnostic.Severity.Warning
    | Spice_ocaml.Diagnostic.Severity.Information
    | Spice_ocaml.Diagnostic.Severity.Hint ->
        false
  in
  match List.find_map located (List.filter is_error entries) with
  | Some _ as file -> file
  | None -> List.find_map located entries

let make_health_loader ~trusted ~host ~stdenv ~clock ~cwd =
  (* While workspace tooling is disengaged no watch runs, so the chat-phase
     poll reports [Disconnected] without touching the registry; the latching
     probe flips it live when tooling engages mid-session. *)
  let engaged = tooling_probe ~trusted ~host ~cwd in
  let workspace = Spice_workspace.single (Spice_workspace.Root.make cwd) in
  let dune =
    lazy
      (Spice_ocaml_dune.Rpc.Instance.create ~fs:(Eio.Stdenv.fs stdenv)
         ~net:(Eio.Stdenv.net stdenv) ~workspace ~sleep:(Eio.Time.sleep clock)
         ())
  in
  fun () ->
    if not (engaged ()) then
      (Spice_ocaml_dune.Rpc.Instance.Health.Disconnected, None)
    else
      let dune = Lazy.force dune in
      let health = Spice_ocaml_dune.Rpc.Instance.build_health dune ~clock () in
      let file =
        match health with
        | Spice_ocaml_dune.Rpc.Instance.Health.Failing _ -> failing_file dune
        | Spice_ocaml_dune.Rpc.Instance.Health.Clean
        | Spice_ocaml_dune.Rpc.Instance.Health.Disconnected
        | Spice_ocaml_dune.Rpc.Instance.Health.Unknown ->
            None
      in
      (health, file)

(* The quick-switch panel's rows: up to [limit] top-level recent sessions in the
   cwd, each projected to the panel's row with the display title and the
   TUI-formatted age (formatting is the TUI's; the facts are the host's,
   doc/plans/tui-next-surfaces.md §Host seams). A transient store error is
   forwarded so the panel renders its error line rather than the empty state. *)
let load_recent_sessions ~stdenv ~clock ~store ~cwd ~limit =
  match
    Spice_host.Session.recent_in_cwd store ~fs:(Eio.Stdenv.fs stdenv) ~cwd
      ~limit
  with
  | Error error -> Error (Spice_protocol.Error.message error)
  | Ok (summaries, _corrupt) ->
      let now = Spice_session.Time.of_unix_seconds_float (Eio.Time.now clock) in
      Ok
        (List.map
           (fun (summary : Spice_protocol.Session_summary.t) ->
             {
               Sessions_panel.id = summary.Spice_protocol.Session_summary.id;
               title = Spice_protocol.Session_summary.display_title summary;
               age =
                 Home.Brief.relative_age ~now
                   summary.Spice_protocol.Session_summary.updated_at;
               search_key = Spice_protocol.Session_summary.search_key summary;
             })
           summaries)

(* The browse screen's recency bucket for a session (03-ia §Sessions): last
   updated within a day is [today], within a week [this week], older [older].
   Bucketing is presentation like the age formatting, so it lives here; the times
   are the host's. *)
let recency_group ~now updated =
  let delta_ms =
    Int64.sub
      (Spice_session.Time.to_unix_ms now)
      (Spice_session.Time.to_unix_ms updated)
  in
  let secs =
    if Int64.compare delta_ms 0L <= 0 then 0
    else Int64.to_int (Int64.div delta_ms 1000L)
  in
  if secs < 24 * 3600 then Sessions_screen.Today
  else if secs < 7 * 24 * 3600 then Sessions_screen.This_week
  else Sessions_screen.Older

(* The browse screen's rows: every resumable top-level session in the cwd,
   newest first, each projected with its recency bucket, turn count, first-prompt
   preview, and — for a forked session — a lineage line naming the parent by its
   title, resolved from the loaded set (mirrors the old picker's [parent_label]).
   A store error is forwarded so the screen renders its error line. *)
let load_screen_sessions ~stdenv ~clock ~store ~cwd =
  match
    Spice_host.Session.recent_in_cwd store ~fs:(Eio.Stdenv.fs stdenv) ~cwd
      ~limit:max_int
  with
  | Error error -> Error (Spice_protocol.Error.message error)
  | Ok (summaries, _corrupt) ->
      let now = Spice_session.Time.of_unix_seconds_float (Eio.Time.now clock) in
      (* One id→title map for the whole load, so resolving every fork's parent
         costs one pass over the summaries — a per-fork scan is quadratic in
         session count, seconds of UI-domain CPU at a few hundred sessions. *)
      let titles = Hashtbl.create (List.length summaries) in
      List.iter
        (fun (s : Spice_protocol.Session_summary.t) ->
          Hashtbl.replace titles
            (Spice_session.Id.to_string s.Spice_protocol.Session_summary.id)
            (Spice_protocol.Session_summary.display_title s))
        summaries;
      let title_of parent =
        let key = Spice_session.Id.to_string parent in
        match Hashtbl.find_opt titles key with
        | Some title -> title
        | None -> key
      in
      Ok
        (List.map
           (fun (summary : Spice_protocol.Session_summary.t) ->
             let lineage =
               Option.map
                 (fun fork ->
                   Printf.sprintf "fork of \"%s\""
                     (title_of (Spice_session.Metadata.Forked_from.parent fork)))
                 summary.Spice_protocol.Session_summary.forked_from
             in
             {
               Sessions_screen.id = summary.Spice_protocol.Session_summary.id;
               title = Spice_protocol.Session_summary.display_title summary;
               age =
                 Home.Brief.relative_age ~now
                   summary.Spice_protocol.Session_summary.updated_at;
               turns = summary.Spice_protocol.Session_summary.turns;
               preview = summary.Spice_protocol.Session_summary.preview;
               lineage;
               cwd =
                 Path_display.home_relative
                   summary.Spice_protocol.Session_summary.cwd;
               search_key = Spice_protocol.Session_summary.search_key summary;
               group =
                 recency_group ~now
                   summary.Spice_protocol.Session_summary.updated_at;
             })
           summaries)

(* Model panel facts (05-overlays-pickers.md §Model picker; doc/plans/
   tui-next-surfaces.md §Host seams "Model panel"). Provider grouping, the detail
   column, and the effort metadata come from the pure catalog; the per-provider
   account phase decides the locked rows and touches the credential store, so —
   like the settings facts — this is the impure builder and {!Model_panel} stays
   pure over it. *)
let model_provider_title provider =
  match Spice_llm.Provider.id provider with
  | "openai" -> "OpenAI"
  | "anthropic" -> "Anthropic"
  | "google" -> "Google"
  | "deepseek" -> "DeepSeek"
  | "local" -> "Local"
  | id -> id

(* Trim a decimal's trailing zeros (and a bare point) so [1.00M] reads [1M]. *)
let trim_decimal text =
  let rec loop index =
    if index <= 0 then ""
    else
      match text.[index - 1] with
      | '0' -> loop (index - 1)
      | '.' -> String.sub text 0 (index - 1)
      | _ -> String.sub text 0 index
  in
  loop (String.length text)

let model_context_label model =
  match Spice_provider.Model.context_window model with
  | None -> None
  | Some tokens ->
      if tokens >= 1_000_000 then
        Some
          (trim_decimal
             (Printf.sprintf "%.2f" (Float.of_int tokens /. 1_000_000.))
          ^ "M context")
      else Some (string_of_int (max 1 (tokens / 1000)) ^ "k context")

let model_status_label model =
  match Spice_provider.Model.status model with
  | Spice_provider.Model.Preview -> Some "Preview"
  | Spice_provider.Model.Deprecated -> Some "Deprecated"
  | Spice_provider.Model.Stable | Spice_provider.Model.Unavailable _ -> None

(* The effort-line caution the panel shows while a preview/deprecated model is
   highlighted (05-overlays-pickers.md §Model picker). *)
let model_warning model =
  match Spice_provider.Model.status model with
  | Spice_provider.Model.Preview -> Some "preview"
  | Spice_provider.Model.Deprecated -> Some "deprecated"
  | Spice_provider.Model.Stable | Spice_provider.Model.Unavailable _ -> None

(* A one-line family blurb (mirrors the old picker's [model_description]) closing
   the detail column when nothing more specific applies. *)
let model_description model =
  let contains needle text =
    String.includes ~affix:needle (String.lowercase_ascii text)
  in
  let family =
    Option.value
      (Spice_provider.Model.family model)
      ~default:(Spice_provider.Model.id model)
  in
  if contains "nano" family || contains "haiku" family then
    "Fastest for quick answers"
  else if
    contains "mini" family || contains "flash" family
    || contains "sonnet" family
  then "Efficient for routine tasks"
  else if
    contains "codex" family || contains "coder" family
    || contains "devstral" family
  then "Tuned for coding tasks"
  else "Best for everyday, complex tasks"

(* The [·]-joined detail — Default, status, context, description — with the
   provider and name excluded (they are the header and the label,
   05-overlays-pickers.md rule 6). *)
let model_detail ~defaults model =
  let default =
    if List.exists (String.equal (Spice_provider.Model.selector model)) defaults
    then Some "Default"
    else None
  in
  [
    default;
    model_status_label model;
    model_context_label model;
    Some (model_description model);
  ]
  |> List.filter_map Fun.id |> String.concat " · "

let default_model_selectors catalog =
  Spice_provider.Catalog.providers catalog
  |> List.filter_map (fun provider ->
      Option.map Spice_provider.Model.selector
        (Spice_provider.default_model provider))

let load_model_facts ?selected ~stdenv ~host () =
  let catalog = Spice_host.Host.catalog host in
  let config = Spice_host.Host.config host in
  (* [selected] is the session's pinned pick; without one the row marks the
     model the next turn would derive. *)
  let current =
    match selected with
    | Some model -> Some (Spice_provider.Model.selector model)
    | None ->
        Spice_host.Models.choose
          ~connected:(Spice_host.Account.connectivity ~stdenv host)
          host Model_choice.Main
        |> Result.to_option
        |> Option.map (fun choice ->
            Spice_provider.Model.selector (Model_choice.model choice))
  in
  let reasoning =
    Spice_host.Config.Models.reasoning (Spice_host.Config.models config)
  in
  let defaults = default_model_selectors catalog in
  (* A model is locked (mute-and-show) only when its provider REQUIRES auth
     AND its account is unusable — no credential or a stored-but-rejected one.
     Both route to [/login] rather than letting the user pick a model that
     fails auth mid-turn (09-auth.md §States). A no-auth or optional-auth
     provider (DeepSeek, the local models, Ollama) is never locked: a missing
     credential there just means "serving bare", so selecting one must use it,
     never route to login. Loaded once; a store failure leaves every provider
     unlocked rather than falsely locking the configured model. *)
  let accounts = Result.to_option (Spice_host.Account.load ~stdenv host) in
  let requires_auth =
    let ids =
      Spice_host.Host.providers host
      |> List.filter_map (fun decl ->
          if Spice_provider.Auth.required (Spice_provider.auth decl) then
            Some (Spice_llm.Provider.id (Spice_provider.id decl))
          else None)
    in
    fun provider -> List.mem (Spice_llm.Provider.id provider) ids
  in
  let locked provider =
    requires_auth provider
    &&
    match accounts with
    | None -> false
    | Some accounts -> not (Spice_host.Account.connected accounts provider)
  in
  let models =
    Spice_provider.Catalog.models catalog
    |> List.filter (fun model ->
        Spice_provider.Model.visible model
        && Spice_provider.Model.has_capability
             Spice_provider.Model.Capability.tools model)
    |> List.map (fun model ->
        let selector = Spice_provider.Model.selector model in
        let provider = Spice_provider.Model.provider model in
        let name =
          match Spice_provider.Model.display_name model with
          | Some name -> name
          | None -> Spice_provider.Model.id model
        in
        {
          Model_panel.selector;
          name;
          provider_title = model_provider_title provider;
          detail = model_detail ~defaults model;
          locked = locked provider;
          is_current =
            (match current with
            | Some current -> String.equal current selector
            | None -> false);
          supported_reasoning = Spice_provider.Model.supported_reasoning model;
          default_reasoning = Spice_provider.Model.default_reasoning model;
          warning = model_warning model;
          search_key =
            String.concat " " [ selector; name; Spice_llm.Provider.id provider ];
        })
  in
  { Model_panel.models; reasoning }

(* Persist a model pick (05-overlays-pickers.md §Model picker): validate the
   selector through [Models.for_select], then set [Field.model] +
   [Field.reasoning] in the user config in one edit. The config write seeds
   future sessions; this session's effectiveness comes from the runtime
   pinning the pick as its selection, which the next turn's binding reads. *)
let save_model_selection ~stdenv host ~selector ~effort =
  let* model =
    Spice_host.Models.for_select (Spice_host.Host.catalog host) selector
    |> Result.map_error host_error
  in
  let selector = Spice_provider.Model.selector model in
  let effort_string =
    Option.map Spice_llm.Request.Options.Reasoning_effort.to_string effort
  in
  let files = Spice_host.Config.files (Spice_host.Host.config host) in
  Spice_host.Config.Config_file.edit ~stdenv files
    Spice_host.Config.Config_file.User ~f:(fun doc ->
      let* doc =
        Spice_host.Config.Config_file.set Spice_host.Config.Field.model
          (Some selector) doc
      in
      Spice_host.Config.Config_file.set Spice_host.Config.Field.reasoning
        effort_string doc)
  |> Result.map_error (fun error ->
      host_error (Spice_host.Host.Error.Config error))
  |> Result.map (fun () -> model)

(* The effective sandbox for a run: the [--sandbox] flag over the config mode,
   gated, protecting the same host authority roots as the headless CLI so the
   frontends confine identically. *)
let resolve_sandbox ?flag ~sw ~stdenv host ~workspace =
  let process_env = Spice_host.Env.current () in
  let config = Spice_host.Host.config host in
  let sandbox_config = Spice_host.Config.sandbox config in
  let workspace_trusted =
    Spice_host.Config.workspace_trust config |> Spice_host.Trust.is_trusted
  in
  Spice_host.Sandbox.resolve ~sw ?flag
    ?config_mode:(Spice_host.Config.Sandbox.mode sandbox_config)
    ~require:(Spice_host.Config.Sandbox.require sandbox_config)
    ~protect:(Spice_host.Config.sandbox_protected_roots config)
    ~writable_roots:(Spice_host.Config.Sandbox.writable_roots sandbox_config)
    ~network:(Spice_host.Config.Sandbox.network sandbox_config)
    ~toolchain_caches:
      (Spice_host.Config.Sandbox.toolchain_caches sandbox_config)
    ~workspace_trusted
    ~stdenv
    ~env:(Spice_host.Env.get process_env)
    ~workspace ()

let git_runner ~stdenv ~sandbox ~cwd args =
  let argv = Spice_sandbox.Argv.make ~program:"git" ("-C" :: cwd :: args) in
  match Spice_sandbox.spawn sandbox ~argv with
  | Error error -> Error (Spice_sandbox.Error.message error)
  | Ok spawn ->
      let argv =
        Spice_sandbox.Spawn.argv spawn |> Spice_sandbox.Argv.to_list
      in
      let env =
        Spice_sandbox.Spawn.env spawn
        |> List.map (fun (name, value) -> name ^ "=" ^ value)
        |> Array.of_list
      in
      let stderr_buffer = Buffer.create 256 in
      match
        Eio.Process.parse_out ~env
          ~stderr:(Eio.Flow.buffer_sink stderr_buffer)
          (Eio.Stdenv.process_mgr stdenv)
          Eio.Buf_read.take_all argv
      with
      | output -> Ok output
      | exception exn ->
          let stderr = String.trim (Buffer.contents stderr_buffer) in
          Error (if String.is_empty stderr then Printexc.to_string exn else stderr)

let restricted_git_runner ~cwd args =
  Error
    (Printf.sprintf
       "repository activation is required to run git %s in %s; trust the \
        repository and reload Spice"
       (String.concat " " args) cwd)

(* Assemble the workspace run for a session: gate the sandbox — the [--sandbox]
   flag over the config mode — and start the credential-free assembly
   (run.mli's fail-closed contract). The turn contract — mode, model,
   credentialed client — binds per turn via {!Spice_host.Run.runner}, so
   assembly happens once per session and a login, model switch, or mode switch
   needs no reassembly. [Run.close] releases the whole owned run when it is
   superseded or the TUI exits. *)
let build_run ?sandbox_flag ~sw ~stdenv ~host ~session_id () =
  let config = Spice_host.Host.config host in
  let workspace =
    Spice_workspace.single
      (Spice_workspace.Root.make (Spice_host.Config.cwd config))
  in
  let* sandbox =
    resolve_sandbox ?flag:sandbox_flag ~sw ~stdenv host ~workspace
    |> Result.map_error Spice_host.Sandbox.Resolve_error.message
  in
  let permission = Spice_host.Config.permission_posture config in
  let* plan =
    Spice_host.Run.plan ~workspace ~sandbox ~permission ()
    |> Result.map_error Spice_host.Sandbox.Gate_error.message
  in
  let store = Spice_host.Session.store ~stdenv host in
  let* run =
    Spice_host.Run.start ~sw ~stdenv host plan ~store ~session:session_id
      ~http:(Spice_host_builtin.web_http_client stdenv)
      ~fetch_https:(Spice_host_builtin.web_fetch_https ())
      ()
    |> Result.map_error host_error
  in
  Ok run

let turn_reasoning config model =
  match
    Spice_host.Config.Models.reasoning (Spice_host.Config.models config)
  with
  | Some effort -> Some effort
  | None -> Spice_provider.Model.default_reasoning model

let make_turn ?origin ~clock ~config ~model ~effort input =
  let reasoning_effort =
    match effort with Some _ -> effort | None -> turn_reasoning config model
  in
  let options = Spice_host.Turn_options.resolve ~model ?reasoning_effort () in
  Spice_protocol.Command.Start.make
    ~id:(Spice_host.Session.fresh_turn_id ~clock)
    ~input ~options ?origin ()

(* The unified @ completion's ignore set: the host's default ignores plus
   picker-local extras — directories a mention would never target (VCS innards,
   vendored deps, direnv state). The extras are UX, not a world fact, so they
   live here rather than widening [Spice_host.default_ignore]
   (doc/plans/tui-next-composer.md §Host seams). *)
let ignored_mention_dir ~rel name =
  Spice_host.default_ignore rel
  ||
  match name with
  | ".svn" | ".hg" | ".bzr" | ".jj" | ".sl" | "node_modules" | ".direnv" -> true
  | _ -> false

(* Classify one directory entry as a mention row: files and directories only —
   symlinks and special files never complete. [None] drops the entry. *)
let mention_item ~fs ~workspace parent name =
  let* child = Spice_workspace_fs.child parent name in
  let rel = Spice_workspace.Path.rel child in
  let* stat =
    Spice_workspace_fs.stat ~fs ~workspace ~follow_symlink:false child
  in
  match stat with
  | None -> Ok None
  | Some stat -> (
      match stat.Eio.File.Stat.kind with
      | `Directory when ignored_mention_dir ~rel name -> Ok None
      | `Directory -> Ok (Some (Mention.Directory rel))
      | `Regular_file -> Ok (Some (Mention.File rel))
      | `Symbolic_link | `Unknown | `Fifo | `Character_special | `Block_device
      | `Socket ->
          Ok None)

(* Directories sort ahead of files, each group by name — the old picker's
   order, kept so the tree reads the same across the rewrite. *)
let mention_rank = function
  | Mention.Directory _ -> 0
  | Mention.File _ | Mention.Agent_thread _ -> 1

let mention_name = function
  | Mention.Directory rel | Mention.File rel -> Spice_path.Rel.to_string rel
  | Mention.Agent_thread { name } -> name

let compare_mention_items a b =
  match Int.compare (mention_rank a) (mention_rank b) with
  | 0 -> String.compare (mention_name a) (mention_name b)
  | order -> order

(* Enumerate one workspace directory for the mention list: a lazy per-dir
   readdir + stat classification, never a bulk walk (Spice_workspace_fs is the
   host-owned seam; tui-next-composer.md §Host seams). *)
let load_mention_dir ~stdenv ~cwd dir =
  let fs = Eio.Stdenv.fs stdenv in
  let workspace = Spice_workspace.single (Spice_workspace.Root.make cwd) in
  let path =
    Spice_workspace.Path.append (Spice_workspace.root_path workspace) dir
  in
  let result =
    let* names = Spice_workspace_fs.read_dir_names ~fs ~workspace path in
    let rec loop acc = function
      | [] -> Ok (List.sort compare_mention_items acc)
      | name :: names -> (
          match mention_item ~fs ~workspace path name with
          | Error error -> Error error
          | Ok None -> loop acc names
          | Ok (Some item) -> loop (item :: acc) names)
    in
    loop [] names
  in
  Result.map_error Spice_workspace_fs.Error.message result

(* Prompt-history I/O: one machine-local JSONL in state home (the codec and load
   semantics live in {!History}; the runtime owns the path, read, and locked
   append — history.mli). *)
let history_path host =
  let config = Spice_host.Host.config host in
  Spice_host.Config.state_home config |> Spice_path.Abs.to_string
  |> fun dir -> Filename.concat dir "history.jsonl"

(* The cross-process lock is a sidecar [.lock] acquired without an uncancellable
   wait: [F_TLOCK] is a non-blocking fcntl, so no systhread parks on it — the
   [sleep] between tries is the only wait, and it is an Eio cancellation point. A
   blocked [F_LOCK] in a systhread would ignore cancellation until the peer
   released the lock, deadlocking teardown; the session store avoids it the same
   way (spice_session_store.ml with_lock_path). *)
let with_history_lock ~sleep path f =
  let rec unlock fd =
    match Unix.lockf fd Unix.F_ULOCK 0 with
    | () -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> unlock fd
  in
  let fd =
    Unix.openfile (path ^ ".lock")
      [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
      0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      let rec acquire backoff =
        match Unix.lockf fd Unix.F_TLOCK 0 with
        | () -> ()
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> acquire backoff
        | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
            sleep backoff;
            acquire (Float.min (backoff *. 2.) 0.1)
      in
      acquire 0.001;
      Fun.protect ~finally:(fun () -> unlock fd) f)

let load_prompt_history ~stdenv host =
  let path = Eio.Path.( / ) (Eio.Stdenv.fs stdenv) (history_path host) in
  if not (Eio.Path.is_file path) then []
  else
    match Eio.Path.load path with
    | contents -> History.load contents
    | exception _ -> []

let rec write_all fd line offset length =
  if length = 0 then ()
  else
    let written = Unix.write_substring fd line offset length in
    write_all fd line (offset + written) (length - written)

(* Best-effort persistence: a failed write loses one history line, never the
   draft (the composer's in-memory walk already recorded it), so failures
   yield [None] rather than surfacing. *)
let append_prompt_history ~stdenv ~clock host ~session entry =
  let ts = Eio.Time.now clock |> Float.floor |> int_of_float in
  match History.Entry.of_draft ~session ~ts entry with
  | None -> None
  | Some record -> (
      match History.encode record with
      | exception Invalid_argument _ -> None
      | encoded -> (
          let path = history_path host in
          let line = encoded ^ "\n" in
          match
            Eio.Path.mkdirs ~exists_ok:true ~perm:0o700
              (Eio.Path.( / ) (Eio.Stdenv.fs stdenv) (Filename.dirname path));
            with_history_lock ~sleep:(Eio.Time.sleep clock) path (fun () ->
                let fd =
                  Unix.openfile path
                    [
                      Unix.O_CREAT; Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CLOEXEC;
                    ]
                    0o600
                in
                Fun.protect
                  ~finally:(fun () -> Unix.close fd)
                  (fun () -> write_all fd line 0 (String.length line)))
          with
          | () -> Some record
          | exception _ -> None))

(* Run one user shell command (03-composer.md §Shell mode): gated through the
   same effective sandbox as the run, executed by {!Spice_tools.Shell} off the
   session drain — ephemeral, never persisted to the session
   (doc/plans/tui-next-composer.md §Host seams). *)
let run_user_shell ?sandbox_flag ~stdenv ~host ~cancelled input =
  Eio.Switch.run @@ fun sw ->
  let config = Spice_host.Host.config host in
  let workspace =
    Spice_workspace.single
      (Spice_workspace.Root.make (Spice_host.Config.cwd config))
  in
  match resolve_sandbox ?flag:sandbox_flag ~sw ~stdenv host ~workspace with
  | Error error -> Error (Spice_host.Sandbox.Resolve_error.message error)
  | Ok sandbox -> (match Spice_host.Sandbox.gate sandbox with
  | Error error -> Error (Spice_host.Sandbox.Gate_error.message error)
  | Ok () ->
      let shell =
        Spice_tools.Shell.Config.make
          ~shell:
            (Spice_host.Config.Runtime.shell (Spice_host.Config.runtime config))
          ~sandbox:(Spice_host.Sandbox.Effective.sandbox sandbox)
          ()
      in
      let tool =
        Spice_tools.Shell.tool ~fs:(Eio.Stdenv.fs stdenv) ~workspace
          ~config:shell ()
      in
      let encoded = Spice_tools.Shell.Input.encode input in
      Spice_tool.Call.decode [ tool ] ~name:Spice_tools.Shell.name
        ~input:encoded ()
      |> Result.map_error (Format.asprintf "%a" Spice_tool.Error.pp)
      |> Result.map (fun call -> Spice_tool.Call.run call ~cancelled ()))

(* Distill a shell result into the settled transcript block: the first output
   line as the [⎿] summary, the exit shape and remaining line count as facts.
   The full 02-tools shell view (output tail, disclosure) is a later
   iteration. *)
let shell_block input result =
  let command = Spice_tools.Shell.Input.command input in
  let stream_lines stream =
    let text =
      match stream with
      | Spice_tools.Shell.Output.Complete text -> text
      | Spice_tools.Shell.Output.Truncated { head; _ } -> head
    in
    List.filter
      (fun line -> not (String.equal (String.trim line) ""))
      (String.split_on_char '\n' text)
  in
  match result with
  | Error message ->
      {
        Tool_block.verb = Tool_block.Shell;
        argument = command;
        dot = Tool_block.Failed;
        summary = message;
        facts = [];
        disclosable = false;
        detail = Tool_block.Summary;
      }
  | Ok result ->
      let output =
        Option.bind (Spice_tool.Result.output result)
          Spice_tools.Shell.Output.of_tool_output
      in
      let lines =
        match output with
        | Some output -> (
            match stream_lines (Spice_tools.Shell.Output.stdout output) with
            | [] -> stream_lines (Spice_tools.Shell.Output.stderr output)
            | lines -> lines)
        | None -> []
      in
      let dot, fallback =
        match Spice_tool.Result.status result with
        | Spice_tool.Result.Completed -> (Tool_block.Ok, "done")
        | Spice_tool.Result.Failed { message; _ } -> (Tool_block.Failed, message)
        | Spice_tool.Result.Interrupted { reason; _ } ->
            (Tool_block.Warned, reason)
      in
      let summary = match lines with line :: _ -> line | [] -> fallback in
      let exit_fact =
        match Option.map Spice_tools.Shell.Output.status output with
        | Some (Spice_tools.Shell.Output.Exited 0) | None -> []
        | Some (Spice_tools.Shell.Output.Exited code) ->
            [ "exit " ^ string_of_int code ]
        | Some (Spice_tools.Shell.Output.Signaled signal) ->
            [ "signal " ^ string_of_int signal ]
        | Some (Spice_tools.Shell.Output.Timed_out _) -> [ "timed out" ]
        | Some Spice_tools.Shell.Output.Cancelled -> [ "interrupted" ]
        | Some (Spice_tools.Shell.Output.Failed_to_start _) -> []
      in
      let more =
        match lines with
        | _ :: (_ :: _ as rest) ->
            [ "+" ^ string_of_int (List.length rest) ^ " lines" ]
        | _ -> []
      in
      {
        Tool_block.verb = Tool_block.Shell;
        argument = command;
        dot;
        summary;
        facts = exit_fact @ more;
        disclosable = false;
        detail = Tool_block.Summary;
      }

(* A transport/provider failure carries a raw exception string in its message —
   each provider's api.ml stores [Printexc.to_string exn], so an unreachable
   endpoint reads as an [Eio.Io Net Connection_failure …] dump. The transcript
   wants a plain sentence, not a backtrace (01-transcript.md §Notices, failure
   class), so humanize a provider error by its kind. Every other
   Spice_protocol.Error already carries a readable message and passes through; the
   raw detail stays in logs and the CLI diagnostic (Spice_protocol.Error.hints). *)
let failure_message error =
  match error with
  | Spice_protocol.Error.Provider provider_error -> (
      let provider =
        match Spice_llm.Error.provider provider_error with
        | Some p -> Spice_llm.Provider.id p
        | None -> "the provider"
      in
      match Spice_llm.Error.kind provider_error with
      | Spice_llm.Error.Transport -> "couldn't reach " ^ provider
      | Spice_llm.Error.Timeout -> "the request to " ^ provider ^ " timed out"
      | Spice_llm.Error.Auth ->
          "authentication failed for " ^ provider
          ^ " — check the provider login or credential"
      | Spice_llm.Error.Rate_limited ->
          provider ^ " rate-limited the request — retry shortly"
      | Spice_llm.Error.Quota -> provider ^ " quota exceeded"
      | Spice_llm.Error.Context_overflow ->
          "the conversation is too long for the model — run /compact"
      | Spice_llm.Error.Cancelled | Spice_llm.Error.Invalid_request
      | Spice_llm.Error.Unsupported | Spice_llm.Error.Content_policy
      | Spice_llm.Error.Decode | Spice_llm.Error.Malformed_stream
      | Spice_llm.Error.Provider | Spice_llm.Error.Other _ ->
          Spice_protocol.Error.message error)
  | _ -> Spice_protocol.Error.message error

(* Execution failures never ride the event stream (live.mli): a settled drain
   reports Finished, a blocked one Waiting, and a transport failure the error.
   The shell renders each — nothing to append on Finished, the static waiting
   line on Waiting, a failure notice on the error. *)
let settled_of_result = function
  | Ok (_, Spice_protocol.Outcome.Finished _) -> App.Finished
  | Ok (_, (Spice_protocol.Outcome.Waiting _ as outcome)) ->
      (* Forward the typed pending boundary so the shell opens the matching
         dialog; [None] for a wait with no user-facing form. *)
      App.Waiting (Spice_protocol.Pending.of_outcome outcome)
  | Error error ->
      App.Failed { message = failure_message error; login_needed = false }

(* The one missing-credential failure whose repair is a login. The binding and
   attachment pipelines compose over string errors, so the class rides the
   message itself: [failed_settle] recognizes this exact string and marks the
   settle, and the shell opens the login flow on it (09-auth §9). *)
let not_logged_in_message = "not logged in — run /login to connect a provider"

let failed_settle message =
  App.Failed
    { message; login_needed = String.equal message not_logged_in_message }

(* {2 Auth ("09-auth.md")}

   The passive provider facts the login / logout pickers render, and the
   display-safe settled records the shell appends. All host reads; the login
   engine ([Spice_host_builtin.Login]) is driven from the run loop's command
   handlers. *)

let provider_display decl =
  match Spice_provider.display_name decl with
  | Some name -> name
  | None -> model_provider_title (Spice_provider.id decl)

let load_auth_providers ~stdenv host =
  match Spice_host.Account.load ~stdenv host with
  | Error error -> Error (Spice_host.Account.Error.message error)
  | Ok accounts ->
      Ok
        (List.map
           (fun decl ->
             let provider = Spice_provider.id decl in
             let auth = Spice_provider.auth decl in
             let phase, source, fingerprint =
               match Spice_host.Account.status accounts provider with
               | Ok account ->
                   ( Spice_account.phase account,
                     Spice_account.source account,
                     Spice_account.fingerprint account )
               | Error _ -> (`Missing, None, None)
             in
             {
               Auth_panel.provider;
               display_name = provider_display decl;
               logins = Spice_provider.Auth.logins auth;
               env =
                 List.map Spice_provider.Auth.Env.name
                   (Spice_provider.Auth.env auth);
               phase;
               source;
               fingerprint;
             })
           (Spice_host.Host.providers host))

let auth_source_word = function
  | Some (Spice_account.Credential.Source.Store _) -> Some "store"
  | Some (Spice_account.Credential.Source.Env name) -> Some ("env " ^ name)
  | Some Spice_account.Credential.Source.Process -> Some "process"
  | None -> None

(* Reduce a settled login to the display-safe record the shell renders. A
   [Checked] account whose phase is [`Blocked] saved but was rejected;
   [Cancelled] is defensive — the command handler drops it before this. *)
let auth_record_of_settled ~provider ~title
    (settled : Spice_host_builtin.Login.settled) : Auth_panel.record =
  match settled with
  | Spice_host_builtin.Login.Checked account ->
      let outcome =
        match Spice_account.phase account with
        | `Blocked -> Auth_panel.Saved_blocked
        | `Missing | `Unchecked | `Ready | `Degraded -> Auth_panel.Signed_in
      in
      {
        Auth_panel.provider_id = Spice_llm.Provider.id provider;
        provider_title = title;
        outcome;
        acct_fingerprint = Spice_account.fingerprint account;
        source_word = auth_source_word (Spice_account.source account);
      }
  | Spice_host_builtin.Login.Unchecked { account; reason } ->
      {
        Auth_panel.provider_id = Spice_llm.Provider.id provider;
        provider_title = title;
        outcome = Auth_panel.Saved_unchecked reason;
        acct_fingerprint = Option.bind account Spice_account.fingerprint;
        source_word =
          Option.bind account (fun a ->
              auth_source_word (Spice_account.source a));
      }
  | Spice_host_builtin.Login.Failed message ->
      {
        Auth_panel.provider_id = Spice_llm.Provider.id provider;
        provider_title = title;
        outcome = Auth_panel.Failed message;
        acct_fingerprint = None;
        source_word = None;
      }
  | Spice_host_builtin.Login.Cancelled ->
      {
        Auth_panel.provider_id = Spice_llm.Provider.id provider;
        provider_title = title;
        outcome = Auth_panel.Failed "sign-in cancelled";
        acct_fingerprint = None;
        source_word = None;
      }

let auth_record_of_logout ~provider ~title
    (result : (Spice_host_builtin.Login.logout, string) result) :
    Auth_panel.record =
  let base outcome =
    {
      Auth_panel.provider_id = Spice_llm.Provider.id provider;
      provider_title = title;
      outcome;
      acct_fingerprint = None;
      source_word = None;
    }
  in
  match result with
  | Ok { Spice_host_builtin.Login.env_still_active = Some var } ->
      base (Auth_panel.Env_active var)
  | Ok { Spice_host_builtin.Login.env_still_active = None } ->
      base Auth_panel.Removed
  | Error message -> base (Auth_panel.Failed message)

let run_loaded ~stdenv ~(startup : App.startup) ?clock ?matrix ?probe host =
  Eio.Switch.run ~name:"spice-tui" @@ fun sw ->
        let clock =
          match clock with
          | Some clock -> clock
          | None -> Eio.Stdenv.clock stdenv
        in
        let cwd = Spice_host.Config.cwd (Spice_host.Host.config host) in
        let trusted =
          Spice_host.Config.workspace_trust (Spice_host.Host.config host)
          |> Spice_host.Trust.is_trusted
        in
        let sandbox_flag = startup.App.sandbox in
        let workspace =
          Spice_workspace.single (Spice_workspace.Root.make cwd)
        in
        let effective_sandbox =
          match
            resolve_sandbox ?flag:sandbox_flag ~sw ~stdenv host ~workspace
          with
          | Ok sandbox -> sandbox
          | Error error ->
              failwith (Spice_host.Sandbox.Resolve_error.message error)
        in
        let git_run =
          if trusted then
            git_runner ~stdenv
              ~sandbox:(Spice_host.Sandbox.Effective.sandbox effective_sandbox)
          else restricted_git_runner
        in
        let snapshot = build_snapshot ?sandbox_flag ~stdenv host in
        let load_brief =
          make_brief_loader ?sandbox_flag ~git_run ~trusted ~stdenv ~clock
            ~host ~cwd ()
        in
        let load_health =
          make_health_loader ~trusted ~host ~stdenv ~clock ~cwd
        in
        (* [start_idle]: the render cadence runs only while something animates
           (mosaic requests it for tick subscriptions). Without it the loop is
           [`Explicit_started] — permanently live — and re-renders the whole
           mounted transcript at 30fps forever, CPU proportional to session
           length even when nothing on screen changes. *)
        let matrix =
          match matrix with
          | Some matrix -> matrix
          | None ->
              Matrix_eio.create ~mode:`Alt ~sw ~clock ~stdin:stdenv#stdin
                ~stdout:stdenv#stdout ~target_fps:(Some 30.)
                ~cursor_visible:true ~mouse_enabled:true ~exit_on_ctrl_c:false
                ~start_idle:true ()
        in
        let process_perform thunk =
          Eio.Fiber.fork_daemon ~sw (fun () ->
              (try thunk () with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                  (* A background effect fault must not fail the shared switch
                     and tear the whole session down. Log it — printing to the
                     UI-owned terminal would corrupt the screen — and drop this
                     effect; the session stays up. *)
                  let backtrace = Printexc.get_raw_backtrace () in
                  Log.err (fun m ->
                      m "background effect raised, dropped: %s@.%s"
                        (Printexc.to_string exn)
                        (Printexc.raw_backtrace_to_string backtrace)));
              `Stop_daemon)
        in
        (* The stable Mosaic dispatch, captured by every perform (the closure
           Mosaic hands a perform is stable for the app's lifetime, so
           re-capturing is idempotent). {!Spice_host.Live}'s event and settle
           subscriptions fire on the drain fiber, off the Mosaic loop, and reach
           the shell only through it. *)
        let dispatch_ref = ref None in
        (* Mosaic dispatch first enqueues the message, then requests a redraw.
           Both operations are non-suspending; the Eio and test backends wake
           by broadcasting a condition. Thus a present dispatch has no
           recoverable failure after admission. Teardown clears the ref before
           closing owners, when there is no interactive app left to settle. *)
        let deliver msg =
          match !dispatch_ref with Some dispatch -> dispatch msg | None -> ()
        in
        let perform f =
          Mosaic.Cmd.perform (fun dispatch ->
              dispatch_ref := Some dispatch;
              f ())
        in
        (* The mode the next runner is built with and each turn declares
           (10-commands.md §Mode switches: /plan and /build set the next-turn
           contract). Read on the perform fibers between scheduler yields, like
           the other runtime refs. *)
        let current_mode = ref startup.App.mode in
        (* The cancel flag the one in-flight user shell polls; the shell
           surface admits a single command at a time (app.ml). *)
        let shell_cancelled = ref false in
        (* Auth flow cancellation (09-auth.md): request id -> the resolver of the
           promise the login engine races with [Eio.Fiber.first] (login.ml).
           Resolving it preempts the 300 s browser-callback await and the
           device-poll sleeps at once — an Eio promise, never a
           [run_in_systhread] wait (uncancellable; project memory
           eio-systhread-teardown). Touched only between scheduler yields on the
           single UI domain, so it needs no synchronization. *)
        let auth_cancels : (int, unit Eio.Promise.u) Hashtbl.t =
          Hashtbl.create 4
        in
        let register_auth_cancel request =
          let promise, resolver = Eio.Promise.create () in
          Hashtbl.replace auth_cancels request resolver;
          promise
        in
        let resolve_auth_cancel request =
          match Hashtbl.find_opt auth_cancels request with
          | Some resolver ->
              Hashtbl.remove auth_cancels request;
              Eio.Promise.resolve resolver ()
          | None -> ()
        in
        (* Prompt history needs a session attribution before the first turn has
           created a document. The id is inert: only [attach_fresh], running
           under [Start_turn], may assemble a run or persist the session. *)
        let fresh_session =
          ref (Spice_host.Session.fresh_session_id ~clock)
        in
        (* The session's model selection. [None] derives the model from config
           and account connectivity at each binding, so a /login flips the
           derived default by the next turn; a /model pick pins the pair for
           this session (and persists as the default future sessions seed
           from). Touched only between scheduler yields on the UI domain. *)
        let current_selection :
            (Spice_provider.Model.t
            * Spice_llm.Request.Options.Reasoning_effort.t option)
            option
            ref =
          ref None
        in
        (* Bind one turn contract over an assembled run: resolve the session's
           model, build the credentialed client from the CURRENT credential
           store (Spice_host.client reloads it, so a login applies at the next
           binding), and derive the interpreter. Cheap and per-turn by design
           (run.mli). A missing credential on a derived choice means no
           provider is connected at all — a connected one would have won the
           derivation — so it reports the login nudge, not a provider name the
           user never chose. *)
        let bind_model_client () =
          let* model, effort =
            match !current_selection with
            | Some (model, effort) -> Ok (model, effort)
            | None ->
                Spice_host.Models.choose
                  ~connected:(Spice_host.Account.connectivity ~stdenv host)
                  host Model_choice.Main
                |> Result.map (fun choice -> (Model_choice.model choice, None))
                |> Result.map_error host_error
          in
          let* client =
            match Spice_host.client ~sw ~stdenv host model with
            | Error (Spice_host.Host.Error.Missing_credential _)
              when Option.is_none !current_selection ->
                Error not_logged_in_message
            | result -> Result.map_error host_error result
          in
          Ok (model, effort, client)
        in
        let bind_runner run =
          let* model, effort, client = bind_model_client () in
          let* runner =
            Spice_host.Run.runner run ~mode:!current_mode ~model ~client
            |> Result.map_error host_error
          in
          Ok (runner, model, effort)
        in
        (* Push the rebuilt slow facts to the shell after an action that can
           move them — a model pick, a credential-store mutation, a turn
           binding — so the rendered model line tracks what the next turn's
           binding will use. The facts come from the same hierarchy the
           binding reads: the session pin first (the loaded host's in-memory
           config predates the pick's file write, so re-deriving would miss
           it), else a re-derivation over config and the freshly re-read
           credential store. The shell drops no-op pushes. *)
        let refresh_snapshot () =
          let snapshot =
            match !current_selection with
            | Some (model, effort) ->
                let config = Spice_host.Host.config host in
                let effort =
                  match effort with
                  | Some _ -> effort
                  | None -> turn_reasoning config model
                in
                {
                  snapshot with
                  Snapshot.model = model_label model;
                  effort =
                    Option.map
                      Spice_llm.Request.Options.Reasoning_effort.to_string
                      effort;
                  context_window = Spice_provider.Model.context_window model;
                }
            | None -> build_snapshot ?sandbox_flag ~stdenv host
          in
          deliver (App.snapshot_refreshed snapshot)
        in
        (* The session's live attachment, created by the first turn. Held as
           [(live, run)]: the run is the workspace assembly each turn's
           contract binds over. Resume onto an existing session is a later
           iteration, so exactly one session is ever attached. *)
        let attachment = ref None in
        let created_session = ref None in
        let main_pending = ref false in
        (* A terminal event is durable progress, not command completion. Keep
           the main check pending until Live publishes the matching settlement;
           otherwise a test can declare quiescence inside the post-commit
           interval where the result owner is still blocked. Child work remains
           visible independently through [spice.jobs] below. *)
        (* A resume/fork in flight, armed SYNCHRONOUSLY in the command
           interpreter (before its perform fork) and resolved once the document
           is loaded (or forked). While set, [ensure_attachment] awaits it and
           attaches to that document instead of minting a fresh session — the
           replay already ran through [App.live_event], and the
           {!Spice_host.Live} attachment is deferred to the first continuation
           exactly as the fresh path defers its [Session.create], so resume needs
           no client until the user speaks. Arming before the fork is what closes
           the race with a fast first submit: a submit that lands while the
           document still loads awaits this rather than minting (and orphaning) a
           fresh session. Single-owner clearing: producers ([resume_into]) never
           clear this; only the consumer ([ensure_attachment]) does, and only the
           handle it actually consumes, so a stale producer cannot wipe a newer
           resume armed over it. *)
        let resume_pending :
            (Spice_session_store.Document.t, string) result Eio.Promise.t option
            ref =
          ref None
        in
        let close_run run =
          match Spice_host.Run.close run with
          | Ok () -> ()
          | Error error ->
              Log.err (fun m ->
                  m "run close failed: %s"
                    (Spice_host.Jobs.Close_error.message error))
        in
        (* A newly assembled run stays owned by the current [Start_turn] until
           [f] returns [Ok] after installing it in [attachment]. Structured
           failures close it before returning; cancellation and unexpected
           exceptions close it under protection, then keep their original
           identity and backtrace. *)
        let with_owned_run run f =
          match f () with
          | Ok _ as result -> result
          | Error _ as result ->
              close_run run;
              result
          | exception exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              Eio.Cancel.protect (fun () -> close_run run);
              Printexc.raise_with_backtrace exn backtrace
        in
        let submit live command =
          main_pending := true;
          Spice_host.Live.submit live command
        in
        let close_attachment () =
          (match !attachment with
          | None -> ()
          | Some (live, run) ->
              attachment := None;
              Fun.protect
                ~finally:(fun () -> close_run run)
                (fun () -> Spice_host.Live.close live));
          main_pending := false
        in
        let subscribe live =
          Spice_host.Live.events live (fun event ->
              deliver (App.live_event ~now:(Eio.Time.now clock) event));
          Spice_host.Live.on_settled live (fun result ->
              main_pending := false;
              deliver
                (App.settled ~now:(Eio.Time.now clock)
                   (settled_of_result result)))
        in
        (* The subagent-thread adapter (doc/plans/tui-next-threads.md §1, §4.5):
           the attached run's {!Spice_host.Jobs} registry fans identity-tagged
           lifecycle events to the shell. Callbacks fire on child drain fibers,
           the same domain as [Live.events] above, so [deliver] is safe here.
           This iteration forwards only the lifecycle the footer count and the
           parent transcript render — mint, ask relay, settlement; the progress
           ticker, permission escalation, and resume land with their surfaces.

           One subscription per run, and a run belongs to exactly one registry
           (the one whose spawn handler minted it). Session replacement closes
           that registry before subscribing the replacement, so old children
           cannot deliver into the new session. *)
        let subscribe_jobs jobs =
          let wake =
            Spice_host.Config.Runtime.subagent_wake
              (Spice_host.Config.runtime (Spice_host.Host.config host))
          in
          Spice_host.Jobs.subscribe jobs (fun event ->
              let now () = Eio.Time.now clock in
              match event with
              | Spice_host.Jobs.Started run -> deliver (App.thread_started run)
              | Spice_host.Jobs.Settled run ->
                  deliver (App.thread_settled ~now:(now ()) ~wake run)
              | Spice_host.Jobs.Asked { run; message } ->
                  deliver (App.thread_asked ~now:(now ()) ~message run)
              | Spice_host.Jobs.Progress _ | Spice_host.Jobs.Blocked _
              | Spice_host.Jobs.Resumed _ ->
                  ())
        in
        (* The first [Start_turn] owns the whole fresh path: assemble the run,
           bind its turn contract, persist the document, and transfer both run
           and live attachment together. Nothing is started speculatively at
           TUI launch, and every failure before transfer closes the run. *)
        let attach_fresh () =
          let session_id = !fresh_session in
          match build_run ?sandbox_flag ~sw ~stdenv ~host ~session_id () with
          | Error _ as error -> error
          | Ok run ->
              with_owned_run run (fun () ->
                  let* runner, _model, _effort = bind_runner run in
                  let store = Spice_host.Session.store ~stdenv host in
                  let created_at =
                    Spice_session.Time.of_unix_seconds_float
                      (Eio.Time.now clock)
                  in
                  let* document =
                    Spice_host.Session.create ~store ~id:session_id ~cwd
                      ~created_at ()
                    |> Result.map_error Spice_protocol.Error.message
                  in
                  let live = Spice_host.Live.attach ~sw ~runner document in
                  (* These subscriptions do not suspend and only reject owners
                     already closing. Both values are fresh, so no close or
                     cancellation can interleave before ownership transfers to
                     [attachment]. *)
                  subscribe live;
                  subscribe_jobs (Spice_host.Run.jobs run);
                  attachment := Some (live, run);
                  created_session := Some session_id;
                  Ok (live, run))
        in
        (* Attach the resumed session behind [pending] (armed before its perform
           fork), replaying under a run built for its own id. A resume superseded
           while we awaited — a newer pick armed over it — is not ours to consume:
           re-read [resume_pending] and await the current one, so the turn
           attaches to the session actually resumed, not a stale pick. Only the
           consumer clears [resume_pending], and only the handle it actually
           consumes, so a superseded producer never wipes the newer pending. A
           resume that failed to load resolves [Error]; the producer has already
           surfaced that failure as a settled notice ([resume_into]), so the
           consumer only recovers — it neither re-reports the failure nor eats
           this submit. Recovery keeps a session already attached (a failed
           mid-chat resume stays on the current chat) and mints fresh only when
           none is (a failed launch resume): [attach_fresh] builds only when the
           pending first turn needs a fresh attachment. *)
        let rec consume_resume pending =
          let result = Eio.Promise.await pending in
          match !resume_pending with
          | Some current when current != pending -> consume_resume current
          | None -> (
              (* Another consumer already cleared [resume_pending] and is mid
                 attach: reuse its attachment once it lands, else mint fresh.
                 Reachable only with two concurrent [Start_turn] consumers, which
                 the shell's single-in-flight-turn invariant forbids today (app.ml
                 [start_turn]: a submit while a turn is in flight queues rather
                 than dispatching a second [Start_turn]) — this rides on that
                 invariant. Without the [attachment] check a second consumer would
                 mint a spurious fresh session over the first's. *)
              match !attachment with
              | Some att -> Ok att
              | None -> attach_fresh ())
          | Some _ -> (
              resume_pending := None;
              match result with
              | Error _ -> (
                  match !attachment with
                  | Some att -> Ok att
                  | None -> attach_fresh ())
              | Ok document ->
                  let session_id =
                    Spice_session.id
                      (Spice_session_store.Document.session document)
                  in
                  (match
                     build_run ?sandbox_flag ~sw ~stdenv ~host ~session_id ()
                  with
                  | Error _ as error -> error
                  | Ok run ->
                      with_owned_run run (fun () ->
                          let* runner, _model, _effort = bind_runner run in
                          close_attachment ();
                          let live =
                            Spice_host.Live.attach ~sw ~runner document
                          in
                          subscribe live;
                          subscribe_jobs (Spice_host.Run.jobs run);
                          attachment := Some (live, run);
                          created_session := Some session_id;
                          Ok (live, run))))
        in
        let ensure_attachment () =
          (* [resume_pending] is consulted before [attachment]: a resume armed
             while a session is still attached (a mid-chat quick-switch) has not
             yet run [enter_session], so [attachment] still holds the
             OLD session — reusing it would submit the turn to the session the
             user just navigated away from. Awaiting the pending resume attaches
             the turn to the session actually resumed. With no resume in flight
             this falls through to the attached session (the ongoing-chat fast
             path) or a fresh mint. *)
          match !resume_pending with
          | Some pending -> consume_resume pending
          | None -> (
              match !attachment with
              | Some att -> Ok att
              | None -> attach_fresh ())
        in
        (* Enter a session's transcript: replay its durable events through the
           turn reducer (turn.mli: replay lands settled through the identical
           path) so the shell rebuilds the transcript (12-home.md §The drop:
           resume skips the home). The prior attachment and its complete run
           close before replay, so no old event can reach the new session. The
           attach target is the
           [resume_pending] handle the command interpreter armed and the caller
           resolves once this returns, so [ensure_attachment] awaits it rather
           than minting a fresh session. *)
        let enter_session document =
          close_attachment ();
          let session_id =
            Spice_session.id (Spice_session_store.Document.session document)
          in
          created_session := Some session_id;
          let now = Eio.Time.now clock in
          List.iter
            (fun event -> deliver (App.live_event ~now event))
            (Spice_protocol.Event.of_session
               (Spice_session_store.Document.session document));
          (* A resumed session's child subagent runs come from the artifact
             ledger, not the (empty) live registry — the threads switcher's
             focused browse over the whole tree is their first consumer
             (doc/plans/tui-next-threads.md §6). This message also re-attributes
             the shell's attached-session id to [session_id] (app.ml
             [Thread_runs_loaded]), so it fires unconditionally: a store error
             just seeds an empty set, but the attribution must still land or the
             resumed session's LIVE spawns are gated out of the switcher. *)
          let store = Spice_host.Session.store ~stdenv host in
          let root =
            Spice_path.Abs.to_string (Spice_session_store.root store)
          in
          let runs =
            match
              Spice_host.Artifacts.Subagent_run.list ~fs:(Eio.Stdenv.fs stdenv)
                ~root ~parent:session_id
            with
            | Ok runs -> runs
            | Error _ -> []
          in
          deliver (App.thread_runs_loaded ~session:session_id runs)
        in
        let store_session id =
          let store = Spice_host.Session.store ~stdenv host in
          Spice_host.Session.load store id
        in
        (* Arm a pending resume/fork synchronously — [resume_pending] is set when
           this runs, i.e. when the command interpreter builds the command's
           [Cmd], before the perform fork — then load (or fork) the document and
           enter its transcript on the perform fiber, resolving the handle so an
           [ensure_attachment] racing the load awaits the resumed document instead
           of minting a fresh session. A load failure resolves [Error] and
           surfaces the failure as a settled notice; the consumer clears the
           handle when it awaits that [Error], so a later submit falls back to a
           fresh session. *)
        let resume_into load =
          let pending, resolve = Eio.Promise.create () in
          resume_pending := Some pending;
          perform (fun () ->
              (* Supersession guard: a newer resume can arm over this one before
                 this perform runs, or during [load] (which yields on the store
                 read), so check currency at both points. Only the pending still
                 current owns the transcript replay and the failure notice; a
                 superseded one still RESOLVES its promise — so an
                 [ensure_attachment] already awaiting it unblocks and re-reads the
                 current pending — but neither replays nor surfaces. The [Error]
                 sentinel a superseded resolve carries is inert: the consumer
                 detects supersession by identity and never surfaces that value.
                 The producer never clears [resume_pending]; the consumer clears
                 the one it actually consumes, so a superseded producer cannot
                 wipe the newer pending. *)
              let is_current () =
                match !resume_pending with
                | Some p -> p == pending
                | None -> false
              in
              if not (is_current ()) then
                Eio.Promise.resolve resolve (Error "resume superseded")
              else
                let result = load () in
                if not (is_current ()) then
                  Eio.Promise.resolve resolve (Error "resume superseded")
                else
                  match result with
                  | Ok document ->
                      enter_session document;
                      Eio.Promise.resolve resolve (Ok document)
                  | Error message ->
                      Eio.Promise.resolve resolve (Error message);
                      deliver
                        (App.settled ~now:(Eio.Time.now clock)
                           (failed_settle message)))
        in
        (* The live attachment for [id], when [id] is the currently attached
           session — so a rename or delete of the active session serializes with
           its drain ({!Spice_host.Live.write}); any other session writes
           directly. *)
        let live_for id =
          match (!attachment, !created_session) with
          | Some (live, _), Some current when Spice_session.Id.equal id current
            ->
              Some live
          | _ -> None
        in
        (* Reload the browse screen's rows after a mutation (rename, delete) so
           the screen reflects the new store state. *)
        let reload_screen () =
          let store = Spice_host.Session.store ~stdenv host in
          match load_screen_sessions ~stdenv ~clock ~store ~cwd with
          | Ok rows -> deliver (App.screen_loaded rows)
          | Error message -> deliver (App.screen_failed message)
        in
        (* Assemble the settings screen's facts, reloading the host so a
           just-persisted config or skills write is visible (Settings_facts is
           pure over the reloaded snapshot). The active session, when set, feeds
           the usage tab and the copyable status id. *)
        let assemble_settings () =
          match load_host ~stdenv startup with
          | Error message -> deliver (App.settings_load_failed message)
          | Ok fresh ->
              let session =
                match !created_session with
                | Some id -> (
                    match store_session id with
                    | Ok document ->
                        Some (Spice_session_store.Document.session document)
                    | Error _ -> None)
                | None -> None
              in
              deliver
                (App.settings_loaded
                   (Settings_facts.assemble ~stdenv ~host:fresh ~session))
        in
        (* Persist one config field to the user config file, then re-assemble. An
           unparseable field name or a write error leaves the on-disk config
           unchanged; the re-assembly still reflects reality. *)
        let write_config field value =
          (match Spice_host.Config.Field.of_string field with
          | Error _ -> ()
          | Ok (Spice_host.Config.Field.Any f) ->
              let files =
                Spice_host.Config.files (Spice_host.Host.config host)
              in
              let (_ : (unit, Spice_host.Config.Error.t) result) =
                Spice_host.Config.Config_file.edit ~stdenv files
                  Spice_host.Config.Config_file.User
                  ~f:(Spice_host.Config.Config_file.set f value)
              in
              ());
          assemble_settings ()
        in
        (* Flip a skill's membership in [skills.disabled]. The current list is
           read from a fresh host so repeated toggles compose against the
           on-disk value, not the stale launch snapshot. *)
        let toggle_skill name =
          (match load_host ~stdenv startup with
          | Error _ -> ()
          | Ok fresh ->
              let config = Spice_host.Host.config fresh in
              let disabled =
                Spice_host.Config.Skills.disabled
                  (Spice_host.Config.skills config)
              in
              let disabled =
                if List.mem name disabled then
                  List.filter (fun n -> not (String.equal n name)) disabled
                else disabled @ [ name ]
              in
              let json =
                "["
                ^ String.concat "," (List.map (Printf.sprintf "%S") disabled)
                ^ "]"
              in
              let (_ : (unit, Spice_host.Config.Error.t) result) =
                Spice_host.Config.Config_file.edit ~stdenv
                  (Spice_host.Config.files config)
                  Spice_host.Config.Config_file.User
                  ~f:
                    (Spice_host.Config.Config_file.set
                       Spice_host.Config.Field.skills_disabled (Some json))
              in
              ());
          assemble_settings ()
        in
        (* The model panel reads the launch host — no write happens while it is
           open (a pick closes it first), so no reload is needed. *)
        let assemble_model_facts () =
          deliver
            (App.model_facts_loaded
               (load_model_facts
                  ?selected:(Option.map fst !current_selection)
                  ~stdenv ~host ()))
        in
        (* Pin a model pick as the session selection, persist it as the
           default future sessions seed from, and report the outcome as the
           panel's confirmation flash: the model and effort on success, the
           host error on a rejected selector. The next turn's binding reads
           the pin, so "effective next turn" is literal. *)
        let switch_model selector effort =
          match save_model_selection ~stdenv host ~selector ~effort with
          | Ok model ->
              current_selection := Some (model, effort);
              refresh_snapshot ();
              let effort_label =
                match effort with
                | Some e ->
                    Spice_llm.Request.Options.Reasoning_effort.to_string e
                    ^ " effort"
                | None -> "default effort"
              in
              deliver
                (App.model_switched
                   (Printf.sprintf "model set to %s · %s — effective next turn"
                      (model_label model) effort_label))
          | Error message -> deliver (App.model_switched message)
        in
        (* Single-flight the brief tick: the 2s tick is unconditional, so a
           load that outruns its interval would otherwise let the next tick
           fork a second loader that races the first over the non-reentrant
           glance handle and shared Dune RPC instance. A tick that arrives
           while a load is in flight is dropped, not queued. The flag lives on
           the single UI domain and is only touched between scheduler yields,
           so the check-and-set needs no synchronization. *)
        let brief_in_flight = ref false in
        let health_in_flight = ref false in
        (* Review screen (doc/plans/tui-next-review.md Appendix A): the review
           sub-library owns its whole async protocol; the runtime interprets each
           effect over Spice_review_git and a dedicated worktree watch,
           dispatching completions back as [App.review_msg]. The repo handle and
           the watcher stop-fn are cached across effects — the open review's root
           is fixed, so reload and mutate reuse the discovered handle. *)
        let review_repo_ref = ref None in
        let review_watch_ref = ref None in
        let review_repo ~root =
          match !review_repo_ref with
          | Some repo when String.equal (Spice_review_git.root repo) root ->
              Ok repo
          | _ -> (
              let fs = Eio.Stdenv.fs stdenv in
              match Spice_review_git.discover ~run:git_run ~fs ~cwd:root with
              | Error _ as error -> error
              | Ok repo ->
                  review_repo_ref := Some repo;
                  Ok repo)
        in
        let review_store_dir root =
          let config = Spice_host.Host.config host in
          let data_root =
            Spice_host.Config.data_home config |> Spice_path.Abs.to_string
          in
          Spice_host.Workspace_state.ensure ~fs:(Eio.Stdenv.fs stdenv)
            ~data_root ~root
          |> Result.map Spice_host.Workspace_state.reviews_dir
        in
        let open_review_snapshot base_spec =
          let fs = Eio.Stdenv.fs stdenv in
          (* Discover at the workspace root the rest of the runtime uses (the home
             brief's [discover_repo] does the same), not [Sys.getcwd ()] — under
             [--cwd] the process directory need not be the workspace. *)
          let cwd =
            match startup.App.cwd with
            | Some abs -> Spice_path.Abs.to_string abs
            | None -> Sys.getcwd ()
          in
          match Spice_review_git.discover ~run:git_run ~fs ~cwd with
          | Error error -> Error (Spice_review_git.Error.message error)
          | Ok repo -> (
              review_repo_ref := Some repo;
              let spec = Option.value base_spec ~default:"HEAD" in
              match Spice_review_git.resolve_base repo spec with
              | Error error -> Error (Spice_review_git.Error.message error)
              | Ok base -> (
                  match Spice_review_git.load repo ~base with
                  | Error error -> Error (Spice_review_git.Error.message error)
                  | Ok load ->
                      let root = Spice_review_git.root repo in
                      let key = Spice_review_git.Records.key ~base in
                      let* dir = review_store_dir root in
                      Ok
                        (Spice_tui_review.snapshot ~root ~base
                           ~range:(spec ^ "..worktree") ~store_key:key
                           ~resolver:
                             (Spice_cr.Handle.to_string
                                (Spice_review_git.user_handle repo))
                           ~feature:load.Spice_review.Live.feature
                           ~crs:load.Spice_review.Live.crs
                           ~fingerprint:load.Spice_review.Live.fingerprint
                           ?persisted:
                             (Spice_review_git.Records.load ~fs ~dir ~key)
                           ())))
        in
        let review_reload ~root ~base ~known =
          match review_repo ~root with
          | Error error -> Error (Spice_review_git.Error.message error)
          | Ok repo -> (
              match Spice_review_git.load_if_changed repo ~base ~known with
              | Error error -> Error (Spice_review_git.Error.message error)
              | Ok result -> Ok result)
        in
        let apply_review_cr_op ~root ~base ~expected op =
          match review_repo ~root with
          | Error error -> Error (Spice_review_git.Error.message error)
          | Ok repo -> (
              match Spice_review_git.apply_op repo ~base ~expected op with
              | Ok load -> Ok load
              | Error Spice_review_git.Stale_worktree ->
                  Error
                    "the worktree changed under the review; retry after it \
                     refreshes"
              | Error (Spice_review_git.Apply_failed message) -> Error message)
        in
        let stop_review_watch () =
          review_repo_ref := None;
          match !review_watch_ref with
          | None -> ()
          | Some stop ->
              review_watch_ref := None;
              stop ()
        in
        (* The review screen's dedicated worktree watcher (not the host notice
           watcher: review works without a session attachment, and its refresh
           path is the Live protocol, not the agent inbox). *)
        let start_review_watch ~root =
          stop_review_watch ();
          let stop =
            Spice_fswatch.watch ~sw ~clock ~ignore:Spice_host.default_ignore
              ~root
              ~f:(fun _events ->
                deliver
                  (App.review_msg
                     (Spice_tui_review.fs_changed ~now:(Eio.Time.now clock))))
              ~on_error:(fun error ->
                deliver
                  (App.review_msg
                     (Spice_tui_review.watch_failed
                        (Format.asprintf "%a" Spice_fswatch.Error.pp error))))
              ()
          in
          review_watch_ref := Some stop
        in
        (* The browser and device OAuth flows differ only in which
           [Spice_host_builtin.Login] driver runs; [drive] is the chosen driver
           already applied up to its [~cancel] and events, so the two arms share
           one events closure and one settle path and cannot drift. *)
        let run_login ~request ~provider drive =
          perform (fun () ->
              let cancel = register_auth_cancel request in
              let events = function
                | Spice_host_builtin.Login.Browser_url url ->
                    deliver
                      (App.auth_challenge ~request (Auth_panel.Browser_url url))
                | Spice_host_builtin.Login.Listening _ ->
                    (* tui-next never auto-opens (09-auth §6); the panel's
                       explicit enter drives [Auth_open_url]. *)
                    ()
                | Spice_host_builtin.Login.Device_challenge
                    { url; user_code; expires_in } ->
                    deliver
                      (App.auth_challenge ~request
                         (Auth_panel.Device_challenge
                            { url; user_code; expires_in }))
              in
              let settled = drive ~cancel events in
              Hashtbl.remove auth_cancels request;
              match settled with
              | Spice_host_builtin.Login.Cancelled -> ()
              | settled ->
                  (* A saved credential (checked or not) can flip the derived
                     default model; a failed login saved nothing. *)
                  (match settled with
                  | Spice_host_builtin.Login.Checked _
                  | Spice_host_builtin.Login.Unchecked _ ->
                      refresh_snapshot ()
                  | Spice_host_builtin.Login.Failed _
                  | Spice_host_builtin.Login.Cancelled ->
                      ());
                  deliver
                    (App.auth_settled ~request
                       (auth_record_of_settled ~provider
                          ~title:(model_provider_title provider)
                          settled)))
        in
        let start_turn ?origin input =
          perform (fun () ->
              try
                match ensure_attachment () with
                | Error message ->
                    deliver
                      (App.settled ~now:(Eio.Time.now clock)
                         (failed_settle message))
                | Ok (live, run) -> (
                    (* Every turn re-binds its contract — selection, fresh
                       credential store, current mode — and swaps the runner
                       before submitting, so a /login or /model between turns
                       takes effect on this very turn. *)
                    match bind_runner run with
                    | Error message ->
                        deliver
                          (App.settled ~now:(Eio.Time.now clock)
                             (failed_settle message))
                    | Ok (runner, model, effort) ->
                        Spice_host.Live.set_runner live runner;
                        refresh_snapshot ();
                        let turn =
                          make_turn ?origin ~clock
                            ~config:(Spice_host.Host.config host)
                            ~model ~effort input
                        in
                        submit live (Spice_protocol.Command.Start turn))
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn ->
                  let backtrace = Printexc.get_raw_backtrace () in
                  Log.err (fun m ->
                      m "turn setup raised: %s@.%s" (Printexc.to_string exn)
                        (Printexc.raw_backtrace_to_string backtrace));
                  let error =
                    Spice_protocol.Error.Internal
                      ("couldn't start the turn: " ^ Printexc.to_string exn)
                  in
                  deliver
                    (App.settled ~now:(Eio.Time.now clock)
                       (settled_of_result (Error error))))
        in
        let command = function
          | App.Quit -> Mosaic.Cmd.quit
          | App.Reload_brief ->
              perform (fun () ->
                  if !brief_in_flight then ()
                  else begin
                    brief_in_flight := true;
                    Fun.protect
                      ~finally:(fun () -> brief_in_flight := false)
                      (fun () -> deliver (App.brief_loaded (load_brief ())))
                  end)
          | App.Reload_health ->
              perform (fun () ->
                  if !health_in_flight then ()
                  else begin
                    health_in_flight := true;
                    Fun.protect
                      ~finally:(fun () -> health_in_flight := false)
                      (fun () ->
                        let health, file = load_health () in
                        deliver
                          (App.health_loaded ~now:(Eio.Time.now clock) ~file
                             health))
                  end)
          | App.Start_turn prompt ->
              start_turn (Spice_session.Turn.Input.user_text prompt)
          | App.Start_subagent_wake ->
              start_turn ~origin:"subagent-wake"
                Spice_session.Turn.Input.continue
          | App.Interrupt ->
              perform (fun () ->
                  match !attachment with
                  | Some (live, _) ->
                      submit live
                        (Spice_protocol.Command.Interrupt { reason = None })
                  | None -> ())
          (* Decision-dialog continuations: submit the typed command to the
             attached session exactly as a turn start does. The parked turn
             resumes when the reply drains. *)
          | App.Reply_permission { permission; answer; message } ->
              perform (fun () ->
                  match !attachment with
                  | Some (live, _) ->
                      submit live
                        (Spice_protocol.Command.Reply
                           { permission; answer; via = None; message })
                  | None -> ())
          | App.Answer_tool { turn; call_id; answer } ->
              perform (fun () ->
                  match !attachment with
                  | Some (live, _) ->
                      submit live
                        (Spice_protocol.Command.Answer { turn; call_id; answer })
                  | None -> ())
          | App.Resolve_plan { turn; call_id; decision } ->
              perform (fun () ->
                  match !attachment with
                  | Some (live, _) ->
                      submit live
                        (Spice_protocol.Command.Resolve_plan
                           { turn; call_id; decision })
                  | None -> ())
          | App.Interrupt_force ->
              (* Out of band, not a queued command: hard-cancel the in-flight
                 step so a lagging cooperative interrupt settles promptly. *)
              perform (fun () ->
                  match !attachment with
                  | Some (live, _) -> Spice_host.Live.force_interrupt live
                  | None -> ())
          | App.Load_sessions ->
              perform (fun () ->
                  let store = Spice_host.Session.store ~stdenv host in
                  match
                    load_recent_sessions ~stdenv ~clock ~store ~cwd ~limit:4
                  with
                  | Ok rows -> deliver (App.sessions_loaded rows)
                  | Error message -> deliver (App.sessions_load_failed message))
          | App.Load_screen_sessions -> perform (fun () -> reload_screen ())
          | App.Resume_session id ->
              resume_into (fun () ->
                  store_session id |> Result.map_error failure_message)
          | App.Compact_session id ->
              perform (fun () ->
                  (* The standalone host compaction (session.mli §Standalone
                     workflows), bound over the same model+client resolution a
                     turn uses and the same context prelude the headless CLI's
                     policy carries. [Live.write] serializes the install with
                     the attached session's drain; progress and the installed
                     compaction deliver as live events, so the reducer narrates
                     (the Compacting verb, then the [compacted] seam). *)
                  let result =
                    let* model, _effort, client = bind_model_client () in
                    let* context =
                      Spice_host.Context.load ~stdenv
                        (Spice_host.Host.config host)
                      |> Result.map_error host_error
                    in
                    let policy =
                      Spice_host.Compactor.Policy.of_model
                        ~prelude:(Spice_host.Context.to_prelude context)
                        model
                    in
                    let store = Spice_host.Session.store ~stdenv host in
                    Spice_host.Live.write ?live:(live_for id) ~store ~session:id
                      ~f:(fun document ->
                        Spice_host.Session.compact ~store ~client ~policy
                          ~observe:(fun event ->
                            deliver
                              (App.live_event ~now:(Eio.Time.now clock) event))
                          document
                        |> Result.map (fun result ->
                            result.Spice_host.Compactor.document))
                      ()
                    |> Result.map_error Spice_protocol.Error.message
                    |> Result.map ignore
                  in
                  match result with
                  | Ok () -> ()
                  | Error message -> deliver (App.compaction_failed message))
          | App.Clear_session ->
              perform (fun () ->
                  (* Start over: supersede any in-flight resume (its producer
                     sees a non-current pending and goes inert — the same guard
                     a newer pick relies on), close the session and its run,
                     and mint the inert id the next [Start_turn] will build. *)
                  resume_pending := None;
                  close_attachment ();
                  fresh_session :=
                    Spice_host.Session.fresh_session_id ~clock)
          | App.Fork_session id ->
              resume_into (fun () ->
                  let store = Spice_host.Session.store ~stdenv host in
                  let forked =
                    let* parent = store_session id in
                    let title =
                      Spice_session.Metadata.title
                        (Spice_session.metadata
                           (Spice_session_store.Document.session parent))
                    in
                    (* [fork] persists the child document here, inside the load,
                       before [resume_into]'s supersession check runs — so a fork
                       superseded by a racing resume leaves an unreferenced child
                       session in the store, and the lineage record below can
                       land in the superseding session's transcript. Accepted:
                       the store tolerates orphaned sessions and the window
                       needs a second pick landing during this write. *)
                    let* child =
                      Spice_host.Session.fork ~store ~clock ?title ~cwd parent
                    in
                    (* Delivered before [enter_session]'s replay events, so the
                       shell's lineage record sits under the fresh banner, above
                       the inherited history. The display title is the parent's
                       title, or its id when untitled
                       ({!Spice_protocol.Session_summary}'s convention). *)
                    let parent_title =
                      match title with
                      | Some t when String.trim t <> "" -> t
                      | Some _ | None -> Spice_session.Id.to_string id
                    in
                    deliver (App.session_forked ~parent_title);
                    Ok child
                  in
                  Result.map_error failure_message forked)
          | App.Load_thread_document run ->
              (* Read-only drill-in over a settled child (doc/plans/tui-next-threads.md
                 §6 phase 5a): load the child's persisted document and replay its
                 durable events back to the shell, folded into the drilled chat
                 exactly as a resume replays. No registry / [Jobs] involvement — a
                 settled child's document is complete and quiescent, so a plain
                 store read is race-free (the live-snapshot case is [Jobs.observe],
                 §3.2, deferred). *)
              perform (fun () ->
                  match store_session run with
                  | Ok document ->
                      let events =
                        Spice_protocol.Event.of_session
                          (Spice_session_store.Document.session document)
                      in
                      deliver
                        (App.thread_document_loaded ~run
                           ~now:(Eio.Time.now clock) events)
                  | Error error ->
                      deliver
                        (App.thread_drill_failed ~run (failure_message error)))
          | App.Rename_session { id; title } ->
              perform (fun () ->
                  let store = Spice_host.Session.store ~stdenv host in
                  let _ : (_, _) result =
                    Spice_host.Live.write ?live:(live_for id) ~store ~session:id
                      ~f:(fun document ->
                        Spice_host.Session.save_title ~store ~title document)
                      ()
                  in
                  reload_screen ())
          | App.Delete_session id ->
              perform (fun () ->
                  let store = Spice_host.Session.store ~stdenv host in
                  let _ : (_, _) result =
                    Spice_host.Live.write ?live:(live_for id) ~store ~session:id
                      ~f:(fun document ->
                        Spice_host.Session.delete ~store document)
                      ()
                  in
                  reload_screen ())
          | App.Load_model_panel -> perform (fun () -> assemble_model_facts ())
          | App.Switch_model { selector; effort } ->
              perform (fun () -> switch_model selector effort)
          | App.Load_settings -> perform (fun () -> assemble_settings ())
          | App.Write_config { field; value } ->
              perform (fun () -> write_config field value)
          | App.Toggle_skill name -> perform (fun () -> toggle_skill name)
          | App.Copy_text text -> Mosaic.Cmd.copy_to_clipboard text
          | App.Load_dir dir ->
              perform (fun () ->
                  deliver
                    (App.dir_loaded ~dir (load_mention_dir ~stdenv ~cwd dir)))
          (* History records are attributed to the active session — the resumed
             one when set, else the inert fresh id. No run is needed, so ctrl+r
             stays live from the first frame. *)
          | App.Load_prompt_history ->
              perform (fun () ->
                  let session =
                    Option.value ~default:!fresh_session !created_session
                  in
                  deliver
                    (App.prompt_history_loaded ~session
                       (load_prompt_history ~stdenv host)))
          | App.Append_prompt_history entry ->
              perform (fun () ->
                  let session =
                    Option.value ~default:!fresh_session !created_session
                  in
                  match
                    append_prompt_history ~stdenv ~clock host ~session entry
                  with
                  | Some record -> deliver (App.prompt_history_appended record)
                  | None -> ())
          | App.Set_mode mode ->
              perform (fun () ->
                  current_mode := mode;
                  (* An existing attachment's runner carries the old contract:
                     re-derive under the new mode and swap (live.mli set_runner
                     — queued commands drain with the new runner). The assembly
                     — producers, jobs registry — is mode-free and stays put; a
                     derivation failure surfaces as the failure notice, the
                     declared mode stands, and the next binding retries. *)
                  match !attachment with
                  | Some (live, run) -> (
                      match bind_runner run with
                      | Ok (runner, _model, _effort) ->
                          Spice_host.Live.set_runner live runner
                      | Error message ->
                          deliver
                            (App.settled ~now:(Eio.Time.now clock)
                               (failed_settle message)))
                  | None -> ())
          | App.Run_shell input ->
              shell_cancelled := false;
              perform (fun () ->
                  let block =
                    try
                      run_user_shell ?sandbox_flag ~stdenv ~host
                        ~cancelled:(fun () -> !shell_cancelled)
                        input
                      |> shell_block input
                    with
                    | Eio.Cancel.Cancelled _ as exn -> raise exn
                    | exn ->
                        let backtrace = Printexc.get_raw_backtrace () in
                        Log.err (fun m ->
                            m "user shell raised: %s@.%s"
                              (Printexc.to_string exn)
                              (Printexc.raw_backtrace_to_string backtrace));
                        Error
                          ("shell execution failed: " ^ Printexc.to_string exn)
                        |> shell_block input
                  in
                  deliver (App.shell_finished block))
          | App.Interrupt_shell -> perform (fun () -> shell_cancelled := true)
          (* Provider login / logout (09-auth.md). [perform] runs each thunk in a
             daemon fiber (Mosaic's ~process_perform), so the browser / device
             flows' up-to-300 s waits never block the UI; the engine's own
             [Eio.Fiber.first] races the cancel promise. *)
          | App.Load_auth_providers ->
              perform (fun () ->
                  deliver
                    (App.auth_providers_loaded
                       (load_auth_providers ~stdenv host)))
          | App.Auth_save_api_key { request; provider; method_id = _; key } ->
              perform (fun () ->
                  match Spice_auth.Secret.api_key key with
                  | Error error ->
                      deliver
                        (App.auth_settled ~request
                           {
                             Auth_panel.provider_id =
                               Spice_llm.Provider.id provider;
                             provider_title = model_provider_title provider;
                             outcome =
                               Auth_panel.Failed
                                 (Spice_auth.Error.message error);
                             acct_fingerprint = None;
                             source_word = None;
                           })
                  | Ok secret ->
                      let settled =
                        Spice_host_builtin.Login.save ~stdenv host ~provider
                          secret
                      in
                      (match settled with
                      | Spice_host_builtin.Login.Checked _
                      | Spice_host_builtin.Login.Unchecked _ ->
                          refresh_snapshot ()
                      | Spice_host_builtin.Login.Failed _
                      | Spice_host_builtin.Login.Cancelled ->
                          ());
                      deliver
                        (App.auth_settled ~request
                           (auth_record_of_settled ~provider
                              ~title:(model_provider_title provider)
                              settled)))
          | App.Auth_browser_login { request; provider; method_id } ->
              run_login ~request ~provider (fun ~cancel events ->
                  Spice_host_builtin.Login.browser ~stdenv host ~provider
                    ~method_id ~cancel events)
          | App.Auth_device_login { request; provider; method_id } ->
              run_login ~request ~provider (fun ~cancel events ->
                  Spice_host_builtin.Login.device ~stdenv host ~provider
                    ~method_id ~cancel events)
          | App.Auth_logout { request; provider } ->
              perform (fun () ->
                  let result =
                    Spice_host_builtin.Login.logout ~stdenv host ~provider ()
                  in
                  (* A removed credential can flip the derived default back. *)
                  (match result with
                  | Ok _ -> refresh_snapshot ()
                  | Error _ -> ());
                  deliver
                    (App.auth_settled ~request
                       (auth_record_of_logout ~provider
                          ~title:(model_provider_title provider)
                          result)))
          | App.Auth_cancel { request } ->
              perform (fun () -> resolve_auth_cancel request)
          | App.Auth_copy text -> Mosaic.Cmd.copy_to_clipboard text
          | App.Auth_open_url { request; url } ->
              (* Guarded by the live-flow table, not only the shell's
                 active-request check: no browser may open for a flow that
                 settled or was cancelled by the time the command runs. *)
              perform (fun () ->
                  if not (Hashtbl.mem auth_cancels request) then ()
                  else if Spice_host_builtin.Login.open_browser url then
                    deliver (App.auth_browser_opened ~request)
                  else deliver (App.auth_browser_open_failed ~request))
          | App.Review_command eff -> (
              match eff with
              | Spice_tui_review.Effect.Snapshot { request; base_spec } ->
                  perform (fun () ->
                      deliver
                        (App.review_msg
                           (Spice_tui_review.opened ~request
                              (open_review_snapshot base_spec))))
              | Spice_tui_review.Effect.Store { root; key; record } ->
                  perform (fun () ->
                      match review_store_dir root with
                      | Error message ->
                          deliver
                            (App.review_msg
                               (Spice_tui_review.save_failed message))
                      | Ok dir -> (
                          match
                            Spice_review_git.Records.save
                              ~fs:(Eio.Stdenv.fs stdenv) ~dir ~key record
                          with
                      | Ok () -> ()
                      | Error message ->
                          deliver
                            (App.review_msg
                               (Spice_tui_review.save_failed message))))
              | Spice_tui_review.Effect.Watch { root } ->
                  perform (fun () -> start_review_watch ~root)
              | Spice_tui_review.Effect.Watch_stop ->
                  perform (fun () -> stop_review_watch ())
              | Spice_tui_review.Effect.Sleep { request; seconds } ->
                  perform (fun () ->
                      Eio.Time.sleep clock seconds;
                      deliver
                        (App.review_msg
                           (Spice_tui_review.tick request
                              ~now:(Eio.Time.now clock))))
              | Spice_tui_review.Effect.Load { request; root; base; known } ->
                  perform (fun () ->
                      deliver
                        (App.review_msg
                           (Spice_tui_review.loaded request
                              (review_reload ~root ~base ~known))))
              | Spice_tui_review.Effect.Mutate
                  { request; root; base; expected; op } ->
                  perform (fun () ->
                      deliver
                        (App.review_msg
                           (Spice_tui_review.mutated request
                              (apply_review_cr_op ~root ~base ~expected op)))))
        in
        let interpret commands = Mosaic.Cmd.batch (List.map command commands) in
        (* The terminal window title is a pure projection of the model
           ({!App.terminal_title}); each init/update diffs it against the last
           emission so the OSC write happens only on change — idle↔working
           flips and the working tick, not every keystroke. *)
        let last_title = ref None in
        let sync_title model commands =
          let title = App.terminal_title model in
          if !last_title = Some title then interpret commands
          else begin
            last_title := Some title;
            Mosaic.Cmd.batch [ interpret commands; Mosaic.Cmd.set_title title ]
          end
        in
        let app =
          {
            Mosaic.init =
              (fun () ->
                (* [spice resume]: a startup session opens straight into the
                   session's chat through [App.init], which takes the same
                   transition (and issues the same {!App.Resume_session}) an
                   in-app resume does, so launch-into-session and in-app resume
                   share one path. *)
                let model, commands =
                  App.init ~startup ~snapshot
                    ~reduced_motion:(reduced_motion ())
                in
                (model, sync_title model commands));
            update =
              (fun msg model ->
                let model, commands = App.update msg model in
                (model, sync_title model commands));
            view = App.view;
            subscriptions = App.subscriptions;
          }
        in
        let probe =
          Option.map
            (fun receive runtime_probe ->
              runtime_probe
              |> Mosaic.Probe.with_pending ~name:"spice.live" (fun () ->
                  !main_pending)
              |> Mosaic.Probe.with_pending ~name:"spice.jobs" (fun () ->
                  match !attachment with
                  | Some (_, run) ->
                      Spice_host.Jobs.is_pending (Spice_host.Run.jobs run)
                  | None -> false)
              |> receive)
            probe
        in
        Fun.protect
          ~finally:(fun () ->
            shell_cancelled := true;
            dispatch_ref := None;
            close_attachment ())
          (fun () -> Mosaic.run ~matrix ~process_perform ?probe app);
        Ok { last_session = !created_session }

let resolve_unknown_trust ~stdenv ~process_env startup host =
  let trust =
    Spice_host.Config.workspace_trust (Spice_host.Host.config host)
  in
  let root = Spice_host.Trust.root trust in
  let decide = function
    | Trust_prompt.Exit -> assert false
    | Trust_prompt.Untrusted -> (
        match Spice_host.Trust.untrust ~stdenv ~process_env ~root () with
        | Error error ->
            Error
              (Trust_prompt.Save_failed
                 (Spice_host.Trust.Error.message error))
        | Ok _ ->
            load_host ~stdenv ~process_env startup
            |> Result.map_error (fun message ->
                Trust_prompt.Continue_failed message))
    | Trust_prompt.Trusted -> (
        match Spice_host.Trust.trust ~stdenv ~process_env ~root () with
        | Error error ->
            Error
              (Trust_prompt.Save_failed
                 (Spice_host.Trust.Error.message error))
        | Ok _ -> (
            match load_host ~stdenv ~process_env startup with
            | Ok host -> Ok host
            | Error message ->
                let rollback_error =
                  match
                    Spice_host.Trust.untrust ~stdenv ~process_env ~root ()
                  with
                  | Ok _ -> None
                  | Error error ->
                      Some (Spice_host.Trust.Error.message error)
                in
                Error
                  (Trust_prompt.Activation_failed
                     { message; rollback_error })))
  in
  Trust_prompt.run ~root ~decide

let run ~stdenv ~(startup : App.startup) ?clock ?matrix ?probe ?process_env () =
  (* A caller-supplied backend owns its own I/O, so the TTY gate only guards
     the default terminal path. *)
  if Option.is_none matrix && not (is_interactive ()) then Error `No_tty
  else
    let process_env =
      Option.value process_env ~default:(Spice_host.Env.current ())
    in
    match load_host ~stdenv ~process_env startup with
    | Error message -> Error (`Runtime message)
    | Ok host -> (
        let trust =
          Spice_host.Config.workspace_trust (Spice_host.Host.config host)
        in
        match Spice_host.Trust.status trust with
        | Spice_host.Trust.Trusted | Spice_host.Trust.Untrusted ->
            run_loaded ~stdenv ~startup ?clock ?matrix ?probe host
        | Spice_host.Trust.Unknown -> (
            match matrix with
            | Some _ ->
                Error
                  (`Runtime
                    "workspace trust must be seeded before using a supplied \
                     TUI matrix")
            | None -> (
                match
                  resolve_unknown_trust ~stdenv ~process_env startup host
                with
                | Trust_prompt.Exit_prompt -> Ok { last_session = None }
                | Trust_prompt.Continue host ->
                    run_loaded ~stdenv ~startup ?clock ?matrix ?probe host)))
