(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OCaml AST edit planning and execution.

    [Ocaml_ast_edit] parses current [.ml] or [.mli] contents with the upstream
    OCaml compiler parser, resolves structural selectors to compiler source
    locations, validates replacement text with the parser for the selected
    syntactic category, and lowers the result to a stale-safe {!Spice_edit.t}.

    The pure {!plan} API performs no filesystem IO. The model-facing {!tool}
    reads one existing UTF-8 regular workspace file, applies the plan through
    {!Spice_edit.apply}, and returns typed edit evidence. *)

val name : string
(** Stable tool name, ["ocaml_ast_edit"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_max_file_bytes : int
(** Default maximum complete-file size accepted by {!run}. *)

(** {1 Source files} *)

type file_kind =
  | Implementation
  | Interface
      (** The OCaml source grammar used for parsing current contents and item
          fragments. *)

(** {1 Selectors} *)

module Item_kind : sig
  (** OCaml structure or signature item namespaces selectable by name. *)

  type t =
    | Value
    | Type
    | Module
    | Module_type
    | Exception
    | External
    | Open
    | Include
    | Class
    | Class_type
    | Extension
    | Eval

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same item kind. *)

  val to_string : t -> string
  (** [to_string t] is the provider-facing name for [t]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

module Node_kind : sig
  (** AST node categories selectable by source range or enclosing position. *)

  type t =
    | Item of Item_kind.t option
    | Expression
    | Type
        (** The type for selectable AST node categories.

            [Item None] selects any item namespace; [Item (Some kind)] restricts
            the item namespace. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same node kind. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

module Selector : sig
  (** Requests for a single AST node, by qualified item name, enclosing
      position, or exact source range. *)

  type t
  (** A request for one AST node. *)

  val item : ?kind:Item_kind.t -> ?occurrence:int -> string list -> t
  (** [item ?kind ?occurrence path] selects an item by qualified source name.

      [path] is non-empty and uses module nesting, for example
      [["M"; "N"; "value"]]. [kind], when present, disambiguates names that
      exist in more than one namespace. [occurrence] is one-based and defaults
      to [1]. It selects among identical matches after parsing order.

      Raises [Invalid_argument] if [path] is empty, any component is empty, or
      [occurrence < 1]. *)

  val enclosing : kind:Node_kind.t -> position:Spice_ocaml.Position.t -> t
  (** [enclosing ~kind ~position] selects the smallest parsed node of [kind]
      whose source range contains [position]. *)

  val exact : kind:Node_kind.t -> range:Spice_ocaml.Range.t -> t
  (** [exact ~kind ~range] selects the parsed node of [kind] whose source range
      exactly equals [range]. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1 Edits} *)

module Edit : sig
  (** Structural edit requests over selected AST nodes. *)

  type op =
    | Replace
    | Insert_before
    | Insert_after
    | Delete  (** The type for structural edit operations. *)

  type t
  (** One structural edit. *)

  val make : op:op -> selector:Selector.t -> ?text:string -> unit -> t
  (** [make ~op ~selector ?text ()] is a structural edit.

      [Replace] and insert operations require non-empty [text]. [Delete] ignores
      [text]. Replacement text for item selections is parsed as a complete item
      fragment in the current file grammar. Replacement text for expression and
      type selections is parsed as exactly one expression or core type.
      Insertions are only valid around item selections and parse [text] as an
      item fragment.

      Raises [Invalid_argument] when the operation/text combination is invalid
      or [text] is not valid UTF-8. *)

  val op : t -> op
  (** [op t] is [t]'s structural operation. *)

  val selector : t -> Selector.t
  (** [selector t] is the AST selector [t] applies to. *)

  val text : t -> string option
  (** [text t] is the replacement or inserted text, when [t]'s operation carries
      text. *)
end

(** {1 Tool input} *)

module Input : sig
  type selector = Selector.t
  (** The type for edit selectors. Alias of {!Selector.t}. *)

  type edit = Edit.t
  (** The type for structural edits. Alias of {!Edit.t}. *)

  type t
  (** Typed AST edit request.

      Provider JSON uses:
      - [path], a workspace-relative or workspace-contained OCaml source path;
      - optional [file_kind], ["implementation"]/[ "ml"] or
        ["interface"]/[ "mli"], otherwise inferred from [.ml] or [.mli];
      - optional [if_identity], a complete-file identity from a previous read;
      - [edits], a non-empty list of structural edits.

      Each JSON edit has [op] equal to ["replace"], ["insert_before"],
      ["insert_after"], or ["delete"], a [selector], and optional [text].
      Selectors have [mode]:
      - ["item"] with [path : string list], optional [item_kind], and optional
        one-based [occurrence];
      - ["enclosing"] with [kind], optional [node_item_kind], [line], and
        zero-based [column];
      - ["exact"] with [kind], optional [node_item_kind], and
        [start_line]/[start_column]/[end_line]/[end_column].

      [kind] is ["item"], ["expression"], or ["type"]. [node_item_kind] is valid
      only when [kind] is ["item"] and uses {!Item_kind.to_string} names. *)

  val make :
    path:string ->
    ?file_kind:file_kind ->
    ?if_identity:Spice_digest.Identity.t ->
    edits:edit list ->
    unit ->
    t
  (** [make ~path ?file_kind ?if_identity ~edits ()] builds a typed request.

      Raises [Invalid_argument] if [path] is empty, [file_kind] cannot be
      inferred, or [edits] is empty. *)

  val path : t -> string
  (** [path t] is the requested path string. *)

  val file_kind : t -> file_kind
  (** [file_kind t] is the grammar used to parse [t]'s target file. *)

  val edits : t -> edit list
  (** [edits t] are the requested structural edits in input order. *)

  val if_identity : t -> Spice_digest.Identity.t option
  (** [if_identity t] is the requested complete-file freshness identity, if any.
  *)

  val contract : t Spice_tool.Input.t
  (** JSON input contract for the model-facing tool. Unknown fields are
      rejected. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes provider JSON with {!contract}. *)
end

(** {1 Results} *)

module Resolved : sig
  type t
  (** Evidence for one selected AST range before rewriting. *)

  val selector : t -> Selector.t
  (** [selector t] is the input selector that resolved to [t]. *)

  val kind : t -> Node_kind.t
  (** [kind t] is the concrete node kind matched by [t]. *)

  val range : t -> Spice_ocaml.Range.t
  (** [range t] is the source range selected in the original file. *)

  val selected_text : t -> string
  (** [selected_text t] is the exact source text covered by {!range}. *)
end

module Plan : sig
  (** Planned full-file rewrites with per-edit selection evidence. Produced by
      {!plan} without filesystem IO. *)

  type t
  (** A planned full-file rewrite plus structural selection evidence. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path being edited. *)

  val file_kind : t -> file_kind
  (** [file_kind t] is the grammar used for parsing and validation. *)

  val before_contents : t -> string
  (** [before_contents t] is the complete source text supplied to {!plan}. *)

  val after_contents : t -> string
  (** [after_contents t] is the complete source text after structural edits. *)

  val edit : t -> Spice_edit.t
  (** [edit t] is the stale-safe full-file rewrite plan for [t]. *)

  val resolved : t -> Resolved.t list
  (** [resolved t] is one selection evidence entry per input edit, in input
      order. *)
end

module Output : sig
  (** Typed tool output: the edited path, selection evidence, mutation receipt,
      and final content identity. *)

  type t
  (** Typed output and edit evidence. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path that was edited or checked. *)

  val file_kind : t -> file_kind
  (** [file_kind t] is the grammar used for parsing and validation. *)

  val before_contents : t -> string
  (** [before_contents t] is the complete UTF-8 source text observed before
      planning.

      This is host/session evidence. {!encode} keeps model-visible output
      compact and does not echo the complete file. *)

  val after_contents : t -> string
  (** [after_contents t] is the complete UTF-8 source text after applying the
      structural edits.

      For unchanged outputs this equals {!before_contents}. *)

  val resolved : t -> Resolved.t list
  (** [resolved t] is selection evidence for the edits that were planned. *)

  val receipt : t -> Receipt.t
  (** [receipt t] is the common successful mutation receipt.

      It is empty for unchanged outputs. *)

  val identity : t -> Spice_digest.Identity.t
  (** [identity t] is the identity of [after_contents t]. *)

  val encode : t Spice_tool.Output.encoder
  (** [encode] projects typed output to compact model-visible text and JSON.

      The projection reports the path, status, selected ranges, final identity,
      and freshness evidence. It does not include complete before or after
      contents; host/session code should use {!before_contents} and
      {!after_contents} for cache and audit state. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the retained typed output when [output] came
      from [ocaml_ast_edit]. *)
end

module Error : sig
  (** Pure AST edit planning errors.

      These errors happen before filesystem mutation. Tool execution maps them
      to model-facing failed tool results; callers using {!plan} can branch on
      constructors directly. *)

  type t =
    | Invalid_text of string
        (** Input text or replacement text is not valid UTF-8, or cannot be used
            for the selected operation. The string is a human-readable
            diagnostic. *)
    | Invalid_range of string
        (** A selector or compiler location described an invalid source range.
        *)
    | Parse_error of {
        phase : string;
            (** Planning phase that parsed source, such as current file,
                replacement fragment, or final file validation. *)
        message : string;  (** Compiler parser diagnostic. *)
        range : Spice_ocaml.Range.t option;
            (** Source range reported by the parser, when available. *)
      }
    | Selection_not_found of Selector.t
        (** A selector matched no parsed node. *)
    | Ambiguous_selection of {
        selector : Selector.t;  (** Selector that matched more than one node. *)
        matches : Spice_ocaml.Range.t list;
            (** Matching source ranges in parse order. *)
      }
    | Invalid_operation of string
        (** The requested operation is not valid for the selected node kind. *)
    | Overlapping_edits of Spice_ocaml.Range.t * Spice_ocaml.Range.t
        (** Two selected ranges overlap and cannot be applied deterministically.
        *)
    | Edit_error of Spice_edit.Error.t
        (** Lowering to the stale-safe full-file edit plan failed. *)

  val message : t -> string
  (** [message t] is a human-readable diagnostic. The exact text is not a stable
      matching surface. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

val plan :
  path:Spice_workspace.Path.t ->
  file_kind:file_kind ->
  contents:string ->
  Edit.t list ->
  (Plan.t, Error.t) result
(** [plan ~path ~file_kind ~contents edits] parses [contents], resolves [edits]
    against that AST, parses replacement fragments, checks that all byte ranges
    are non-overlapping, applies replacements bottom-up, reparses the final
    file, and returns a {!Spice_edit.rewrite} plan.

    Formatting and comments outside selected ranges are byte-preserved. Text
    inside selected ranges is replaced exactly by caller-provided text. Comments
    outside compiler locations are intentionally not moved or reattached. Empty
    edit lists are invalid because this planner represents a requested AST edit,
    not a no-op check. *)

val permissions :
  workspace:Spice_workspace.t -> Input.t -> Spice_permission.Request.t list
(** [permissions ~workspace input] is the modify permission request for the
    target path. If the path cannot be resolved, {!run} reports the failure. *)

val run :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?max_file_bytes:int ->
  ?cancelled:(unit -> bool) ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~fs ~workspace input] reads, plans, validates, and applies an AST edit.

    The target must be an existing regular UTF-8 OCaml source file inside the
    workspace. The current contents are parsed with the selected grammar,
    selectors are resolved against compiler AST locations, replacement fragments
    are parsed, overlapping ranges are rejected, and the edited file is parsed
    again before mutation. Application uses {!Spice_edit.apply}, so concurrent
    changes after planning are rejected as stale writes.

    [if_identity], when supplied, must match the complete current file identity
    before parsing begins. [max_file_bytes] defaults to
    {!default_max_file_bytes}. *)

val tool :
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  ?max_file_bytes:int ->
  unit ->
  Spice_tool.t
(** [tool ~fs ~workspace ()] is the erased model-facing tool for {!run}. *)
