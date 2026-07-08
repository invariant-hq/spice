(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "spice.host.skills" ~doc:"Skill discovery"

module Log = (val Logs.src_log log_src : Logs.LOG)

let json_mem name value = Jsont.Json.mem (Jsont.Json.name name) value
let json_object fields = Jsont.Json.object' fields
let digest_string text = Spice_digest.Identity.(to_string (of_contents text))

(* Rough per-token byte cost for prose. A real BPE tokenizer varies by content
   and model; four UTF-8 bytes per token is the conventional estimate, and is
   the only place the divisor is named. *)
let bytes_per_token = 4

(* [estimate_tokens bytes] is the token estimate for [bytes] of text, rounded
   up so any non-empty text costs at least one token. *)
let estimate_tokens bytes = (bytes + bytes_per_token - 1) / bytes_per_token

(* Cut [text] to at most [max_bytes] without splitting a UTF-8 sequence. *)
let take_utf8_prefix text max_bytes =
  if String.length text <= max_bytes then text
  else
    let stop = ref max_bytes in
    while !stop > 0 && Char.code text.[!stop] land 0xC0 = 0x80 do
      decr stop
    done;
    String.sub text 0 !stop

module Skill = struct
  module Name = struct
    type t = string

    let max_bytes = 64

    let valid name =
      String.length name > 0
      && String.length name <= max_bytes
      && (match name.[0] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
      && String.for_all
           (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
           name

    let of_string name =
      if valid name then Ok name
      else
        Error
          (Printf.sprintf
             "%S is not a skill name (lowercase letters, digits, and hyphens; \
              at most %d bytes)"
             name max_bytes)

    let to_string name = name
    let equal = String.equal
    let compare = String.compare
    let pp = Format.pp_print_string
  end

  type kind = Project | Compat_agents | Compat_claude | User | Path | Builtin

  type content = {
    description : string;
    display_name : string option;
    text : string;
        (* raw file: provenance for [skills show], identity for bytes/digest *)
    body : string; (* frontmatter-stripped guidance sent to the model *)
    bytes : int;
    digest : string;
    resources : string list;
    ignored_keys : string list;
  }

  type invalid =
    [ `Description_missing
    | `Description_too_long
    | `Invalid_frontmatter of string
    | `Unreadable of string ]

  type status =
    | Active of content
    | Shadowed of { by : string }
    | Disabled of [ `Project_skills | `Compat | `Builtin | `Config ]
    | Invalid of invalid

  type t = {
    name : Name.t;
    kind : kind;
    status : status;
    origin : string;
    dir : Spice_path.Abs.t option;
  }

  let name t = t.name
  let kind t = t.kind
  let status t = t.status
  let origin t = t.origin

  let context_cost t =
    match t.status with
    | Active content -> Some (estimate_tokens (String.length content.body))
    | Shadowed _ | Disabled _ | Invalid _ -> None

  let kind_string = function
    | Project -> "project"
    | Compat_agents -> "compat_agents"
    | Compat_claude -> "compat_claude"
    | User -> "user"
    | Path -> "path"
    | Builtin -> "builtin"

  let state_string = function
    | Active _ -> "active"
    | Shadowed _ -> "shadowed"
    | Disabled _ -> "disabled"
    | Invalid _ -> "invalid"

  let reason_string = function
    | Active _ -> None
    | Shadowed _ -> Some "shadowed"
    | Disabled `Project_skills -> Some "project_skills_disabled"
    | Disabled `Compat -> Some "compat_disabled"
    | Disabled `Builtin -> Some "builtin_disabled"
    | Disabled `Config -> Some "config_disabled"
    | Invalid `Description_missing -> Some "description_missing"
    | Invalid `Description_too_long -> Some "description_too_long"
    | Invalid (`Invalid_frontmatter _) -> Some "invalid_frontmatter"
    | Invalid (`Unreadable _) -> Some "unreadable"

  let detail_string = function
    | Invalid (`Invalid_frontmatter message) | Invalid (`Unreadable message) ->
        Some message
    | Shadowed { by } -> Some by
    | Active _ | Disabled _
    | Invalid (`Description_missing | `Description_too_long) ->
        None

  let to_json t =
    let base =
      [
        json_mem "name" (Jsont.Json.string (Name.to_string t.name));
        json_mem "kind" (Jsont.Json.string (kind_string t.kind));
        json_mem "origin" (Jsont.Json.string t.origin);
        json_mem "state" (Jsont.Json.string (state_string t.status));
      ]
    in
    let reason =
      match reason_string t.status with
      | None -> []
      | Some reason -> [ json_mem "reason" (Jsont.Json.string reason) ]
    in
    let detail =
      match detail_string t.status with
      | None -> []
      | Some detail -> [ json_mem "detail" (Jsont.Json.string detail) ]
    in
    let content =
      match t.status with
      | Active content -> (
          [
            json_mem "description" (Jsont.Json.string content.description);
            json_mem "bytes" (Jsont.Json.int content.bytes);
            json_mem "digest" (Jsont.Json.string content.digest);
            json_mem "resources"
              (Jsont.Json.list
                 (List.map
                    (fun value -> Jsont.Json.string value)
                    content.resources));
            json_mem "ignored_keys"
              (Jsont.Json.list
                 (List.map
                    (fun value -> Jsont.Json.string value)
                    content.ignored_keys));
          ]
          @
          match content.display_name with
          | None -> []
          | Some display ->
              [ json_mem "display_name" (Jsont.Json.string display) ])
      | Shadowed _ | Disabled _ | Invalid _ -> []
    in
    json_object (base @ reason @ detail @ content)
end

module Catalog = struct
  type t = {
    text : string;
    digest : string;
    trimmed : Skill.Name.t list;
    names_only : bool;
  }

  let text t = t.text
  let bytes t = String.length t.text
  let context_cost t = estimate_tokens (String.length t.text)
  let digest t = t.digest
  let trimmed t = t.trimmed
  let names_only t = t.names_only

  let to_json t =
    json_object
      [
        json_mem "bytes" (Jsont.Json.int (bytes t));
        json_mem "digest" (Jsont.Json.string t.digest);
        json_mem "trimmed"
          (Jsont.Json.list
             (List.map
                (fun name -> Jsont.Json.string (Skill.Name.to_string name))
                t.trimmed));
        json_mem "names_only" (Jsont.Json.bool t.names_only);
      ]

  let ellipsis = "\xE2\x80\xA6" (* U+2026, the visible trim marker *)
  let min_description_bytes = 16

  let entry_line ~name ~description =
    if String.equal description "" then "- " ^ name
    else "- " ^ name ^ ": " ^ description

  (* Render [(name, description, builtin)] entries under [budget] bytes.
     Builtin descriptions never trim; names are never dropped. Over budget,
     non-builtin descriptions share the remaining bytes equally and longer
     ones are cut at a UTF-8 boundary with a visible ellipsis. If even that
     floor does not fit, non-builtin descriptions drop entirely. *)
  let render ~budget entries =
    let line (name, description, _) = entry_line ~name ~description in
    let full = String.concat "\n" (List.map line entries) in
    let finish ?(trimmed = []) ?(names_only = false) text =
      { text; digest = digest_string text; trimmed; names_only }
    in
    if String.length full <= budget || entries = [] then finish full
    else
      let builtin, other =
        List.partition (fun (_, _, builtin) -> builtin) entries
      in
      let fixed_bytes =
        List.fold_left
          (fun total entry -> total + String.length (line entry) + 1)
          0 builtin
      in
      let name_overhead =
        List.fold_left
          (fun total (name, _, _) ->
            (* "- name: " plus the joining newline. *)
            total + String.length name + 5)
          0 other
      in
      let available = budget - fixed_bytes - name_overhead in
      let per_entry = if other = [] then 0 else available / List.length other in
      if per_entry < min_description_bytes then
        let text =
          entries
          |> List.map (fun (name, description, builtin) ->
              if builtin then entry_line ~name ~description
              else entry_line ~name ~description:"")
          |> String.concat "\n"
        in
        finish ~names_only:true text
      else
        let trimmed = ref [] in
        let text =
          entries
          |> List.map (fun (name, description, builtin) ->
              if builtin || String.length description <= per_entry then
                entry_line ~name ~description
              else begin
                trimmed := name :: !trimmed;
                let cut =
                  take_utf8_prefix description
                    (per_entry - String.length ellipsis)
                in
                entry_line ~name ~description:(cut ^ ellipsis)
              end)
          |> String.concat "\n"
        in
        finish ~trimmed:(List.rev !trimmed) text
end

type t = { enabled : bool; skills : Skill.t list; catalog : Catalog.t }

let enabled t = t.enabled
let skills t = t.skills
let catalog t = t.catalog

let find_active t name =
  List.find_map
    (fun (skill : Skill.t) ->
      match skill.Skill.status with
      | Skill.Active content when Skill.Name.equal skill.Skill.name name ->
          Some (skill, content)
      | _ -> None)
    t.skills

(* Discovery. One filesystem pass per root, with the same follow-and-contain
   observation policy as tools and context. *)

let skill_file = "SKILL.md"
let max_description_bytes = 1024

let fs_abs stdenv abs =
  Eio.Path.( / ) (Eio.Stdenv.fs stdenv) (Spice_path.Abs.to_string abs)

let marker_exists stdenv dir =
  let path = Eio.Path.( / ) (fs_abs stdenv dir) ".git" in
  Eio.Path.is_file path || Eio.Path.is_directory path

let find_workspace_root ~stdenv cwd =
  let rec loop dir =
    if marker_exists stdenv dir then Some dir
    else
      match Spice_path.Abs.parent dir with
      | None -> None
      | Some parent -> loop parent
  in
  loop cwd

(* Builds content facts for one read skill file. *)
let content_of_text ~resources text =
  match Spice_frontmatter.parse text with
  | Error error ->
      Error (`Invalid_frontmatter (Spice_frontmatter.Error.message error))
  | Ok header -> (
      match Spice_frontmatter.string "description" header with
      | None -> Error `Description_missing
      | Some description when String.length description > max_description_bytes
        ->
          Error `Description_too_long
      | Some description ->
          let display_name = Spice_frontmatter.string "name" header in
          let body = Spice_frontmatter.body header in
          let ignored_keys =
            Spice_frontmatter.keys header
            |> List.filter (fun key ->
                not (List.mem key [ "name"; "description" ]))
          in
          Ok
            {
              Skill.description;
              display_name;
              text;
              body;
              bytes = String.length text;
              digest = digest_string text;
              resources;
              ignored_keys;
            })

(* One filesystem skills root. [gate] of [None] reads candidates; [Some
   disabled] lists them from existence checks only, without content reads. *)

type observed = Missing | Found | Broken of string

let observe ~fs ~workspace path =
  match
    Spice_workspace_fs.regular_opt ~fs ~workspace ~follow_symlink:true path
  with
  | Ok None | Error (Spice_workspace_fs.Error.Not_found _) -> Missing
  | Ok (Some _) -> Found
  | Error error -> Broken (Spice_workspace_fs.Error.message error)

let list_resources ~fs ~workspace dir_path =
  match Spice_workspace_fs.read_dir_names ~fs ~workspace dir_path with
  | Error _ -> []
  | Ok names ->
      names
      |> List.filter (fun name -> not (String.equal name skill_file))
      |> List.sort String.compare

let read_candidate ~fs ~workspace ~dir_path skill_path =
  match
    Spice_workspace_fs.load_regular ~fs ~workspace ~follow_symlink:true
      skill_path
  with
  | Error error ->
      Skill.Invalid (`Unreadable (Spice_workspace_fs.Error.message error))
  | Ok text -> (
      let resources = list_resources ~fs ~workspace dir_path in
      match content_of_text ~resources text with
      | Ok content -> Skill.Active content
      | Error invalid -> Skill.Invalid invalid)

let candidate_paths root_path entry =
  match Spice_workspace_fs.child root_path entry with
  | Error _ -> None
  | Ok dir_path -> (
      match Spice_workspace_fs.child dir_path skill_file with
      | Error _ -> None
      | Ok skill_path -> Some (dir_path, skill_path))

let classify_entry ~fs ~workspace ~root_path ~root_abs ~kind ~gate entry =
  match Skill.Name.of_string entry with
  | Error _ -> None (* not a candidate, like bare files *)
  | Ok name -> (
      let origin = Filename.concat (Spice_path.Abs.to_string root_abs) entry in
      let dir = Spice_path.Abs.of_string origin |> Result.to_option in
      let make status = Some { Skill.name; kind; status; origin; dir } in
      match candidate_paths root_path entry with
      | None -> None
      | Some (dir_path, skill_path) -> (
          match observe ~fs ~workspace skill_path with
          | Missing -> None (* no SKILL.md: not a skill directory *)
          | Broken message -> make (Skill.Invalid (`Unreadable message))
          | Found -> (
              match gate with
              | Some disabled -> make (Skill.Disabled disabled)
              | None ->
                  make (read_candidate ~fs ~workspace ~dir_path skill_path))))

let filesystem_root ~stdenv ~kind ~gate root_abs =
  let fs = Eio.Stdenv.fs stdenv in
  let root = Spice_workspace.Root.make root_abs in
  let workspace = Spice_workspace.single root in
  let root_path = Spice_workspace.Path.make ~root Spice_path.Rel.root in
  if not (Eio.Path.is_directory (fs_abs stdenv root_abs)) then []
  else
    match Spice_workspace_fs.read_dir_names ~fs ~workspace root_path with
    | Error _ -> []
    | Ok names ->
        names |> List.sort String.compare
        |> List.filter_map
             (classify_entry ~fs ~workspace ~root_path ~root_abs ~kind ~gate)

let builtin_skills ~builtins ~origin ~gate =
  List.filter_map
    (fun (entry, text) ->
      match Skill.Name.of_string entry with
      | Error _ -> None (* the generator already enforces the grammar *)
      | Ok name -> (
          let make status =
            Some
              { Skill.name; kind = Skill.Builtin; status; origin; dir = None }
          in
          match gate with
          | Some disabled -> make (Skill.Disabled disabled)
          | None -> (
              match content_of_text ~resources:[] text with
              | Ok content -> make (Skill.Active content)
              | Error invalid -> make (Skill.Invalid invalid))))
    builtins

(* Per-skill config disable ([skills.disabled]). Every candidate whose name is
   listed becomes [Disabled `Config], before shadowing, so no lower-precedence
   candidate of the name is promoted to active in its place. Listed names that
   match no candidate are inert. *)
let apply_config_disable disabled candidates =
  match disabled with
  | [] -> candidates
  | disabled ->
      List.map
        (fun (skill : Skill.t) ->
          if List.exists (Skill.Name.equal skill.Skill.name) disabled then
            { skill with Skill.status = Skill.Disabled `Config }
          else skill)
        candidates

(* Shadowing: the first active candidate per name wins; invalid and disabled
   candidates never claim a name. *)
let apply_shadowing candidates =
  let winners = Hashtbl.create 16 in
  List.map
    (fun (skill : Skill.t) ->
      match skill.Skill.status with
      | Skill.Active _ -> (
          match Hashtbl.find_opt winners skill.Skill.name with
          | None ->
              Hashtbl.add winners skill.Skill.name skill.Skill.origin;
              skill
          | Some by -> { skill with Skill.status = Skill.Shadowed { by } })
      | _ -> skill)
    candidates

let load ~stdenv ~builtins ?(builtin_origin = "builtin") config =
  let skills_config = Config.skills config in
  if not (Config.Skills.enabled skills_config) then
    { enabled = false; skills = []; catalog = Catalog.render ~budget:0 [] }
  else
    let cwd = Config.cwd config in
    let root = Option.value (find_workspace_root ~stdenv cwd) ~default:cwd in
    let under base segments =
      List.fold_left
        (fun abs segment ->
          match
            Spice_path.Abs.of_string
              (Filename.concat (Spice_path.Abs.to_string abs) segment)
          with
          | Ok abs -> abs
          | Error _ -> abs)
        base segments
    in
    let project_gate =
      if Config.Skills.project skills_config then None else Some `Project_skills
    in
    let compat_gate =
      if not (Config.Skills.project skills_config) then Some `Project_skills
      else if not (Config.Skills.compat skills_config) then Some `Compat
      else None
    in
    let user_dir =
      Config.Config_file.user (Config.files config)
      |> Spice_path.Abs.to_string |> Filename.dirname
    in
    (* Relative [skills.paths] entries anchor on [Config.cwd], matching every
       other discovery root, so a [--cwd] override does not split the path
       root off from the rest of the run. *)
    let path_roots =
      Config.Skills.paths skills_config
      |> List.filter_map (fun text ->
          let absolute =
            if Filename.is_relative text then
              Filename.concat (Spice_path.Abs.to_string cwd) text
            else text
          in
          Spice_path.Abs.of_string absolute |> Result.to_option)
    in
    let builtin_gate =
      if Config.Skills.builtin skills_config then None else Some `Builtin
    in
    let candidates =
      filesystem_root ~stdenv ~kind:Skill.Project ~gate:project_gate
        (under root [ ".spice"; "skills" ])
      @ filesystem_root ~stdenv ~kind:Skill.Compat_agents ~gate:compat_gate
          (under root [ ".agents"; "skills" ])
      @ filesystem_root ~stdenv ~kind:Skill.Compat_claude ~gate:compat_gate
          (under root [ ".claude"; "skills" ])
      @ (match Spice_path.Abs.of_string user_dir with
        | Error _ -> []
        | Ok user_abs ->
            filesystem_root ~stdenv ~kind:Skill.User ~gate:None
              (under user_abs [ "skills" ]))
      @ List.concat_map
          (fun root_abs ->
            filesystem_root ~stdenv ~kind:Skill.Path ~gate:None root_abs)
          path_roots
      @ builtin_skills ~builtins ~origin:builtin_origin ~gate:builtin_gate
    in
    (* [skills.disabled] carries raw names; keep the well-formed ones (a
       malformed name can match no discovered candidate). *)
    let disabled_names =
      Config.Skills.disabled skills_config
      |> List.filter_map (fun raw ->
          Skill.Name.of_string raw |> Result.to_option)
    in
    let skills =
      apply_shadowing (apply_config_disable disabled_names candidates)
    in
    let entries =
      List.filter_map
        (fun (skill : Skill.t) ->
          match skill.Skill.status with
          | Skill.Active content ->
              Some
                ( Skill.Name.to_string skill.Skill.name,
                  content.Skill.description,
                  skill.Skill.kind = Skill.Builtin )
          | _ -> None)
        skills
    in
    let catalog =
      Catalog.render
        ~budget:(Config.Skills.catalog_max_bytes skills_config)
        entries
    in
    Log.debug (fun m ->
        m "skills loaded discovered=%d active=%d catalog_bytes=%d"
          (List.length skills) (List.length entries) (Catalog.bytes catalog));
    { enabled = true; skills; catalog }

(* The skill tool. A view of the snapshot: the description carries the
   catalog, the handler serves snapshot text and call-time resource reads. *)

module Tool_input = struct
  type t = { name : string; resource : string option }

  let optional_resource = function
    | None -> None
    | Some resource -> (
        match String.trim resource with
        | "" | "/" | "." | "./" -> None
        | resource -> Some resource)

  let codec =
    Jsont.Object.map ~kind:"skill input" (fun name resource ->
        { name; resource = optional_resource resource })
    |> Jsont.Object.mem "name" Jsont.string ~enc:(fun t -> t.name)
    |> Jsont.Object.opt_mem "resource" Jsont.string ~enc:(fun t -> t.resource)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_object
      [
        json_mem "type" (Jsont.Json.string "object");
        json_mem "properties"
          (json_object
             [
               json_mem "name"
                 (json_object
                    [
                      json_mem "type" (Jsont.Json.string "string");
                      json_mem "description"
                        (Jsont.Json.string
                           "Name of the skill to load, from the available \
                            skills listing.");
                    ]);
               json_mem "resource"
                 (json_object
                    [
                      json_mem "type" (Jsont.Json.string "string");
                      json_mem "minLength" (Jsont.Json.int 1);
                      json_mem "description"
                        (Jsont.Json.string
                           "Optional path of a resource file to read, relative \
                            to the skill directory. Use only resource names \
                            listed by the skill guidance. Omit this field, or \
                            pass /, to load the skill guidance.");
                    ]);
             ]);
        json_mem "required" (Jsont.Json.list [ Jsont.Json.string "name" ]);
        json_mem "additionalProperties" (Jsont.Json.bool false);
      ]

  let contract = Spice_tool.Input.make codec ~schema
end

let max_resource_bytes = 128 * 1024
let resource_truncation_marker = "\n[... resource truncated by spice ...]"

let active_names t =
  List.filter_map
    (fun (skill : Skill.t) ->
      match skill.Skill.status with
      | Skill.Active _ -> Some (Skill.Name.to_string skill.Skill.name)
      | _ -> None)
    t.skills

let skill_payload content =
  match content.Skill.resources with
  | [] -> content.Skill.body
  | resources ->
      content.Skill.body
      ^ "\n\nResources (load with the skill tool's resource field):\n"
      ^ String.concat "\n" (List.map (fun name -> "- " ^ name) resources)

let read_resource ~stdenv (skill : Skill.t) resource =
  match skill.Skill.dir with
  | None ->
      Error
        (Printf.sprintf
           "skill %S has no resource files; call the skill tool without \
            resource to load its guidance"
           (Skill.Name.to_string skill.Skill.name))
  | Some dir_abs -> (
      let fs = Eio.Stdenv.fs stdenv in
      let root = Spice_workspace.Root.make dir_abs in
      let workspace = Spice_workspace.single root in
      match Spice_workspace_fs.resolve ~workspace resource with
      | Error error -> Error (Spice_workspace_fs.Error.message error)
      | Ok path -> (
          match
            Spice_workspace_fs.load_regular ~fs ~workspace ~follow_symlink:true
              path
          with
          | Error error -> Error (Spice_workspace_fs.Error.message error)
          | Ok text ->
              if String.length text <= max_resource_bytes then Ok text
              else
                Ok
                  (take_utf8_prefix text max_resource_bytes
                  ^ resource_truncation_marker)))

let tool_name = "skill"

(* The single [skill] tool, or [None] when the surface is disabled or no skill
   is active. [tools] wraps this into the list run-tool assembly appends. *)
let tool ~stdenv t =
  if (not t.enabled) || active_names t = [] then None
  else
    let description =
      Spice_prompts.Tools.skill ^ "\n\nAvailable skills:\n"
      ^ Catalog.text t.catalog
    in
    let run _context (input : Tool_input.t) =
      let fail kind message = Spice_tool.Result.failed kind message in
      match Skill.Name.of_string input.Tool_input.name with
      | Error message -> fail `Invalid_input message
      | Ok name -> (
          match find_active t name with
          | None ->
              fail `Not_found
                (Printf.sprintf "unknown skill %S; available skills: %s"
                   input.Tool_input.name
                   (String.concat ", " (active_names t)))
          | Some (skill, content) -> (
              match input.Tool_input.resource with
              | None ->
                  Spice_tool.Result.completed ~output:(skill_payload content) ()
              | Some resource -> (
                  match read_resource ~stdenv skill resource with
                  | Ok text -> Spice_tool.Result.completed ~output:text ()
                  | Error message -> fail `Not_found message)))
    in
    Some
      (Spice_tool.make ~name:tool_name ~description ~input:Tool_input.contract
         ~output:(fun s ->
           Spice_tool.Output.make ~text:s ~json:(Jsont.Json.string s) ())
         ~run ())

let tools ~stdenv t = Option.to_list (tool ~stdenv t)

let injections t ~names =
  let resolve raw =
    match Skill.Name.of_string raw with
    | Error message -> Error message
    | Ok name -> (
        match find_active t name with
        | None ->
            Error
              (Printf.sprintf "unknown skill %S; available skills: %s" raw
                 (match active_names t with
                 | [] -> "(none)"
                 | names -> String.concat ", " names))
        | Some (_, content) ->
            Ok
              (Printf.sprintf
                 "The user invoked the %S skill. Follow it for this task.\n\n%s"
                 raw (skill_payload content)))
  in
  List.fold_left
    (fun acc raw ->
      match acc with
      | Error _ as error -> error
      | Ok texts -> (
          match resolve raw with
          | Ok text -> Ok (text :: texts)
          | Error _ as error -> error))
    (Ok []) names
  |> Result.map List.rev

let warnings t =
  let skill_warnings =
    List.filter_map
      (fun (skill : Skill.t) ->
        let name = Skill.Name.to_string skill.Skill.name in
        match skill.Skill.status with
        | Skill.Invalid invalid ->
            let reason =
              match invalid with
              | `Description_missing -> "frontmatter has no description"
              | `Description_too_long -> "description exceeds 1024 bytes"
              | `Invalid_frontmatter message | `Unreadable message -> message
            in
            Some
              (Printf.sprintf "skill %s (%s): %s" name skill.Skill.origin reason)
        | Skill.Active { Skill.ignored_keys = _ :: _ as keys; _ } ->
            Some
              (Printf.sprintf "skill %s: ignored frontmatter keys: %s" name
                 (String.concat ", " keys))
        | _ -> None)
      t.skills
  in
  let catalog_warnings =
    if Catalog.names_only t.catalog then
      [
        "skill catalog over budget: descriptions dropped for non-builtin skills";
      ]
    else
      match Catalog.trimmed t.catalog with
      | [] -> []
      | trimmed ->
          [
            Printf.sprintf
              "skill catalog over budget: descriptions trimmed for %s"
              (String.concat ", " (List.map Skill.Name.to_string trimmed));
          ]
  in
  skill_warnings @ catalog_warnings
