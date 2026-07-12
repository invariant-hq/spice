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

let review_reason_jsont =
  let make kind rule =
    match (kind, rule) with
    | "unmatched", None -> Review.Unmatched
    | "rule", Some rule -> Review.By_rule rule
    | "unmatched", Some _ ->
        decode_error "unmatched permission review reason must not carry a rule"
    | "rule", None ->
        decode_error "rule permission review reason requires a rule"
    | kind, _ -> decode_error ("unknown permission review reason: " ^ kind)
  in
  let kind = function
    | Review.Unmatched -> "unmatched"
    | Review.By_rule _ -> "rule"
  in
  let rule = function
    | Review.Unmatched -> None
    | Review.By_rule rule -> Some rule
  in
  Jsont.Object.map ~kind:"permission review reason" make
  |> Jsont.Object.mem "kind" Jsont.string ~enc:kind
  |> Jsont.Object.opt_mem "rule" Spice_permission.Policy.Rule.jsont ~enc:rule
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let reviewed_jsont =
  Jsont.Object.map ~kind:"reviewed permission access" (fun access reason ->
      (access, reason))
  |> Jsont.Object.mem "access" Access.jsont ~enc:fst
  |> Jsont.Object.mem "reason" review_reason_jsont ~enc:snd
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

module Requested = struct
  type t = {
    id : Id.t;
    turn : Turn.Id.t;
    tool_call : Spice_llm.Tool.Call.t;
    request : Request.t;
    reasons : (Access.t * Review.reason) list;
  }

  let check_reasons request reasons =
    match Review.restore request reasons with
    | Ok _ -> ()
    | Error Review.Empty_accesses ->
        invalid "Requested.make" "review reasons must not be empty"
    | Error (Review.Access_not_in_request _) ->
        invalid "Requested.make" "review accesses must belong to request"

  let make ~id ~turn ~tool_call ~request ~reasons () =
    check_reasons request reasons;
    { id; turn; tool_call; request; reasons }

  let of_review ~id ~turn ~tool_call review =
    let request = Review.request review in
    let reasons = Review.reasons review in
    make ~id ~turn ~tool_call ~request ~reasons ()

  let id t = t.id
  let turn t = t.turn
  let tool_call t = t.tool_call
  let request t = t.request
  let reasons t = t.reasons

  let review t =
    match Review.restore t.request t.reasons with
    | Ok review -> review
    | Error Review.Empty_accesses ->
        invalid "Requested.review" "review reasons must not be empty"
    | Error (Review.Access_not_in_request _) ->
        invalid "Requested.review" "review accesses must belong to request"

  let equal_reason a b =
    match (a, b) with
    | Review.Unmatched, Review.Unmatched -> true
    | Review.By_rule a, Review.By_rule b ->
        Spice_permission.Policy.Rule.equal a b
    | Review.Unmatched, Review.By_rule _ | Review.By_rule _, Review.Unmatched ->
        false

  let equal a b =
    Id.equal a.id b.id
    && Turn.Id.equal a.turn b.turn
    && Spice_llm.Tool.Call.equal a.tool_call b.tool_call
    && Request.equal a.request b.request
    && List.equal
         (fun (a_access, a_reason) (b_access, b_reason) ->
           Access.equal a_access b_access && equal_reason a_reason b_reason)
         a.reasons b.reasons

  let pp_reasons ppf reasons =
    Format.pp_print_list
      ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
      (fun ppf (access, reason) ->
        match reason with
        | Review.Unmatched -> Format.fprintf ppf "%a:unmatched" Access.pp access
        | Review.By_rule rule ->
            Format.fprintf ppf "%a:rule(%a)" Access.pp access
              Spice_permission.Policy.Rule.pp rule)
      ppf reasons

  let pp ppf t =
    Format.fprintf ppf
      "@[<hov>{ id = %a; turn = %a; tool_call = %s; request = %a; reasons = [%a] \
       }@]"
      Id.pp t.id Turn.Id.pp t.turn
      (Spice_llm.Tool.Call.id t.tool_call)
      Request.pp t.request pp_reasons t.reasons

  let jsont =
    let make id turn tool_call request reasons =
      decode_invalid_arg (fun () ->
          make ~id ~turn ~tool_call ~request ~reasons ())
    in
    Jsont.Object.map ~kind:"session permission request" make
    |> Jsont.Object.mem "id" Id.jsont ~enc:id
    |> Jsont.Object.mem "turn" Turn.Id.jsont ~enc:turn
    |> Jsont.Object.mem "tool_call" Spice_llm.Tool.Call.jsont ~enc:tool_call
    |> Jsont.Object.mem "request" Request.jsont ~enc:request
    |> Jsont.Object.mem "reasons" Jsont.(list reviewed_jsont) ~enc:reasons
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Resolved = struct
  type via = [ `Reviewer | `Unattended ]
  type allowance = Once | Session
  type answer = Allow of allowance | Deny
  type decision = Allowed of allowance | Denied of Spice_llm.Tool.Result.t
  type t = { id : Id.t; decision : decision; via : via }

  let allow_once ~id = { id; decision = Allowed Once; via = `Reviewer }

  let allow_session ~id =
    { id; decision = Allowed Session; via = `Reviewer }

  let deny ~id ?(via = `Reviewer) result =
    { id; decision = Denied result; via }
  let id t = t.id
  let decision t = t.decision
  let via t = t.via
  let equal a b = Id.equal a.id b.id && a.decision = b.decision && a.via = b.via

  (* The wire form keeps the [answer] string and optional [tool_result] of the
     original two-eliminator encoding; these project the [decision] sum back
     onto that shape. *)
  let answer t =
    match t.decision with
    | Allowed allowance -> Allow allowance
    | Denied _ -> Deny

  let denial_result t =
    match t.decision with Denied result -> Some result | Allowed _ -> None

  let pp ppf t =
    let answer_string =
      match t.decision with
      | Allowed Once -> "allow-once"
      | Allowed Session -> "allow-session"
      | Denied _ -> "deny"
    in
    Format.fprintf ppf "@[<hov>{ id = %a; answer = %s%s }@]" Id.pp t.id
      answer_string
      (match t.via with `Reviewer -> "" | `Unattended -> "; via = unattended")

  let via_jsont =
    Jsont.enum ~kind:"permission resolution provenance"
      [ ("reviewer", `Reviewer); ("unattended", `Unattended) ]

  let answer_jsont =
    let dec = function
      | "allow-once" -> Ok (Allow Once)
      | "allow-session" -> Ok (Allow Session)
      | "deny" -> Ok Deny
      | other ->
          Error
            (Printf.sprintf
               "unknown permission answer %S: expected allow-once, \
                allow-session, deny"
               other)
    in
    let enc = function
      | Allow Once -> Ok "allow-once"
      | Allow Session -> Ok "allow-session"
      | Deny -> Ok "deny"
    in
    Jsont.Base.string
      (Jsont.Base.map ~kind:"permission answer"
         ~dec:(Jsont.Base.dec_result dec)
         ~enc:(Jsont.Base.enc_result enc)
         ())

  let of_json id answer result via =
    decode_invalid_arg (fun () ->
        match (answer, result) with
        | Allow Once, None | Allow Session, None -> (
            if via = Some `Unattended then
              invalid "Resolved.jsont"
                "unattended provenance applies only to denials";
            match answer with
            | Allow Once -> allow_once ~id
            | Allow Session -> allow_session ~id
            | Deny -> assert false)
        | Deny, Some result -> deny ~id ?via result
        | Deny, None ->
            invalid "Resolved.jsont"
              "denied permission answer must include tool_result"
        | (Allow Once | Allow Session), Some _ ->
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
