(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Emits the [Spice_prompts] module from prompt text files.

   Usage: gen -o OUTPUT FILE.md...

   Each file becomes one [string] value named after the file stem; each
   directory level becomes one nested module. File contents are embedded
   byte-exact except for one final newline, which editors enforce on text
   files and prompts must not depend on.

   Files under a [skills] directory are builtin skills, not stem values:
   each [skills/NAME.md] becomes one [(NAME, contents)] entry of
   [Skills.all]. Skill frontmatter is validated here so an invalid builtin
   skill fails the build, with the same parser the runtime uses. *)

let fail fmt =
  Printf.ksprintf
    (fun message ->
      prerr_endline message;
      exit 1)
    fmt

let is_valid_name name =
  String.length name > 0
  && (match name.[0] with 'a' .. 'z' -> true | _ -> false)
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
       name

let value_name path stem =
  if not (is_valid_name stem) then
    fail "%s: %S is not a lowercase OCaml identifier; rename the file" path stem;
  stem

let module_name path dir =
  if not (is_valid_name dir) then
    fail "%s: directory %S is not a lowercase OCaml identifier" path dir;
  String.capitalize_ascii dir

let read_contents path =
  let ic = open_in_bin path in
  let length = in_channel_length ic in
  let contents = really_input_string ic length in
  close_in ic;
  let length = String.length contents in
  if length > 0 && contents.[length - 1] = '\n' then
    String.sub contents 0 (length - 1)
  else contents

(* One prompt file keyed by its directory components and value name. *)
type entry = { dirs : string list; name : string; contents : string }

let path_components path =
  let rec components acc dir =
    if String.equal dir "." then acc
    else components (Filename.basename dir :: acc) (Filename.dirname dir)
  in
  components [] (Filename.dirname path)

let is_skill_file path = List.mem "skills" (path_components path)

let entry path =
  let stem = Filename.remove_extension (Filename.basename path) in
  let dirs = path_components path in
  List.iter (fun dir -> ignore (module_name path dir)) dirs;
  { dirs; name = value_name path stem; contents = read_contents path }

(* Builtin skill validation. The name grammar and description cap must stay
   in sync with the runtime skill loader; both pin them with tests. *)

let max_skill_name_bytes = 64
let max_skill_description_bytes = 1024

let is_consumed_metadata_key key =
  String.equal key "name" || String.equal key "description"

let duplicate_consumed_metadata_key keys =
  let rec loop seen = function
    | [] -> None
    | key :: keys ->
        if is_consumed_metadata_key key && List.exists (String.equal key) seen
        then Some key
        else
          let seen = if is_consumed_metadata_key key then key :: seen else seen in
          loop seen keys
  in
  loop [] keys

let metadata_text path field value =
  if
    String.exists
      (fun c ->
        let code = Char.code c in
        code < 0x20 || code = 0x7F)
      value
  then fail "%s: frontmatter %s must be single-line text" path field

let is_valid_skill_name name =
  String.length name > 0
  && String.length name <= max_skill_name_bytes
  && (match name.[0] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false)
       name

let skill_entry path =
  (match List.rev (path_components path) with
  | "skills" :: _ -> ()
  | _ -> fail "%s: the skills directory holds flat NAME.md files only" path);
  let name = Filename.remove_extension (Filename.basename path) in
  if not (is_valid_skill_name name) then
    fail
      "%s: %S is not a skill name (lowercase letters, digits, and hyphens; at \
       most %d bytes); rename the file"
      path name max_skill_name_bytes;
  let contents = read_contents path in
  let header =
    match Spice_frontmatter.parse contents with
    | Ok header -> header
    | Error error -> fail "%s: %s" path (Spice_frontmatter.Error.message error)
  in
  (match duplicate_consumed_metadata_key (Spice_frontmatter.keys header) with
  | None -> ()
  | Some key -> fail "%s: frontmatter %s must appear only once" path key);
  (match Spice_frontmatter.string "description" header with
  | None -> fail "%s: frontmatter must carry a description string" path
  | Some description
    when String.length description > max_skill_description_bytes ->
      fail "%s: description exceeds %d bytes" path max_skill_description_bytes
  | Some description -> metadata_text path "description" description);
  (match Spice_frontmatter.string "name" header with
  | None -> ()
  | Some name -> metadata_text path "name" name);
  (name, contents)

let skill_entries paths =
  let entries = List.map skill_entry paths in
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) entries in
  let rec check_duplicates = function
    | (a, _) :: ((b, _) :: _ as rest) ->
        if String.equal a b then
          fail "skill %S is declared by more than one skills file" a;
        check_duplicates rest
    | _ -> []
  in
  ignore (check_duplicates sorted);
  sorted

let rec emit buffer indent entries =
  let value, nested = List.partition (fun entry -> entry.dirs = []) entries in
  let pad = String.make (2 * indent) ' ' in
  List.iter
    (fun entry ->
      Printf.bprintf buffer "%slet %s = %S\n" pad entry.name entry.contents)
    (List.sort (fun a b -> compare a.name b.name) value);
  let submodules =
    List.sort_uniq compare (List.map (fun entry -> List.hd entry.dirs) nested)
  in
  List.iter
    (fun dir ->
      let children =
        List.filter_map
          (fun entry ->
            match entry.dirs with
            | head :: rest when String.equal head dir ->
                Some { entry with dirs = rest }
            | _ -> None)
          nested
      in
      Printf.bprintf buffer "\n%smodule %s = struct\n" pad
        (String.capitalize_ascii dir);
      emit buffer (indent + 1) children;
      Printf.bprintf buffer "%send\n" pad)
    submodules

let () =
  let output = ref None in
  let inputs = ref [] in
  let rec parse = function
    | [] -> ()
    | "-o" :: path :: rest ->
        output := Some path;
        parse rest
    | path :: rest ->
        inputs := path :: !inputs;
        parse rest
  in
  parse (List.tl (Array.to_list Sys.argv));
  let output =
    match !output with Some path -> path | None -> fail "missing -o OUTPUT"
  in
  let inputs = List.sort compare !inputs in
  let skill_paths, prompt_paths = List.partition is_skill_file inputs in
  let entries = List.map entry prompt_paths in
  let skills = skill_entries skill_paths in
  let buffer = Buffer.create 8192 in
  Buffer.add_string buffer
    "(* Generated by prompts/gen from the files in prompts/. Do not edit. *)\n\n";
  emit buffer 0 entries;
  Buffer.add_string buffer "\nmodule Skills = struct\n  let all =\n    [\n";
  List.iter
    (fun (name, contents) ->
      Printf.bprintf buffer "      (%S, %S);\n" name contents)
    skills;
  Buffer.add_string buffer "    ]\nend\n";
  let oc = open_out_bin output in
  output_string oc (Buffer.contents buffer);
  close_out oc
