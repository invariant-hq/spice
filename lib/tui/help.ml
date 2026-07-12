(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

type entry = { keys : string; action : string }
type section = { title : string; entries : entry list }

(* The composer keybindings (03-composer.md §Keybindings), grouped into the
   three columns of the old sheet. The shell trims entries whose keys the
   current surface does not bind. *)
let sections =
  [
    {
      title = "composer";
      entries =
        [
          { keys = "/"; action = "commands" };
          { keys = "@"; action = "file paths" };
          { keys = "!"; action = "shell mode" };
          { keys = "?"; action = "this help" };
        ];
    };
    {
      title = "history";
      entries =
        [
          { keys = "shift+enter"; action = "newline" };
          { keys = "↑ ↓"; action = "prompt history" };
          { keys = "ctrl+r"; action = "search history" };
          { keys = "esc esc"; action = "interrupt turn" };
        ];
    };
    {
      title = "controls";
      entries =
        [
          { keys = "←"; action = "focus agents" };
          { keys = "ctrl+o"; action = "verbose reasoning" };
          { keys = "pageup pagedown"; action = "scroll" };
          { keys = "ctrl+c ctrl+c"; action = "quit" };
        ];
    };
  ]

let display_width s = Matrix.Text.measure ~width_method:`Unicode ~tab_width:2 s

(* Keys carry multibyte marks (arrows), so alignment is by display width, not
   byte length. *)
let pad_keys width s =
  let w = display_width s in
  if w >= width then s else s ^ String.make (width - w) ' '

let column { title; entries } =
  let key_width =
    List.fold_left (fun w e -> max w (display_width e.keys)) 0 entries
  in
  let entry_row e =
    box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
      ~size:{ width = auto; height = px 1 }
      [
        text ~style:Theme.faint ~wrap:`None (pad_keys key_width e.keys);
        text ~style:Theme.muted ~wrap:`None ("  " ^ e.action);
      ]
  in
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~padding:(padding_lrtb 0 2 0 0)
    (text ~style:Theme.muted ~wrap:`None title :: List.map entry_row entries)

let view sections =
  box ~flex_direction:Flex_direction.Row ~padding:(padding_lrtb 2 0 0 0)
    ~size:{ width = pct 100; height = auto }
    (List.map column sections)
