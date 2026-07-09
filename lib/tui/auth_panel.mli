(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The provider login / logout panel (09-auth.md): a staged drill-down over the
    shared panel form — provider picker, method picker, then one of three
    protocol surfaces (a masked api-key entry, a browser flow panel, a
    device-code flow panel) — settling to a transcript record the shell appends.

    A mini-Elm surface (doc/plans/tui-next-surfaces.md,
    doc/plans/tui-next-auth.md): the shell holds {!t}, routes keys through
    {!key}, folds the resulting {!msg} with {!update} — which yields the next
    {!t} and an {!event} the shell interprets — and renders {!view} through
    {!Panel.view}. The panel reads no host, clock, or environment: the provider
    facts arrive as {!provider_entry} values the runtime assembles once
    ({!providers_loaded}), and the async protocol progress arrives as
    {!challenge} / {!browser_opened} folds.

    This module is UI-pure. It owns the flow's shape, navigation, and view, but
    never opens a browser, polls, sleeps, or touches the credential store — the
    shell mints request ids and issues runtime commands; the runtime composes
    the {!Spice_host_builtin.Login} primitives. The one secret in the surface is
    the api-key {i buffer}, rendered only as bullets: it never enters the
    composer draft, prompt history, the transcript, a log, or the clipboard, and
    leaves only as the {!Begin_api_key} command payload (09-auth §10). *)

(** {1:facts Host facts} *)

