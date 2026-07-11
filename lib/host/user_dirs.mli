(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** User-owned Spice directories.

    Project configuration cannot redirect these roots. Config, durable data, and
    machine-local state resolve independently so repository inputs, sessions,
    and diagnostics keep distinct ownership and retention. *)

type getenv = string -> string option
(** The type for environment lookups. *)

module Error : sig
  type t
  (** The type for invalid or unavailable user-directory inputs. *)

  val variable : t -> string
  (** [variable e] is the environment variable responsible for [e]. *)

  val value : t -> string
  (** [value e] is the rejected value, empty when a required home was absent. *)

  val message : t -> string
  (** [message e] is the user-facing path-resolution diagnostic. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message}[ e]. *)
end

val config_home : getenv -> (string, Error.t) result
(** [config_home getenv] is the directory for user-authored configuration and
    authority stores. It honors an absolute [SPICE_CONFIG_HOME], then the
    platform config directory, then [$HOME/.config/spice]. Relative overrides
    and a missing fallback home are errors. *)

val data_home : getenv -> (string, Error.t) result
(** [data_home getenv] is the durable global data directory. It honors an
    absolute [SPICE_DATA_HOME], then the platform data directory, then
    [$HOME/.local/share/spice]. Relative overrides and a missing fallback home
    are errors. *)

val state_home : getenv -> (string, Error.t) result
(** [state_home getenv] is the machine-local state directory. It honors an
    absolute [SPICE_STATE_HOME], then the platform state directory, then
    [$HOME/.local/state/spice]. Relative overrides and a missing fallback home
    are errors. *)

val config_path : getenv -> (string, Error.t) result
(** [config_path getenv] is [config.json] below {!config_home}. *)

val auth_store_path : getenv -> (string, Error.t) result
(** [auth_store_path getenv] is [auth.json] below {!config_home}. *)

val trust_store_path : getenv -> (string, Error.t) result
(** [trust_store_path getenv] is [trust.json] below {!config_home}. *)
