#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const workflowPath = path.join(root, ".github", "workflows", "release.yml");
const readinessWorkflowPath = path.join(root, ".github", "workflows", "release-readiness.yml");
const adapterPath = path.join(root, "scripts", "run-v4-app-deprovision.sh");
const workflow = fs.readFileSync(workflowPath, "utf8");
const readinessWorkflow = fs.readFileSync(readinessWorkflowPath, "utf8");
const adapter = fs.readFileSync(adapterPath, "utf8");

const section = (start, end) => {
  const startIndex = workflow.indexOf(start);
  const endIndex = workflow.indexOf(end, startIndex + start.length);
  assert.notEqual(startIndex, -1, `missing workflow section: ${start}`);
  assert.notEqual(endIndex, -1, `missing workflow boundary: ${end}`);
  return workflow.slice(startIndex, endIndex);
};

const windowsBuildJob = section("  build-windows:", "  release-windows:");
const windowsJob = section("  release-windows:", "  release-apple:");
const appleJob = section("  release-apple:", "  release-linux:");
const linuxJob = section("  release-linux:", "  publish-draft:");
const macBuild = section(
  "- name: Build notarized macOS bundle without publishing",
  "- name: Stage exact stable release asset",
);
const windowsBuild = section(
  "- name: Build Windows bundle without publishing",
  "- name: Stage exact unsigned Windows bundle",
);
const linuxBuild = section(
  "- name: Build Linux bundle without publishing",
  "- name: Stage exact stable release asset",
);
for (const build of [macBuild, windowsBuild, linuxBuild]) {
  assert.match(build, /uses: tauri-apps\/tauri-action@[a-f0-9]{40} # v1/);
  assert.doesNotMatch(build, /GITHUB_TOKEN|tagName:|releaseName:|releaseBody:|releaseDraft:|prerelease:|releaseId:/);
}
assert.doesNotMatch(windowsJob, /APPLE_CERTIFICATE|APPLE_PASSWORD|APPLE_API_PRIVATE_KEY/);
assert.doesNotMatch(windowsBuildJob, /id-token: write|environment: release|Azure\/login|artifact-signing-action|AZURE_SIGNING_SUBJECT/);
assert.doesNotMatch(linuxJob, /APPLE_CERTIFICATE|APPLE_PASSWORD|APPLE_API_PRIVATE_KEY|id-token: write|environment: release/);
assert.match(windowsJob, /permissions:\n      contents: read\n      id-token: write/);
assert.doesNotMatch(appleJob, /id-token: write|Azure\/login|artifact-signing-action/);
assert.equal((workflow.match(/uses: tauri-apps\/tauri-action@[a-f0-9]{40}/g) ?? []).length, 3);

const windowsDownloadIndex = windowsJob.indexOf("- name: Download exact unsigned Windows input");
const azureLoginIndex = windowsJob.indexOf("- name: Sign Windows installer with Azure Artifact Signing");
const azureSignIndex = windowsJob.indexOf("- name: Apply Windows Authenticode signature");
const stagingIndex = windowsJob.indexOf("- name: Stage exact stable release asset");
const verifyIndex = windowsJob.indexOf("- name: Verify exact version, PE architecture, Authenticode signer, and RFC3161 timestamp");
const artifactUploadIndex = windowsJob.indexOf("- name: Upload verified release asset to workflow storage");
const publisherIndex = workflow.indexOf("publish-draft:");
assert.ok(windowsDownloadIndex < azureLoginIndex);
assert.ok(azureLoginIndex < azureSignIndex);
assert.ok(azureSignIndex < stagingIndex);
assert.ok(stagingIndex < verifyIndex);
assert.ok(verifyIndex < artifactUploadIndex);
assert.ok(artifactUploadIndex > verifyIndex);

const staging = windowsJob.slice(stagingIndex, verifyIndex);
assert.match(staging, /Copy-Item -LiteralPath "unsigned-release\/\$\{\{ matrix[.]asset \}\}" -Destination "staged-release\/\$\{\{ matrix[.]asset \}\}"/);
const windowsVerification = windowsJob.slice(verifyIndex, artifactUploadIndex);
assert.match(windowsVerification, /Get-Item -LiteralPath "staged-release\/\$\{\{ matrix[.]asset \}\}"/);
assert.doesNotMatch(windowsVerification, /Get-ChildItem|Select-Object -First/);
assert.match(windowsVerification, /TimeStamperCertificate/);
assert.match(windowsVerification, /1[.]3[.]6[.]1[.]5[.]5[.]7[.]3[.]8/);
assert.match(windowsVerification, /AZURE_SIGNING_SUBJECT/);
assert.match(windowsVerification, /ProductVersion/);
assert.match(windowsVerification, /ToUInt16\(\$bytes, \$peOffset \+ 4\)/);
assert.match(windowsVerification, /matrix[.]pe_machine/);
assert.match(windowsBuildJob, /src-tauri\/target\/\$\{\{ matrix[.]target \}\}\/release\/bundle\/nsis/);
assert.match(appleJob, /hdiutil attach "\$dmg" -readonly -nobrowse/);
assert.match(appleJob, /CFBundleShortVersionString/);
assert.match(appleJob, /lipo -archs/);
assert.match(linuxJob, /dpkg-deb --field "\$package" Version/);
assert.match(linuxJob, /dpkg-deb --field "\$package" Architecture/);

const publisher = workflow.slice(publisherIndex);
assert.match(publisher, /needs: \[release-windows, release-apple, release-linux\]/);
assert.match(publisher, /actions\/download-artifact@[a-f0-9]{40} # v5/);
assert.match(publisher, /test "\$\{#actual\[@\]\}" -eq 6/);
assert.match(publisher, /gh release upload "\$tag" release-assets\/[*] --clobber/);
assert.match(publisher, /gh release create "\$tag"[\s\S]*--draft/);
assert.match(publisher, /sha256sum --check/);
assert.match(publisher, /git fetch --force --no-tags origin "refs\/tags\/\$tag:refs\/tags\/\$tag"/);
assert.match(publisher, /git rev-parse --verify "refs\/tags\/\$tag\^\{commit\}"/);
assert.ok(publisher.indexOf("git rev-parse --verify") < publisher.indexOf('gh release create "$tag"'));
assert.equal((workflow.match(/gh release upload/g) ?? []).length, 1);
assert.equal((workflow.match(/gh release create/g) ?? []).length, 1);
assert.match(workflow, /validate-readiness-provenance:/);
assert.match(workflow, /--workflow release-readiness[.]yml/);
assert.match(workflow, /--commit "\$workflow_commit"/);
assert.match(workflow, /--status success/);
assert.match(workflow, /no recent successful protected readiness run is bound to this version and commit/);

assert.match(readinessWorkflow, /workflow_dispatch:/);
assert.match(readinessWorkflow, /run-name: Release readiness v\$\{\{ inputs[.]version \}\}/);
assert.match(readinessWorkflow, /\$\{\{ inputs[.]nonce \}\}/);
assert.match(readinessWorkflow, /READINESS_NONCE/);
assert.match(readinessWorkflow, /^permissions:\n  contents: read$/m);
assert.match(readinessWorkflow, /apple-readiness:[\s\S]*runs-on: macos-latest[\s\S]*environment: release/);
assert.match(readinessWorkflow, /azure-readiness:[\s\S]*permissions:\n      contents: read\n      id-token: write/);
assert.match(readinessWorkflow, /readiness:[\s\S]*needs: \[apple-readiness, azure-readiness\]/);
assert.doesNotMatch(
  readinessWorkflow,
  /contents: write|gh release|git tag|git push|notarytool submit|az provider register|az role assignment create|az resource create/,
);
assert.match(readinessWorkflow, /openssl pkcs12/);
assert.match(readinessWorkflow, /openssl x509[^\n]*-checkend 604800/);
assert.match(readinessWorkflow, /certificate_common_name[\s\S]*APPLE_SIGNING_IDENTITY/);
assert.match(readinessWorkflow, /security verify-cert[\s\S]*-p codeSign -R ocsp -R require/);
assert.match(readinessWorkflow, /codesign --force --options runtime --timestamp/);
assert.match(readinessWorkflow, /grep -Eq '\^Timestamp='/);
assert.match(readinessWorkflow, /xcrun notarytool history/);
assert.match(readinessWorkflow, /uses: Azure\/login@[a-f0-9]{40} # v3/);
assert.match(readinessWorkflow, /Microsoft[.]CodeSigning\/codeSigningAccounts/);
assert.match(readinessWorkflow, /eai-installer-signing/);
assert.match(readinessWorkflow, /eai-installer-windows/);
assert.match(readinessWorkflow, /profileType/);
assert.match(readinessWorkflow, /identityValidationId/);
assert.match(readinessWorkflow, /certificate profile is not Active/);
assert.match(readinessWorkflow, /Artifact Signing Certificate Profile Signer/);
assert.match(readinessWorkflow, /AZURE_SIGNING_RESOURCE_GROUP/);
assert.match(readinessWorkflow, /AZURE_SIGNING_SUBJECT/);
assert.match(readinessWorkflow, /properties[.]accountUri !== "https:\/\/neu[.]codesigning[.]azure[.]net\/"/);
assert.match(readinessWorkflow, /signing account provisioning has not succeeded/);
assert.match(readinessWorkflow, /2837e146-70d7-4cfd-ad55-7efa6464f958/);
assert.match(readinessWorkflow, /profile has no valid identity-validation ID/);
assert.doesNotMatch(readinessWorkflow, /identityValidationId[^\n]*startsWith\("\/subscriptions\/"\)/);
assert.doesNotMatch(readinessWorkflow, /az provider show|az resource list|--include-groups/);
assert.match(readinessWorkflow, /No signing request was submitted/);
assert.match(readinessWorkflow, /post-tag Windows matrix signature is the authoritative Azure data-plane proof/);
assert.doesNotMatch(readinessWorkflow, /azure\/artifact-signing-action/);
assert.match(workflow, /echo "APPLE_API_KEY_PATH=\$RUNNER_TEMP\/AuthKey_\$\{APPLE_API_KEY\}[.]p8" >> "\$GITHUB_ENV"/);
assert.doesNotMatch(workflow, /APPLE_API_KEY_PATH: \$\{\{ runner[.]temp \}\}\/AuthKey_/);
for (const source of [workflow, readinessWorkflow]) {
  assert.doesNotMatch(
    source,
    /uses: (?:actions\/(?:checkout|setup-node|upload-artifact|download-artifact)|tauri-apps\/tauri-action|Azure\/(?:login|artifact-signing-action))@(?:v\d+|stable)/i,
  );
}

assert.match(adapter, /eai_candidate=.*command -v eai/);
assert.match(adapter, /--preflight/);
assert.match(adapter, /minimum_eai_version/);
assert.match(adapter, /BASE_URL_PUBLIC_API="\$api_origin"/);
assert.match(adapter, /app delete "\$app_name"/);
assert.match(adapter, /resources list tenant-vertical-enrollment/);
assert.match(adapter, /--where "\$where_json"/);
assert.match(adapter, /receipt[.]schemaVersion !== "eai[.]app-deletion-receipt[.]v1"/);
assert.match(adapter, /receipt[.]tenantId !== expectedTenantId/);
assert.match(adapter, /receipt[.]appKey !== expectedAppName/);
assert.match(adapter, /receipt[.]verified !== true/);
assert.match(adapter, /receipt[.]ownershipManifestHash !== receipt[.]planHash/);
assert.match(adapter, /hasExactKeys\(receipt[.]deleted, \["resourceAPI"\]\)/);
assert.match(adapter, /vertical-service-activation/);
assert.match(adapter, /vertical-product-config/);
assert.match(adapter, /absence[.]totalDocs !== 0/);
assert.match(adapter, /source: "public-api-v4"/);
assert.match(adapter, /schemaVersion: "eai[.]release-e2e[.]cleanup-receipt[.]v1"/);
assert.match(adapter, /apiOriginSha256/);
assert.match(adapter, /eaiVersion/);
assert.match(adapter, /cleanupVerified: true/);
assert.doesNotMatch(adapter, /windows-diagnostic-cleanup|portal|resources delete|curl .*DELETE/i);
assert.match(adapter, /ln "\$receipt_tmp" "\$receipt_file"/);
assert.doesNotMatch(adapter, /mv -- "\$receipt_tmp" "\$receipt_file"/);

const syntax = spawnSync("bash", ["-n", adapterPath], { cwd: root, encoding: "utf8" });
assert.equal(syntax.status, 0, syntax.stderr);

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "eai-v4-adapter-test-"));
const fixtureBin = path.join(fixtureRoot, "bin");
fs.mkdirSync(fixtureBin, { recursive: true });
const fakeEai = path.join(fixtureBin, "eai");
const fakeLn = path.join(fixtureBin, "ln");

fs.writeFileSync(fakeEai, `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
const mode = process.env.EAI_V4_FIXTURE_MODE || "success";
if (args[0] === "--cli-version") {
  process.stdout.write(mode === "old-cli" ? "3.15.9\\n" : "3.15.10\\n");
  process.exit(0);
}
if (args.includes("--help")) {
  if (args[0] === "app" && args[1] === "delete") {
    process.stdout.write("--tenant-id --confirm --non-interactive --format\\n");
    process.exit(0);
  }
  if (args[0] === "resources" && args[1] === "list") {
    process.stdout.write("--tenant-id --where --format\\n");
    process.exit(0);
  }
}
fs.appendFileSync(process.env.EAI_V4_FIXTURE_LOG, JSON.stringify(args) + "\\n");

if (args[0] === "app" && args[1] === "delete") {
  if (mode === "no-plan") {
    process.stderr.write("404 deletion-plan for " + process.env.EAI_DEPROVISION_TENANT_ID + " "
      + process.env.EAI_DEPROVISION_APP_NAME + " " + process.env.EAI_DEPROVISION_TENANT_NAME + "\\n");
    process.exit(7);
  }
  const receipt = {
    schemaVersion: "eai.app-deletion-receipt.v1",
    operationId: "appdel-fixture-operation",
    planHash: "a".repeat(64),
    ownershipManifestHash: "a".repeat(64),
    tenantId: process.env.EAI_DEPROVISION_TENANT_ID,
    appKey: process.env.EAI_DEPROVISION_APP_NAME,
    status: "deleted",
    verified: true,
    deleted: { resourceAPI: { resources: 3 } },
    retained: { sharedObjectTypes: [] },
    steps: { resourceAPI: "verified" },
  };
  if (mode === "wrong-tenant") receipt.tenantId = "00000000-0000-4000-8000-000000000099";
  if (mode === "wrong-app") receipt.appKey = "another-app";
  if (mode === "unverified") receipt.verified = false;
  if (mode === "empty-deleted") receipt.deleted = {};
  if (mode === "unverified-step") receipt.steps.resourceAPI = "pending";
  if (mode === "bad-plan") receipt.planHash = "not-a-manifest-hash";
  if (mode === "missing-manifest") delete receipt.ownershipManifestHash;
  if (mode === "mismatched-manifest") receipt.ownershipManifestHash = "b".repeat(64);
  if (mode === "zero-resources") receipt.deleted.resourceAPI.resources = 0;
  if (mode === "bad-retained") receipt.retained = {};
  if (mode === "extra-receipt-key") receipt.unexpected = true;
  process.stdout.write(JSON.stringify(receipt));
  process.exit(0);
}

if (args[0] === "resources" && args[1] === "list") {
  if (mode === "absence-fail") {
    process.stderr.write("query failed for " + process.env.EAI_DEPROVISION_TENANT_ID + "\\n");
    process.exit(8);
  }
  const result = {
    type: args[2],
    resources: [],
    totalDocs: 0,
    page: 1,
    totalPages: 0,
    nextCursor: null,
  };
  if (mode === "absence-present") {
    result.resources = [{ id: "fixture", data: { verticalKey: process.env.EAI_DEPROVISION_APP_NAME } }];
    result.totalDocs = 1;
    result.totalPages = 1;
  }
  if (mode === "absence-ambiguous") result.nextCursor = "another-page";
  process.stdout.write(JSON.stringify(result));
  process.exit(0);
}

process.exit(9);
`);
fs.chmodSync(fakeEai, 0o700);
fs.writeFileSync(fakeLn, `#!/usr/bin/env bash
set -euo pipefail
if [[ "\${EAI_V4_FIXTURE_INJECT_RECEIPT_RACE:-0}" == 1 ]]; then
  printf 'occupied-by-race-fixture\n' > "\$2"
fi
exec /bin/ln "\$@"
`);
fs.chmodSync(fakeLn, 0o700);

const tenantId = "12345678-1234-4abc-8def-1234567890ab";
const tenantName = "Protected Fixture Tenant";
const appName = "test-macos-1788430000000-abc123";
const baseEnvironment = {
  ...process.env,
  PATH: `${fixtureBin}${path.delimiter}${process.env.PATH ?? ""}`,
  EAI_DEPROVISION_TENANT_ID: tenantId,
  EAI_DEPROVISION_TENANT_NAME: tenantName,
  EAI_DEPROVISION_APP_NAME: appName,
  EAI_DEPROVISION_CONFIRM: appName,
  EAI_DEPROVISION_APP_CREATED: "1",
  EAI_DEPROVISION_RUN_ID: "1788430000000-abc123",
  EAI_DEPROVISION_API_ORIGIN: "https://api.au.myenterprise.ai/public",
};

const runFixture = (name, mode = "success", overrides = {}) => {
  const directory = path.join(fixtureRoot, name);
  fs.mkdirSync(directory);
  const receipt = path.join(directory, "cleanup-receipt.json");
  const log = path.join(directory, "calls.jsonl");
  const result = spawnSync("bash", [adapterPath], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...baseEnvironment,
      EAI_V4_FIXTURE_MODE: mode,
      EAI_V4_FIXTURE_LOG: log,
      EAI_DEPROVISION_RECEIPT_FILE: receipt,
      ...overrides,
    },
  });
  const calls = fs.existsSync(log)
    ? fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line))
    : [];
  return { result, receipt, calls };
};

