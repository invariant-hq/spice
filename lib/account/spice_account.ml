(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type timestamp = int64

let invalid fn message = invalid_arg ("Spice_account." ^ fn ^ ": " ^ message)

let check_non_empty fn field = function
  | "" -> invalid fn (field ^ " must not be empty")
  | _ -> ()

let check_optional_non_empty fn field = function
  | None -> ()
  | Some value -> check_non_empty fn field value

let check_optional_non_negative_time fn field = function
  | None -> ()
  | Some value when Int64.compare value 0L >= 0 -> ()
  | Some _ -> invalid fn (field ^ " must not be negative")

let equal_option equal a b =
  match (a, b) with
  | None, None -> true
  | Some a, Some b -> equal a b
  | None, Some _ | Some _, None -> false

let valid_env_name name =
  let len = String.length name in
  let valid_first = function
    | 'A' .. 'Z' | 'a' .. 'z' | '_' -> true
    | _ -> false
  in
  let valid_rest = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  let rec loop index =
    index = len
    || (valid_rest (String.unsafe_get name index) && loop (index + 1))
  in
  len > 0 && valid_first (String.unsafe_get name 0) && loop 1

let check_env_name fn name =
  if not (valid_env_name name) then invalid fn "name is invalid"

let valid_name name =
  let len = String.length name in
  let valid_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' | '.' -> true
    | _ -> false
  in
  let rec loop index =
    index = len
    || (valid_char (String.unsafe_get name index) && loop (index + 1))
  in
  len > 0 && loop 0

let check_name fn name =
  if not (valid_name name) then invalid fn "name is invalid"

module Secret = struct
  module Kind = struct
    type t = Api_key | Bearer | OAuth

    let equal a b =
      match (a, b) with
      | Api_key, Api_key | Bearer, Bearer | OAuth, OAuth -> true
      | Api_key, (Bearer | OAuth)
      | Bearer, (Api_key | OAuth)
      | OAuth, (Api_key | Bearer) ->
          false

    let pp ppf = function
      | Api_key -> Format.pp_print_string ppf "api_key"
      | Bearer -> Format.pp_print_string ppf "bearer"
      | OAuth -> Format.pp_print_string ppf "oauth"
  end

  type t =
    | Api_key of string
    | Bearer of string
    | OAuth of {
        access_token : string;
        refresh_token : string option;
        expires_at : timestamp option;
        account_id : string option;
      }

  let api_key key =
    check_non_empty "Secret.api_key" "key" key;
    Api_key key

  let bearer token =
    check_non_empty "Secret.bearer" "token" token;
    Bearer token

  let oauth ~access_token ?refresh_token ?expires_at ?account_id () =
    check_non_empty "Secret.oauth" "access_token" access_token;
    check_optional_non_empty "Secret.oauth" "refresh_token" refresh_token;
    check_optional_non_empty "Secret.oauth" "account_id" account_id;
    check_optional_non_negative_time "Secret.oauth" "expires_at" expires_at;
    OAuth { access_token; refresh_token; expires_at; account_id }

  let kind = function
    | Api_key _ -> Kind.Api_key
    | Bearer _ -> Kind.Bearer
    | OAuth _ -> Kind.OAuth

  let equal a b =
    match (a, b) with
    | Api_key a, Api_key b | Bearer a, Bearer b -> String.equal a b
    | OAuth a, OAuth b ->
        String.equal a.access_token b.access_token
        && equal_option String.equal a.refresh_token b.refresh_token
        && equal_option Int64.equal a.expires_at b.expires_at
        && equal_option String.equal a.account_id b.account_id
    | Api_key _, (Bearer _ | OAuth _)
    | Bearer _, (Api_key _ | OAuth _)
    | OAuth _, (Api_key _ | Bearer _) ->
        false

  let material_fingerprint material =
    let len = String.length material in
    if len < 8 then None else Some (String.sub material (len - 4) 4)

  let fingerprint = function
    | Api_key key -> material_fingerprint key
    | Bearer token -> material_fingerprint token
    | OAuth { account_id = Some account_id; _ } -> Some account_id
    | OAuth { access_token; account_id = None; _ } ->
        material_fingerprint access_token

  let expires_at = function
    | Api_key _ | Bearer _ -> None
    | OAuth { expires_at; _ } -> expires_at

  let has_refresh_token = function
    | Api_key _ | Bearer _ -> false
    | OAuth { refresh_token; _ } -> Option.is_some refresh_token

  let expose t ~api_key ~bearer ~oauth =
    match t with
    | Api_key key -> api_key ~key
    | Bearer token -> bearer ~token
    | OAuth { access_token; refresh_token; expires_at; account_id } ->
        oauth ~access_token ~refresh_token ~expires_at ~account_id
end

module Credential = struct
  module Name = struct
    type t = string

    let default = "default"

    let make name =
      check_name "Credential.Name.make" name;
      name

    let to_string t = t
    let equal = String.equal
    let compare = String.compare
    let pp ppf t = Format.pp_print_string ppf t
  end

  module Source = struct
    type t = Process | Env of string | Store of Name.t

    let process = Process

    let env name =
      check_env_name "Credential.Source.env" name;
      Env name

    let store ?(name = Name.default) () = Store name
    let tag = function Process -> `Process | Env _ -> `Env | Store _ -> `Store

    let name = function
      | Process -> None
      | Env name -> Some name
      | Store name -> Some (Name.to_string name)

    let equal a b =
      match (a, b) with
      | Process, Process -> true
      | Env a, Env b -> String.equal a b
      | Store a, Store b -> Name.equal a b
      | Process, (Env _ | Store _)
      | Env _, (Process | Store _)
      | Store _, (Process | Env _) ->
          false

    let pp ppf = function
      | Process -> Format.pp_print_string ppf "process"
      | Env name -> Format.fprintf ppf "env(%s)" name
      | Store name -> Format.fprintf ppf "store(%a)" Name.pp name
  end

  type t = {
    provider : Spice_llm.Provider.t;
    source : Source.t;
    secret : Secret.t;
  }

  let make ~provider ~source secret = { provider; source; secret }
  let provider t = t.provider
  let source t = t.source
  let kind t = Secret.kind t.secret
  let fingerprint t = Secret.fingerprint t.secret
  let secret t = t.secret
end

module Source = Credential.Source

let resolve credentials provider =
  List.find_opt
    (fun credential ->
      Spice_llm.Provider.equal provider (Credential.provider credential))
    credentials

let decode_error message = Jsont.Error.msg Jsont.Meta.none message

let decode_invalid_arg f =
  match f () with
  | value -> value
  | exception Invalid_argument message -> decode_error message

let mem name value = Jsont.Json.mem (Jsont.Json.name name) value
let string value = Jsont.Json.string value
let int value = Jsont.Json.int value
let int64 value = Jsont.Json.int64 value

let opt_mem name enc = function
  | None -> []
  | Some value -> [ mem name (enc value) ]

let object_fields kind = function
  | Jsont.Object (fields, _) -> fields
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      decode_error (kind ^ " must be an object")

let field name json =
  match json with
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let has_field name json = Option.is_some (field name json)

let reject_fields kind names json =
  List.iter
    (fun name ->
      if has_field name json then
        decode_error (kind ^ " field " ^ name ^ " is not allowed"))
    names

let optional_string_field kind name json =
  match field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some _ -> decode_error (kind ^ " field " ^ name ^ " must be a string")
  | None -> None

let optional_int_field kind name json =
  match field name json with
  | None -> None
  | Some value -> (
      match Jsont.Json.decode Jsont.int value with
      | Ok value -> Some value
      | Error _ -> decode_error (kind ^ " field " ^ name ^ " must be an integer")
      )

let optional_int64_field kind name json =
  match field name json with
  | None -> None
  | Some value -> (
      match Jsont.Json.decode Jsont.int64 value with
      | Ok value -> Some value
      | Error _ -> decode_error (kind ^ " field " ^ name ^ " must be an integer")
      )

let require_int_field kind name json =
  match optional_int_field kind name json with
  | Some value -> value
  | None -> decode_error (kind ^ " requires integer field " ^ name)

let require_string_field kind name json =
  match optional_string_field kind name json with
  | Some value -> value
  | None -> decode_error (kind ^ " requires string field " ^ name)

let require_object_field kind name json =
  match field name json with
  | Some (Jsont.Object _ as value) -> value
  | Some _ -> decode_error (kind ^ " field " ^ name ^ " must be an object")
  | None -> decode_error (kind ^ " requires object field " ^ name)

let optional_object_field kind name json =
  match field name json with
  | Some (Jsont.Object _ as value) -> Some value
  | Some _ -> decode_error (kind ^ " field " ^ name ^ " must be an object")
  | None -> None

let require_array_field kind name json =
  match field name json with
  | Some (Jsont.Array (values, _)) -> values
  | Some _ -> decode_error (kind ^ " field " ^ name ^ " must be an array")
  | None -> decode_error (kind ^ " requires array field " ^ name)

let unexpected_fields kind allowed json =
  let fields = object_fields kind json in
  List.iter
    (fun ((name, _), _) ->
      if not (List.exists (String.equal name) allowed) then
        decode_error (kind ^ " has unknown field " ^ name))
    fields

let check_unique_fields kind fields =
  let rec loop seen = function
    | [] -> ()
    | ((name, _), _) :: fields ->
        if List.exists (String.equal name) seen then
          decode_error (kind ^ " has duplicate field " ^ name);
        loop (name :: seen) fields
  in
  loop [] fields

let provider_of_string id =
  decode_invalid_arg (fun () -> Spice_llm.Provider.make id)

let secret_kind_to_string = function
  | Secret.Kind.Api_key -> "api_key"
  | Secret.Kind.Bearer -> "bearer"
  | Secret.Kind.OAuth -> "oauth"

let secret_kind_of_string = function
  | "api_key" -> Some Secret.Kind.Api_key
  | "bearer" -> Some Secret.Kind.Bearer
  | "oauth" -> Some Secret.Kind.OAuth
  | _ -> None

let source_to_json = function
  | Source.Process -> Jsont.Json.object' [ mem "kind" (string "process") ]
  | Source.Env name ->
      Jsont.Json.object' [ mem "kind" (string "env"); mem "name" (string name) ]
  | Source.Store name ->
      Jsont.Json.object'
        [
          mem "kind" (string "store");
          mem "name" (string (Credential.Name.to_string name));
        ]

let source_of_json json =
  let kind = require_string_field "credential source" "kind" json in
  match kind with
  | "process" ->
      unexpected_fields "process credential source" [ "kind" ] json;
      Source.process
  | "env" ->
      unexpected_fields "env credential source" [ "kind"; "name" ] json;
      decode_invalid_arg (fun () ->
          Source.env (require_string_field "env credential source" "name" json))
  | "store" ->
      unexpected_fields "store credential source" [ "kind"; "name" ] json;
      decode_invalid_arg (fun () ->
          let name =
            Option.map Credential.Name.make
              (optional_string_field "store credential source" "name" json)
          in
          Source.store ?name ())
  | value -> decode_error ("unknown credential source kind: " ^ value)

let secret_to_json secret =
  Secret.expose secret
    ~api_key:(fun ~key ->
      Jsont.Json.object'
        [ mem "kind" (string "api_key"); mem "api_key" (string key) ])
    ~bearer:(fun ~token ->
      Jsont.Json.object'
        [ mem "kind" (string "bearer"); mem "token" (string token) ])
    ~oauth:(fun ~access_token ~refresh_token ~expires_at ~account_id ->
      Jsont.Json.object'
        ([
           mem "kind" (string "oauth"); mem "access_token" (string access_token);
         ]
        @ opt_mem "refresh_token" string refresh_token
        @ opt_mem "expires_at" int64 expires_at
        @ opt_mem "account_id" string account_id))

let secret_of_json json =
  let kind = require_string_field "secret credential" "kind" json in
  match kind with
  | "api_key" ->
      unexpected_fields "API key secret" [ "kind"; "api_key" ] json;
      decode_invalid_arg (fun () ->
          Secret.api_key (require_string_field "API key secret" "api_key" json))
  | "bearer" ->
      unexpected_fields "bearer secret" [ "kind"; "token" ] json;
      decode_invalid_arg (fun () ->
          Secret.bearer (require_string_field "bearer secret" "token" json))
  | "oauth" ->
      unexpected_fields "OAuth secret"
        [ "kind"; "access_token"; "refresh_token"; "expires_at"; "account_id" ]
        json;
      decode_invalid_arg (fun () ->
          Secret.oauth
            ~access_token:
              (require_string_field "OAuth secret" "access_token" json)
            ?refresh_token:
              (optional_string_field "OAuth secret" "refresh_token" json)
            ?expires_at:(optional_int64_field "OAuth secret" "expires_at" json)
            ?account_id:(optional_string_field "OAuth secret" "account_id" json)
            ())
  | value -> decode_error ("unknown credential kind: " ^ value)

module Store = struct
  type binding = Spice_llm.Provider.t * Credential.Name.t * Secret.t
  type t = { bindings : binding list }

  let empty = { bindings = [] }

  let compare_binding (provider_a, name_a, _) (provider_b, name_b, _) =
    match Spice_llm.Provider.compare provider_a provider_b with
    | 0 -> Credential.Name.compare name_a name_b
    | order -> order

  let same_key provider name (binding_provider, binding_name, _) =
    Spice_llm.Provider.equal provider binding_provider
    && Credential.Name.equal name binding_name

  let check_unique sorted =
    let rec loop = function
      | [] | [ _ ] -> ()
      | (provider, name, _) :: ((next_provider, next_name, _) :: _ as bindings)
        ->
          if
            Spice_llm.Provider.equal provider next_provider
            && Credential.Name.equal name next_name
          then
            invalid "Store.of_list"
              ("duplicate credential "
              ^ Spice_llm.Provider.id provider
              ^ "/"
              ^ Credential.Name.to_string name);
          loop bindings
    in
    loop sorted

  let of_list bindings =
    let sorted = List.sort compare_binding bindings in
    check_unique sorted;
    { bindings = sorted }

  let bindings ?provider t =
    match provider with
    | None -> t.bindings
    | Some provider ->
        List.filter
          (fun (binding_provider, _, _) ->
            Spice_llm.Provider.equal provider binding_provider)
          t.bindings

  let names t ~provider =
    bindings ~provider t |> List.map (fun (_, name, _) -> name)

  let secret t ~provider ?(name = Credential.Name.default) () =
    match List.find_opt (same_key provider name) t.bindings with
    | None -> None
    | Some (_, _, secret) -> Some secret

  let credential t ~provider ?(name = Credential.Name.default) () =
    match secret t ~provider ~name () with
    | None -> None
    | Some secret ->
        let source = Source.store ~name () in
        Some (Credential.make ~provider ~source secret)

  let set ~provider ?(name = Credential.Name.default) secret t =
    let bindings =
      List.filter
        (fun binding -> not (same_key provider name binding))
        t.bindings
    in
    of_list ((provider, name, secret) :: bindings)

  let remove t ~provider ?(name = Credential.Name.default) () =
    {
      bindings =
        List.filter
          (fun binding -> not (same_key provider name binding))
          t.bindings;
    }

  let provider_credentials_to_json t provider =
    bindings ~provider t
    |> List.map (fun (_, name, secret) ->
        mem (Credential.Name.to_string name) (secret_to_json secret))
    |> Jsont.Json.object'

  let store_to_json t =
    let providers =
      t.bindings
      |> List.map (fun (provider, _, _) -> provider)
      |> List.sort_uniq Spice_llm.Provider.compare
    in
    let credentials =
      providers
      |> List.map (fun provider ->
          mem
            (Spice_llm.Provider.id provider)
            (provider_credentials_to_json t provider))
      |> Jsont.Json.object'
    in
    Jsont.Json.object' [ mem "version" (int 1); mem "credentials" credentials ]

  let bindings_of_credentials_json json =
    let fields = object_fields "account store credentials" json in
    check_unique_fields "account store credentials" fields;
    fields
    |> List.map (fun ((provider_id, _), provider_json) ->
        let provider = provider_of_string provider_id in
        let fields =
          object_fields
            ("account store credentials for provider " ^ provider_id)
            provider_json
        in
        check_unique_fields
          ("account store credentials for provider " ^ provider_id)
          fields;
        List.map
          (fun ((name, _), secret_json) ->
            let name =
              decode_invalid_arg (fun () -> Credential.Name.make name)
            in
            (provider, name, secret_of_json secret_json))
          fields)
    |> List.concat

  let store_of_json json =
    unexpected_fields "account store" [ "version"; "credentials" ] json;
    let version = require_int_field "account store" "version" json in
    if version <> 1 then
      decode_error
        ("unsupported account store version: " ^ string_of_int version);
    let bindings =
      json
      |> require_object_field "account store" "credentials"
      |> bindings_of_credentials_json
    in
    decode_invalid_arg (fun () -> of_list bindings)

  let jsont =
    Jsont.map ~kind:"account store" ~dec:store_of_json ~enc:store_to_json
      Jsont.json
end

module Profile = struct
  type t = { id : string option; email : string option; name : string option }

  let make ?id ?email ?name () =
    check_optional_non_empty "Profile.make" "id" id;
    check_optional_non_empty "Profile.make" "email" email;
    check_optional_non_empty "Profile.make" "name" name;
    if Option.is_none id && Option.is_none email && Option.is_none name then
      invalid "Profile.make" "at least one field is required";
    { id; email; name }

  let equal a b =
    equal_option String.equal a.id b.id
    && equal_option String.equal a.email b.email
    && equal_option String.equal a.name b.name

  let pp ppf t =
    Format.fprintf ppf "@[<2>{id=%a; email=%a; name=%a}@]"
      Format.(pp_print_option pp_print_string)
      t.id
      Format.(pp_print_option pp_print_string)
      t.email
      Format.(pp_print_option pp_print_string)
      t.name
end

module Org = struct
  type t = { id : string; name : string option }

  let make ~id ?name () =
    check_non_empty "Org.make" "id" id;
    check_optional_non_empty "Org.make" "name" name;
    { id; name }

  let equal a b =
    String.equal a.id b.id && equal_option String.equal a.name b.name

  let pp ppf t =
    Format.fprintf ppf "@[<2>{id=%s; name=%a}@]" t.id
      Format.(pp_print_option pp_print_string)
      t.name
end

module Problem = struct
  type label = string

  type t =
    | Invalid_credential
    | Expired_credential
    | Refresh_failed
    | Revoked
    | Wrong_account
    | Wrong_organization
    | Rate_limited
    | Quota_exceeded
    | Network
    | Unsupported
    | Other of label

  let valid_label label =
    let len = String.length label in
    let valid_first = function 'a' .. 'z' -> true | _ -> false in
    let valid_rest = function
      | 'a' .. 'z' | '0' .. '9' | '_' -> true
      | _ -> false
    in
    let rec loop index =
      index = len
      || (valid_rest (String.unsafe_get label index) && loop (index + 1))
    in
    len > 0 && valid_first (String.unsafe_get label 0) && loop 1

  let to_string = function
    | Invalid_credential -> "invalid_credential"
    | Expired_credential -> "expired_credential"
    | Refresh_failed -> "refresh_failed"
    | Revoked -> "revoked"
    | Wrong_account -> "wrong_account"
    | Wrong_organization -> "wrong_organization"
    | Rate_limited -> "rate_limited"
    | Quota_exceeded -> "quota_exceeded"
    | Network -> "network"
    | Unsupported -> "unsupported"
    | Other label -> label

  let is_reserved = function
    | "invalid_credential" | "expired_credential" | "refresh_failed" | "revoked"
    | "wrong_account" | "wrong_organization" | "rate_limited" | "quota_exceeded"
    | "network" | "unsupported" ->
        true
    | _ -> false

  let check_other_label fn label =
    if (not (valid_label label)) || is_reserved label then
      invalid fn "label is invalid"

  let other label =
    check_other_label "Problem.other" label;
    Other label

  let check fn = function
    | Other label -> check_other_label fn label
    | Invalid_credential | Expired_credential | Refresh_failed | Revoked
    | Wrong_account | Wrong_organization | Rate_limited | Quota_exceeded
    | Network | Unsupported ->
        ()

  let of_string = function
    | "invalid_credential" -> Some Invalid_credential
    | "expired_credential" -> Some Expired_credential
    | "refresh_failed" -> Some Refresh_failed
    | "revoked" -> Some Revoked
    | "wrong_account" -> Some Wrong_account
    | "wrong_organization" -> Some Wrong_organization
    | "rate_limited" -> Some Rate_limited
    | "quota_exceeded" -> Some Quota_exceeded
    | "network" -> Some Network
    | "unsupported" -> Some Unsupported
    | label when valid_label label && not (is_reserved label) ->
        Some (Other label)
    | _ -> None

  let fatal = function
    | Invalid_credential | Expired_credential | Refresh_failed | Revoked
    | Wrong_account | Wrong_organization ->
        true
    | Rate_limited | Quota_exceeded | Network | Unsupported | Other _ -> false

  let transient = function
    | Network | Rate_limited -> true
    | Invalid_credential | Expired_credential | Refresh_failed | Revoked
    | Wrong_account | Wrong_organization | Quota_exceeded | Unsupported
    | Other _ ->
        false

  let compare a b = String.compare (to_string a) (to_string b)
  let equal a b = compare a b = 0
  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

let normalize_problems fn problems =
  List.iter (Problem.check fn) problems;
  List.sort_uniq Problem.compare problems

type credential_summary = {
  source : Source.t;
  kind : Secret.Kind.t;
  fingerprint : string option;
}

type checked = {
  at : timestamp option;
  profile : Profile.t option;
  org : Org.t option;
  problems : Problem.t list;
  models : string list option;
}

module State = struct
  type t = Missing | Present | Checked

  let to_string = function
    | Missing -> "missing"
    | Present -> "present"
    | Checked -> "checked"

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

type status =
  | Missing_status
  | Present_status of credential_summary
  | Checked_status of credential_summary * checked

type t = { provider : Spice_llm.Provider.t; status : status }
type phase = [ `Missing | `Unchecked | `Ready | `Degraded | `Blocked ]

