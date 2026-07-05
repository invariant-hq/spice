(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Interactive login and logout workflows.

    This module owns the credential-acquisition orchestration both frontends
    share: resolving a provider's login method, rerooting its endpoints onto a
    [SPICE_<PROVIDER>_AUTH_BASE_URL] override, driving the browser
    authorization-code and device-code protocols from {!Spice_auth}, and
    settling every flow through one persist-then-check policy. Frontends keep
    presentation only: they render {!event}s and {!settled} facts in their own
    vocabulary and decide when to open a browser.

    Nothing display-unsafe crosses this interface. No secret, token,
    authorization code, or verifier appears in {!event} or {!settled}; settled
    facts are the account phase, source, and fingerprint views frontends
    already render. *)

(** {1:events Progress events} *)

type event =
  | Browser_url of Uri.t
      (** The authorization URL the user must visit. The frontend displays it;
          opening a browser is the frontend's decision, typically on
          {!Listening}. *)
  | Listening of { redirect_uri : Uri.t }
      (** The local callback listener is bound and the authorization can
          complete; emitted after {!Browser_url}. *)
  | Device_challenge of { url : Uri.t; user_code : string; expires_in : int }
      (** The device-code challenge to present verbatim: visit [url], enter
          [user_code]. [expires_in] is the challenge's remaining validity in
          seconds, at least [0]. *)

(** {1:settling Settled outcomes} *)

type settled =
  | Checked of Spice_account.t
      (** The secret is persisted and the post-save provider check ran;
          the account is the checked view. *)
  | Unchecked of { account : Spice_account.t option; reason : string }
      (** The secret is persisted but the provider check could not run for
          [reason]; [account] is the passive (never-checked) view when one
          could be read. *)
  | Failed of string
      (** Nothing was persisted. The message is display-safe and, for browser
          callback timeouts and network failures, already carries the
          use-a-device-code hint for headless machines. *)
  | Cancelled
      (** The [cancel] promise resolved before the flow settled; nothing was
          persisted. Never returned by a flow that was given no [cancel]. *)

(** {1:flows Flows}

    Every flow resolves [method_id] against [provider]'s declared logins and
    fails with {!Failed} when the method is unknown or its protocol does not
    match the flow. Flows run their provider I/O under an internal switch;
    [cancel] preempts blocking waits (the browser-callback await, device-poll
    sleeps) as soon as it resolves. *)

val save :
  stdenv:Eio_unix.Stdenv.base ->
  Spice_host.Host.t ->
  provider:Spice_llm.Provider.t ->
  ?name:Spice_account.Credential.Name.t ->
  Spice_account.Secret.t ->
  settled
(** [save ~stdenv host ~provider ?name secret] persists [secret] and settles
    with the persist-then-check policy: {!Checked} when the post-save provider
    check ran, {!Unchecked} when it could not, {!Failed} when the store write
    failed. This is the API-key login's settling half — frontends validate the
    raw key at their edge (keeping usage-error classification and masked-input
    handling local) and hand the validated secret here. *)

val browser :
  stdenv:Eio_unix.Stdenv.base ->
  Spice_host.Host.t ->
  provider:Spice_llm.Provider.t ->
  method_id:string ->
  ?name:Spice_account.Credential.Name.t ->
  ?cancel:unit Eio.Promise.t ->
  (event -> unit) ->
  settled
(** [browser ~stdenv host ~provider ~method_id ?name ?cancel events] drives
    the OAuth2 authorization-code flow: it emits {!Browser_url}, binds the
    local callback and emits {!Listening}, awaits the redirect for up to 300
    seconds, exchanges the callback for a secret (using the provider's token
    profile), and settles through the {!save} policy. [method_id] must name an
    authorization-code login. *)

val device :
  stdenv:Eio_unix.Stdenv.base ->
  Spice_host.Host.t ->
  provider:Spice_llm.Provider.t ->
  method_id:string ->
  ?name:Spice_account.Credential.Name.t ->
  ?cancel:unit Eio.Promise.t ->
  (event -> unit) ->
  settled
(** [device ~stdenv host ~provider ~method_id ?name ?cancel events] drives a
    device-code flow — standard OAuth2 or a provider flow (currently
    ["openai_chatgpt"]) — emitting {!Device_challenge} and polling at the
    protocol's cadence until the authorization settles, expires, or is
    rejected, then settles through the {!save} policy. [method_id] must name a
    device-code login. *)

type logout = {
  env_still_active : string option;
      (** The environment variable still supplying a credential for the
          provider after removal, which logout cannot clear. *)
}

val logout :
  stdenv:Eio_unix.Stdenv.base ->
  Spice_host.Host.t ->
  provider:Spice_llm.Provider.t ->
  ?name:Spice_account.Credential.Name.t ->
  unit ->
  (logout, string) result
(** [logout ~stdenv host ~provider ?name ()] removes the stored credential for
    [provider] under [name] (a missing credential is left missing) and reports
    whether an environment credential remains active. Provider-side revocation
    is not part of logout; it is a separate frontend concern. *)

(** {1:browser Browser launching} *)

val open_browser : Uri.t -> bool
(** [open_browser uri] spawns the OS URL opener for [uri], detached from the
    calling terminal ([open], [xdg-open], or [cmd /c start]), and reports
    whether an opener could be spawned. It never blocks and never inherits
    stdio, so an alt-screen frontend is not disturbed. *)
