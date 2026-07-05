(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

let check_non_empty message = function
  | "" -> Error message
  | (_ : string) -> Ok ()

let check_optional_non_empty message = function
  | Some "" -> Error message
  | Some _ | None -> Ok ()

module Role = struct
  type t = Explore | Review | Verify

  let to_string = function
    | Explore -> "explore"
    | Review -> "review"
    | Verify -> "verify"

  let equal a b = a = b
  let pp ppf t = Format.pp_print_string ppf (to_string t)

  let jsont =
    Jsont.map ~kind:"subagent role"
      ~dec:(function
        | "explore" -> Explore
        | "review" -> Review
        | "verify" -> Verify
        | role -> Decode.error ("unknown subagent role: " ^ role))
      ~enc:to_string Jsont.string

  let contract = function
    | Explore | Review -> Contract.read_only
    | Verify -> Contract.checks

  let developer text = Spice_llm.Message.developer text

  let prelude_messages = function
    | Explore -> [ developer Spice_prompts.Subagents.explore ]
    | Review -> [ developer Spice_prompts.Subagents.review ]
    | Verify -> [ developer Spice_prompts.Subagents.verify ]
end

module Spawn = struct
  type t = {
    role : Role.t;
    task : string;
    scope : string list;
    expected_output : string option;
  }

  let check_scope scope =
    let rec loop = function
      | [] -> Ok ()
      | "" :: _ -> Error "subagent scope item must not be empty"
      | _ :: rest -> loop rest
    in
    loop scope

  let make ~role ~task ?(scope = []) ?expected_output () =
    let* () = check_non_empty "subagent task must not be empty" task in
    let* () = check_scope scope in
    let* () =
      check_optional_non_empty "subagent expected output must not be empty"
        expected_output
    in
    Ok { role; task; scope; expected_output }

  let role t = t.role
  let task t = t.task
  let scope t = t.scope
  let expected_output t = t.expected_output
  let equal a b = a = b

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ role = %a; task = %S; scope = %a; expected_output = %a }@]"
      Role.pp t.role t.task
      (Format.pp_print_list Format.pp_print_string)
      t.scope
      (Format.pp_print_option Format.pp_print_string)
      t.expected_output

  let jsont =
    Jsont.Object.map ~kind:"subagent spawn"
      (fun role task scope expected_output ->
        let scope = Option.value scope ~default:[] in
        Decode.or_error (make ~role ~task ~scope ?expected_output ()))
    |> Jsont.Object.mem "role" Role.jsont ~enc:role
    |> Jsont.Object.mem "task" Jsont.string ~enc:task
    |> Jsont.Object.opt_mem "scope" (Jsont.list Jsont.string) ~enc:(fun t ->
        Some (scope t))
    |> Jsont.Object.opt_mem "expected_output" Jsont.string ~enc:expected_output
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_list values = Jsont.Json.list values

let string_schema = json_obj [ ("type", Jsont.Json.string "string") ]

let decode_for expected jsont call =
  let actual = Spice_llm.Tool.Call.name call in
  if not (String.equal actual expected) then
    Error ("expected " ^ expected ^ " call, got " ^ actual)
  else Jsont.Json.decode jsont (Spice_llm.Tool.Call.input call)

module Wait = struct
  module Request = struct
    type t = { runs : Spice_session.Id.t list }

    let make ~runs =
      match runs with
      | [] -> Error "wait_subagents runs must not be empty"
      | runs -> Ok { runs }

    let runs t = t.runs
    let equal a b = a = b

    let pp ppf t =
      Format.fprintf ppf "@[<hov>{ runs = %a }@]"
        (Format.pp_print_list Spice_session.Id.pp)
        t.runs

    let jsont =
      Jsont.Object.map ~kind:"subagent wait" (fun runs ->
          Decode.or_error (make ~runs))
      |> Jsont.Object.mem "runs"
           (Jsont.list Spice_session.Id.jsont)
           ~enc:runs
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
  end

  let name = "wait_subagents"

  let tool_schema =
    json_obj
      [
        ("type", Jsont.Json.string "object");
        ( "properties",
          json_obj
            [
              ( "runs",
                json_obj
                  [
                    ("type", Jsont.Json.string "array");
                    ("items", string_schema);
                  ] );
            ] );
        ("required", json_list [ Jsont.Json.string "runs" ]);
        ("additionalProperties", Jsont.Json.bool false);
      ]

  let tool =
    Spice_llm.Tool.make ~name ~description:Spice_prompts.Tools.wait_subagents
      ~input_schema:tool_schema ()

  let decode call = decode_for name Request.jsont call
end

