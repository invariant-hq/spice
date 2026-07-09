(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Frontmatter = Spice_frontmatter

let parsed doc =
  match Frontmatter.parse doc with
  | Ok t -> t
  | Error error ->
      failf "unexpected parse error: %s" (Frontmatter.Error.message error)

let parse_error doc =
  match Frontmatter.parse doc with
  | Ok _ -> fail "expected a parse error"
  | Error error -> error

let no_fence () =
  let doc = "# Title\n\nNo header here.\n" in
  let t = parsed doc in
  equal (list string) ~msg:"no keys" [] (Frontmatter.keys t);
  equal string ~msg:"body is the whole document" doc (Frontmatter.body t)

let dashes_not_at_line_start () =
  let doc = "----\nkey: value\n---\nbody\n" in
  let t = parsed doc in
  equal (list string) ~msg:"four dashes do not open a fence" []
    (Frontmatter.keys t);
  equal string ~msg:"body is the whole document" doc (Frontmatter.body t)

let spaces_do_not_open_a_fence () =
  let docs =
    [
      "--- \nkey: value\n---\nbody\n";
      " ---\nkey: value\n---\nbody\n";
      "\t---\nkey: value\n---\nbody\n";
    ]
  in
  List.iter
    (fun doc ->
      let t = parsed doc in
      equal (list string) ~msg:"no keys" [] (Frontmatter.keys t);
      equal string ~msg:"body is the whole document" doc (Frontmatter.body t))
    docs

let spaces_do_not_close_a_fence () =
  match parse_error "---\nkey: value\n--- \nbody\n" with
  | Frontmatter.Error.Unterminated -> ()
  | error -> failf "expected Unterminated: %s" (Frontmatter.Error.message error)

let four_dashes_do_not_close_a_fence () =
  match parse_error "---\nkey: value\n----\nbody\n" with
  | Frontmatter.Error.Unterminated -> ()
  | error -> failf "expected Unterminated: %s" (Frontmatter.Error.message error)

let empty_fence () =
  let t = parsed "---\n---\nbody\n" in
  equal (list string) ~msg:"no keys" [] (Frontmatter.keys t);
  equal string ~msg:"body follows the closing fence" "body\n"
    (Frontmatter.body t)

let whitespace_only_fence () =
  let t = parsed "---\n   \n\n---\nbody\n" in
  equal (list string) ~msg:"no keys" [] (Frontmatter.keys t)

let string_fields () =
  let t =
    parsed
      "---\nname: ocaml-release\ndescription: \"Cut a release.\"\n---\nbody\n"
  in
  equal (option string) ~msg:"plain unquoted string" (Some "ocaml-release")
    (Frontmatter.string "name" t);
  equal (option string) ~msg:"quoted string" (Some "Cut a release.")
    (Frontmatter.string "description" t);
  equal (option string) ~msg:"absent key" None (Frontmatter.string "missing" t)

let non_string_scalar_fields_are_not_read () =
  let t =
    parsed "---\ncount: 3\nratio: 1.5\nenabled: true\nempty:\n---\nbody\n"
  in
  equal (option string) ~msg:"integer number" None
    (Frontmatter.string "count" t);
  equal (option string) ~msg:"decimal number" None
    (Frontmatter.string "ratio" t);
  equal (option string) ~msg:"boolean" None (Frontmatter.string "enabled" t);
  equal (option string) ~msg:"null" None (Frontmatter.string "empty" t)

let structured_fields_are_listed_not_read () =
  let t =
    parsed
      "---\n\
       description: Use carefully.\n\
       allowed-tools:\n\
      \  - Bash\n\
      \  - Read\n\
       hooks:\n\
      \  pre: echo hi\n\
       empty:\n\
       ---\n\
       body\n"
  in
  equal (list string) ~msg:"keys list every key in document order"
    [ "description"; "allowed-tools"; "hooks"; "empty" ]
    (Frontmatter.keys t);
  equal (option string) ~msg:"list value reads as None" None
    (Frontmatter.string "allowed-tools" t);
  equal (option string) ~msg:"mapping value reads as None" None
    (Frontmatter.string "hooks" t);
  equal (option string) ~msg:"null value reads as None" None
    (Frontmatter.string "empty" t);
  equal (option string) ~msg:"string still reads" (Some "Use carefully.")
    (Frontmatter.string "description" t)

let yaml_alias_values_are_not_a_parse_error () =
  let t =
    parsed
      "---\ndescription: &desc \"Use carefully.\"\ncopy: *desc\n---\nbody\n"
  in
  equal (list string) ~msg:"keys list aliases in document order"
    [ "description"; "copy" ] (Frontmatter.keys t);
  equal (option string) ~msg:"anchored scalar reads as a string"
    (Some "Use carefully.")
    (Frontmatter.string "description" t);
  equal (option string) ~msg:"alias values are not string fields" None
    (Frontmatter.string "copy" t)

let unterminated_fence () =
  match parse_error "---\nkey: value\nbody without closing fence\n" with
  | Frontmatter.Error.Unterminated -> ()
  | error -> failf "expected Unterminated: %s" (Frontmatter.Error.message error)

let fence_only_document () =
  match parse_error "---" with
  | Frontmatter.Error.Unterminated -> ()
  | error -> failf "expected Unterminated: %s" (Frontmatter.Error.message error)

let invalid_yaml () =
  match parse_error "---\nkey: [unclosed\n---\nbody\n" with
  | Frontmatter.Error.Invalid_yaml message ->
      is_true ~msg:"carries a parser message" (String.length message > 0)
  | error -> failf "expected Invalid_yaml: %s" (Frontmatter.Error.message error)

let non_mapping_top_level () =
  match parse_error "---\n- one\n- two\n---\nbody\n" with
  | Frontmatter.Error.Not_a_mapping -> ()
  | error ->
      failf "expected Not_a_mapping: %s" (Frontmatter.Error.message error)

let null_top_level () =
  match parse_error "---\nnull\n---\nbody\n" with
  | Frontmatter.Error.Not_a_mapping -> ()
  | error ->
      failf "expected Not_a_mapping: %s" (Frontmatter.Error.message error)

let crlf_input () =
  let t = parsed "---\r\ndescription: Windows file.\r\n---\r\nbody\r\n" in
  equal (option string) ~msg:"field parses through CRLF" (Some "Windows file.")
    (Frontmatter.string "description" t);
  equal string ~msg:"body keeps its CRLF bytes" "body\r\n" (Frontmatter.body t)

let body_is_byte_exact () =
  let t = parsed "---\nkey: value\n---\n\n  indented\ttext\n" in
  equal string ~msg:"body keeps leading blank line and whitespace"
    "\n  indented\ttext\n" (Frontmatter.body t)

let closing_fence_at_end_of_input () =
  let t = parsed "---\nkey: value\n---" in
  equal string ~msg:"empty body after a final fence without newline" ""
    (Frontmatter.body t);
  equal (option string) ~msg:"field still parses" (Some "value")
    (Frontmatter.string "key" t)

let duplicate_keys_preserved () =
  let t = parsed "---\nname: first\nname: second\n---\nbody\n" in
  equal (list string) ~msg:"duplicates preserved in order" [ "name"; "name" ]
    (Frontmatter.keys t);
  equal (option string) ~msg:"string reads the first occurrence" (Some "first")
    (Frontmatter.string "name" t)

let () =
  run "spice.frontmatter"
    [
      test "treats a fenceless document as all body" no_fence;
      test "requires the fence to be exactly three dashes"
        dashes_not_at_line_start;
      test "does not allow spaces around an opening fence"
        spaces_do_not_open_a_fence;
      test "does not allow spaces around a closing fence"
        spaces_do_not_close_a_fence;
      test "does not allow four dashes as a closing fence"
        four_dashes_do_not_close_a_fence;
      test "parses an empty fence" empty_fence;
      test "parses a whitespace-only fence" whitespace_only_fence;
      test "reads YAML string fields" string_fields;
      test "does not coerce non-string scalar fields"
        non_string_scalar_fields_are_not_read;
      test "lists structured fields without reading them"
        structured_fields_are_listed_not_read;
      test "does not reject YAML aliases"
        yaml_alias_values_are_not_a_parse_error;
      test "errors on an unterminated fence" unterminated_fence;
      test "errors on a fence-only document" fence_only_document;
      test "errors on invalid YAML" invalid_yaml;
      test "errors on a non-mapping top level" non_mapping_top_level;
      test "errors on an explicit null top level" null_top_level;
      test "handles CRLF input" crlf_input;
      test "keeps the body byte-exact" body_is_byte_exact;
      test "accepts a closing fence at end of input"
        closing_fence_at_end_of_input;
      test "preserves duplicate keys in order" duplicate_keys_preserved;
    ]
