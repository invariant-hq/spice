(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Cr = Spice_cr
module Path = Spice_path
module Identity = Spice_digest.Identity

let error_kind =
  let pp ppf = function
    | Cr.Error.Invalid_handle -> Format.pp_print_string ppf "Invalid_handle"
    | Cr.Error.Invalid_body -> Format.pp_print_string ppf "Invalid_body"
    | Cr.Error.Invalid_syntax -> Format.pp_print_string ppf "Invalid_syntax"
    | Cr.Error.Invalid_comment -> Format.pp_print_string ppf "Invalid_comment"
    | Cr.Error.Invalid_anchor -> Format.pp_print_string ppf "Invalid_anchor"
    | Cr.Error.Stale_occurrence -> Format.pp_print_string ppf "Stale_occurrence"
  in
  testable ~pp ~equal:( = ) ()

let handle_value = testable ~pp:Cr.Handle.pp ~equal:Cr.Handle.equal ()
let status_value = testable ~pp:Cr.Status.pp ~equal:Cr.Status.equal ()

(* CR identities are [Spice_digest.Identity.t]: SHA-256 content identities whose
   canonical form is [sha256:<64 hex>:<byte length>]. Identity's own grammar is
   covered by test_digest; here we assert the CR module produces well-formed
   identities and uses them for equality. *)
let digest_value = testable ~pp:Identity.pp ~equal:Identity.equal ()

let is_hex64 s =
  String.length s = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) s

let check_identity_form msg identity =
  is_true
    ~msg:(msg ^ ": digest_hex is 64 lowercase hex characters")
    (is_hex64 (Identity.digest_hex identity));
  equal string
    ~msg:(msg ^ ": to_string is the canonical sha256:<hex>:<len> token")
    (Printf.sprintf "sha256:%s:%d"
       (Identity.digest_hex identity)
       (Identity.byte_length identity))
    (Identity.to_string identity)

let syntax_value = testable ~pp:Cr.Syntax.pp ~equal:Cr.Syntax.equal ()

let rel path =
  match Path.Rel.of_string path with
  | Ok path -> path
  | Error error -> failf "invalid relative path: %a" Path.Error.pp error

let source_path = rel "lib/a.ml"

let expect_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Cr.Error.pp error

let expect_error msg expected = function
  | Ok _ -> failf "%s: expected error" msg
  | Error error -> equal error_kind ~msg expected (Cr.Error.kind error)

let handle text = expect_ok text (Cr.Handle.of_string text)

let make ?priority ?recipient body =
  expect_ok body (Cr.make ?priority ?recipient ~body ())

let parse text = expect_ok text (Cr.parse text)

let expect_comment msg occurrence =
  expect_ok msg (Cr.Occurrence.comment occurrence)

let expect_occurrence_error msg expected occurrence =
  expect_error msg expected (Cr.Occurrence.comment occurrence)

let nth_occurrence msg n occurrences =
  match List.nth_opt occurrences n with
  | Some occurrence -> occurrence
  | None -> failf "%s: missing occurrence %d" msg n

let handle_validation () =
  let spice = handle "spice" in
  equal string ~msg:"handle source form" "spice" (Cr.Handle.to_string spice);
  equal handle_value ~msg:"handles compare by source form" spice
    (handle "spice");
  List.iter
    (fun text ->
      expect_error
        ("invalid handle " ^ String.escaped text)
        Cr.Error.Invalid_handle (Cr.Handle.of_string text))
    [
      "";
      "two words";
      "agent:one";
      "agent\000one";
      "agent\011one";
      "agent\012one";
    ]

