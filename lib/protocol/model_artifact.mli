(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Local model artifact facts.

    Artifacts are provider-owned local files required before a model can run.
    This type is provider-neutral so interactive surfaces can show readiness and
    progress without importing provider packages.

    The memory-budget {e fit} verdict is deliberately {e not} part of this
    neutral vocabulary: it is meaningful only for local weights and is computed
    against the running machine's budget, so it stays a display enrichment
    beside this seam rather than a field every other provider would answer with
    a null. *)

type phase =
  | Checking
  | Downloading
  | Verifying
  | Ready
      (** The current preparation phase for a provider-owned local artifact.

          [Checking] means the provider is resolving local state or remote
          metadata. [Downloading] means bytes are being transferred. [Verifying]
          means the downloaded artifact is being checked before installation.
          [Ready] means the artifact is available for use. *)

type status =
  | Installed of { path : string }
      (** The artifact exists locally at [path]. *)
  | Missing of { path : string; size : int64 option; source : string option }
      (** The artifact is not installed at [path].

          [size] is the expected byte size when known. [source] is a
          human-readable origin, such as a download URL, when the provider can
          expose one safely. *)
  | Unavailable of { message : string }
      (** The provider could not determine artifact status. [message] is a
          display diagnostic and is not meant to be parsed. *)

type progress = {
  provider : Spice_llm.Provider.t;
      (** Provider namespace that owns the artifact. *)
  model : string;  (** Provider-local model id being prepared. *)
  label : string;  (** Short display label for the artifact. *)
  path : string;  (** Local destination path for the artifact. *)
  received : int64;  (** Bytes received or verified so far. *)
  total : int64 option;  (** Total byte count when known. *)
  phase : phase;  (** Current preparation phase. *)
}
(** A provider-neutral artifact preparation update.

    Progress values are intentionally display-oriented. Provider adapters keep
    protocol-specific download state, checksums, and mirror selection private.

    {b Note.} [path] is a provider-owned local, display-only artifact path, not
    session-portable identity. *)

val summary : status -> string
(** [summary status] is a short display string for status panes. *)

(** The outcome of an explicit, force-able model-artifact download.

    Distinct from the passive {!type:status}: this is the result of a
    user-requested download workflow, which owns the status check, the on-disk
    install, and the force override. The engine performs the download; this
    vocabulary is what surfaces render. *)
type download_outcome =
  | Already_installed of string
      (** The artifact is already installed at the given path; nothing was
          downloaded. *)
  | Not_downloadable
      (** The model is an explicit local weight path — a user-provided file — so
          there is nothing to download. *)
  | Downloaded  (** The artifact was fetched, verified, and installed. *)
  | Refused of { message : string; force_hint : bool }
      (** The download did not proceed. [message] explains why. [force_hint] is
          [true] when re-running with a force override would proceed, for
          example past a memory-budget guard. *)
