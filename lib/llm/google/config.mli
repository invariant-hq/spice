(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Google Gemini client configuration.

    Configuration values are inert. They do not read process environment
    variables, open network resources, validate credentials, or choose model
    defaults. Pass them to {!Spice_llm_google.client} to affect subsequent HTTP
    requests. *)

type t
(** The type for Google Gemini HTTP configuration. *)

val default : t
(** [default] is [make ()].

    Provider defaults are applied by the adapter: the public Google endpoint, a
    600-second whole-request deadline, and two retry attempts after the initial
    request. *)

val make : ?base_url:string -> ?timeout_s:float -> ?max_retries:int -> unit -> t
(** [make ()] is Google Gemini HTTP configuration.

    - [base_url] is the API root, without the endpoint path. Trailing slashes,
      when present, are removed.
    - [timeout_s] is the whole logical-request deadline, covering retries,
      backoff, and streamed response consumption. It defaults to 600 seconds.
    - [max_retries] is the number of retry attempts after the initial request
      when present.

    Raises [Invalid_argument] if [base_url] is empty, contains a newline, or
    contains only slashes, [timeout_s] is not positive and finite, or
    [max_retries] is negative. *)

val base_url : t -> string option
(** [base_url t] is the normalized API root, if any.

    [None] means the Google Gemini default endpoint. *)

val timeout_s : t -> float
(** [timeout_s t] is the whole logical-request deadline in seconds. *)

val max_retries : t -> int option
(** [max_retries t] is the retry count after the initial attempt, if any.

    [None] means two retry attempts after the initial request. [Some 0] disables
    retries. *)
