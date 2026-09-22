#!/usr/bin/env bash

# Load only the non-password release-test identity values from the host
# Keychain. This file is intended to be sourced by release entry points.

[[ "$(uname -s)" == Darwin ]] || {
  printf 'Release E2E Keychain loader requires macOS.\n' >&2
  return 1 2>/dev/null || exit 1
}
command -v security >/dev/null 2>&1 || {
  printf 'The macOS Keychain command is unavailable.\n' >&2
  return 1 2>/dev/null || exit 1
}

account_service="${EAI_LOGIN_KEYCHAIN_SERVICE:-eai-installer-release-test-account}"
tenant_id_service="${EAI_TENANT_ID_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-id}"
tenant_name_service="${EAI_TENANT_NAME_KEYCHAIN_SERVICE:-eai-installer-release-test-tenant-name}"
keychain_account="${EAI_TENANT_KEYCHAIN_ACCOUNT:-release-e2e}"

test_email="$(/usr/bin/security find-generic-password -s "$account_service" 2>&1 \
  | /usr/bin/awk -F '"' '$2 == "acct" { print $4; exit }')"
tenant_id="$(/usr/bin/security find-generic-password -s "$tenant_id_service" -a "$keychain_account" -w 2>/dev/null || true)"
tenant_name="$(/usr/bin/security find-generic-password -s "$tenant_name_service" -a "$keychain_account" -w 2>/dev/null || true)"

[[ -n "$test_email" && "$test_email" != *[[:space:]]* ]] || {
  printf 'The release-test account is missing from the host Keychain.\n' >&2
  return 1 2>/dev/null || exit 1
}
[[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$ ]] || {
  printf 'The harness tenant ID is missing from the host Keychain.\n' >&2
  return 1 2>/dev/null || exit 1
}
[[ -n "$tenant_name" ]] || {
  printf 'The harness tenant name is missing from the host Keychain.\n' >&2
  return 1 2>/dev/null || exit 1
}

export EAI_HARNESS_USER_EMAIL="$test_email"
export EAI_HARNESS_TENANT_ID="$tenant_id"
export EAI_HARNESS_TENANT_NAME="$tenant_name"