let phase_to_string = function
  | `Missing -> "missing"
  | `Unchecked -> "unchecked"
  | `Ready -> "ready"
  | `Degraded -> "degraded"
  | `Blocked -> "blocked"

let pp_phase ppf t = Format.pp_print_string ppf (phase_to_string t)

let summary_of_credential credential =
  {
    source = Credential.source credential;
    kind = Credential.kind credential;
    fingerprint = Credential.fingerprint credential;
  }

let missing ~provider = { provider; status = Missing_status }

let present credential =
  {
    provider = Credential.provider credential;
    status = Present_status (summary_of_credential credential);
  }

let checked credential ?at ?profile ?org ?(problems = []) ?models () =
  check_optional_non_negative_time "checked" "at" at;
  {
    provider = Credential.provider credential;
    status =
      Checked_status
        ( summary_of_credential credential,
          {
            at;
            profile;
            org;
            problems = normalize_problems "checked" problems;
            models = Option.map (List.sort_uniq String.compare) models;
          } );
  }

let provider t = t.provider

let state t =
  match t.status with
  | Missing_status -> State.Missing
  | Present_status _ -> State.Present
  | Checked_status _ -> State.Checked

let credential t =
  match t.status with
  | Missing_status -> None
  | Present_status credential | Checked_status (credential, _) ->
      Some credential

let checked_facts t =
  match t.status with
  | Missing_status | Present_status _ -> None
  | Checked_status (_, checked) -> Some checked

let source t = Option.map (fun credential -> credential.source) (credential t)

let credential_kind t =
  Option.map (fun credential -> credential.kind) (credential t)

let fingerprint t =
  Option.bind (credential t) (fun credential -> credential.fingerprint)

let checked_at t = Option.bind (checked_facts t) (fun checked -> checked.at)
let profile t = Option.bind (checked_facts t) (fun checked -> checked.profile)
let org t = Option.bind (checked_facts t) (fun checked -> checked.org)

let problems t =
  match checked_facts t with None -> [] | Some checked -> checked.problems

let models t = Option.bind (checked_facts t) (fun checked -> checked.models)

let model_available t model =
  match models t with
  | None -> `Unknown
  | Some models ->
      if List.exists (String.equal model) models then `Available
      else `Unavailable

