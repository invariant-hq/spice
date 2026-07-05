(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let max_honored_delay = 60.

let header_value headers name =
  List.find_map
    (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)
    headers

let month_number = function
  | "Jan" -> Some 1
  | "Feb" -> Some 2
  | "Mar" -> Some 3
  | "Apr" -> Some 4
  | "May" -> Some 5
  | "Jun" -> Some 6
  | "Jul" -> Some 7
  | "Aug" -> Some 8
  | "Sep" -> Some 9
  | "Oct" -> Some 10
  | "Nov" -> Some 11
  | "Dec" -> Some 12
  | _ -> None

(* Days from 1970-01-01 for a proleptic Gregorian civil date (Howard
   Hinnant's algorithm). *)
let days_from_civil ~year ~month ~day =
  let year = if month <= 2 then year - 1 else year in
  let era = (if year >= 0 then year else year - 399) / 400 in
  let year_of_era = year - (era * 400) in
  let day_of_year =
    (((153 * if month > 2 then month - 3 else month + 9) + 2) / 5) + day - 1
  in
  let day_of_era =
    (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100) + day_of_year
  in
  (era * 146097) + day_of_era - 719468

(* IMF-fixdate only ("Sun, 06 Nov 1994 08:49:37 GMT"); the obsolete RFC 850
   and asctime forms are not worth parsing. *)
let imf_fixdate text =
  let int_of value = int_of_string_opt value in
  match String.split_on_char ' ' (String.trim text) with
  | [ _weekday; day; month; year; time; "GMT" ] -> (
      match
        ( int_of day,
          month_number month,
          int_of year,
          String.split_on_char ':' time )
      with
      | Some day, Some month, Some year, [ hours; minutes; seconds ] -> (
          match (int_of hours, int_of minutes, int_of seconds) with
          | Some hours, Some minutes, Some seconds
            when day >= 1 && day <= 31 && hours < 24 && minutes < 60
                 && seconds < 61 ->
              Some
                (float_of_int
                   ((days_from_civil ~year ~month ~day * 86_400)
                   + (hours * 3_600) + (minutes * 60) + seconds))
          | _ -> None)
      | _ -> None)
  | _ -> None

let after ~now headers =
  match header_value headers "retry-after-ms" with
  | Some value ->
      Option.map
        (fun ms -> Float.max 0. (float_of_int ms /. 1000.))
        (int_of_string_opt value)
  | None -> (
      match header_value headers "retry-after" with
      | None -> None
      | Some value -> (
          match int_of_string_opt (String.trim value) with
          | Some seconds -> Some (Float.max 0. (float_of_int seconds))
          | None ->
              Option.map
                (fun date -> Float.max 0. (date -. now))
                (imf_fixdate value)))

let capacity_status status = status = 429 || status = 503 || status = 529

let budget ~max_retries ~status =
  if max_retries > 0 && capacity_status status then max 5 max_retries
  else max_retries
