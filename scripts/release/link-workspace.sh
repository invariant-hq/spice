#!/bin/sh
# Emit a dune-workspace that makes release builds portable, on stdout.
#
# Release binaries must not depend on shared libraries a user's machine may
# lack. On Linux the build runs inside Alpine and links fully statically
# against musl. On macOS full static linking is impossible (libSystem is
# always dynamic), so the two Homebrew libraries in spice's closure — gmp
# (via zarith) and zstd (linked by the OCaml 5.5 runtime for compressed
# marshaling) — are resolved statically: ocamlopt places `-ccopt` flags
# before every library search path in the final cc invocation, so a leading
# -L pointing at a directory holding only the .a archives forces ld to pick
# them over the Homebrew dylibs.
#
# Usage: scripts/release/link-workspace.sh > "$RUNNER_TEMP/dune-workspace"
#        dune build --workspace "$RUNNER_TEMP/dune-workspace" ...
set -eu

case "$(uname -s)" in
Linux)
  cat <<'EOF'
(lang dune 3.22)
(profile release)
(env
 (_
  (link_flags (:standard -ccopt -static))))
EOF
  ;;
Darwin)
  stage="${SPICE_STATIC_LIB_DIR:-$(mktemp -d /tmp/spice-static-libs.XXXXXX)}"
  for lib in gmp zstd; do
    prefix="$(brew --prefix "$lib")"
    cp -f "$prefix/lib/lib$lib.a" "$stage/"
  done
  cat <<EOF
(lang dune 3.22)
(profile release)
(env
 (_
  (link_flags (:standard -ccopt -L$stage))))
EOF
  ;;
*)
  echo "link-workspace.sh: unsupported platform $(uname -s)" >&2
  exit 1
  ;;
esac
