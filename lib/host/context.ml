(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.host.context" ~doc:"Instruction file discovery"

module Log = (val Logs.src_log log_src : Logs.LOG)

let local_override_filename = "AGENTS.override.md"
let agents_filename = "AGENTS.md"
let claude_filename = "CLAUDE.md"
let scan_cap = 2048
let scan_skip_dirs = [ ".git"; ".svn"; ".hg"; ".bzr"; ".jj"; ".sl" ]
let digest_string text = Spice_digest.Identity.(to_string (of_contents text))

(* JSON value helpers shared by the fact codecs. *)

let json_mem name value = Jsont.Json.mem (Jsont.Json.name name) value
let json_object fields = Jsont.Json.object' fields

type skip_reason =
  [ `Not_file
  | `Outside_workspace
  | `Unreadable of string
  | `Empty
  | `Budget_exhausted ]

module Source = struct
  type kind = Global | Project | Local_override | Compatibility

  type content = {
    bytes : int;
    digest : string;
    included_bytes : int;
    included_digest : string;
    omitted_bytes : int;
    utf8_repaired : bool;
  }

  type status =
    | Active of content
    | Shadowed of { by : Spice_path.Abs.t }
    | Disabled of [ `Instructions | `Project_instructions | `Compatibility ]
    | Not_activated
    | Skipped of skip_reason

  type t = {
    path : Spice_path.Abs.t;
    display_path : string;
    kind : kind;
    status : status;
  }

  let path t = t.path
  let display_path t = t.display_path
  let kind t = t.kind
  let status t = t.status

  let kind_string = function
    | Global -> "global"
    | Project -> "project"
    | Local_override -> "local_override"
    | Compatibility -> "compatibility"

  let state_string = function
    | Active _ -> "active"
    | Shadowed _ -> "shadowed"
    | Disabled _ -> "disabled"
    | Not_activated -> "not_activated"
    | Skipped _ -> "skipped"

  let reason_string = function
    | Active _ -> None
    | Shadowed { by } ->
        let by = Option.value (Spice_path.Abs.basename by) ~default:"" in
        if String.equal by local_override_filename then
          Some "shadowed_by_override"
        else Some "shadowed_by_agents"
    | Disabled `Instructions -> Some "instructions_disabled"
    | Disabled `Project_instructions -> Some "project_instructions_disabled"
    | Disabled `Compatibility -> Some "compatibility_disabled"
    | Not_activated -> Some "nested_not_activated"
    | Skipped `Not_file -> Some "not_file"
    | Skipped `Outside_workspace -> Some "outside_workspace"
    | Skipped (`Unreadable _) -> Some "unreadable"
    | Skipped `Empty -> Some "empty"
    | Skipped `Budget_exhausted -> Some "budget_exhausted"

  let to_json t =
    let reason =
      match reason_string t.status with
      | None -> Jsont.Json.null ()
      | Some reason -> Jsont.Json.string reason
    in
    let content =
      match t.status with
      | Active content ->
          [
            json_mem "bytes" (Jsont.Json.int content.bytes);
            json_mem "included_bytes" (Jsont.Json.int content.included_bytes);
            json_mem "digest" (Jsont.Json.string content.digest);
            json_mem "included_digest"
              (Jsont.Json.string content.included_digest);
            json_mem "omitted_bytes" (Jsont.Json.int content.omitted_bytes);
            json_mem "utf8_repaired" (Jsont.Json.bool content.utf8_repaired);
          ]
      | Shadowed _ | Disabled _ | Not_activated | Skipped _ -> []
    in
    json_object
      ([
         json_mem "path" (Jsont.Json.string (Spice_path.Abs.to_string t.path));
         json_mem "display_path" (Jsont.Json.string t.display_path);
         json_mem "kind" (Jsont.Json.string (kind_string t.kind));
         json_mem "state" (Jsont.Json.string (state_string t.status));
         json_mem "reason" reason;
       ]
      @ content)
end

