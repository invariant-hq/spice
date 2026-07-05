Apply one patch to UTF-8 text files in the workspace. Use this for every
edit: a single targeted replacement, several hunks in one file, edits
spanning multiple files, or adding, deleting, and moving files in one
atomic step.

The patch uses the envelope

  *** Begin Patch
  *** Update File: path/to/file.ml
  @@ let nearest_enclosing_header
   context line
  -old line
  +new line
   context line
  *** End Patch

with *** Add File:, *** Delete File:, and optional *** Move to: sections.
Paths are workspace-root relative, never absolute.

Context craft: give about three lines of context above and below each
change; when that does not uniquely locate the hunk, add an @@ line
naming the enclosing definition. Missing or ambiguous context rejects
the whole patch — nothing is partially applied.

Also rejected: absolute paths, symlinks, directories, binary files,
invalid UTF-8, duplicate outputs, and add or move destinations that
already exist. On success, do not re-read the files to confirm; a patch
that does not apply fails loudly.
