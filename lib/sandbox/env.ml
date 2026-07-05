(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Name shapes for values a confined command must not inherit. Classes, not a
   secret scanner: credentials by suffix/contains, provider prefixes, loader
   injection, and shell-startup overrides. Reviewed by unit tests. *)
let stripped_patterns =
  [
    (* credential shapes *)
    "*API_KEY*";
    "*ACCESS_KEY*";
    "*SECRET*";
    "*TOKEN*";
    "*PASSWORD*";
    "*CREDENTIAL*";
    "*PRIVATE_KEY*";
    (* provider and cloud prefixes *)
    "ANTHROPIC_*";
    "OPENAI_*";
    "GEMINI_*";
    "AWS_*";
    "AZURE_*";
    (* loader injection *)
    "LD_*";
    "DYLD_*";
    (* shell startup overrides *)
    "BASH_ENV";
    "ENV";
    "ZDOTDIR";
  ]

let ascii_uppercase = String.uppercase_ascii
let uppercase_patterns = List.map ascii_uppercase stripped_patterns

(* Glob match where '*' matches any (possibly empty) substring. Both sides
   are ASCII-uppercased by the caller. *)
let rec glob pattern p name n =
  let plen = String.length pattern and nlen = String.length name in
  if p = plen then n = nlen
  else
    match pattern.[p] with
    | '*' ->
        let rec try_from i =
          if i > nlen then false
          else glob pattern (p + 1) name i || try_from (i + 1)
        in
        try_from n
    | c -> n < nlen && Char.equal name.[n] c && glob pattern (p + 1) name (n + 1)

let matches name =
  let name = ascii_uppercase name in
  List.exists (fun pattern -> glob pattern 0 name 0) uppercase_patterns

let partition bindings =
  let kept, stripped =
    List.partition_map
      (fun ((name, _value) as binding) ->
        if matches name then Either.Right name else Either.Left binding)
      bindings
  in
  (kept, stripped)
