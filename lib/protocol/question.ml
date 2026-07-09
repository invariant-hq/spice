(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let json_obj fields =
  Jsont.Json.object'
    (List.map
       (fun (name, value) -> Jsont.Json.mem (Jsont.Json.name name) value)
       fields)

let json_list values = Jsont.Json.list values

let non_empty_string_schema =
  json_obj
    [
      ("type", Jsont.Json.string "string"); ("minLength", Jsont.Json.int 1);
    ]

module Option = struct
  type t = { label : string; description : string option }

  let make ~label ?description () =
    if String.is_empty label then Error "option label must not be empty"
    else
      match description with
      | Some d when String.is_empty d ->
          Error "option description must not be empty when present"
      | _ -> Ok { label; description }

  let label t = t.label
  let description t = t.description
  let equal a b = a = b

  let pp ppf t =
    Format.fprintf ppf "{ label = %S; description = %a }" t.label
      (Format.pp_print_option Format.pp_print_string)
      t.description

  let jsont =
    Jsont.Object.map ~kind:"question option" (fun label description ->
        Decode.or_error (make ~label ?description ()))
    |> Jsont.Object.mem "label" Jsont.string ~enc:label
    |> Jsont.Object.opt_mem "description" Jsont.string ~enc:description
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Request = struct
  type t = {
    header : string option;
    question : string;
    options : Option.t list;
    multi : bool;
  }

  let make ?header ~question ?(options = []) ?(multi = false) () =
    if String.is_empty question then Error "question must not be empty"
    else
      match header with
      | Some h when String.is_empty h ->
          Error "question header must not be empty when present"
      | _ -> Ok { header; question; options; multi }

  let header t = t.header
  let question t = t.question
  let options t = t.options
  let multi t = t.multi
  let equal a b = a = b

  let pp ppf t =
    Format.fprintf ppf
      "{ header = %a; question = %S; options = [%a]; multi = %b }"
      (Format.pp_print_option Format.pp_print_string)
      t.header t.question
      (Format.pp_print_list
         ~pp_sep:(fun ppf () -> Format.fprintf ppf "; ")
         Option.pp)
      t.options t.multi

  (* [options]/[multi] are absent-tolerant: a bare [{ question }] call decodes to
     the free-text question every [ask_user] was before options landed. *)
  let jsont =
    Jsont.Object.map ~kind:"question request"
      (fun header question options multi ->
        Decode.or_error
          (make ?header ~question
             ~options:(Stdlib.Option.value ~default:[] options)
             ~multi ()))
    |> Jsont.Object.opt_mem "header" Jsont.string ~enc:header
    |> Jsont.Object.mem "question" Jsont.string ~enc:question
    |> Jsont.Object.opt_mem "options" (Jsont.list Option.jsont) ~enc:(fun t ->
        match t.options with [] -> None | options -> Some options)
    |> Jsont.Object.mem "multi" Jsont.bool ~dec_absent:false
         ~enc_omit:(fun multi -> not multi)
         ~enc:multi
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let name = "ask_user"

(* The option/header/multi fields are optional in the model-facing schema: a
   question can still be a bare free-text ask. A malformed structured payload
   fails [decode] and, through [Call.classify], parks as an answerable
   [Call.Invalid] rather than wedging the turn. *)
let tool_schema =
  json_obj
    [
      ("type", Jsont.Json.string "object");
      ( "properties",
        json_obj
          [
            ("header", non_empty_string_schema);
            ("question", non_empty_string_schema);
            ( "options",
              json_obj
                [
                  ("type", Jsont.Json.string "array");
                  ( "items",
                    json_obj
                      [
                        ("type", Jsont.Json.string "object");
                        ( "properties",
                          json_obj
                            [
                              ( "label",
                                non_empty_string_schema );
                              ( "description",
                                non_empty_string_schema );
                            ] );
                        ("required", json_list [ Jsont.Json.string "label" ]);
                        ("additionalProperties", Jsont.Json.bool false);
                      ] );
                ] );
            ("multi", json_obj [ ("type", Jsont.Json.string "boolean") ]);
          ] );
      ("required", json_list [ Jsont.Json.string "question" ]);
      ("additionalProperties", Jsont.Json.bool false);
    ]

let tool =
  Spice_llm.Tool.make ~name ~description:Spice_prompts.Tools.ask_user
    ~input_schema:tool_schema ()

let decode call =
  let actual = Spice_llm.Tool.Call.name call in
  if not (String.equal actual name) then
    Error ("expected " ^ name ^ " call, got " ^ actual)
  else Jsont.Json.decode Request.jsont (Spice_llm.Tool.Call.input call)

let answer_text text =
  if String.is_empty text then Error "answer must not be empty"
  else Ok ("User answered: " ^ text)
