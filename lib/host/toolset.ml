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
    ~fetch_https ?anchors ?dune ?project_source ?merlin_program () =
  let config = Host.config host in
  let trusted = Trust.is_trusted (Config.workspace_trust config) in
  (* The shell tool cannot read the network posture back from the sealed
     sandbox, so pass it: a network-restricted confinement lets a failed
     command that looks network-blocked explain the policy to the model. *)
  let network_restricted =
    match (Sandbox.Effective.status sandbox).Sandbox.Status.network with
    | Sandbox.Status.Restricted -> true
    | Sandbox.Status.Enabled | Sandbox.Status.External -> false
  in
  let shell =
    Spice_tools.Shell.Config.make
      ~shell:(Config.Runtime.shell (Config.runtime config))
      ~sandbox:(Sandbox.Effective.sandbox sandbox)
      ?toolchain_root:(if trusted then Some (Config.project_root config) else None)
      ~network_restricted ()
  in
  let editor, _reason = editor_decision host model in
  let mutating = Sandbox.mutating_tools sandbox in
  let process_sandbox = Sandbox.Effective.sandbox sandbox in
  let fs = Eio.Stdenv.fs stdenv in
  let dune =
    match dune with
    | Some dune -> dune
    | None ->
        Spice_ocaml_dune.Rpc.Instance.create ~fs
          ~net:(Eio.Stdenv.net stdenv) ~workspace ()
  in
  (* [ocaml_eval]'s watched-build probe reads the shared endpoint status; it
     never engages the build engine. *)
  let watch () =
    match Spice_ocaml_dune.Rpc.Instance.refresh_status dune with
    | Spice_ocaml_dune.Rpc.Instance.Found endpoint ->
        Some (Spice_ocaml_dune.Rpc.Endpoint.to_string endpoint)
    | Spice_ocaml_dune.Rpc.Instance.Not_found
    | Spice_ocaml_dune.Rpc.Instance.Lookup_failed _ ->
        None
  in
  List.concat
    [
      Spice_tools.files ?anchors ~fs ~workspace ();
      Spice_tools.search ?anchors ~sandbox:process_sandbox ~fs ~workspace ();
      Spice_tools.edits ~mutating ?anchors ~editor ~fs ~workspace ();
      Spice_tools.ocaml ~mutating ~project_tools:trusted ?project_source
        ?merlin_program ~watch ~sandbox:process_sandbox ~fs
        ~process_mgr:(Eio.Stdenv.process_mgr stdenv)
        ~clock:(Eio.Stdenv.clock stdenv) ~cwd ~dune ~workspace ();
      Spice_tools.shell ~fs ~workspace ~config:shell ();
    ]
  @ Spice_tools.web ~sw
      ~mono_clock:(Eio.Stdenv.mono_clock stdenv)
      ~net:(Eio.Stdenv.net stdenv) ~fetch_https ~http ~policy:(web_policy host)
      ()
  @ Skills.tools ~stdenv skills
