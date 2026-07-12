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
  | Staged_tool : {
      name : string;
      description : string;
      input : 'input Input.t;
      output : 'output Output.encoder;
      preliminary_permissions :
        'input -> Spice_permission.Request.t list;
      prepare :
        Context.t ->
        'input ->
        [ `Prepared of 'prepared | `Finished of 'output Result.t ];
      permissions : 'prepared -> Spice_permission.Request.t list;
      run : Context.t -> 'prepared -> 'output Result.t;
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

let make_staged ~name ~description ~input ~output
    ?(preliminary_permissions = no_permissions) ~prepare ~permissions ~run () =
  reject_empty "make_staged" "name" name;
  reject_empty "make_staged" "description" description;
  Staged_tool
    {
      name;
      description;
      input;
      output;
      preliminary_permissions;
      prepare;
      permissions;
      run;
    }

let name = function Tool t -> t.name | Staged_tool t -> t.name

let description = function
  | Tool t -> t.description
  | Staged_tool t -> t.description

let input_schema = function
  | Tool t -> Input.schema t.input
  | Staged_tool t -> Input.schema t.input

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

module Execution = struct
  type t =
    | Execution : {
        tool : string;
        input : 'input;
        output : 'output Output.encoder;
        run : Context.t -> 'input -> 'output Result.t;
      }
        -> t

  let make ~tool ~input ~output ~run = Execution { tool; input; output; run }
  let tool (Execution t) = t.tool

  let run (Execution t) ?(cancelled = not_cancelled) ?(emit = ignore_update) () =
    let context = Context.make ~cancelled ~emit () in
    map_output t.output (t.run context t.input)
end

module Preparation = struct
  type outcome =
    | Finished of Output.t Result.t
    | Prepared of {
        permissions : Spice_permission.Request.t list;
        execution : Execution.t;
      }

  type t = { witness : unit ref; outcome : outcome }

  let make ~witness outcome = { witness; outcome }
  let witness t = t.witness
  let outcome t = t.outcome
end

module Call = struct
  type t =
    | Immediate : {
        tool : string;
        input : 'input;
        output : 'output Output.encoder;
        permissions : 'input -> Spice_permission.Request.t list;
        run : Context.t -> 'input -> 'output Result.t;
      }
        -> t
    | Staged_call : {
        tool : string;
        witness : unit ref;
        input : 'input;
        output : 'output Output.encoder;
        preliminary_permissions :
          'input -> Spice_permission.Request.t list;
        prepare :
          Context.t ->
          'input ->
          [ `Prepared of 'prepared | `Finished of 'output Result.t ];
        permissions : 'prepared -> Spice_permission.Request.t list;
        run : Context.t -> 'prepared -> 'output Result.t;
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
              (Immediate
                 {
                   tool = tool.name;
                   input;
                   output = tool.output;
                   permissions = tool.permissions;
                   run = tool.run;
                 }))
    | Some (Staged_tool tool) -> (
        match Input.decode tool.input input with
        | Error diagnostic ->
            Error (Error.Invalid_input { tool = tool.name; diagnostic })
        | Ok input ->
            Ok
              (Staged_call
                 {
                   tool = tool.name;
                   witness = ref ();
                   input;
                   output = tool.output;
                   preliminary_permissions = tool.preliminary_permissions;
                   prepare = tool.prepare;
                   permissions = tool.permissions;
                   run = tool.run;
                 }))

  let decode tools ~name ~input () =
    match validate tools with
    | Error _ as error -> error
    | Ok () -> decode_present tools ~name ~input

  let tool = function Immediate t -> t.tool | Staged_call t -> t.tool

  let permissions = function
    | Immediate t -> t.permissions t.input
    | Staged_call t -> t.preliminary_permissions t.input

  let execution = function
    | Immediate t ->
        Some
          (Execution.make ~tool:t.tool ~input:t.input ~output:t.output
             ~run:t.run)
    | Staged_call _ -> None

  let prepare call ?(cancelled = not_cancelled) ?(emit = ignore_update) () =
    match call with
    | Immediate _ -> None
    | Staged_call t ->
        let context = Context.make ~cancelled ~emit () in
        let outcome =
          match t.prepare context t.input with
          | `Finished result -> Preparation.Finished (map_output t.output result)
          | `Prepared prepared -> (
              match t.permissions prepared with
              | permissions ->
                  let execution =
                    Execution.make ~tool:t.tool ~input:prepared ~output:t.output
                      ~run:t.run
                  in
                  Preparation.Prepared { permissions; execution }
              | exception exn ->
                  Preparation.Finished
                    (Result.failed `Failed
                       ("tool permission planner raised: "
                      ^ Printexc.to_string exn)))
        in
        Some (Preparation.make ~witness:t.witness outcome)

  let prepared_outcome call preparation =
    match call with
    | Immediate _ -> None
    | Staged_call t ->
        if t.witness == Preparation.witness preparation then
          Some (Preparation.outcome preparation)
        else None

  let run call ?cancelled ?emit () =
    match execution call with
    | Some execution -> Execution.run execution ?cancelled ?emit ()
    | None -> invalid "Call.run" "staged call must be prepared before execution"
end

module Catalog = struct
  type tool = t
  type t = tool list

  let make tools =
    match validate tools with Error _ as error -> error | Ok () -> Ok tools

  let tools t = t
  let decode t ~name ~input () = Call.decode_present t ~name ~input
end
