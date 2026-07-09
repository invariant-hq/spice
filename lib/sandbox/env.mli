(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Safe-environment partition for confined commands.

    Confined commands must not inherit credentials, loader-injection variables,
    or shell-startup overrides. The partition is pure and is the single source
    for both the spawn path and explain rendering, so what is reported stripped
    is what was stripped.

    Patterns are name shapes, not a secret scanner: matching is
    ASCII-case-insensitive and [*] matches any (possibly empty) substring.
    Values never appear in any output of this module; only names do.

    Confinement removes credentials, not the ability to find tools: [PATH] and the
    toolchain-locator variables ([OPAM_SWITCH_PREFIX], [OCAMLPATH], [CAML_*]) are
    never stripped, so a confined command still resolves the developer toolchain
    the unconfined process could. Do not add [PATH] or those name shapes to
    {!stripped_patterns}. *)

val stripped_patterns : string list
(** [stripped_patterns] are the name patterns removed from confined command
    environments: credential shapes ([*TOKEN*], [*SECRET*], ...), provider
    prefixes ([ANTHROPIC_*], [OPENAI_*], ...), credential-agent handles
    ([SSH_AUTH_SOCK], [GPG_AGENT_INFO], ...), loader injection ([LD_*],
    [DYLD_*]), and shell-startup overrides ([BASH_ENV], ...). *)

val partition : (string * string) list -> (string * string) list * string list
(** [partition bindings] is [(kept, stripped_names)] preserving binding order.
    [stripped_names] contains names only, never values. *)
