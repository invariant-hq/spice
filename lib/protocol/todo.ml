(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

module Id = struct
  type t = string

  let of_string id =
    if String.is_empty id then Error "todo id must not be empty" else Ok id

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t

  let jsont =
    Jsont.map ~kind:"todo id"
      ~dec:(fun id -> Decode.or_error (of_string id))
      ~enc:to_string Jsont.string
end

module Owner = struct
  type t = string

  let main = "main"

  let of_string owner =
    if String.is_empty owner then Error "todo owner must not be empty"
    else Ok owner

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t

  let jsont =
    Jsont.map ~kind:"todo owner"
      ~dec:(fun owner -> Decode.or_error (of_string owner))
      ~enc:to_string Jsont.string
end

module Status = struct
  type t = Pending | In_progress | Completed | Cancelled

  let of_string = function
    | "pending" -> Some Pending
    | "in_progress" -> Some In_progress
    | "completed" -> Some Completed
    | "cancelled" -> Some Cancelled
    | _ -> None

  let to_string = function
    | Pending -> "pending"
    | In_progress -> "in_progress"
    | Completed -> "completed"
    | Cancelled -> "cancelled"

  let equal a b = a = b
  let pp ppf t = Format.pp_print_string ppf (to_string t)

  let jsont =
    Jsont.map ~kind:"todo status"
      ~dec:(fun status ->
        match of_string status with
        | Some status -> status
        | None -> Decode.error ("unknown todo status: " ^ status))
      ~enc:to_string Jsont.string
end

module Priority = struct
  type t = High | Medium | Low

  let default = Medium

  let of_string = function
    | "high" -> Some High
    | "medium" -> Some Medium
    | "low" -> Some Low
    | _ -> None

  let to_string = function High -> "high" | Medium -> "medium" | Low -> "low"
  let equal a b = a = b
  let pp ppf t = Format.pp_print_string ppf (to_string t)

  let jsont =
    Jsont.map ~kind:"todo priority"
      ~dec:(fun priority ->
        match of_string priority with
        | Some priority -> priority
        | None -> Decode.error ("unknown todo priority: " ^ priority))
      ~enc:to_string Jsont.string
end

module Item = struct
  type t = {
    id : Id.t;
    owner : Owner.t;
    content : string;
    status : Status.t;
    priority : Priority.t;
    position : int;
  }

  let check_content = function
    | "" -> Error "todo content must not be empty"
    | _ -> Ok ()

  let check_position position =
    if position < 0 then
      Error ("todo position mismatch: expected 0, got " ^ string_of_int position)
    else Ok ()

  let make ~id ?(owner = Owner.main) ~content ?(status = Status.Pending)
      ?(priority = Priority.default) ~position () =
    let* () = check_content content in
    let* () = check_position position in
    Ok { id; owner; content; status; priority; position }

  let id t = t.id
  let owner t = t.owner
  let content t = t.content
  let status t = t.status
  let priority t = t.priority
  let position t = t.position
  let equal a b = a = b

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ id = %a; owner = %a; content = %S; status = %a; priority = %a; \
       position = %d }@]"
      Id.pp t.id Owner.pp t.owner t.content Status.pp t.status Priority.pp
      t.priority t.position

  let jsont =
    Jsont.Object.map ~kind:"todo item"
      (fun id owner content status priority position ->
        let owner = Option.value owner ~default:Owner.main in
        Decode.or_error
          (make ~id ~owner ~content ~status ~priority ~position ()))
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.opt_mem "owner" Owner.jsont ~enc:(fun t -> Some (owner t))
    |> Jsont.Object.mem "content" Jsont.string ~enc:content
    |> Jsont.Object.mem "status" Status.jsont ~enc:status
    |> Jsont.Object.mem "priority" Priority.jsont ~enc:priority
    |> Jsont.Object.mem "position" Jsont.int ~enc:position
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

type t = Item.t list

let empty = []

let compare_item a b =
  match Owner.compare (Item.owner a) (Item.owner b) with
  | 0 -> Int.compare (Item.position a) (Item.position b)
  | order -> order

let check_unique_ids items =
  let seen = Hashtbl.create (List.length items) in
  let rec loop = function
    | [] -> Ok ()
    | item :: rest ->
        let key = Id.to_string (Item.id item) in
        if Hashtbl.mem seen key then Error ("duplicate todo id: " ^ key)
        else (
          Hashtbl.add seen key ();
          loop rest)
  in
  loop items

let grouped_by_owner items =
  let table = Hashtbl.create 8 in
  List.iter
    (fun item ->
      let owner = Owner.to_string (Item.owner item) in
      let current = Option.value (Hashtbl.find_opt table owner) ~default:[] in
      Hashtbl.replace table owner (item :: current))
    items;
  Hashtbl.to_seq table |> List.of_seq
  |> List.map (fun (owner, items) -> (owner, List.sort compare_item items))