module Fragment = struct
  type role = System | Developer | User
  type t = { role : role; text : string; sources : Spice_path.Abs.t list }

  let role t = t.role
  let text t = t.text

  let role_string = function
    | System -> "system"
    | Developer -> "developer"
    | User -> "user"

  let to_json t =
    json_object
      [
        json_mem "role" (Jsont.Json.string (role_string t.role));
        json_mem "sources"
          (Jsont.Json.list
             (List.map
                (fun path -> Jsont.Json.string (Spice_path.Abs.to_string path))
                t.sources));
        json_mem "text" (Jsont.Json.string t.text);
      ]
end

type t = {
  cwd : Spice_path.Abs.t;
  root : Spice_path.Abs.t;
  root_marker : string option;
  budget_used : int;
  nested_scan : [ `Off | `Complete | `Capped ];
  sources : Source.t list;
  fragments : Fragment.t list;
  rendered_digest : string;
}

let cwd t = t.cwd

let eio_cwd ~stdenv ?override t =
  (* The tools' filesystem authority prefers the process-restricted cwd
     capability: relativize the context cwd against the process working
     directory and reach it through [Stdenv.cwd] when it lies within. Otherwise
     fall back to the unrestricted [Stdenv.fs] rooted at the override or the
     absolute context cwd. *)
  let context_cwd = t.cwd in
  let process_cwd =
    Result.to_option
      (Spice_path.Abs.of_string (Eio.Path.native_exn (Eio.Stdenv.cwd stdenv)))
  in
  match
    Option.bind process_cwd (fun process_cwd ->
        Spice_path.Abs.relativize ~root:process_cwd context_cwd)
  with
  | Some rel ->
      Eio.Path.( / ) (Eio.Stdenv.cwd stdenv) (Spice_path.Rel.to_string rel)
  | None -> (
      match override with
      | Some abs ->
          Eio.Path.( / ) (Eio.Stdenv.fs stdenv) (Spice_path.Abs.to_string abs)
      | None ->
          Eio.Path.( / ) (Eio.Stdenv.fs stdenv)
            (Spice_path.Abs.to_string context_cwd))

let root t = t.root
let root_marker t = t.root_marker
let budget_used t = t.budget_used
let nested_scan t = t.nested_scan
let sources t = t.sources
let rendered_digest t = t.rendered_digest

(* Filesystem access for paths already validated as portable syntax. *)

let fs_abs stdenv abs =
  Eio.Path.( / ) (Eio.Stdenv.fs stdenv) (Spice_path.Abs.to_string abs)

let read_file ~stdenv abs =
  match Eio.Path.load (fs_abs stdenv abs) with
  | text -> Ok text
  | exception exn -> Error (Printexc.to_string exn)

let marker_exists stdenv dir =
  let path = Eio.Path.( / ) (fs_abs stdenv dir) ".git" in
  Eio.Path.is_file path || Eio.Path.is_directory path

let project_dirs ~root_path cwd_rel =
  let step (dir, acc) component =
    match Spice_workspace.Path.add_component dir component with
    | Ok next -> (next, next :: acc)
    | Error _ -> assert false
  in
  let _, acc =
    List.fold_left step (root_path, [ root_path ])
      (Spice_path.Rel.components cwd_rel)
  in
  List.rev acc

(* Candidate observation. Metadata only: stat with symlink following plus
   resolved-target containment, never content reads. *)

type observed = Missing | File | Bad of skip_reason

let observe ~fs ~workspace wpath =
  match
    Spice_workspace_fs.regular_opt ~fs ~workspace ~follow_symlink:true wpath
  with
  | Ok None -> Missing
  | Ok (Some _) -> File
  | Error (Spice_workspace_fs.Error.Escapes_workspace _) ->
      Bad `Outside_workspace
  | Error (Spice_workspace_fs.Error.Unexpected_kind _) -> Bad `Not_file
  | Error (Spice_workspace_fs.Error.Not_found _) -> Missing
  | Error error -> Bad (`Unreadable (Spice_workspace_fs.Error.message error))

type enabled = { global : bool; project : bool; claude_md : bool }

type pending =
  | Settled of Source.t
  | Read_candidate of {
      abs : Spice_path.Abs.t;
      display : string;
      kind : Source.kind;
    }

let make_source ~abs ~display ~kind status =
  { Source.path = abs; display_path = display; kind; status }

let project_display wpath = "./" ^ Spice_workspace.Path.display wpath

let resolve_dir ~fs ~workspace ~enabled dir =
  let candidates =
    [
      (local_override_filename, Source.Local_override);
      (agents_filename, Source.Project);
      (claude_filename, Source.Compatibility);
    ]
  in
  let observed =
    List.filter_map
      (fun (name, kind) ->
        match Spice_workspace_fs.child dir name with
        | Error _ -> None
        | Ok wpath -> Some (kind, wpath, observe ~fs ~workspace wpath))
      candidates
  in
  let settle (winner, acc) (kind, wpath, obs) =
    let abs = Spice_workspace.Path.abs wpath in
    let display = project_display wpath in
    let settled status =
      (winner, Settled (make_source ~abs ~display ~kind status) :: acc)
    in
    match obs with
    | Missing -> (winner, acc)
    | (File | Bad _) when not enabled.project ->
        settled (Source.Disabled `Project_instructions)
    | (File | Bad _)
      when (match kind with
             | Source.Compatibility -> true
             | Source.Global | Source.Project | Source.Local_override -> false)
           && not enabled.claude_md ->
        settled (Source.Disabled `Compatibility)
    | Bad reason -> settled (Source.Skipped reason)
    | File -> (
        match winner with
        | Some by -> settled (Source.Shadowed { by })
        | None -> (Some abs, Read_candidate { abs; display; kind } :: acc))
  in
  let _, acc = List.fold_left settle (None, []) observed in
  List.rev acc

(* Text projection. UTF-8 repair, trimming, and budget accounting are pure.
   The budget counts original file bytes; truncation slices the repaired text
   at a character boundary. *)

let utf8_lossy text =
  if String.is_valid_utf_8 text then text
  else
    let replacement = Uchar.of_int 0xFFFD in
    let buffer = Buffer.create (String.length text) in
    let rec loop index =
      if index >= String.length text then Buffer.contents buffer
      else
        let decode = String.get_utf_8_uchar text index in
        let length = max 1 (Uchar.utf_decode_length decode) in
        let uchar =
          if Uchar.utf_decode_is_valid decode then Uchar.utf_decode_uchar decode
          else replacement
        in
        Buffer.add_utf_8_uchar buffer uchar;
        loop (index + length)
    in
    loop 0

let take_utf8_prefix text max_bytes =
  if max_bytes <= 0 then ""
  else if String.length text <= max_bytes then text
  else
    let rec boundary stop =
      if stop >= max_bytes then stop
      else
        let decode = String.get_utf_8_uchar text stop in
        let length = max 1 (Uchar.utf_decode_length decode) in
        if stop + length > max_bytes then stop else boundary (stop + length)
    in
    String.sub text 0 (boundary 0)

let instruction_header display = "Instructions from: " ^ display

let truncated_marker ~budget ~omitted =
  "[Instruction file truncated: omitted " ^ string_of_int omitted
  ^ " byte(s) due to the " ^ string_of_int budget
  ^ "-byte project instruction budget]"

let omitted_marker =
  "[Instruction file omitted: project instruction budget exhausted]"

let read_facts raw =
  ( String.length raw,
    digest_string raw,
    not (String.is_valid_utf_8 raw),
    String.trim (utf8_lossy raw) )

let global_entry ~stdenv ~abs ~display ~kind =
  match read_file ~stdenv abs with
  | Error message ->
      ( make_source ~abs ~display ~kind (Source.Skipped (`Unreadable message)),
        None )
  | Ok raw ->
      let bytes, digest, utf8_repaired, text = read_facts raw in
      if String.is_empty text then
        (make_source ~abs ~display ~kind (Source.Skipped `Empty), None)
      else
        let content =
          {
            Source.bytes;
            digest;
            included_bytes = String.length text;
            included_digest = digest_string text;
            omitted_bytes = 0;
            utf8_repaired;
          }
        in
        ( make_source ~abs ~display ~kind (Source.Active content),
          Some (instruction_header display ^ "\n" ^ text) )

let project_entry ~stdenv ~budget ~remaining ~abs ~display ~kind =
  if remaining <= 0 then
    ( make_source ~abs ~display ~kind (Source.Skipped `Budget_exhausted),
      Some (instruction_header display ^ "\n" ^ omitted_marker),
      remaining )
  else
    match read_file ~stdenv abs with
    | Error message ->
        ( make_source ~abs ~display ~kind (Source.Skipped (`Unreadable message)),
          None,
          remaining )
    | Ok raw ->
        let bytes, digest, utf8_repaired, text = read_facts raw in
        let consumed = min bytes remaining in
        let omitted = bytes - consumed in
        let remaining = remaining - consumed in
        let text =
          if omitted = 0 then text
          else String.trim (take_utf8_prefix text consumed)
        in
        if String.is_empty text && omitted = 0 then
          ( make_source ~abs ~display ~kind (Source.Skipped `Empty),
            None,
            remaining )
        else
          let body =
            if omitted = 0 then text
            else if String.is_empty text then truncated_marker ~budget ~omitted
            else text ^ "\n\n" ^ truncated_marker ~budget ~omitted
          in
          let content =
            {
              Source.bytes;
              digest;
              included_bytes = String.length text;
              included_digest = digest_string text;
              omitted_bytes = omitted;
              utf8_repaired;
            }
          in
          ( make_source ~abs ~display ~kind (Source.Active content),
            Some (instruction_header display ^ "\n" ^ body),
            remaining )

let read_project ~stdenv ~budget pendings =
  let step (sources, blocks, remaining) = function
    | Settled source -> (source :: sources, blocks, remaining)
    | Read_candidate { abs; display; kind } ->
        let source, block, remaining =
          project_entry ~stdenv ~budget ~remaining ~abs ~display ~kind
        in
        let blocks =
          match block with
          | None -> blocks
          | Some block -> (abs, block) :: blocks
        in
        (source :: sources, blocks, remaining)
  in
  let sources, blocks, remaining =
    List.fold_left step ([], [], budget) pendings
  in
  (List.rev sources, List.rev blocks, remaining)

(* The global candidate is a single [AGENTS.md] in the user config directory,
   observed against its own config-home-rooted workspace and never budgeted. *)

let global_candidate ~stdenv ~fs ~enabled config =
  match
    Config.Config_file.user (Config.files config) |> Spice_path.Abs.parent
  with
  | None -> ([], [])
  | Some dir_abs -> (
      let root = Spice_workspace.Root.make dir_abs in
      let workspace = Spice_workspace.single root in
      let root_path = Spice_workspace.Path.make ~root Spice_path.Rel.root in
      match Spice_workspace_fs.child root_path agents_filename with
      | Error _ -> ([], [])
      | Ok wpath -> (
          let abs = Spice_workspace.Path.abs wpath in
          let display = Spice_path.Abs.to_string abs in
          let kind = Source.Global in
          let settled status =
            ([ make_source ~abs ~display ~kind status ], [])
          in
          match observe ~fs ~workspace wpath with
          | Missing -> ([], [])
          | (File | Bad _) when not enabled.global ->
              settled (Source.Disabled `Instructions)
          | Bad reason -> settled (Source.Skipped reason)
          | File ->
              let source, block = global_entry ~stdenv ~abs ~display ~kind in
              let blocks =
                match block with None -> [] | Some block -> [ (abs, block) ]
              in
              ([ source ], blocks)))

