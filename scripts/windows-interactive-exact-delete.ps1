[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9+/]+={0,2}$')]
    [string]$AppKeyBase64,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9+/]+={0,2}$')]
    [string]$DisplayNameBase64,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9+/]+={0,2}$')]
    [string]$ExpectedGuestUserBase64,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$UiHelperSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string]$RunnerSha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$InvocationId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$resultPath = Join-Path $PSScriptRoot "windows-interactive-exact-delete-result-$InvocationId.json"
$uiHelper = Join-Path $PSScriptRoot 'windows-ui-action.ps1'
$stage = 'startup'
$mutationMayHaveOccurred = $false
$appName = ''
$displayName = ''
$exactExpectedUser = $false
$interactiveSessionId = $null
$interactiveSessionProven = $false
$explorerSessionMatched = $false
$explorerOwnerSidMatched = $false
$edgeUiBoundToInteractiveSession = $false
$edgeOwnerSidMatched = $false
$browserWindowHandle = $null
$browserProcessId = $null
$browserProcessSessionId = $null
$topLevelWindowRuntimeIdSha256 = ''
$dialogFinalRuntimeIdSha256 = ''
$sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke = $false
$exactBrowserWindowForegroundAtInvoke = $false

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Value)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
        )).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Write-DeleteResult {
    param([Parameter(Mandatory = $true)][hashtable]$Value)

    $Value.schemaVersion = 'eai.windows-interactive-exact-delete.v1'
    $Value.invocationId = $InvocationId
    $Value.uiHelperSha256 = $UiHelperSha256
    $Value.runnerSha256 = $RunnerSha256
    $Value.exactExpectedUser = $exactExpectedUser
    $Value.interactiveSessionId = $interactiveSessionId
    $Value.interactiveSessionProven = $interactiveSessionProven
    $Value.explorerSessionMatched = $explorerSessionMatched
    $Value.explorerOwnerSidMatched = $explorerOwnerSidMatched
    $Value.edgeUiBoundToInteractiveSession = $edgeUiBoundToInteractiveSession
    $Value.edgeOwnerSidMatched = $edgeOwnerSidMatched
    $Value.browserWindowHandle = $browserWindowHandle
    $Value.browserProcessId = $browserProcessId
    $Value.browserProcessSessionId = $browserProcessSessionId
    $Value.topLevelWindowRuntimeIdSha256 = $topLevelWindowRuntimeIdSha256
    $Value.dialogFinalRuntimeIdSha256 = $dialogFinalRuntimeIdSha256
    $Value.sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke = $sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke
    $Value.exactBrowserWindowForegroundAtInvoke = $exactBrowserWindowForegroundAtInvoke
    $Value.sanitized = $true
    $Value.diagnostic = $true
    $Value.productionGate = $false
    $Value.retryMutationAutomatically = $false
    $Value.recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $temporary = "$resultPath.tmp"
    if (Test-Path -LiteralPath $resultPath) {
        throw 'The unique interactive deletion result already exists.'
    }
    [IO.File]::WriteAllText(
        $temporary,
        (($Value | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::Move($temporary, $resultPath)
}

try {
    $stage = 'validate-interactive-session'
    try {
        $expectedGuestUser = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($ExpectedGuestUserBase64)
        )
    } catch {
        throw 'The expected guest username encoding is invalid.'
    }
    if ($expectedGuestUser -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw 'The expected guest username is invalid.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity -or $identity.IsSystem -or -not [Environment]::UserInteractive) {
        throw 'The deletion worker is not running as an interactive non-system user.'
    }
    $actualGuestUser = ([string]$identity.Name -split '\\')[-1]
    if (-not [string]::Equals(
        $actualGuestUser,
        $expectedGuestUser,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The deletion worker is not running as the exact expected guest user.'
    }
    $exactExpectedUser = $true
    $interactiveSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    if ($interactiveSessionId -le 0) {
        throw 'The deletion worker is not running in a real interactive session.'
    }
    $explorerProcesses = @(
        Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
            Where-Object { -not $_.HasExited -and $_.SessionId -eq $interactiveSessionId }
    )
    if ($explorerProcesses.Count -lt 1) {
        throw 'The deletion worker session has no matching interactive Explorer shell.'
    }
    foreach ($explorerProcess in $explorerProcesses) {
        $explorerCim = Get-CimInstance Win32_Process -Filter "ProcessId = $($explorerProcess.Id)" -ErrorAction Stop
        $explorerOwner = Invoke-CimMethod -InputObject $explorerCim -MethodName GetOwnerSid -ErrorAction Stop
        if ($explorerOwner.ReturnValue -eq 0 -and $explorerOwner.Sid -ceq $identity.User.Value) {
            $explorerOwnerSidMatched = $true
            break
        }
    }
    if (-not $explorerOwnerSidMatched) {
        throw 'The interactive Explorer shell is not owned by the exact expected user SID.'
    }
    $explorerSessionMatched = $true
    $interactiveSessionProven = $true

    $stage = 'validate-worker-integrity'
    $runnerItem = Get-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
    if ($runnerItem.PSIsContainer -or
        ($runnerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The interactive deletion worker is not a real file.'
    }
    $actualRunnerSha256 = (Get-FileHash -LiteralPath $runnerItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualRunnerSha256 -cne $RunnerSha256) {
        throw 'The interactive deletion worker hash changed after preparation.'
    }

    $stage = 'load-ui-helper'
    if (-not (Test-Path -LiteralPath $uiHelper -PathType Leaf)) {
        throw 'The protected Windows UI helper is unavailable.'
    }
    $uiHelperItem = Get-Item -LiteralPath $uiHelper -Force -ErrorAction Stop
    if ($uiHelperItem.PSIsContainer -or
        ($uiHelperItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected Windows UI helper is not a real file.'
    }
    $actualUiHelperSha256 = (Get-FileHash -LiteralPath $uiHelperItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualUiHelperSha256 -cne $UiHelperSha256) {
        throw 'The protected Windows UI helper hash changed after preparation.'
    }
    . $uiHelper
    $stage = 'initialize-ui-automation'
    Initialize-WindowsUiAutomation
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EaiExactDeleteForegroundWindow {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
'@
    $stage = 'decode-target'
    $target = ConvertFrom-CleanupTargetBase64 `
        -AppKeyBase64 $AppKeyBase64 -DisplayNameBase64 $DisplayNameBase64
    $appName = $target.AppKey
    $displayName = $target.DisplayName
    $stage = 'bind-exact-dialog'
    $state = Get-DeleteConfirmationState -Target $target
    $stage = 'validate-exact-dialog'
    Assert-DeleteConfirmationValue -State $state -Target $target
    $browserWindowHandle = [int64]$state.WindowHandle
    $browserProcessId = [int]$state.WindowProcessId
    $topLevelWindowRuntimeIdSha256 = Get-Sha256Text -Value ([string]$state.WindowRuntimeKey)
    $dialogFinalRuntimeIdSha256 = Get-Sha256Text -Value ([string]$state.FinalRuntimeKey)
    $edgeProcess = Get-Process -Id $browserProcessId -ErrorAction Stop
    try {
        if ($edgeProcess.HasExited -or $edgeProcess.SessionId -ne $interactiveSessionId) {
            throw 'The exact Edge UI process is not in the interactive worker session.'
        }
        $browserProcessSessionId = [int]$edgeProcess.SessionId
        $edgeCim = Get-CimInstance Win32_Process -Filter "ProcessId = $browserProcessId" -ErrorAction Stop
        $edgeOwner = Invoke-CimMethod -InputObject $edgeCim -MethodName GetOwnerSid -ErrorAction Stop
        if ($edgeOwner.ReturnValue -ne 0 -or $edgeOwner.Sid -cne $identity.User.Value) {
            throw 'The exact Edge UI process is not owned by the expected user SID.'
        }
        $edgeOwnerSidMatched = $true
    } finally {
        $edgeProcess.Dispose()
    }
    $edgeUiBoundToInteractiveSession = $true

    # Re-fetch and validate the exact dialog immediately before the destructive
    # UI Automation call. The element passed to InvokePattern is therefore the
    # uniquely bound button from this same interactive user's Edge session.
    $stage = 'activate-exact-button'
    $latestState = Get-DeleteConfirmationState -Target $target
    Assert-DeleteConfirmationValue -State $latestState -Target $target
    if ([int64]$latestState.WindowHandle -ne $browserWindowHandle -or
        [int]$latestState.WindowProcessId -ne $browserProcessId -or
        (Get-Sha256Text -Value ([string]$latestState.WindowRuntimeKey)) -cne $topLevelWindowRuntimeIdSha256 -or
        (Get-Sha256Text -Value ([string]$latestState.FinalRuntimeKey)) -cne $dialogFinalRuntimeIdSha256) {
        throw 'The exact Edge HWND, process, or permanent-delete button changed immediately before invocation.'
    }
    $state = $latestState
    $sameWindowAndButtonRevalidatedImmediatelyBeforeInvoke = $true
    Focus-UiElement -Element $state.Final
    if (-not $state.Final.Current.HasKeyboardFocus) {
        throw 'The exact permanent-delete button did not retain interactive focus.'
    }
    if ([EaiExactDeleteForegroundWindow]::GetForegroundWindow() -ne [IntPtr]$browserWindowHandle) {
        throw 'The exact Edge top-level window is not the foreground HWND.'
    }
    $exactBrowserWindowForegroundAtInvoke = $true

    $stage = 'invoke-exact-button'
    $invokedAt = [DateTimeOffset]::UtcNow.ToString('o')
    # From this point onward any exception is uncertain: InvokePattern may have
    # completed even if its caller loses the interactive transport.
    $mutationMayHaveOccurred = $true
    Invoke-UiElement -Element $state.Final

    $stage = 'wait-for-dialog-close'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $consecutiveAbsentChecks = 0
    do {
        Start-Sleep -Milliseconds 250
        if (-not (Test-DeleteConfirmationVisible -Target $target)) {
            $consecutiveAbsentChecks += 1
            if ($consecutiveAbsentChecks -ge 12) {
                Write-DeleteResult @{
                    appName = $target.AppKey
                    displayName = $target.DisplayName
                    exactDialogVerified = $true
                    exactTypedValueVerified = $true
                    exactDialogRevalidatedImmediatelyBeforeInvoke = $true
                    exactButtonFocused = $true
                    scopedInvokePatternInvoked = $true
                    mutationState = 'invoked-unverified'
                    invokedAt = $invokedAt
                    confirmationDialogClosed = $true
                    dialogAbsentConsecutiveChecks = 12
                    dialogClosureStableMilliseconds = 3000
                    absenceVerificationRequired = $true
                }
                exit 0
            }
        } else {
            $consecutiveAbsentChecks = 0
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    Write-DeleteResult @{
        appName = $target.AppKey
        displayName = $target.DisplayName
        exactDialogVerified = $true
        exactTypedValueVerified = $true
        exactDialogRevalidatedImmediatelyBeforeInvoke = $true
        exactButtonFocused = $true
        scopedInvokePatternInvoked = $true
        mutationState = 'uncertain'
        invokedAt = $invokedAt
        confirmationDialogClosed = $false
        dialogAbsentConsecutiveChecks = $consecutiveAbsentChecks
        dialogClosureStableMilliseconds = 0
        absenceVerificationRequired = $true
    }
    exit 3
} catch {
    Write-DeleteResult @{
        appName = $appName
        displayName = $displayName
        mutationState = if ($mutationMayHaveOccurred) { 'uncertain' } else { 'not-applied' }
        confirmationDialogClosed = $false
        dialogClosureStableMilliseconds = 0
        absenceVerificationRequired = $true
        errorCode = 'interactive-exact-delete-failed'
        errorStage = $stage
    }
    exit 2
}
