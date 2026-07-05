#!/bin/sh
# Install spice, the OCaml coding agent.
#
#   curl -fsSL https://raw.githubusercontent.com/invariant-hq/spice/main/scripts/install.sh | sh
#
# Options (flags or environment variables):
#   -v, --version X.Y.Z    install a specific release  (SPICE_VERSION)
#   -d, --dir DIR          install directory           (SPICE_INSTALL_DIR,
#                          default ~/.local/bin)
#       --no-modify-path   never edit shell rc files
#
# Downloads the release archive for this platform from GitHub Releases,
# verifies it against the release's SHA256SUMS, and installs atomically.
# The whole script is a function invoked on the last line so a truncated
# download cannot execute a partial script.

set -eu

REPO="invariant-hq/spice"
GITHUB="https://github.com"

usage() {
  cat <<'EOF'
Install spice, the OCaml coding agent.

  curl -fsSL https://raw.githubusercontent.com/invariant-hq/spice/main/scripts/install.sh | sh

Options (flags or environment variables):
  -v, --version X.Y.Z    install a specific release  (SPICE_VERSION)
  -d, --dir DIR          install directory           (SPICE_INSTALL_DIR,
                         default ~/.local/bin)
      --no-modify-path   never edit shell rc files
EOF
}

say() { printf '%s\n' "$*"; }
err() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" > /dev/null 2>&1 || err "required command not found: $1"
}

sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    err "neither sha256sum nor shasum found; cannot verify download"
  fi
}

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
  Darwin)
    # A binary running under Rosetta reports x86_64; the machine is arm64.
    if [ "$arch" = "x86_64" ] \
      && [ "$(sysctl -n sysctl.proc_translated 2> /dev/null || echo 0)" = "1" ]; then
      arch=arm64
    fi
    case "$arch" in
    arm64) target=darwin-arm64 ;;
    x86_64) target=darwin-x64 ;;
    *) err "unsupported macOS architecture: $arch" ;;
    esac
    ;;
  Linux)
    case "$arch" in
    x86_64 | amd64) target=linux-x64 ;;
    aarch64 | arm64) target=linux-arm64 ;;
    *) err "unsupported Linux architecture: $arch" ;;
    esac
    ;;
  MINGW* | MSYS* | CYGWIN*)
    err "Windows is not supported yet; use WSL and the Linux binary"
    ;;
  *)
    err "unsupported platform: $os"
    ;;
  esac
  printf '%s' "$target"
}

# Resolve the concrete version tag for a release, following GitHub's
# "latest" redirect so we never need the rate-limited API.
resolve_version() {
  if [ -n "$version" ]; then
    printf '%s' "$version"
    return
  fi
  location="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "$GITHUB/$REPO/releases/latest")" \
    || err "cannot reach $GITHUB/$REPO/releases/latest"
  tag="${location##*/}"
  case "$tag" in
  latest | '') err "no published release found for $REPO" ;;
  esac
  printf '%s' "$tag"
}

modify_path() {
  case ":$PATH:" in
  *":$install_dir:"*) return 0 ;;
  esac

  # Make the freshly installed binary visible to GitHub Actions steps.
  if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$install_dir" >> "$GITHUB_PATH"
    return 0
  fi

  if [ "$no_modify_path" = 1 ]; then
    say ""
    say "Add $install_dir to your PATH to use spice:"
    say "  export PATH=\"$install_dir:\$PATH\""
    return 0
  fi

  shell_name="$(basename "${SHELL:-sh}")"
  rc=""
  line="export PATH=\"$install_dir:\$PATH\""
  case "$shell_name" in
  zsh) rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash)
    for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
      [ -f "$f" ] && rc="$f" && break
    done
    rc="${rc:-$HOME/.bashrc}"
    ;;
  fish)
    rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
    line="fish_add_path $install_dir"
    ;;
  *) rc="$HOME/.profile" ;;
  esac

  if [ -f "$rc" ] && grep -Fq "$line" "$rc"; then
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  printf '\n# Added by the spice installer\n%s\n' "$line" >> "$rc"
  say "Added $install_dir to PATH in $rc; restart your shell to pick it up."
}

main() {
  version="${SPICE_VERSION:-}"
  install_dir="${SPICE_INSTALL_DIR:-$HOME/.local/bin}"
  no_modify_path=0

  while [ $# -gt 0 ]; do
    case "$1" in
    -v | --version)
      [ $# -ge 2 ] || err "$1 requires an argument"
      version="$2"
      shift 2
      ;;
    -d | --dir)
      [ $# -ge 2 ] || err "$1 requires an argument"
      install_dir="$2"
      shift 2
      ;;
    --no-modify-path)
      no_modify_path=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      err "unknown option: $1 (try --help)"
      ;;
    esac
  done

  need uname
  need curl
  need tar
  need mktemp

  target="$(detect_target)"
  version="$(resolve_version)"
  archive="spice-$target.tar.gz"
  base="$GITHUB/$REPO/releases/download/$version"

  installed="$install_dir/spice"
  if [ -x "$installed" ] \
    && [ "$("$installed" --version 2> /dev/null || true)" = "$version" ]; then
    say "spice $version is already installed at $installed"
    exit 0
  fi

  say "Installing spice $version ($target) to $install_dir"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/$archive" "$base/$archive" \
    || err "download failed: $base/$archive"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" \
    || err "download failed: $base/SHA256SUMS"

  expected="$(awk -v f="$archive" '$2 == f { print $1 }' "$tmp/SHA256SUMS")"
  [ -n "$expected" ] || err "no checksum for $archive in SHA256SUMS"
  actual="$(sha256_of "$tmp/$archive")"
  if [ "$actual" != "$expected" ]; then
    err "checksum mismatch for $archive
  expected: $expected
  actual:   $actual
The download may be corrupted or tampered with; not installing."
  fi

  tar -xzf "$tmp/$archive" -C "$tmp"
  [ -f "$tmp/spice" ] || err "archive did not contain a spice binary"

  # Copy into the destination directory first so the final rename is atomic
  # even when $tmp is on another filesystem.
  mkdir -p "$install_dir"
  chmod 755 "$tmp/spice"
  cp -f "$tmp/spice" "$installed.tmp.$$"
  mv -f "$installed.tmp.$$" "$installed"

  say "Installed $("$installed" --version) -> $installed"
  modify_path

  say ""
  say "Get started:"
  say "  spice auth login anthropic   # or openai, google"
  say "  spice                        # open the TUI in your project"
  say ""
  say "Shell completions: spice completion zsh|bash|pwsh (see spice completion --help)"
}

main "$@"