(* Nested audit scan: directories strictly below cwd, lexicographic, no
   symlink following, VCS metadata skipped, capped. Facts only. *)

let nested_scan_sources ~fs ~workspace cwd_path =
  let found = ref [] in
  let visited = ref 0 in
  let capped = ref false in
  let rec walk ~record dir =
    if !capped then ()
    else if !visited >= scan_cap then capped := true
    else begin
      incr visited;
      match Spice_workspace_fs.read_dir_names ~fs ~workspace dir with
      | Error _ -> ()
      | Ok names ->
          let names = List.sort String.compare names in
          List.iter
            (fun name ->
              if not !capped then
                match Spice_workspace_fs.child dir name with
                | Error _ -> ()
                | Ok child -> (
                    match
                      Spice_workspace_fs.stat ~fs ~workspace
                        ~follow_symlink:false child
                    with
                    | Ok (Some stat) -> (
                        match stat.Eio.File.Stat.kind with
                        | `Directory when not (List.mem name scan_skip_dirs) ->
                            walk ~record:true child
                        | `Regular_file
                          when record && String.equal name agents_filename ->
                            found := child :: !found
                        | _ -> ())
                    | Ok None | Error _ -> ()))
            names
    end
  in
  walk ~record:false cwd_path;
  let sources =
    List.rev_map
      (fun wpath ->
        make_source
          ~abs:(Spice_workspace.Path.abs wpath)
          ~display:(project_display wpath) ~kind:Source.Project
          Source.Not_activated)
      !found
  in
  (sources, if !capped then `Capped else `Complete)

