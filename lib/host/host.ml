(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Reasoning_effort = Spice_llm.Request.Options.Reasoning_effort

module Error = struct
  type t =
    | Config of Config.Error.t
    | Duplicate_provider of Spice_llm.Provider.t
    | Unknown_provider of {
        provider : Spice_llm.Provider.t;
        field : Config.Field.any option;
        known : string list;
      }
    | Unknown_model of {
        provider : Spice_llm.Provider.t;
        model : string;
        field : Config.Field.any option;
        known : string list;
      }
    | Invalid_selector of {
        input : string;
        message : string;
        candidates : string list;
      }
    | Not_selectable of {
        selector : string;
        status : Spice_provider.Model.status;
        field : Config.Field.any option;
      }
    | Missing_capability of {
        selector : string;
        capability : Spice_provider.Model.Capability.t;
        alternative : string option;
      }
    | Unsupported_reasoning of {
        selector : string;
        effort : Spice_llm.Request.Options.Reasoning_effort.t;
        supported : Spice_llm.Request.Options.Reasoning_effort.t list;
      }
    | No_model
    | Missing_credential of Spice_llm.Provider.t
    | Blocked_credential of {
        provider : Spice_llm.Provider.t;
        problems : Spice_account.Problem.t list;
      }
    | Unsupported_credential of {
        provider : Spice_llm.Provider.t;
        kind : Spice_account.Secret.Kind.t;
      }
    | Credentials of {
        provider : Spice_llm.Provider.t option;
        message : string;
      }
    | No_adapter of Spice_llm.Provider.t
    | Client of { provider : Spice_llm.Provider.t; message : string }
    | Instructions of Spice_llm.Request.Error.t
    | Workspace of { cwd : string; message : string }

  let named key description =
    match key with
    | None -> description
    | Some (Config.Field.Any field) ->
        Config.Field.name field ^ " names " ^ description

  let message = function
    | Config error -> Config.Error.message error
    | Duplicate_provider provider ->
        "duplicate provider: " ^ Spice_llm.Provider.id provider
    | Unknown_provider { provider; field; _ } ->
        named field
          (Printf.sprintf "unknown provider %S"
             (Spice_llm.Provider.id provider))
    | Unknown_model { provider; model; field; _ } ->
        named field
          (Printf.sprintf "unknown model %S for provider %S" model
             (Spice_llm.Provider.id provider))
    | Invalid_selector { input; message; _ } ->
        Printf.sprintf "invalid model %S: %s" input message
    | Not_selectable { selector; status; field } ->
        named field
          (match status with
          | Spice_provider.Model.Unavailable reason ->
              Printf.sprintf "unavailable model %S: %s" selector reason
          | Spice_provider.Model.Deprecated ->
              Printf.sprintf "deprecated model %S is not selectable" selector
          | Spice_provider.Model.Stable | Spice_provider.Model.Preview ->
              Printf.sprintf "model %S is not selectable" selector)
    | Missing_capability { selector; capability; _ } ->
        Printf.sprintf "model %S does not support %s" selector
          (Spice_provider.Model.Capability.to_string capability)
    | Unsupported_reasoning { selector; effort; supported = [] } ->
        Printf.sprintf "model %S does not support reasoning effort %s" selector
          (Reasoning_effort.to_string effort)
    | Unsupported_reasoning { selector; effort; supported } ->
        Printf.sprintf
          "model %S does not support reasoning effort %s (supported: %s)"
          selector
          (Reasoning_effort.to_string effort)
          (String.concat ", " (List.map Reasoning_effort.to_string supported))
    | No_model -> "no model is available"
    | Missing_credential provider ->
        "missing credential for provider: " ^ Spice_llm.Provider.id provider
    | Blocked_credential { provider; problems } ->
        Printf.sprintf "blocked credential for provider %s: %s"
          (Spice_llm.Provider.id provider)
          (String.concat ", "
             (List.map Spice_account.Problem.to_string problems))
    | Unsupported_credential { provider; kind } ->
        Format.asprintf "unsupported credential kind %a for provider %a"
          Spice_account.Secret.Kind.pp kind Spice_llm.Provider.pp provider
    | Credentials { provider = None; message } -> message
    | Credentials { provider = Some provider; message } ->
        Printf.sprintf "invalid credential for provider %s: %s"
          (Spice_llm.Provider.id provider)
          message
    | No_adapter provider ->
        "no adapter for provider: " ^ Spice_llm.Provider.id provider
    | Client { provider; message } ->
        Printf.sprintf "cannot build %s client: %s"
          (Spice_llm.Provider.id provider)
          message
    | Instructions error ->
        "invalid instruction prelude: " ^ Spice_llm.Request.Error.message error
    | Workspace { cwd; message } ->
        Printf.sprintf "invalid workspace directory %s: %s" cwd message

  let unset_hint = function
    | Some (Config.Field.Any field)
      when Config.Field.equal field Config.Field.model
           || Config.Field.equal field Config.Field.small_model ->
        [
          Printf.sprintf "run `spice config unset %s` to clear it"
            (Config.Field.name field);
        ]
    | Some _ | None -> []

  let show_hint selector =
    [
      Printf.sprintf "run `spice models show %s` to inspect the model" selector;
    ]

  let hints = function
    | Config error -> Config.Error.hints error
    | Unknown_provider { provider; field; known } ->
        Spice_diagnostic.did_you_mean
          (Spice_llm.Provider.id provider)
          ~candidates:known
        @ unset_hint field
    | Unknown_model { model; field; known; _ } ->
        Spice_diagnostic.did_you_mean model ~candidates:known @ unset_hint field
    | Invalid_selector { candidates; _ } -> Spice_diagnostic.suggest candidates
    | Not_selectable { field = Some _ as field; _ } -> unset_hint field
    | Not_selectable { field = None; _ } ->
        [ "run `spice models --all` to inspect model status" ]
    | Missing_capability { selector; alternative; _ } ->
        (match alternative with
          | Some alternative -> [ "try " ^ alternative ]
          | None -> [])
        @ show_hint selector
    | Unsupported_reasoning { selector; _ } -> show_hint selector
    | Missing_credential provider ->
        [
          Printf.sprintf "run `spice auth login %s` to add a credential"
            (Spice_llm.Provider.id provider);
        ]
    | Blocked_credential { provider; _ } ->
        [
          Printf.sprintf
            "run `spice auth status %s` and the repair command it names"
            (Spice_llm.Provider.id provider);
        ]
    | Duplicate_provider _ | No_model | Unsupported_credential _ | Credentials _
    | No_adapter _ | Client _ | Instructions _ | Workspace _ ->
        []

  let diagnostic error =
    Spice_diagnostic.make ~hints:(hints error) (message error)

  let pp ppf error = Format.pp_print_string ppf (message error)
end

module Provider_map = Map.Make (struct
  type t = Spice_llm.Provider.t

  let compare = Spice_llm.Provider.compare
end)

module Adapter = struct
  type build =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    ?base_url:string ->
    Spice_account.Credential.t option ->
    (Spice_llm.Client.t, Error.t) result

  type observation = {
    problems : Spice_account.Problem.t list;
    profile : Spice_account.Profile.t option;
    org : Spice_account.Org.t option;
    models : string list option;
  }

  type check =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    ?base_url:string ->
    Spice_account.Credential.t ->
    (observation, Error.t) result

  type refresh =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    now:Spice_account.timestamp ->
    ?auth_base_url:string ->
    Spice_account.Secret.t ->
    (Spice_account.Secret.t, Spice_account.Problem.t) result

  type revoke =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    ?auth_base_url:string ->
    Spice_account.Secret.t ->
    (unit, Spice_account.Problem.t) result

  type artifact_prepare =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    cancelled:(unit -> bool) ->
    observe:(Spice_protocol.Model_artifact.progress -> unit) ->
    Spice_provider.Model.t ->
    (unit, Spice_llm.Error.t) result

  type artifact_download =
    sw:Eio.Switch.t ->
    stdenv:Eio_unix.Stdenv.base ->
    force:bool ->
    observe:(Spice_protocol.Model_artifact.progress -> unit) ->
    Spice_provider.Model.t ->
    Spice_protocol.Model_artifact.download_outcome

  type model_artifact = {
    status :
      Spice_provider.Model.t -> Spice_protocol.Model_artifact.status option;
    prepare : artifact_prepare;
    download : artifact_download;
  }

  type t = {
    build : build;
    check : check option;
    refresh : refresh option;
    revoke : revoke option;
    model_artifact : model_artifact option;
  }

  let make ~build ?check ?refresh ?revoke ?model_artifact () =
    { build; check; refresh; revoke; model_artifact }

  let build t ~sw ~stdenv ?base_url credential =
    t.build ~sw ~stdenv ?base_url credential

  let check t = t.check
  let refresh t = t.refresh
  let revoke t = t.revoke
  let model_artifact t = t.model_artifact
end

module Provider = struct
  type t = { declaration : Spice_provider.t; adapter : Adapter.t option }

  let make declaration ?adapter () = { declaration; adapter }
  let declaration t = t.declaration
  let adapter t = t.adapter
end

module Provider_registry = struct
  (* The provider-uniqueness invariant lives once, in [Catalog.of_list]. The
     registry adds only the host-specific concern: the runtime adapter index,
     whose values [Catalog.t] does not carry. *)
  type t = {
    entries : Provider.t list;
    catalog : Spice_provider.Catalog.t;
    adapters : Adapter.t Provider_map.t;
  }

  let make entries =
    match
      Spice_provider.Catalog.of_list (List.map Provider.declaration entries)
    with
    | Error provider -> Error (Error.Duplicate_provider provider)
    | Ok catalog ->
        (* Ids are unique via [of_list], so no adapter entry is clobbered. *)
        let adapters =
          List.fold_left
            (fun map entry ->
              match Provider.adapter entry with
              | None -> map
              | Some adapter ->
                  Provider_map.add
                    (Spice_provider.id (Provider.declaration entry))
                    adapter map)
            Provider_map.empty entries
        in
        Ok { entries; catalog; adapters }

  let entries t = t.entries
  let providers t = Spice_provider.Catalog.providers t.catalog
  let catalog t = t.catalog
  let provider t id = Spice_provider.Catalog.provider t.catalog id
  let adapter t id = Provider_map.find_opt id t.adapters

  let provider_ids t =
    List.map
      (fun provider -> Spice_llm.Provider.id (Spice_provider.id provider))
      (providers t)
end

type t = { config : Config.t; registry : Provider_registry.t }

let make ~config ~registry () = Ok { config; registry }

let load ~stdenv ~registry ?cwd ?config () =
  let config =
    match config with
    | Some config -> Ok config
    | None ->
        Result.map_error
          (fun error -> Error.Config error)
          (Config.load ~stdenv ?cwd ())
  in
  match config with
  | Error _ as error -> error
  | Ok config -> make ~config ~registry ()

let config t = t.config
let registry t = t.registry
let runtime_providers t = Provider_registry.entries t.registry
let providers t = Provider_registry.providers t.registry
let catalog t = Provider_registry.catalog t.registry
let provider t id = Provider_registry.provider t.registry id
let adapter t id = Provider_registry.adapter t.registry id

let require_provider t id =
  match provider t id with
  | None -> Error (`Unknown_provider id)
  | Some provider -> Ok provider

let provider_ids t = Provider_registry.provider_ids t.registry
