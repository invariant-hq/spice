Search UTF-8 file contents inside the workspace with a ripgrep-style
regex, for example "let +normalize\b".

Modes: the default returns matching file paths only; count returns
per-file matching-line counts; matches returns line-numbered snippets.
Search roots may be files or directories; directory searches are
recursive, deterministic, respect standard ignore files, and skip binary
files and VCS metadata. Output paths are workspace-relative.

To find files by name, use glob. For an open-ended investigation needing
several rounds of searching and reading, spawn an explore subagent
instead of searching piecemeal.
