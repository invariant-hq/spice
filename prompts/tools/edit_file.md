Replace exact UTF-8 text in one existing workspace file. This is the
default tool for small, targeted edits.

Usage:
- Read the file first, and copy old_string exactly as it appears —
  without the line-number prefix that read_file adds, with the original
  indentation intact.
- By default old_string must occur exactly once. If the edit fails
  because the text is not found, re-read the file — it changed since you
  read it. If it fails because the text is ambiguous, either extend
  old_string with surrounding lines until unique, pass occurrence=all to
  replace every instance, or switch to edit_lines and address the exact
  lines by anchor.
- Use the smallest old_string that is clearly unique — a few adjacent
  lines, not ten.
- Pass if_identity from a complete read_file observation to reject the
  edit if the file changed underneath you.
- Line endings in old_string and new_string are matched to the file's
  existing style. Existing UTF-8 BOMs are preserved; do not add or remove a
  BOM in the replacement text.

For a new file or a full rewrite, use write_file. To delete or move a
file, use shell. Directories, symlinks, binary files, invalid UTF-8, and
oversized files are rejected.