(* Projection rendering. The layout is byte-stable: a base
   system identity, a workspace developer message, and one contextual user
   message wrapping per-source instruction blocks. *)

let workspace_text cwd_text =
  "# Workspace\n\nCurrent working directory: " ^ cwd_text

let instructions_text cwd_text blocks =
  "# AGENTS.md instructions for " ^ cwd_text ^ "\n\n<INSTRUCTIONS>\n"
  ^ String.concat "\n\n" blocks
  ^ "\n</INSTRUCTIONS>"

let render_fragments ~cwd_text blocks =
  let base =
    [
      {
        Fragment.role = Fragment.System;
        text = Spice_prompts.system;
        sources = [];
      };
      {
        Fragment.role = Fragment.Developer;
        text = workspace_text cwd_text;
        sources = [];
      };
    ]
  in
  match blocks with
  | [] -> base
  | blocks ->
      base
      @ [
          {
            Fragment.role = Fragment.User;
            text = instructions_text cwd_text (List.map snd blocks);
            sources = List.map fst blocks;
          };
        ]

(* The length prefix keeps the encoding injective over the (role, text)
   fragment sequence: digest equality implies byte equality. It must not be
   reduced to plain concatenation, which would confuse fragment boundaries. *)
let digest_fragments fragments =
  let buffer = Buffer.create 1024 in
  List.iter
    (fun fragment ->
      let add text =
        Buffer.add_string buffer (string_of_int (String.length text));
        Buffer.add_char buffer ':';
        Buffer.add_string buffer text
      in
      add (Fragment.role_string (Fragment.role fragment));
      add (Fragment.text fragment))
    fragments;
  digest_string (Buffer.contents buffer)

