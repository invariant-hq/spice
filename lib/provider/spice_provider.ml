(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Account = Spice_account
module Llm_model = Spice_llm.Model
module Llm_provider = Spice_llm.Provider
module Options = Spice_llm.Request.Options

let invalid fn message = invalid_arg ("Spice_provider." ^ fn ^ ": " ^ message)

let check_optional_non_empty fn field = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid fn (field ^ " must not be empty")

let valid_env_name name =
  let len = String.length name in
  let valid_first = function '_' -> true | c -> Char.Ascii.is_letter c in
  let valid_rest = function
    | '_' -> true
    | c -> Char.Ascii.is_letter c || Char.Ascii.is_digit c
  in
  let rec loop index =
    index = len
    || (valid_rest (String.unsafe_get name index) && loop (index + 1))
  in
  len > 0 && valid_first (String.unsafe_get name 0) && loop 1

let check_env_name fn name =
  if not (valid_env_name name) then invalid fn "name is invalid"

let check_sorted_no_duplicates fn field compare values =
  let rec loop = function
    | first :: second :: rest ->
        if compare first second = 0 then
          invalid fn (field ^ " contain duplicates");
        loop (second :: rest)
    | [] | [ _ ] -> ()
  in
  loop values

let check_no_duplicates fn field compare values =
  check_sorted_no_duplicates fn field compare (List.sort compare values)

let sort_unique fn field compare values =
  let sorted = List.sort compare values in
  check_sorted_no_duplicates fn field compare sorted;
  sorted

module Tag = struct
  let is_first c = Char.Ascii.is_lower c

  let is_rest c =
    Char.Ascii.is_lower c || Char.Ascii.is_digit c || Char.equal c '-'
    || Char.equal c '_'

  let valid tag =
    let len = String.length tag in
    let rec loop index =
      index = len || (is_rest (String.unsafe_get tag index) && loop (index + 1))
    in
    len > 0 && is_first (String.unsafe_get tag 0) && loop 1

  let check fn kind tag =
    if not (valid tag) then invalid fn (kind ^ " tag is invalid")

  let reserved names tag = List.exists (String.equal tag) names
end

module Auth = struct
  module Env = struct
    type t = { name : string; kind : Account.Secret.Kind.t }

    let declare ~fn ~name ~kind =
      check_env_name fn name;
      { name; kind }

    let api_key name =
      declare ~fn:"Auth.Env.api_key" ~name ~kind:Account.Secret.Kind.Api_key

    let bearer name =
      declare ~fn:"Auth.Env.bearer" ~name ~kind:Account.Secret.Kind.Bearer

    let oauth_access_token name =
      declare ~fn:"Auth.Env.oauth_access_token" ~name
        ~kind:Account.Secret.Kind.OAuth

    let name t = t.name
    let kind t = t.kind

    module Error = struct
      type t =
        | Invalid_secret of {
            name : string;
            kind : Account.Secret.Kind.t;
            message : string;
          }

      let message = function
        | Invalid_secret { name; kind; message } ->
            Format.asprintf
              "environment variable %s is not valid %a credential material: %s"
              name Account.Secret.Kind.pp kind message

      let pp ppf error = Format.pp_print_string ppf (message error)
    end

    let user_error_message message =
      match String.split_first ~sep:":" message with
      | None -> message
      | Some (_, rest) -> String.trim rest

    let invalid_secret t message =
      Error
        (Error.Invalid_secret
           {
             name = t.name;
             kind = t.kind;
             message = user_error_message message;
           })

    let secret t value =
      if String.is_empty value then invalid_secret t "value must not be empty"
      else
        match t.kind with
        | Account.Secret.Kind.Api_key -> (
            match Account.Secret.api_key value with
            | secret -> Ok secret
            | exception Invalid_argument message -> invalid_secret t message)
        | Account.Secret.Kind.Bearer -> (
            match Account.Secret.bearer value with
            | secret -> Ok secret
            | exception Invalid_argument message -> invalid_secret t message)
        | Account.Secret.Kind.OAuth -> (
            match Account.Secret.oauth ~access_token:value () with
            | secret -> Ok secret
            | exception Invalid_argument message -> invalid_secret t message)

    let pp ppf t =
      Format.fprintf ppf "%s:%a" t.name Account.Secret.Kind.pp t.kind
  end

  module Login = struct
    module Protocol = struct
      type oauth2_device_code = {
        device_client : Oauth2.Client.t;
        device_endpoint : Uri.t;
        device_token_endpoint : Uri.t;
        device_scope : string list;
        device_extra : (string * string) list;
      }

      type oauth2_authorization_code = {
        authorization_client : Oauth2.Client.t;
        authorization_endpoint : Uri.t;
        authorization_token_endpoint : Uri.t;
        redirect_uri : Uri.t option;
        authorization_scope : string list;
        authorization_extra : (string * string) list;
        pkce : bool;
      }

      type t =
        | Api_key
        | OAuth2_device_code of oauth2_device_code
        | OAuth2_authorization_code of oauth2_authorization_code
        | Provider_device_code of { provider_flow : string }
        | External of { instructions : string option }
    end

    type t = { id : string; label : string; protocol : Protocol.t }

    let check_id fn id = Tag.check fn "login method" id

    let make ~id ~label protocol =
      check_id "Auth.Login.make" id;
      if String.is_empty label then
        invalid "Auth.Login.make" "label must not be empty";
      { id; label; protocol }

    let api_key ?(id = "api-key") ?(label = "API key") () =
      make ~id ~label Protocol.Api_key

    let oauth2_device_code ?(id = "device-code") ?(label = "Device code")
        ?(scope = []) ?(extra = []) ~client ~device_endpoint ~token_endpoint ()
        =
      let config : Protocol.oauth2_device_code =
        {
          Protocol.device_client = client;
          Protocol.device_endpoint;
          Protocol.device_token_endpoint = token_endpoint;
          Protocol.device_scope = scope;
          Protocol.device_extra = extra;
        }
      in
      make ~id ~label (Protocol.OAuth2_device_code config)

    let oauth2_authorization_code ?(id = "browser") ?(label = "Browser")
        ?(scope = []) ?(extra = []) ?redirect_uri ?(pkce = true) ~client
        ~authorization_endpoint ~token_endpoint () =
      make ~id ~label
        (Protocol.OAuth2_authorization_code
           {
             Protocol.authorization_client = client;
             Protocol.authorization_endpoint;
             Protocol.authorization_token_endpoint = token_endpoint;
             Protocol.redirect_uri;
             Protocol.authorization_scope = scope;
             Protocol.authorization_extra = extra;
             Protocol.pkce;
           })

    let id t = t.id
    let label t = t.label
    let protocol t = t.protocol
  end

  type t = { required : bool; env : Env.t list; login : Login.t list }

  let make ?required ?(env = []) ?(login = []) () =
    check_no_duplicates "Auth.make" "environment declarations" String.compare
      (List.map Env.name env);
    check_no_duplicates "Auth.make" "login methods" String.compare
      (List.map Login.id login);
    let has_method = not (List.is_empty env && List.is_empty login) in
    let required = Option.value required ~default:has_method in
    if required && not has_method then
      invalid "Auth.make" "required auth declares no env or login method";
    { required; env; login }

  let none = make ()
  let required t = t.required
  let env t = t.env
  let logins t = t.login

  let login_by_id t id =
    List.find_opt (fun login -> String.equal id (Login.id login)) t.login
end

module Selector = struct
  type t = { provider : Llm_provider.t; id : string }

  module Error = struct
    type t =
      | Empty
      | Missing_slash
      | Empty_provider
      | Empty_model
      | Invalid_provider of string * string

    let message = function
      | Empty -> "model selector must not be empty"
      | Missing_slash -> "model selector must be in the form provider/model"
      | Empty_provider -> "model selector provider must not be empty"
      | Empty_model -> "model selector model must not be empty"
      | Invalid_provider (provider, message) ->
          Printf.sprintf "model selector provider %S is invalid: %s" provider
            message

    let pp ppf error = Format.pp_print_string ppf (message error)
  end

  open Error

  let make ~provider ~id =
    if String.is_empty id then Error Empty_model else Ok { provider; id }

  let of_string raw =
    let value = String.trim raw in
    if String.is_empty value then Error Empty
    else
      match String.split_first ~sep:"/" value with
      | None -> Error Missing_slash
      | Some ("", _) -> Error Empty_provider
      | Some (_, "") -> Error Empty_model
      | Some (provider, id) ->
          begin match Llm_provider.make provider with
          | provider -> make ~provider ~id
          | exception Invalid_argument message ->
              Error (Invalid_provider (provider, message))
          end

  let provider t = t.provider
  let id t = t.id
end

module Model = struct
  module Date = struct
    type t = { year : int; month : int; day : int }

    let is_leap_year year =
      year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)

    let days_in_month year = function
      | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
      | 4 | 6 | 9 | 11 -> 30
      | 2 -> if is_leap_year year then 29 else 28
      | _ -> 0

    let make ~year ~month ~day =
      if year < 1 || year > 9999 then
        invalid "Model.Date.make" "year must be between 1 and 9999";
      if month < 1 || month > 12 then
        invalid "Model.Date.make" "month must be between 1 and 12";
      let max_day = days_in_month year month in
      if day < 1 || day > max_day then
        invalid "Model.Date.make" "day is invalid for month";
      { year; month; day }

    let digit s index = Char.Ascii.digit_to_int (String.unsafe_get s index)

    let all_digits s indexes =
      List.for_all
        (fun index -> Char.Ascii.is_digit (String.unsafe_get s index))
        indexes

    let of_string s =
      if
        String.length s = 10
        && Char.equal (String.unsafe_get s 4) '-'
        && Char.equal (String.unsafe_get s 7) '-'
        && all_digits s [ 0; 1; 2; 3; 5; 6; 8; 9 ]
      then
        let year =
          (digit s 0 * 1000) + (digit s 1 * 100) + (digit s 2 * 10) + digit s 3
        in
        let month = (digit s 5 * 10) + digit s 6 in
        let day = (digit s 8 * 10) + digit s 9 in
        match make ~year ~month ~day with
        | date -> Some date
        | exception Invalid_argument _ -> None
      else None

    let to_string t = Printf.sprintf "%04d-%02d-%02d" t.year t.month t.day
    let equal a b = a.year = b.year && a.month = b.month && a.day = b.day

    let compare a b =
      match Int.compare a.year b.year with
      | 0 -> (
          match Int.compare a.month b.month with
          | 0 -> Int.compare a.day b.day
          | order -> order)
      | order -> order

    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end

  module Modality = struct
    type t = string

    let text = "text"
    let image = "image"
    let audio = "audio"
    let video = "video"
    let pdf = "pdf"
    let reserved = [ audio; image; pdf; text; video ]

    let extension tag =
      Tag.check "Model.Modality.extension" "modality" tag;
      if Tag.reserved reserved tag then
        invalid "Model.Modality.extension" "tag is reserved";
      tag

    let to_string t = t

    let of_string = function
      | "audio" -> Some audio
      | "image" -> Some image
      | "pdf" -> Some pdf
      | "text" -> Some text
      | "video" -> Some video
      | tag -> if Tag.valid tag then Some tag else None

    let equal = String.equal
    let compare = String.compare
    let pp = Format.pp_print_string
  end

  module Capability = struct
    type t = string

    let tools = "tools"
    let reasoning = "reasoning"
    let json_schema = "json_schema"
    let reserved = [ json_schema; reasoning; tools ]

    let extension tag =
      Tag.check "Model.Capability.extension" "capability" tag;
      if Tag.reserved reserved tag then
        invalid "Model.Capability.extension" "tag is reserved";
      tag

    let to_string t = t

    let of_string = function
      | "json_schema" -> Some json_schema
      | "reasoning" -> Some reasoning
      | "tools" -> Some tools
      | tag -> if Tag.valid tag then Some tag else None

    let equal = String.equal
    let compare = String.compare
    let pp = Format.pp_print_string
  end

  type price = {
    input_per_million : float option;
    cached_input_per_million : float option;
    output_per_million : float option;
    cache_write_5m_per_million : float option;
    cache_write_1h_per_million : float option;
  }

  type pricing = { default : price; context_over : (int * price) list }

  let check_price field = function
    | None -> ()
    | Some value ->
        if (not (Float.is_finite value)) || value < 0. then
          invalid "Model.price" (field ^ " must be finite and non-negative")

  let price ?input_per_million ?cached_input_per_million ?output_per_million
      ?cache_write_5m_per_million ?cache_write_1h_per_million () =
    check_price "input_per_million" input_per_million;
    check_price "cached_input_per_million" cached_input_per_million;
    check_price "output_per_million" output_per_million;
    check_price "cache_write_5m_per_million" cache_write_5m_per_million;
    check_price "cache_write_1h_per_million" cache_write_1h_per_million;
    {
      input_per_million;
      cached_input_per_million;
      output_per_million;
      cache_write_5m_per_million;
      cache_write_1h_per_million;
    }

  let check_context_over threshold =
    if threshold < 0 then
      invalid "Model.make_pricing"
        "context_over thresholds must be non-negative"

  let make_pricing ?(context_over = []) default =
    List.iter (fun (threshold, _) -> check_context_over threshold) context_over;
    let context_over =
      List.sort
        (fun (left, _) (right, _) -> Int.compare left right)
        context_over
    in
    check_no_duplicates "Model.make_pricing" "context_over thresholds"
      Int.compare
      (List.map fst context_over);
    { default; context_over }

  let price_for ?context_tokens t =
    begin match context_tokens with
    | Some tokens when tokens < 0 ->
        invalid "Model.price_for" "context_tokens must be non-negative"
    | None | Some _ -> ()
    end;
    match context_tokens with
    | None -> t.default
    | Some tokens -> (
        let selected =
          List.fold_left
            (fun selected (threshold, price) ->
              if tokens > threshold then
                match selected with
                | None -> Some (threshold, price)
                | Some (selected_threshold, _) as selected ->
                    if threshold > selected_threshold then
                      Some (threshold, price)
                    else selected
              else selected)
            None t.context_over
        in
        match selected with None -> t.default | Some (_, price) -> price)

  type status = Stable | Preview | Deprecated | Unavailable of string

  type t = {
    llm : Llm_model.t;
    display_name : string option;
    family : string option;
    released_on : Date.t option;
    context_window : int option;
    max_output_tokens : int option;
    default_reasoning : Options.Reasoning_effort.t option;
    supported_reasoning : Options.Reasoning_effort.t list;
    input_modalities : Modality.t list;
    output_modalities : Modality.t list;
    capabilities : Capability.t list;
    pricing : pricing option;
    status : status;
  }

  let reasoning_rank = function
    | Options.Reasoning_effort.Disabled -> 0
    | Options.Reasoning_effort.Minimal -> 1
    | Options.Reasoning_effort.Low -> 2
    | Options.Reasoning_effort.Medium -> 3
    | Options.Reasoning_effort.High -> 4
    | Options.Reasoning_effort.Extra_high -> 5
    | Options.Reasoning_effort.Max -> 6

  let compare_reasoning a b = Int.compare (reasoning_rank a) (reasoning_rank b)

  let check_positive_option fn field = function
    | None -> ()
    | Some value -> if value <= 0 then invalid fn (field ^ " must be positive")

  let normalize_modalities field values =
    sort_unique "Model.make" field Modality.compare values

  let normalize_capabilities values =
    sort_unique "Model.make" "capabilities" Capability.compare values

  let normalize_supported_reasoning values =
    sort_unique "Model.make" "supported_reasoning" compare_reasoning values

  let make llm ?display_name ?family ?released_on ?context_window
      ?max_output_tokens ?default_reasoning ?supported_reasoning
      ?input_modalities ?output_modalities ?capabilities ?pricing
      ?(status = Stable) () =
    check_optional_non_empty "Model.make" "display_name" display_name;
    check_optional_non_empty "Model.make" "family" family;
    check_positive_option "Model.make" "context_window" context_window;
    check_positive_option "Model.make" "max_output_tokens" max_output_tokens;
    let supported_reasoning =
      supported_reasoning |> Option.value ~default:[]
      |> normalize_supported_reasoning
    in
    let input_modalities =
      input_modalities
      |> Option.value ~default:[ Modality.text ]
      |> normalize_modalities "input_modalities"
    in
    let output_modalities =
      output_modalities
      |> Option.value ~default:[ Modality.text ]
      |> normalize_modalities "output_modalities"
    in
    let capabilities =
      capabilities |> Option.value ~default:[] |> normalize_capabilities
    in
    {
      llm;
      display_name;
      family;
      released_on;
      context_window;
      max_output_tokens;
      default_reasoning;
      supported_reasoning;
      input_modalities;
      output_modalities;
      capabilities;
      pricing;
      status;
    }

  let llm t = t.llm
  let provider t = Llm_model.provider t.llm
  let api t = Llm_model.api t.llm
  let id t = Llm_model.id t.llm
  let selector t = Llm_provider.id (provider t) ^ "/" ^ id t
  let display_name t = t.display_name
  let family t = t.family
  let released_on t = t.released_on
  let context_window t = t.context_window
  let max_output_tokens t = t.max_output_tokens
  let default_reasoning t = t.default_reasoning
  let supported_reasoning t = t.supported_reasoning
  let input_modalities t = t.input_modalities
  let output_modalities t = t.output_modalities

  let has_input_modality modality t =
    List.exists (Modality.equal modality) t.input_modalities

  let has_output_modality modality t =
    List.exists (Modality.equal modality) t.output_modalities

  let capabilities t = t.capabilities

  let has_capability capability t =
    List.exists (Capability.equal capability) t.capabilities

  let pricing t = t.pricing

  let cost t usage =
    match t.pricing with
    | None -> None
    | Some pricing ->
        let price =
          price_for
            ~context_tokens:(Spice_llm.Usage.input_total usage)
            pricing
        in
        (* Each disjoint usage lane billed against its rate in [price]. A lane
           that spent nothing costs nothing whatever its rate; a spent lane with
           an unknown rate makes the total unknown. *)
        let lanes =
          [
            (usage.Spice_llm.Usage.input, price.input_per_million);
            (usage.Spice_llm.Usage.cache_read, price.cached_input_per_million);
            (usage.Spice_llm.Usage.cache_write, price.cache_write_5m_per_million);
            (usage.Spice_llm.Usage.output, price.output_per_million);
            (usage.Spice_llm.Usage.reasoning, price.output_per_million);
          ]
        in
        List.fold_left
          (fun acc (tokens, rate) ->
            match acc with
            | None -> None
            | Some total ->
                if tokens = 0 then Some total
                else
                  match rate with
                  | None -> None
                  | Some per_million ->
                      Some
                        (total +. (float_of_int tokens /. 1_000_000. *. per_million)))
          (Some 0.) lanes

  let status t = t.status

  let visible t =
    match t.status with
    | Stable | Preview | Deprecated -> true
    | Unavailable _ -> false

  let selectable t =
    match t.status with
    | Stable | Preview -> true
    | Deprecated | Unavailable _ -> false

  let pp_status ppf = function
    | Stable -> Format.pp_print_string ppf "stable"
    | Preview -> Format.pp_print_string ppf "preview"
    | Deprecated -> Format.pp_print_string ppf "deprecated"
    | Unavailable reason -> Format.fprintf ppf "unavailable(%s)" reason

  let pp ppf t =
    Format.fprintf ppf "%a[%a]" Llm_model.pp t.llm pp_status t.status
