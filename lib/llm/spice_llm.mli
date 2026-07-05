(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Provider-neutral LLM request and stream values.

    [Spice_llm] defines inert values for provider-neutral model requests,
    model-visible transcripts, completed provider responses, and semantic stream
    progress. Provider clients interpret requests through concrete provider
    packages. Executable tools, sessions, permissions, storage, and provider
    configuration live outside this library.

    A typical turn builds or updates a {!Transcript.t}, constructs a checked
    {!Request.t}, sends it through a {!Client.t}, consumes a {!Stream.t} or
    terminal {!Response.t}, and appends {!Response.message} back to the
    transcript. *)

module Provider = Provider
(** Provider namespaces. *)

module Model = Model
(** Provider model identities. *)

module Content = Content
(** Model-visible content blocks. *)

module Tool = Tool
(** Model-visible tools, calls, and results. *)

module Usage = Usage
(** Token usage. *)

module Message = Message
(** Replayable model-visible messages. *)

module Transcript = Transcript
(** Checked model-visible transcripts. *)

module Request = Request
(** Model requests. *)

module Response = Response
(** Completed provider responses. *)

module Error = Error
(** Provider-boundary errors. *)

module Stream = Stream
(** Semantic streams of provider progress. *)

module Retry = Retry
(** Server retry guidance shared by provider adapters. *)

module Client = Client
(** Provider interpreters. *)
