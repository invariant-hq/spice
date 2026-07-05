Apply anchored line edits to one existing UTF-8 text file. Use this when
exact-string replacement is awkward: the target text occurs many times,
or the region is whitespace-sensitive.

Read the file first: each line comes prefixed with its line number and
an opaque anchor word. Anchors carry no meaning and are file-scoped.
Each edit names its target as "anchor§exact line text" — the anchor
word, the § delimiter, then the line's current text exactly as it
appears after the tab (no line number, no anchor word, indentation
intact). For example, if read_file shows line 12 as

  12 AppleBanana	  let count = ref 0 in

then replacing that line uses anchor "AppleBanana§  let count = ref 0 in".

Operations:
- replace: replaces the inclusive range from anchor to end_anchor with
  text. end_anchor is required and may equal anchor for a single line.
  Empty text deletes the range.
- insert_before / insert_after: inserts text adjacent to the anchor
  line. end_anchor is not allowed.

Batch all non-overlapping edits to the file into one call; they are
validated together and applied atomically. If any anchor is missing or
its line text does not match, nothing is applied and the failure reports
expected versus provided text — re-read the file for fresh anchors and
retry.
