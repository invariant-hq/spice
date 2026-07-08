(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { root : string }

let root t = t.root
let path t local = Filename.concat t.root local

(* A scratch path OUTSIDE the workspace root, under the sibling XDG dir that [env]
   provisions and [with_temp] tears down. Fixture scaffolding that must not
   surface as untracked files in the workspace — the fake provider's script, port,
   capture, and log — lives here, so the file picker's listing and the /review
   diff stay free of test plumbing (the same reason [env] keeps HOME/XDG out of
   the root). *)
let scratch t local = Filename.concat (t.root ^ ".xdg") local
let exists t local = Sys.file_exists (path t local)
let write t local text = Util.write_file (path t local) text
let read t local = Util.read_file (path t local)

let env ?openai_base_url ?(unset = []) ?(extra = []) t =
  (* Keep the home/XDG scratch dirs OUTSIDE the workspace root: created inside
     it they pollute the file picker's shallow listing of the project (the
     picker window is only a few rows, so real entries scroll out of view). *)
  let xdg = t.root ^ ".xdg" in
  let home = Filename.concat xdg "home" in
  let config = Filename.concat xdg "config" in
  let cache = Filename.concat xdg "cache" in
  let runtime = Filename.concat xdg "runtime" in
  Util.mkdir_p home;
  Util.mkdir_p config;
  Util.mkdir_p cache;
  Util.mkdir_p runtime;
  let overrides =
    [
      ("HOME", home);
      ("XDG_CONFIG_HOME", config);
      ("XDG_CACHE_HOME", cache);
      ("XDG_RUNTIME_DIR", runtime);
      ("TERM", "xterm-256color");
      ("SPICE_AUTO_TITLE", "0");
      ("SPICE_MODEL", "openai/gpt-5.5");
      ("SPICE_SANDBOX_MODE", "danger-full-access");
    ]
    @ extra
    @
    match openai_base_url with
    | None -> []
    | Some base_url ->
        [ ("OPENAI_API_KEY", "test-key"); ("SPICE_OPENAI_BASE_URL", base_url) ]
  in
  (* [unset] names are absent from the child env entirely: dropped from the
     defaults above and filtered from the inherited environment, so a test can
     stage the genuinely-unconfigured state (no SPICE_MODEL, no key) rather
     than fight the harness defaults with empty-string overrides the config
     layer would reject. *)
  let unset_name name = List.exists (String.equal name) unset in
  let overrides =
    List.filter (fun (key, _) -> not (unset_name key)) overrides
  in
  let overridden name =
    List.exists (fun (key, _) -> String.equal key name) overrides
    || unset_name name
  in
  (* The spice under test must not see the dune that runs this test suite:
     an inherited RPC environment makes the footer read "dune: connected"
     inside a temp project that runs no dune of its own. *)
  let leaks_dune name =
    String.starts_with ~prefix:"DUNE_" name || String.equal name "INSIDE_DUNE"
  in
  let keep item =
    match String.split_first ~sep:"=" item with
    | None -> true
    | Some (name, _) -> (not (overridden name)) && not (leaks_dune name)
  in
  let base = Unix.environment () |> Array.to_list |> List.filter keep in
  let bindings = List.map (fun (key, value) -> key ^ "=" ^ value) overrides in
  Array.of_list (bindings @ base)

let with_temp name f =
  let root = Filename.concat "/tmp" ("spice-tui-" ^ name) in
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

let git t args =
  let quoted = List.map Filename.quote args in
  let command =
    String.concat " "
      ("git" :: "-C" :: Filename.quote t.root :: "-c" :: "user.name=Reviewer"
     :: "-c" :: "user.email=reviewer@example.com" :: quoted)
  in
  match Sys.command (command ^ " >/dev/null 2>&1") with
  | 0 -> ()
  | code -> failwith (Printf.sprintf "%s exited with %d" command code)

(* A committed baseline plus uncommitted edits: the shape the review screen
   opens on. Callers mutate further through [write] and [git]. *)
let with_git_fixture name f =
  with_temp name @@ fun project ->
  git project [ "init"; "-q" ];
  write project "lib/code.ml"
    "let alpha = 1\nlet beta = 2\nlet gamma = 3\nlet delta = 4\n";
  write project "notes.txt" "baseline\n";
  git project [ "add"; "-A" ];
  git project [ "commit"; "-q"; "-m"; "baseline" ];
  f project

(* Spice discovers dune through the RPC registry in the (isolated) XDG runtime
   dir and re-polls it, so there is no need to wait for the watch to be up
   before launching spice: tests wait on the "dune: connected" footer. *)
let with_external_dune_watch t f =
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let argv = [| "dune"; "build"; "--root"; t.root; "--watch"; "@all" |] in
  let pid =
    Unix.create_process_env "dune" argv (env t) dev_null dev_null dev_null
  in
  Unix.close dev_null;
  let stop () =
    (try Unix.kill pid Sys.sigterm with Unix.Unix_error _ -> ());
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
        ignore (Unix.waitpid [] pid : int * Unix.process_status)
    | _ -> ()
    | exception Unix.Unix_error _ -> ()
  in
  Fun.protect ~finally:stop f