try {
  const success = runFixture("success");
  assert.equal(success.result.status, 0, success.result.stderr);
  assert.ok(fs.existsSync(success.receipt));
  assert.doesNotMatch(success.result.stdout + success.result.stderr, new RegExp(tenantId));
  assert.doesNotMatch(success.result.stdout + success.result.stderr, new RegExp(tenantName));
  assert.equal(success.calls.length, 4);
  assert.deepEqual(success.calls[0], [
    "app", "delete", appName,
    "--tenant-id", tenantId,
    "--confirm", appName,
    "--non-interactive",
    "--format", "json",
  ]);
  assert.deepEqual(success.calls.slice(1).map((call) => call.slice(0, 3)), [
    ["resources", "list", "tenant-vertical-enrollment"],
    ["resources", "list", "vertical-service-activation"],
    ["resources", "list", "vertical-product-config"],
  ]);
  const whereIndex = success.calls[1].indexOf("--where");
  assert.notEqual(whereIndex, -1);
  assert.deepEqual(JSON.parse(success.calls[1][whereIndex + 1]), { verticalKey: appName });
  const receipt = JSON.parse(fs.readFileSync(success.receipt, "utf8"));
  assert.deepEqual(receipt, {
    schemaVersion: "eai.release-e2e.cleanup-receipt.v1",
    status: "verified",
    source: "public-api-v4",
    operationId: "appdel-fixture-operation",
    appName,
    appCreated: true,
    confirmation: appName,
    tenantMatch: "verified",
    tenantIdSha256: crypto.createHash("sha256").update(tenantId).digest("hex"),
    apiOriginSha256: crypto.createHash("sha256").update("https://api.au.myenterprise.ai/public").digest("hex"),
    eaiVersion: "3.15.10",
    planHash: "a".repeat(64),
    ownershipManifestHash: "a".repeat(64),
    deletedRecords: {
      exactAppEnrollmentMatchesAfter: 0,
      exactFilteredTotalAfter: 0,
    },
    deletedResources: {
      serverReceiptSchemaVersion: "eai.app-deletion-receipt.v1",
      resourceApiDeletedCount: 3,
      resourceApiStep: "verified",
      retainedSharedObjectTypes: [],
    },
    absenceCheck: {
      method: "v4-filtered-manifest-owned-resource-queries",
      resourceTypes: [
        "tenant-vertical-enrollment",
        "vertical-service-activation",
        "vertical-product-config",
      ],
      filterField: "verticalKey",
      exactMatchesByType: {
        "tenant-vertical-enrollment": 0,
        "vertical-service-activation": 0,
        "vertical-product-config": 0,
      },
      allManifestOwnedResourceTypesAbsent: true,
    },
    cleanupVerified: true,
  });

  const preflightDirectory = path.join(fixtureRoot, "preflight");
  fs.mkdirSync(preflightDirectory);
  const preflightLog = path.join(preflightDirectory, "calls.jsonl");
  const preflight = spawnSync("bash", [adapterPath, "--preflight"], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...baseEnvironment,
      EAI_V4_FIXTURE_LOG: preflightLog,
      EAI_DEPROVISION_APP_NAME: "",
      EAI_DEPROVISION_CONFIRM: "",
      EAI_DEPROVISION_APP_CREATED: "",
      EAI_DEPROVISION_RUN_ID: "",
      EAI_DEPROVISION_RECEIPT_FILE: "",
    },
  });
  assert.equal(preflight.status, 0, preflight.stderr);
  const preflightResult = JSON.parse(preflight.stdout);
  assert.equal(preflightResult.schemaVersion, "eai.v4-deprovision-preflight.v1");
  assert.equal(preflightResult.status, "ready");
  assert.equal(preflightResult.mutationAttempted, false);
  const preflightCalls = fs.readFileSync(preflightLog, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.equal(preflightCalls.length, 1);
  assert.deepEqual(preflightCalls[0].slice(0, 3), ["resources", "list", "tenant-vertical-enrollment"]);
  assert.equal(preflightCalls.some((args) => args[0] === "app" && args[1] === "delete"), false);

  const oldCli = spawnSync("bash", [adapterPath, "--preflight"], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...baseEnvironment,
      EAI_V4_FIXTURE_MODE: "old-cli",
      EAI_V4_FIXTURE_LOG: path.join(preflightDirectory, "old-cli-calls.jsonl"),
    },
  });
  assert.notEqual(oldCli.status, 0);
  assert.match(oldCli.stderr, /older than the installer release contract/);

  const wrongOrigin = spawnSync("bash", [adapterPath, "--preflight"], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...baseEnvironment,
      EAI_DEPROVISION_API_ORIGIN: "https://example.invalid/public",
      EAI_V4_FIXTURE_LOG: path.join(preflightDirectory, "wrong-origin-calls.jsonl"),
    },
  });
  assert.notEqual(wrongOrigin.status, 0);
  assert.match(wrongOrigin.stderr, /approved regional PublicAPI origin/);

  const noPlan = runFixture("no-plan", "no-plan");
  assert.notEqual(noPlan.result.status, 0);
  assert.equal(fs.existsSync(noPlan.receipt), false);
  assert.equal(noPlan.calls.length, 1);
  assert.doesNotMatch(noPlan.result.stdout + noPlan.result.stderr, new RegExp(tenantId));
  assert.doesNotMatch(noPlan.result.stdout + noPlan.result.stderr, new RegExp(tenantName));

  for (const mode of [
    "wrong-tenant", "wrong-app", "unverified", "empty-deleted", "unverified-step",
    "bad-plan", "missing-manifest", "mismatched-manifest", "zero-resources",
    "bad-retained", "extra-receipt-key",
  ]) {
    const fixture = runFixture(mode, mode);
    assert.notEqual(fixture.result.status, 0, mode);
    assert.equal(fs.existsSync(fixture.receipt), false, mode);
    assert.equal(fixture.calls.length, 1, mode);
  }

  for (const mode of ["absence-present", "absence-ambiguous", "absence-fail"]) {
    const fixture = runFixture(mode, mode);
    assert.notEqual(fixture.result.status, 0, mode);
    assert.equal(fs.existsSync(fixture.receipt), false, mode);
    assert.equal(fixture.calls.length, mode === "absence-fail" ? 2 : 4, mode);
  }

  const mismatchedConfirmation = runFixture("mismatched-confirmation", "success", {
    EAI_DEPROVISION_CONFIRM: "another-app",
  });
  assert.notEqual(mismatchedConfirmation.result.status, 0);
  assert.equal(fs.existsSync(mismatchedConfirmation.receipt), false);
  assert.equal(mismatchedConfirmation.calls.length, 0);

  const occupiedAtPublish = runFixture("occupied-at-publish", "success", {
    EAI_V4_FIXTURE_INJECT_RECEIPT_RACE: "1",
  });
  assert.notEqual(occupiedAtPublish.result.status, 0);
  assert.equal(occupiedAtPublish.calls.length, 4);
  assert.equal(fs.readFileSync(occupiedAtPublish.receipt, "utf8"), "occupied-by-race-fixture\n");
  assert.match(occupiedAtPublish.result.stderr, /occupied before atomic publication/);
} finally {
  fs.rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log("production release safeguard checks ok");
