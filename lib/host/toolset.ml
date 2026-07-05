(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Web policy construction: the configured backend plus its process-environment
   credential. The Brave API key is read from [SPICE_WEB_BRAVE_API_KEY] in the
   host configuration's process-environment snapshot, not a config-file value. *)
let web_policy host =
  let config = Host.config host in
  let web = Config.web config in
  let search_backend =
    match Config.Web.search_backend web with
    | "disabled" -> Spice_tools.Web.Policy.Disabled
    | "brave" -> (
        match Env.get (Config.process_env config) "SPICE_WEB_BRAVE_API_KEY" with
        | None | Some "" -> Spice_tools.Web.Policy.Disabled
        | Some api_key -> Spice_tools.Web.Policy.Brave { api_key })
    | backend ->
        invalid_arg ("unknown web search backend in resolved config: " ^ backend)
  in
  Spice_tools.Web.Policy.make ~enabled:(Config.Web.enabled web)
    ~allow_private_network:(Config.Web.allow_private_network web)
    ~max_fetch_bytes:(Config.Web.fetch_max_bytes web)
    ~max_output_chars:(Config.Web.output_max_chars web)
    ~default_timeout_ms:(Config.Web.timeout_ms web)
    ~max_timeout_ms:(Config.Web.max_timeout_ms web)
    ~search_backend ()

(* The capability tag a model carries when it was trained on the apply_patch
   unified-diff format. Absence is a definite "no", so proxy and unknown models
   resolve to the string-replace family. *)
let apply_patch_capability =
  Spice_provider.Model.Capability.extension "apply-patch"

type editor_reason = Override | Capability | Default_no_model

let editor_reason_to_string = function
  | Override -> "override"
  | Capability -> "capability"
  | Default_no_model -> "default(no-model)"

(* Which file-mutation editor family a model receives, and why. The
   [tools.editor] config override wins; [auto] defers to the model's capability
   metadata, and falls back to the string-replace family when no model is
   available (the [spice debug tools] snapshot without credentials). The enum
   is validated at config parse, so any other spelling is a bug here. *)
let editor_decision host model =
  let config = Host.config host in
  match Config.Tools.editor (Config.tools config) with
  | "apply-patch" -> (Spice_tools.Editor.Apply_patch, Override)
  | "string-replace" -> (Spice_tools.Editor.String_replace, Override)
  | "auto" -> (
      match model with
      | None -> (Spice_tools.Editor.String_replace, Default_no_model)
      | Some model ->
          if Spice_provider.Model.has_capability apply_patch_capability model
          then (Spice_tools.Editor.Apply_patch, Capability)
          else (Spice_tools.Editor.String_replace, Capability))
  | other -> invalid_arg ("unknown tools.editor in resolved config: " ^ other)

let make ~sw ~stdenv host ?model ~workspace ~sandbox ~skills ~cwd ~http
    ~fetch_https ~anchors_seed ?dune ?project_source ?merlin_program () =
  let config = Host.config host in
  let shell =
    Spice_tools.Shell.Config.make
      ~shell:(Config.Runtime.shell (Config.runtime config))
      ~sandbox:(Sandbox.Effective.sandbox sandbox)
      ()
  in
  (* Anchored edits are flag-gated: one ephemeral resolver per run, seeded from
     the session id so scripted transcripts are stable. With the flag off the
     catalog and read output are byte-identical to today. *)
  let anchors =
    if Config.Tools.anchored_edits (Config.tools config) then
      Some
        (Spice_tools.Anchor_tracker.resolver
           (Spice_tools.Anchor_tracker.create ~seed:anchors_seed ()))
    else None
  in
  let dune =
    match dune with
    | Some dune -> dune
    | None ->
        Spice_ocaml_dune.Rpc.Instance.create ~fs:(Eio.Stdenv.fs stdenv)
          ~net:(Eio.Stdenv.net stdenv) ~workspace ()
  in
  (* [ocaml_eval]'s watched-build probe: the current Dune RPC endpoint, if a
     watch holds the lock. It reads the shared instance's registry status, not a
     fresh poll, so it never engages the build engine. *)
  let watch () =
    match Spice_ocaml_dune.Rpc.Instance.refresh_status dune with
    | Spice_ocaml_dune.Rpc.Instance.Found endpoint ->
        Some (Spice_ocaml_dune.Rpc.Endpoint.to_string endpoint)
    | Spice_ocaml_dune.Rpc.Instance.Not_found
    | Spice_ocaml_dune.Rpc.Instance.Lookup_failed _ ->
        None
  in
  let editor, _reason = editor_decision host model in
  Spice_tools.default
    ~mutating:(Sandbox.mutating_tools sandbox)
    ~editor ?project_source ?merlin_program ~watch ?anchors
    ~fs:(Eio.Stdenv.fs stdenv)
    ~process_mgr:(Eio.Stdenv.process_mgr stdenv)
    ~clock:(Eio.Stdenv.clock stdenv) ~cwd ~dune ~workspace ~shell ()
  @ Spice_tools.web ~sw
      ~mono_clock:(Eio.Stdenv.mono_clock stdenv)
      ~net:(Eio.Stdenv.net stdenv) ~fetch_https ~http ~policy:(web_policy host)
      ()
  @ Skills.tools ~stdenv skills
