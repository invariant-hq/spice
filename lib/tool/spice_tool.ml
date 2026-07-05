(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Input = Input
module Output = Output
module Result = Result
module Error = Error

let invalid fn message = invalid_arg ("Spice_tool." ^ fn ^ ": " ^ message)

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

module Update = struct
  type t =
    | Progress of { title : string option; metadata : Jsont.json option }
    | Text_delta of string
end

module Context = struct
  type t = { cancelled : unit -> bool; emit : Update.t -> unit }

  let make ~cancelled ~emit () = { cancelled; emit }
  let cancelled t = t.cancelled ()
  let emit t update = t.emit update
end

type t =
  | Tool : {
      name : string;
      description : string;
      input : 'input Input.t;
      output : 'output Output.encoder;
      permissions : 'input -> Spice_permission.Request.t list;
      run : Context.t -> 'input -> 'output Result.t;
    }
      -> t

let no_permissions input =
  ignore input;
  []

let not_cancelled () = false
let ignore_update update = ignore update

let make ~name ~description ~input ~output ?(permissions = no_permissions) ~run
    () =
  reject_empty "make" "name" name;
  reject_empty "make" "description" description;
  Tool { name; description; input; output; permissions; run }

let name (Tool t) = t.name
let description (Tool t) = t.description
let input_schema (Tool t) = Input.schema t.input

let rec mem_name searched = function
  | [] -> false
  | tool :: tools ->
      String.equal searched (name tool) || mem_name searched tools

let validate tools =
  let rec loop seen = function
    | [] -> Ok ()
    | tool :: tools ->
        let name = name tool in
        if mem_name name seen then Error (Error.Duplicate_name name)
        else loop (tool :: seen) tools
  in
  loop [] tools

let rec find_tool searched = function
  | [] -> None
  | tool :: tools ->
      if String.equal searched (name tool) then Some tool
      else find_tool searched tools

(* Erases typed handler output to {!Output.t} while preserving status.
   [Completed] always carries output by construction. *)
let map_output f (result : _ Result.t) : _ Result.t =
  match (Result.status result, Result.output result) with
  | Result.Completed, Some output -> Result.completed ~output:(f output) ()
  | Result.Completed, None -> assert false
  | Result.Failed { kind; message; metadata }, output ->
      Result.failed ?output:(Option.map f output) ?metadata kind message
  | Result.Interrupted { reason; cancelled }, output ->
      Result.interrupted ?output:(Option.map f output) ~reason ~cancelled ()

module Call = struct
  type t =
    | Call : {
        tool : string;
        input : 'input;
        output : 'output Output.encoder;
        permissions : 'input -> Spice_permission.Request.t list;
        run : Context.t -> 'input -> 'output Result.t;
      }
        -> t

  (* Selects and decodes [name] in [tools] without checking for duplicate
     names. Callers that hold a plain, unchecked list must run {!validate}
     first; a {!Catalog.t} has already passed that check at construction. *)
  let decode_present tools ~name ~input =
    match find_tool name tools with
    | None -> Error (Error.Unknown_tool name)
    | Some (Tool tool) -> (
        match Input.decode tool.input input with
        | Error diagnostic ->
            Error (Error.Invalid_input { tool = tool.name; diagnostic })
        | Ok input ->
            Ok
              (Call
                 {
                   tool = tool.name;
                   input;
                   output = tool.output;
                   permissions = tool.permissions;
                   run = tool.run;
                 }))

  let decode tools ~name ~input () =
    match validate tools with
    | Error _ as error -> error
    | Ok () -> decode_present tools ~name ~input

  let tool (Call t) = t.tool
  let permissions (Call t) = t.permissions t.input

  let run (Call t) ?(cancelled = not_cancelled) ?(emit = ignore_update) () =
    let context = Context.make ~cancelled ~emit () in
    map_output t.output (t.run context t.input)
end

module Catalog = struct
  type tool = t
  type t = tool list

  let make tools =
    match validate tools with Error _ as error -> error | Ok () -> Ok tools

  let tools t = t
  let decode t ~name ~input () = Call.decode_present t ~name ~input
end
