[CmdletBinding()]
param(
  [string]$ProjectName,
  [string]$Directory,
  [switch]$CurrentDir,
  [switch]$AutoInstall
)

$ErrorActionPreference = "Stop"

function Has-Command([string]$Name) {
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Require-AutoInstall([string]$Name) {
  if (-not $AutoInstall) {
    throw "Missing $Name. Re-run this script with -AutoInstall after reviewing the fixed WinGet steps."
  }
}

if (-not (Has-Command "git")) {
  Require-AutoInstall "Git"
  if (-not (Has-Command "winget")) { throw "WinGet is unavailable. Install or enable Microsoft's App Installer, then rerun EAI Setup." }
  winget install --id Git.Git -e --source winget --accept-source-agreements --accept-package-agreements
}

if (-not (Has-Command "node") -or -not (Has-Command "npm")) {
  Require-AutoInstall "Node.js"
  if (-not (Has-Command "winget")) { throw "WinGet is unavailable. Install or enable Microsoft's App Installer, then rerun EAI Setup." }
  winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-source-agreements --accept-package-agreements
}

if (-not (Has-Command "node") -or -not (Has-Command "npm")) {
  throw "Node.js and npm are required. Restart PowerShell after WinGet updates PATH, then rerun."
}

$nodeMajor = [int]((node -p "process.versions.node.split('.')[0]").Trim())
if ($nodeMajor -lt 24) { throw "Node.js 24 or newer is required." }

if (-not (Has-Command "eai")) {
  Require-AutoInstall "EAI CLI"
  npm install --global @enterpriseai/cli
}

Write-Host (git --version)
Write-Host (node --version)
Write-Host (npm --version)
Write-Host (eai --version)

if ($ProjectName) {
  if ($ProjectName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw "Project name must be kebab-case." }
  if ($CurrentDir) {
    eai init $ProjectName --current-dir
  } else {
    if (-not $Directory) { $Directory = Join-Path (Get-Location) $ProjectName }
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    Push-Location $Directory
    try { eai init $ProjectName --current-dir } finally { Pop-Location }
  }
} else {
  Write-Host "Next: eai login, eai whoami, then eai init <project-name>."
}