end

type t = {
  id : Llm_provider.t;
  display_name : string option;
  auth : Auth.t;
  models : Model.t list;
  default_model : Model.t option;
  dynamic_model : (string -> Model.t option) option;
}

let model_matches llm model = Llm_model.equal llm (Model.llm model)
let declared_model models llm = List.find_opt (model_matches llm) models

let make id ?display_name ?(auth = Auth.none) ?default_model ?dynamic_model
    models =
  check_optional_non_empty "make" "display_name" display_name;
  List.iter
    (fun model ->
      let provider = Llm_model.provider (Model.llm model) in
      if not (Llm_provider.equal id provider) then
        invalid "make" "model provider does not match declaration provider")
    models;
  check_no_duplicates "make" "models" Llm_model.compare
    (List.map Model.llm models);
  check_no_duplicates "make" "model ids" String.compare
    (List.map Model.id models);
  let default_model =
    match default_model with
    | None -> None
    | Some llm -> (
        match declared_model models llm with
        | Some model -> Some model
        | None -> invalid "make" "default_model is not declared")
  in
  { id; display_name; auth; models; default_model; dynamic_model }

let id t = t.id
let display_name t = t.display_name
let auth t = t.auth
let default_model t = t.default_model
let models t = t.models
let model t llm = declared_model t.models llm

