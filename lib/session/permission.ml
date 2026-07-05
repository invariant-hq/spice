(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_session.Permission" fn message

module Access = Spice_permission.Access
module Review = Spice_permission.Policy.Review
module Request = Spice_permission.Request

module Id =
  String_id.Make
    (struct
      let module_path = "Spice_session.Permission.Id"
      let kind = "permission prompt id"
    end)
    ()

let access_set_jsont =
  Jsont.map ~kind:"permission access set"
    ~dec:(fun accesses ->
      List.fold_left
        (fun set access -> Access.Set.add access set)
        Access.Set.empty accesses)
    ~enc:Access.Set.elements (Jsont.list Access.jsont)

module Requested = struct
  type t = {
    id : Id.t;
    turn : Turn.Id.t;
    tool_call : Spice_llm.Tool.Call.t;
    request : Request.t;
    asked : Access.Set.t;
  }

  let check_asked request asked =
    if Access.Set.is_empty asked then
      invalid "Requested.make" "asked accesses must not be empty";
    match Review.restore request asked with
    | Ok _ -> ()
    | Error Review.Empty_accesses ->
        invalid "Requested.make" "asked accesses must not be empty"
    | Error (Review.Access_not_in_request _) ->
        invalid "Requested.make" "asked accesses must belong to request"

  let make ~id ~turn ~tool_call ~request ~asked () =
    check_asked request asked;
    { id; turn; tool_call; request; asked }

  let of_review ~id ~turn ~tool_call review =
    let request = Review.request review in
    let asked = Review.access_set review in
    make ~id ~turn ~tool_call ~request ~asked ()

  let id t = t.id
  let turn t = t.turn
  let tool_call t = t.tool_call
  let request t = t.request
  let asked t = t.asked

  let review t =
    match Review.restore t.request t.asked with
    | Ok review -> review
    | Error Review.Empty_accesses ->
        invalid "Requested.review" "asked accesses must not be empty"
    | Error (Review.Access_not_in_request _) ->
        invalid "Requested.review" "asked accesses must belong to request"

  let equal a b =
    Id.equal a.id b.id
    && Turn.Id.equal a.turn b.turn
    && Spice_llm.Tool.Call.equal a.tool_call b.tool_call
    && Request.equal a.request b.request
    && Access.Set.equal a.asked b.asked

  let pp_accesses ppf accesses =
    Format.pp_print_list
      ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
      Access.pp ppf
      (Access.Set.elements accesses)

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ id = %a; turn = %a; tool_call = %s; request = %a; asked = [%a] \
       }@]"
      Id.pp t.id Turn.Id.pp t.turn
      (Spice_llm.Tool.Call.id t.tool_call)
      Request.pp t.request pp_accesses t.asked

  let jsont =
    let make id turn tool_call request asked =
      decode_invalid_arg (fun () ->
          make ~id ~turn ~tool_call ~request ~asked ())
    in
    Jsont.Object.map ~kind:"session permission request" make
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.mem "turn" Turn.Id.jsont ~enc:turn
    |> Jsont.Object.mem "tool_call" Spice_llm.Tool.Call.jsont ~enc:tool_call
    |> Jsont.Object.mem "request" Request.jsont ~enc:request
    |> Jsont.Object.mem "asked" access_set_jsont ~enc:asked
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Resolved = struct
  type via = [ `Reviewer | `Unattended ]
  type decision = Allow of Review.scope | Deny of Spice_llm.Tool.Result.t
  type t = { id : Id.t; decision : decision; via : via }

  let allow_once ~id = { id; decision = Allow Review.Once; via = `Reviewer }

  let allow_session ~id =
    { id; decision = Allow Review.Session; via = `Reviewer }

  let deny ~id ?(via = `Reviewer) result = { id; decision = Deny result; via }
  let id t = t.id
  let decision t = t.decision
  let via t = t.via
  let equal a b = Id.equal a.id b.id && a.decision = b.decision && a.via = b.via

  (* The wire form keeps the [answer] string and optional [tool_result] of the
     original two-eliminator encoding; these project the [decision] sum back
     onto that shape. *)
  let answer t =
    match t.decision with
    | Allow scope -> Review.Allow scope
    | Deny _ -> Review.Deny

  let denial_result t =
    match t.decision with Deny result -> Some result | Allow _ -> None

  let pp ppf t =
    let answer_string =
      match t.decision with
      | Allow Review.Once -> "allow-once"
      | Allow Review.Session -> "allow-session"
      | Deny _ -> "deny"
    in
    Format.fprintf ppf "@[<hov>{ id = %a; answer = %s%s }@]" Id.pp t.id
      answer_string
      (match t.via with `Reviewer -> "" | `Unattended -> "; via = unattended")

  let via_jsont =
    Jsont.enum ~kind:"permission resolution provenance"
      [ ("reviewer", `Reviewer); ("unattended", `Unattended) ]

  let answer_jsont =
    let dec = function
      | "allow-once" -> Ok (Review.Allow Review.Once)
      | "allow-session" -> Ok (Review.Allow Review.Session)
      | "deny" -> Ok Review.Deny
      | other ->
          Error
            (Printf.sprintf
               "unknown permission answer %S: expected allow-once, \
                allow-session, deny"
               other)
    in
    let enc = function
      | Review.Allow Review.Once -> Ok "allow-once"
      | Review.Allow Review.Session -> Ok "allow-session"
      | Review.Deny -> Ok "deny"
    in
    Jsont.Base.string
      (Jsont.Base.map ~kind:"permission answer"
         ~dec:(Jsont.Base.dec_result dec)
         ~enc:(Jsont.Base.enc_result enc)
         ())

  let of_json id answer result via =
    decode_invalid_arg (fun () ->
        match (answer, result) with
        | Review.Allow Review.Once, None | Review.Allow Review.Session, None
          -> (
            if via = Some `Unattended then
              invalid "Resolved.jsont"
                "unattended provenance applies only to denials";
            match answer with
            | Review.Allow Review.Once -> allow_once ~id
            | Review.Allow Review.Session -> allow_session ~id
            | Review.Deny -> assert false)
        | Review.Deny, Some result -> deny ~id ?via result
        | Review.Deny, None ->
            invalid "Resolved.jsont"
              "denied permission answer must include tool_result"
        | (Review.Allow Review.Once | Review.Allow Review.Session), Some _ ->
            invalid "Resolved.jsont"
              "allowed permission answer must not include tool_result")

  let jsont =
    Jsont.Object.map ~kind:"session permission answer" of_json
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.mem "answer" answer_jsont ~enc:answer
    |> Jsont.Object.opt_mem "tool_result" Spice_llm.Tool.Result.jsont
         ~enc:denial_result
    |> Jsont.Object.opt_mem "via" via_jsont ~enc:(fun t ->
        match via t with `Unattended -> Some `Unattended | `Reviewer -> None)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let matches request resolution =
  Id.equal (Requested.id request) (Resolved.id resolution)
