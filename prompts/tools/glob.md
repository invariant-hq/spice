Find files inside the workspace by ripgrep glob pattern, for example
"**/*.mli" or "lib/**/dune".

Discovery is recursive, respects standard ignore files, includes ordinary
dotfiles, and excludes VCS metadata. Results are workspace-relative
paths, paginated with a one-based offset; use sort=modified for newest
first. To search file contents rather than names, use search_text. For
an open-ended hunt that will take several rounds of globbing and
searching, spawn an explore subagent instead.