let dynamic_model t model_id =
  match t.dynamic_model with
  | None -> None
  | Some synthesize -> synthesize model_id

module Provider_map = Map.Make (struct
  type t = Llm_provider.t

  let compare = Llm_provider.compare
end)

let visible_models ~include_hidden models =
  if include_hidden then models else List.filter Model.visible models

let model_by_id models id =
  List.find_opt (fun model -> String.equal id (Model.id model)) models

module Catalog = struct
  type declaration = t

  type t = {
    providers : declaration list;
    providers_by_id : declaration Provider_map.t;
  }

  module Lookup_error = struct
    type t =
      | Invalid_selector of {
          input : string;
          message : string;
          candidates : string list;
        }
      | Unknown_provider of { provider : Llm_provider.t; known : string list }
      | Unknown_model of {
          provider : Llm_provider.t;
          model : string;
          known : string list;
        }

    let join = function [] -> "none" | values -> String.concat ", " values

    let message = function
      | Invalid_selector { input; message; candidates } ->
          Printf.sprintf "model selector %S is invalid: %s; known models: %s"
            input message (join candidates)
      | Unknown_provider { provider; known } ->
          Printf.sprintf "unknown provider %S; known providers: %s"
            (Llm_provider.id provider) (join known)
      | Unknown_model { provider; model; known } ->
          Printf.sprintf "unknown model %S for provider %S; known models: %s"
            model (Llm_provider.id provider) (join known)

    let pp ppf error = Format.pp_print_string ppf (message error)
  end

  let empty = { providers = []; providers_by_id = Provider_map.empty }

  let add_provider map provider =
    let id = id provider in
    if Provider_map.mem id map then Error id
    else Ok (Provider_map.add id provider map)

  let of_list providers =
    let providers_by_id =
      List.fold_left
        (fun result provider ->
          match result with
          | Error _ -> result
          | Ok map -> add_provider map provider)
        (Ok Provider_map.empty) providers
    in
    Result.map
      (fun providers_by_id -> { providers; providers_by_id })
      providers_by_id

  let providers t = t.providers
  let provider t id = Provider_map.find_opt id t.providers_by_id
  let known_providers t = t.providers |> List.map id |> List.map Llm_provider.id
  let known_models provider = provider.models |> List.map Model.id

  let models ?(include_hidden = false) t =
    t.providers
    |> List.concat_map (fun provider -> provider.models)
    |> visible_models ~include_hidden

  let model_selectors t =
    models ~include_hidden:true t |> List.map Model.selector

  let invalid_selector_candidates t input = function
    | Selector.Error.Empty -> []
    | Selector.Error.Missing_slash ->
        let model_id = String.trim input in
        let exact =
          models ~include_hidden:true t
          |> List.filter (fun model -> String.equal model_id (Model.id model))
          |> List.map Model.selector
        in
        if List.is_empty exact then model_selectors t else exact
    | Selector.Error.Empty_provider | Selector.Error.Empty_model
    | Selector.Error.Invalid_provider _ ->
        model_selectors t

  let models_for ?(include_hidden = false) t provider_id =
    match provider t provider_id with
    | None ->
        Error
          (Lookup_error.Unknown_provider
             { provider = provider_id; known = known_providers t })
    | Some provider -> Ok (visible_models ~include_hidden provider.models)

  let resolve_selector t selector =
    let provider_id = Selector.provider selector in
    match provider t provider_id with
    | None ->
        Error
          (Lookup_error.Unknown_provider
             { provider = provider_id; known = known_providers t })
    | Some provider ->
        let model_id = Selector.id selector in
        begin match model_by_id provider.models model_id with
        | Some model -> Ok model
        | None ->
            Error
              (Lookup_error.Unknown_model
                 {
                   provider = provider_id;
                   model = model_id;
                   known = known_models provider;
                 })
        end

  let resolve t input =
    match Selector.of_string input with
    | Ok selector -> resolve_selector t selector
    | Error reason ->
        Error
          (Lookup_error.Invalid_selector
             {
               input;
               message = Selector.Error.message reason;
               candidates = invalid_selector_candidates t input reason;
             })
end

let pp ppf t =
  Format.fprintf ppf "%a(%d models)" Llm_provider.pp t.id (List.length t.models)
