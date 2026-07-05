#!/bin/sh
# Gate a release binary: it must carry no dynamic dependencies a user's
# machine may lack, must be built for the architecture its name promises,
# and must report the expected version.
#
# Usage: scripts/release/check-portable.sh <binary> <expected-version> <target>
# where <target> is one of: linux-x64 linux-arm64 darwin-x64 darwin-arm64
#
# On Linux the binary must be fully static; running this on a glibc host
# against the musl-built binary doubles as the portability proof. On macOS
# only /usr/lib and /System libraries are allowed.
set -eu

bin="$1"
expected="$2"
target="$3"

case "$target" in
*-x64) arch_pattern='x86[-_]64' ;;
*-arm64) arch_pattern='arm64|aarch64' ;;
*)
  echo "check-portable.sh: unknown target $target" >&2
  exit 1
  ;;
esac
if ! file "$bin" | grep -qE "$arch_pattern"; then
  echo "check-portable.sh: architecture mismatch: expected $target but:" >&2
  file "$bin" >&2
  exit 1
fi

case "$(uname -s)" in
Darwin)
  bad="$(otool -L "$bin" | tail -n +2 | awk '{print $1}' \
    | grep -Ev '^(/usr/lib/|/System/)' || true)"
  if [ -n "$bad" ]; then
    echo "check-portable.sh: non-system dynamic libraries:" >&2
    echo "$bad" >&2
    exit 1
  fi
  ;;
Linux)
  # glibc ldd: "statically linked" / "not a dynamic executable";
  # musl ldd: "Not a valid dynamic program".
  if ! ldd "$bin" 2>&1 | grep -qiE 'not a dynamic executable|statically linked|not a valid dynamic program'; then
    echo "check-portable.sh: binary is dynamically linked:" >&2
    ldd "$bin" >&2 || true
    exit 1
  fi
  ;;
*)
  echo "check-portable.sh: unsupported platform $(uname -s)" >&2
  exit 1
  ;;
esac

actual="$("$bin" --version)"
if [ "$actual" != "$expected" ]; then
  echo "check-portable.sh: version mismatch: binary reports '$actual'," \
    "expected '$expected'" >&2
  exit 1
fi

echo "portable OK: $bin ($target, $actual)"