let message_of_fragment fragment =
  match Fragment.role fragment with
  | Fragment.System -> Spice_llm.Message.system (Fragment.text fragment)
  | Fragment.Developer -> Spice_llm.Message.developer (Fragment.text fragment)
  | Fragment.User -> Spice_llm.Message.user_text (Fragment.text fragment)

let projection_messages t = List.map message_of_fragment t.fragments
let projection_texts t = List.map Fragment.text t.fragments
let projection_json t = List.map Fragment.to_json t.fragments

let to_prelude t =
  match Spice_llm.Request.Prelude.make (projection_messages t) with
  | Ok prelude -> prelude
  | Error _ ->
      (* Fragment roles are exactly the prelude-admissible message kinds. *)
      assert false

let extend_prelude t messages =
  Spice_llm.Request.Prelude.append (to_prelude t) messages

let warnings t =
  let source_warnings source =
    let display = Source.display_path source in
    match Source.status source with
    | Source.Skipped (`Unreadable message) -> [ display ^ ": " ^ message ]
    | Source.Skipped `Budget_exhausted ->
        [ display ^ ": omitted: project instruction budget exhausted" ]
    | Source.Active content ->
        (if content.Source.omitted_bytes > 0 then
           [
             display ^ ": truncated: omitted "
             ^ string_of_int content.Source.omitted_bytes
             ^ " byte(s) by the project instruction budget";
           ]
         else [])
        @
        if content.Source.utf8_repaired then
          [ display ^ ": invalid UTF-8 replaced with U+FFFD" ]
        else []
    | Source.Shadowed _ | Source.Disabled _ | Source.Not_activated
    | Source.Skipped (`Not_file | `Outside_workspace | `Empty) ->
        []
  in
  let compatibility_guidance =
    (* A project whose only instruction file is a disabled CLAUDE.md should
       say so clearly and point to the way out. *)
    let disabled_compatibility source =
      match Source.status source with
      | Source.Disabled `Compatibility -> true
      | Source.Active _ | Source.Shadowed _
      | Source.Disabled (`Instructions | `Project_instructions)
      | Source.Not_activated | Source.Skipped _ ->
          false
    in
    let active_project source =
      match (Source.kind source, Source.status source) with
      | ( (Source.Project | Source.Local_override | Source.Compatibility),
          Source.Active _ ) ->
          true
      | _, _ -> false
    in
    if
      List.exists disabled_compatibility t.sources
      && not (List.exists active_project t.sources)
    then
      [
        "CLAUDE.md compatibility is disabled; enable instructions.claude_md or \
         migrate to AGENTS.md";
      ]
    else []
  in
  List.concat_map source_warnings t.sources
  @ compatibility_guidance
  @
  match t.nested_scan with
  | `Capped ->
      [
        "nested instruction scan stopped at " ^ string_of_int scan_cap
        ^ " directories";
      ]
  | `Off | `Complete -> []

let load ~stdenv ?(nested_scan = false) config =
  let cwd = Config.cwd config in
  let cwd_text = Spice_path.Abs.to_string cwd in
  let root = Config.project_root config in
  let root_marker = if marker_exists stdenv root then Some ".git" else None in
  let ws_root = Spice_workspace.Root.make root in
  let cwd_rel =
    match Spice_path.Abs.relativize ~root cwd with
    | Some rel -> rel
    | None -> assert false
  in
  let workspace = Spice_workspace.single ~cwd:cwd_rel ws_root in
  let root_path = Spice_workspace.Path.make ~root:ws_root Spice_path.Rel.root in
  let cwd_path = Spice_workspace.Path.make ~root:ws_root cwd_rel in
  let instructions = Config.instructions config in
  let enabled =
    {
      global = Config.Instructions.global instructions;
      project = Config.Instructions.project instructions;
      claude_md = Config.Instructions.claude_md instructions;
    }
  in
  let budget = Config.Instructions.project_max_bytes instructions in
  let fs = Eio.Stdenv.fs stdenv in
  let global_sources, global_blocks =
    global_candidate ~stdenv ~fs ~enabled config
  in
  let trusted = Trust.is_trusted (Config.workspace_trust config) in
  let project_sources, project_blocks, remaining =
    if trusted then
      let pendings =
        List.concat_map
          (resolve_dir ~fs ~workspace ~enabled)
          (project_dirs ~root_path cwd_rel)
      in
      read_project ~stdenv ~budget pendings
    else ([], [], budget)
  in
  let nested_sources, scan_state =
    if trusted && nested_scan then nested_scan_sources ~fs ~workspace cwd_path
    else ([], `Off)
  in
  let fragments = render_fragments ~cwd_text (global_blocks @ project_blocks) in
  let sources = global_sources @ project_sources @ nested_sources in
  let active_count =
    List.length
      (List.filter
         (fun source ->
           match Source.status source with
           | Source.Active _ -> true
           | _ -> false)
         sources)
  in
  Log.debug (fun m ->
      m "context loaded sources=%d active=%d budget_used=%d"
        (List.length sources) active_count (budget - remaining));
  Ok
    {
      cwd;
      root;
      root_marker;
      budget_used = budget - remaining;
      nested_scan = scan_state;
      sources;
      fragments;
      rendered_digest = digest_fragments fragments;
    }
