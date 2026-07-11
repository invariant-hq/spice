(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Atomic installation of remotely fetched model artifacts. *)

type phase =
  | Checking
  | Downloading
  | Verifying
  | Installed  (** The phase of an artifact installation. *)

val install :
  env:Eio_unix.Stdenv.base ->
  http:Cohttp_eio.Client.t ->
  provider:Spice_llm.Provider.t ->
  cancelled:(unit -> bool) ->
  observe:(phase -> received:int64 -> total:int64 option -> unit) ->
  url:string ->
  path:string ->
  size:int64 ->
  sha256:string ->
  (unit, Spice_llm.Error.t) result
(** [install ~env ~http ~provider ~cancelled ~observe ~url ~path ~size ~sha256]
    downloads and installs one artifact.

    The response is streamed into an exclusively created mode-[0600] candidate
    in [path]'s directory. The candidate is closed, checked against [size] and
    [sha256], then atomically renamed to [path]. Concurrent installers never
    share a candidate; each can only publish a complete verified artifact.

    [observe] receives progress at phase boundaries and periodically while bytes
    are transferred. Predicate cancellation and recoverable network, filesystem,
    and integrity failures return structured provider errors. Eio cancellation
    is re-raised after candidate cleanup. Network resources are scoped to this
    call and released before it returns. *)