type provider_entry = {
  provider : Spice_llm.Provider.t;
      (** The provider handle a login command names — [Spice_provider.id decl].
      *)
  display_name : string;  (** The picker label ([OpenAI], [Anthropic], …). *)
  logins : Spice_provider.Auth.Login.t list;
      (** The provider's declared login methods; empty for a no-auth provider.
      *)
  env : string list;
      (** The env var names that supply a credential for the provider. *)
  phase : Spice_account.phase;
      (** The resolved account phase, [`Missing] when unresolved. *)
  source : Spice_account.Credential.Source.t option;
      (** Where the resolved credential comes from ([Store]/[Env]/[Process]),
          [None] when missing. *)
  fingerprint : string option;
      (** The redacted last-four of the resolved credential, [None] for none or
          for short material. *)
}
(** One provider row, assembled by the runtime from [Spice_host.Host.providers],
    [Spice_host.Account.status], and [Spice_provider.Auth.*]. Carries no secret
    — only display-safe passive facts. *)

(** Whether the panel drives a login or a logout drill-down. *)
type mode = Login | Logout

(** The display-safe protocol challenge the runtime forwards from a
    [Spice_host_builtin.Login.event]. No token, code, or verifier crosses here.
*)
type challenge =
  | Browser_url of Uri.t  (** The browser authorization URL to display. *)
  | Device_challenge of { url : Uri.t; user_code : string; expires_in : int }
      (** The device-code challenge: visit [url], enter [user_code], expiring in
          [expires_in] seconds. *)

(** How a flow settled, reduced to display-safe record material by the runtime.
    Cancellation produces no record (nothing happened), so it is absent here. *)
type outcome =
  | Signed_in  (** The credential saved and the provider check passed. *)
  | Saved_blocked  (** The credential saved but the provider rejected it. *)
  | Saved_unchecked of string
      (** The credential saved but the check could not run, for the given
          reason. *)
  | Removed  (** A logout removed the stored credential. *)
  | Env_active of string
      (** A logout removed the store credential but an env var still supplies
          one. *)
  | Failed of string
      (** Nothing persisted; the display-safe failure message. *)

type record = {
  provider_title : string;
      (** The provider display name for the record head. *)
  outcome : outcome;  (** The settled outcome. *)
  acct_fingerprint : string option;
      (** The redacted account fingerprint, when one exists. *)
  source_word : string option;
      (** The source word ([store] / [env NAME] / [process]), when known. *)
}
(** The settled record the runtime builds and the shell appends to the
    transcript (09-auth §8). Carries only provider, outcome, redacted
    fingerprint, and source — never a secret. *)

(** {1:surface The surface} *)

type t
(** The panel state: the current stage of the drill-down (loading, a load error,
    a picker, the masked api-key entry, a browser / device flow panel, a working
    line, or the logout empty state) plus the loaded entries and mode. *)

type msg
(** A key routed to the panel, opaque; produced by {!key}. *)

(** The panel's outcome, which the shell interprets: it mints a request id,
    issues the runtime command, and — for a flow start — folds the id back with
    {!started}. *)
type event =
  | Stay  (** Remain open with the updated state. *)
  | Close
      (** Esc out of the provider picker (or the empty logout): close and
          restore the composer + draft unchanged. *)
  | Begin_api_key of {
      provider : Spice_llm.Provider.t;
      method_id : string;
      key : string;
    }
      (** Submit an api-key login: the runtime validates [key] at its edge and
          saves-then-checks. The panel is now in its working stage. *)
  | Begin_browser of { provider : Spice_llm.Provider.t; method_id : string }
      (** Start a browser OAuth flow. The panel is now in its browser stage
          awaiting {!started}. *)
  | Begin_device of { provider : Spice_llm.Provider.t; method_id : string }
      (** Start a device-code flow. The panel is now in its device stage
          awaiting {!started}. *)
  | Begin_logout of { provider : Spice_llm.Provider.t }
      (** Remove [provider]'s stored credential. The panel is now in its working
          stage. *)
  | Cancel of { request : int }
      (** Esc from a waiting flow: resolve the runtime's cancel promise for
          [request] (no secret written), then step back one rung. *)
  | Copy of string  (** Copy the display-safe string (a URL or user code). *)
  | Open_url of Uri.t
      (** The browser flow's explicit open keypress: launch the OS browser on
          [url] (tui-next never auto-opens — 09-auth §6). *)
  | Flash of string
      (** Reject a no-op key (a non-selectable provider, an empty key) and flash
          the message; the panel stays. *)

val loading : mode:mode -> ?provider:string -> unit -> t
(** [loading ~mode ?provider ()] is the panel just opened, before its provider
    entries arrive: {!view} renders a muted loading line. [provider] is the
    optional argument of [/login <provider>] / [/logout <provider>], which skips
    the provider picker once the entries load ({!providers_loaded}). *)

val key : Matrix.Input.Key.event -> msg option
(** [key ev] is the panel's message for [ev], or [None] for a key it ignores (so
    it dies in the modal shell). The classification is uniform
    ({!Panel.classify}); the stage-dependent interpretation lives in {!update} —
    a printable narrows a picker's filter but appends to the masked buffer in
    the api-key stage. *)

val update : msg -> t -> t * event
(** [update msg t] folds one key. In a picker: printables narrow the filter,
    digits jump-pick while empty, [↑]/[↓] move, [↵]/[tab] confirm (opening the
    method picker, a protocol stage, or emitting a flow-start event), esc steps
    back one rung ({!Close} from the provider picker). In the api-key stage:
    every printable and digit appends to the masked buffer, backspace erases one
    UTF-8 scalar, [↵] submits (empty → {!Flash}), esc steps back to the method
    picker. In a flow panel: [c] copies ({!Copy}), [↵] opens the browser
    ({!Open_url}, browser stage only), esc cancels ({!Cancel}) and steps back.
    In the working stage every key is ignored. *)

(** {1:async Runtime folds}

    Each is dispatched by the runtime as an [App.msg] the shell folds into the
    surface; late results (after the panel closed, or from a superseded attempt)
    are dropped by the request guard. *)

val providers_loaded : (provider_entry list, string) result -> t -> t * event
(** [providers_loaded result t] folds the loaded entries: [Error] renders a
    load-error line; [Ok entries] opens the provider picker, or — for a
    [/login <provider>] / [/logout <provider>] fast path — resolves the named
    provider and emits its {!event} directly (a picker for a many-connected
    logout, {!Begin_logout} for a single, {!Close} for an empty logout, {!Flash}
    for an unknown or no-auth provider). *)

val started : request:int -> t -> t
(** [started ~request t] stamps the just-entered flow stage (browser / device /
    working) with the shell's minted [request] id, so later {!challenge},
    {!browser_opened}, and the settled guard ({!active_request}) correlate.
    Called immediately after the shell interprets a {!Begin_browser},
    {!Begin_device}, {!Begin_api_key}, or {!Begin_logout} event. *)

val active_request : t -> int option
(** [active_request t] is the request id the panel's current flow stage carries,
    or [None] when no flow is in flight. The shell reads it to decide whether a
    settled record belongs to the attempt on screen (append + close) or is a
    superseded / late result (drop). *)

val challenge : request:int -> challenge -> t -> t
(** [challenge ~request c t] advances the browser / device flow panel to the
    waiting state carrying [c]'s display-safe challenge, when [request] matches
    the active flow; otherwise [t] unchanged. *)

val browser_opened : request:int -> t -> t
(** [browser_opened ~request t] marks the browser flow's URL as opened (the
    first line flips to "Browser opened…"), when [request] matches; otherwise
    [t] unchanged. *)

val browser_open_failed : request:int -> t -> t
(** [browser_open_failed ~request t] marks the browser flow's auto-open as
    failed (a "Could not open a browser automatically" line surfaces under the
    link, and enter retries), when [request] matches; otherwise [t] unchanged.
*)

val tick : t -> t
(** [tick t] advances a waiting flow panel's elapsed counter and device
    countdown by one second; a no-op in every other stage. Only the spinner cell
    animates — the URL and code rows stay static for copyability. *)

val ticking : t -> bool
(** [ticking t] is [true] while a browser / device flow panel is waiting, so the
    shell runs the one-second {!tick}. *)

val accepts_paste : t -> bool
(** [accepts_paste t] is [true] only in the api-key stage, so the shell routes a
    paste to the masked buffer rather than the (hidden) composer. *)

val paste : string -> t -> t
(** [paste text t] appends [text] to the masked api-key buffer (newlines
    stripped so a pasted key with a trailing newline saves cleanly); a no-op
    outside the api-key stage. The pasted bytes are masked exactly as typed. *)

val view : frame:Mosaic.Ansi.Color.t -> width:int -> rows:int -> t -> _ Mosaic.t
(** [view ~frame ~width ~rows t] renders the current stage through {!Panel.view}
    ([frame] tinting the boundary and the [log in] / [log out] chip): the
    provider or method picker (windowed to [rows], type-to-filter, right-aligned
    account detail with a [✓] / [!] mark), the masked api-key entry (bullets, a
    framed input, the env-prefill note), the browser or device flow panel (the
    static copyable URL / code rows, the spinner, the phishing warning, the
    headless steer), the working line, or the loading / error / empty lines. *)
