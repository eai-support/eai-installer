$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$VsCodeVersion = '1.136.1'
$VsCodeCommit = 'a44adf7f53e00964ab890f9f8758a334f1fc15bc'
$PinnedSha256 = '57454d84d55f07b532fcf42295c57a5445054006be668ad7b1c19c9de9f68e31'
$DownloadUrl = 'https://update.code.visualstudio.com/1.136.1/win32-arm64/stable'
$InstallerPath = 'C:\Users\Public\eai-release-e2e-vscode-system-setup-arm64.exe'
$EvidencePath = 'C:\Users\Public\eai-release-e2e-windows-ai-workspace.json'
$ExpectedUser = [string]$env:EAI_WINDOWS_AI_EXPECTED_USER

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Get-LowerSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$ExpectedSize,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $item = Get-Item -Force -LiteralPath $Path
    Assert-Condition (-not $item.PSIsContainer) "$Label is not a regular file."
    Assert-Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "$Label is a reparse point."
    Assert-Condition ($item.Length -eq $ExpectedSize) "$Label size does not match the pinned catalog."
    Assert-Condition ((Get-LowerSha256 $Path) -ceq $ExpectedSha256) "$Label hash does not match the pinned catalog."
}

function Assert-ExactDirectoryEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actual = @(Get-ChildItem -Force -LiteralPath $Path | ForEach-Object { $_.Name })
    $actualSorted = @($actual | Sort-Object)
    $expectedSorted = @($Expected | Sort-Object)
    Assert-Condition ($actualSorted.Count -eq $expectedSorted.Count) "$Label contains an unexpected number of entries."
    for ($index = 0; $index -lt $expectedSorted.Count; $index += 1) {
        Assert-Condition ($actualSorted[$index] -ieq $expectedSorted[$index]) "$Label contains an unexpected entry."
    }
}

