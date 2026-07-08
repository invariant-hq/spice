(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Diff = Spice_diff

let label = Diff.Label.of_string

let limits ?(max_files = 10) ?(max_file_bytes = 1_000) ?(max_lines = 1_000)
    ?max_edit_distance () =
  Diff.Limits.make ~max_files ~max_file_bytes ~max_lines ?max_edit_distance ()

let print_diff ?context ?limits ?mode changes =
  Diff.render ?context ?limits ?mode changes |> Diff.to_string |> print_string

let print_case name = Printf.printf "-- %s --\n" name

let%expect_test "basic modify" =
  print_diff
    [
      Diff.File_change.modify ~label:(label "file.txt") ~before:"a\nb\nc\n"
        ~after:"a\nB\nc\n";
    ];
  [%expect
    {|
    --- file.txt
    +++ file.txt
    @@ -1,3 +1,3 @@
     a
    -b
    +B
     c |}]

let%expect_test "create and delete use dev null" =
  print_diff
    [
      Diff.File_change.create ~label:(label "new.txt") ~contents:"hello\n";
      Diff.File_change.delete ~label:(label "old.txt") ~contents:"bye\n";
    ];
  [%expect
    {|
    --- /dev/null
    +++ new.txt
    @@ -0,0 +1,1 @@
    +hello
    --- old.txt
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -bye |}]

let%expect_test "requested context" =
  print_diff ~context:0
    [
      Diff.File_change.modify ~label:(label "file.txt") ~before:"a\nb\nc\n"
        ~after:"a\nB\nc\n";
    ];
  [%expect
    {|
    --- file.txt
    +++ file.txt
    @@ -2,1 +2,1 @@
    -b
    +B |}]

let%expect_test "separated changes split into hunks" =
  print_diff ~context:1
    [
      Diff.File_change.modify ~label:(label "multi.txt")
        ~before:"a\nb\nc\nd\ne\nf\ng\n" ~after:"a\nB\nc\nd\ne\nF\ng\n";
    ];
  [%expect
    {|
    --- multi.txt
    +++ multi.txt
    @@ -1,3 +1,3 @@
     a
    -b
    +B
     c
    @@ -5,3 +5,3 @@
     e
    -f
    +F
     g |}]

let%expect_test "missing final newline markers" =
  print_case "modified file";
  print_diff
    [
      Diff.File_change.modify ~label:(label "file.txt") ~before:"hello"
        ~after:"hello\n";
    ];
  [%expect
    {|
    -- modified file --
    --- file.txt
    +++ file.txt
    @@ -1,1 +1,1 @@
    -hello
    \ No newline at end of file
    +hello |}];
  print_case "deleted file";
  print_diff
    [ Diff.File_change.delete ~label:(label "old.txt") ~contents:"bye" ];
  [%expect
    {|
    -- deleted file --
    --- old.txt
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -bye
    \ No newline at end of file |}];
  print_case "created file";
  print_diff
    [ Diff.File_change.create ~label:(label "new.txt") ~contents:"hello" ];
  [%expect
    {|
    -- created file --
    --- /dev/null
    +++ new.txt
    @@ -0,0 +1,1 @@
    +hello
    \ No newline at end of file |}]

let%expect_test "empty create and delete still render headers" =
  print_diff
    [
      Diff.File_change.create ~label:(label "empty-new.txt") ~contents:"";
      Diff.File_change.delete ~label:(label "empty-old.txt") ~contents:"";
    ];
  [%expect
    {|
    --- /dev/null
    +++ empty-new.txt
    --- empty-old.txt
    +++ /dev/null |}]

let%expect_test "boundary insertions and deletions" =
  print_case "insertions";
  print_diff ~context:0
    [
      Diff.File_change.modify ~label:(label "file.txt") ~before:"b\nc\n"
        ~after:"a\nb\nc\nd\n";
    ];
  [%expect
    {|
    -- insertions --
    --- file.txt
    +++ file.txt
    @@ -0,0 +1,1 @@
    +a
    @@ -2,0 +4,1 @@
    +d |}];
  print_case "deletions";
  print_diff ~context:0
    [
      Diff.File_change.modify ~label:(label "file.txt") ~before:"a\nb\nc\nd\n"
        ~after:"b\nc\n";
    ];
  [%expect
    {|
    -- deletions --
    --- file.txt
    +++ file.txt
    @@ -1,1 +0,0 @@
    -a
    @@ -4,1 +2,0 @@
    -d |}]

let%expect_test "nearby and overlapping context" =
  print_case "nearby changes";
  print_diff ~context:1
    [
      Diff.File_change.modify ~label:(label "file.txt") ~before:"a\nb\nc\n"
        ~after:"A\nb\nC\n";
    ];
  [%expect
    {|
    -- nearby changes --
    --- file.txt
    +++ file.txt
    @@ -1,3 +1,3 @@
    -a
    +A
     b
    -c
    +C |}];
  print_case "overlapping context";
  print_diff ~context:3
    [
      Diff.File_change.modify ~label:(label "file.txt")
        ~before:"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
        ~after:"a\nB\nc\nd\ne\nf\ng\nh\nI\nj\n";
    ];
  [%expect
    {|
    -- overlapping context --
    --- file.txt
    +++ file.txt
    @@ -1,10 +1,10 @@
     a
    -b
    +B
     c
     d
     e
     f
     g
     h
    -i
    +I
     j |}]

let%expect_test "repeated line context" =
  print_diff ~context:1
    [
      Diff.File_change.modify ~label:(label "repeat.txt")
        ~before:"same\na\nsame\na\nsame\n" ~after:"same\na\nsame\nb\nsame\n";
    ];
  [%expect
    {|
    --- repeat.txt
    +++ repeat.txt
    @@ -3,3 +3,3 @@
     same
    -a
    +b
     same |}]

let%expect_test "multi file order follows input order" =
  print_diff
    [
      Diff.File_change.create ~label:(label "b.txt") ~contents:"b\n";
      Diff.File_change.create ~label:(label "a.txt") ~contents:"a\n";
    ];
  [%expect
    {|
    --- /dev/null
    +++ b.txt
    @@ -0,0 +1,1 @@
    +b
    --- /dev/null
    +++ a.txt
    @@ -0,0 +1,1 @@
    +a |}]

let%expect_test "limits" =
  print_case "file bytes";
  print_diff
    ~limits:(limits ~max_file_bytes:4 ())
    [ Diff.File_change.create ~label:(label "big.txt") ~contents:"hello\n" ];
  [%expect
    {|
    -- file bytes --
    --- /dev/null
    +++ big.txt
    [diff omitted: file exceeds 4 byte display limit] |}];
  print_case "edit distance";
  print_diff
    ~limits:(limits ~max_edit_distance:1 ())
    [
      Diff.File_change.modify ~label:(label "rewrite.txt") ~before:"a\nb\n"
        ~after:"c\nd\n";
    ];
  [%expect
    {|
    -- edit distance --
    --- rewrite.txt
    +++ rewrite.txt
    [diff omitted: edit distance exceeds 1 display limit] |}];
  print_case "file count";
  print_diff ~limits:(limits ~max_files:1 ())
    [
      Diff.File_change.create ~label:(label "a.txt") ~contents:"a\n";
      Diff.File_change.create ~label:(label "b.txt") ~contents:"b\n";
    ];
  [%expect
    {|
    -- file count --
    --- /dev/null
    +++ a.txt
    @@ -0,0 +1,1 @@
    +a
    [diff omitted: 1 file exceeds max_files display limit] |}]

let%expect_test "display mode escapes unsafe text" =
  let unsafe_label =
    Diff.Label.of_string "bad\216\156\226\128\142\226\128\143.txt"
  in
  let unsafe_text = "safe\027\216\156\226\128\142\226\128\143\226\128\174\n" in
  print_diff
    [ Diff.File_change.create ~label:unsafe_label ~contents:unsafe_text ];
  [%expect
    {|
    --- /dev/null
    +++ bad\u{061c}\u{200e}\u{200f}.txt
    @@ -0,0 +1,1 @@
    +safe\x1B\u{061c}\u{200e}\u{200f}\u{202e} |}]

let%expect_test "display mode escapes C1 controls" =
  let unsafe_label = Diff.Label.of_string "bad\128\155\159.txt" in
  let unsafe_text = "safe\128\155\159\n" in
  print_diff [ Diff.File_change.create ~label:unsafe_label ~contents:unsafe_text ];
  [%expect
    {|
    --- /dev/null
    +++ bad\x80\x9B\x9F.txt
    @@ -0,0 +1,1 @@
    +safe\x80\x9B\x9F |}]

[%%run_tests "spice.diff.expect"]