module Cancel = struct
  module Request = struct
    type t = { run : Spice_session.Id.t }

    let make ~run = { run }
    let run t = t.run
    let equal a b = a = b

    let pp ppf t =
      Format.fprintf ppf "@[<hov>{ run = %a }@]" Spice_session.Id.pp t.run

    let jsont =
      Jsont.Object.map ~kind:"subagent cancel" (fun run -> make ~run)
      |> Jsont.Object.mem "run" Spice_session.Id.jsont ~enc:run
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
  end

  let name = "cancel_subagent"

  let tool_schema =
    json_obj
      [
        ("type", Jsont.Json.string "object");
        ("properties", json_obj [ ("run", string_schema) ]);
        ("required", json_list [ Jsont.Json.string "run" ]);
        ("additionalProperties", Jsont.Json.bool false);
      ]

  let tool =
    Spice_llm.Tool.make ~name ~description:Spice_prompts.Tools.cancel_subagent
      ~input_schema:tool_schema ()

  let decode call = decode_for name Request.jsont call
end

module Message = struct
  module Request = struct
    type t = { run : Spice_session.Id.t; message : string }

    let make ~run ~message =
      let* () =
        check_non_empty "subagent message must not be empty" message
      in
      Ok { run; message }

    let run t = t.run
    let message t = t.message
    let equal a b = a = b

    let pp ppf t =
      Format.fprintf ppf "@[<hov>{ run = %a; message = %S }@]"
        Spice_session.Id.pp t.run t.message

    let jsont =
      Jsont.Object.map ~kind:"subagent message" (fun run message ->
          Decode.or_error (make ~run ~message))
      |> Jsont.Object.mem "run" Spice_session.Id.jsont ~enc:run
      |> Jsont.Object.mem "message" Jsont.string ~enc:message
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
  end

  let name = "message_subagent"

  let tool_schema =
    json_obj
      [
        ("type", Jsont.Json.string "object");
        ( "properties",
          json_obj [ ("run", string_schema); ("message", string_schema) ] );
        ( "required",
          json_list [ Jsont.Json.string "run"; Jsont.Json.string "message" ] );
        ("additionalProperties", Jsont.Json.bool false);
      ]

  let tool =
    Spice_llm.Tool.make ~name
      ~description:Spice_prompts.Tools.message_subagent
      ~input_schema:tool_schema ()

  let decode call = decode_for name Request.jsont call
end

module Message_parent = struct
  module Request = struct
    type t = { message : string }

    let make ~message =
      let* () =
        check_non_empty "parent message must not be empty" message
      in
      Ok { message }

    let message t = t.message
    let equal a b = a = b

    let pp ppf t =
      Format.fprintf ppf "@[<hov>{ message = %S }@]" t.message

    let jsont =
      Jsont.Object.map ~kind:"parent message" (fun message ->
          Decode.or_error (make ~message))
      |> Jsont.Object.mem "message" Jsont.string ~enc:message
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
  end

  let name = "message_parent"

  let tool_schema =
    json_obj
      [
        ("type", Jsont.Json.string "object");
        ("properties", json_obj [ ("message", string_schema) ]);
        ("required", json_list [ Jsont.Json.string "message" ]);
        ("additionalProperties", Jsont.Json.bool false);
      ]

  let tool =
    Spice_llm.Tool.make ~name
      ~description:Spice_prompts.Tools.message_parent
      ~input_schema:tool_schema ()

  let decode call = decode_for name Request.jsont call
end

let name = "spawn_subagent"

let tool_schema =
  json_obj
    [
      ("type", Jsont.Json.string "object");
      ( "properties",
        json_obj
          [
            ( "role",
              json_obj
                [
                  ("type", Jsont.Json.string "string");
                  ( "enum",
                    json_list
                      [
                        Jsont.Json.string "explore";
                        Jsont.Json.string "review";
                        Jsont.Json.string "verify";
                      ] );
                ] );
            ("task", json_obj [ ("type", Jsont.Json.string "string") ]);
            ( "scope",
              json_obj
                [
                  ("type", Jsont.Json.string "array");
                  ("items", json_obj [ ("type", Jsont.Json.string "string") ]);
                ] );
            ( "expected_output",
              json_obj [ ("type", Jsont.Json.string "string") ] );
          ] );
      ( "required",
        json_list [ Jsont.Json.string "role"; Jsont.Json.string "task" ] );
      ("additionalProperties", Jsont.Json.bool false);
    ]

let tool =
  Spice_llm.Tool.make ~name ~description:Spice_prompts.Tools.spawn_subagent
    ~input_schema:tool_schema ()

let decode call = decode_for name Spawn.jsont call
