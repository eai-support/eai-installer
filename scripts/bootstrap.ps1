[CmdletBinding()]
param(
  [string]$ProjectName,
  [string]$Directory,
  [switch]$CurrentDir,
  [switch]$AutoInstall
)

$ErrorActionPreference = "Stop"
$script:EaiCliVersion = $null

function Has-Command([string]$Name) {
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Require-AutoInstall([string]$Name) {
  if (-not $AutoInstall) {
    throw "Missing $Name. Re-run this script with -AutoInstall after reviewing the fixed WinGet steps."
  }
}

function Has-HelpOption([string]$Text, [string]$Option) {
  $pattern = '(?:^|\s)' + [regex]::Escape($Option) + '(?:[=\s]|$)'
  return $Text -cmatch $pattern
}

function Has-EaiManagedDeploy {
  if (-not (Has-Command "eai")) { return $false }
  $rawVersion = & eai --version 2>$null | Select-Object -First 1
  if (-not $rawVersion) { return $false }
  $versionOutput = ([string]$rawVersion).Trim()
  $script:EaiCliVersion = $versionOutput
  if ($versionOutput -notmatch '^v?(\d+)\.(\d+)\.(\d+)') { return $false }
  $currentVersion = [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
  if ($currentVersion -lt [version]::new(3, 17, 0)) { return $false }
  $deployHelp = & eai deploy app --help 2>$null
  if ($LASTEXITCODE -ne 0) { return $false }
  $helpText = $deployHelp -join "`n"
  return (Has-HelpOption $helpText "--source") `
    -and (Has-HelpOption $helpText "--github-link-session") `
    -and (Has-HelpOption $helpText "--target-tenant-id")
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

$eaiManagedDeployReady = Has-EaiManagedDeploy
if (-not $eaiManagedDeployReady) {
  if ((Has-Command "eai") -and -not $AutoInstall) {
    throw "The installed EAI CLI is incompatible. EAI Setup requires version 3.17.0 or newer with source choice, GitHub-link handoff, and target-tenant binding. Re-run with -AutoInstall to update it."
  }
  Require-AutoInstall "EAI CLI"
  npm install --global @enterpriseai/cli
  $eaiManagedDeployReady = Has-EaiManagedDeploy
}

if (-not $eaiManagedDeployReady) {
  throw "The installed EAI CLI is incompatible. EAI Setup requires version 3.17.0 or newer with source choice, GitHub-link handoff, and target-tenant binding."
}

Write-Host (git --version)
Write-Host (node --version)
Write-Host (npm --version)
Write-Host $script:EaiCliVersion

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
  Write-Host "Next: eai login, eai whoami, then eai init <project-name>. Use 'eai deploy app --help' when you are ready to choose hosting. EAI hosting verifies your linked GitHub identity, then offers EAI-maintained or customer-owned source."
}
