(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { rule : Policy.Rule.t; summary : string }

let rule t = t.rule
let summary t = t.summary

(* Command family arity: how many leading tokens (program included) name the
   human-understood command, so a longer command still generalizes to that
   family. Modelled on opencode's arity table and codex's allow-prefix — flags
   never count, the longest matching prefix wins, and an unlisted program falls
   back to the program alone. Kept small and dev-focused on purpose: a wrong
   entry only widens or narrows the suggested rule, which the reviewer sees and
   the scope selector bounds. *)
let arity_of_prefix = function
  | "git" | "dune" | "opam" | "cargo" | "go" | "npm" | "pnpm" | "yarn"
  | "docker" | "kubectl" | "bundle" | "gem" | "brew" | "apt" | "apt-get" | "pip"
  | "pip3" | "poetry" | "uv" ->
      Some 2
  | "npm run" | "pnpm run" | "yarn run" | "cargo run" | "uv run" -> Some 3
  | _ -> None

let take n xs =
  let rec go n = function
    | x :: rest when n > 0 -> x :: go (n - 1) rest
    | _ -> []
  in
  if n <= 0 then [] else go n xs

(* The command family prefix for [tokens] (program :: args): the longest listed
   arity prefix, else the program alone. *)
let command_prefix tokens =
  let rec find len =
    if len <= 0 then take 1 tokens
    else
      match arity_of_prefix (String.concat " " (take len tokens)) with
      | Some arity -> take arity tokens
      | None -> find (len - 1)
  in
  find (List.length tokens)

let command_suggestion execution cwd program args =
  match (cwd : Access.Path_scope.t) with
  | Access.Path_scope.Workspace { root_key; relative } ->
      let prefix = command_prefix (program :: args) in
      (* [prefix] holds [program] as its head, so the argument prefix is its
         tail. *)
      let args_prefix = match prefix with [] -> [] | _ :: rest -> rest in
      let cwd = Policy.Match.Path.exact_key ~root_key ~relative in
      let matcher =
        Policy.Match.command
          (Policy.Match.Command.argv_prefix ~execution ~cwd ~program
             ~args:args_prefix ())
      in
      Some
        { rule = Policy.Rule.allow matcher; summary = String.concat " " prefix }
  | Access.Path_scope.Outside_workspace _ | Access.Path_scope.Unknown _ -> None

let path_op_noun = function
  | `Read -> "reads"
  | `Create | `Modify -> "edits"
  | `Delete -> "deletes"

let path_suggestion op scope =
  match (scope : Access.Path_scope.t) with
  | Access.Path_scope.Workspace { relative; _ } ->
      let matcher, target =
        match Spice_path.Rel.parent relative with
        | Some parent when not (Spice_path.Rel.is_root parent) ->
            ( Policy.Match.path ~op (Policy.Match.Path.under_relative parent),
              "under " ^ Spice_path.Rel.to_string parent ^ "/" )
        | Some _ | None ->
            ( Policy.Match.path ~op (Policy.Match.Path.exact_relative relative),
              "to " ^ Spice_path.Rel.to_string relative )
      in
      Some
        {
          rule = Policy.Rule.allow matcher;
          summary = path_op_noun op ^ " " ^ target;
        }
  | Access.Path_scope.Outside_workspace _ | Access.Path_scope.Unknown _ -> None

let network_suggestion host =
  Some
    {
      rule = Policy.Rule.allow (Policy.Match.network_host ~host ());
      summary = "requests to " ^ host;
    }

let of_access access =
  match (access : Access.t) with
  | Access.Path { op; scope } -> path_suggestion op scope
  | Access.Command
      (Access.Command.Argv { program; args; cwd; execution }) ->
      command_suggestion execution cwd program args
  | Access.Command (Access.Command.Shell _) -> None
  | Access.Network { host; _ } -> network_suggestion host
  | Access.Custom _ -> None

let of_accesses accesses =
  let seen = ref [] in
  List.filter_map
    (fun access ->
      match of_access access with
      | None -> None
      | Some suggestion ->
          if List.exists (Policy.Rule.equal suggestion.rule) !seen then None
          else begin
            seen := suggestion.rule :: !seen;
            Some suggestion
          end)
    accesses