let comment_construction_and_resolution () =
  let recipient = handle "spice" in
  let resolver = handle "agent" in
  let cr = make ~recipient "  tighten this  " in
  equal string ~msg:"default priority is now" "now"
    (Cr.Priority.to_string Cr.Priority.default);
  equal status_value ~msg:"default status is open now"
    (Cr.Status.Open Cr.Priority.Now) (Cr.status cr);
  equal (option handle_value) ~msg:"recipient is retained" (Some recipient)
    (Cr.recipient cr);
  equal string ~msg:"body is trimmed" "tighten this" (Cr.body cr);
  equal string ~msg:"open CR renders canonically" "CR spice: tighten this"
    (Cr.to_string cr);
  let resolved = expect_ok "resolve" (Cr.resolve ~resolver cr) in
  equal status_value ~msg:"resolve records resolver"
    (Cr.Status.Resolved { resolver })
    (Cr.status resolved);
  equal string ~msg:"resolve retains body and recipient"
    "XCR agent for spice: tighten this" (Cr.to_string resolved);
  let rewritten =
    expect_ok "resolve with body" (Cr.resolve ~resolver ~body:" fixed " cr)
  in
  equal string ~msg:"resolve can replace body" "XCR agent for spice: fixed"
    (Cr.to_string rewritten);
  expect_error "empty body" Cr.Error.Invalid_body (Cr.make ~body:"  " ());
  expect_error "NUL body" Cr.Error.Invalid_body (Cr.make ~body:"a\000b" ())

let parsing_and_rendering () =
  let cases =
    [
      (" CR: fix it ", "CR: fix it", Cr.Status.Open Cr.Priority.Now, None);
      ( "CR spice: fix it",
        "CR spice: fix it",
        Cr.Status.Open Cr.Priority.Now,
        Some "spice" );
      ( "CR-soon spice: fix it",
        "CR-soon spice: fix it",
        Cr.Status.Open Cr.Priority.Soon,
        Some "spice" );
      ( "XCR agent: fixed",
        "XCR agent: fixed",
        Cr.Status.Resolved { resolver = handle "agent" },
        None );
      ( "XCR agent for spice: fixed",
        "XCR agent for spice: fixed",
        Cr.Status.Resolved { resolver = handle "agent" },
        Some "spice" );
    ]
  in
  List.iter
    (fun (input, rendered, status, recipient) ->
      let cr = parse input in
      equal string ~msg:input rendered (Cr.to_string cr);
      equal status_value ~msg:(input ^ " status") status (Cr.status cr);
      equal (option string) ~msg:(input ^ " recipient") recipient
        (Option.map Cr.Handle.to_string (Cr.recipient cr)))
    cases;
  List.iter
    (fun (input, kind) -> expect_error input kind (Cr.parse input))
    [
      ("TODO: fix", Cr.Error.Invalid_comment);
      ("CR", Cr.Error.Invalid_comment);
      ("CR bad handle: fix", Cr.Error.Invalid_comment);
      ("XCR agent while spice: fix", Cr.Error.Invalid_comment);
      ("XCR agent for: fix", Cr.Error.Invalid_comment);
      ("CR:  ", Cr.Error.Invalid_body);
    ]

