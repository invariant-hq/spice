(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OpenAI-compatible chat-completions transport for local servers.

    This is the wire layer for a llama.cpp [llama-server] managed by
    {!Spice_llm_local}: plain-HTTP requests against a loopback base URL, no
    authentication, no TLS, no retries — a local server that fails is reported,
    not retried. Request and stream shapes mimic the OpenAI chat-completions
    API, which is the surface every local inference server exposes. *)

module Error : sig
  (** Transport failures: non-2xx responses, transport errors, and decode
      errors. *)

  type response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }
  (** A non-success HTTP response. *)

  type t =
    | Response of response  (** The server answered with a non-2xx status. *)
    | Transport of string  (** The request never completed. *)
    | Decode of string  (** The response bytes were not decodable. *)
end

module Client : sig
  (** Connection targets for the local chat-completions server. *)

  type t
  (** A connection target: base URL plus the Eio capabilities to reach it. *)

  val make :
    base_url:string -> sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit -> t
  (** [make ~base_url ~sw ~env ()] targets [base_url], e.g.
      ["http://127.0.0.1:8321"]. *)
end

val health : ?timeout_s:float -> Client.t -> (unit, Error.t) result
(** [health client] is [Ok ()] when [GET /health] answers 200. llama-server
    answers 503 while the model is still loading. [timeout_s] defaults to 2
    seconds. *)

module Chat : sig
  (** Streaming chat-completions requests and their event streams. *)

  type request = {
    model : string;
    messages : Jsont.json list;
    tools : Jsont.json list;
    tool_choice : Jsont.json option;
    response_format : Jsont.json option;
    reasoning_effort : string option;
    max_tokens : int option;
    temperature : float option;
  }
  (** A [/v1/chat/completions] request body; [stream] is always true and usage
      reporting is always requested. *)

  type event =
    | Chunk of Jsont.json
    | Done
        (** One server-sent event: a streamed chunk object, or the [[DONE]]
            sentinel. *)

  type stream
  (** A single-consumer stream of chat completion events. *)

  val next : stream -> (event, Error.t) result option
  (** [next stream] is the next event, or [None] after the underlying response
      body ends. Transport failures are returned as [Error]; cancellation
      propagates to the caller. *)

  val close : stream -> unit
  (** [close stream] abandons the stream. *)

  val create_stream : Client.t -> request -> (stream, Error.t) result
  (** [create_stream client request] posts [request] with [stream: true] and
      returns the event stream. No timeout applies: local generation is
      legitimately slow. *)
end
