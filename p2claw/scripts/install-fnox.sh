#!/usr/bin/env bash
# install-fnox.sh
# Idempotent fnox installer for p2claw skill setup.
# Detects existing installations and the best install method for the platform.

set -euo pipefail

# Colors for output (only if stdout is a terminal)
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RESET=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' RESET=''
fi

log()   { printf '%s\n' "$*" >&2; }
ok()    { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn()  { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fail()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# Refuse to run on native Windows. Tell the user to use WSL.
check_not_windows() {
  case "${OS:-}" in
    Windows_NT)
      fail "p2claw doesn't support native Windows. Please install WSL and run this from inside an Ubuntu (or other Linux) shell: https://learn.microsoft.com/en-us/windows/wsl/install"
      ;;
  esac

  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      fail "p2claw doesn't support Git Bash / MSYS / Cygwin on Windows. Please install WSL and run this from inside an Ubuntu (or other Linux) shell: https://learn.microsoft.com/en-us/windows/wsl/install"
      ;;
  esac
}

# Check if fnox is already installed and working
check_existing() {
  if command -v fnox >/dev/null 2>&1; then
    local version
    version=$(fnox --version 2>/dev/null | head -1 || echo "unknown")
    ok "fnox already installed: $version"
    return 0
  fi
  return 1
}

# Detect platform for binary download fallback
detect_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) fail "Unsupported architecture: $arch" ;;
  esac

  case "$os" in
    darwin) os="apple-darwin" ;;
    linux) os="unknown-linux-gnu" ;;
    *) fail "Unsupported OS: $os" ;;
  esac

  echo "${arch}-${os}"
}

# Install via mise (preferred)
install_via_mise() {
  if command -v mise >/dev/null 2>&1; then
    log "Installing fnox via mise..."
    mise use -g fnox
    ok "Installed fnox via mise"
    return 0
  fi
  return 1
}

# Install via Homebrew (macOS or Linux with brew)
install_via_brew() {
  if command -v brew >/dev/null 2>&1; then
    log "Installing fnox via Homebrew..."
    brew install fnox
    ok "Installed fnox via Homebrew"
    return 0
  fi
  return 1
}

# Install via cargo (if Rust toolchain is present)
install_via_cargo() {
  if command -v cargo >/dev/null 2>&1; then
    log "Installing fnox via cargo (this may take a few minutes)..."
    cargo install fnox
    ok "Installed fnox via cargo"
    return 0
  fi
  return 1
}

# Download prebuilt binary as last resort
install_via_binary() {
  local platform install_dir url tmpdir
  platform=$(detect_platform)
  install_dir="${HOME}/.local/bin"
  mkdir -p "$install_dir"

  log "Downloading fnox binary for ${platform}..."

  # Get latest release tag from GitHub API
  local tag
  tag=$(curl -fsSL https://api.github.com/repos/jdx/fnox/releases/latest \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/') \
    || fail "Could not fetch latest fnox release"

  url="https://github.com/jdx/fnox/releases/download/${tag}/fnox-${tag#v}-${platform}.tar.gz"
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" EXIT

  curl -fsSL "$url" -o "$tmpdir/fnox.tar.gz" \
    || fail "Failed to download fnox from $url"

  tar -xzf "$tmpdir/fnox.tar.gz" -C "$tmpdir"
  install -m 0755 "$tmpdir"/fnox*/fnox "$install_dir/fnox" \
    || install -m 0755 "$tmpdir/fnox" "$install_dir/fnox" \
    || fail "Could not find fnox binary in archive"

  ok "Installed fnox to $install_dir/fnox"

  # Warn if install_dir isn't on PATH
  if ! echo ":$PATH:" | grep -q ":$install_dir:"; then
    warn "$install_dir is not on your PATH"
    warn "Add this to your shell profile:"
    warn "    export PATH=\"$install_dir:\$PATH\""
  fi
}

# Verify the installation worked
verify_install() {
  # Pick up new PATH entries from this session
  hash -r 2>/dev/null || true

  if command -v fnox >/dev/null 2>&1; then
    local version
    version=$(fnox --version 2>/dev/null | head -1 || echo "unknown")
    ok "fnox installed: $version"
    return 0
  fi

  fail "fnox installed but not found on PATH. You may need to restart your shell."
}

main() {
  check_not_windows

  log "Checking for fnox..."

  if check_existing; then
    exit 0
  fi

  log "fnox not found. Installing..."

  # Try install methods in order of preference
  install_via_mise \
    || install_via_brew \
    || install_via_cargo \
    || install_via_binary

  verify_install
}

main "$@"