let phase t =
  match t.status with
  | Missing_status -> `Missing
  | Present_status _ -> `Unchecked
  | Checked_status (_, { problems = []; _ }) -> `Ready
  | Checked_status (_, { problems; _ }) ->
      if List.exists Problem.fatal problems then `Blocked else `Degraded

let equal_credential_summary a b =
  Source.equal a.source b.source
  && Secret.Kind.equal a.kind b.kind
  && equal_option String.equal a.fingerprint b.fingerprint

let equal_checked a b =
  equal_option Int64.equal a.at b.at
  && equal_option Profile.equal a.profile b.profile
  && equal_option Org.equal a.org b.org
  && List.equal Problem.equal a.problems b.problems
  && equal_option (List.equal String.equal) a.models b.models

let equal_status a b =
  match (a, b) with
  | Missing_status, Missing_status -> true
  | Present_status a, Present_status b -> equal_credential_summary a b
  | ( Checked_status (a_credential, a_checked),
      Checked_status (b_credential, b_checked) ) ->
      equal_credential_summary a_credential b_credential
      && equal_checked a_checked b_checked
  | (Missing_status | Present_status _ | Checked_status _), _ -> false

let equal a b =
  Spice_llm.Provider.equal a.provider b.provider
  && equal_status a.status b.status

let pp_timestamp ppf timestamp = Format.fprintf ppf "%Ld" timestamp

let pp_credential_summary ppf t =
  Format.fprintf ppf "@[<2>{source=%a; kind=%a; fingerprint=%a}@]" Source.pp
    t.source Secret.Kind.pp t.kind
    Format.(pp_print_option pp_print_string)
    t.fingerprint

let pp_problems ppf problems =
  Format.(
    pp_print_list
      ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
      Problem.pp)
    ppf problems

let pp_models ppf models =
  Format.(
    pp_print_option
      (pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         pp_print_string))
    ppf models

let pp_checked ppf checked =
  Format.fprintf ppf
    "@[<2>{at=%a; profile=%a; org=%a; problems=[%a]; models=%a}@]"
    Format.(pp_print_option pp_timestamp)
    checked.at
    Format.(pp_print_option Profile.pp)
    checked.profile
    Format.(pp_print_option Org.pp)
    checked.org pp_problems checked.problems pp_models checked.models

let pp ppf t =
  match t.status with
  | Missing_status ->
      Format.fprintf ppf "@[<2>{provider=%a; state=missing}@]"
        Spice_llm.Provider.pp t.provider
  | Present_status credential ->
      Format.fprintf ppf "@[<2>{provider=%a; state=present; credential=%a}@]"
        Spice_llm.Provider.pp t.provider pp_credential_summary credential
  | Checked_status (credential, checked) ->
      Format.fprintf ppf
        "@[<2>{provider=%a; state=checked; credential=%a; checked=%a}@]"
        Spice_llm.Provider.pp t.provider pp_credential_summary credential
        pp_checked checked

let profile_to_json profile =
  Jsont.Json.object'
    (opt_mem "id" string profile.Profile.id
    @ opt_mem "email" string profile.Profile.email
    @ opt_mem "name" string profile.Profile.name)

let profile_of_json json =
  unexpected_fields "account profile" [ "id"; "email"; "name" ] json;
  decode_invalid_arg (fun () ->
      Profile.make
        ?id:(optional_string_field "account profile" "id" json)
        ?email:(optional_string_field "account profile" "email" json)
        ?name:(optional_string_field "account profile" "name" json)
        ())

let org_to_json org =
  Jsont.Json.object'
    ([ mem "id" (string org.Org.id) ] @ opt_mem "name" string org.Org.name)

let org_of_json json =
  unexpected_fields "account organization" [ "id"; "name" ] json;
  decode_invalid_arg (fun () ->
      Org.make
        ~id:(require_string_field "account organization" "id" json)
        ?name:(optional_string_field "account organization" "name" json)
        ())

let problem_to_json problem = string (Problem.to_string problem)

let problem_of_json = function
  | Jsont.String (label, _) -> (
      match Problem.of_string label with
      | Some problem -> problem
      | None -> decode_error ("invalid account problem label: " ^ label))
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
  | Jsont.Array _ ->
      decode_error "account problem must be a string"

let problems_to_json problems =
  Jsont.Json.list (List.map problem_to_json problems)

let problems_of_json values = List.map problem_of_json values
let string_list_to_json values = Jsont.Json.list (List.map string values)

let string_list_of_json kind = function
  | Jsont.Array (values, _) ->
      List.map
        (function
          | Jsont.String (value, _) -> value
          | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
          | Jsont.Array _ ->
              decode_error (kind ^ " must be an array of strings"))
        values
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Object _ ->
      decode_error (kind ^ " must be an array")

let optional_string_list_field kind name json =
  match field name json with
  | None -> None
  | Some value -> Some (string_list_of_json (kind ^ " field " ^ name) value)

let credential_summary_to_json_fields summary =
  [
    mem "source" (source_to_json summary.source);
    mem "credential_kind" (string (secret_kind_to_string summary.kind));
  ]
  @ opt_mem "fingerprint" string summary.fingerprint

let credential_summary_of_json_fields context json =
  let source = source_of_json (require_object_field context "source" json) in
  let kind =
    match require_string_field context "credential_kind" json with
    | label -> (
        match secret_kind_of_string label with
        | Some kind -> kind
        | None -> decode_error ("unknown credential kind: " ^ label))
  in
  {
    source;
    kind;
    fingerprint = optional_string_field context "fingerprint" json;
  }

let checked_at_of_json kind json =
  let checked_at = optional_int64_field kind "checked_at" json in
  match checked_at with
  | None -> None
  | Some value when Int64.compare value 0L >= 0 -> checked_at
  | Some _ -> decode_error (kind ^ " checked_at must not be negative")

let account_to_json t =
  match t.status with
  | Missing_status ->
      Jsont.Json.object'
        [
          mem "version" (int 1);
          mem "provider" (string (Spice_llm.Provider.id t.provider));
          mem "state" (string "missing");
        ]
  | Present_status credential ->
      Jsont.Json.object'
        ([
           mem "version" (int 1);
           mem "provider" (string (Spice_llm.Provider.id t.provider));
           mem "state" (string "present");
         ]
        @ credential_summary_to_json_fields credential)
  | Checked_status (credential, checked) ->
      Jsont.Json.object'
        ([
           mem "version" (int 1);
           mem "provider" (string (Spice_llm.Provider.id t.provider));
           mem "state" (string "checked");
           mem "problems" (problems_to_json checked.problems);
         ]
        @ credential_summary_to_json_fields credential
        @ opt_mem "checked_at" int64 checked.at
        @ opt_mem "profile" profile_to_json checked.profile
        @ opt_mem "org" org_to_json checked.org
        @ opt_mem "models" string_list_to_json checked.models)

let account_of_json json =
  unexpected_fields "account"
    [
      "version";
      "provider";
      "state";
      "source";
      "credential_kind";
      "fingerprint";
      "checked_at";
      "profile";
      "org";
      "problems";
      "models";
    ]
    json;
  let provider =
    provider_of_string (require_string_field "account" "provider" json)
  in
  let version = require_int_field "account" "version" json in
  if version <> 1 then
    decode_error ("unsupported account version: " ^ string_of_int version);
  match require_string_field "account" "state" json with
  | "missing" ->
      reject_fields "missing account"
        [
          "source";
          "credential_kind";
          "fingerprint";
          "checked_at";
          "profile";
          "org";
          "problems";
          "models";
        ]
        json;
      missing ~provider
  | "present" ->
      reject_fields "present account"
        [ "checked_at"; "profile"; "org"; "problems"; "models" ]
        json;
      {
        provider;
        status =
          Present_status (credential_summary_of_json_fields "account" json);
      }
  | "checked" ->
      let credential = credential_summary_of_json_fields "account" json in
      let problems =
        require_array_field "account" "problems" json
        |> problems_of_json |> normalize_problems "jsont"
      in
      {
        provider;
        status =
          Checked_status
            ( credential,
              {
                at = checked_at_of_json "account" json;
                profile =
                  Option.map profile_of_json
                    (optional_object_field "account" "profile" json);
                org =
                  Option.map org_of_json
                    (optional_object_field "account" "org" json);
                problems;
                models =
                  Option.map
                    (List.sort_uniq String.compare)
                    (optional_string_list_field "account" "models" json);
              } );
      }
  | state -> decode_error ("unknown account state: " ^ state)

let jsont =
  Jsont.map ~kind:"account" ~dec:account_of_json ~enc:account_to_json Jsont.json
