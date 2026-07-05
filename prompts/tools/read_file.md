Read what is at a path inside the workspace: a file's text, or a directory's
entries.

Files:
- UTF-8 text comes back numbered. Use offset and limit to read just the range
  you need from a large file — avoid re-reading whole files for one section —
  and max_bytes to bound very large reads.
- When the complete file is read, the result includes a file identity: a token
  you can pass as if_identity to an editing tool that accepts one, so a
  concurrent change rejects your mutation instead of clobbering it.
- Reading several known files? Issue the read_file calls in parallel.

Directories:
- Reading a directory lists its immediate entries, one per line, sorted by kind
  then name, with a trailing slash on subdirectories. Ordinary dotfiles are
  included; VCS metadata is omitted. offset and limit page the entries the same
  way they page a file's lines; max_bytes and if_identity do not apply.
- To explore a tree by name pattern use glob; to find content use search_text.

Binary files, special files, and paths outside the workspace are rejected.
