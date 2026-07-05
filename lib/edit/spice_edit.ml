(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module W = Spice_workspace

type kind = [ `Create | `Modify | `Delete ]

module State = struct
  type t = Missing | Text of string

  let equal a b =
    match (a, b) with
    | Missing, Missing -> true
    | Text a, Text b -> String.equal a b
    | (Missing | Text _), _ -> false

  let pp ppf = function
    | Missing -> Format.pp_print_string ppf "Missing"
    | Text contents ->
        Format.fprintf ppf "@[<hov>Text { bytes = %d }@]"
          (String.length contents)
end

module Observed = struct
  type kind = [ `Missing | `Text | `Other ]
  type t = Missing | Text of string | Other

  let kind = function Missing -> `Missing | Text _ -> `Text | Other -> `Other
  let text = function Text contents -> Some contents | Missing | Other -> None

  let identity = function
    | Text contents -> Some (Spice_digest.Identity.of_contents contents)
    | Missing | Other -> None

  let equal_kind (a : kind) (b : kind) = a = b

  let equal a b =
    match (a, b) with
    | Missing, Missing -> true
    | Text a, Text b -> String.equal a b
    | Other, Other -> true
    | (Missing | Text _ | Other), _ -> false

  let pp_kind ppf = function
    | `Missing -> Format.pp_print_string ppf "missing"
    | `Text -> Format.pp_print_string ppf "text"
    | `Other -> Format.pp_print_string ppf "other"

  let pp ppf = function
    | Missing -> Format.pp_print_string ppf "Missing"
    | Text contents ->
        Format.fprintf ppf "@[<hov>Text { bytes = %d }@]"
          (String.length contents)
    | Other -> Format.pp_print_string ppf "Other"
end

module Error = struct
  type t =
    | Invalid_text of W.Path.t option * string
    | Duplicate_path of W.Path.t
    | State_mismatch of {
        path : W.Path.t;
        expected : Observed.kind;
        actual : Observed.kind;
      }
    | Conflict of { path : W.Path.t; expected : State.t; actual : Observed.t }
    | Too_large of { path : W.Path.t; size : int64; max_size : int64 }
    | Workspace of W.Path.t option * W.Resolve_error.t
    | Out_of_workspace of W.Path.t
    | Protected_path of W.Path.t * string
    | Io of W.Path.t option * string

  let invalid fn message =
    invalid_arg ("Spice_edit.Error." ^ fn ^ ": " ^ message)

  let reject_empty fn field value =
    if String.equal value "" then invalid fn (field ^ " must not be empty")

  let path = function
    | Invalid_text (path, _) | Workspace (path, _) | Io (path, _) -> path
    | Duplicate_path path
    | State_mismatch { path; _ }
    | Too_large { path; _ }
    | Out_of_workspace path
    | Protected_path (path, _) ->
        Some path
    | Conflict { path; _ } -> Some path

  let invalid_text ?path reason =
    reject_empty "invalid_text" "reason" reason;
    Invalid_text (path, reason)

  let duplicate_path path = Duplicate_path path

  let state_mismatch ~path ~expected ~actual =
    State_mismatch { path; expected; actual }

  let conflict ~path ~expected ~actual = Conflict { path; expected; actual }

  let too_large ~path ~size ~max_size =
    if size < 0L then invalid "too_large" "size must be non-negative";
    if max_size < 0L then invalid "too_large" "max_size must be non-negative";
    Too_large { path; size; max_size }

  let workspace ?path error = Workspace (path, error)
  let out_of_workspace path = Out_of_workspace path

  let protected_path ~path ~name =
    reject_empty "protected_path" "name" name;
    Protected_path (path, name)

  let io ?path reason =
    reject_empty "io" "reason" reason;
    Io (path, reason)

  let path_prefix = function
    | None -> ""
    | Some path -> Format.asprintf "%a: " W.Path.pp path

  let message = function
    | Invalid_text (path, reason) ->
        path_prefix path ^ "invalid UTF-8 text: " ^ reason
    | Duplicate_path path ->
        Format.asprintf "%a: duplicate edit target" W.Path.pp path
    | State_mismatch { path; expected; actual } ->
        Format.asprintf "%a: expected %a, found %a" W.Path.pp path
          Observed.pp_kind expected Observed.pp_kind actual
    | Conflict { path; _ } -> Format.asprintf "%a: stale write" W.Path.pp path
    | Too_large { path; size; max_size } ->
        Format.asprintf "%a: file is too large (%Ld bytes, max %Ld)" W.Path.pp
          path size max_size
    | Workspace (path, error) ->
        path_prefix path ^ W.Resolve_error.message error
    | Out_of_workspace path ->
        Format.asprintf "%a: edit target is no longer inside the workspace"
          W.Path.pp path
    | Protected_path (path, name) ->
        Format.asprintf
          "%a: %s is protected workspace metadata and cannot be modified by \
           tools; change sandbox and workspace policy through configuration or \
           the CLI instead"
          W.Path.pp path name
    | Io (path, reason) -> path_prefix path ^ "filesystem I/O error: " ^ reason

  let equal a b =
    match (a, b) with
    | Invalid_text (a_path, a_reason), Invalid_text (b_path, b_reason)
    | Io (a_path, a_reason), Io (b_path, b_reason) ->
        Option.equal W.Path.equal a_path b_path
        && String.equal a_reason b_reason
    | Duplicate_path a, Duplicate_path b -> W.Path.equal a b
    | ( State_mismatch
          { path = a_path; expected = a_expected; actual = a_actual },
        State_mismatch
          { path = b_path; expected = b_expected; actual = b_actual } ) ->
        W.Path.equal a_path b_path
        && Observed.equal_kind a_expected b_expected
        && Observed.equal_kind a_actual b_actual
    | ( Conflict { path = a_path; expected = a_expected; actual = a_actual },
        Conflict { path = b_path; expected = b_expected; actual = b_actual } )
      ->
        W.Path.equal a_path b_path
        && State.equal a_expected b_expected
        && Observed.equal a_actual b_actual
    | ( Too_large { path = a_path; size = a_size; max_size = a_max },
        Too_large { path = b_path; size = b_size; max_size = b_max } ) ->
        W.Path.equal a_path b_path && Int64.equal a_size b_size
        && Int64.equal a_max b_max
    | Workspace (a_path, a_error), Workspace (b_path, b_error) ->
        Option.equal W.Path.equal a_path b_path
        && W.Resolve_error.equal a_error b_error
    | Out_of_workspace a, Out_of_workspace b -> W.Path.equal a b
    | Protected_path (a_path, a_name), Protected_path (b_path, b_name) ->
        W.Path.equal a_path b_path && String.equal a_name b_name
    | ( ( Invalid_text _ | Duplicate_path _ | State_mismatch _ | Conflict _
        | Too_large _ | Workspace _ | Out_of_workspace _ | Protected_path _
        | Io _ ),
        _ ) ->
        false

  let pp ppf t = Format.pp_print_string ppf (message t)
end

let valid_utf8 text =
  let rec loop i =
    if i = String.length text then true
    else
      let uchar = String.get_utf_8_uchar text i in
      Uchar.utf_decode_is_valid uchar && loop (i + Uchar.utf_decode_length uchar)
  in
  loop 0

let check_text ?path text =
  if valid_utf8 text then Ok ()
  else Error (Error.invalid_text ?path "invalid UTF-8")

module Change = struct
  open State

  type t = { path : W.Path.t; before : State.t; after : State.t }

  let validate_image path = function
    | State.Missing -> Ok ()
    | Text contents -> check_text ~path contents

  let make ~path ~before ~after =
    match validate_image path before with
    | Error _ as error -> error
    | Ok () -> (
        match validate_image path after with
        | Error _ as error -> error
        | Ok () -> (
            match (before, after) with
            | Missing, Missing -> Ok None
            | Text before, Text after when String.equal before after -> Ok None
            | Missing, Text _ | Text _, Text _ | Text _, Missing ->
                Ok (Some { path; before; after })))

  let create ~path ~contents =
    match make ~path ~before:Missing ~after:(Text contents) with
    | Ok (Some change) -> Ok change
    | Ok None -> Error (Error.io ~path "create normalized to an empty change")
    | Error _ as error -> error

  let rewrite ~path ~before ~after =
    make ~path ~before:(Text before) ~after:(Text after)

  let delete ~path ~before =
    match make ~path ~before:(Text before) ~after:Missing with
    | Ok (Some change) -> Ok change
    | Ok None -> Error (Error.io ~path "delete normalized to an empty change")
    | Error _ as error -> error

  let kind = function
    | { before = Missing; after = Text _; _ } -> `Create
    | { before = Text _; after = Text _; _ } -> `Modify
    | { before = Text _; after = Missing; _ } -> `Delete
    | { before = Missing; after = Missing; _ } -> assert false

  let path t = t.path
  let before t = t.before
  let after t = t.after

  let equal a b =
    W.Path.equal a.path b.path
    && State.equal a.before b.before
    && State.equal a.after b.after

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ path = %a; before = %a; after = %a }@]"
      W.Path.pp t.path State.pp t.before State.pp t.after

  let default_label path = Spice_diff.Label.escaped (W.Path.display path)

  let to_diff ?(label = default_label) t =
    let label = label t.path in
    match (t.before, t.after) with
    | Missing, Text contents -> Spice_diff.File_change.create ~label ~contents
    | Text contents, Missing -> Spice_diff.File_change.delete ~label ~contents
    | Text before, Text after ->
        Spice_diff.File_change.modify ~label ~before ~after
    | Missing, Missing -> assert false
end

module Apply = struct
  type io = {
    with_write_lock :
      'a.
      W.Path.t list -> (unit -> ('a, Error.t) result) -> ('a, Error.t) result;
    revalidate : W.Path.t -> (W.Path.t, Error.t) result;
    read : W.Path.t -> (Observed.t, Error.t) result;
    commit :
      path:W.Path.t -> before:State.t -> after:State.t -> (unit, Error.t) result;
  }
end

module Result = struct
  module Entry = struct
    type t = {
      planned : Change.t;
      target_path : W.Path.t;
      before : Observed.t;
      after : Observed.t;
    }

    let equal a b =
      Change.equal a.planned b.planned
      && W.Path.equal a.target_path b.target_path
      && Observed.equal a.before b.before
      && Observed.equal a.after b.after

    let pp ppf t =
      Format.fprintf ppf
        "@[<hov>{ planned = %a; target_path = %a; before = %a; after = %a }@]"
        Change.pp t.planned W.Path.pp t.target_path Observed.pp t.before
        Observed.pp t.after

    let kind t = Change.kind t.planned
    let target_path t = t.target_path
    let before t = t.before
    let after t = t.after
  end

  type t = { entries : Entry.t list }

  let empty = { entries = [] }
  let is_empty t = List.is_empty t.entries
  let entries t = t.entries
  let equal a b = List.equal Entry.equal a.entries b.entries

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ entries = [%a] }@]"
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         Entry.pp)
      t.entries
end

module Apply_error = struct
  type t = { error : Error.t; applied : Result.Entry.t list }

  let error t = t.error
  let applied t = t.applied
  let message t = Error.message t.error

  let equal a b =
    Error.equal a.error b.error
    && List.equal Result.Entry.equal a.applied b.applied

  let pp ppf t =
    Format.fprintf ppf "@[<hov>{ error = %a; applied = [%a] }@]" Error.pp
      t.error
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
         Result.Entry.pp)
      t.applied
end

type t = { changes : Change.t list }

let empty = { changes = [] }
let is_empty t = List.is_empty t.changes

let create ~path ~contents =
  match Change.create ~path ~contents with
  | Error _ as error -> error
  | Ok change -> Ok { changes = [ change ] }

let rewrite ~path ~before ~after =
  match Change.rewrite ~path ~before ~after with
  | Error _ as error -> error
  | Ok None -> Ok empty
  | Ok (Some change) -> Ok { changes = [ change ] }

let delete ~path ~before =
  match Change.delete ~path ~before with
  | Error _ as error -> error
  | Ok change -> Ok { changes = [ change ] }

let first_duplicate_path paths =
  let sorted = List.sort W.Path.compare paths in
  let rec loop = function
    | [] | [ _ ] -> None
    | a :: (b :: _ as rest) -> if W.Path.equal a b then Some a else loop rest
  in
  loop sorted

let of_changes changes =
  let paths = List.map Change.path changes in
  match first_duplicate_path paths with
  | Some path -> Error (Error.duplicate_path path)
  | None -> Ok { changes }

let concat plans =
  let rec collect acc = function
    | [] -> of_changes (List.rev acc)
    | plan :: plans -> collect (List.rev_append plan.changes acc) plans
  in
  collect [] plans

let paths t = List.map Change.path t.changes
let equal a b = List.equal Change.equal a.changes b.changes

let pp ppf t =
  Format.fprintf ppf "@[<hov>{ changes = [%a] }@]"
    (Format.pp_print_list
       ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
       Change.pp)
    t.changes

let diff ?label ?mode ?limits ?context t =
  Spice_diff.render ?mode ?limits ?context
    (List.map (Change.to_diff ?label) t.changes)

let workspace_path_error path = Error.out_of_workspace path

let revalidate_one ~workspace ~io path =
  match io.Apply.revalidate path with
  | Error _ as error -> error
  | Ok path ->
      if W.contains_path workspace path then Ok path
      else Error (workspace_path_error path)

let rec revalidate_all ~workspace ~io acc = function
  | [] -> Ok (List.rev acc)
  | path :: paths -> (
      match revalidate_one ~workspace ~io path with
      | Error _ as error -> error
      | Ok path -> revalidate_all ~workspace ~io (path :: acc) paths)

let rec read_all ~io acc = function
  | [] -> Ok (List.rev acc)
  | path :: paths -> (
      match io.Apply.read path with
      | Error _ as error -> error
      | Ok target -> read_all ~io (target :: acc) paths)

let validate_target change path target =
  match (Change.before change, target) with
  | State.Missing, Observed.Missing -> Ok ()
  | State.Missing, target ->
      Error
        (Error.state_mismatch ~path ~expected:`Missing
           ~actual:(Observed.kind target))
  | State.Text before, Observed.Text current ->
      if String.equal before current then Ok ()
      else
        Error
          (Error.conflict ~path ~expected:(State.Text before) ~actual:target)
  | State.Text _, target ->
      Error
        (Error.state_mismatch ~path ~expected:`Text
           ~actual:(Observed.kind target))

type checked = { change : Change.t; path : W.Path.t; before : Observed.t }

let checked_entry change path before =
  match validate_target change path before with
  | Error _ as error -> error
  | Ok () -> Ok { change; path; before }

let checked_entries changes paths targets =
  let rec loop acc changes paths targets =
    match (changes, paths, targets) with
    | [], [], [] -> Ok (List.rev acc)
    | change :: changes, path :: paths, target :: targets -> (
        match checked_entry change path target with
        | Error _ as error -> error
        | Ok checked -> loop (checked :: acc) changes paths targets)
    | [], _, _ | _, [], _ | _, _, [] ->
        Error (Error.io "edit apply state length mismatch")
  in
  loop [] changes paths targets

let target_after_change change =
  match Change.after change with
  | State.Text contents -> Observed.Text contents
  | State.Missing -> Observed.Missing

let result_entry checked =
  ({
     Result.Entry.planned = checked.change;
     Result.Entry.target_path = checked.path;
     Result.Entry.before = checked.before;
     Result.Entry.after = target_after_change checked.change;
   }
    : Result.Entry.t)

let apply_one ~io checked =
  match
    io.Apply.commit ~path:checked.path
      ~before:(Change.before checked.change)
      ~after:(Change.after checked.change)
  with
  | Error _ as error -> error
  | Ok () -> Ok (result_entry checked)

let apply_error ?(applied = []) error : Apply_error.t =
  { Apply_error.error; Apply_error.applied }

let apply_checked ~io checked =
  let rec loop applied = function
    | [] -> Ok ({ Result.entries = List.rev applied } : Result.t)
    | checked :: rest -> (
        match apply_one ~io checked with
        | Ok entry -> loop (entry :: applied) rest
        | Error error -> Error (apply_error ~applied:(List.rev applied) error))
  in
  loop [] checked

let apply_inside_lock ~io ~workspace t =
  match revalidate_all ~workspace ~io [] (paths t) with
  | Error error -> Error (apply_error error)
  | Ok paths -> (
      match first_duplicate_path paths with
      | Some path -> Error (apply_error (Error.duplicate_path path))
      | None -> (
          match read_all ~io [] paths with
          | Error error -> Error (apply_error error)
          | Ok targets -> (
              match checked_entries t.changes paths targets with
              | Error error -> Error (apply_error error)
              | Ok checked -> apply_checked ~io checked)))

let apply ~io ~workspace t =
  if is_empty t then Ok Result.empty
  else
    match
      io.Apply.with_write_lock (paths t) (fun () ->
          Ok (apply_inside_lock ~io ~workspace t))
    with
    | Error error -> Error (apply_error error)
    | Ok result -> result
