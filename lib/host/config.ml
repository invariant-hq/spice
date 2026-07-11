(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

let log_src = Logs.Src.create "spice.host.config" ~doc:"Configuration assembly"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Error = struct
  type t = { message : string; hints : string list }

  let message t = t.message
  let hints t = t.hints
  let diagnostic t = Spice_diagnostic.of_text ~hints:t.hints t.message
  let pp ppf t = Format.pp_print_string ppf t.message
end

let error_t ?(hints = []) message = { Error.message; hints }
let error ?hints message = Error (error_t ?hints message)

module Reasoning_effort = Spice_llm.Request.Options.Reasoning_effort

let invalid_provider_id id message =
  let message =
    List.fold_left
      (fun message prefix ->
        if String.starts_with ~prefix message then
          String.drop_first (String.length prefix) message
        else message)
      message
      [ "Spice_llm.Provider.make: "; "Spice_llm.Provider.make: " ]
  in
  error (Printf.sprintf "invalid provider id %S: %s" id message)

(* [decode_enum ~what ~all ~to_string of_string value] parses a closed enum from
   user text. On failure the hints list an [all]-ordered candidate set plus a
   {!Spice_diagnostic.did_you_mean} nudge, and the message reads
   [unknown <what>: <value>]. The exact wording is a pinned diagnostic contract
   (config cram [errors.t]); do not alter it. *)
let decode_enum ~what ~all ~to_string of_string value =
  match of_string value with
  | Some x -> Ok x
  | None ->
      let allowed = List.map to_string all in
      error
        ~hints:
          (("expected one of: " ^ String.concat ", " allowed)
          :: Spice_diagnostic.did_you_mean value ~candidates:allowed)
        ("unknown " ^ what ^ ": " ^ value)

let permission_mode_of_string =
  decode_enum ~what:"permission mode" ~all:Permission.Preset.all
    ~to_string:Permission.Preset.to_string Permission.Preset.of_string

(* Bypass is a per-invocation flag: no durable channel (config file or
   environment) may set it, or an escalation would survive restarts. Only the
   [--permission-mode] CLI flag reaches [Preset.Bypass]. *)
let durable_permission_mode_of_string name value =
  let* mode = permission_mode_of_string value in
  match mode with
  | Permission.Preset.Bypass ->
      error
        ~hints:[ "pass --permission-mode bypass for one run" ]
        (name ^ " must not be bypass")
  | Permission.Preset.Default | Permission.Preset.Accept_edits
  | Permission.Preset.Plan ->
      Ok mode

let permission_unattended_of_string =
  decode_enum ~what:"permission unattended policy"
    ~all:Permission.Unattended.all ~to_string:Permission.Unattended.to_string
    Permission.Unattended.of_string

let sandbox_mode_of_string =
  decode_enum ~what:"sandbox mode" ~all:Sandbox.Mode.all
    ~to_string:Sandbox.Mode.to_string Sandbox.Mode.of_string

let sandbox_require_of_string =
  decode_enum ~what:"sandbox requirement" ~all:Sandbox.Require.all
    ~to_string:Sandbox.Require.to_string Sandbox.Require.of_string

let sandbox_network_of_string =
  decode_enum ~what:"sandbox network" ~all:Sandbox.Network.all
    ~to_string:Sandbox.Network.to_string Sandbox.Network.of_string

let reasoning_effort_of_string =
  decode_enum ~what:"reasoning effort" ~all:Reasoning_effort.all
    ~to_string:Reasoning_effort.to_string Reasoning_effort.of_string

(* [tools.editor] and [web.search_backend] are closed-vocabulary string fields:
   their domain value stays a validated string. The [decode_enum] machinery over
   the identity codec keeps the pinned error wording. *)
let string_enum_of_string ~what ~spellings value =
  decode_enum ~what ~all:spellings ~to_string:Fun.id
    (fun v -> if List.mem v spellings then Some v else None)
    value

let tools_editor_spellings = [ "auto"; "apply-patch"; "string-replace" ]
let web_search_backend_spellings = [ "disabled"; "brave" ]
let workspace_tooling_spellings = [ "auto"; "on"; "off" ]

let tools_editor_of_string =
  string_enum_of_string ~what:"tools editor" ~spellings:tools_editor_spellings

let web_search_backend_of_string =
  string_enum_of_string ~what:"web search backend"
    ~spellings:web_search_backend_spellings

let workspace_tooling_of_string =
  string_enum_of_string ~what:"workspace tooling mode"
    ~spellings:workspace_tooling_spellings

let with_error_context context = function
  | Ok _ as ok -> ok
  | Error error ->
      Error
        (error_t ~hints:(Error.hints error)
           (context ^ ": " ^ Error.message error))

let absolute_path_jsont =
  Jsont.map ~kind:"absolute path"
    ~dec:(fun raw ->
      match Spice_path.Abs.of_string raw with
      | Ok path -> path
      | Error error ->
          Jsont.Error.msg Jsont.Meta.none (Spice_path.Error.message error))
    ~enc:Spice_path.Abs.to_string Jsont.string

module Source = struct
  type t =
    | User of { path : Spice_path.Abs.t }
    | Project of { path : Spice_path.Abs.t }
    | Project_local of { path : Spice_path.Abs.t }
    | Extra_file of { path : Spice_path.Abs.t }
    | Env of { name : string }
    | Override
    | Default of { reason : string }

  let path_string = Spice_path.Abs.to_string

  let pp ppf = function
    | User { path } -> Format.fprintf ppf "user %s" (path_string path)
    | Project { path } -> Format.fprintf ppf "project %s" (path_string path)
    | Project_local { path } ->
        Format.fprintf ppf "project-local %s" (path_string path)
    | Extra_file { path } ->
        Format.fprintf ppf "extra-file %s" (path_string path)
    | Env { name } -> Format.fprintf ppf "env %s" name
    | Override -> Format.pp_print_string ppf "override"
    | Default { reason } -> Format.fprintf ppf "default %s" reason

  let kind_string = function
    | User _ -> "user"
    | Project _ -> "project"
    | Project_local _ -> "project-local"
    | Extra_file _ -> "extra"
    | Env _ -> "env"
    | Override -> "override"
    | Default _ -> "preset"

  (* The single-[path] cases; [enc_case] routes each to its own encoder, so the
     other constructors are unreachable. *)
  let source_path = function
    | User { path }
    | Project { path }
    | Project_local { path }
    | Extra_file { path } ->
        path
    | Env _ | Override | Default _ -> assert false

  let jsont =
    let path_case ~kind ~name make =
      Jsont.Object.map ~kind make
      |> Jsont.Object.mem "path" absolute_path_jsont ~enc:source_path
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map name ~dec:Fun.id
    in
    let user =
      path_case ~kind:"user config source" ~name:"user" (fun path ->
          User { path })
    in
    let project =
      path_case ~kind:"project config source" ~name:"project" (fun path ->
          Project { path })
    in
    let project_local =
      path_case ~kind:"project-local config source" ~name:"project_local"
        (fun path -> Project_local { path })
    in
    let extra_file =
      path_case ~kind:"extra config source" ~name:"extra_file" (fun path ->
          Extra_file { path })
    in
    let env =
      Jsont.Object.map ~kind:"env config source" (fun name -> Env { name })
      |> Jsont.Object.mem "name" Jsont.string ~enc:(function
        | Env { name } -> name
        | User _ | Project _ | Project_local _ | Extra_file _ | Override
        | Default _ ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "env" ~dec:Fun.id
    in
    let override =
      Jsont.Object.map ~kind:"override config source" Override
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "override" ~dec:Fun.id
    in
    let default =
      Jsont.Object.map ~kind:"default config source" (fun reason ->
          Default { reason })
      |> Jsont.Object.mem "reason" Jsont.string ~enc:(function
        | Default { reason } -> reason
        | User _ | Project _ | Project_local _ | Extra_file _ | Env _ | Override
          ->
            assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "default" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ user; project; project_local; extra_file; env; override; default ]
    in
    let enc_case = function
      | User _ as source -> Jsont.Object.Case.value user source
      | Project _ as source -> Jsont.Object.Case.value project source
      | Project_local _ as source ->
          Jsont.Object.Case.value project_local source
      | Extra_file _ as source -> Jsont.Object.Case.value extra_file source
      | Env _ as source -> Jsont.Object.Case.value env source
      | Override as source -> Jsont.Object.Case.value override source
      | Default _ as source -> Jsont.Object.Case.value default source
    in
    Jsont.Object.map ~kind:"config source" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Origin = struct
  type t = { source : Source.t; shadowed : Source.t list }

  let make ~source ~shadowed = { source; shadowed }
  let source t = t.source
  let shadowed t = t.shadowed

  let pp ppf t =
    match t.shadowed with
    | [] -> Source.pp ppf t.source
    | shadowed ->
        Format.fprintf ppf "%a; overrides: %a" Source.pp t.source
          Format.(
            pp_print_list
              ~pp_sep:(fun ppf () -> pp_print_string ppf ", ")
              Source.pp)
          shadowed

  let jsont =
    Jsont.Object.map ~kind:"config origin" (fun source shadowed ->
        make ~source ~shadowed)
    |> Jsont.Object.mem "source" Source.jsont ~enc:source
    |> Jsont.Object.mem "shadowed" (Jsont.list Source.jsont) ~enc:shadowed
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let env_non_empty getenv name =
  match getenv name with
  | Some value when not (String.is_empty value) -> Some value
  | Some _ | None -> None

let default_shell_program getenv =
  if String.equal Filename.dir_sep "\\" then
    Option.value (env_non_empty getenv "COMSPEC") ~default:"cmd"
  else Option.value (env_non_empty getenv "SHELL") ~default:"/bin/sh"

let max_json_safe_int = 9_007_199_254_740_991
let max_json_safe_int_float = 9_007_199_254_740_991.

let check_positive_int field value =
  if value <= 0 then error (field ^ " must be positive")
  else if value > max_json_safe_int then
    error (field ^ " must be at most " ^ string_of_int max_json_safe_int)
  else Ok value

let json_number_to_positive_int field value =
  if not (Float.is_integer value) then error (field ^ " must be an integer")
  else if value <= 0. then error (field ^ " must be positive")
  else if value > max_json_safe_int_float then
    error (field ^ " must be at most " ^ string_of_int max_json_safe_int)
  else Ok (int_of_float value)

let default_instructions_project_max_bytes = 32 * 1024
let default_skills_catalog_max_bytes = 8 * 1024
let default_web_fetch_max_bytes = 5 * 1024 * 1024
let default_web_output_max_chars = 100_000
let default_web_timeout_ms = 30_000
let default_web_max_timeout_ms = 120_000

let parse_selector field raw =
  let raw = String.trim raw in
  match Spice_provider.Selector.of_string raw with
  | Ok _ -> Ok raw
  | Error e -> error (field ^ " " ^ Spice_provider.Selector.Error.message e)

let json_mem name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_object_fields = function
  | Jsont.Object (fields, _) -> Some fields
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_string = function Jsont.String (value, _) -> Some value | _ -> None

(* JSON leaf decoders shared by file loading and validation. [label] is the
   error-label prefix, for example "<source> run.max_steps". *)

let decode_string_leaf label leaf =
  match json_string leaf with
  | Some "" -> error (label ^ " must not be empty")
  | Some value -> Ok value
  | None -> error (label ^ " must be a string")

let decode_selector_leaf label leaf =
  match json_string leaf with
  | Some "" -> error (label ^ " must not be empty")
  | Some raw -> parse_selector label raw
  | None -> error (label ^ " must be a string")

let decode_vocab_leaf label of_string leaf =
  match json_string leaf with
  | Some value -> with_error_context label (of_string value)
  | None -> error (label ^ " must be a string")

let decode_bool_leaf label = function
  | Jsont.Bool (value, _) -> Ok value
  | Jsont.Null _ | Jsont.Number _ | Jsont.String _ | Jsont.Object _
  | Jsont.Array _ ->
      error (label ^ " must be a boolean")

let decode_positive_int_leaf label = function
  | Jsont.Number (value, _) -> json_number_to_positive_int label value
  | Jsont.Null _ | Jsont.Bool _ | Jsont.String _ | Jsont.Object _
  | Jsont.Array _ ->
      error (label ^ " must be an integer")

let json_null = Jsont.Json.null ()

let json_of_string_list values =
  Jsont.Json.list (List.map (fun value -> Jsont.Json.string value) values)

let string_list_to_text values =
  match Jsont_bytesrw.encode_string Jsont.json (json_of_string_list values) with
  | Ok text -> text
  | Error message -> invalid_arg message

let decode_string_list_leaf label = function
  | Jsont.Array (elements, _) ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | element :: rest ->
            let* value = decode_string_leaf label element in
            collect (value :: acc) rest
      in
      collect [] elements
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Object _ ->
      error (label ^ " must be a JSON array of strings")

let parse_string key raw =
  if String.is_empty raw then error (key ^ " must not be empty") else Ok raw

let parse_int key raw =
  match int_of_string_opt raw with
  | None -> error (key ^ " must be an integer")
  | Some value -> check_positive_int key value

let parse_bool key raw =
  match raw with
  | "true" -> Ok true
  | "false" -> Ok false
  | _ -> error (key ^ " must be true or false")

let parse_string_list key raw =
  match Jsont_bytesrw.decode_string Jsont.json raw with
  | Error _ ->
      error
        (key ^ " must be a JSON array of strings, for example [\"/a\", \"/b\"]")
  | Ok json -> decode_string_list_leaf key json

(* [ocaml.merlin_program] is an argv prefix that reaches the Merlin transport
   and its execution permission. An empty list or an empty/NUL token would raise
   [Invalid_argument] mid-call there instead of refusing cleanly, so reject both
   at parse. *)
let validate_merlin_program key = function
  | [] -> error (key ^ " must not be empty")
  | values ->
      if
        List.exists
          (fun v -> String.is_empty v || String.contains v '\000')
          values
      then error (key ^ " elements must be non-empty and must not contain NUL")
      else Ok values

(* One [Type.Id.t] per domain type. Typed field reads recover a stored value's
   type by comparing the id of the queried field with the id of the field that
   stored it; the two ids are physically the same whenever the field names match
   (see {!Layer.get_field}), so a shared per-type id is sufficient and no
   per-field witness is needed. *)
let string_id : string Type.Id.t = Type.Id.make ()
let bool_id : bool Type.Id.t = Type.Id.make ()
let int_id : int Type.Id.t = Type.Id.make ()
let reasoning_id : Reasoning_effort.t Type.Id.t = Type.Id.make ()
let preset_id : Permission.Preset.t Type.Id.t = Type.Id.make ()
let unattended_id : Permission.Unattended.t Type.Id.t = Type.Id.make ()
let mode_id : Sandbox.Mode.t Type.Id.t = Type.Id.make ()
let require_id : Sandbox.Require.t Type.Id.t = Type.Id.make ()
let network_id : Sandbox.Network.t Type.Id.t = Type.Id.make ()
let string_list_id : string list Type.Id.t = Type.Id.make ()

(* A codec is the value-shape half of a field: how its domain value renders and
   parses as text (CLI [get]/[set]) and as a JSON leaf (file load/write), plus
   the equality and type witness the layer needs. Environment parsing, the
   built-in default, and the workspace-shared flag are per-field and live on the
   {!spec}. *)
type 'a codec = {
  type_id : 'a Type.Id.t;
  equal : 'a -> 'a -> bool;
  to_text : 'a -> string;
  parse_text : label:string -> string -> ('a, Error.t) result;
  encode_json : 'a -> Jsont.json;
  decode_json : label:string -> Jsont.json -> ('a, Error.t) result;
  values : string list option;
      (* The closed vocabulary [parse_text] and [decode_json] accept, in
         presentation order, or [None] when the codec parses an open shape
         (free strings, integers, lists). This is the single source for a
         field's allowed spellings: it lives on the codec beside the parser,
         so a value drawn from it always validates. *)
}

let string_codec =
  {
    type_id = string_id;
    equal = String.equal;
    to_text = Fun.id;
    parse_text = (fun ~label raw -> parse_string label raw);
    encode_json = (fun value -> Jsont.Json.string value);
    decode_json = (fun ~label leaf -> decode_string_leaf label leaf);
    values = None;
  }

let selector_codec =
  {
    type_id = string_id;
    equal = String.equal;
    to_text = Fun.id;
    parse_text = (fun ~label raw -> parse_selector label raw);
    encode_json = (fun value -> Jsont.Json.string value);
    decode_json = (fun ~label leaf -> decode_selector_leaf label leaf);
    values = None;
  }

let bool_codec =
  {
    type_id = bool_id;
    equal = Bool.equal;
    to_text = string_of_bool;
    parse_text = (fun ~label raw -> parse_bool label raw);
    encode_json = (fun value -> Jsont.Json.bool value);
    decode_json = (fun ~label leaf -> decode_bool_leaf label leaf);
    values = Some [ "true"; "false" ];
  }

let int_codec =
  {
    type_id = int_id;
    equal = Int.equal;
    to_text = string_of_int;
    parse_text = (fun ~label raw -> parse_int label raw);
    encode_json = (fun value -> Jsont.Json.int value);
    decode_json = (fun ~label leaf -> decode_positive_int_leaf label leaf);
    values = None;
  }

let string_list_codec =
  {
    type_id = string_list_id;
    equal = List.equal String.equal;
    to_text = string_list_to_text;
    parse_text = (fun ~label raw -> parse_string_list label raw);
    encode_json = json_of_string_list;
    decode_json = (fun ~label leaf -> decode_string_list_leaf label leaf);
    values = None;
  }

let validate_sandbox_writable_roots label values =
  let valid spelling =
    String.equal spelling "~"
    || (String.length spelling >= 2 && String.sub spelling 0 2 = "~/")
    || Result.is_ok (Spice_path.Abs.of_string spelling)
  in
  let rec loop index = function
    | [] -> Ok values
    | spelling :: rest ->
        if valid spelling then loop (index + 1) rest
        else
          error
            (Printf.sprintf
               "%s[%d] must be absolute, \"~\", or start with \"~/\"" label
               index)
  in
  loop 0 values

let sandbox_writable_roots_codec =
  {
    string_list_codec with
    parse_text =
      (fun ~label raw ->
        let* values = parse_string_list label raw in
        validate_sandbox_writable_roots label values);
    decode_json =
      (fun ~label leaf ->
        let* values = decode_string_list_leaf label leaf in
        validate_sandbox_writable_roots label values);
  }

let merlin_codec =
  {
    string_list_codec with
    parse_text =
      (fun ~label raw ->
        let* values = parse_string_list label raw in
        validate_merlin_program label values);
    decode_json =
      (fun ~label leaf ->
        let* values = decode_string_list_leaf label leaf in
        validate_merlin_program label values);
  }

(* A closed enum whose domain value has a dedicated type. [to_text]/[of_text]
   are the enum's spellings; the file decoder prefixes errors with the field
   label, while the text parser leaves the bare [unknown <what>: <value>]. *)
(* [values] enumerates the enum's spellings, in [all] order, so a vocab
   codec's allowed set is derived from the same [all]/[to_text] the parser
   validates against — no separate spelling table to drift. *)
let vocab_codec ~type_id ~equal ~to_text ~all ~of_text =
  {
    type_id;
    equal;
    to_text;
    parse_text = (fun ~label:_ raw -> of_text raw);
    encode_json = (fun value -> Jsont.Json.string (to_text value));
    decode_json = (fun ~label leaf -> decode_vocab_leaf label of_text leaf);
    values = Some (List.map to_text all);
  }

let reasoning_codec =
  vocab_codec ~type_id:reasoning_id ~equal:( = )
    ~to_text:Reasoning_effort.to_string ~all:Reasoning_effort.all
    ~of_text:reasoning_effort_of_string

let unattended_codec =
  vocab_codec ~type_id:unattended_id ~equal:Permission.Unattended.equal
    ~to_text:Permission.Unattended.to_string ~all:Permission.Unattended.all
    ~of_text:permission_unattended_of_string

let sandbox_mode_codec =
  vocab_codec ~type_id:mode_id ~equal:Sandbox.Mode.equal
    ~to_text:Sandbox.Mode.to_string ~all:Sandbox.Mode.all
    ~of_text:sandbox_mode_of_string

let sandbox_require_codec =
  vocab_codec ~type_id:require_id ~equal:Sandbox.Require.equal
    ~to_text:Sandbox.Require.to_string ~all:Sandbox.Require.all
    ~of_text:sandbox_require_of_string

let sandbox_network_codec =
  vocab_codec ~type_id:network_id ~equal:Sandbox.Network.equal
    ~to_text:Sandbox.Network.to_string ~all:Sandbox.Network.all
    ~of_text:sandbox_network_of_string

(* The presets [permission.mode] accepts on a durable channel, in preset
   order: exactly those {!durable_permission_mode_of_string} does not reject,
   so the exposed vocabulary can never claim a spelling the parser refuses
   (bypass is per-invocation only). *)
let durable_preset_spellings =
  List.filter_map
    (fun preset ->
      let spelling = Permission.Preset.to_string preset in
      match durable_permission_mode_of_string "permission.mode" spelling with
      | Ok _ -> Some spelling
      | Error _ -> None)
    Permission.Preset.all

(* [permission.mode] rejects the bypass preset on every durable channel and
   names the channel in the message, so its text parser and file decoder both
   thread the label through {!durable_permission_mode_of_string}. *)
let permission_mode_codec =
  {
    type_id = preset_id;
    equal = Permission.Preset.equal;
    to_text = Permission.Preset.to_string;
    parse_text = (fun ~label raw -> durable_permission_mode_of_string label raw);
    encode_json =
      (fun value -> Jsont.Json.string (Permission.Preset.to_string value));
    decode_json =
      (fun ~label leaf ->
        decode_vocab_leaf label (durable_permission_mode_of_string label) leaf);
    values = Some durable_preset_spellings;
  }

(* A closed enum kept as a validated string, with no dedicated domain type.
   [spellings] is both the accepted set and the exposed vocabulary. *)
let string_enum_codec ~spellings of_text =
  {
    type_id = string_id;
    equal = String.equal;
    to_text = Fun.id;
    parse_text = (fun ~label:_ raw -> of_text raw);
    encode_json = (fun value -> Jsont.Json.string value);
    decode_json = (fun ~label leaf -> decode_vocab_leaf label of_text leaf);
    values = Some spellings;
  }

let tools_editor_codec =
  string_enum_codec ~spellings:tools_editor_spellings tools_editor_of_string

let web_search_backend_codec =
  string_enum_codec ~spellings:web_search_backend_spellings
    web_search_backend_of_string

let workspace_tooling_codec =
  string_enum_codec ~spellings:workspace_tooling_spellings
    workspace_tooling_of_string

module Field = struct
  type 'a t =
    | Model : string t
    | Small_model : string t
    | Reasoning : Reasoning_effort.t t
    | Tui_thinking : bool t
    | Provider_base_url : Spice_llm.Provider.t -> string t
    | Run_max_steps : int t
    | Run_subagent_max_concurrent : int t
    | Run_subagent_max_depth : int t
    | Run_subagent_wake : bool t
    | Run_subagent_max_exchanges : int t
    | Permission_mode : Permission.Preset.t t
    | Permission_unattended : Permission.Unattended.t t
    | Sandbox_mode : Sandbox.Mode.t t
    | Sandbox_require : Sandbox.Require.t t
    | Sandbox_writable_roots : string list t
    | Sandbox_network : Sandbox.Network.t t
    | Sandbox_toolchain_caches : bool t
    | Shell : string t
    | Compaction_auto : bool t
    | Notices_fswatch : bool t
    | Notices_cr_comments : bool t
    | Notices_dune_diagnostics : bool t
    | Notices_dune_build : bool t
    | Workspace_tooling : string t
    | Instructions_global : bool t
    | Instructions_project : bool t
    | Instructions_claude_md : bool t
    | Instructions_project_max_bytes : int t
    | Skills_enabled : bool t
    | Skills_builtin : bool t
    | Skills_project : bool t
    | Skills_compat : bool t
    | Skills_disabled : string list t
    | Skills_paths : string list t
    | Skills_catalog_max_bytes : int t
    | Tools_anchored_edits : bool t
    | Tools_editor : string t
    | Ocaml_merlin_program : string list t
    | Web_enabled : bool t
    | Web_allow_private_network : bool t
    | Web_search_backend : string t
    | Web_fetch_max_bytes : int t
    | Web_output_max_chars : int t
    | Web_timeout_ms : int t
    | Web_max_timeout_ms : int t

  type any = Any : 'a t -> any

  let model = Model
  let small_model = Small_model
  let reasoning = Reasoning
  let tui_thinking = Tui_thinking
  let provider_base_url provider = Provider_base_url provider
  let run_max_steps = Run_max_steps
  let run_subagent_max_concurrent = Run_subagent_max_concurrent
  let run_subagent_max_depth = Run_subagent_max_depth
  let run_subagent_wake = Run_subagent_wake
  let run_subagent_max_exchanges = Run_subagent_max_exchanges
  let permission_mode = Permission_mode
  let permission_unattended = Permission_unattended
  let sandbox_mode = Sandbox_mode
  let sandbox_require = Sandbox_require
  let sandbox_writable_roots = Sandbox_writable_roots
  let sandbox_network = Sandbox_network
  let sandbox_toolchain_caches = Sandbox_toolchain_caches
  let shell = Shell
  let compaction_auto = Compaction_auto
  let notices_fswatch = Notices_fswatch
  let notices_cr_comments = Notices_cr_comments
  let notices_dune_diagnostics = Notices_dune_diagnostics
  let notices_dune_build = Notices_dune_build
  let workspace_tooling = Workspace_tooling
  let instructions_global = Instructions_global
  let instructions_project = Instructions_project
  let instructions_claude_md = Instructions_claude_md
  let instructions_project_max_bytes = Instructions_project_max_bytes
  let skills_enabled = Skills_enabled
  let skills_builtin = Skills_builtin
  let skills_project = Skills_project
  let skills_compat = Skills_compat
  let skills_disabled = Skills_disabled
  let skills_paths = Skills_paths
  let skills_catalog_max_bytes = Skills_catalog_max_bytes
  let tools_anchored_edits = Tools_anchored_edits
  let tools_editor = Tools_editor
  let ocaml_merlin_program = Ocaml_merlin_program
  let web_enabled = Web_enabled
  let web_allow_private_network = Web_allow_private_network
  let web_search_backend = Web_search_backend
  let web_fetch_max_bytes = Web_fetch_max_bytes
  let web_output_max_chars = Web_output_max_chars
  let web_timeout_ms = Web_timeout_ms
  let web_max_timeout_ms = Web_max_timeout_ms

  let name : type a. a t -> string = function
    | Model -> "model"
    | Small_model -> "small_model"
    | Reasoning -> "reasoning"
    | Tui_thinking -> "tui.thinking"
    | Provider_base_url provider ->
        "providers." ^ Spice_llm.Provider.id provider ^ ".base_url"
    | Run_max_steps -> "run.max_steps"
    | Run_subagent_max_concurrent -> "run.subagent_max_concurrent"
    | Run_subagent_max_depth -> "run.subagent_max_depth"
    | Run_subagent_wake -> "run.subagent_wake"
    | Run_subagent_max_exchanges -> "run.subagent_max_exchanges"
    | Permission_mode -> "permission.mode"
    | Permission_unattended -> "permission.unattended"
    | Sandbox_mode -> "sandbox.mode"
    | Sandbox_require -> "sandbox.require"
    | Sandbox_writable_roots -> "sandbox.writable_roots"
    | Sandbox_network -> "sandbox.network"
    | Sandbox_toolchain_caches -> "sandbox.toolchain_caches"
    | Shell -> "shell"
    | Compaction_auto -> "compaction.auto"
    | Notices_fswatch -> "notices.fswatch"
    | Notices_cr_comments -> "notices.cr_comments"
    | Notices_dune_diagnostics -> "notices.dune_diagnostics"
    | Notices_dune_build -> "notices.dune_build"
    | Workspace_tooling -> "workspace.tooling"
    | Instructions_global -> "instructions.global"
    | Instructions_project -> "instructions.project"
    | Instructions_claude_md -> "instructions.claude_md"
    | Instructions_project_max_bytes -> "instructions.project_max_bytes"
    | Skills_enabled -> "skills.enabled"
    | Skills_builtin -> "skills.builtin"
    | Skills_project -> "skills.project"
    | Skills_compat -> "skills.compat"
    | Skills_disabled -> "skills.disabled"
    | Skills_paths -> "skills.paths"
    | Skills_catalog_max_bytes -> "skills.catalog_max_bytes"
    | Tools_anchored_edits -> "tools.anchored_edits"
    | Tools_editor -> "tools.editor"
    | Ocaml_merlin_program -> "ocaml.merlin_program"
    | Web_enabled -> "web.enabled"
    | Web_allow_private_network -> "web.allow_private_network"
    | Web_search_backend -> "web.search_backend"
    | Web_fetch_max_bytes -> "web.fetch_max_bytes"
    | Web_output_max_chars -> "web.output_max_chars"
    | Web_timeout_ms -> "web.timeout_ms"
    | Web_max_timeout_ms -> "web.max_timeout_ms"

  let equal a b = String.equal (name a) (name b)

  (* The non-provider-family fields, in the stable order exposed by {!all}. The
     provider base URL family is a parameterized field spliced in after
     [reasoning] by key-ordered surfaces (see {!with_provider_family}). *)
  let all () =
    [
      Any Model;
      Any Small_model;
      Any Reasoning;
      Any Tui_thinking;
      Any Run_max_steps;
      Any Run_subagent_max_concurrent;
      Any Run_subagent_max_depth;
      Any Run_subagent_wake;
      Any Run_subagent_max_exchanges;
      Any Permission_mode;
      Any Permission_unattended;
      Any Sandbox_mode;
      Any Sandbox_require;
      Any Sandbox_writable_roots;
      Any Sandbox_network;
      Any Sandbox_toolchain_caches;
      Any Shell;
      Any Compaction_auto;
      Any Notices_fswatch;
      Any Notices_cr_comments;
      Any Notices_dune_diagnostics;
      Any Notices_dune_build;
      Any Workspace_tooling;
      Any Instructions_global;
      Any Instructions_project;
      Any Instructions_claude_md;
      Any Instructions_project_max_bytes;
      Any Skills_enabled;
      Any Skills_builtin;
      Any Skills_project;
      Any Skills_compat;
      Any Skills_disabled;
      Any Skills_paths;
      Any Skills_catalog_max_bytes;
      Any Tools_anchored_edits;
      Any Tools_editor;
      Any Ocaml_merlin_program;
      Any Web_enabled;
      Any Web_allow_private_network;
      Any Web_search_backend;
      Any Web_fetch_max_bytes;
      Any Web_output_max_chars;
      Any Web_timeout_ms;
      Any Web_max_timeout_ms;
    ]

  (* [values field] routes each field to its codec's closed vocabulary, so a
     field's allowed spellings live once — on the codec, beside the parser that
     accepts them — and open-shaped fields carry [None]. The routing mirrors
     the codec each field is given in {!field_spec}; the spellings themselves
     are never restated here. *)
  let values : type a. a t -> string list option =
   fun field ->
    match field with
    | Model | Small_model -> selector_codec.values
    | Reasoning -> reasoning_codec.values
    | Provider_base_url _ | Shell -> string_codec.values
    | Tui_thinking | Run_subagent_wake | Compaction_auto | Notices_fswatch
    | Notices_cr_comments | Notices_dune_diagnostics | Notices_dune_build
    | Instructions_global | Instructions_project | Instructions_claude_md
    | Skills_enabled | Skills_builtin | Skills_project | Skills_compat
    | Sandbox_toolchain_caches | Tools_anchored_edits | Web_enabled
    | Web_allow_private_network ->
        bool_codec.values
    | Run_max_steps | Run_subagent_max_concurrent | Run_subagent_max_depth
    | Run_subagent_max_exchanges | Instructions_project_max_bytes
    | Skills_catalog_max_bytes | Web_fetch_max_bytes | Web_output_max_chars
    | Web_timeout_ms | Web_max_timeout_ms ->
        int_codec.values
    | Sandbox_writable_roots | Skills_disabled | Skills_paths ->
        string_list_codec.values
    | Ocaml_merlin_program -> merlin_codec.values
    | Permission_mode -> permission_mode_codec.values
    | Permission_unattended -> unattended_codec.values
    | Sandbox_mode -> sandbox_mode_codec.values
    | Sandbox_require -> sandbox_require_codec.values
    | Sandbox_network -> sandbox_network_codec.values
    | Tools_editor -> tools_editor_codec.values
    | Web_search_backend -> web_search_backend_codec.values
    | Workspace_tooling -> workspace_tooling_codec.values

  let supported_key_spellings =
    List.concat_map
      (fun (Any field) ->
        name field
        ::
        (match field with
        | Reasoning -> [ "providers.<provider>.base_url" ]
        | _ -> []))
      (all ())

  let supported_key_hint =
    "supported keys: " ^ String.concat ", " supported_key_spellings

  let of_string name =
    match name with
    | "model" -> Ok (Any Model)
    | "small_model" -> Ok (Any Small_model)
    | "reasoning" -> Ok (Any Reasoning)
    | "tui.thinking" -> Ok (Any Tui_thinking)
    | "run.max_steps" -> Ok (Any Run_max_steps)
    | "run.subagent_max_concurrent" -> Ok (Any Run_subagent_max_concurrent)
    | "run.subagent_max_depth" -> Ok (Any Run_subagent_max_depth)
    | "run.subagent_wake" -> Ok (Any Run_subagent_wake)
    | "run.subagent_max_exchanges" -> Ok (Any Run_subagent_max_exchanges)
    | "permission.mode" -> Ok (Any Permission_mode)
    | "permission.unattended" -> Ok (Any Permission_unattended)
    | "permission.rules" ->
        error
          ~hints:
            [
              "permission rules are structured config: edit the config file \
               directly, then inspect with `spice permission list` and remove \
               with `spice permission remove`";
            ]
          "config key permission.rules is not a scalar value"
    | "sandbox.mode" -> Ok (Any Sandbox_mode)
    | "sandbox.require" -> Ok (Any Sandbox_require)
    | "sandbox.writable_roots" -> Ok (Any Sandbox_writable_roots)
    | "sandbox.network" -> Ok (Any Sandbox_network)
    | "sandbox.toolchain_caches" -> Ok (Any Sandbox_toolchain_caches)
    | "shell" -> Ok (Any Shell)
    | "compaction.auto" -> Ok (Any Compaction_auto)
    | "notices.fswatch" -> Ok (Any Notices_fswatch)
    | "notices.cr_comments" -> Ok (Any Notices_cr_comments)
    | "notices.dune_diagnostics" -> Ok (Any Notices_dune_diagnostics)
    | "notices.dune_build" -> Ok (Any Notices_dune_build)
    | "workspace.tooling" -> Ok (Any Workspace_tooling)
    | "instructions.global" -> Ok (Any Instructions_global)
    | "instructions.project" -> Ok (Any Instructions_project)
    | "instructions.claude_md" -> Ok (Any Instructions_claude_md)
    | "instructions.project_max_bytes" ->
        Ok (Any Instructions_project_max_bytes)
    | "skills.enabled" -> Ok (Any Skills_enabled)
    | "skills.builtin" -> Ok (Any Skills_builtin)
    | "skills.project" -> Ok (Any Skills_project)
    | "skills.compat" -> Ok (Any Skills_compat)
    | "skills.disabled" -> Ok (Any Skills_disabled)
    | "skills.paths" -> Ok (Any Skills_paths)
    | "skills.catalog_max_bytes" -> Ok (Any Skills_catalog_max_bytes)
    | "tools.anchored_edits" -> Ok (Any Tools_anchored_edits)
    | "tools.editor" -> Ok (Any Tools_editor)
    | "ocaml.merlin_program" -> Ok (Any Ocaml_merlin_program)
    | "web.enabled" -> Ok (Any Web_enabled)
    | "web.allow_private_network" -> Ok (Any Web_allow_private_network)
    | "web.search_backend" -> Ok (Any Web_search_backend)
    | "web.fetch_max_bytes" -> Ok (Any Web_fetch_max_bytes)
    | "web.output_max_chars" -> Ok (Any Web_output_max_chars)
    | "web.timeout_ms" -> Ok (Any Web_timeout_ms)
    | "web.max_timeout_ms" -> Ok (Any Web_max_timeout_ms)
    | _ -> (
        match String.split_on_char '.' name with
        | [ "providers"; provider; "base_url" ] -> (
            try Ok (Any (Provider_base_url (Spice_llm.Provider.make provider)))
            with Invalid_argument message ->
              invalid_provider_id provider message)
        | "providers" :: _ ->
            error
              ~hints:
                [
                  "provider keys are spelled providers.<provider>.base_url";
                  supported_key_hint;
                ]
              ("unknown config key: " ^ name)
        | _ ->
            error
              ~hints:
                (Spice_diagnostic.did_you_mean name
                   ~candidates:supported_key_spellings
                @ [ supported_key_hint ])
              ("unknown config key: " ^ name))
end

(* Fields keyed in key-order surfaces list the provider base URL family after
   [reasoning]. *)
let with_provider_family providers =
  List.concat_map
    (fun (Field.Any field as any) ->
      any :: (match field with Field.Reasoning -> providers | _ -> []))
    (Field.all ())

(* The full per-field description: its {!codec}, its optional environment
   override (variable name and parser), whether workspace config may set it, and
   its optional built-in default (a domain value plus the diagnostic reason it
   records as a {!Source.Default}). Adding a config field is one case here. *)
type 'a spec = {
  codec : 'a codec;
  env : (string * (string -> ('a, Error.t) result)) option;
  shared_project : bool;
  default : ((string -> string option) -> 'a * string) option;
}

let make_spec ?env ?(shared = false) ?default codec =
  { codec; env; shared_project = shared; default }

let builtin field value _getenv = (value, "built-in " ^ Field.name field)

let provider_env_var provider =
  "SPICE_"
  ^ (String.uppercase_ascii (Spice_llm.Provider.id provider)
    |> String.map (function ('A' .. 'Z' | '0' .. '9') as c -> c | _ -> '_'))
  ^ "_BASE_URL"

let field_spec : type a. a Field.t -> a spec =
 fun field ->
  match field with
  | Field.Model ->
      make_spec selector_codec ~shared:true
        ~env:("SPICE_MODEL", parse_selector "SPICE_MODEL")
  | Field.Small_model ->
      make_spec selector_codec ~shared:true
        ~env:("SPICE_SMALL_MODEL", parse_selector "SPICE_SMALL_MODEL")
  | Field.Reasoning ->
      make_spec reasoning_codec ~shared:true
        ~env:("SPICE_REASONING", reasoning_effort_of_string)
  | Field.Tui_thinking -> make_spec bool_codec ~default:(builtin field true)
  | Field.Provider_base_url provider ->
      make_spec string_codec
        ~env:(provider_env_var provider, parse_string (Field.name field))
  | Field.Run_max_steps ->
      make_spec int_codec ~shared:true
        ~env:
          ( "SPICE_MAX_STEPS",
            fun raw ->
              match int_of_string_opt raw with
              | None -> error "SPICE_MAX_STEPS must be a positive integer"
              | Some value -> check_positive_int "SPICE_MAX_STEPS" value )
  | Field.Run_subagent_max_concurrent ->
      make_spec int_codec ~default:(builtin field 4)
  | Field.Run_subagent_max_depth ->
      make_spec int_codec ~default:(builtin field 2)
  | Field.Run_subagent_wake ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Run_subagent_max_exchanges ->
      make_spec int_codec ~default:(builtin field 8)
  | Field.Permission_mode ->
      make_spec permission_mode_codec
        ~default:(builtin field Permission.Preset.Default)
        ~env:
          ( "SPICE_PERMISSION_MODE",
            durable_permission_mode_of_string "SPICE_PERMISSION_MODE" )
  | Field.Permission_unattended ->
      make_spec unattended_codec ~shared:true
        ~default:(builtin field Permission.Unattended.Block)
        ~env:("SPICE_PERMISSION_UNATTENDED", permission_unattended_of_string)
  | Field.Sandbox_mode ->
      make_spec sandbox_mode_codec
        ~env:("SPICE_SANDBOX_MODE", sandbox_mode_of_string)
  | Field.Sandbox_require ->
      make_spec sandbox_require_codec
        ~default:(builtin field Sandbox.Require.Enforced)
        ~env:("SPICE_SANDBOX_REQUIRE", sandbox_require_of_string)
  | Field.Sandbox_writable_roots ->
      make_spec sandbox_writable_roots_codec ~default:(builtin field [])
  | Field.Sandbox_network ->
      make_spec sandbox_network_codec
        ~default:(builtin field Sandbox.Network.Restricted)
        ~env:("SPICE_SANDBOX_NETWORK", sandbox_network_of_string)
  | Field.Sandbox_toolchain_caches ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Shell ->
      make_spec string_codec
        ~env:("SPICE_SHELL", parse_string "shell")
        ~default:(fun getenv ->
          let reason =
            if String.equal Filename.dir_sep "\\" then
              match env_non_empty getenv "COMSPEC" with
              | Some _ -> "COMSPEC"
              | None -> "built-in shell"
            else
              match env_non_empty getenv "SHELL" with
              | Some _ -> "SHELL"
              | None -> "built-in shell"
          in
          (default_shell_program getenv, reason))
  | Field.Compaction_auto -> make_spec bool_codec ~default:(builtin field true)
  | Field.Notices_fswatch -> make_spec bool_codec ~default:(builtin field true)
  | Field.Notices_cr_comments ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Notices_dune_diagnostics ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Notices_dune_build ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Workspace_tooling ->
      make_spec workspace_tooling_codec ~shared:true
        ~default:(builtin field "auto")
        ~env:("SPICE_WORKSPACE_TOOLING", workspace_tooling_of_string)
  | Field.Instructions_global ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Instructions_project ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Instructions_claude_md ->
      make_spec bool_codec ~default:(builtin field true)
  | Field.Instructions_project_max_bytes ->
      make_spec int_codec
        ~default:(builtin field default_instructions_project_max_bytes)
  | Field.Skills_enabled -> make_spec bool_codec ~default:(builtin field true)
  | Field.Skills_builtin -> make_spec bool_codec ~default:(builtin field true)
  | Field.Skills_project -> make_spec bool_codec ~default:(builtin field true)
  | Field.Skills_compat -> make_spec bool_codec ~default:(builtin field true)
  | Field.Skills_disabled ->
      make_spec string_list_codec ~default:(builtin field [])
  | Field.Skills_paths ->
      make_spec string_list_codec ~default:(builtin field [])
  | Field.Skills_catalog_max_bytes ->
      make_spec int_codec
        ~default:(builtin field default_skills_catalog_max_bytes)
  | Field.Tools_anchored_edits ->
      make_spec bool_codec ~default:(builtin field false)
  | Field.Tools_editor ->
      make_spec tools_editor_codec ~shared:true ~default:(builtin field "auto")
  | Field.Ocaml_merlin_program ->
      make_spec merlin_codec
        ~default:(builtin field Spice_tools.Ocaml_merlin.default_program)
  | Field.Web_enabled -> make_spec bool_codec ~default:(builtin field false)
  | Field.Web_allow_private_network ->
      make_spec bool_codec ~default:(builtin field false)
  | Field.Web_search_backend ->
      make_spec web_search_backend_codec ~shared:true
        ~default:(builtin field "disabled")
  | Field.Web_fetch_max_bytes ->
      make_spec int_codec ~shared:true
        ~default:(builtin field default_web_fetch_max_bytes)
  | Field.Web_output_max_chars ->
      make_spec int_codec ~shared:true
        ~default:(builtin field default_web_output_max_chars)
  | Field.Web_timeout_ms ->
      make_spec int_codec ~shared:true
        ~default:(builtin field default_web_timeout_ms)
  | Field.Web_max_timeout_ms ->
      make_spec int_codec ~shared:true
        ~default:(builtin field default_web_max_timeout_ms)

let field_codec : type a. a Field.t -> a codec =
 fun field -> (field_spec field).codec

module Name_map = Map.Make (String)

(* One configured field bound to its domain value. The layer keys these by field
   name, so a lookup recovers the stored field's identity from the query
   field. *)
type value = V : 'a Field.t * 'a -> value

module Layer = struct
  type t = {
    scalars : value Name_map.t;
    permission_rules : Spice_permission.Policy.Rule.t list;
        (* [permission.rules] is a structured, non-scalar field outside the
           field-key system: it is a concat-merged monoid, not a replace-on-merge
           scalar, and is never addressable through a {!Field.t}. *)
  }

  let empty = { scalars = Name_map.empty; permission_rules = [] }

  let is_empty t =
    Name_map.is_empty t.scalars && List.is_empty t.permission_rules

  let get_field : type a. a Field.t -> t -> a option =
   fun field t ->
    match Name_map.find_opt (Field.name field) t.scalars with
    | None -> None
    | Some (V (stored, value)) -> (
        (* The stored field has the same name as [field], hence the same
           constructor and the same per-type id, so this witness always holds;
           the [None] arm is unreachable but keeps the recovery total. *)
        match
          Type.Id.provably_equal (field_codec field).type_id
            (field_codec stored).type_id
        with
        | Some Type.Equal -> Some value
        | None -> None)

  let set_field field value t =
    match value with
    | None -> { t with scalars = Name_map.remove (Field.name field) t.scalars }
    | Some value ->
        {
          t with
          scalars = Name_map.add (Field.name field) (V (field, value)) t.scalars;
        }

  let set_text field raw t =
    match raw with
    | None -> Ok (set_field field None t)
    | Some raw ->
        let* value =
          (field_codec field).parse_text ~label:(Field.name field) raw
        in
        Ok (set_field field (Some value) t)

  let get field t = Option.map (field_codec field).to_text (get_field field t)

  let json field t =
    match get_field field t with
    | Some value -> (field_codec field).encode_json value
    | None -> json_null

  let value_equal (V (fa, va)) (V (fb, vb)) =
    match
      Type.Id.provably_equal (field_codec fa).type_id (field_codec fb).type_id
    with
    | Some Type.Equal -> (field_codec fa).equal va vb
    | None -> false

  let equal a b =
    Name_map.equal value_equal a.scalars b.scalars
    && List.equal Spice_permission.Policy.Rule.equal a.permission_rules
         b.permission_rules

  let merge ~low ~high =
    {
      scalars =
        Name_map.union
          (fun _name _low high -> Some high)
          low.scalars high.scalars;
      (* Rules concatenate high before low: the merged layer's rules are the
         effective durable order, mirroring first-match precedence. *)
      permission_rules =
        (match (low.permission_rules, high.permission_rules) with
        | rules, [] | [], rules -> rules
        | low, high -> high @ low);
    }

  let merge_all layers =
    List.fold_left (fun low high -> merge ~low ~high) empty layers

  let permission_rules t = t.permission_rules
  let set_permission_rules rules t = { t with permission_rules = rules }

  let provider_base_url ~provider t =
    get_field (Field.Provider_base_url provider) t

  let provider_base_urls t =
    Name_map.bindings t.scalars
    |> List.filter_map
         (fun
           (_name, V (field, value)) : (Spice_llm.Provider.t * string) option ->
           match field with
           | Field.Provider_base_url provider -> Some (provider, value)
           | _ -> None)
    |> List.sort (fun (a, _) (b, _) -> Spice_llm.Provider.compare a b)

  (* Configured provider fields, ordered by provider id. *)
  let provider_keys t =
    provider_base_urls t
    |> List.map (fun (provider, _) ->
        Field.Any (Field.Provider_base_url provider))

  (* Configured fields in key order, with the provider family after
     [reasoning]. *)
  let keys t =
    let providers = provider_keys t in
    List.concat_map
      (fun (Field.Any field as any) ->
        (if Name_map.mem (Field.name field) t.scalars then [ any ] else [])
        @ match field with Field.Reasoning -> providers | _ -> [])
      (Field.all ())
end

let origins_of_layers layers =
  List.fold_left
    (fun origins (source, layer) ->
      List.fold_left
        (fun origins (Field.Any field as any) ->
          let name = Field.name field in
          let shadowed =
            match Name_map.find_opt name origins with
            | None -> []
            | Some (_, origin) -> Origin.source origin :: Origin.shadowed origin
          in
          Name_map.add name (any, Origin.make ~source ~shadowed) origins)
        origins (Layer.keys layer))
    Name_map.empty layers

let origin_with_defaults getenv origins =
  List.fold_left
    (fun origins (Field.Any field as any) ->
      match (field_spec field).default with
      | None -> origins
      | Some default ->
          let name = Field.name field in
          if Name_map.mem name origins then origins
          else
            let _value, reason = default getenv in
            Name_map.add name
              (any, Origin.make ~source:(Source.Default { reason }) ~shadowed:[])
              origins)
    origins (Field.all ())

let fs_path env path = Eio.Path.( / ) (Eio.Stdenv.fs env) path
let cwd_default env = Eio.Path.native_exn (Eio.Stdenv.cwd env)

let process_cwd env =
  let cwd = cwd_default env in
  if Filename.is_relative cwd then Sys.getcwd () else cwd

let abs_path ~name path =
  match Spice_path.Abs.of_string path with
  | Ok path -> Ok path
  | Error path_error -> error (name ^ ": " ^ Spice_path.Error.message path_error)

let host_cwd env =
  match Spice_path.Abs.of_string (process_cwd env) with
  | Ok cwd -> Ok cwd
  | Error path_error -> error ("cwd: " ^ Spice_path.Error.message path_error)

let resolve_under ~base ~name path =
  match Spice_path.Abs.resolve_any ~base path with
  | Ok path -> Ok path
  | Error path_error -> error (name ^ ": " ^ Spice_path.Error.message path_error)

let canonical_cwd env = function
  | "" -> error "cwd must not be empty"
  | cwd ->
      let path = fs_path env cwd in
      if Eio.Path.is_directory path then
        let* base = host_cwd env in
        resolve_under ~base ~name:"cwd" (Eio.Path.native_exn path)
      else error ("cwd is not a directory: " ^ cwd)

let fs_abs stdenv abs =
  Eio.Path.( / ) (Eio.Stdenv.fs stdenv) (Spice_path.Abs.to_string abs)

let git_marker_exists stdenv dir =
  let path = Eio.Path.( / ) (fs_abs stdenv dir) ".git" in
  Eio.Path.is_file path || Eio.Path.is_directory path

let discover_project_root stdenv cwd =
  let rec loop dir =
    if git_marker_exists stdenv dir then dir
    else
      match Spice_path.Abs.parent dir with
      | None -> cwd
      | Some parent -> loop parent
  in
  loop cwd

let spice_dir project_root =
  Filename.concat (Spice_path.Abs.to_string project_root) ".spice"

let project_config_path project_root =
  Filename.concat (spice_dir project_root) "config.json"

let project_local_config_path project_root =
  Filename.concat (spice_dir project_root) "config.local.json"

let file_exists env path = Eio.Path.is_file (fs_path env path)

let path_exists env path =
  match Eio.Path.kind ~follow:false (fs_path env path) with
  | `Not_found -> false
  | `Regular_file | `Directory | `Symbolic_link | `Socket | `Fifo
  | `Character_special | `Block_device | `Unknown ->
      true
  | exception _ -> true

let decode_json_file env path =
  match Eio.Path.load (fs_path env path) with
  | exception exn -> Error (Printexc.to_string exn)
  | text -> (
      match Jsont_bytesrw.decode_string Jsont.json text with
      | Ok json -> Ok json
      | Error message -> Error message)

(* File report order: top-level scalar fields, then the provider family, then
   nested sections, all derived from the field list. Loading, validation, and
   the file encoder fold the same order, so first-error reports, collect-all
   reports, and written field order stay aligned. *)
type file_unit = Key of Field.any | Providers | Section of string

let field_path field = String.split_on_char '.' (Field.name field)

let file_units =
  let top_level, sections =
    List.fold_left
      (fun (top_level, sections) (Field.Any field as any) ->
        match field_path field with
        | [ _ ] -> (top_level @ [ Key any ], sections)
        | head :: _ :: _ when not (List.exists (String.equal head) sections) ->
            (top_level, sections @ [ head ])
        | _ -> (top_level, sections))
      ([], []) (Field.all ())
  in
  top_level @ (Providers :: List.map (fun head -> Section head) sections)

let section_keys head =
  List.filter
    (fun (Field.Any field) ->
      match field_path field with
      | seg :: _ :: _ -> String.equal seg head
      | _ -> false)
    (Field.all ())

let decode_file_key source json (Field.Any field) layer =
  let name = Field.name field in
  let* leaf =
    match field_path field with
    | [ name ] -> Ok (json_mem name json)
    | [ section; name ] -> (
        match json_mem section json with
        | None -> Ok None
        | Some (Jsont.Object _ as inner) -> Ok (json_mem name inner)
        | Some _ -> error (source ^ " " ^ section ^ " must be an object"))
    | _ -> assert false
  in
  match leaf with
  | None -> Ok layer
  | Some leaf ->
      let* value =
        (field_codec field).decode_json ~label:(source ^ " " ^ name) leaf
      in
      Ok (Layer.set_field field (Some value) layer)

let load_providers source json layer =
  match json_mem "providers" json with
  | None -> Ok layer
  | Some (Jsont.Object (providers, _)) ->
      List.fold_left
        (fun acc ((name, _), value) ->
          let* layer = acc in
          let* provider =
            try Ok (Spice_llm.Provider.make name)
            with Invalid_argument message -> invalid_provider_id name message
          in
          match json_object_fields value with
          | None -> error (source ^ " providers." ^ name ^ " must be an object")
          | Some _ -> (
              match json_mem "base_url" value with
              | None -> Ok layer
              | Some leaf ->
                  let field = Field.Provider_base_url provider in
                  let* url =
                    (field_codec field).decode_json
                      ~label:(source ^ " providers." ^ name ^ ".base_url")
                      leaf
                  in
                  Ok (Layer.set_field field (Some url) layer)))
        (Ok layer) providers
  | Some _ -> error (source ^ " providers must be an object")

(* [permission.rules] is a structured field outside the scalar key system:
   parsed here, written by [layer_to_fields], and never addressable through a
   {!Field.t}. Duplicate rules within one layer are load errors so the effective
   evaluation order never carries silent repeats. *)
let check_duplicate_rule_ids label rules =
  let rec loop seen = function
    | [] -> Ok ()
    | rule :: rest ->
        let id = Permission.rule_id rule in
        if List.exists (String.equal id) seen then
          error (label ^ " contains duplicate rule " ^ id)
        else loop (id :: seen) rest
  in
  loop [] rules

(* [permission.rules] persists as a bare, unversioned [list Rule.jsont]. Should
   it gain a wire envelope, it lands here and at {!permission_rules_json}: wrap
   the array as [{ "version": N; "rules": [...] }] and add a read-side version
   check. This is the only site that parses the field. *)
let decode_permission_rules source json layer =
  match json_mem "permission" json with
  | None
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Array _ ) ->
      (* A non-object [permission] is reported by the keyed decoders. *)
      Ok layer
  | Some (Jsont.Object _ as inner) -> (
      match json_mem "rules" inner with
      | None -> Ok layer
      | Some leaf -> (
          let label = source ^ " permission.rules" in
          match
            Jsont.Json.decode
              Jsont.(list Spice_permission.Policy.Rule.jsont)
              leaf
          with
          | Error message -> error (label ^ ": " ^ message)
          | Ok rules ->
              let* () = check_duplicate_rule_ids label rules in
              Ok (Layer.set_permission_rules rules layer)))

let layer_of_json source = function
  | Jsont.Object _ as json ->
      let* layer =
        List.fold_left
          (fun acc unit ->
            let* layer = acc in
            match unit with
            | Key key -> decode_file_key source json key layer
            | Providers -> load_providers source json layer
            | Section head ->
                List.fold_left
                  (fun acc key ->
                    let* layer = acc in
                    decode_file_key source json key layer)
                  (Ok layer) (section_keys head))
          (Ok Layer.empty) file_units
      in
      decode_permission_rules source json layer
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      error (source ^ " config must be a JSON object")

let unknown_field_t source name = error_t (source ^ " unknown field: " ^ name)
let errors_of_result = function Ok _ -> [] | Error error -> [ error ]

let validate_providers source json =
  match json_mem "providers" json with
  | None -> []
  | Some (Jsont.Object (providers, _)) ->
      List.concat_map
        (fun ((name, _), value) ->
          let id_errors =
            errors_of_result
              (try Ok (Spice_llm.Provider.make name)
               with Invalid_argument message ->
                 invalid_provider_id name message)
          in
          match json_object_fields value with
          | None ->
              id_errors
              @ [
                  error_t (source ^ " providers." ^ name ^ " must be an object");
                ]
          | Some _ -> (
              match json_mem "base_url" value with
              | None -> id_errors
              | Some leaf ->
                  id_errors
                  @ errors_of_result
                      (decode_string_leaf
                         (source ^ " providers." ^ name ^ ".base_url")
                         leaf)))
        providers
  | Some _ -> [ error_t (source ^ " providers must be an object") ]

let unknown_object_field_errors source allowed json =
  match json_object_fields json with
  | None -> []
  | Some fields ->
      List.filter_map
        (fun ((name, _), _value) ->
          if List.exists (String.equal name) allowed then None
          else Some (unknown_field_t source name))
        fields

let validate_provider_unknown_fields source json =
  match json_mem "providers" json with
  | Some (Jsont.Object (providers, _)) ->
      List.concat_map
        (fun ((name, _), value) ->
          match json_object_fields value with
          | None -> []
          | Some _ ->
              unknown_object_field_errors
                (source ^ " providers." ^ name)
                [ "base_url" ] value)
        providers
  | None | Some _ -> []

let validate_layer_json source ?(strict = false) json =
  match json with
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      [ error_t (source ^ " config must be a JSON object") ]
  | Jsont.Object _ ->
      let key_errors key =
        errors_of_result (decode_file_key source json key Layer.empty)
      in
      let supported_errors =
        List.concat_map
          (function
            | Key key -> key_errors key
            | Providers -> validate_providers source json
            | Section head -> (
                match json_mem head json with
                | None -> []
                | Some (Jsont.Object _) ->
                    List.concat_map key_errors (section_keys head)
                | Some _ ->
                    [ error_t (source ^ " " ^ head ^ " must be an object") ]))
          file_units
        @ errors_of_result (decode_permission_rules source json Layer.empty)
      in
      if not strict then supported_errors
      else
        let top_level_allowed =
          List.map
            (function
              | Key (Field.Any field) -> Field.name field
              | Providers -> "providers"
              | Section head -> head)
            file_units
        in
        let section_unknown_errors =
          List.concat_map
            (function
              | Key _ | Providers -> []
              | Section head -> (
                  match json_mem head json with
                  | Some (Jsont.Object _ as inner) ->
                      let structured_members =
                        (* Structured fields live outside the scalar key
                           system but are supported file members. *)
                        match head with
                        | "permission" -> [ "rules" ]
                        | _ -> []
                      in
                      unknown_object_field_errors
                        (source ^ " " ^ head)
                        (List.map
                           (fun (Field.Any field) ->
                             String.concat "." (List.tl (field_path field)))
                           (section_keys head)
                        @ structured_members)
                        inner
                  | None | Some _ -> []))
            file_units
        in
        supported_errors
        @ unknown_object_field_errors source top_level_allowed json
        @ section_unknown_errors
        @ validate_provider_unknown_fields source json

let load_layer_path ~stdenv path =
  if not (file_exists stdenv path) then Ok Layer.empty
  else
    let* json =
      match decode_json_file stdenv path with
      | Ok json -> Ok json
      | Error message -> error (path ^ ": " ^ message)
    in
    layer_of_json path json

(* Workspace config files are repository content: byte-capped before parsing, so
   a hostile checkout cannot stall or exhaust the load. Callers degrade failures
   to an empty layer with a diagnostic; user-authored config keeps failing
   loudly through {!load_layer_path}. *)
let workspace_config_max_bytes = 1024 * 1024

let load_workspace_layer_path ~stdenv path =
  if not (file_exists stdenv path) then Ok Layer.empty
  else
    let* text =
      match
        Eio.Path.with_open_in (fs_path stdenv path) @@ fun flow ->
        Eio.Buf_read.(
          take_all (of_flow ~max_size:workspace_config_max_bytes flow))
      with
      | text -> Ok text
      | exception Eio.Buf_read.Buffer_limit_exceeded ->
          error
            (Printf.sprintf "%s: exceeds the %d-byte workspace config limit"
               path workspace_config_max_bytes)
      | exception exn -> error (path ^ ": " ^ Printexc.to_string exn)
    in
    let* json =
      match Jsont_bytesrw.decode_string Jsont.json text with
      | Ok json -> Ok json
      | Error message -> error (path ^ ": " ^ message)
    in
    layer_of_json path json

let validate_layer_path ~stdenv ?(strict = false) path =
  if not (file_exists stdenv path) then []
  else
    match
      match decode_json_file stdenv path with
      | Ok json -> Ok json
      | Error message -> error (path ^ ": " ^ message)
    with
    | Error error -> [ error ]
    | Ok json -> validate_layer_json path ~strict json

(* The environment layer is one fold over the field list; the provider base URL
   family contributes its wired providers -- the cloud endpoints a user may
   proxy plus the OpenAI-compatible [ollama] endpoint a self-hosted server
   (llama.cpp, vLLM, LM Studio) is reached through. Each variable parses with
   its field's environment parser, so per-variable error wording lives on the
   field description. *)
let env_named_layers getenv =
  let env_fields =
    with_provider_family
      (List.map
         (fun id ->
           Field.Any (Field.Provider_base_url (Spice_llm.Provider.make id)))
         [ "openai"; "anthropic"; "ollama" ])
  in
  let* layers =
    List.fold_left
      (fun acc (Field.Any field) ->
        let* layers = acc in
        match (field_spec field).env with
        | None -> Ok layers
        | Some (name, parse) -> (
            match getenv name with
            | None | Some "" -> Ok layers
            | Some value ->
                let* value = parse value in
                Ok
                  (( Source.Env { name },
                     Layer.set_field field (Some value) Layer.empty )
                  :: layers)))
      (Ok []) env_fields
  in
  Ok (List.rev layers)

let mkdir_p env dir =
  if String.is_empty dir || String.equal dir "." then Ok ()
  else
    match Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path env dir) with
    | () -> Ok ()
    | exception exn -> error (Printexc.to_string exn)

let make_mem name value = Jsont.Json.mem (Jsont.Json.name name) value
let json_object fields = Jsont.Json.object' fields

let read_object env path =
  if not (file_exists env path) then Ok []
  else
    match decode_json_file env path with
    | Error message -> error (path ^ ": " ^ message)
    | Ok (Jsont.Object (fields, _)) -> Ok fields
    | Ok _ -> error (path ^ " must contain a JSON object")

let mem_name ((name, _), _) = name

let remove_key key fields =
  List.filter (fun mem -> not (String.equal (mem_name mem) key)) fields

let find_key key fields =
  List.find_map
    (fun (((name, _), value) as _mem) ->
      if String.equal name key then Some value else None)
    fields

let object_fields = function
  | Jsont.Object (fields, _) -> fields
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      []

let rec set_path parts value fields =
  match parts with
  | [] -> fields
  | [ key ] -> make_mem key value :: remove_key key fields
  | key :: rest ->
      let nested =
        match find_key key fields with
        | None -> []
        | Some value -> object_fields value
      in
      make_mem key (json_object (set_path rest value nested))
      :: remove_key key fields

let rec unset_path parts fields =
  match parts with
  | [] -> fields
  | [ key ] -> remove_key key fields
  | key :: rest -> (
      match find_key key fields with
      | None -> fields
      | Some value ->
          let nested = unset_path rest (object_fields value) in
          let fields = remove_key key fields in
          if List.is_empty nested then fields
          else make_mem key (json_object nested) :: fields)

let path_parts key =
  List.filter
    (fun part -> not (String.is_empty part))
    (String.split_on_char '.' key)

let set_member key value fields = set_path (path_parts key) value fields
let unset_member key fields = unset_path (path_parts key) fields
let string_json value = Jsont.Json.string value

let update_optional key enc value fields =
  match value with
  | None -> unset_member key fields
  | Some value -> set_member key (enc value) fields

let write_provider_base_urls layer fields =
  let providers =
    object_fields
      (Option.value (find_key "providers" fields) ~default:(json_object []))
  in
  let providers =
    List.fold_left
      (fun providers ((name, _), value) ->
        let provider =
          try Some (Spice_llm.Provider.make name)
          with Invalid_argument _ -> None
        in
        match provider with
        | None -> providers
        | Some provider ->
            let key = Spice_llm.Provider.id provider in
            let provider_fields = object_fields value in
            let provider_fields =
              update_optional "base_url" string_json
                (Layer.provider_base_url ~provider layer)
                provider_fields
            in
            let providers = remove_key key providers in
            if List.is_empty provider_fields then providers
            else make_mem key (json_object provider_fields) :: providers)
      providers providers
  in
  let providers =
    List.fold_left
      (fun providers (provider, base_url) ->
        let key = Spice_llm.Provider.id provider in
        let provider_fields =
          match find_key key providers with
          | None -> []
          | Some value -> object_fields value
        in
        let provider_fields =
          set_member "base_url" (string_json base_url) provider_fields
        in
        make_mem key (json_object provider_fields) :: remove_key key providers)
      providers
      (Layer.provider_base_urls layer)
  in
  if List.is_empty providers then remove_key "providers" fields
  else
    make_mem "providers" (json_object providers)
    :: remove_key "providers" fields

let permission_rules_json rules =
  match
    Jsont.Json.encode Jsont.(list Spice_permission.Policy.Rule.jsont) rules
  with
  | Ok json -> json
  | Error message ->
      (* Rules in a layer were validated at decode or construction time, so a
         failed re-encode is a programmer bug, not file input. *)
      invalid_arg ("permission.rules encode failed: " ^ message)

let layer_to_fields layer fields =
  let apply fields (Field.Any field) =
    match Layer.json field layer with
    | Jsont.Null _ -> unset_member (Field.name field) fields
    | value -> set_member (Field.name field) value fields
  in
  List.fold_left
    (fun fields unit ->
      match unit with
      | Providers -> fields
      | Key key -> apply fields key
      | Section head -> List.fold_left apply fields (section_keys head))
    fields file_units
  |> write_provider_base_urls layer
  |> fun fields ->
  match Layer.permission_rules layer with
  | [] -> unset_member "permission.rules" fields
  | rules -> set_member "permission.rules" (permission_rules_json rules) fields

let tmp_counter = ref 0

let tmp_path env path =
  incr tmp_counter;
  let stamp =
    Eio.Time.now (Eio.Stdenv.clock env)
    |> Int64.bits_of_float |> Int64.to_string
  in
  path ^ ".tmp."
  ^ string_of_int (Unix.getpid ())
  ^ "." ^ stamp ^ "." ^ string_of_int !tmp_counter

let write_json env path fields =
  let json = json_object (List.rev fields) in
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Error message -> error message
  | Ok encoded -> (
      let tmp = tmp_path env path in
      match
        Eio.Path.save ~create:(`Exclusive 0o600) (fs_path env tmp)
          (encoded ^ "\n")
      with
      | exception exn -> error (Printexc.to_string exn)
      | () -> (
          match Eio.Path.rename (fs_path env tmp) (fs_path env path) with
          | () -> Ok ()
          | exception exn ->
              let () =
                try Eio.Path.unlink (fs_path env tmp)
                with cleanup ->
                  Log.debug (fun m ->
                      m "config temp cleanup failed: %s"
                        (Printexc.to_string cleanup))
              in
              error (path ^ ": " ^ Printexc.to_string exn)))

let ensure_project_local_gitignore env path =
  let dir = Filename.dirname path in
  let gitignore = Filename.concat dir ".gitignore" in
  let entry = Filename.basename path in
  let existing =
    match Eio.Path.load (fs_path env gitignore) with
    | exception _ -> ""
    | text -> text
  in
  if List.exists (String.equal entry) (String.split_on_char '\n' existing) then
    Ok ()
  else
    let prefix =
      if String.is_empty existing then ""
      else if Char.equal existing.[String.length existing - 1] '\n' then
        existing
      else existing ^ "\n"
    in
    match
      Eio.Path.save ~create:(`Or_truncate 0o600) (fs_path env gitignore)
        (prefix ^ entry ^ "\n")
    with
    | () -> Ok ()
    | exception exn -> error (Printexc.to_string exn)

let edit_path ~stdenv ~path ~before_write ~f =
  let* fields = read_object stdenv path in
  let* old_layer = layer_of_json path (json_object fields) in
  let* new_layer = f old_layer in
  if Layer.equal old_layer new_layer then Ok ()
  else
    let* () = mkdir_p stdenv (Filename.dirname path) in
    let* () = before_write () in
    write_json stdenv path (layer_to_fields new_layer fields)

let ensure_path ~stdenv ~path ?(before_write = fun () -> Ok ()) () =
  if file_exists stdenv path then Ok ()
  else
    let* () = mkdir_p stdenv (Filename.dirname path) in
    let* () = before_write () in
    write_json stdenv path []

module Files = struct
  type kind = User | Project | Project_local

  type t = {
    project_root : Spice_path.Abs.t;
    user : Spice_path.Abs.t;
    project : Spice_path.Abs.t;
    project_local : Spice_path.Abs.t;
  }

  let path t = function
    | User -> t.user
    | Project -> t.project
    | Project_local -> t.project_local

  let user t = t.user
  let project_root t = t.project_root
  let project t = t.project
  let project_local t = t.project_local
  let path_string t kind = path t kind |> Spice_path.Abs.to_string

  let discover ~stdenv ?process_env ?cwd () =
    let process_env = Option.value process_env ~default:(Env.current ()) in
    let getenv = Env.get process_env in
    let cwd = Option.value cwd ~default:(cwd_default stdenv) in
    let* cwd = canonical_cwd stdenv cwd in
    let* base = host_cwd stdenv in
    let* user =
      resolve_under ~base ~name:"user config path"
        (User_dirs.config_path getenv)
    in
    let project_root = discover_project_root stdenv cwd in
    let* project =
      project_config_path project_root |> abs_path ~name:"project config path"
    in
    let* project_local =
      project_local_config_path project_root
      |> abs_path ~name:"project-local config path"
    in
    Ok { project_root; user; project; project_local }

  let load_path ~stdenv path = load_layer_path ~stdenv path

  let validate_path ~stdenv ?strict path =
    validate_layer_path ~stdenv ?strict path

  let load ~stdenv t kind = load_path ~stdenv (path_string t kind)

  let before_project_write stdenv t () =
    ensure_project_local_gitignore stdenv (path_string t Project_local)

  let edit ~stdenv t kind ~f =
    let path = path_string t kind in
    match kind with
    | User ->
        edit_path ~stdenv ~path ~before_write:(fun () -> Ok ()) ~f
    | Project | Project_local ->
        edit_path ~stdenv ~path ~before_write:(before_project_write stdenv t) ~f

  let ensure ~stdenv t kind =
    let path = path_string t kind in
    match kind with
    | User -> ensure_path ~stdenv ~path ()
    | Project ->
        ensure_path ~stdenv ~path ~before_write:(before_project_write stdenv t)
          ()
    | Project_local when file_exists stdenv path ->
      ensure_project_local_gitignore stdenv path
    | Project_local ->
        ensure_path ~stdenv ~path
          ~before_write:(before_project_write stdenv t)
          ()
end

module Config_file = struct
  type paths = Files.t
  type kind = Files.kind = User | Project | Project_local
  type doc = Layer.t

  let empty = Layer.empty
  let path = Files.path
  let user = Files.user
  let project_root = Files.project_root
  let project = Files.project
  let project_local = Files.project_local
  let discover = Files.discover
  let load_path = Files.load_path
  let validate_path = Files.validate_path
  let load = Files.load

  (* Both workspace files share the allowlist: [config.local.json] is workspace
     content a repository can commit, so it carries no more authority than the
     committed file. *)
  let field_allowed kind field =
    match kind with
    | Project | Project_local -> (field_spec field).shared_project
    | User -> true

  let field_names kind =
    Field.all ()
    |> List.filter (fun (Field.Any field) -> field_allowed kind field)
    |> List.map (fun (Field.Any field) -> Field.name field)

  let get field doc = Layer.get field doc
  let set field value doc = Layer.set_text field value doc
  let json field doc = Layer.json field doc
  let permission_rules = Layer.permission_rules
  let set_permission_rules = Layer.set_permission_rules
  let edit = Files.edit
  let ensure = Files.ensure

  let add_permission_rule ~stdenv paths kind rule =
    Files.edit ~stdenv paths kind ~f:(fun doc ->
        let rules = Layer.permission_rules doc in
        if List.exists (Spice_permission.Policy.Rule.equal rule) rules then
          Ok doc
        else Ok (Layer.set_permission_rules (rules @ [ rule ]) doc))
end

module Patch = struct
  type t = Layer.t

  let empty = Layer.empty
  let is_empty = Layer.is_empty
  let set field value t = Layer.set_text field value t
  let get field t = Layer.get field t
end

type t = {
  process_env : Env.t;
  cwd : Spice_path.Abs.t;
  project_root : Spice_path.Abs.t;
  workspace_trust : Trust.t;
  data_home : Spice_path.Abs.t;
  state_home : Spice_path.Abs.t;
  auth_store_path : Spice_path.Abs.t;
  layer : Layer.t;
  origins : (Field.any * Origin.t) Name_map.t;
  permission_rules : (Source.t * Spice_permission.Policy.Rule.t list) list;
      (* Per-layer durable rules retained at load beside [origins]: the
         provenance view whose flattening equals the merged layer's rules. *)
  ignored_project_keys : (Field.any * Source.t) list;
  ignored_project_rules : (Source.t * int) list;
  ignored_project_budgets : (Field.any * Source.t * int) list;
  invalid_project_files : (Source.t * string) list;
  disabled_project_files : Source.t list;
  files : Files.t;
}

let cwd t = t.cwd
let project_root t = t.project_root
let workspace_trust t = t.workspace_trust
let data_home t = t.data_home
let state_home t = t.state_home
let auth_store_path t = t.auth_store_path
let process_env t = t.process_env
let files t = t.files

let sandbox_protected_roots t =
  Option.to_list (Spice_path.Abs.parent (Files.user t.files))
  @ Option.to_list (Spice_path.Abs.parent (Files.project t.files))
  @ [ t.data_home; t.state_home ]

let find field t = Layer.get_field field t.layer

let field_default field getenv =
  match (field_spec field).default with
  | Some default -> Some (fst (default getenv))
  | None -> None

(* The effective domain value: the configured value, or the field's built-in
   default. *)
let effective field t =
  match Layer.get_field field t.layer with
  | Some value -> Some value
  | None -> field_default field (Env.get t.process_env)

(* The effective value for a field that always resolves, i.e. one with a
   built-in default. Fields without a default are read through {!find} or the
   view modules, never here. *)
let value field t =
  match effective field t with
  | Some value -> value
  | None -> invalid_arg (Field.name field ^ " has no built-in default")

module Models = struct
  type nonrec t = t

  let main t = find Field.model t

  let main_with_origin t =
    let origin t =
      Option.map snd (Name_map.find_opt (Field.name Field.model) t.origins)
    in
    Option.map (fun selector -> (selector, origin t)) (main t)

  let small t = find Field.small_model t
  let reasoning t = find Field.reasoning t
  let provider_base_url t ~provider = Layer.provider_base_url ~provider t.layer
  let provider_base_urls t = Layer.provider_base_urls t.layer
end

module Runtime = struct
  type nonrec t = t

  let max_steps t = find Field.run_max_steps t
  let subagent_max_concurrent t = value Field.run_subagent_max_concurrent t
  let subagent_max_depth t = value Field.run_subagent_max_depth t
  let subagent_wake t = value Field.run_subagent_wake t
  let subagent_max_exchanges t = value Field.run_subagent_max_exchanges t
  let shell t = value Field.shell t
  let compaction_auto t = value Field.compaction_auto t
end

module Tui = struct
  type nonrec t = t

  let thinking t = value Field.tui_thinking t
end

module Permissions = struct
  type nonrec t = t

  let mode t = value Field.permission_mode t
  let unattended t = value Field.permission_unattended t
  let rules t = t.permission_rules
end

module Sandbox = struct
  type nonrec t = t

  (* No built-in default for [mode]: an unset sandbox mode resolves through the
     host sandbox adapter, or fails fast. *)
  let mode t = find Field.sandbox_mode t
  let require t = value Field.sandbox_require t
  let writable_roots t = value Field.sandbox_writable_roots t
  let network t = value Field.sandbox_network t
  let toolchain_caches t = value Field.sandbox_toolchain_caches t
end

module Instructions = struct
  type nonrec t = t

  let global t = value Field.instructions_global t
  let project t = value Field.instructions_project t
  let claude_md t = value Field.instructions_claude_md t
  let project_max_bytes t = value Field.instructions_project_max_bytes t
end

module Notices = struct
  type nonrec t = t

  let fswatch t = value Field.notices_fswatch t
  let cr_comments t = value Field.notices_cr_comments t
  let dune_diagnostics t = value Field.notices_dune_diagnostics t
  let dune_build t = value Field.notices_dune_build t
end

module Workspace = struct
  type nonrec t = t

  let tooling t = value Field.workspace_tooling t

  (* The codec admits only the three spellings, so the wildcard is [auto]: it
     engages when the workspace root carries a Dune project marker, resolved
     against the filesystem here rather than at config load so a directory that
     gains or loses a [dune-project] between launches is read afresh. *)
  let tooling_engaged t ~root =
    match tooling t with
    | "on" -> true
    | "off" -> false
    | _ ->
        Sys.file_exists (Filename.concat root "dune-project")
        || Sys.file_exists (Filename.concat root "dune-workspace")
end

module Skills = struct
  type nonrec t = t

  let enabled t = value Field.skills_enabled t
  let builtin t = value Field.skills_builtin t
  let project t = value Field.skills_project t
  let compat t = value Field.skills_compat t
  let disabled t = value Field.skills_disabled t
  let paths t = value Field.skills_paths t
  let catalog_max_bytes t = value Field.skills_catalog_max_bytes t
end

module Tools = struct
  type nonrec t = t

  let anchored_edits t = value Field.tools_anchored_edits t
  let editor t = value Field.tools_editor t
end

module Ocaml = struct
  type nonrec t = t

  let merlin_program t = value Field.ocaml_merlin_program t
end

module Web = struct
  type nonrec t = t

  let enabled t = value Field.web_enabled t
  let allow_private_network t = value Field.web_allow_private_network t
  let search_backend t = value Field.web_search_backend t
  let fetch_max_bytes t = value Field.web_fetch_max_bytes t
  let output_max_chars t = value Field.web_output_max_chars t
  let timeout_ms t = value Field.web_timeout_ms t
  let max_timeout_ms t = value Field.web_max_timeout_ms t
end

let models t = t
let runtime t = t
let tui t = t
let permissions t = t

let permission_posture ?preset t =
  let permissions = permissions t in
  let preset = Option.value preset ~default:(Permissions.mode permissions) in
  Permission.Run.make
    ~preset:
      ( Source.Default
          { reason = "permission.mode=" ^ Permission.Preset.to_string preset },
        preset )
    ~durable:(Permissions.rules permissions)
    ()

let sandbox t = t
let instructions t = t
let notices t = t
let workspace t = t
let skills t = t
let tools t = t
let ocaml t = t
let web t = t

let origin field t =
  Option.map snd (Name_map.find_opt (Field.name field) t.origins)

let origins t = Name_map.bindings t.origins |> List.map snd
let get field t = Option.map (field_codec field).to_text (effective field t)

let json field t =
  match effective field t with
  | Some value -> (field_codec field).encode_json value
  | None -> json_null

module Warning = struct
  type kind =
    | Ignored_project_key
    | Ignored_project_rules
    | Ignored_project_budget
    | Invalid_project_config
    | Project_config_disabled

  type t = {
    kind : kind;
    source : Source.t;
    key : Field.any option;
    message : string;
  }

  let kind_string = function
    | Ignored_project_key -> "ignored_project_key"
    | Ignored_project_rules -> "ignored_project_rules"
    | Ignored_project_budget -> "ignored_project_budget"
    | Invalid_project_config -> "invalid_project_config"
    | Project_config_disabled -> "project_config_disabled"

  let kind_of_string = function
    | "ignored_project_key" -> Some Ignored_project_key
    | "ignored_project_rules" -> Some Ignored_project_rules
    | "ignored_project_budget" -> Some Ignored_project_budget
    | "invalid_project_config" -> Some Invalid_project_config
    | "project_config_disabled" -> Some Project_config_disabled
    | _ -> None

  let source_kind_and_path = function
    | Source.User { path } -> ("user", Spice_path.Abs.to_string path)
    | Source.Project { path } -> ("project", Spice_path.Abs.to_string path)
    | Source.Project_local { path } ->
        ("project_local", Spice_path.Abs.to_string path)
    | Source.Extra_file { path } -> ("extra_file", Spice_path.Abs.to_string path)
    | Source.Env { name } -> ("env", name)
    | Source.Override -> ("override", "")
    | Source.Default { reason } -> ("default", reason)

  let source_of_kind_and_path kind path =
    let file make =
      match Spice_path.Abs.of_string path with
      | Ok path -> Ok (make path)
      | Error error -> Error (Spice_path.Error.message error)
    in
    match kind with
    | "user" -> file (fun path -> Source.User { path })
    | "project" -> file (fun path -> Source.Project { path })
    | "project_local" -> file (fun path -> Source.Project_local { path })
    | "extra_file" -> file (fun path -> Source.Extra_file { path })
    | "env" -> Ok (Source.Env { name = path })
    | "override" -> Ok Source.Override
    | "default" -> Ok (Source.Default { reason = path })
    | _ -> Error ("unknown config diagnostic source: " ^ kind)

  let message t = t.message
  let source t = t.source
  let field t = t.key
  let key_name = function Field.Any field -> Field.name field

  let ignored_project_rules ~count source =
    {
      kind = Ignored_project_rules;
      source;
      key = None;
      message =
        Printf.sprintf
          "permission.rules is ignored in workspace config: %d rule%s dropped \
           (workspace config cannot carry permission rules)"
          count
          (if count = 1 then "" else "s");
    }

  let ignored_project_budget key ~cap source =
    {
      kind = Ignored_project_budget;
      source;
      key = Some key;
      message =
        Printf.sprintf
          "%s is ignored because workspace config may tighten but not widen it \
           (effective limit: %d)"
          (key_name key) cap;
    }

  let invalid_project_config ~reason source =
    {
      kind = Invalid_project_config;
      source;
      key = None;
      message = "workspace config file ignored: " ^ reason;
    }

  let project_config_disabled status source =
    {
      kind = Project_config_disabled;
      source;
      key = None;
      message =
        "workspace config file disabled: workspace trust is "
        ^ Trust.status_to_string status;
    }

  let ignored_project_key key source =
    {
      kind = Ignored_project_key;
      source;
      key = Some key;
      message =
        Printf.sprintf
          "%s is ignored because shared project config may only set: %s"
          (key_name key)
          (String.concat ", " (Config_file.field_names Config_file.Project));
    }

  let make_mem name value = Jsont.Json.mem (Jsont.Json.name name) value

  let to_json t =
    let source_kind, path = source_kind_and_path t.source in
    let key_field =
      match t.key with
      | None -> []
      | Some key -> [ make_mem "key" (Jsont.Json.string (key_name key)) ]
    in
    Jsont.Json.object'
      ([
         make_mem "kind" (Jsont.Json.string (kind_string t.kind));
         make_mem "source" (Jsont.Json.string source_kind);
         make_mem "path" (Jsont.Json.string path);
       ]
      @ key_field
      @ [ make_mem "message" (Jsont.Json.string t.message) ])

  let decode_error message = Jsont.Error.msg Jsont.Meta.none message

  let require_string_field context name json =
    match json_mem name json with
    | Some (Jsont.String (value, _)) -> value
    | Some _ -> decode_error (context ^ " " ^ name ^ " must be a string")
    | None -> decode_error (context ^ " missing " ^ name)

  let optional_string_field context name json =
    match json_mem name json with
    | None -> None
    | Some (Jsont.String (value, _)) -> Some value
    | Some _ -> decode_error (context ^ " " ^ name ^ " must be a string")

  let of_json json =
    match json_object_fields json with
    | None -> decode_error "config diagnostic must be an object"
    | Some _ ->
        let kind_raw = require_string_field "config diagnostic" "kind" json in
        let kind =
          match kind_of_string kind_raw with
          | Some kind -> kind
          | None -> decode_error ("unknown config diagnostic kind: " ^ kind_raw)
        in
        let source_kind =
          require_string_field "config diagnostic" "source" json
        in
        let path = require_string_field "config diagnostic" "path" json in
        let source =
          match source_of_kind_and_path source_kind path with
          | Ok source -> source
          | Error message -> decode_error message
        in
        let key =
          match optional_string_field "config diagnostic" "key" json with
          | None -> None
          | Some raw -> (
              match Field.of_string raw with
              | Ok key -> Some key
              | Error error -> decode_error (Error.message error))
        in
        let message = require_string_field "config diagnostic" "message" json in
        { kind; source; key; message }

  let jsont =
    Jsont.map ~kind:"config diagnostic" ~dec:of_json ~enc:to_json Jsont.json

  let pp ppf t =
    let source_kind, path = source_kind_and_path t.source in
    match (t.kind, t.key) with
    | Ignored_project_key, Some key ->
        Format.fprintf ppf "%s config key ignored in workspace config: %s (%s)"
          source_kind (key_name key) path
    | ( ( Ignored_project_rules | Ignored_project_budget
        | Invalid_project_config | Project_config_disabled ),
        _ ) ->
        Format.fprintf ppf "%s (%s: %s)" t.message source_kind path
    | Ignored_project_key, None -> Format.pp_print_string ppf t.message
end

let warnings t =
  List.map
    (Warning.project_config_disabled (Trust.status t.workspace_trust))
    t.disabled_project_files
  @ List.map
    (fun (source, reason) -> Warning.invalid_project_config ~reason source)
    t.invalid_project_files
  @ List.map
      (fun (key, source) -> Warning.ignored_project_key key source)
      t.ignored_project_keys
  @ List.map
      (fun (source, count) -> Warning.ignored_project_rules ~count source)
      t.ignored_project_rules
  @ List.map
      (fun (key, source, cap) -> Warning.ignored_project_budget key ~cap source)
      t.ignored_project_budgets

let filter_shared_project_layer source layer =
  List.fold_left
    (fun (layer, ignored) (Field.Any field as any) ->
      if (field_spec field).shared_project then (layer, ignored)
      else (Layer.set_field field None layer, (any, source) :: ignored))
    (layer, []) (Layer.keys layer)
  |> fun (layer, ignored) -> (layer, List.rev ignored)

(* Workspace layers are attacker-controlled repository content, reduced to
   inputs that are safe by construction: scalar keys outside the shared
   allowlist drop, [permission.rules] never load from the workspace (the one
   structured field that carries authority), and budget keys may tighten but not
   widen the non-workspace effective value. Every drop surfaces as a
   diagnostic. *)
let sanitize_workspace_layer ~run_max_steps_cap source layer =
  let layer, ignored_keys = filter_shared_project_layer source layer in
  let layer, ignored_rules =
    match Layer.permission_rules layer with
    | [] -> (layer, [])
    | rules ->
        (Layer.set_permission_rules [] layer, [ (source, List.length rules) ])
  in
  let layer, ignored_budgets =
    match (Layer.get_field Field.run_max_steps layer, run_max_steps_cap) with
    | Some value, Some cap when value > cap ->
        ( Layer.set_field Field.run_max_steps None layer,
          [ (Field.Any Field.run_max_steps, source, cap) ] )
    | (Some _ | None), _ -> (layer, [])
  in
  (layer, ignored_keys, ignored_rules, ignored_budgets)

type workspace_layers = {
  project : Layer.t;
  project_local : Layer.t;
  ignored_keys : (Field.any * Source.t) list;
  ignored_rules : (Source.t * int) list;
  ignored_budgets : (Field.any * Source.t * int) list;
  invalid_files : (Source.t * string) list;
  disabled_files : Source.t list;
}

let validate_merged_layer layer =
  let timeout_ms =
    Option.value
      (Layer.get_field Field.web_timeout_ms layer)
      ~default:default_web_timeout_ms
  in
  let max_timeout_ms =
    Option.value
      (Layer.get_field Field.web_max_timeout_ms layer)
      ~default:default_web_max_timeout_ms
  in
  if timeout_ms > max_timeout_ms then
    error "web.timeout_ms must not exceed web.max_timeout_ms"
  else Ok ()

let pp ppf t =
  let permissions = permissions t in
  let runtime = runtime t in
  Format.fprintf ppf
    "@[<v>{ cwd = %S; project_root = %S; data_home = %S; state_home = %S; \
     auth_store_path = %S; permission_mode = %S; shell = %S }@]"
    (Spice_path.Abs.to_string t.cwd)
    (Spice_path.Abs.to_string t.project_root)
    (Spice_path.Abs.to_string t.data_home)
    (Spice_path.Abs.to_string t.state_home)
    (Spice_path.Abs.to_string t.auth_store_path)
    (Permission.Preset.to_string (Permissions.mode permissions))
    (Runtime.shell runtime)

let load ~stdenv ?process_env ?cwd ?extra_config_file ?data_home
    ?(overrides = []) () =
  let process_env = Option.value process_env ~default:(Env.current ()) in
  let getenv = Env.get process_env in
  let cwd = Option.value cwd ~default:(cwd_default stdenv) in
  let* files = Files.discover ~stdenv ~process_env ~cwd () in
  let project_root = Files.project_root files in
  let* workspace_trust =
    Trust.find ~stdenv ~process_env ~root:project_root ()
    |> Result.map_error (fun error ->
        error_t (Trust.Error.message error))
  in
  let* cwd = canonical_cwd stdenv cwd in
  let* base = host_cwd stdenv in
  let* data_home =
    match data_home with
    | Some path -> resolve_under ~base ~name:"data home" path
    | None -> (
        match User_dirs.data_home getenv with
        | Ok path -> resolve_under ~base ~name:"data home" path
        | Error path_error -> error (User_dirs.Error.message path_error))
  in
  let* state_home =
    match User_dirs.state_home getenv with
    | Ok path -> resolve_under ~base ~name:"state home" path
    | Error path_error -> error (User_dirs.Error.message path_error)
  in
  let* auth_store_path =
    resolve_under ~base ~name:"auth_store_path"
      (User_dirs.auth_store_path getenv)
  in
  let user_config_file = Files.user files in
  let* extra_config_file =
    let raw =
      match extra_config_file with
      | Some path -> Some path
      | None -> (
          match getenv "SPICE_CONFIG" with
          | Some "" | None -> None
          | Some path -> Some path)
    in
    match raw with
    | None -> Ok None
    | Some path ->
        let* path = resolve_under ~base ~name:"extra config path" path in
        Ok (Some path)
  in
  let project_config_path = Files.project files in
  let project_local_config_path = Files.project_local files in
  let project_config_file = Spice_path.Abs.to_string project_config_path in
  let project_local_config_file =
    Spice_path.Abs.to_string project_local_config_path
  in
  let* user =
    load_layer_path ~stdenv (Spice_path.Abs.to_string user_config_file)
  in
  let user_source = Source.User { path = user_config_file } in
  let project_source = Source.Project { path = project_config_path } in
  let project_local_source =
    Source.Project_local { path = project_local_config_path }
  in
  let extra_source =
    match extra_config_file with
    | None -> None
    | Some path -> Some (Source.Extra_file { path })
  in
  let* extra =
    match extra_config_file with
    | None -> Ok Layer.empty
    | Some path -> load_layer_path ~stdenv (Spice_path.Abs.to_string path)
  in
  let extra_layers =
    match extra_source with None -> [] | Some source -> [ (source, extra) ]
  in
  let* env_layers = env_named_layers getenv in
  (* Trusted workspace layers still pass through the shared-key filter, rule
     stripping, budget clamp, and byte cap. Unknown and untrusted workspaces do
     not open the files at all; their paths remain available to explicit config
     inspection and editing commands. *)
  let run_max_steps_cap =
    Layer.get_field Field.run_max_steps
      (Layer.merge_all
         ([ user ] @ List.map snd extra_layers @ List.map snd env_layers
        @ overrides))
  in
  let load_workspace source path =
    match load_workspace_layer_path ~stdenv path with
    | Ok layer -> (layer, [])
    | Error err -> (Layer.empty, [ (source, Error.message err) ])
  in
  let workspace =
    if Trust.is_trusted workspace_trust then
      let project_raw, project_invalid =
        load_workspace project_source project_config_file
      in
      let project_local_raw, project_local_invalid =
        load_workspace project_local_source project_local_config_file
      in
      let project, project_keys, project_rules, project_budgets =
        sanitize_workspace_layer ~run_max_steps_cap project_source project_raw
      in
      let ( project_local,
            project_local_keys,
            project_local_rules,
            project_local_budgets ) =
        sanitize_workspace_layer ~run_max_steps_cap project_local_source
          project_local_raw
      in
      {
        project;
        project_local;
        ignored_keys = project_keys @ project_local_keys;
        ignored_rules = project_rules @ project_local_rules;
        ignored_budgets = project_budgets @ project_local_budgets;
        invalid_files = project_invalid @ project_local_invalid;
        disabled_files = [];
      }
    else
      let disabled_files =
        [ (project_source, project_config_file);
          (project_local_source, project_local_config_file) ]
        |> List.filter_map (fun (source, path) ->
            if path_exists stdenv path then Some source else None)
      in
      {
        project = Layer.empty;
        project_local = Layer.empty;
        ignored_keys = [];
        ignored_rules = [];
        ignored_budgets = [];
        invalid_files = [];
        disabled_files;
      }
  in
  let layers =
    [
      (user_source, user);
      (project_source, workspace.project);
      (project_local_source, workspace.project_local);
    ]
    @ extra_layers @ env_layers
    @ List.map (fun layer -> (Source.Override, layer)) overrides
  in
  let layer = Layer.merge_all (List.map snd layers) in
  let* () = validate_merged_layer layer in
  let origins = origins_of_layers layers |> origin_with_defaults getenv in
  let permission_rules =
    (* Non-workspace file layers only, in descending precedence: env and
       override layers cannot carry rules by construction, and workspace layers
       had theirs stripped by [sanitize_workspace_layer]. Flattening this list
       equals the merged layer's rules because [Layer.merge] concatenates
       high-first. *)
    List.filter_map
      (fun (source, layer) ->
        match Layer.permission_rules layer with
        | [] -> None
        | rules -> Some (source, rules))
      (extra_layers @ [ (user_source, user) ])
  in
  Log.debug (fun m ->
      m "config assembled layers=[%s] resolved_keys=%d"
        (String.concat ";"
           (List.filter_map
              (fun (source, layer) ->
                if Layer.is_empty layer then None
                else Some (Source.kind_string source))
              layers))
        (Name_map.cardinal origins));
  Ok
    {
      process_env;
      cwd;
      project_root;
      workspace_trust;
      data_home;
      state_home;
      auth_store_path;
      layer;
      origins;
      permission_rules;
      ignored_project_keys = workspace.ignored_keys;
      ignored_project_rules = workspace.ignored_rules;
      ignored_project_budgets = workspace.ignored_budgets;
      invalid_project_files = workspace.invalid_files;
      disabled_project_files = workspace.disabled_files;
      files;
    }