let digest_validation () =
  let cr = parse "CR: fix it" in
  let identity = Cr.digest cr in
  check_identity_form "CR digest" identity;
  (* The identity is over the normalized source text ([to_string]), so its byte
     length is that text's length. *)
  equal int ~msg:"digest byte length matches normalized text"
    (String.length (Cr.to_string cr))
    (Identity.byte_length identity);
  equal digest_value ~msg:"identical comments share a digest" identity
    (Cr.digest (parse "CR: fix it"));
  is_true ~msg:"different bodies digest differently"
    (not (Identity.equal identity (Cr.digest (parse "CR: other"))));
  let resolved =
    expect_ok "resolve" (Cr.resolve ~resolver:(handle "agent") cr)
  in
  is_true ~msg:"resolving changes the digest"
    (not (Identity.equal identity (Cr.digest resolved)))

let syntax_validation () =
  let line = expect_ok "line syntax" (Cr.Syntax.line ~prefix:"//") in
  let block =
    expect_ok "block syntax" (Cr.Syntax.block ~open_:"/*" ~close:"*/")
  in
  equal syntax_value ~msg:"line syntax equality" line
    (expect_ok "line syntax copy" (Cr.Syntax.line ~prefix:"//"));
  equal syntax_value ~msg:"block syntax equality" block
    (expect_ok "block syntax copy" (Cr.Syntax.block ~open_:"/*" ~close:"*/"));
  List.iter
    (fun (msg, result) -> expect_error msg Cr.Error.Invalid_syntax result)
    [
      ("empty line prefix", Cr.Syntax.line ~prefix:"");
      ("space-prefixed line prefix", Cr.Syntax.line ~prefix:" //");
      ("tab-prefixed line prefix", Cr.Syntax.line ~prefix:"\t//");
      ("line prefix with LF", Cr.Syntax.line ~prefix:"//\n");
      ("line prefix with CR", Cr.Syntax.line ~prefix:"//\r");
      ("empty block opener", Cr.Syntax.block ~open_:"" ~close:"*/");
      ("block closer with NUL", Cr.Syntax.block ~open_:"/*" ~close:"*\000/");
      ("block closer with CR", Cr.Syntax.block ~open_:"/*" ~close:"*/\r");
    ]

let syntax_of_path_conventions () =
  let some msg expected path =
    match Cr.Syntax.of_path (rel path) with
    | Some syntax -> equal syntax_value ~msg expected syntax
    | None -> failf "%s: expected a syntax for %s" msg path
  in
  let line prefix = expect_ok "line syntax" (Cr.Syntax.line ~prefix) in
  let block open_ close =
    expect_ok "block syntax" (Cr.Syntax.block ~open_ ~close)
  in
  some "dune files use lisp line comments" (line ";") "lib/host/dune";
  some "dune-project uses lisp line comments" (line ";") "dune-project";
  some "dune-workspace uses lisp line comments" (line ";") "dune-workspace";
  some "OCaml sources use block comments" Cr.Syntax.ocaml "lib/cr/spice_cr.ml";
  some "OCaml interfaces use block comments" Cr.Syntax.ocaml "a.mli";
  some "C-family sources use slash comments" (line "//") "src/main.rs";
  some "scripts use hash comments" (line "#") "setup.sh";
  some "yaml uses hash comments" (line "#") ".github/workflows/ci.yml";
  some "css uses block comments" (block "/*" "*/") "web/site.css";
  is_true ~msg:"unknown extensions have no syntax"
    (Option.is_none (Cr.Syntax.of_path (rel "README.md")));
  is_true ~msg:"extensionless files have no syntax"
    (Option.is_none (Cr.Syntax.of_path (rel "LICENSE")))

let scan_ocaml_block_comments () =
  let text =
    String.concat "\n"
      [
        "let x = 1";
        "  (* CR spice: tighten this *)";
        "let y = 2";
        "(* CR bad handle: report this *)";
        "(* not CR: ignored *)";
        "";
      ]
  in
  let occurrences = Cr.scan ~syntax:Cr.Syntax.ocaml ~path:source_path ~text in
  equal int ~msg:"block scanner includes valid and malformed CRs" 2
    (List.length occurrences);
  let first = nth_occurrence "block scan" 0 occurrences in
  let second = nth_occurrence "block scan" 1 occurrences in
  equal string ~msg:"valid raw block" "(* CR spice: tighten this *)"
    (Cr.Occurrence.raw first);
  equal string ~msg:"valid parsed block" "CR spice: tighten this"
    (Cr.to_string (expect_comment "valid block" first));
  equal int ~msg:"occurrence line is one-based" 2 (Cr.Occurrence.line first);
  check_identity_form "valid occurrence digest" (Cr.Occurrence.digest first);
  equal digest_value ~msg:"valid occurrence digests its parsed comment"
    (Cr.digest (expect_comment "valid block" first))
    (Cr.Occurrence.digest first);
  expect_occurrence_error "malformed block is preserved"
    Cr.Error.Invalid_comment second;
  check_identity_form "malformed occurrence digest"
    (Cr.Occurrence.digest second);
  is_true ~msg:"malformed occurrence has a distinct, stable digest"
    (not
       (Identity.equal
          (Cr.Occurrence.digest first)
          (Cr.Occurrence.digest second)))

let scan_respects_payload_boundaries () =
  let syntax =
    expect_ok "custom block syntax" (Cr.Syntax.block ~open_:"/*" ~close:"R*/")
  in
  let text = "/* CR*/\n/* CR: real */R*/\n" in
  let occurrences = Cr.scan ~syntax ~path:source_path ~text in
  equal int ~msg:"scanner does not read CR marker across close delimiter" 1
    (List.length occurrences);
  let occurrence = nth_occurrence "custom block scan" 0 occurrences in
  equal string ~msg:"scanner keeps the real payload" "CR: real */"
    (Cr.to_string (expect_comment "custom block" occurrence))

let scan_ocaml_nested_block_comments () =
  let text = "let x = 1\n(* CR: outer (* nested *) done *)\nlet y = 2\n" in
  let occurrences = Cr.scan ~syntax:Cr.Syntax.ocaml ~path:source_path ~text in
  equal int ~msg:"nested OCaml block yields one occurrence" 1
    (List.length occurrences);
  let occurrence = nth_occurrence "nested block scan" 0 occurrences in
  equal string ~msg:"nested raw block" "(* CR: outer (* nested *) done *)"
    (Cr.Occurrence.raw occurrence);
  equal string ~msg:"nested payload parses through outer close"
    "CR: outer (* nested *) done"
    (Cr.to_string (expect_comment "nested block" occurrence))

let scan_ocaml_nested_cr_inside_non_cr_comment () =
  let text = "let x = 1\n(* ignored (* CR: nested *) ignored *)\n" in
  let occurrences = Cr.scan ~syntax:Cr.Syntax.ocaml ~path:source_path ~text in
  equal int ~msg:"nested CR inside non-CR block is scanned" 1
    (List.length occurrences);
  let occurrence = nth_occurrence "nested inner CR scan" 0 occurrences in
  equal string ~msg:"nested inner raw block" "(* CR: nested *)"
    (Cr.Occurrence.raw occurrence);
  equal string ~msg:"nested inner payload parses" "CR: nested"
    (Cr.to_string (expect_comment "nested inner block" occurrence))

let scan_ocaml_ignores_string_literals () =
  let text =
    String.concat "\n"
      [
        "let ordinary = \"(* CR: not a comment *)\"";
        "let quoted = {| (* CR: not a comment *) |}";
        "let tagged = {fixture| (* CR: not a comment *) |fixture}";
        "let unterminated = {| (* CR: not a comment *)";
      ]
  in
  let occurrences = Cr.scan ~syntax:Cr.Syntax.ocaml ~path:source_path ~text in
  equal int ~msg:"OCaml scanner ignores string literals" 0
    (List.length occurrences)

let scan_line_comments () =
  let syntax = expect_ok "line syntax" (Cr.Syntax.line ~prefix:"//") in
  let text =
    String.concat "\n"
      [
        "  // CR: first";
        "let x = 1 // CR: inline is ignored";
        "// XCR agent: done";
        "// CR bad handle: malformed";
        "";
      ]
  in
  let occurrences = Cr.scan ~syntax ~path:source_path ~text in
  equal int ~msg:"line scanner finds line-start CR-looking comments" 3
    (List.length occurrences);
  let first = nth_occurrence "line scan" 0 occurrences in
  let second = nth_occurrence "line scan" 1 occurrences in
  let third = nth_occurrence "line scan" 2 occurrences in
  equal string ~msg:"line raw excludes indentation" "// CR: first"
    (Cr.Occurrence.raw first);
  equal int ~msg:"line occurrence records first line" 1
    (Cr.Occurrence.line first);
  equal string ~msg:"resolved line parses" "XCR agent: done"
    (Cr.to_string (expect_comment "resolved line" second));
  expect_occurrence_error "malformed line is preserved" Cr.Error.Invalid_comment
    third

let counts_open_and_addressed () =
  let text =
    String.concat "\n"
      [
        "let a = 1";
        "(* CR alice: tighten *)";
        "(* CR bob: document *)";
        "(* CR: unaddressed *)";
        "(* XCR alice: already resolved *)";
        "(* CR *)";
        "";
      ]
  in
  let occurrences = Cr.scan_file ~path:source_path ~text in
  equal int ~msg:"scan finds every CR-looking comment, valid or not" 5
    (List.length occurrences);
  let counts handle = Cr.Occurrence.counts ~handle occurrences in
  let alice = counts (handle "alice") in
  equal int ~msg:"open counts valid unresolved CRs only" 3
    alice.Cr.Occurrence.open_;
  equal int ~msg:"addressed counts open CRs recipient-matched to alice" 1
    alice.Cr.Occurrence.addressed;
  let bob = counts (handle "bob") in
  equal int ~msg:"open is recipient-independent" 3 bob.Cr.Occurrence.open_;
  equal int ~msg:"bob is addressed once" 1 bob.Cr.Occurrence.addressed;
  let carol = counts (handle "carol") in
  equal int ~msg:"an unaddressed handle counts no addressed CRs" 0
    carol.Cr.Occurrence.addressed;
  let empty = Cr.Occurrence.counts ~handle:(handle "alice") [] in
  equal int ~msg:"no occurrences means no open CRs" 0 empty.Cr.Occurrence.open_

let scan_file_uses_path_convention () =
  let text = "let x = 1\n(* CR spice: fix this *)\n" in
  equal int ~msg:"scan_file scans OCaml sources by convention" 1
    (List.length (Cr.scan_file ~path:source_path ~text));
  let unknown_path =
    match Path.Rel.of_string "notes.md" with
    | Ok path -> path
    | Error error -> failf "invalid path: %a" Path.Error.pp error
  in
  equal int ~msg:"scan_file yields nothing for unconventional paths" 0
    (List.length (Cr.scan_file ~path:unknown_path ~text:"(* CR: fix *)\n"))

let render_source_comments () =
  let cr = make "review this" in
  equal (result string error_kind) ~msg:"OCaml block render"
    (Ok "(* CR: review this *)")
    (Result.map_error Cr.Error.kind (Cr.render ~syntax:Cr.Syntax.ocaml cr));
  expect_error "line render rejects newline" Cr.Error.Invalid_body
    (Cr.render
       ~syntax:(expect_ok "line syntax" (Cr.Syntax.line ~prefix:"//"))
       (make "first\nsecond"));
  expect_error "block render rejects delimiter" Cr.Error.Invalid_body
    (Cr.render ~syntax:Cr.Syntax.ocaml (make "contains *) close"))

let text_insertions () =
  let cr = make "review this" in
  let source = "let f x =\n  x + 1\n" in
  let expected = "let f x =\n  (* CR: review this *)\n  x + 1\n" in
  equal string ~msg:"insert before line uses target indentation" expected
    (expect_ok "before line"
       (Cr.add_before_line ~syntax:Cr.Syntax.ocaml ~text:source ~line:2 cr));
  equal string ~msg:"insert after line uses following indentation" expected
    (expect_ok "after line"
       (Cr.add_after_line ~syntax:Cr.Syntax.ocaml ~text:source ~line:1 cr));
  equal string ~msg:"append after trailing newline"
    "let x = 1\n(* CR: review this *)\n"
    (expect_ok "append trailing newline"
       (Cr.add_at_end ~syntax:Cr.Syntax.ocaml ~text:"let x = 1\n" cr));
  equal string ~msg:"append adds a separator newline"
    "let x = 1\n(* CR: review this *)\n"
    (expect_ok "append missing trailing newline"
       (Cr.add_at_end ~syntax:Cr.Syntax.ocaml ~text:"let x = 1" cr));
  expect_error "line outside source" Cr.Error.Invalid_anchor
    (Cr.add_before_line ~syntax:Cr.Syntax.ocaml ~text:source ~line:99 cr);
  expect_error "line comments reject multi-line CRs" Cr.Error.Invalid_body
    (Cr.add_at_end
       ~syntax:(expect_ok "line syntax" (Cr.Syntax.line ~prefix:"//"))
       ~text:"" (make "first\nsecond"));
  expect_error "block comments reject closing delimiter" Cr.Error.Invalid_body
    (Cr.add_at_end ~syntax:Cr.Syntax.ocaml ~text:"" (make "contains *) close"));
  expect_error "OCaml block comments reject opening delimiter"
    Cr.Error.Invalid_body
    (Cr.add_at_end ~syntax:Cr.Syntax.ocaml ~text:"" (make "contains (* open"))

let replace_and_remove_occurrences () =
  let text = "let x = 1\n  (* CR spice: fix this *)\nlet y = 2\n" in
  let occurrence =
    match Cr.scan ~syntax:Cr.Syntax.ocaml ~path:source_path ~text with
    | [ occurrence ] -> occurrence
    | occurrences ->
        failf "expected one occurrence, got %d" (List.length occurrences)
  in
  let cr = expect_comment "replace target" occurrence in
  let resolved =
    expect_ok "resolve target" (Cr.resolve ~resolver:(handle "agent") cr)
  in
  equal string ~msg:"replace preserves surrounding indentation"
    "let x = 1\n  (* XCR agent for spice: fix this *)\nlet y = 2\n"
    (expect_ok "replace" (Cr.replace ~text occurrence resolved));
  equal string ~msg:"removing a comment alone on its line removes the line"
    "let x = 1\nlet y = 2\n"
    (expect_ok "remove" (Cr.remove ~text occurrence));
  (let inline = "let x = 1 (* CR spice: fix this *)\nlet y = 2\n" in
   let occurrence =
     match Cr.scan ~syntax:Cr.Syntax.ocaml ~path:source_path ~text:inline with
     | [ occurrence ] -> occurrence
     | occurrences ->
         failf "expected one inline occurrence, got %d"
           (List.length occurrences)
   in
   equal string ~msg:"removing a trailing comment keeps the line"
     "let x = 1 \nlet y = 2\n"
     (expect_ok "inline remove" (Cr.remove ~text:inline occurrence)));
  let stale = "let x = 1\n  (* CR spice: changed *)\nlet y = 2\n" in
  expect_error "stale replace" Cr.Error.Stale_occurrence
    (Cr.replace ~text:stale occurrence resolved);
  expect_error "stale remove" Cr.Error.Stale_occurrence
    (Cr.remove ~text:stale occurrence)

let replace_line_comment_preserves_crlf () =
  let syntax = expect_ok "line syntax" (Cr.Syntax.line ~prefix:"//") in
  let text = "// CR: first\r\nlet x = 1\r\n" in
  let occurrence =
    match Cr.scan ~syntax ~path:source_path ~text with
    | [ occurrence ] -> occurrence
    | occurrences ->
        failf "expected one occurrence, got %d" (List.length occurrences)
  in
  let cr = expect_comment "CRLF line comment" occurrence in
  let resolved =
    expect_ok "resolve CRLF line comment"
      (Cr.resolve ~resolver:(handle "agent") cr)
  in
  equal string ~msg:"replace preserves CRLF line ending"
    "// XCR agent: first\r\nlet x = 1\r\n"
    (expect_ok "replace CRLF line comment"
       (Cr.replace ~text occurrence resolved))

let rendered_comments_parse_back (soon, recipient_text, body) =
  let priority = if soon then Cr.Priority.Soon else Cr.Priority.Now in
  let recipient = Option.map handle recipient_text in
  let cr = make ~priority ?recipient body in
  equal string ~msg:"rendered comment parses canonically" (Cr.to_string cr)
    (Cr.to_string (parse (Cr.to_string cr)))

let handle_text =
  testable ~pp:Format.pp_print_string ~equal:String.equal
    ~gen:(Gen.string_size (Gen.int_range 1 8) (Gen.char_range 'a' 'z'))
    ()

let body_text =
  testable ~pp:Format.pp_print_string ~equal:String.equal
    ~gen:(Gen.string_size (Gen.int_range 1 30) (Gen.char_range 'a' 'z'))
    ()

let () =
  run "spice.cr"
    [
      group "comments"
        [
          test "validates handles" handle_validation;
          test "constructs and resolves comments"
            comment_construction_and_resolution;
          test "parses and renders source syntax" parsing_and_rendering;
          test "digests comments" digest_validation;
          prop' "rendered comments parse back"
            (triple bool (option handle_text) body_text)
            rendered_comments_parse_back;
        ];
      group "source syntax"
        [
          test "validates syntax delimiters" syntax_validation;
          test "maps paths to conventional syntaxes" syntax_of_path_conventions;
          test "renders source comments" render_source_comments;
        ];
      group "scanning"
        [
          test "scans OCaml block comments" scan_ocaml_block_comments;
          test "respects payload boundaries" scan_respects_payload_boundaries;
          test "scans nested OCaml block comments"
            scan_ocaml_nested_block_comments;
          test "scans nested CR inside non-CR OCaml comments"
            scan_ocaml_nested_cr_inside_non_cr_comment;
          test "ignores OCaml string literals"
            scan_ocaml_ignores_string_literals;
          test "scans line comments" scan_line_comments;
          test "scans by path convention" scan_file_uses_path_convention;
          test "counts open and addressed occurrences" counts_open_and_addressed;
        ];
      group "text transformations"
        [
          test "inserts comments" text_insertions;
          test "replaces and removes occurrences" replace_and_remove_occurrences;
          test "preserves CRLF line endings when replacing line comments"
            replace_line_comment_preserves_crlf;
        ];
    ]
