(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-facing Dune RPC diagnostics tool.

    [ocaml_dune_diagnostics] reads the current OCaml diagnostics from a shared
    workspace-level {!Spice_ocaml_dune.Rpc.Instance.t}. The same instance is
    intended to be owned by the host and passed both to this tool and to the
    proactive diagnostics watcher, so tool calls and watcher notifications see
    one latest-known Dune diagnostic store.

    The tool does not own a Dune process and does not issue a blocking
    synchronous diagnostics request. Hosts that want live diagnostics should
    pass the same instance to the Dune diagnostics watcher, which owns endpoint
    startup and refresh. If no endpoint has been discovered, the tool fails as
    unavailable. *)

val name : string
(** Stable tool name, ["ocaml_dune_diagnostics"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

module Output : sig
  type t
  (** The typed output retained by completed [ocaml_dune_diagnostics] calls. *)

  val endpoint : t -> Spice_ocaml_dune.Rpc.Endpoint.t
  (** [endpoint t] is the Dune RPC endpoint used for the diagnostic request. *)

  val endpoint_text : t -> string
  (** [endpoint_text t] is a human-readable form of {!endpoint}. *)

  val diagnostics :
    t -> (Spice_ocaml_dune.Rpc.Diagnostic.id * Spice_ocaml.Diagnostic.t) list
  (** [diagnostics t] is the current Dune diagnostic set returned by the RPC
      request, ordered according to the adapter store. The list may be empty
      when Dune reports no diagnostics. *)

  val diagnostic_count : t -> int
  (** [diagnostic_count t] is the number of diagnostics in {!diagnostics}. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is [Some t] if [output] was produced by this tool
      and retained typed evidence, and [None] otherwise. *)
end

val permissions : Spice_workspace.t -> Spice_permission.Request.t list
(** [permissions workspace] is the workspace-root read permission needed to poll
    the Dune RPC registry. Network/socket authority is supplied by the shared
    {!Spice_ocaml_dune.Rpc.Instance.t}. *)

val run :
  dune:Spice_ocaml_dune.Rpc.Instance.t ->
  Spice_tool.Context.t ->
  unit ->
  Output.t Spice_tool.Result.t
(** [run ~dune ctx ()] returns the latest diagnostic set observed through
    [dune].

    The result is completed with {!Output.t} when [dune] already has a selected
    endpoint or registry polling finds one. The output contains the shared
    instance's latest-known diagnostic store, which may be empty if Dune has not
    published diagnostics yet. The result is interrupted if [ctx] is cancelled
    before work starts, and failed as [`Unavailable] if no endpoint is visible
    or registry polling fails. *)

val tool : dune:Spice_ocaml_dune.Rpc.Instance.t -> unit -> Spice_tool.t
(** [tool ~dune ()] is the erased model-facing diagnostics tool backed by
    [dune]. *)
