#!/usr/bin/env bash
set -euo pipefail

AUTO_INSTALL="${EAI_SETUP_AUTO_INSTALL:-0}"
PROJECT_NAME=""
PROJECT_DIR=""
CURRENT_DIR=0

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--project <kebab-name>] [--directory <path>] [--current-dir]

The script installs only fixed, documented prerequisites. Set
EAI_SETUP_AUTO_INSTALL=1 to allow package-manager installation.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT_NAME="${2:?missing project name}"; shift 2 ;;
    --directory) PROJECT_DIR="${2:?missing directory}"; shift 2 ;;
    --current-dir) CURRENT_DIR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux) PLATFORM=linux ;;
  *) echo "This script supports macOS and Linux. Use scripts/bootstrap.ps1 on Windows." >&2; exit 1 ;;
esac

has() { command -v "$1" >/dev/null 2>&1; }
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
      else echo "Install Node.js 20+ with your distribution's signed package manager, then rerun." >&2; exit 1; fi
      ;;
  esac
}

if ! has git; then
  if [ "$PLATFORM" = macos ] && ! has brew; then
    echo "Git is missing and Homebrew is not installed. Install Homebrew from https://brew.sh, then rerun." >&2
    exit 1
  fi
  install_package git
fi

if ! has node || ! has npm; then
  if [ "$PLATFORM" = macos ] && ! has brew; then
    echo "Node.js is missing and Homebrew is not installed. Install Homebrew from https://brew.sh, then rerun." >&2
    exit 1
  fi
  install_package node
fi

if ! has node || ! has npm; then echo "Node.js and npm are required after installation." >&2; exit 1; fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then echo "Node.js 20 or newer is required; found $(node --version)." >&2; exit 1; fi

if ! has eai || [ "$AUTO_INSTALL" = "1" ]; then
  require_auto_install eai
  npm install --global @enterpriseai/cli
fi

echo "Git: $(git --version)"
echo "Node: $(node --version)"
echo "npm: $(npm --version)"
echo "EAI CLI: $(eai --version)"

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
  echo "Next: eai login, eai whoami, then eai init <project-name>."
fi
