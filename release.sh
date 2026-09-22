#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${EAI_INSTALLER_REPO:-eai-support/eai-installer}"

usage() {
  cat <<'EOF'
Usage:
  ./release.sh <patch|minor|major> [message]
  ./release.sh publish <version>
  ./release.sh publish-test <version>
  ./release.sh publish-diagnostic <version>  # disabled fail-closed
  ./release.sh e2e <version>
  ./release.sh diagnostic-e2e <version>

The version commands create a release PR. They never push directly to main.
After that PR is merged, `publish` tags the merged version, waits for the
GitHub release workflow, downloads the exact release assets, and runs the VM
end-to-end gate.

Examples:
  ./release.sh patch "Improve clean-machine bootstrap"
  ./release.sh minor "Add release VM gate"
  ./release.sh publish 0.2.0
  ./release.sh publish-test 0.3.5
  ./release.sh diagnostic-e2e 0.3.0
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

wait_for_test_release_workflow() {
  local started_at="$1"
  local run_id=""
  for _ in $(seq 1 60); do
    run_id="$(gh run list --repo "$REPO" --workflow test-release.yml --event workflow_dispatch --limit 20 --json databaseId,createdAt,headBranch --jq ".[] | select(.headBranch == \"main\" and .createdAt >= \"$started_at\") | .databaseId" | head -n 1)"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || die "Could not find the test release workflow run"
  gh run watch "$run_id" --repo "$REPO" --exit-status
}

wait_for_release_readiness_workflow() {
  local version="$1"
  local nonce="$2"
  local started_at="$3"
  local expected_sha="$4"
  local run_id=""
  local expected_title="Release readiness v$version ($nonce)"
  for _ in $(seq 1 60); do
    run_id="$(gh run list --repo "$REPO" --workflow release-readiness.yml --event workflow_dispatch --limit 20 --json databaseId,createdAt,headBranch,headSha,displayTitle --jq ".[] | select(.headBranch == \"main\" and .headSha == \"$expected_sha\" and .displayTitle == \"$expected_title\" and .createdAt >= \"$started_at\") | .databaseId" | head -n 1)"
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || die "Could not find the protected release-readiness workflow for v$version"
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
  # shellcheck disable=SC2016 # JavaScript template literals are intentionally quoted from the shell.
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
  [[ "$REPO" == "eai-support/eai-installer" ]] || die "Production publish is bound to eai-support/eai-installer"
  [[ "$(version_from_source)" == "$version" ]] || die "package.json is $(version_from_source), not $version"
  local tag="v$version"
  git show-ref --verify --quiet "refs/tags/$tag" && die "Local tag already exists: $tag"
  git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && die "Remote tag already exists: $tag"
  npm test
  local canonical_deprovision="$ROOT/scripts/run-v4-app-deprovision.sh"
  if [[ -n "${EAI_APP_DEPROVISION_COMMAND:-}" && "$EAI_APP_DEPROVISION_COMMAND" != "$canonical_deprovision" ]]; then
    die "Production publish only accepts the repository V4 deprovision adapter"
  fi
  export EAI_APP_DEPROVISION_COMMAND="$canonical_deprovision"
  local canonical_macos="$ROOT/scripts/run-macos-guest-test.sh"
  local canonical_windows="$ROOT/scripts/run-windows-guest-test.sh"
  local canonical_ubuntu="$ROOT/scripts/run-ubuntu-guest-test.sh"
  [[ -z "${EAI_VM_MACOS_COMMAND:-}" || "$EAI_VM_MACOS_COMMAND" == "$canonical_macos" ]] \
    || die "Production publish only accepts the repository macOS VM adapter"
  [[ -z "${EAI_VM_WINDOWS_COMMAND:-}" || "$EAI_VM_WINDOWS_COMMAND" == "$canonical_windows" ]] \
    || die "Production publish only accepts the repository Windows VM adapter"
  [[ -z "${EAI_VM_UBUNTU_COMMAND:-}" || "$EAI_VM_UBUNTU_COMMAND" == "$canonical_ubuntu" ]] \
    || die "Production publish only accepts the repository Ubuntu VM adapter"
  export EAI_VM_MACOS_COMMAND="$canonical_macos"
  export EAI_VM_WINDOWS_COMMAND="$canonical_windows"
  export EAI_VM_UBUNTU_COMMAND="$canonical_ubuntu"
  if [[ "$(uname -s)" == Darwin ]]; then
    # Keep tenant identity in the protected host Keychain while making the
    # normal production command use the same source as the diagnostic wrapper.
    source "$ROOT/scripts/load-release-e2e-keychain.sh"
  fi
  unset EAI_RELEASE_MACOS_ASSET EAI_RELEASE_WINDOWS_ASSET EAI_RELEASE_UBUNTU_ASSET
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" --tag "$tag" --driver command --vms macos,windows,ubuntu --deprovision api --preflight

  local readiness_started_at
  local readiness_nonce
  local readiness_commit
  readiness_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  readiness_nonce="$version-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  readiness_commit="$(git rev-parse HEAD)"
  section "Checking protected signing readiness before tagging"
  gh workflow run release-readiness.yml --repo "$REPO" --ref main \
    --field "version=$version" \
    --field "nonce=$readiness_nonce"
  wait_for_release_readiness_workflow "$version" "$readiness_nonce" "$readiness_started_at" "$readiness_commit"

  git tag -a "$tag" -m "EAI Setup v$version"
  git push origin "$tag"
  wait_for_release_workflow "$tag"
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" --tag "$tag" --driver command --vms macos,windows,ubuntu --deprovision api
  section "Publishing the verified customer release"
  gh release edit "$tag" --repo "$REPO" --draft=false --latest
  echo "Customer release published: https://github.com/$REPO/releases/tag/$tag"
}

publish_test_release() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "publish-test requires MAJOR.MINOR.PATCH"
  require_command node
  require_command gh
  cd "$ROOT"
  ensure_clean_main
  [[ "$(version_from_source)" == "$version" ]] || die "package.json is $(version_from_source), not $version"
  local diagnostic_vm="${EAI_RELEASE_VMS:-}"
  [[ "$diagnostic_vm" =~ ^(macos|windows|ubuntu)$ ]] \
    || die "publish-test requires one explicit EAI_RELEASE_VMS value: macos, windows, or ubuntu"
  npm test
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" --tag "eai-setup-test-v$version" --driver "${EAI_VM_DRIVER:-command}" --vms "$diagnostic_vm" --deprovision mock --diagnostic --preflight

  local started_at
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  section "Publishing controlled test installers to GitHub"
  gh workflow run test-release.yml --repo "$REPO" --ref main --field "version=$version"
  wait_for_test_release_workflow "$started_at"

  section "Running guest E2E against the published test installers"
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" --tag "eai-setup-test-v$version" --driver "${EAI_VM_DRIVER:-command}" --vms "$diagnostic_vm" --deprovision mock --diagnostic
}

publish_diagnostic_release() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "publish-diagnostic requires MAJOR.MINOR.PATCH"
  die "publish-diagnostic is disabled because diagnostic cleanup cannot authorize a production v* tag; use publish-test"
}

run_e2e() {
  local version="$1"
  shift
  require_command node
  cd "$ROOT"
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" "$@"
}

run_diagnostic_e2e() {
  local version="$1"
  shift
  require_command node
  cd "$ROOT"
  node scripts/release-e2e.mjs --version "$version" --repo "$REPO" "$@" --driver command --deprovision mock --diagnostic
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
  publish-test)
    [[ -n "${2:-}" ]] || { usage; exit 2; }
    publish_test_release "$2"
    ;;
  publish-diagnostic)
    [[ -n "${2:-}" ]] || { usage; exit 2; }
    publish_diagnostic_release "$2"
    ;;
  e2e)
    [[ -n "${2:-}" ]] || { usage; exit 2; }
    version="$2"
    shift 2
    run_e2e "$version" "$@"
    ;;
  diagnostic-e2e)
    [[ -n "${2:-}" ]] || { usage; exit 2; }
    version="$2"
    shift 2
    run_diagnostic_e2e "$version" "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