function Get-DirectoryTreeIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = Get-Item -Force -LiteralPath $Path
    Assert-Condition $root.PSIsContainer 'The catalog tree root is not a directory.'
    Assert-Condition (($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'The catalog tree root is a reparse point.'
    $allItems = @(Get-ChildItem -Force -Recurse -LiteralPath $root.FullName)
    Assert-Condition ($allItems.Count -le 20000) 'The catalog tree exceeded its bounded entry count.'
    foreach ($item in $allItems) {
        Assert-Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'The catalog tree contains a reparse point.'
    }
    $files = @($allItems | Where-Object { -not $_.PSIsContainer })
    Assert-Condition ($files.Count -le 10000) 'The catalog tree exceeded its bounded file count.'
    $records = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    [long]$totalBytes = 0
    foreach ($file in $files) {
        Assert-Condition ($file.Length -le 1073741824) 'The catalog tree contains an oversized file.'
        $totalBytes += $file.Length
        Assert-Condition ($totalBytes -le 2147483648) 'The catalog tree exceeded its bounded byte count.'
        $relativePath = $file.FullName.Substring($root.FullName.TrimEnd('\').Length + 1).Replace('\', '/')
        $records.Add($relativePath, [pscustomobject]@{
            Size = [long]$file.Length
            Sha256 = Get-LowerSha256 $file.FullName
        })
    }
    [string[]]$orderedPaths = @($records.Keys)
    [Array]::Sort($orderedPaths, [System.StringComparer]::Ordinal)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($relativePath in $orderedPaths) {
        $record = $records[$relativePath]
        [void]$builder.Append($relativePath)
        [void]$builder.Append([char]0)
        [void]$builder.Append($record.Size.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        [void]$builder.Append([char]0)
        [void]$builder.Append($record.Sha256)
        [void]$builder.Append("`n")
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($builder.ToString())
    $digest = [System.Security.Cryptography.SHA256]::Create()
    try {
        $aggregateSha256 = ([BitConverter]::ToString($digest.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $digest.Dispose()
    }
    return [ordered]@{
        FileCount = $files.Count
        TotalBytes = $totalBytes
        Sha256 = $aggregateSha256
    }
}

function Assert-ProtectedInstallation {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $trustedWriters = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
    )
    $trustedOwners = $trustedWriters
    [long]$writeMask = 0x500D0156
    function Test-ProtectedNode {
        param([Parameter(Mandatory = $true)]$Item, [bool]$RequireProtected, [bool]$IgnoreInheritOnly)
        Assert-Condition (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) 'The VS Code installation contains a reparse point.'
        $acl = Get-Acl -LiteralPath $Item.FullName
        Assert-Condition $acl.AreAccessRulesCanonical 'The VS Code installation has a non-canonical ACL.'
        Assert-Condition (-not $RequireProtected -or $acl.AreAccessRulesProtected) 'The VS Code installation root does not have a protected ACL.'
        Assert-Condition ($acl.Sddl -notmatch 'NO_ACCESS_CONTROL') 'The VS Code installation has an invalid ACL.'
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        Assert-Condition ($trustedOwners -contains $owner) 'The VS Code installation has an untrusted owner.'
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or $trustedWriters -contains $rule.IdentityReference.Value) { continue }
            if ($IgnoreInheritOnly -and (($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0)) { continue }
            Assert-Condition (([long]$rule.FileSystemRights -band $writeMask) -eq 0) 'An unprivileged principal can modify the VS Code installation.'
        }
    }

    $programFilesItem = Get-Item -Force -LiteralPath ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles))
    $root = Get-Item -Force -LiteralPath $InstallRoot
    $expected = [System.IO.Path]::GetFullPath((Join-Path $programFilesItem.FullName 'Microsoft VS Code')).TrimEnd([char]92)
    $actual = [System.IO.Path]::GetFullPath($root.FullName).TrimEnd([char]92)
    Assert-Condition ([string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) 'VS Code is not installed at the exact Program Files path.'
    Test-ProtectedNode $programFilesItem $true $true
    Test-ProtectedNode $root $true $false
    foreach ($item in @(Get-ChildItem -Force -Recurse -LiteralPath $root.FullName)) {
        Test-ProtectedNode $item $false $false
    }
}

function Assert-MicrosoftAuthenticodeSignature {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $signature = Get-AuthenticodeSignature -FilePath $Path
    Assert-Condition ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) "$Label does not have a valid Authenticode signature."
    Assert-Condition ($null -ne $signature.SignerCertificate) "$Label does not have a signer certificate."
    $publisher = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    Assert-Condition ($publisher -ceq 'Microsoft Corporation') "$Label is not signed by Microsoft Corporation."
}

function Get-PeMachine {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = New-Object System.IO.BinaryReader($stream)
    try {
        Assert-Condition ($stream.Length -ge 70) 'The installed Code.exe is too small to contain a valid PE header.'
        Assert-Condition ($reader.ReadUInt16() -eq 0x5A4D) 'The installed Code.exe does not have an MZ header.'
        [void]$stream.Seek(0x3C, [System.IO.SeekOrigin]::Begin)
        $peOffset = $reader.ReadInt32()
        Assert-Condition ($peOffset -ge 64 -and ($peOffset + 6) -le $stream.Length) 'The installed Code.exe has an invalid PE offset.'
        [void]$stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
        Assert-Condition ($reader.ReadUInt32() -eq 0x00004550) 'The installed Code.exe does not have a PE signature.'
        return $reader.ReadUInt16()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Invoke-CurlWithRetry {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage,
        [ValidateRange(1, 10)][int]$RetryCount = 5
    )

    $curl = Get-Command 'curl.exe' -ErrorAction Stop | Select-Object -First 1
    for ($attempt = 1; $attempt -le $RetryCount; $attempt += 1) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            # Windows PowerShell can promote a native program's stderr to a
            # terminating NativeCommandError when the script preference is
            # Stop. Capture curl's status ourselves so transient attempts can
            # reach the bounded retry loop.
            $ErrorActionPreference = 'Continue'
            $output = @(& $curl.Source @Arguments 2>&1 | ForEach-Object { [string]$_ })
            $curlStatus = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($curlStatus -eq 0) {
            return $output
        }
        if ($attempt -lt $RetryCount) {
            Start-Sleep -Seconds 2
        }
    }
    throw [System.InvalidOperationException]::new("$FailureMessage (curl exit $curlStatus).")
}

function Get-OfficialDownloadMetadata {
    $headerLines = @(Invoke-CurlWithRetry -Arguments @(
        '--proto', '=https',
        '--tlsv1.2',
        '--head',
        '--silent',
        '--show-error',
        '--max-redirs', '0',
        '--connect-timeout', '15',
        '--max-time', '45',
        '--user-agent', 'eai-installer-release-e2e',
        $DownloadUrl
    ) -FailureMessage 'The official VS Code endpoint could not be reached')
    $headers = $headerLines -join "`n"
    $statusMatch = [regex]::Match($headers, '(?m)^HTTP/\S+\s+(\d{3})\b')
    Assert-Condition ($statusMatch.Success) 'The official VS Code endpoint did not return an HTTP status line.'
    $statusCode = [int]$statusMatch.Groups[1].Value
    Assert-Condition (@(301, 302, 307, 308) -contains $statusCode) 'The official VS Code endpoint did not return the expected HTTPS redirect.'

    $hashMatch = [regex]::Match($headers, '(?im)^x-sha256:\s*([0-9a-f]{64})\s*$')
    Assert-Condition ($hashMatch.Success) 'The official VS Code response did not provide an x-sha256 header.'
    $responseHash = $hashMatch.Groups[1].Value.ToLowerInvariant()
    Assert-Condition ($responseHash -ceq $PinnedSha256) 'The official VS Code response hash does not match the pinned release-test dependency.'

    $locationMatch = [regex]::Match($headers, '(?im)^location:\s*(https://\S+)\s*$')
    Assert-Condition ($locationMatch.Success) 'The official VS Code response did not provide an absolute HTTPS download location.'
    $redirectUri = [System.Uri]$locationMatch.Groups[1].Value
    Assert-Condition ($redirectUri.Scheme -ceq 'https') 'The official VS Code redirect was not HTTPS.'
    Assert-Condition ($redirectUri.Host -ieq 'vscode.download.prss.microsoft.com') 'The official VS Code redirect used an unexpected host.'
    $expectedPath = "/dbazure/download/stable/$VsCodeCommit/VSCodeSetup-arm64-$VsCodeVersion.exe"
    Assert-Condition ($redirectUri.AbsolutePath -ceq $expectedPath) 'The official VS Code redirect did not target the pinned version and commit.'

    return [ordered]@{
        Sha256 = $responseHash
        RedirectUrl = $redirectUri.AbsoluteUri
    }
}

function Assert-PrivilegedInstallContext {
    Assert-Condition ($ExpectedUser -match '^[A-Za-z0-9._-]+$') 'The expected Windows guest username is missing or invalid.'
    $identityName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    Assert-Condition ($identityName -ieq 'NT AUTHORITY\SYSTEM') 'The VS Code SystemSetup preparation must run through the privileged Parallels guest channel.'
    $interactiveUsers = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        if ($owner.ReturnValue -eq 0) { [string]$owner.User }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    Assert-Condition ($interactiveUsers -contains $ExpectedUser) 'The expected Windows user does not have an active Explorer session.'
}

function Write-SanitizedEvidence {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Evidence)

    $json = $Evidence | ConvertTo-Json -Depth 4
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($EvidencePath, "$json`n", $utf8WithoutBom)
}

function Invoke-Preparation {
    Assert-PrivilegedInstallContext
    if (Test-Path -LiteralPath $EvidencePath) {
        Remove-Item -LiteralPath $EvidencePath -Force
    }

    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($programFiles)) 'Windows did not provide the native Program Files path.'
    Assert-Condition ([System.IO.Path]::IsPathRooted($programFiles)) 'The native Program Files path is not absolute.'

    $installRoot = Join-Path $programFiles 'Microsoft VS Code'
    $codePath = Join-Path $installRoot 'Code.exe'
    $cliPath = Join-Path $installRoot 'bin\code.cmd'
    $wasInstalled = Test-Path -LiteralPath $codePath -PathType Leaf
    $source = if ($wasInstalled) { 'existing' } else { 'official-download' }

    $metadata = Get-OfficialDownloadMetadata
    $installerReady = $false
    if (Test-Path -LiteralPath $InstallerPath -PathType Leaf) {
        $installerReady = (Get-LowerSha256 $InstallerPath) -ceq $metadata.Sha256
    }
    if (-not $installerReady) {
        $partialPath = "$InstallerPath.partial"
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath -Force
        }
        [void](Invoke-CurlWithRetry -Arguments @(
            '--proto', '=https',
            '--tlsv1.2',
            '--fail',
            '--silent',
            '--show-error',
            '--connect-timeout', '15',
            '--max-time', '600',
            '--output', $partialPath,
            '--user-agent', 'eai-installer-release-e2e',
            $metadata.RedirectUrl
        ) -FailureMessage 'The pinned VS Code installer download failed')
        $partialHash = Get-LowerSha256 $partialPath
        Assert-Condition ($partialHash -ceq $metadata.Sha256) 'The downloaded VS Code installer hash did not match the official response header.'
        Move-Item -LiteralPath $partialPath -Destination $InstallerPath -Force
    }

    $installerHash = Get-LowerSha256 $InstallerPath
    Assert-Condition ($installerHash -ceq $PinnedSha256) 'The pinned VS Code installer hash verification failed.'
    Assert-MicrosoftAuthenticodeSignature $InstallerPath 'The pinned VS Code installer'

    if (-not $wasInstalled) {
        $arguments = @('/VERYSILENT', '/NORESTART', '/MERGETASKS=!runcode')
        $installerProcess = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        Assert-Condition ($installerProcess.ExitCode -eq 0) "The VS Code SystemSetup installer exited with code $($installerProcess.ExitCode)."
        for ($attempt = 0; $attempt -lt 30 -and -not (Test-Path -LiteralPath $codePath -PathType Leaf); $attempt += 1) {
            Start-Sleep -Seconds 1
        }
    }

    Assert-Condition (Test-Path -LiteralPath $codePath -PathType Leaf) 'VS Code was not installed at the standard machine-wide Program Files path.'
    Assert-Condition (Test-Path -LiteralPath $cliPath -PathType Leaf) 'The installed VS Code command-line launcher was not found.'
    Assert-MicrosoftAuthenticodeSignature $codePath 'The installed Code.exe'

    $machine = Get-PeMachine $codePath
    Assert-Condition ($machine -eq 0xAA64) ('The installed Code.exe PE machine was 0x{0:X4}, not ARM64 0xAA64.' -f $machine)

    $versionDirectoryName = $VsCodeCommit.Substring(0, 10)
    Assert-Condition ($versionDirectoryName -ceq 'a44adf7f53') 'The pinned VS Code commit-directory name is invalid.'
    $versionRoot = Join-Path $installRoot $versionDirectoryName
    $applicationRoot = Join-Path $versionRoot 'resources\app'
    $cliJsPath = Join-Path $applicationRoot 'out\cli.js'
    $visualManifestPath = Join-Path $installRoot 'Code.VisualElementsManifest.xml'
    Assert-Condition (Test-Path -LiteralPath $versionRoot -PathType Container) 'The exact pinned VS Code commit directory was not found.'
    Assert-Condition (Test-Path -LiteralPath $applicationRoot -PathType Container) 'The pinned VS Code application-resource directory was not found.'

    Assert-ExactDirectoryEntries $installRoot @(
        $versionDirectoryName,
        'bin',
        'Code.exe',
        'Code.VisualElementsManifest.xml',
        'unins000.dat',
        'unins000.exe',
        'unins000.msg'
    ) 'The VS Code installation root'
    Assert-ExactDirectoryEntries (Join-Path $installRoot 'bin') @('code', 'code-tunnel.exe', 'code.cmd') 'The VS Code bin directory'
    Assert-ProtectedInstallation $installRoot

    $appPackagePath = Join-Path $applicationRoot 'package.json'
    $productPath = Join-Path $applicationRoot 'product.json'
    $copilotPackagePath = Join-Path $applicationRoot 'extensions\copilot\package.json'
    Assert-Condition (Test-Path -LiteralPath $appPackagePath -PathType Leaf) 'The installed VS Code package metadata was not found.'
    Assert-Condition (Test-Path -LiteralPath $productPath -PathType Leaf) 'The installed VS Code product metadata was not found.'
    Assert-Condition (Test-Path -LiteralPath $copilotPackagePath -PathType Leaf) 'The built-in Copilot Chat extension metadata was not found.'
    Assert-FileIdentity $codePath 218732896 'c8e8f54f217223f3d4adff4dbd1f529aa7386c3a1705dbe214ecf187b963423e' 'The installed Code.exe'
    Assert-FileIdentity $visualManifestPath 398 'cff3bb59579080b4ac4e69fc8d936c35bbb41455f66f9188ed54f4e31882e68b' 'The VS Code visual manifest'
    Assert-FileIdentity $appPackagePath 15233 '18ce306138992d44d6c0537c386943b277621865d5161e1932e792b09ef766f0' 'The VS Code package metadata'
    Assert-FileIdentity $productPath 71150 '4bdbecbf1cd1a700f4f738216bd0e6f08f561a52e1fd9ca915ea9ff9a6a7a7a6' 'The VS Code product metadata'
    Assert-FileIdentity $copilotPackagePath 200790 '586aa5105751792bedcb7c3ef785d0c1cb1bac8c97812afd50f1349f0a6c1a09' 'The built-in Copilot Chat metadata'
    Assert-FileIdentity $cliJsPath 291407 '487137301c6d9ac59dc846a93c17e2f52ba98fdf1670c164dac24b4eb5acad61' 'The VS Code CLI runtime'
    $applicationTree = Get-DirectoryTreeIdentity $versionRoot
    Assert-Condition ($applicationTree.FileCount -eq 2463) 'The VS Code application tree file count does not match the pinned catalog.'
    Assert-Condition ($applicationTree.TotalBytes -eq 782690305) 'The VS Code application tree byte count does not match the pinned catalog.'
    Assert-Condition ($applicationTree.Sha256 -ceq '11009193bf07e51892a0ae9f6030188c7f8914e79ef4344e2f6a3a344807753f') 'The VS Code application tree hash does not match the pinned catalog.'
    $binTree = Get-DirectoryTreeIdentity (Join-Path $installRoot 'bin')
    Assert-Condition ($binTree.FileCount -eq 3) 'The VS Code bin tree file count does not match the pinned catalog.'
    Assert-Condition ($binTree.TotalBytes -eq 25558542) 'The VS Code bin tree byte count does not match the pinned catalog.'
    Assert-Condition ($binTree.Sha256 -ceq '73fbdad4bf097af9408bdcbe75f4c5cc1741b88b9eedf9d946b338124457408b') 'The VS Code bin tree hash does not match the pinned catalog.'
    $appPackage = Get-Content -LiteralPath $appPackagePath -Raw | ConvertFrom-Json
    $product = Get-Content -LiteralPath $productPath -Raw | ConvertFrom-Json
    Assert-Condition ([string]$appPackage.version -ceq $VsCodeVersion) 'The installed VS Code package version does not match the pinned version.'
    Assert-Condition ([string]$product.commit -ceq $VsCodeCommit) 'The installed VS Code commit does not match the pinned release.'

    $fileProductVersion = [string](Get-Item -LiteralPath $codePath).VersionInfo.ProductVersion
    $escapedVersion = [regex]::Escape($VsCodeVersion)
    Assert-Condition ($fileProductVersion -match "^$escapedVersion(?:\.0)?$") 'The installed Code.exe product version does not match the pinned version.'

    $cliOutput = @(& $cliPath --version 2>&1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
    $cliExitCode = $LASTEXITCODE
    Assert-Condition ($cliExitCode -eq 0) 'The installed VS Code CLI version check failed.'
    Assert-Condition ($cliOutput.Count -ge 3) 'The installed VS Code CLI did not return its version, commit, and architecture.'
    Assert-Condition ($cliOutput[0] -ceq $VsCodeVersion) 'The VS Code CLI version does not match the pinned version.'
    Assert-Condition ($cliOutput[1] -ceq $VsCodeCommit) 'The VS Code CLI commit does not match the pinned release.'
    Assert-Condition ($cliOutput[2] -ieq 'arm64') 'The VS Code CLI did not report ARM64.'

    $copilotPackage = Get-Content -LiteralPath $copilotPackagePath -Raw | ConvertFrom-Json
    Assert-Condition ([string]$copilotPackage.publisher -ceq 'GitHub') 'The built-in Copilot Chat extension has an unexpected publisher.'
    Assert-Condition ([string]$copilotPackage.name -ceq 'copilot-chat') 'The built-in Copilot Chat extension has an unexpected identifier.'

    Write-SanitizedEvidence ([ordered]@{
        status = 'prepared'
        surfaceId = 'vscode-copilot'
        product = 'Visual Studio Code'
        source = $source
        version = $VsCodeVersion
        commit = $VsCodeCommit
        architecture = 'arm64'
        peMachine = '0xAA64'
        applicationPath = '%ProgramFiles%\Microsoft VS Code\Code.exe'
        cliPath = '%ProgramFiles%\Microsoft VS Code\bin\code.cmd'
        downloadUrl = $DownloadUrl
        responseSha256 = $metadata.Sha256
        installerSha256 = $installerHash
        installerSignatureVerified = $true
        applicationSignatureVerified = $true
        publisher = 'Microsoft Corporation'
        bundledCopilotVerified = $true
        extensionId = 'GitHub.copilot-chat'
        machineWideInstallVerified = $true
        protectedAclVerified = $true
        applicationTreeFileCount = $applicationTree.FileCount
        applicationTreeTotalBytes = $applicationTree.TotalBytes
        applicationTreeSha256 = $applicationTree.Sha256
        binTreeFileCount = $binTree.FileCount
        binTreeTotalBytes = $binTree.TotalBytes
        binTreeSha256 = $binTree.Sha256
        preparedAt = [DateTime]::UtcNow.ToString('o')
    })

    [Console]::Out.WriteLine("AI_WORKSPACE_READY surface=vscode-copilot version=$VsCodeVersion source=$source")
}

try {
    Invoke-Preparation
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    foreach ($path in @([string]$env:USERPROFILE, [string]$env:LOCALAPPDATA)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $message = $message.Replace($path, '%USERPROFILE%')
        }
    }
    $message = ($message -replace '[\r\n]+', ' ').Trim()
    [Console]::Out.WriteLine("AI_WORKSPACE_ERROR: $message")
    exit 1
}
