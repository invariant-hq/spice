(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Temp workspace scaffolding and the pinned environment.

   The TUI runs in-process, so the environment reaches it two ways: the host
   configuration reads the [Spice_host.Env.t] snapshot injected through
   [Spice_tui.run ?process_env], and the few direct [Sys.getenv] reads (HOME
   tilde-folding, SPICE_REDUCED_MOTION) see the process environment, which
   {!apply} pins with [Unix.putenv]. Tests within one executable run
   sequentially, so process-global env mutation is safe. *)

type t = { root : string }

let root t = t.root
let path t local = Filename.concat t.root local

(* A scratch path OUTSIDE the workspace root, under the sibling XDG dir that
   [bindings] provisions and [with_temp] tears down, so test plumbing never
   surfaces in the file picker's listing or the /review diff. *)
let scratch t local = Filename.concat (t.root ^ ".xdg") local
let write t local text = Util.write_file (path t local) text
let read t local = Util.read_file (path t local)
let data t local = scratch t (Filename.concat "data/spice" local)
let state t local = scratch t (Filename.concat "state/spice" local)

let bindings ?openai_base_url ?(extra = []) t =
  (* Keep the home/XDG scratch dirs OUTSIDE the workspace root: created inside
     it they pollute the file picker's shallow listing of the project. *)
  let xdg = t.root ^ ".xdg" in
  let home = Filename.concat xdg "home" in
  let config = Filename.concat xdg "config" in
  let cache = Filename.concat xdg "cache" in
  let data = Filename.concat xdg "data" in
  let runtime = Filename.concat xdg "runtime" in
  let state = Filename.concat xdg "state" in
  Util.mkdir_p home;
  Util.mkdir_p config;
  Util.mkdir_p cache;
  Util.mkdir_p data;
  Util.mkdir_p runtime;
  Util.mkdir_p state;
  [
    ("HOME", home);
    ("XDG_CONFIG_HOME", config);
    ("XDG_CACHE_HOME", cache);
    ("XDG_DATA_HOME", data);
    ("XDG_RUNTIME_DIR", runtime);
    ("XDG_STATE_HOME", state);
    ("TERM", "xterm-256color");
    ("SPICE_AUTO_TITLE", "0");
    (* Reduced motion by default: without live animation the app sits in the
       idle regime, where queued messages render immediately instead of being
       gated behind the (virtual) frame cadence — so waiting never consumes
       virtual time and elapsed counters stay exact. Animation tests opt back
       in with [extra]. *)
    ("SPICE_REDUCED_MOTION", "1");
    ("SPICE_MODEL", "openai/gpt-5.5");
    ("SPICE_SANDBOX_MODE", "danger-full-access");
    (* Workspace tooling OFF by default: the OCaml/Dune integration is skipped,
       so a launch spawns no `dune build --watch`, `dune describe`, or fswatch.
       Without this the eager launch prewarm spawns a real dune subprocess once
       virtual time creeps past ~2s (settle quantizes ~1s per interaction), and
       the health probe's connection to it races the settle — a genuinely flaky
       footer (`dune ✗ → ✓`) plus a leaked long-running subprocess per test. Off,
       the footer freezes at the honest degraded `dune ✗ · diagnostics
       unavailable`, deterministically, and turns no longer pay the workspace
       spin-up. Tests that assert real dune states opt back in with
       [("SPICE_WORKSPACE_TOOLING", "auto")] in [~env]. *)
    ("SPICE_WORKSPACE_TOOLING", "off");
  ]
  @ extra
  @
  match openai_base_url with
  | None -> []
  | Some base_url ->
      [ ("OPENAI_API_KEY", "test-key"); ("SPICE_OPENAI_BASE_URL", base_url) ]

(* The spice under test must not see the dune that runs this test suite: an
   inherited RPC environment makes the footer read "dune: connected" inside a
   temp project that runs no dune of its own. *)
let leaks_dune name =
  String.starts_with ~prefix:"DUNE_" name || String.equal name "INSIDE_DUNE"

let env_snapshot overrides =
  let overridden name =
    List.exists (fun (key, _) -> String.equal key name) overrides
  in
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter_map (fun item ->
        match String.index_opt item '=' with
        | None -> None
        | Some eq ->
            let name = String.sub item 0 eq in
            let value =
              String.sub item (eq + 1) (String.length item - eq - 1)
            in
            if overridden name || leaks_dune name then None
            else Some (name, value))
  in
  (* [Spice_host.Env.of_list]: later bindings replace earlier ones. *)
  Spice_host.Env.of_list (inherited @ overrides)

let apply overrides = List.iter (fun (k, v) -> Unix.putenv k v) overrides

(* Run a git command in the project root, for review fixtures. Called from a
   [~seed] callback, which runs before the Eio loop starts, so a blocking
   [Sys.command] is fine. Pinned identity keeps commits deterministic. *)
let git t args =
  let command =
    String.concat " "
      ("git" :: "-C" :: Filename.quote t.root :: "-c" :: "user.name=Reviewer"
     :: "-c" :: "user.email=reviewer@example.com"
      :: List.map Filename.quote args)
  in
  match Sys.command (command ^ " >/dev/null 2>&1") with
  | 0 -> ()
  | code -> Util.failf "%s exited with %d" command code

(* A committed baseline the review screen opens on: [git init], the seeded files
   committed, so a caller's later [write] shows as the worktree diff. *)
let git_baseline t =
  git t [ "init"; "-q" ];
  git t [ "add"; "-A" ];
  git t [ "commit"; "-q"; "-m"; "baseline" ]

let with_temp name f =
  let root = Filename.concat "/tmp" ("spice-tui-next-" ^ name) in
  Util.rm_rf root;
  Util.mkdir_p root;
  let project = { root = Unix.realpath root } in
  Util.rm_rf (project.root ^ ".xdg");
  write project "dune-project" "(lang dune 3.0)\n(name fixture)\n";
  Fun.protect
    ~finally:(fun () ->
      Util.rm_rf project.root;
      Util.rm_rf (project.root ^ ".xdg"))
    (fun () -> f project)
