(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "spice.host.models" ~doc:"Model role resolution"

module Log = (val Logs.src_log log_src : Logs.LOG)

type choice = {
  model : Spice_provider.Model.t;
  reason : Reason.t;
  field : Config.Field.any option;
}

module Model_choice_base = struct
  type role = Main | Small
  type t = choice

  let model t = t.model
  let reason t = t.reason
end

(* Resolving user input. *)

let resolve_input ?field catalog input =
  match Spice_provider.Catalog.resolve catalog input with
  | Ok model -> Ok model
  | Error
      (Spice_provider.Catalog.Lookup_error.Unknown_provider { provider; known })
    ->
      Error (Host.Error.Unknown_provider { provider; field; known })
  | Error
      (Spice_provider.Catalog.Lookup_error.Unknown_model
         { provider; model; known }) ->
      Error
        (Host.Error.Unknown_model
           { provider; model; field; known; base_url = None })
  | Error
      (Spice_provider.Catalog.Lookup_error.Invalid_selector
         { input; message; candidates }) ->
      Error (Host.Error.Invalid_selector { input; message; candidates })

let resolve catalog input =
  Result.map
    (fun model -> { model; reason = Reason.explicit input; field = None })
    (resolve_input catalog input)

let for_select catalog input =
  Result.bind (resolve catalog input) (fun { model; _ } ->
      if Spice_provider.Model.selectable model then Ok model
      else
        Error
          (Host.Error.Not_selectable
             {
               selector = Spice_provider.Model.selector model;
               status = Spice_provider.Model.status model;
               field = None;
             }))

(* Run gates. *)

let tools_alternative catalog model =
  match
    Spice_provider.Catalog.provider catalog
      (Spice_provider.Model.provider model)
  with
  | None -> None
  | Some provider ->
      let usable candidate =
        Spice_provider.Model.selectable candidate
        && Spice_provider.Model.has_capability
             Spice_provider.Model.Capability.tools candidate
      in
      let candidate =
        match Spice_provider.default_model provider with
        | Some default when usable default -> Some default
        | Some _ | None -> List.find_opt usable (Spice_provider.models provider)
      in
      Option.map
        (fun candidate -> Spice_provider.Model.selector candidate)
        candidate

let require_choice ?reasoning_effort catalog { model; field; _ } =
  let selector = Spice_provider.Model.selector model in
  if not (Spice_provider.Model.selectable model) then
    Error
      (Host.Error.Not_selectable
         { selector; status = Spice_provider.Model.status model; field })
  else if
    not
      (Spice_provider.Model.has_capability Spice_provider.Model.Capability.tools
         model)
  then
    Error
      (Host.Error.Missing_capability
         {
           selector;
           capability = Spice_provider.Model.Capability.tools;
           alternative = tools_alternative catalog model;
         })
  else
    match reasoning_effort with
    | None -> Ok ()
    | Some effort ->
        let supported = Spice_provider.Model.supported_reasoning model in
        if
          Spice_provider.Model.has_capability
            Spice_provider.Model.Capability.reasoning model
          && List.mem effort supported
        then Ok ()
        else
          Error
            (Host.Error.Unsupported_reasoning { selector; effort; supported })

module Model_choice = struct
  include Model_choice_base

  let require = require_choice
end

(* Role resolution. *)

(* A configured selector resolves through the same rules as user input, tagged
   with the config field that named it so a resolution failure points at the
   setting. A configured value whose origin was not recorded degrades to
   [derived] rather than crashing a live resolution — and to [derived], not
   [explicit], because [cli_run] classifies [explicit] as command-line input
   and would misreport a configured value. *)
let configured_choice t ~field selector origin =
  let reason =
    match origin with
    | Some origin -> Reason.configured origin
    | None ->
        Log.warn (fun m ->
            m "configured model selector %s has no origin; treating as derived"
              selector);
        Reason.derived "configured"
  in
  match resolve_input ~field (Host.catalog t) selector with
  | Ok model -> Ok { model; reason; field = Some field }
  (* A configured selector whose provider carries a base-URL override is aimed at
     a custom endpoint; annotate the unknown-model failure with that override so
     the diagnostic points at the OpenAI-compatible [ollama] route rather than at
     catalog typos. *)
  | Error
      (Host.Error.Unknown_model
         { provider; model; field = error_field; known; base_url = _ }) ->
      let base_url =
        Config.Models.provider_base_url
          (Config.models (Host.config t))
          ~provider
      in
      Error
        (Host.Error.Unknown_model
           { provider; model; field = error_field; known; base_url })
  | Error error -> Error error

let configured_main t =
  let models = Config.models (Host.config t) in
  (* [main_with_origin] reads selector and origin from the same layer, so they
     cannot disagree. *)
  Option.map
    (fun (selector, origin) ->
      configured_choice t ~field:(Config.Field.Any Config.Field.model) selector
        origin)
    (Config.Models.main_with_origin models)

let configured_small t =
  let config = Host.config t in
  Option.map
    (fun selector ->
      configured_choice t ~field:(Config.Field.Any Config.Field.small_model)
        selector
        (Config.origin Config.Field.small_model config))
    (Config.Models.small (Config.models config))

let ( <|> ) candidate next =
  match candidate with Some _ as some -> some | None -> next ()

let first_selectable models =
  List.find_opt Spice_provider.Model.selectable models

(* A connected provider's default wins over registry order: a derived default
   must be a model the user can actually run, not whichever provider is
   declared first. With nothing connected the registry order stands, and the
   client build reports what is missing. *)
let first_provider_default ~connected t =
  let default_of providers =
    providers
    |> List.filter_map Spice_provider.default_model
    |> first_selectable
  in
  let providers = Host.providers t in
  let preferred =
    default_of
      (List.filter
         (fun declaration -> connected (Spice_provider.id declaration))
         providers)
  in
  match preferred with
  | Some model ->
      Some { model; reason = Reason.derived "connected_default"; field = None }
  | None ->
      Option.map
        (fun model ->
          { model; reason = Reason.derived "provider_default"; field = None })
        (default_of providers)

let first_selectable_model t =
  Spice_provider.Catalog.models ~include_hidden:true (Host.catalog t)
  |> first_selectable
  |> Option.map (fun model ->
      { model; reason = Reason.derived "first_selectable"; field = None })

let main ~connected t =
  match configured_main t with
  | Some result -> result
  | None -> (
      match
        first_provider_default ~connected t <|> fun () ->
        first_selectable_model t
      with
      | Some choice -> Ok choice
      | None -> Error Host.Error.No_model)

let input_price model =
  Option.bind (Spice_provider.Model.pricing model) (fun pricing ->
      pricing.Spice_provider.Model.default
        .Spice_provider.Model.input_per_million)

let cheapest_small t provider =
  let candidates =
    match
      Spice_provider.Catalog.models_for ~include_hidden:true (Host.catalog t)
        provider
    with
    | Error _ -> []
    | Ok models ->
        List.filter
          (fun model ->
            Spice_provider.Model.selectable model
            && Spice_provider.Model.has_input_modality
                 Spice_provider.Model.Modality.text model
            && Spice_provider.Model.has_output_modality
                 Spice_provider.Model.Modality.text model)
          models
  in
  List.fold_left
    (fun best model ->
      match (input_price model, best) with
      | None, _ -> best
      | Some price, None -> Some (model, price)
      | Some price, Some (_, best_price) when price < best_price ->
          Some (model, price)
      | Some _, Some _ -> best)
    None candidates
  |> Option.map fst

let small ~connected t =
  match configured_small t with
  | Some result -> result
  | None ->
      Result.map
        (fun main_choice ->
          let provider = Spice_provider.Model.provider main_choice.model in
          match cheapest_small t provider with
          | Some model ->
              { model; reason = Reason.derived "small_heuristic"; field = None }
          | None ->
              {
                main_choice with
                reason = Reason.derived "main_fallback";
                field = None;
              })
        (main ~connected t)

let choose ~connected t role =
  let result =
    match role with
    | Model_choice.Main -> main ~connected t
    | Model_choice.Small -> small ~connected t
  in
  (match result with
  | Ok { model; reason; _ } ->
      Log.debug (fun m ->
          m "model resolved role=%s provider=%s model=%s reason=%s"
            (match role with
            | Model_choice.Main -> "main"
            | Model_choice.Small -> "small")
            (Spice_llm.Provider.id (Spice_provider.Model.provider model))
            (Spice_provider.Model.selector model)
            (Reason.to_string reason))
  | Error _ -> ());
  result
