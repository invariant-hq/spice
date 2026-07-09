(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims
module Login = Spice_provider.Auth.Login
module Protocol = Spice_provider.Auth.Login.Protocol
module Source = Spice_account.Credential.Source

(* {1 Types} *)

type provider_entry = {
  provider : Spice_llm.Provider.t;
  display_name : string;
  logins : Login.t list;
  env : string list;
  phase : Spice_account.phase;
  source : Source.t option;
  fingerprint : string option;
}

type mode = Login | Logout

type challenge =
  | Browser_url of Uri.t
  | Device_challenge of { url : Uri.t; user_code : string; expires_in : int }

type outcome =
  | Signed_in
  | Saved_blocked
  | Saved_unchecked of string
  | Removed
  | Env_active of string
  | Failed of string

type record = {
  provider_title : string;
  outcome : outcome;
  acct_fingerprint : string option;
  source_word : string option;
}

(* The protocol surface a login method routes to; a provider-specific device
   flow (OpenAI's ChatGPT device code) shares the device-code panel with the
   standard OAuth device flow. *)
type method_kind = Api_key_kind | Browser_kind | Device_kind | External_kind

let method_kind login =
  match Login.protocol login with
  | Protocol.Api_key -> Api_key_kind
  | Protocol.OAuth2_authorization_code _ -> Browser_kind
  | Protocol.OAuth2_device_code _ | Protocol.Provider_device_code _ ->
      Device_kind
  | Protocol.External _ -> External_kind

type pick = { query : string; selected : int }

(* A browser / device-code waiting panel. [request] is stamped by the shell
   after the flow starts ({!started}); [elapsed] counts up and, for the device
   code, [remaining] counts down, both driven by the flow tick so the spinner is
   the only animated cell and the copyable url/code rows stay static. Only
   display-safe challenge fields live here. *)
type flow_panel = {
  fp_entry : provider_entry;
  fp_request : int option;
  fp_url : Uri.t option;
  fp_user_code : string option;
  fp_elapsed : int;
  fp_remaining : int option;
  fp_opened : bool;
  fp_open_failed : bool;
  fp_copied : bool;
}

type api_key_state = {
  ak_entry : provider_entry;
  ak_login : Login.t;
  ak_buffer : string;
  ak_flash : string option;
}

(* An external method's instruction card: Spice cannot drive the flow, so it
   shows the provider's declared instructions and offers to copy them. *)
type external_state = {
  ext_entry : provider_entry;
  ext_label : string;
  ext_instructions : string;
  ext_copied : bool;
}

type stage =
  | Loading
  | Load_error of string
  | Provider_pick of pick
  | Logout_empty
  | Method_pick of { entry : provider_entry; pick : pick }
  | Api_key of api_key_state
  | Browser of flow_panel
  | Device of flow_panel
  | External of external_state
  | Working of { entry : provider_entry; request : int option; label : string }

type t = {
  mode : mode;
  requested : string option;
  entries : provider_entry list;
  stage : stage;
}

type msg = Key of Panel.key

type event =
  | Stay
  | Close
  | Begin_api_key of {
      provider : Spice_llm.Provider.t;
      method_id : string;
      key : string;
    }
  | Begin_browser of { provider : Spice_llm.Provider.t; method_id : string }
  | Begin_device of { provider : Spice_llm.Provider.t; method_id : string }
  | Begin_logout of { provider : Spice_llm.Provider.t }
  | Cancel of { request : int }
  | Copy of string
  | Open_url of Uri.t
  | Reload
  | Flash of string

let loading ~mode ?provider () =
  { mode; requested = provider; entries = []; stage = Loading }

let empty_pick = { query = ""; selected = 0 }

let fresh_panel entry =
  {
    fp_entry = entry;
    fp_request = None;
    fp_url = None;
    fp_user_code = None;
    fp_elapsed = 0;
    fp_remaining = None;
    fp_opened = false;
    fp_open_failed = false;
    fp_copied = false;
  }

(* {1 Sorting and filtering} *)

let requires_auth entry =
  not (List.is_empty entry.logins && List.is_empty entry.env)

let connected entry =
  requires_auth entry && match entry.phase with `Missing -> false | _ -> true

let entry_rank entry =
  if not (requires_auth entry) then 3
  else
    match entry.source with
    | Some (Source.Store _) -> 0
    | Some (Source.Process | Source.Env _) -> 1
    | None -> 2

let sort_login entries =
  List.stable_sort
    (fun a b -> Int.compare (entry_rank a) (entry_rank b))
    entries

let connected_entries entries = List.filter connected entries

let contains ~needle haystack =
  let needle = String.lowercase_ascii needle in
  let haystack = String.lowercase_ascii haystack in
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.equal (String.sub haystack i nl) needle then true
      else loop (i + 1)
    in
    loop 0

let entry_matches ~query entry =
  let query = String.trim query in
  String.equal query ""
  || contains ~needle:query entry.display_name
  || contains ~needle:query (Spice_llm.Provider.id entry.provider)

let base_entries t =
  match t.mode with
  | Login -> sort_login t.entries
  | Logout -> connected_entries t.entries

let pick_entries t pick =
  List.filter (entry_matches ~query:pick.query) (base_entries t)

let method_matches ~query login =
  let query = String.trim query in
  String.equal query "" || contains ~needle:query (Login.label login)

let method_entries entry pick =
  List.filter (method_matches ~query:pick.query) entry.logins

(* {1 Confirm — provider / method selection} *)

let enter_api_key entry login t =
  ( {
      t with
      stage =
        Api_key
          {
            ak_entry = entry;
            ak_login = login;
            ak_buffer = "";
            ak_flash = None;
          };
    },
    Stay )

let confirm_method entry login t =
  let method_id = Login.id login in
  match method_kind login with
  | Api_key_kind -> enter_api_key entry login t
  | Browser_kind ->
      ( { t with stage = Browser (fresh_panel entry) },
        Begin_browser { provider = entry.provider; method_id } )
  | Device_kind ->
      ( { t with stage = Device (fresh_panel entry) },
        Begin_device { provider = entry.provider; method_id } )
  | External_kind -> (
      match Login.protocol login with
      | Protocol.External { instructions = Some instructions } ->
          ( {
              t with
              stage =
                External
                  {
                    ext_entry = entry;
                    ext_label = Login.label login;
                    ext_instructions = instructions;
                    ext_copied = false;
                  };
            },
            Stay )
      | _ -> (t, Flash "this method is completed outside Spice"))

(* Route a chosen provider to its next surface: the method picker when it
   declares more than one method, else straight to the sole method's protocol
   (the head of the declaration list). *)
let confirm_provider entry t =
  if not (requires_auth entry) then
    (t, Flash (entry.display_name ^ " runs locally and needs no login"))
  else
    match entry.logins with
    | [] -> (t, Flash (entry.display_name ^ " declares no login methods"))
    | [ login ] -> confirm_method entry login t
    | _ :: _ ->
        ({ t with stage = Method_pick { entry; pick = empty_pick } }, Stay)

let begin_logout entry t =
  ( {
      t with
      stage = Working { entry; request = None; label = "removing credential…" };
    },
    Begin_logout { provider = entry.provider } )

(* {1 Post-load transition} *)

let on_providers_loaded entries t =
  let t = { t with entries } in
  match t.mode with
  | Login -> (
      match t.requested with
      | Some id -> (
          match
            List.find_opt
              (fun e -> String.equal (Spice_llm.Provider.id e.provider) id)
              entries
          with
          | Some entry -> confirm_provider entry t
          | None -> ({ t with stage = Provider_pick empty_pick }, Stay))
      | None -> ({ t with stage = Provider_pick empty_pick }, Stay))
  | Logout -> (
      let connected = connected_entries entries in
      match (t.requested, connected) with
      | Some id, _ -> (
          match
            List.find_opt
              (fun e -> String.equal (Spice_llm.Provider.id e.provider) id)
              connected
          with
          | Some entry -> begin_logout entry t
          | None ->
              ({ t with stage = Logout_empty }, Flash (id ^ " is not connected"))
          )
      | None, [] -> ({ t with stage = Logout_empty }, Close)
      | None, [ entry ] -> begin_logout entry t
      | None, _ -> ({ t with stage = Provider_pick empty_pick }, Stay))

let providers_loaded result t =
  match result with
  | Error message -> ({ t with stage = Load_error message }, Stay)
  | Ok entries -> on_providers_loaded entries t

(* {1 Navigation} *)

let clamp count selected = selected |> max 0 |> min (max 0 (count - 1))

let apply_offset ~wrap count selected offset =
  if count = 0 then 0
  else if wrap then (((selected + offset) mod count) + count) mod count
  else clamp count (selected + offset)

let nav_provider offset ~wrap t pick =
  let count = List.length (pick_entries t pick) in
  let selected = apply_offset ~wrap count pick.selected offset in
  { t with stage = Provider_pick { pick with selected } }

let nav_method offset ~wrap t entry pick =
  let count = List.length (method_entries entry pick) in
  let selected = apply_offset ~wrap count pick.selected offset in
  { t with stage = Method_pick { entry; pick = { pick with selected } } }

let move offset ~wrap t =
  match t.stage with
  | Provider_pick pick -> nav_provider offset ~wrap t pick
  | Method_pick { entry; pick } -> nav_method offset ~wrap t entry pick
  | _ -> t

let with_query query t =
  match t.stage with
  | Provider_pick _ -> { t with stage = Provider_pick { query; selected = 0 } }
  | Method_pick { entry; _ } ->
      { t with stage = Method_pick { entry; pick = { query; selected = 0 } } }
  | _ -> t

let query t =
  match t.stage with
  | Provider_pick pick -> pick.query
  | Method_pick { pick; _ } -> pick.query
  | _ -> ""

(* {1 Confirm (enter / tab)} *)

let confirm t =
  match t.stage with
  | Provider_pick pick -> (
      let entries = pick_entries t pick in
      match
        List.nth_opt entries (clamp (List.length entries) pick.selected)
      with
      | None -> (t, Stay)
      | Some entry -> (
          match t.mode with
          | Login -> confirm_provider entry t
          | Logout -> begin_logout entry t))
  | Method_pick { entry; pick } -> (
      let logins = method_entries entry pick in
      match List.nth_opt logins (clamp (List.length logins) pick.selected) with
      | None -> (t, Stay)
      | Some login -> confirm_method entry login t)
  | _ -> (t, Stay)

(* {1 Api-key masked input} *)

(* Drop one UTF-8 scalar, not one byte, so multi-byte input erases as one
   keypress. *)
let drop_last_scalar buffer =
  let len = String.length buffer in
  if len = 0 then buffer
  else
    let rec start i =
      if i <= 0 then 0
      else if Char.code buffer.[i] land 0xC0 = 0x80 then start (i - 1)
      else i
    in
    String.sub buffer 0 (start (len - 1))

let api_key_append text state =
  { state with ak_buffer = state.ak_buffer ^ text; ak_flash = None }

let strip_newlines text =
  String.to_seq text
  |> Seq.filter (fun c -> not (Char.equal c '\n' || Char.equal c '\r'))
  |> String.of_seq

let submit_api_key entry login state t =
  if String.equal (String.trim state.ak_buffer) "" then
    ( { t with stage = Api_key { state with ak_flash = Some "enter a key" } },
      Stay )
  else
    ( { t with stage = Working { entry; request = None; label = "saving key…" } },
      Begin_api_key
        {
          provider = entry.provider;
          method_id = Login.id login;
          key = state.ak_buffer;
        } )

(* {1 Esc ladder} *)

let back_to_provider t = { t with stage = Provider_pick empty_pick }

(* From a protocol surface, esc returns to the method picker when the provider
   had one, else the provider picker; from the method picker, to the provider
   picker; from the provider picker, esc closes the whole flow. *)
let back_from_protocol entry t =
  if List.length entry.logins > 1 then
    { t with stage = Method_pick { entry; pick = empty_pick } }
  else back_to_provider t

let back t =
  match t.stage with
  | Loading | Load_error _ | Logout_empty | Provider_pick _ -> (t, Close)
  | Method_pick _ -> (back_to_provider t, Stay)
  | Api_key { ak_entry; _ } -> (back_from_protocol ak_entry t, Stay)
  | External { ext_entry; _ } -> (back_from_protocol ext_entry t, Stay)
  (* The host call behind a working line is synchronous and cannot be
     cancelled; esc stops watching instead of wedging the panel, and the
     request guard drops the settle that lands after the close. *)
  | Working _ -> (t, Close)
  | Browser panel | Device panel -> (
      let t = back_from_protocol panel.fp_entry t in
      match panel.fp_request with
      | Some request -> (t, Cancel { request })
      | None -> (t, Stay))

(* {1 Update} *)

let key ev =
  match Panel.classify ev with
  | Panel.Action Panel.Other -> None
  | k -> Some (Key k)

let flow_copy_target (stage : stage) =
  match stage with
  | Device panel -> panel.fp_user_code
  | Browser panel -> Option.map (fun u -> Uri.to_string u) panel.fp_url
  | _ -> None

let update (Key k) t =
  match t.stage with
  | Api_key state -> (
      match k with
      | Panel.Action Panel.Escape -> back t
      | Panel.Action Panel.Enter ->
          submit_api_key state.ak_entry state.ak_login state t
      | Panel.Action Panel.Backspace ->
          ( {
              t with
              stage =
                Api_key
                  {
                    state with
                    ak_buffer = drop_last_scalar state.ak_buffer;
                    ak_flash = None;
                  };
            },
            Stay )
      | Panel.Printable s ->
          ({ t with stage = Api_key (api_key_append s state) }, Stay)
      | Panel.Digit d ->
          ( { t with stage = Api_key (api_key_append (string_of_int d) state) },
            Stay )
      | Panel.Action
          ( Panel.Tab | Panel.Left | Panel.Right | Panel.Up | Panel.Down
          | Panel.Ctrl_d | Panel.Other ) ->
          (t, Stay))
  | Browser _ | Device _ -> (
      match k with
      | Panel.Action Panel.Escape -> back t
      | Panel.Printable "c" -> (
          match flow_copy_target t.stage with
          | Some s ->
              ( {
                  t with
                  stage =
                    (match t.stage with
                    | Browser p -> Browser { p with fp_copied = true }
                    | Device p -> Device { p with fp_copied = true }
                    | s -> s);
                },
                Copy s )
          | None -> (t, Stay))
      | Panel.Action Panel.Enter -> (
          (* The browser flow's explicit open (09-auth §6), also re-opening a
             closed window; device-code has no open (the browser is on another
             device). *)
          match t.stage with
          | Browser { fp_url = Some url; _ } -> (t, Open_url url)
          | _ -> (t, Stay))
      | _ -> (t, Stay))
  | External state -> (
      match k with
      | Panel.Action Panel.Escape -> back t
      | Panel.Printable "c" ->
          ( { t with stage = External { state with ext_copied = true } },
            Copy state.ext_instructions )
      | _ -> (t, Stay))
  | Working _ -> (
      match k with Panel.Action Panel.Escape -> back t | _ -> (t, Stay))
  | Load_error _ -> (
      match k with
      | Panel.Action Panel.Escape -> (t, Close)
      | Panel.Action Panel.Enter -> ({ t with stage = Loading }, Reload)
      | _ -> (t, Stay))
  | Loading | Logout_empty -> (
      match k with Panel.Action Panel.Escape -> (t, Close) | _ -> (t, Stay))
  | Provider_pick _ | Method_pick _ -> (
      match k with
      | Panel.Action Panel.Escape -> back t
      | Panel.Action (Panel.Enter | Panel.Tab) -> confirm t
      | Panel.Action Panel.Up -> (move (-1) ~wrap:true t, Stay)
      | Panel.Action Panel.Down -> (move 1 ~wrap:true t, Stay)
      | Panel.Action Panel.Backspace ->
          (with_query (drop_last_scalar (query t)) t, Stay)
      | Panel.Printable s -> (with_query (query t ^ s) t, Stay)
      | Panel.Digit d ->
          if String.equal (query t) "" then
            (* Jump-pick the nth visible row, then confirm — a provider/method
               pick has no second field to spoil (unlike the model panel). *)
            let count =
              match t.stage with
              | Provider_pick pick -> List.length (pick_entries t pick)
              | Method_pick { entry; pick } ->
                  List.length (method_entries entry pick)
              | _ -> 0
            in
            if d >= 1 && d <= count then
              confirm
                (match t.stage with
                | Provider_pick pick ->
                    {
                      t with
                      stage = Provider_pick { pick with selected = d - 1 };
                    }
                | Method_pick { entry; pick } ->
                    {
                      t with
                      stage =
                        Method_pick
                          { entry; pick = { pick with selected = d - 1 } };
                    }
                | _ -> t)
            else (t, Stay)
          else (with_query (query t ^ string_of_int d) t, Stay)
      | Panel.Action (Panel.Left | Panel.Right | Panel.Ctrl_d | Panel.Other) ->
          (t, Stay))

(* {1 Async folds} *)

let started ~request t =
  let stamp panel = { panel with fp_request = Some request } in
  match t.stage with
  | Browser panel -> { t with stage = Browser (stamp panel) }
  | Device panel -> { t with stage = Device (stamp panel) }
  | Working w -> { t with stage = Working { w with request = Some request } }
  | _ -> t

let active_request t =
  match t.stage with
  | Browser panel | Device panel -> panel.fp_request
  | Working { request; _ } -> request
  | _ -> None

(* The shell's abort chord (ctrl+c) while a browser / device flow waits:
   cancel and step back exactly as esc does. [None] when no cancellable flow
   is in flight, so the chord keeps its quit meaning everywhere else. *)
let cancel_active t =
  match t.stage with
  | Browser { fp_request = Some _; _ } | Device { fp_request = Some _; _ } ->
      Some (back t)
  | _ -> None

let map_flow request f t =
  match t.stage with
  | Browser panel when panel.fp_request = Some request ->
      { t with stage = Browser (f panel) }
  | Device panel when panel.fp_request = Some request ->
      { t with stage = Device (f panel) }
  | _ -> t

let challenge ~request (c : challenge) t =
  match c with
  | Browser_url url ->
      map_flow request (fun p -> { p with fp_url = Some url }) t
  | Device_challenge { url; user_code; expires_in } ->
      map_flow request
        (fun p ->
          {
            p with
            fp_url = Some url;
            fp_user_code = Some user_code;
            fp_remaining = Some expires_in;
          })
        t

let browser_opened ~request t =
  map_flow request
    (fun p -> { p with fp_opened = true; fp_open_failed = false })
    t

let browser_open_failed ~request t =
  map_flow request (fun p -> { p with fp_open_failed = true }) t

let ticking t = match t.stage with Browser _ | Device _ -> true | _ -> false

let tick t =
  let bump p =
    {
      p with
      fp_elapsed = p.fp_elapsed + 1;
      fp_remaining = Option.map (fun r -> max 0 (r - 1)) p.fp_remaining;
    }
  in
  match t.stage with
  | Browser p -> { t with stage = Browser (bump p) }
  | Device p -> { t with stage = Device (bump p) }
  | _ -> t

let accepts_paste t = match t.stage with Api_key _ -> true | _ -> false

let paste text t =
  match t.stage with
  | Api_key state ->
      { t with stage = Api_key (api_key_append (strip_newlines text) state) }
  | _ -> t

(* {1 View} *)

let default_style = Ansi.Style.default
let hidden = { x = Overflow.Hidden; y = Overflow.Hidden }
let check = "✓"
let blank_row = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []

let pad_row nodes =
  box ~flex_shrink:0. ~flex_direction:Flex_direction.Row ~overflow:hidden
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    nodes

let line ?(style = default_style) s = pad_row [ seg style s ]
let muted_line s = line ~style:Theme.muted s
let faint_line s = line ~style:Theme.faint s
let bold_line s = line ~style:Theme.bold s

(* One picker row on the shared list anatomy: cursor, the label (accent
   selected, muted when non-selectable), a right-aligned muted detail, and an
   optional trailing outcome mark. *)
let list_row ~selected ~selectable ~label ~detail ~mark =
  let cursor =
    if selected then seg Theme.accent Theme.cursor else seg default_style "  "
  in
  let label_style =
    if not selectable then Theme.muted
    else if selected then Theme.accent
    else default_style
  in
  let detail_nodes =
    match detail with "" -> [] | d -> [ seg Theme.muted d ]
  in
  let mark_nodes =
    match mark with
    | None -> []
    | Some (glyph, style) -> [ seg style ("  " ^ glyph) ]
  in
  let background = if selected then Some Theme.color_hover_bg else None in
  box ?background ~flex_shrink:0. ~flex_direction:Flex_direction.Row
    ~overflow:hidden ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    ([ cursor; seg label_style label; box ~flex_grow:1. ~flex_shrink:1. [] ]
    @ detail_nodes @ mark_nodes)

let fingerprint_label = function None -> None | Some fp -> Some ("…" ^ fp)

let source_word = function
  | Some (Source.Store _) -> Some "store"
  | Some (Source.Env name) -> Some ("env " ^ name)
  | Some Source.Process -> Some "process"
  | None -> None

(* The detail column and trailing mark for a provider row, from the passive
   account facts. A stored credential reads as connected (trailing [✓]); a
   degraded/blocked one carries a [!] warning instead; an env credential is
   muted with no mark; a missing one reads "not connected". *)
let provider_detail (entry : provider_entry) =
  if not (requires_auth entry) then ("no login needed", None)
  else
    match entry.source with
    | Some (Source.Store _) -> (
        let facts =
          List.filter_map Fun.id
            [ fingerprint_label entry.fingerprint; source_word entry.source ]
        in
        let joined = String.concat Theme.separator facts in
        let with_phase word =
          if joined = "" then word else word ^ Theme.separator ^ joined
        in
        match entry.phase with
        | `Blocked ->
            (with_phase "blocked", Some (String.trim Theme.problem, Theme.error))
        | `Degraded ->
            ( with_phase "degraded",
              Some (String.trim Theme.problem, Theme.warning) )
        | `Missing | `Unchecked | `Ready -> (joined, Some (check, Theme.success))
        )
    | Some (Source.Env name) -> ("env " ^ name, None)
    | Some Source.Process -> ("process", None)
    | None -> ("not connected", None)

let method_description login =
  match method_kind login with
  | Api_key_kind -> "paste a key from the provider"
  | Browser_kind -> "open your browser to authorize"
  | Device_kind -> "enter a code on another device"
  | External_kind -> "completed outside Spice"

(* A centered window keeps the selection visible without the list growing
   unbounded (03-ia open question 1). *)
let window_limit rows = max 3 (min 8 (rows - 16))

let window ~limit ~selected ~count =
  if count <= limit then (0, count)
  else
    let start = selected - (limit / 2) in
    let start = max 0 (min start (count - limit)) in
    (start, limit)

let windowed ~rows ~selected rows_list =
  let count = List.length rows_list in
  let limit = window_limit rows in
  let start, length = window ~limit ~selected ~count in
  let visible =
    List.filteri (fun i _ -> i >= start && i < start + length) rows_list
  in
  let above =
    if start > 0 then [ muted_line ("↑ " ^ string_of_int start ^ " more") ]
    else []
  in
  let below =
    if start + length < count then
      [ muted_line ("↓ " ^ string_of_int (count - start - length) ^ " more") ]
    else []
  in
  above @ visible @ below

let provider_pick_content ~rows t pick =
  let entries = pick_entries t pick in
  let selected = clamp (List.length entries) pick.selected in
  let subtitle =
    match t.mode with
    | Login -> "Choose a provider to authenticate."
    | Logout -> "Choose a provider to disconnect."
  in
  let rows_list =
    match entries with
    | [] -> [ muted_line "  no matching providers" ]
    | _ ->
        List.mapi
          (fun i entry ->
            let detail, mark = provider_detail entry in
            list_row ~selected:(i = selected) ~selectable:(requires_auth entry)
              ~label:entry.display_name ~detail ~mark)
          entries
        |> windowed ~rows ~selected
  in
  muted_line subtitle :: blank_row :: rows_list

let method_pick_content ~rows entry pick =
  let logins = method_entries entry pick in
  let selected = clamp (List.length logins) pick.selected in
  let rows_list =
    match logins with
    | [] -> [ muted_line "  no matching methods" ]
    | _ ->
        List.mapi
          (fun i login ->
            list_row ~selected:(i = selected) ~selectable:true
              ~label:(Login.label login) ~detail:(method_description login)
              ~mark:None)
          logins
        |> windowed ~rows ~selected
  in
  bold_line ("Log in to " ^ entry.display_name)
  :: muted_line "Choose how to sign in."
  :: blank_row :: rows_list

(* The masked composer borrow (09-auth §5): every buffered scalar renders as one
   bullet; the buffer is never drawn as text. *)
let bullets buffer =
  let count = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr count) buffer;
  String.concat "" (List.init !count (fun _ -> "•"))

let rule_line width =
  line ~style:Theme.rule
    (String.concat "" (List.init (max 0 (width - 4)) (fun _ -> "─")))

let api_key_content ~width state =
  let env_note =
    match state.ak_entry.source with
    | Some (Source.Env var) ->
        [
          muted_line
            ("Detected " ^ var
           ^ " in the environment; saving a key here takes precedence.");
        ]
    | _ -> []
  in
  let input_line =
    line ~style:Theme.accent (Theme.cursor ^ bullets state.ak_buffer ^ "▌")
  in
  let hint_line =
    match state.ak_flash with
    | Some flash -> faint_line flash
    | None ->
        faint_line "enter save · esc back · paste works · your key is not shown"
  in
  [
    line ~style:Theme.accent
      ("Paste your " ^ state.ak_entry.display_name ^ " API key");
    muted_line "Stored locally in the auth store; never displayed again.";
  ]
  @ env_note
  @ [ blank_row; rule_line width; input_line; rule_line width; hint_line ]

let spinner_frame elapsed =
  let frames = Theme.spinner_frames in
  frames.(elapsed mod Array.length frames)

let waiting_row p =
  pad_row
    [
      seg Theme.running (spinner_frame p.fp_elapsed ^ " ");
      seg Theme.muted
        (Printf.sprintf "Waiting for authorization… (%ds · esc to cancel)"
           p.fp_elapsed);
    ]

(* Display-column length over UTF-8 (every glyph the URL row draws is one column
   wide) and an OCaml truncation, so the copy affordance stays on-screen: the
   Mosaic flex-truncate quirk measures [~truncate:true] text at its previous
   layout width, which would let a long URL push [c copy] off the right edge
   (doc/plans/tui-next.md §Rules). [c] always copies the full, untruncated URL. *)
let utf8_char_len c =
  let b = Char.code c in
  if b < 0x80 then 1 else if b < 0xE0 then 2 else if b < 0xF0 then 3 else 4

let column_count s =
  let n = String.length s in
  let rec loop i acc =
    if i >= n then acc else loop (i + utf8_char_len s.[i]) (acc + 1)
  in
  loop 0 0

let truncate_cols ~cols s =
  if cols <= 0 then ""
  else if column_count s <= cols then s
  else
    let rec take i c =
      if i >= String.length s || c >= cols - 1 then i
      else take (i + utf8_char_len s.[i]) (c + 1)
    in
    String.sub s 0 (take 0 0) ^ "…"

let url_row ~width url copied =
  let affordance = if copied then "copied" else "c  copy" in
  let budget = max 8 (width - 4 - 3 - column_count affordance - 4) in
  let shown = truncate_cols ~cols:budget (Uri.to_string url) in
  box ~flex_shrink:0. ~flex_direction:Flex_direction.Row ~overflow:hidden
    ~padding:(padding_lrtb 2 2 0 0)
    ~size:{ width = pct 100; height = px 1 }
    [
      text ~wrap:`None ~selectable:true ~flex_shrink:0. ("   " ^ shown);
      box ~flex_grow:1. [];
      seg Theme.faint (affordance ^ "  ");
    ]

let browser_content ~width p =
  let open_line =
    if p.fp_opened then muted_line "Browser opened. Complete sign-in there."
    else if p.fp_open_failed then
      faint_line "Press enter to try your browser again."
    else faint_line "Press enter to open your browser and authorize Spice."
  in
  let url_nodes =
    match p.fp_url with
    | None -> [ muted_line "Preparing the authorization link…" ]
    | Some url ->
        [
          muted_line "Or open this link yourself:";
          blank_row;
          url_row ~width url p.fp_copied;
        ]
  in
  (* [open_browser] could not spawn a browser (a headless or remote host): say so
     under the link, which sits just above, so the flow is not stranded on
     "Press enter…" (09-auth.md §States). Enter still retries. *)
  let failure_nodes =
    if p.fp_open_failed && not p.fp_opened then
      [
        blank_row;
        line ~style:Theme.warning
          "Could not open a browser automatically — open the link above.";
      ]
    else []
  in
  [
    bold_line ("Log in to " ^ p.fp_entry.display_name ^ " · browser");
    blank_row;
    open_line;
  ]
  @ url_nodes @ failure_nodes
  @ [
      blank_row;
      waiting_row p;
      blank_row;
      faint_line
        "On a remote or headless machine? Press esc and choose device code.";
    ]

let duration_text seconds =
  if seconds >= 60 then
    Printf.sprintf "%dm %02ds" (seconds / 60) (seconds mod 60)
  else Printf.sprintf "%ds" seconds

let device_content ~width p =
  let expiry =
    match p.fp_remaining with
    | Some remaining ->
        Printf.sprintf "2. Enter this code (expires in %s):"
          (duration_text remaining)
    | None -> "2. Enter this code:"
  in
  let code_row =
    match p.fp_user_code with
    | None -> muted_line "   requesting a code…"
    | Some code ->
        box ~flex_shrink:0. ~flex_direction:Flex_direction.Row ~overflow:hidden
          ~padding:(padding_lrtb 2 2 0 0)
          ~size:{ width = pct 100; height = px 1 }
          [
            text ~style:Theme.accent ~wrap:`None ~selectable:true
              ~flex_shrink:0. ("   " ^ code);
            box ~flex_grow:1. [];
            seg Theme.faint
              ((if p.fp_copied then "copied" else "c  copy") ^ "  ");
          ]
  in
  let url_nodes =
    match p.fp_url with
    | None -> [ muted_line "   requesting the link…" ]
    | Some url -> [ url_row ~width url p.fp_copied ]
  in
  [
    bold_line ("Log in to " ^ p.fp_entry.display_name ^ " · device code");
    blank_row;
    muted_line "1. Open this link and sign in:";
    blank_row;
  ]
  @ url_nodes
  @ [
      blank_row;
      muted_line expiry;
      blank_row;
      code_row;
      blank_row;
      muted_line
        "Device codes are a common phishing target. Never share this code.";
      blank_row;
      waiting_row p;
    ]

(* The instruction card for a method Spice cannot drive: the provider's
   declared instructions, verbatim, with the usual copy affordance. *)
let external_content state =
  let instruction_rows =
    String.split_on_char '\n' state.ext_instructions |> List.map muted_line
  in
  bold_line
    ("Log in to " ^ state.ext_entry.display_name ^ " · " ^ state.ext_label)
  :: blank_row :: instruction_rows

let chip_name = function Login -> "log in" | Logout -> "log out"

let hint_for stage mode =
  match stage with
  | Provider_pick _ ->
      let verb = match mode with Login -> "choose" | Logout -> "log out" in
      [ "↵ " ^ verb; "esc cancel"; "type to filter"; "↑↓ select" ]
  | Method_pick _ -> [ "↵ choose"; "esc back"; "type to filter"; "↑↓ select" ]
  | Api_key _ -> [ "↵ save"; "esc back" ]
  | Browser _ -> [ "↵ open browser"; "c copy"; "esc cancel" ]
  | Device _ -> [ "c copy"; "esc cancel" ]
  | External { ext_copied; _ } ->
      [ (if ext_copied then "copied" else "c copy"); "esc back" ]
  | Load_error _ -> [ "↵ retry"; "esc close" ]
  | Loading | Logout_empty | Working _ -> [ "esc close" ]

let content ~width ~rows t =
  match t.stage with
  | Loading -> [ muted_line "⠋ loading providers…" ]
  | Load_error message -> [ line ~style:Theme.error (Theme.problem ^ message) ]
  | Logout_empty -> [ muted_line "no providers are connected" ]
  | Provider_pick pick -> provider_pick_content ~rows t pick
  | Method_pick { entry; pick } -> method_pick_content ~rows entry pick
  | Api_key state -> api_key_content ~width state
  | Browser p -> browser_content ~width p
  | Device p -> device_content ~width p
  | External state -> external_content state
  | Working { label; _ } -> [ muted_line label ]

let view ~frame ~width ~rows t =
  Panel.view ~frame ~name:(chip_name t.mode) ~filter:(query t) ~width
    ~hint:(hint_for t.stage t.mode) ~content:(content ~width ~rows t)
