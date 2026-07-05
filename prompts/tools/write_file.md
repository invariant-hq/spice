Create or replace one UTF-8 text file in the workspace. Use it for new
files and full rewrites; prefer edit_file for modifying existing files,
so the change is reviewable as a diff. Do not create
documentation files or READMEs unless the user asked for them.

Usage:
- Without if_identity, the target must not exist yet; it is created,
  along with missing parent directories.
- To replace an existing file, first read it completely (read_file with
  no offset, limit, or max_bytes — the result includes its identity),
  then pass that identity as if_identity. A stale identity rejects the
  write, protecting against changes made underneath you.

Directories, symlinks, binary contents, stale identities, and paths
outside the workspace are rejected.
