(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Anthropic HTTP configuration.

    Configuration values are inert. They do not read process environment
    variables, open network resources, or validate credentials. The provider
    adapter consumes them when constructing an {!Api.Client.t}; absent fields
    select the adapter defaults for Anthropic's public API endpoint, per-attempt
    timeout, and retry policy. *)

(** {1:types Types} *)

type t
(** The type for Anthropic HTTP configuration. *)

(** {1:constructors Constructors} *)

val default : t
(** [default] is [make ()]. *)

val make : ?base_url:string -> ?timeout_s:float -> ?max_retries:int -> unit -> t
(** [make ()] is Anthropic HTTP configuration.

    - [base_url] is the API root, without the endpoint path. Trailing slashes
      are ignored. The value is otherwise used as supplied.
    - [timeout_s] is the per-attempt HTTP timeout in seconds when present.
    - [max_retries] is the number of retry attempts after the initial request
      when present.

    Raises [Invalid_argument] if [base_url] is empty, contains a newline, or
    contains only slashes, [timeout_s] is not positive and finite, or
    [max_retries] is negative. *)

(** {1:queries Queries} *)

val base_url : t -> string option
(** [base_url t] is the configured API root, if any. *)

val timeout_s : t -> float option
(** [timeout_s t] is the per-attempt timeout in seconds, if any. *)

val max_retries : t -> int option
(** [max_retries t] is the retry count after the initial attempt, if any. *)