let check_owner_positions items =
  let rec loop expected = function
    | [] -> Ok ()
    | item :: rest ->
        let actual = Item.position item in
        if actual = expected then loop (expected + 1) rest
        else
          Error
            ("todo position mismatch: expected " ^ string_of_int expected
           ^ ", got " ^ string_of_int actual)
  in
  loop 0 items

let check_in_progress owner items =
  let count =
    List.fold_left
      (fun count item ->
        match Item.status item with
        | Status.In_progress -> count + 1
        | Status.Pending | Status.Completed | Status.Cancelled -> count)
      0 items
  in
  if count > 1 then Error ("multiple todos are in progress for owner " ^ owner)
  else Ok ()

let check_owner (owner, items) =
  let* () = check_owner_positions items in
  check_in_progress owner items

let rec check_owners = function
  | [] -> Ok ()
  | group :: rest ->
      let* () = check_owner group in
      check_owners rest

(* The single validation path; the codec and [decode] funnel through it. *)
let make items =
  let* () = check_unique_ids items in
  let* () = check_owners (grouped_by_owner items) in
  Ok (List.sort compare_item items)

let items t = t

let by_owner owner t =
  List.filter (fun item -> Owner.equal (Item.owner item) owner) t

let count_status status items =
  List.fold_left
    (fun count item ->
      if Status.equal (Item.status item) status then count + 1 else count)
    0 items

let counts ?owner t =
  let items = match owner with None -> t | Some owner -> by_owner owner t in
  [
    (Status.Pending, count_status Status.Pending items);
    (Status.In_progress, count_status Status.In_progress items);
    (Status.Completed, count_status Status.Completed items);
    (Status.Cancelled, count_status Status.Cancelled items);
  ]

let equal a b = a = b

let pp ppf t =
  Format.fprintf ppf "@[<v>%a@]"
    (Format.pp_print_list ~pp_sep:Format.pp_print_cut Item.pp)
    t

let jsont =
  Jsont.map ~kind:"todo list"
    ~dec:(fun items -> Decode.or_error (make items))
    ~enc:items (Jsont.list Item.jsont)

(* Host tool *)

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_list values = Jsont.Json.list values
let name = "todo_write"

let item_schema =
  json_obj
    [
      ("type", Jsont.Json.string "object");
      ( "properties",
        json_obj
          [
            ( "id",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ("minLength", Jsont.Json.int 1);
                  ("description", Jsont.Json.string "Stable non-empty todo id.");
                ] );
            ( "owner",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ("minLength", Jsont.Json.int 1);
                  ( "description",
                    Jsont.Json.string
                      "Todo owner. Defaults to \"main\" for the main assistant \
                       thread." );
                ] );
            ( "content",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ("minLength", Jsont.Json.int 1);
                  ("description", Jsont.Json.string "Actionable todo text.");
                ] );
            ( "status",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ( "enum",
                    json_list
                      [
                        Jsont.Json.string "pending";
                        Jsont.Json.string "in_progress";
                        Jsont.Json.string "completed";
                        Jsont.Json.string "cancelled";
                      ] );
                  ( "description",
                    Jsont.Json.string
                      "Todo lifecycle. Use at most one in_progress todo per \
                       owner." );
                ] );
            ( "priority",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ( "enum",
                    json_list
                      [
                        Jsont.Json.string "high";
                        Jsont.Json.string "medium";
                        Jsont.Json.string "low";
                      ] );
                  ("description", Jsont.Json.string "Todo priority.");
                ] );
            ( "position",
              json_obj
                [
                  ("type", Jsont.Json.string "integer");
                  ("minimum", Jsont.Json.int 0);
                  ( "description",
                    Jsont.Json.string
                      "Zero-based order within the owner list. Positions must \
                       be contiguous: 0, 1, 2, ... ." );
                ] );
          ] );
      ( "required",
        json_list
          [
            Jsont.Json.string "id";
            Jsont.Json.string "content";
            Jsont.Json.string "status";
            Jsont.Json.string "priority";
            Jsont.Json.string "position";
          ] );
      ("additionalProperties", Jsont.Json.bool false);
    ]

let tool_schema =
  json_obj
    [
      ("type", Jsont.Json.string "object");
      ( "properties",
        json_obj
          [
            ( "todos",
              json_obj
                [ ("type", Jsont.Json.string "array"); ("items", item_schema) ]
            );
          ] );
      ("required", json_list [ Jsont.Json.string "todos" ]);
      ("additionalProperties", Jsont.Json.bool false);
    ]

let tool =
  Spice_llm.Tool.make ~name ~description:Spice_prompts.Tools.todo_write
    ~input_schema:tool_schema ()

let input_jsont =
  Jsont.Object.map ~kind:"todo_write input" (fun todos -> todos)
  |> Jsont.Object.mem "todos" jsont ~enc:Fun.id
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let decode call =
  let actual = Spice_llm.Tool.Call.name call in
  if not (String.equal actual name) then
    Error ("expected " ^ name ^ " call, got " ^ actual)
  else Jsont.Json.decode input_jsont (Spice_llm.Tool.Call.input call)
