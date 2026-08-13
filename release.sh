#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${EAI_INSTALLER_REPO:-eai-support/eai-installer}"

usage() {
  cat <<'EOF'
Usage:
  ./release.sh <patch|minor|major> [message]
  ./release.sh publish <version>
  ./release.sh e2e <version>

The version commands create a release PR. They never push directly to main.
After that PR is merged, `publish` tags the merged version, waits for the
GitHub release workflow, downloads the exact release assets, and runs the VM
end-to-end gate.

Examples:
  ./release.sh patch "Improve clean-machine bootstrap"
  ./release.sh minor "Add release VM gate"
  ./release.sh publish 0.2.0
EOF
}

section() { printf '\n▸ %s\n' "$1"; }
die() { echo "✗ $1" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

version_from_source() { node -p "require('./package.json').version"; }

ensure_clean_main() {
  local branch
  branch="$(git branch --show-current)"
  [[ "$branch" == "main" ]] || die "This operation must start from main; currently on $branch"
  [[ -z "$(git status --porcelain)" ]] || die "Working tree is dirty; commit or stash changes first"
  git fetch origin main --quiet
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "Local main is not equal to origin/main"
}

wait_for_release_workflow() {
  local tag="$1"
  local run_id=""
  for _ in $(seq 1 60); do
    run_id="$(gh run list --repo "$REPO" --workflow release.yml --limit 20 --json databaseId,headBranch --jq ".[] | select(.headBranch == \"$tag\") | .databaseId" | head -n 1)"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || die "Could not find the release workflow for $tag"
  gh run watch "$run_id" --repo "$REPO" --exit-status
}

prepare_release() {
  local bump="$1"
  local message="${2:-EAI Setup release}"
  [[ "$bump" =~ ^(patch|minor|major)$ ]] || { usage; exit 2; }
  require_command git
  require_command node
  require_command gh
  cd "$ROOT"
  ensure_clean_main

  local current next branch
  current="$(version_from_source)"
  next="$(node -e '
    const [major, minor, patch] = process.argv[1].split(".").map(Number);
    const bump = process.argv[2];
    if (bump === "major") console.log(`${major + 1}.0.0`);
    else if (bump === "minor") console.log(`${major}.${minor + 1}.0`);
    else console.log(`${major}.${minor}.${patch + 1}`);
  ' "$current" "$bump")"
  branch="release/v$next"
  git show-ref --verify --quiet "refs/heads/$branch" && die "Local branch already exists: $branch"
  gh pr list --repo "$REPO" --head "$branch" --state all --json url --jq '.[0].url' | grep -q . && die "A release PR already exists for $branch"
  git switch -c "$branch"
  test "$(node scripts/bump-version.mjs "$bump")" = "$next"
  git add package.json src-tauri/Cargo.toml src-tauri/tauri.conf.json
  npm test
  bash -n release.sh scripts/bootstrap.sh scripts/release-preflight.sh
  git commit -m "chore: prepare EAI Setup v$next"
  git push --set-upstream origin "$branch"
  gh pr create --repo "$REPO" --base main --head "$branch" --title "chore: release EAI Setup v$next" --body "## Release preparation\n\n$bump release: $current -> $next\n\nThe merged release will run the published-asset VM gate through \`release.sh publish $next\`.\n\nRelease notes: $message"
}

publish_release() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "publish requires MAJOR.MINOR.PATCH"
  require_command git
  require_command node
  require_command gh
  cd "$ROOT"
  ensure_clean_main
  [[ "$(version_from_source)" == "$version" ]] || die "package.json is $(version_from_source), not $version"
  local tag="v$version"
  git show-ref --verify --quiet "refs/tags/$tag" && die "Local tag already exists: $tag"
  git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && die "Remote tag already exists: $tag"
  npm test
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" --tag "$tag" --driver "${EAI_VM_DRIVER:-command}" --deprovision "${EAI_DEPROVISION_MODE:-api}" --preflight
  git tag -a "$tag" -m "EAI Setup v$version"
  git push origin "$tag"
  wait_for_release_workflow "$tag"
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" --tag "$tag" --driver "${EAI_VM_DRIVER:-command}" --deprovision "${EAI_DEPROVISION_MODE:-api}"
}

run_e2e() {
  local version="$1"
  shift
  require_command node
  cd "$ROOT"
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" "$@"
}

command="${1:-}"
case "$command" in
  patch|minor|major)
    prepare_release "$command" "${2:-}"
    ;;
  publish)
    [[ -n "${2:-}" ]] || { usage; exit 2; }
    publish_release "$2"
    ;;
  e2e)
    [[ -n "${2:-}" ]] || { usage; exit 2; }
    version="$2"
    shift 2
    run_e2e "$version" "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
