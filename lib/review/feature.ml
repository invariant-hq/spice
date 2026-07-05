(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Evidence identities are computed over length-prefixed frames so that
   arbitrary content bytes (including NUL and newlines) cannot collide with
   the framing. *)
let add_frame buffer text =
  Buffer.add_string buffer (string_of_int (String.length text));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer text

module File = struct
  type status = Added | Deleted | Modified

  type content =
    | Text of Spice_diff.Hunk.t list
    | Opaque of [ `Binary | `Too_large ]

  type t = {
    path : Spice_path.Rel.t;
    status : status;
    content : content;
    before : string option;
    after : string option;
    digest : Spice_digest.Identity.t;
  }

  let identity ~before ~after =
    let buffer = Buffer.create 512 in
    Buffer.add_string buffer "file";
    let side = function
      | None -> Buffer.add_string buffer "\x00-"
      | Some text ->
          Buffer.add_string buffer "\x00+";
          add_frame buffer text
    in
    side before;
    side after;
    Spice_digest.Identity.of_contents (Buffer.contents buffer)

  let make ?(context = 12) ?(max_edit_distance = 4096) ~path ~before ~after () =
    if context < 0 then
      Error (Error.make Error.Invalid_file "context must be non-negative")
    else if max_edit_distance < 0 then
      Error
        (Error.make Error.Invalid_file "max_edit_distance must be non-negative")
    else
      match (before, after) with
      | None, None ->
          Error
            (Error.make Error.Invalid_file
               "file change must have at least one side")
      | _ ->
          let status =
            match (before, after) with
            | None, Some _ -> Added
            | Some _, None -> Deleted
            | _ -> Modified
          in
          let text_side = function
            | None -> true
            | Some text -> String.is_valid_utf_8 text
          in
          let content =
            if not (text_side before && text_side after) then Opaque `Binary
            else
              match
                Spice_diff.hunks ~context ~max_edit_distance
                  ~before:(Option.value before ~default:"")
                  ~after:(Option.value after ~default:"")
                  ()
              with
              | None -> Opaque `Too_large
              | Some hunks -> Text hunks
          in
          Ok
            {
              path;
              status;
              content;
              before;
              after;
              digest = identity ~before ~after;
            }

  let path t = t.path
  let status t = t.status
  let content t = t.content
  let before t = t.before
  let after t = t.after
  let digest t = t.digest

  let equal a b =
    Spice_path.Rel.equal a.path b.path
    && Spice_digest.Identity.equal a.digest b.digest

  let pp ppf t =
    Format.fprintf ppf "%s %s"
      (match t.status with
      | Added -> "added"
      | Deleted -> "deleted"
      | Modified -> "modified")
      (Spice_path.Rel.to_string t.path)
end

type t = {
  title : string option;
  base : string;
  tip : string;
  files : File.t list;
  digest : Spice_digest.Identity.t;
}

let identity files =
  let buffer = Buffer.create 512 in
  Buffer.add_string buffer "feature";
  List.iter
    (fun file ->
      Buffer.add_char buffer '\x00';
      add_frame buffer (Spice_path.Rel.to_string (File.path file));
      add_frame buffer (Spice_digest.Identity.to_string (File.digest file)))
    files;
  Spice_digest.Identity.of_contents (Buffer.contents buffer)

let v ?title ~base ~tip files =
  let files =
    let sorted =
      List.stable_sort
        (fun a b -> Spice_path.Rel.compare (File.path a) (File.path b))
        files
    in
    let rec dedup = function
      | a :: b :: rest when Spice_path.Rel.equal (File.path a) (File.path b) ->
          dedup (a :: rest)
      | a :: rest -> a :: dedup rest
      | [] -> []
    in
    dedup sorted
  in
  { title; base; tip; files; digest = identity files }

let title t = t.title
let base t = t.base
let tip t = t.tip
let files t = t.files

let find_file t ~path =
  List.find_opt (fun file -> Spice_path.Rel.equal (File.path file) path) t.files

let digest t = t.digest
let is_empty t = match t.files with [] -> true | _ :: _ -> false
let equal a b = Spice_digest.Identity.equal a.digest b.digest

let pp ppf t =
  Format.fprintf ppf "%s..%s (%d files)" t.base t.tip (List.length t.files)
