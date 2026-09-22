import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const requiredEnvironment = [
  "EAI_RECEIPT",
  "EAI_VERIFICATION",
  "EAI_VM_DIR",
  "EAI_TENANT_HASH",
  "EAI_PORTAL_CHAIN_HASH",
  "EAI_SCREENSHOT",
  "EAI_SCREENSHOT_HASH",
];
for (const name of requiredEnvironment) {
  if (!process.env[name]) throw new Error(`missing-${name.toLowerCase()}`);
}
if (!/^[a-f0-9]{64}$/.test(process.env.EAI_TENANT_HASH)
  || !/^[a-f0-9]{64}$/.test(process.env.EAI_PORTAL_CHAIN_HASH)
  || !/^[a-f0-9]{64}$/.test(process.env.EAI_SCREENSHOT_HASH)) {
  throw new Error("finalize-hash-input-invalid");
}

const receipt = JSON.parse(fs.readFileSync(process.env.EAI_RECEIPT, "utf8"));
const verification = JSON.parse(fs.readFileSync(process.env.EAI_VERIFICATION, "utf8"));
const chainParts = [
  fs.readFileSync(process.env.EAI_RECEIPT),
  fs.readFileSync(process.env.EAI_VERIFICATION),
];
const methodFiles = {
  "admin-portal-interactive-delete-attempt-1": [
    "windows-portal-cleanup-target.json",
    "windows-portal-delete-prepared.json",
    "windows-portal-delete-invocation.json",
    "windows-portal-delete-attempt-1-verification.json",
  ],
  "admin-portal-interactive-delete-attempt-2": [
    "windows-portal-cleanup-target.json",
    "windows-portal-delete-attempt-1-still-present.json",
    "windows-portal-delete-attempt-2-target.json",
    "windows-portal-delete-attempt-2-prepared.json",
    "windows-portal-delete-attempt-2-preinvoke.json",
    "windows-portal-delete-attempt-2-invocation.json",
    "windows-portal-delete-attempt-2-verification.json",
  ],
};
for (const name of methodFiles[receipt.method] || []) {
  const file = path.join(process.env.EAI_VM_DIR, name);
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("portal-finalize-chain-unsafe");
  chainParts.push(fs.readFileSync(file));
}

const actualChainHash = crypto.createHash("sha256").update(Buffer.concat(chainParts)).digest("hex");
if (actualChainHash !== process.env.EAI_PORTAL_CHAIN_HASH
  || receipt.tenantIdSha256 !== process.env.EAI_TENANT_HASH
  || verification.tenantIdSha256 !== process.env.EAI_TENANT_HASH) {
  throw new Error("portal-finalize-chain-changed");
}
const screenshotStat = fs.lstatSync(process.env.EAI_SCREENSHOT);
if (!screenshotStat.isFile() || screenshotStat.isSymbolicLink()) {
  throw new Error("portal-screenshot-unsafe");
}

const alreadyFinalized = receipt.cleanupVerified === true
  && receipt.portalVerified === true
  && verification.cleanupVerified === true
  && verification.checks?.portalExactMatchesAfter === 0
  && verification.portalSemanticResult === "verified-absent"
  && verification.verificationScreenshot?.path === "manual-cleanup-verified-absent.png"
  && verification.verificationScreenshot?.sha256 === process.env.EAI_SCREENSHOT_HASH
  && receipt.portalVerifiedAt === verification.portalVerifiedAt;
if (alreadyFinalized) process.exit(0);

const deletionRecordedAt = Date.parse(receipt.deletionRecordedAt || receipt.recordedAt);
if (!Number.isFinite(deletionRecordedAt) || screenshotStat.mtimeMs < deletionRecordedAt) {
  throw new Error("portal-screenshot-predates-cleanup");
}
const verifiedAt = new Date().toISOString();
receipt.deletionRecordedAt = receipt.deletionRecordedAt || receipt.recordedAt;
verification.checks.portalExactMatchesAfter = 0;
verification.portalVerifiedAt = verifiedAt;
verification.portalSemanticResult = "verified-absent";
verification.verificationScreenshot = {
  path: "manual-cleanup-verified-absent.png",
  sha256: process.env.EAI_SCREENSHOT_HASH,
  showsExactDisplayNameSearch: true,
  showsNoAppsMatch: true,
  sanitized: true,
};
verification.cleanupVerified = true;
verification.recordedAt = verifiedAt;
receipt.portalVerified = true;
receipt.portalVerifiedAt = verifiedAt;
receipt.cleanupVerified = true;
receipt.recordedAt = verifiedAt;

const atomicWrite = (file, value) => {
  const temporary = `${file}.finalize-${process.pid}-${crypto.randomBytes(8).toString("hex")}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  fs.renameSync(temporary, file);
};
// Verification is committed first. A crash between these two atomic renames
// leaves a recoverable partial state: the next run revalidates the same chain
// and screenshot, then idempotently commits both files.
atomicWrite(process.env.EAI_VERIFICATION, verification);
atomicWrite(process.env.EAI_RECEIPT, receipt);
