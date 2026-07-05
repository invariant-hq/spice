(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** User configuration home and store paths.

    Resolves the directory that holds spice's user-scoped state — the
    configuration file, the credential store, and the trust store — and the path
    of each file under it.

    The directory is resolved from the environment with this precedence:
    + [SPICE_CONFIG_HOME], an explicit override;
    + the platform location: [APPDATA] on Windows, [XDG_CONFIG_HOME] elsewhere;
    + a [HOME]-relative [.config/spice] fallback, or [./.config/spice] when
      [HOME] is unset.

    Only absolute overrides are honoured: a relative [SPICE_CONFIG_HOME],
    [APPDATA], or [XDG_CONFIG_HOME] is ignored in favour of the next source in
    the chain. Resolution reads the environment through the supplied lookup and
    performs no I/O; the returned directory is not guaranteed to exist. *)

type getenv = string -> string option
(** The type for environment lookups. [getenv name] is the value bound to
    [name], or [None] if [name] is unset. *)

val path : getenv -> string
(** [path getenv] is the user configuration directory resolved from [getenv] by
    the precedence above. *)

val config_path : getenv -> string
(** [config_path getenv] is the path of the configuration file [config.json]
    under {!path}. *)

val auth_store_path : getenv -> string
(** [auth_store_path getenv] is the path of the credential store [auth.json]
    under {!path}. *)

val trust_store_path : getenv -> string
(** [trust_store_path getenv] is the path of the trust store [trust.json] under
    {!path}. *)
