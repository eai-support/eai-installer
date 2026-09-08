#!/usr/bin/env bash

set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'V4 app deprovision failed: %s\n' "$*" >&2
  exit 1
}

mode="${1:-run}"
[[ "$#" -le 1 ]] || fail "pass either no argument or --preflight."
[[ "$mode" == "run" || "$mode" == "--preflight" ]] \
  || fail "the only supported argument is --preflight."

tenant_id="${EAI_DEPROVISION_TENANT_ID:-}"
tenant_name="${EAI_DEPROVISION_TENANT_NAME:-}"
app_name="${EAI_DEPROVISION_APP_NAME:-}"
confirmation="${EAI_DEPROVISION_CONFIRM:-}"
app_created="${EAI_DEPROVISION_APP_CREATED:-}"
run_id="${EAI_DEPROVISION_RUN_ID:-}"
receipt_file="${EAI_DEPROVISION_RECEIPT_FILE:-}"
api_origin="${EAI_DEPROVISION_API_ORIGIN:-https://api.au.myenterprise.ai/public}"

[[ "$tenant_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  || fail "EAI_DEPROVISION_TENANT_ID must be the protected tenant UUID."
[[ -n "$tenant_name" && ${#tenant_name} -le 256 ]] \
  || fail "EAI_DEPROVISION_TENANT_NAME is required."
api_origin="${api_origin%/}"
[[ "$api_origin" =~ ^https://api\.(au|ca|eu)\.myenterprise\.ai/public$ ]] \
  || fail "EAI_DEPROVISION_API_ORIGIN must be an approved regional PublicAPI origin."
command -v node >/dev/null 2>&1 || fail "Node.js is required to validate V4 receipts."

eai_candidate="${EAI_DEPROVISION_EAI_BIN:-$(command -v eai 2>/dev/null || true)}"
[[ -n "$eai_candidate" && "$eai_candidate" == /* ]] \
  || fail "The current EAI CLI is unavailable on PATH."
eai_bin="$(node -e 'const fs=require("node:fs"); try { process.stdout.write(fs.realpathSync(process.argv[1])); } catch { process.exit(1); }' "$eai_candidate" 2>/dev/null || true)"
[[ -n "$eai_bin" && "$eai_bin" == /* && -f "$eai_bin" && ! -L "$eai_bin" && -x "$eai_bin" ]] \
  || fail "The resolved EAI CLI is not a canonical executable file."

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/eai-v4-app-deprovision.XXXXXX")" \
  || fail "Could not create the private validation directory."
receipt_tmp=""

# CLI 3.15.10 requires authenticated resource and app commands to run from a
# recognized EAI project. Keep release cleanup isolated from whichever source
# repository launched it by supplying a private, empty project marker.
: >"$work_dir/eai.config.ts"
cd "$work_dir" || fail "Could not enter the private validation directory."

cleanup() {
  if [[ -n "$receipt_tmp" ]]; then
    rm -f -- "$receipt_tmp"
  fi
  rm -rf -- "$work_dir"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cli_version_stderr="$work_dir/cli-version.stderr"
eai_version="$(EAI_PROFILE=default BASE_URL_PUBLIC_API="$api_origin" "$eai_bin" --cli-version 2>"$cli_version_stderr" || true)"
minimum_eai_version="$(node -e '
  const manifest = require(process.argv[1]);
  const item = manifest.prerequisites.find((entry) => entry.id === "eai-cli");
  if (!item || typeof item.minimumVersion !== "string") process.exit(1);
  process.stdout.write(item.minimumVersion);
' "$ROOT/installer-manifest.json" 2>/dev/null || true)"
[[ "$eai_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$minimum_eai_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "The EAI CLI version or installer minimum version is invalid."
node -e '
  const parse = (value) => value.split(".").map(Number);
  const [actual, minimum] = process.argv.slice(1).map(parse);
  for (let index = 0; index < 3; index += 1) {
    if (actual[index] > minimum[index]) process.exit(0);
    if (actual[index] < minimum[index]) process.exit(1);
  }
' "$eai_version" "$minimum_eai_version" \
  || fail "The resolved EAI CLI is older than the installer release contract."

api_origin_sha256="$(node -e 'const crypto=require("node:crypto"); process.stdout.write(crypto.createHash("sha256").update(process.argv[1]).digest("hex"));' "$api_origin")"

if [[ "$mode" == "--preflight" ]]; then
  delete_help="$work_dir/app-delete-help.txt"
  resources_help="$work_dir/resources-list-help.txt"
  readonly_json="$work_dir/readonly.json"
  readonly_stderr="$work_dir/readonly.stderr"

  EAI_PROFILE=default BASE_URL_PUBLIC_API="$api_origin" "$eai_bin" app delete --help >"$delete_help" 2>/dev/null \
    || fail "the EAI CLI app-deletion command is unavailable."
  for option in '--tenant-id' '--confirm' '--non-interactive' '--format'; do
    grep -Fq -- "$option" "$delete_help" \
      || fail "the EAI CLI app-deletion command is missing a required option."
  done
  EAI_PROFILE=default BASE_URL_PUBLIC_API="$api_origin" "$eai_bin" resources list --help >"$resources_help" 2>/dev/null \
    || fail "the EAI CLI resource-list command is unavailable."
  for option in '--tenant-id' '--where' '--format'; do
    grep -Fq -- "$option" "$resources_help" \
      || fail "the EAI CLI resource-list command is missing a required option."
  done

  if ! EAI_PROFILE=default BASE_URL_PUBLIC_API="$api_origin" "$eai_bin" resources list tenant-vertical-enrollment \
    --tenant-id "$tenant_id" \
    --page 1 \
    --limit 1 \
    --format json >"$readonly_json" 2>"$readonly_stderr"; then
    fail "the read-only V4 tenant authorization check failed."
  fi
  node --input-type=module - "$readonly_json" <<'NODE' \
    || fail "the read-only V4 tenant authorization response was malformed."
import fs from "node:fs";
const value = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (value === null || typeof value !== "object" || Array.isArray(value)
  || value.type !== "tenant-vertical-enrollment"
  || !Array.isArray(value.resources)
  || !Number.isSafeInteger(value.totalDocs)
  || value.totalDocs < 0
  || value.resources.length > 1
  || value.page !== 1
  || !Number.isSafeInteger(value.totalPages)
  || value.totalPages < 0
  || (value.nextCursor !== null && typeof value.nextCursor !== "string")) {
  process.exit(1);
}
NODE

  printf '{"schemaVersion":"eai.v4-deprovision-preflight.v1","status":"ready","eaiVersion":"%s","minimumEaiVersion":"%s","apiOriginSha256":"%s","tenantAuthorization":"verified-read-only","mutationAttempted":false}\n' \
    "$eai_version" "$minimum_eai_version" "$api_origin_sha256"
  exit 0
fi

[[ "$app_name" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] \
  || fail "EAI_DEPROVISION_APP_NAME is not an exact generated app key."
[[ "$confirmation" == "$app_name" ]] \
  || fail "EAI_DEPROVISION_CONFIRM must exactly match the generated app key."
[[ "$app_created" == "0" || "$app_created" == "1" ]] \
  || fail "EAI_DEPROVISION_APP_CREATED must be 0 or 1."
[[ "$run_id" =~ ^[0-9]{13}-[0-9a-f]{6}$ ]] \
  || fail "EAI_DEPROVISION_RUN_ID is invalid."
[[ "$receipt_file" == /* ]] \
  || fail "EAI_DEPROVISION_RECEIPT_FILE must be an absolute path."
[[ "$(basename "$receipt_file")" == "cleanup-receipt.json" ]] \
  || fail "The cleanup receipt must use the controller's exact filename."
[[ ! -e "$receipt_file" && ! -L "$receipt_file" ]] \
  || fail "The cleanup receipt path already exists or is unsafe."

receipt_parent="$(dirname "$receipt_file")"
[[ -d "$receipt_parent" && ! -L "$receipt_parent" ]] \
  || fail "The cleanup receipt parent must be a real directory."
receipt_parent="$(cd "$receipt_parent" && pwd -P)"
receipt_file="$receipt_parent/cleanup-receipt.json"

delete_json="$work_dir/delete.json"
delete_stderr="$work_dir/delete.stderr"
delete_summary="$work_dir/delete-summary.json"

if ! EAI_PROFILE=default BASE_URL_PUBLIC_API="$api_origin" "$eai_bin" app delete "$app_name" \
  --tenant-id "$tenant_id" \
  --confirm "$confirmation" \
  --non-interactive \
  --format json >"$delete_json" 2>"$delete_stderr"; then
  fail "the V4 deletion command did not return a verified receipt; no fallback was attempted."
fi

if ! node --input-type=module - "$delete_json" "$delete_summary" <<'NODE'
import fs from "node:fs";

const [inputPath, summaryPath] = process.argv.slice(2);
const expectedTenantId = process.env.EAI_DEPROVISION_TENANT_ID;
const expectedAppName = process.env.EAI_DEPROVISION_APP_NAME;
const isPlainObject = (value) => value !== null
  && typeof value === "object"
  && !Array.isArray(value)
  && Object.getPrototypeOf(value) === Object.prototype;
const hasExactKeys = (value, keys) => isPlainObject(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort());
const invalid = () => {
  throw new Error("invalid verified V4 deletion receipt");
};

let receipt;
try {
  receipt = JSON.parse(fs.readFileSync(inputPath, "utf8"));
} catch {
  invalid();
}

if (!hasExactKeys(receipt, [
  "schemaVersion", "operationId", "planHash", "tenantId", "appKey",
  "ownershipManifestHash", "status", "verified", "deleted", "retained", "steps",
])
  || receipt.schemaVersion !== "eai.app-deletion-receipt.v1"
  || receipt.status !== "deleted"
  || receipt.verified !== true
  || receipt.tenantId !== expectedTenantId
  || receipt.appKey !== expectedAppName
  || typeof receipt.operationId !== "string"
  || !/^[A-Za-z0-9._:-]{1,256}$/.test(receipt.operationId)
  || typeof receipt.planHash !== "string"
  || !/^[a-f0-9]{64}$/.test(receipt.planHash)
  || typeof receipt.ownershipManifestHash !== "string"
  || !/^[a-f0-9]{64}$/.test(receipt.ownershipManifestHash)
  || receipt.ownershipManifestHash !== receipt.planHash
  || !hasExactKeys(receipt.deleted, ["resourceAPI"])
  || !hasExactKeys(receipt.deleted.resourceAPI, ["resources"])
  || !Number.isSafeInteger(receipt.deleted.resourceAPI.resources)
  || receipt.deleted.resourceAPI.resources < 1
  || !hasExactKeys(receipt.retained, ["sharedObjectTypes"])
  || !Array.isArray(receipt.retained.sharedObjectTypes)
  || receipt.retained.sharedObjectTypes.some((value) => typeof value !== "string" || value.length < 1)
  || new Set(receipt.retained.sharedObjectTypes).size !== receipt.retained.sharedObjectTypes.length
  || !hasExactKeys(receipt.steps, ["resourceAPI"])
  || receipt.steps.resourceAPI !== "verified") {
  invalid();
}

fs.writeFileSync(summaryPath, `${JSON.stringify({
  operationId: receipt.operationId,
  planHash: receipt.planHash,
  ownershipManifestHash: receipt.ownershipManifestHash,
  resourceApiDeletedCount: receipt.deleted.resourceAPI.resources,
  retainedSharedObjectTypes: receipt.retained.sharedObjectTypes,
  resourceApiStep: receipt.steps.resourceAPI,
})}\n`, { mode: 0o600 });
NODE
then
  fail "the V4 deletion response was malformed, unverified, or did not match the exact tenant and app."
fi

where_json="{\"verticalKey\":\"$app_name\"}"
absence_types=(tenant-vertical-enrollment vertical-service-activation vertical-product-config)
absence_arguments=()
for resource_type in "${absence_types[@]}"; do
  absence_json="$work_dir/absence-$resource_type.json"
  absence_stderr="$work_dir/absence-$resource_type.stderr"
  if ! EAI_PROFILE=default BASE_URL_PUBLIC_API="$api_origin" "$eai_bin" resources list "$resource_type" \
    --tenant-id "$tenant_id" \
    --page 1 \
    --limit 2 \
    --where "$where_json" \
    --format json >"$absence_json" 2>"$absence_stderr"; then
    fail "an independent post-delete manifest-owned-resource absence query failed."
  fi
  absence_arguments+=("$resource_type" "$absence_json")
done

receipt_tmp="$(mktemp "$receipt_parent/.cleanup-receipt.json.XXXXXX")" \
  || fail "Could not create the private cleanup receipt."
chmod 600 "$receipt_tmp"

if ! EAI_DEPROVISION_API_ORIGIN_SHA256="$api_origin_sha256" \
  EAI_DEPROVISION_EAI_VERSION="$eai_version" \
  node --input-type=module - "$delete_summary" "$receipt_tmp" "${absence_arguments[@]}" <<'NODE'
import crypto from "node:crypto";
import fs from "node:fs";

const [summaryPath, outputPath, ...absenceArguments] = process.argv.slice(2);
const expectedTenantId = process.env.EAI_DEPROVISION_TENANT_ID;
const expectedAppName = process.env.EAI_DEPROVISION_APP_NAME;
const expectedConfirmation = process.env.EAI_DEPROVISION_CONFIRM;
const expectedApiOriginSha256 = process.env.EAI_DEPROVISION_API_ORIGIN_SHA256;
const expectedEaiVersion = process.env.EAI_DEPROVISION_EAI_VERSION;
const isPlainObject = (value) => value !== null
  && typeof value === "object"
  && !Array.isArray(value)
  && Object.getPrototypeOf(value) === Object.prototype;
const invalid = () => {
  throw new Error("ambiguous post-delete absence evidence");
};

let deletion;
try {
  deletion = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
} catch {
  invalid();
}

if (!isPlainObject(deletion)
  || typeof deletion.operationId !== "string"
  || !/^[A-Za-z0-9._:-]{1,256}$/.test(deletion.operationId)
  || typeof deletion.planHash !== "string"
  || !/^[a-f0-9]{64}$/.test(deletion.planHash)
  || deletion.ownershipManifestHash !== deletion.planHash
  || !Number.isSafeInteger(deletion.resourceApiDeletedCount)
  || deletion.resourceApiDeletedCount < 1
  || !Array.isArray(deletion.retainedSharedObjectTypes)
  || deletion.retainedSharedObjectTypes.some((value) => typeof value !== "string" || value.length < 1)
  || deletion.resourceApiStep !== "verified"
  || absenceArguments.length !== 6) {
  invalid();
}

const expectedTypes = [
  "tenant-vertical-enrollment",
  "vertical-service-activation",
  "vertical-product-config",
];
const exactMatchesByType = {};
for (let index = 0; index < absenceArguments.length; index += 2) {
  const resourceType = absenceArguments[index];
  if (resourceType !== expectedTypes[index / 2]) invalid();
  let absence;
  try {
    absence = JSON.parse(fs.readFileSync(absenceArguments[index + 1], "utf8"));
  } catch {
    invalid();
  }
  if (!isPlainObject(absence)
    || absence.type !== resourceType
    || !Array.isArray(absence.resources)
    || absence.resources.length !== 0
    || absence.totalDocs !== 0
    || absence.page !== 1
    || !Number.isSafeInteger(absence.totalPages)
    || absence.totalPages < 0
    || absence.totalPages > 1
    || absence.nextCursor !== null) {
    invalid();
  }
  exactMatchesByType[resourceType] = 0;
}

const receipt = {
  schemaVersion: "eai.release-e2e.cleanup-receipt.v1",
  status: "verified",
  source: "public-api-v4",
  operationId: deletion.operationId,
  appName: expectedAppName,
  appCreated: process.env.EAI_DEPROVISION_APP_CREATED === "1",
  confirmation: expectedConfirmation,
  tenantMatch: "verified",
  tenantIdSha256: crypto.createHash("sha256").update(expectedTenantId).digest("hex"),
  apiOriginSha256: expectedApiOriginSha256,
  eaiVersion: expectedEaiVersion,
  planHash: deletion.planHash,
  ownershipManifestHash: deletion.ownershipManifestHash,
  deletedRecords: {
    exactAppEnrollmentMatchesAfter: 0,
    exactFilteredTotalAfter: 0,
  },
  deletedResources: {
    serverReceiptSchemaVersion: "eai.app-deletion-receipt.v1",
    resourceApiDeletedCount: deletion.resourceApiDeletedCount,
    resourceApiStep: deletion.resourceApiStep,
    retainedSharedObjectTypes: deletion.retainedSharedObjectTypes,
  },
  absenceCheck: {
    method: "v4-filtered-manifest-owned-resource-queries",
    resourceTypes: expectedTypes,
    filterField: "verticalKey",
    exactMatchesByType,
    allManifestOwnedResourceTypesAbsent: true,
  },
  cleanupVerified: true,
};

fs.writeFileSync(outputPath, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
NODE
then
  fail "the independent post-delete query did not prove exact-app absence."
fi

[[ ! -e "$receipt_file" && ! -L "$receipt_file" ]] \
  || fail "The cleanup receipt path became unsafe before publication."
if ! ln "$receipt_tmp" "$receipt_file"; then
  fail "The cleanup receipt path became occupied before atomic publication."
fi
rm -f -- "$receipt_tmp"
receipt_tmp=""
printf 'Verified PublicAPI V4 app deprovision and exact-app absence.\n'
