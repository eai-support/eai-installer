#!/usr/bin/env bash
set -euo pipefail

AUTO_INSTALL="${EAI_SETUP_AUTO_INSTALL:-0}"
INSTALL_HOMEBREW="${EAI_SETUP_INSTALL_HOMEBREW:-0}"
PROJECT_NAME=""
PROJECT_DIR=""
CURRENT_DIR=0

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--project <kebab-name>] [--directory <path>] [--current-dir] [--install-homebrew]

The script installs only fixed, documented prerequisites. Set
EAI_SETUP_AUTO_INSTALL=1 to allow package-manager installation. On macOS,
--install-homebrew (or EAI_SETUP_INSTALL_HOMEBREW=1) explicitly permits the
official Homebrew installer to run when brew is missing.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT_NAME="${2:?missing project name}"; shift 2 ;;
    --directory) PROJECT_DIR="${2:?missing directory}"; shift 2 ;;
    --current-dir) CURRENT_DIR=1; shift ;;
    --install-homebrew) INSTALL_HOMEBREW=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Explicit Homebrew consent also permits the fixed Git/Node package steps.
if [ "$INSTALL_HOMEBREW" = "1" ]; then AUTO_INSTALL=1; fi

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux) PLATFORM=linux ;;
  *) echo "This script supports macOS and Linux. Use scripts/bootstrap.ps1 on Windows." >&2; exit 1 ;;
esac

has() { command -v "$1" >/dev/null 2>&1; }
EAI_CLI_VERSION=""
eai_version_supported() {
  local current=""
  current="$(eai --version 2>/dev/null)" || return 1
  EAI_CLI_VERSION="$current"
  [[ "$current" =~ ^v?([0-9]+)[.]([0-9]+)[.]([0-9]+) ]] || return 1
  local major="${BASH_REMATCH[1]}"
  local minor="${BASH_REMATCH[2]}"
  local patch="${BASH_REMATCH[3]}"
  (( major > 3 )) || (( major == 3 && minor > 17 )) || (( major == 3 && minor == 17 && patch >= 0 ))
}
eai_managed_deploy_ready() {
  has eai && eai_version_supported || return 1
  local deploy_help=""
  deploy_help="$(eai deploy app --help 2>/dev/null)" || return 1
  [[ "$deploy_help" == *"--source"* \
    && "$deploy_help" == *"--github-link-session"* \
    && "$deploy_help" == *"--target-tenant-id"* ]]
}
require_auto_install() {
  if [ "$AUTO_INSTALL" != "1" ]; then
    echo "Missing $1. Re-run with EAI_SETUP_AUTO_INSTALL=1 after reviewing the fixed package-manager steps." >&2
    exit 1
  fi
}

install_package() {
  case "$PLATFORM:$1" in
    macos:git) require_auto_install git; brew install git ;;
    macos:node) require_auto_install node; brew install node ;;
    linux:git)
      require_auto_install git
      if has apt-get; then sudo apt-get update && sudo apt-get install -y git
      elif has dnf; then sudo dnf install -y git
      else echo "Install Git with your distribution's signed package manager, then rerun." >&2; exit 1; fi
      ;;
    linux:node)
      require_auto_install node
      if has apt-get; then sudo apt-get update && sudo apt-get install -y nodejs npm
      elif has dnf; then sudo dnf install -y nodejs npm
      else echo "Install Node.js 24+ with your distribution's signed package manager, then rerun." >&2; exit 1; fi
      ;;
  esac
}

install_homebrew() {
  if has brew; then return 0; fi
  if [ "$INSTALL_HOMEBREW" != "1" ]; then
    echo "Homebrew is missing. Re-run with --install-homebrew after reviewing the official installer." >&2
    exit 1
  fi
  has curl || { echo "curl is required to install Homebrew from its official HTTPS source." >&2; exit 1; }
  local installer
  installer="$(mktemp "${TMPDIR:-/tmp}/eai-homebrew.XXXXXX.sh")"
  trap 'rm -f "$installer"' EXIT
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$installer" \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
  /bin/bash "$installer"
  rm -f "$installer"
  trap - EXIT
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  has brew || { echo "Homebrew installation completed without brew being available on PATH. Restart your shell and rerun." >&2; exit 1; }
}

if ! has git; then
  if [ "$PLATFORM" = macos ] && ! has brew; then
    install_homebrew
  fi
  install_package git
fi

if ! has node || ! has npm; then
  if [ "$PLATFORM" = macos ] && ! has brew; then
    install_homebrew
  fi
  install_package node
fi

if ! has node || ! has npm; then echo "Node.js and npm are required after installation." >&2; exit 1; fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 24 ]; then echo "Node.js 24 or newer is required; found $(node --version)." >&2; exit 1; fi

EAI_MANAGED_DEPLOY_READY=0
if eai_managed_deploy_ready; then EAI_MANAGED_DEPLOY_READY=1; fi
if [ "$EAI_MANAGED_DEPLOY_READY" != "1" ]; then
  if has eai && [ "$AUTO_INSTALL" != "1" ]; then
    echo "The installed EAI CLI is incompatible. EAI Setup requires version 3.17.0 or newer with source choice, GitHub-link handoff, and target-tenant binding. Re-run with EAI_SETUP_AUTO_INSTALL=1 to update it." >&2
    exit 1
  fi
  require_auto_install eai
  npm install --global @enterpriseai/cli
  EAI_MANAGED_DEPLOY_READY=0
  if eai_managed_deploy_ready; then EAI_MANAGED_DEPLOY_READY=1; fi
fi

if [ "$EAI_MANAGED_DEPLOY_READY" != "1" ]; then
  echo "The installed EAI CLI is incompatible. EAI Setup requires version 3.17.0 or newer with source choice, GitHub-link handoff, and target-tenant binding." >&2
  exit 1
fi

echo "Git: $(git --version)"
echo "Node: $(node --version)"
echo "npm: $(npm --version)"
echo "EAI CLI: $EAI_CLI_VERSION"

if [ -n "$PROJECT_NAME" ]; then
  case "$PROJECT_NAME" in
    *[!a-z0-9-]*|[-]*|*-|"") echo "Project name must be kebab-case." >&2; exit 2 ;;
  esac
  if [ "$CURRENT_DIR" = "1" ]; then
    eai init "$PROJECT_NAME" --current-dir
  else
    [ -n "$PROJECT_DIR" ] || PROJECT_DIR="$(pwd)/$PROJECT_NAME"
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    eai init "$PROJECT_NAME" --current-dir
  fi
else
  echo "Next: eai login, eai whoami, then eai init <project-name>. Use 'eai deploy app --help' when you are ready to choose hosting. EAI hosting verifies your linked GitHub identity, then offers EAI-maintained or customer-owned source."
fi
