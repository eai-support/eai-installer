param(
    [switch]$SelfTest,
    [string[]]$CleanupInputBase64 = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )

    if (-not $Condition) {
        throw $Code
    }
}

function Read-CleanupInputLines {
    if ($CleanupInputBase64.Count -gt 0) {
        Assert-Condition ($CleanupInputBase64.Count -eq 6) "cleanup-input-count-invalid"
        return @($CleanupInputBase64 | ForEach-Object {
            try {
                [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))
            } catch {
                throw "cleanup-input-base64-invalid"
            }
        })
    }
    return @(
        [Console]::In.ReadLine(),
        [Console]::In.ReadLine(),
        [Console]::In.ReadLine(),
        [Console]::In.ReadLine(),
        [Console]::In.ReadLine(),
        [Console]::In.ReadLine()
    )
}

function Get-Sha256Text {
    param([AllowEmptyString()][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-OutputLineCount {
    param([AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return 0 }
    return @($Value -split "`r?`n").Count
}

function Test-AuthenticationFailure {
    param([AllowEmptyString()][string]$Value)

    return $Value -match '(?i)(not authenticated|authentication (?:failed|required)|unauthori[sz]ed|forbidden|access denied|login required|sign in required|token (?:expired|invalid))'
}

function Get-V4FailureClassification {
    param([AllowEmptyString()][string]$Value)

    $authenticationFailure = Test-AuthenticationFailure -Value $Value
    $missingOwnershipManifest = $Value -match '(?i)(missing|no|without|cannot find|could not find|does not (?:have|identify|contain)).{0,100}(?:unambiguous )?ownership manifest' -or
        $Value -match '(?i)(?:unambiguous )?ownership manifest.{0,100}(missing|not found|unavailable|required)'
    $deletionPlanContext = $Value -match '(?i)(deletion[- ]plan|prepare app deletion)'
    $notFound = $Value -match '(?i)(\b404\b|resource not found)'
    $deletionPlanNotFound = $deletionPlanContext -and $notFound
    $knownFailure = -not $authenticationFailure -and ($missingOwnershipManifest -or $deletionPlanNotFound)

    return [ordered]@{
        deletionRequest = $true
        missingOwnershipManifest = [bool]$missingOwnershipManifest
        deletionPlanNotFound = [bool]$deletionPlanNotFound
        authenticationFailure = [bool]$authenticationFailure
        knownDiagnosticFallbackCondition = [bool]$knownFailure
    }
}

function ConvertFrom-StrictJson {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Code
    )

    try {
        return $Value | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw $Code
    }
}

function Get-ResourceDocuments {
    param([Parameter(Mandatory = $true)]$Payload)

    if ($Payload -is [Array]) { return @($Payload) }
    foreach ($name in @('resources', 'docs', 'items')) {
        $property = $Payload.PSObject.Properties[$name]
        if ($null -ne $property) { return @($property.Value) }
    }
    return @()
}

function Get-AppDocuments {
    param([Parameter(Mandatory = $true)]$Payload)

    if ($Payload -is [Array]) { return @($Payload) }
    $property = $Payload.PSObject.Properties['apps']
    if ($null -ne $property) { return @($property.Value) }
    return @()
}

function Get-DocumentData {
    param([Parameter(Mandatory = $true)]$Document)

    $property = $Document.PSObject.Properties['data']
    if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    return $Document
}

function Get-FirstPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }
    return $null
}

function Assert-CompleteBoundedResourcePage {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Documents,
        [Parameter(Mandatory = $true)][string]$CodePrefix
    )

    $totalDocsProperty = @($Payload.PSObject.Properties | Where-Object { $_.Name -ceq 'totalDocs' })
    Assert-Condition ($totalDocsProperty.Count -eq 1) "$CodePrefix-total-docs-missing"
    $totalDocs = [int64]::MinValue
    Assert-Condition ([int64]::TryParse(
        [string]$totalDocsProperty[0].Value,
        [System.Globalization.NumberStyles]::Integer,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$totalDocs
    )) "$CodePrefix-total-docs-invalid"
    Assert-Condition ($totalDocs -ge 0 -and $totalDocs -lt 1000) "$CodePrefix-may-be-truncated"
    Assert-Condition ($totalDocs -eq $Documents.Count) "$CodePrefix-page-count-mismatch"
}

function Get-AuthoritativeChildState {
    param(
        [Parameter(Mandatory = $true)][string]$AppKey,
        [Parameter(Mandatory = $true)][string]$TenantId
    )

    $queries = [ordered]@{}
    foreach ($spec in @(
        [pscustomobject]@{ Key = 'serviceActivations'; ObjectType = 'vertical-service-activation' },
        [pscustomobject]@{ Key = 'productConfigs'; ObjectType = 'vertical-product-config' }
    )) {
        $query = Invoke-Eai -Arguments @(
            'resources', 'list', $spec.ObjectType,
            '--tenant-id', $TenantId,
            '--limit', '1000',
            '--format', 'json'
        )
        Assert-Condition ($query.exitCode -eq 0) "$($spec.Key)-query-failed"
        $payload = ConvertFrom-StrictJson -Value $query.text -Code "$($spec.Key)-query-invalid-json"
        $documents = @(Get-ResourceDocuments -Payload $payload)
        Assert-CompleteBoundedResourcePage -Payload $payload -Documents $documents -CodePrefix "$($spec.Key)-query"
        $matches = @($documents | Where-Object {
            $data = Get-DocumentData -Document $_
            [string]$data.verticalKey -ceq $AppKey
        })
        $queries[$spec.Key] = [ordered]@{
            objectType = $spec.ObjectType
            filterField = 'data.verticalKey'
            comparison = 'case-sensitive-exact'
            filterValueAppKeyBound = $true
            querySucceeded = $true
            completeBoundedPage = $true
            totalDocs = $documents.Count
            exactVerticalKeyMatches = $matches.Count
        }
    }

    # Any product-config bound to this vertical is a child, including a future
    # or unknown configKey. Rejecting the whole set is intentionally stricter
    # than trying to recognize only today's workflow/setup shapes.
    Assert-Condition ($queries.serviceActivations.exactVerticalKeyMatches -eq 0) 'service-activations-nonzero'
    Assert-Condition ($queries.productConfigs.exactVerticalKeyMatches -eq 0) 'vertical-product-configs-nonzero'
    return [ordered]@{
        queriesComplete = $true
        serviceActivations = $queries.serviceActivations
        productConfigs = $queries.productConfigs
    }
}

function Get-ExactJsonPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Code
    )

    $properties = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name })
    Assert-Condition ($properties.Count -eq 1) $Code
    return $properties[0].Value
}

function Confirm-EaiProjectPackageContract {
    param(
        [Parameter(Mandatory = $true)]$Package,
        [Parameter(Mandatory = $true)][string]$AppKey
    )

    $packageName = [string](Get-ExactJsonPropertyValue -Object $Package -Name 'name' -Code 'project-package-name-missing')
    Assert-Condition ($packageName -ceq "@eai-tools/$AppKey") 'project-package-name-mismatch'

    $scripts = Get-ExactJsonPropertyValue -Object $Package -Name 'scripts' -Code 'project-package-scripts-missing'
    foreach ($scriptName in @('build', 'typecheck')) {
        $scriptValue = [string](Get-ExactJsonPropertyValue -Object $scripts -Name $scriptName -Code "project-package-$scriptName-script-missing")
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($scriptValue)) "project-package-$scriptName-script-empty"
    }

    $dependencies = Get-ExactJsonPropertyValue -Object $Package -Name 'dependencies' -Code 'project-package-dependencies-missing'
    $acceptedEaiDependencies = @(
        '@enterpriseaigroup/core',
        '@enterpriseaigroup/platform-sdk',
        '@eai-tools/core',
        '@eai-tools/platform-sdk'
    )
    $eaiDependencyMatches = @($dependencies.PSObject.Properties | Where-Object {
        $acceptedEaiDependencies -ccontains $_.Name -and
        -not [string]::IsNullOrWhiteSpace([string]$_.Value)
    })
    Assert-Condition ($eaiDependencyMatches.Count -ge 1) 'project-package-eai-dependency-missing'
}

function Confirm-EaiProjectManifestContract {
    param([Parameter(Mandatory = $true)]$Manifest)

    $schemaVersion = Get-ExactJsonPropertyValue -Object $Manifest -Name 'schemaVersion' -Code 'project-manifest-schema-missing'
    Assert-Condition ([string]$schemaVersion -ceq '1') 'project-manifest-schema-invalid'
    $template = Get-ExactJsonPropertyValue -Object $Manifest -Name 'template' -Code 'project-manifest-template-missing'
    $templateRepo = [string](Get-ExactJsonPropertyValue -Object $template -Name 'repo' -Code 'project-manifest-template-repo-missing')
    Assert-Condition ($templateRepo -ceq 'https://github.com/eai-support/eai-app-template.git') 'project-manifest-template-repo-invalid'
    $templateCommit = [string](Get-ExactJsonPropertyValue -Object $template -Name 'commit' -Code 'project-manifest-template-commit-missing')
    Assert-Condition ($templateCommit -cmatch '^[0-9a-f]{40}$') 'project-manifest-template-commit-invalid'
}

function Get-RealDirectoryWithoutReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CodePrefix
    )

    try {
        $expectedPath = [IO.Path]::GetFullPath($Path)
    } catch {
        throw "$CodePrefix-path-invalid"
    }
    $cursor = [IO.DirectoryInfo]$expectedPath
    $leaf = $null
    while ($null -ne $cursor) {
        try {
            $item = Get-Item -LiteralPath $cursor.FullName -Force -ErrorAction Stop
        } catch {
            throw "$CodePrefix-component-missing"
        }
        Assert-Condition ($item.PSIsContainer) "$CodePrefix-component-not-directory"
        Assert-Condition (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "$CodePrefix-component-is-reparse-point"
        Assert-Condition ([string]::Equals($item.FullName, $cursor.FullName, [StringComparison]::OrdinalIgnoreCase)) "$CodePrefix-component-resolved-elsewhere"
        if ($null -eq $leaf) { $leaf = $item }
        $cursor = $cursor.Parent
    }
    Assert-Condition ($null -ne $leaf) "$CodePrefix-directory-missing"
    return $leaf
}

function Get-RealProjectFile {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$CodePrefix
    )

    try {
        $candidatePath = [IO.Path]::GetFullPath((Join-Path -Path $ProjectPath -ChildPath $RelativePath))
    } catch {
        throw "$CodePrefix-path-invalid"
    }
    $projectPrefix = $ProjectPath.TrimEnd('\') + '\'
    Assert-Condition ($candidatePath.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) "$CodePrefix-outside-project"
    $parentPath = [IO.Path]::GetDirectoryName($candidatePath)
    $parentItem = Get-RealDirectoryWithoutReparsePoints -Path $parentPath -CodePrefix "$CodePrefix-parent"
    try {
        $file = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
    } catch {
        throw "$CodePrefix-missing"
    }
    Assert-Condition (-not $file.PSIsContainer) "$CodePrefix-not-file"
    Assert-Condition (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "$CodePrefix-is-reparse-point"
    Assert-Condition ([string]::Equals($file.FullName, $candidatePath, [StringComparison]::OrdinalIgnoreCase)) "$CodePrefix-resolved-elsewhere"
    Assert-Condition ([string]::Equals($file.Directory.FullName, $parentItem.FullName, [StringComparison]::OrdinalIgnoreCase)) "$CodePrefix-parent-mismatch"
    Assert-Condition ($file.Length -gt 0) "$CodePrefix-empty"
    return $file
}

function Resolve-ExactEaiCleanupProject {
    param([Parameter(Mandatory = $true)][string]$AppKey)

    # This root is deliberately not supplied by input or environment. The app
    # leaf is already receipt/run-ID bound and excludes all path separators.
    $fixedRoot = [IO.Path]::GetFullPath('C:\Users\Public\EAIReleaseTests')
    $rootItem = Get-RealDirectoryWithoutReparsePoints -Path $fixedRoot -CodePrefix 'project-root'
    Assert-Condition ([string]::Equals($rootItem.FullName, $fixedRoot, [StringComparison]::OrdinalIgnoreCase)) 'project-root-resolved-elsewhere'
    try {
        $expectedProjectPath = [IO.Path]::GetFullPath((Join-Path -Path $fixedRoot -ChildPath $AppKey))
    } catch {
        throw 'project-path-invalid'
    }
    $expectedParent = [IO.Directory]::GetParent($expectedProjectPath)
    Assert-Condition ($null -ne $expectedParent) 'project-parent-missing'
    Assert-Condition ([string]::Equals($expectedParent.FullName, $fixedRoot, [StringComparison]::OrdinalIgnoreCase)) 'project-path-escaped-fixed-root'

    $projectItem = Get-RealDirectoryWithoutReparsePoints -Path $expectedProjectPath -CodePrefix 'project'
    Assert-Condition ([string]::Equals($projectItem.FullName, $expectedProjectPath, [StringComparison]::OrdinalIgnoreCase)) 'project-resolved-elsewhere'
    Assert-Condition ([string]::Equals($projectItem.Parent.FullName, $rootItem.FullName, [StringComparison]::OrdinalIgnoreCase)) 'project-parent-mismatch'

    $packageItem = Get-RealProjectFile -ProjectPath $projectItem.FullName -RelativePath 'package.json' -CodePrefix 'project-package'
    $manifestItem = Get-RealProjectFile -ProjectPath $projectItem.FullName -RelativePath '.eai-manifest.json' -CodePrefix 'project-manifest'
    $objectTypesItem = Get-RealProjectFile -ProjectPath $projectItem.FullName -RelativePath 'src\eai.config\object-types.ts' -CodePrefix 'project-object-types'

    try {
        $packageText = [IO.File]::ReadAllText($packageItem.FullName, [Text.Encoding]::UTF8)
        $manifestText = [IO.File]::ReadAllText($manifestItem.FullName, [Text.Encoding]::UTF8)
        $objectTypesText = [IO.File]::ReadAllText($objectTypesItem.FullName, [Text.Encoding]::UTF8)
    } catch {
        throw 'project-marker-read-failed'
    }
    $package = ConvertFrom-StrictJson -Value $packageText -Code 'project-package-invalid-json'
    $manifest = ConvertFrom-StrictJson -Value $manifestText -Code 'project-manifest-invalid-json'
    Confirm-EaiProjectPackageContract -Package $package -AppKey $AppKey
    Confirm-EaiProjectManifestContract -Manifest $manifest
    Assert-Condition ($objectTypesText -cmatch '\b(?:export\s+)?const\s+objectTypes\b') 'project-object-types-marker-invalid'

    # Recheck the three leaves after reading them. A link swap must never turn
    # a validated path into an execution context.
    [void](Get-RealProjectFile -ProjectPath $projectItem.FullName -RelativePath 'package.json' -CodePrefix 'project-package')
    [void](Get-RealProjectFile -ProjectPath $projectItem.FullName -RelativePath '.eai-manifest.json' -CodePrefix 'project-manifest')
    [void](Get-RealProjectFile -ProjectPath $projectItem.FullName -RelativePath 'src\eai.config\object-types.ts' -CodePrefix 'project-object-types')

    return [pscustomobject]@{
        ProjectPath = $projectItem.FullName
        PackageSha256 = Get-Sha256Text -Value $packageText
        ManifestSha256 = Get-Sha256Text -Value $manifestText
        ObjectTypesSha256 = Get-Sha256Text -Value $objectTypesText
    }
}

function Invoke-Eai {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $binding = Resolve-ExactEaiCleanupProject -AppKey $script:ProjectAppKey
    Assert-Condition ([string]::Equals($binding.ProjectPath, $script:ProjectPath, [StringComparison]::OrdinalIgnoreCase)) 'project-binding-path-changed'
    Assert-Condition ($binding.PackageSha256 -ceq $script:ProjectPackageSha256) 'project-binding-package-changed'
    Assert-Condition ($binding.ManifestSha256 -ceq $script:ProjectManifestSha256) 'project-binding-manifest-changed'
    Assert-Condition ($binding.ObjectTypesSha256 -ceq $script:ProjectObjectTypesSha256) 'project-binding-object-types-changed'

    $lines = @()
    $commandExitCode = 1
    Push-Location -LiteralPath $binding.ProjectPath
    try {
        $location = Get-Location
        Assert-Condition ($location.Provider.Name -ceq 'FileSystem') 'project-working-directory-provider-invalid'
        Assert-Condition ([string]::Equals($location.ProviderPath, $binding.ProjectPath, [StringComparison]::OrdinalIgnoreCase)) 'project-working-directory-mismatch'
        $currentItem = Get-Item -LiteralPath '.' -Force -ErrorAction Stop
        Assert-Condition ($currentItem.PSIsContainer) 'project-working-directory-not-directory'
        Assert-Condition (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'project-working-directory-is-reparse-point'
        Assert-Condition ([string]::Equals($currentItem.FullName, $binding.ProjectPath, [StringComparison]::OrdinalIgnoreCase)) 'project-working-directory-resolved-elsewhere'
        # Non-zero CLI commands (notably the expected V4 deletion-plan
        # fallback) write diagnostics to stderr. Capture those records and the
        # native exit code instead of allowing the script-wide Stop policy to
        # turn them into an unrelated terminating PowerShell exception.
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $lines = @(& $script:EaiPath @Arguments 2>&1)
            $commandExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    } finally {
        Pop-Location
    }
    $text = (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
    return [ordered]@{
        exitCode = $commandExitCode
        text = $text
        outputLineCount = Get-OutputLineCount -Value $text
        outputSha256 = Get-Sha256Text -Value $text
    }
}

function Get-ExactEnrollment {
    param(
        [Parameter(Mandatory = $true)][string]$AppKey,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][DateTimeOffset]$RunStartedAt
    )

    $query = Invoke-Eai -Arguments @(
        'resources', 'list', 'tenant-vertical-enrollment',
        '--tenant-id', $TenantId,
        '--limit', '1000',
        '--format', 'json'
    )
    Assert-Condition ($query.exitCode -eq 0) "enrollment-query-failed"
    $payload = ConvertFrom-StrictJson -Value $query.text -Code "enrollment-query-invalid-json"
    $docs = @(Get-ResourceDocuments -Payload $payload)
    $matches = @($docs | Where-Object {
        $data = Get-DocumentData -Document $_
        [string]$data.verticalKey -ceq $AppKey
    })
    Assert-CompleteBoundedResourcePage -Payload $payload -Documents $docs -CodePrefix 'enrollment-query'
    Assert-Condition ($matches.Count -eq 1) "enrollment-exact-match-count-not-one"

    $record = $matches[0]
    $data = Get-DocumentData -Document $record
    $recordId = [string](Get-FirstPropertyValue -Object $record -Names @('id', '_id'))
    Assert-Condition ($recordId -match '^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$') "enrollment-id-invalid"
    $displayName = [string](Get-FirstPropertyValue -Object $data -Names @('displayName', 'name'))
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($displayName)) "enrollment-display-name-missing"
    Assert-Condition ($displayName.Length -le 200 -and $displayName -notmatch '[\r\n]') "enrollment-display-name-invalid"
    $source = [string](Get-FirstPropertyValue -Object $data -Names @('source'))
    Assert-Condition ($source -ceq 'eai-cli') "enrollment-source-not-eai-cli"

    $createdRaw = Get-FirstPropertyValue -Object $record -Names @('createdAt', 'created_at')
    if ($null -eq $createdRaw) {
        $createdRaw = Get-FirstPropertyValue -Object $data -Names @('createdAt', 'created_at')
    }
    $createdAt = [DateTimeOffset]::MinValue
    Assert-Condition ([DateTimeOffset]::TryParse(
        [string]$createdRaw,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$createdAt
    )) "enrollment-created-at-invalid"
    $now = [DateTimeOffset]::UtcNow
    Assert-Condition ($createdAt -ge $RunStartedAt -and $createdAt -le $now.AddMinutes(5)) "enrollment-not-created-during-run"
    $childState = Get-AuthoritativeChildState -AppKey $AppKey -TenantId $TenantId

    return [ordered]@{
        recordId = $recordId
        resourceIdSha256 = Get-Sha256Text -Value $recordId
        displayName = $displayName
        resourceCreatedAt = $createdAt.ToUniversalTime().ToString('o')
        createdDuringThisRun = $true
        sourceVerified = $true
        authoritativeChildQueriesComplete = $true
        childQueries = $childState
        servicesBeforeDeletion = [int]$childState.serviceActivations.exactVerticalKeyMatches
        verticalProductConfigsBeforeDeletion = [int]$childState.productConfigs.exactVerticalKeyMatches
        workflowExactMatchesBeforeDeletion = [int]$childState.productConfigs.exactVerticalKeyMatches
        setupExactMatchesBeforeDeletion = [int]$childState.productConfigs.exactVerticalKeyMatches
        enrollmentExactMatches = 1
    }
}

function Confirm-ManualFallbackGate {
    param(
        [Parameter(Mandatory = $true)]$Gate,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$AppKey,
        [Parameter(Mandatory = $true)]$Enrollment
    )

    Assert-Condition ([string]$Gate.schemaVersion -ceq 'eai.windows-diagnostic-cleanup-child-gate.v1') "fallback-gate-schema-invalid"
    Assert-Condition ([string]$Gate.runId -ceq $RunId) "fallback-gate-run-mismatch"
    Assert-Condition ([string]$Gate.platform -ceq 'windows') "fallback-gate-platform-mismatch"
    Assert-Condition ([string]$Gate.appName -ceq $AppKey) "fallback-gate-app-mismatch"
    Assert-Condition ([string]$Gate.resourceIdSha256 -ceq [string]$Enrollment.resourceIdSha256) "fallback-gate-resource-mismatch"
    Assert-Condition ([string]$Gate.displayName -ceq [string]$Enrollment.displayName) "fallback-gate-display-name-mismatch"
    Assert-Condition ($Gate.enrollmentExactMatches -eq 1) "fallback-gate-enrollment-count-invalid"
    Assert-Condition ($Gate.createdDuringThisRun -eq $true) "fallback-gate-provenance-invalid"
    Assert-Condition ($Gate.exactDisplayNameVerified -eq $true) "fallback-gate-display-not-verified"
    Assert-Condition ($Gate.typedConfirmation -eq $true) "fallback-gate-confirmation-not-verified"
    Assert-Condition ($Gate.servicesBeforeDeletion -eq 0) "fallback-gate-services-nonzero"
    Assert-Condition ($Gate.workflowExactMatchesBeforeDeletion -eq 0) "fallback-gate-workflows-nonzero"
    Assert-Condition ($Gate.setupExactMatchesBeforeDeletion -eq 0) "fallback-gate-setup-nonzero"
    Assert-Condition ($Gate.sanitized -eq $true -and $Gate.diagnostic -eq $true) "fallback-gate-marking-invalid"
}

function Get-AbsenceEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$AppKey,
        [Parameter(Mandatory = $true)][string]$TenantId
    )

    $resourceQuery = Invoke-Eai -Arguments @(
        'resources', 'list', 'tenant-vertical-enrollment',
        '--tenant-id', $TenantId,
        '--limit', '1000',
        '--format', 'json'
    )
    Assert-Condition ($resourceQuery.exitCode -eq 0) "absence-resource-query-failed"
    $resourcePayload = ConvertFrom-StrictJson -Value $resourceQuery.text -Code "absence-resource-query-invalid-json"
    $resourceDocs = @(Get-ResourceDocuments -Payload $resourcePayload)
    $resourceExactMatches = @($resourceDocs | Where-Object {
        $data = Get-DocumentData -Document $_
        [string]$data.verticalKey -ceq $AppKey
    }).Count
    Assert-CompleteBoundedResourcePage -Payload $resourcePayload -Documents $resourceDocs -CodePrefix 'absence-resource-query'

    $appQuery = Invoke-Eai -Arguments @(
        'app', 'list',
        '--tenant-id', $TenantId,
        '--limit', '1000',
        '--format', 'json'
    )
    Assert-Condition ($appQuery.exitCode -eq 0) "absence-app-list-failed"
    $appPayload = ConvertFrom-StrictJson -Value $appQuery.text -Code "absence-app-list-invalid-json"
    $appDocs = @(Get-AppDocuments -Payload $appPayload)
    Assert-Condition ($appDocs.Count -lt 1000) "absence-app-list-may-be-truncated"
    $appExactMatches = @($appDocs | Where-Object {
        $data = Get-DocumentData -Document $_
        [string]$data.verticalKey -ceq $AppKey
    }).Count

    return [ordered]@{
        resourceApiExactMatchesAfter = $resourceExactMatches
        cliExactMatchesAfter = $appExactMatches
        resourceApiQuerySucceeded = $true
        cliAppListSucceeded = $true
        verified = ($resourceExactMatches -eq 0 -and $appExactMatches -eq 0)
        verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Invoke-SelfTest {
    Assert-Condition ((Get-V4FailureClassification -Value 'Could not prepare app deletion: 404 Resource not found').knownDiagnosticFallbackCondition -eq $true) "self-test-deletion-plan"
    Assert-Condition ((Get-V4FailureClassification -Value 'No unambiguous ownership manifest exists for this app').knownDiagnosticFallbackCondition -eq $true) "self-test-ownership"
    Assert-Condition ((Get-V4FailureClassification -Value '404 Resource not found').knownDiagnosticFallbackCondition -eq $false) "self-test-generic-404"
    Assert-Condition ((Get-V4FailureClassification -Value 'Authentication required before deletion-plan request').knownDiagnosticFallbackCondition -eq $false) "self-test-auth-override"
    Assert-Condition ((Get-Sha256Text -Value 'abc') -ceq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') "self-test-sha"
    $testEnrollment = [pscustomobject]@{
        resourceIdSha256 = (('a' * 64) -join '')
        displayName = 'Exact Test App'
    }
    $testGate = [pscustomobject]@{
        schemaVersion = 'eai.windows-diagnostic-cleanup-child-gate.v1'
        runId = '1999999999999-abc123'
        platform = 'windows'
        appName = 'test-windows-1999999999999-abc123'
        resourceIdSha256 = (('a' * 64) -join '')
        displayName = 'Exact Test App'
        enrollmentExactMatches = 1
        createdDuringThisRun = $true
        exactDisplayNameVerified = $true
        typedConfirmation = $true
        servicesBeforeDeletion = 0
        workflowExactMatchesBeforeDeletion = 0
        setupExactMatchesBeforeDeletion = 0
        sanitized = $true
        diagnostic = $true
    }
    Confirm-ManualFallbackGate -Gate $testGate -RunId $testGate.runId -AppKey $testGate.appName -Enrollment $testEnrollment
    $testGate.servicesBeforeDeletion = 1
    $nonzeroGateRejected = $false
    try {
        Confirm-ManualFallbackGate -Gate $testGate -RunId $testGate.runId -AppKey $testGate.appName -Enrollment $testEnrollment
    } catch {
        $nonzeroGateRejected = $_.Exception.Message -ceq 'fallback-gate-services-nonzero'
    }
    Assert-Condition $nonzeroGateRejected "self-test-nonzero-gate"

    $testAppKey = 'test-windows-1999999999999-abc123'
    $testPackage = [pscustomobject]@{
        name = "@eai-tools/$testAppKey"
        scripts = [pscustomobject]@{ build = 'next build'; typecheck = 'tsc --noEmit' }
        dependencies = [pscustomobject]@{ '@enterpriseaigroup/core' = '1.0.0' }
    }
    Confirm-EaiProjectPackageContract -Package $testPackage -AppKey $testAppKey
    $testManifest = [pscustomobject]@{
        schemaVersion = 1
        template = [pscustomobject]@{
            repo = 'https://github.com/eai-support/eai-app-template.git'
            commit = ('a' * 40)
        }
    }
    Confirm-EaiProjectManifestContract -Manifest $testManifest
    $wrongPackageRejected = $false
    $testPackage.name = '@eai-tools/a-different-app'
    try {
        Confirm-EaiProjectPackageContract -Package $testPackage -AppKey $testAppKey
    } catch {
        $wrongPackageRejected = $_.Exception.Message -ceq 'project-package-name-mismatch'
    }
    Assert-Condition $wrongPackageRejected 'self-test-project-package-mismatch'
    $wrongManifestRejected = $false
    $testManifest.template.repo = 'https://example.invalid/user-controlled-template.git'
    try {
        Confirm-EaiProjectManifestContract -Manifest $testManifest
    } catch {
        $wrongManifestRejected = $_.Exception.Message -ceq 'project-manifest-template-repo-invalid'
    }
    Assert-Condition $wrongManifestRejected 'self-test-project-manifest-mismatch'
    $boundedPage = [pscustomobject]@{
        totalDocs = 1
        resources = @([pscustomobject]@{ id = 'one' })
    }
    Assert-CompleteBoundedResourcePage -Payload $boundedPage -Documents @($boundedPage.resources) -CodePrefix 'self-test-resource-page'
    $truncatedPageRejected = $false
    $boundedPage.totalDocs = 1000
    try {
        Assert-CompleteBoundedResourcePage -Payload $boundedPage -Documents @($boundedPage.resources) -CodePrefix 'self-test-resource-page'
    } catch {
        $truncatedPageRejected = $_.Exception.Message -ceq 'self-test-resource-page-may-be-truncated'
    }
    Assert-Condition $truncatedPageRejected 'self-test-resource-page-truncation'
    [Console]::Out.WriteLine('WINDOWS_DIAGNOSTIC_CLEANUP_SELF_TEST_OK')
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$cleanupInput = @(Read-CleanupInputLines)
$mode = $cleanupInput[0]
$appKey = $cleanupInput[1]
$tenantId = $cleanupInput[2]
$runId = $cleanupInput[3]
$gateBase64 = $cleanupInput[4]
$expectedGuestUser = $cleanupInput[5]
$cleanupInput = $null
$CleanupInputBase64 = @()
$result = $null
$exitCode = 1
$mutationMayHaveOccurred = $false
$verifiedDeletion = $false

try {
    Assert-Condition ($mode -in @('Cleanup', 'VerifyOnly', 'PortalTargetOnly')) "mode-invalid"
    Assert-Condition ($runId -match '^(?<milliseconds>[0-9]{13})-[0-9a-f]{6}$') "run-id-invalid"
    $runStartedMilliseconds = [int64]$Matches.milliseconds
    Assert-Condition ($appKey -ceq "test-windows-$runId") "app-key-not-bound-to-run"
    Assert-Condition ($appKey -match '^[a-z0-9][a-z0-9-]{0,127}$') "app-key-invalid"
    Assert-Condition ($tenantId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$') "tenant-id-invalid"
    Assert-Condition ($expectedGuestUser -match '^[A-Za-z0-9._-]{1,64}$') "expected-guest-user-invalid"
    $runStartedAt = [DateTimeOffset]::FromUnixTimeMilliseconds($runStartedMilliseconds)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    Assert-Condition ($null -ne $identity -and -not $identity.IsSystem) "current-user-is-system"
    Assert-Condition ([Environment]::UserInteractive) "current-user-not-interactive"
    $actualAccountName = ([string]$identity.Name -split '\\')[-1]
    Assert-Condition ([string]::Equals($actualAccountName, $expectedGuestUser, [StringComparison]::OrdinalIgnoreCase)) "current-user-mismatch"

    # Resolve and freeze the only permitted CLI working directory before the
    # first read or mutation. Invoke-Eai revalidates this binding before every
    # command so a later junction/symlink or marker swap fails closed.
    $projectBinding = Resolve-ExactEaiCleanupProject -AppKey $appKey
    $script:ProjectAppKey = $appKey
    $script:ProjectPath = $projectBinding.ProjectPath
    $script:ProjectPackageSha256 = $projectBinding.PackageSha256
    $script:ProjectManifestSha256 = $projectBinding.ManifestSha256
    $script:ProjectObjectTypesSha256 = $projectBinding.ObjectTypesSha256

    $script:EaiPath = Join-Path $env:APPDATA 'npm\eai.cmd'
    $eaiItem = Get-Item -LiteralPath $script:EaiPath -ErrorAction Stop
    Assert-Condition (-not $eaiItem.PSIsContainer) "eai-cli-not-file"
    Assert-Condition (($eaiItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "eai-cli-is-reparse-point"

    if ($mode -ceq 'PortalTargetOnly') {
        $enrollment = Get-ExactEnrollment -AppKey $appKey -TenantId $tenantId -RunStartedAt $runStartedAt
        Assert-Condition ($enrollment.enrollmentExactMatches -eq 1) "portal-target-enrollment-count-invalid"
        Assert-Condition ($enrollment.createdDuringThisRun -eq $true) "portal-target-provenance-invalid"
        Assert-Condition ($enrollment.authoritativeChildQueriesComplete -eq $true) "portal-target-child-query-state-invalid"
        Assert-Condition ($enrollment.servicesBeforeDeletion -eq 0) "portal-target-services-nonzero"
        Assert-Condition ($enrollment.workflowExactMatchesBeforeDeletion -eq 0) "portal-target-workflows-nonzero"
        Assert-Condition ($enrollment.setupExactMatchesBeforeDeletion -eq 0) "portal-target-setup-nonzero"
        $result = [ordered]@{
            schemaVersion = 'eai.windows-diagnostic-cleanup.v1'
            action = 'portal-target-only'
            runId = $runId
            platform = 'windows'
            appName = $appKey
            displayName = $enrollment.displayName
            resourceCreatedAt = $enrollment.resourceCreatedAt
            resourceIdSha256 = $enrollment.resourceIdSha256
            preDeleteValidation = [ordered]@{
                enrollmentExactMatches = 1
                createdDuringThisRun = $true
                sourceVerified = $true
                authoritativeChildQueriesComplete = $true
                childQueries = $enrollment.childQueries
                servicesBeforeDeletion = 0
                verticalProductConfigsBeforeDeletion = 0
                workflowExactMatchesBeforeDeletion = 0
                setupExactMatchesBeforeDeletion = 0
            }
            mutationAttempted = $false
            deleted = $false
            sanitized = $true
            diagnostic = $true
            productionGate = $false
            recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $exitCode = 0
    } elseif ($mode -ceq 'VerifyOnly') {
        $absence = Get-AbsenceEvidence -AppKey $appKey -TenantId $tenantId
        $result = [ordered]@{
            schemaVersion = 'eai.windows-diagnostic-cleanup.v1'
            action = 'verify-only'
            runId = $runId
            platform = 'windows'
            appName = $appKey
            absence = $absence
            deleted = $false
            portalVerificationRequired = $true
            cleanupVerified = $false
            sanitized = $true
            diagnostic = $true
            productionGate = $false
            recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $exitCode = if ($absence.verified) { 0 } else { 4 }
    } else {
        $enrollment = Get-ExactEnrollment -AppKey $appKey -TenantId $tenantId -RunStartedAt $runStartedAt
        $v4 = Invoke-Eai -Arguments @(
            'app', 'delete', $appKey,
            '--tenant-id', $tenantId,
            '--confirm', $appKey,
            '--non-interactive',
            '--format', 'json'
        )
        $classification = Get-V4FailureClassification -Value $v4.text
        $v4Evidence = [ordered]@{
            attempts = 1
            exitCode = $v4.exitCode
            outputLineCount = $v4.outputLineCount
            sanitizedOutputSha256 = $v4.outputSha256
            classification = $classification
            sanitized = $true
            diagnostic = $true
            attemptedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $deletion = $null
        $action = 'failed'
        $method = 'none'
        $deleted = $false

        if ($v4.exitCode -eq 0) {
            $mutationMayHaveOccurred = $true
            $v4Receipt = ConvertFrom-StrictJson -Value $v4.text -Code "v4-delete-invalid-json"
            Assert-Condition ([string]$v4Receipt.schemaVersion -ceq 'eai.app-deletion-receipt.v1') "v4-delete-schema-invalid"
            Assert-Condition ([string]$v4Receipt.status -ceq 'deleted' -and $v4Receipt.verified -eq $true) "v4-delete-not-verified"
            Assert-Condition ([string]$v4Receipt.appKey -ceq $appKey) "v4-delete-app-mismatch"
            Assert-Condition ([string]$v4Receipt.tenantId -ceq $tenantId) "v4-delete-tenant-mismatch"
            $operationId = [string]$v4Receipt.operationId
            Assert-Condition (-not [string]::IsNullOrWhiteSpace($operationId)) "v4-delete-operation-id-missing"
            $deletion = [ordered]@{
                method = 'public-api-v4-cli'
                exitCode = 0
                verified = $true
                operationIdSha256 = Get-Sha256Text -Value $operationId
            }
            $action = 'deleted-v4'
            $method = 'public-api-v4-cli'
            $deleted = $true
            $verifiedDeletion = $true
            $mutationMayHaveOccurred = $false
        } elseif ($classification.knownDiagnosticFallbackCondition) {
            if ([string]::IsNullOrWhiteSpace($gateBase64)) {
                $result = [ordered]@{
                    schemaVersion = 'eai.windows-diagnostic-cleanup.v1'
                    action = 'fallback-gate-required'
                    runId = $runId
                    platform = 'windows'
                    appName = $appKey
                    displayName = $enrollment.displayName
                    resourceCreatedAt = $enrollment.resourceCreatedAt
                    resourceIdSha256 = $enrollment.resourceIdSha256
                    preDeleteValidation = [ordered]@{
                        enrollmentExactMatches = 1
                        createdDuringThisRun = $true
                        sourceVerified = $true
                        authoritativeChildQueriesComplete = $true
                        childQueries = $enrollment.childQueries
                        servicesBeforeDeletion = $null
                        verticalProductConfigsBeforeDeletion = $null
                        workflowExactMatchesBeforeDeletion = $null
                        setupExactMatchesBeforeDeletion = $null
                    }
                    v4Attempt = $v4Evidence
                    deleted = $false
                    portalDeleteAutomationAvailable = $false
                    portalVerificationRequired = $true
                    cleanupVerified = $false
                    sanitized = $true
                    diagnostic = $true
                    productionGate = $false
                    recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
                }
                $exitCode = 3
            } else {
                try {
                    $gateJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($gateBase64))
                } catch {
                    throw "fallback-gate-base64-invalid"
                }
                $gate = ConvertFrom-StrictJson -Value $gateJson -Code "fallback-gate-invalid-json"
                Confirm-ManualFallbackGate -Gate $gate -RunId $runId -AppKey $appKey -Enrollment $enrollment
                $fallback = Invoke-Eai -Arguments @(
                    'resources', 'delete', 'tenant-vertical-enrollment', $enrollment.recordId,
                    '--tenant-id', $tenantId,
                    '--force',
                    '--format', 'json'
                )
                Assert-Condition ($fallback.exitCode -eq 0) "fallback-delete-failed"
                $mutationMayHaveOccurred = $true
                $fallbackReceipt = ConvertFrom-StrictJson -Value $fallback.text -Code "fallback-delete-invalid-json"
                Assert-Condition ([string]$fallbackReceipt.type -ceq 'tenant-vertical-enrollment') "fallback-delete-type-mismatch"
                Assert-Condition ([string]$fallbackReceipt.id -ceq [string]$enrollment.recordId) "fallback-delete-id-mismatch"
                Assert-Condition ($fallbackReceipt.deleted -eq $true) "fallback-delete-not-confirmed"
                $deletion = [ordered]@{
                    method = 'resource-api-fallback-after-known-v4-failure'
                    exitCode = 0
                    jsonParsed = $true
                    returnedIdMatched = $true
                    deleted = $true
                    outputSha256 = $fallback.outputSha256
                }
                $action = 'deleted-fallback'
                $method = 'resource-api-fallback-after-known-v4-failure'
                $deleted = $true
                $verifiedDeletion = $true
                $mutationMayHaveOccurred = $false
            }
        } else {
            $result = [ordered]@{
                schemaVersion = 'eai.windows-diagnostic-cleanup.v1'
                action = 'v4-failed-not-eligible-for-fallback'
                runId = $runId
                platform = 'windows'
                appName = $appKey
                v4Attempt = $v4Evidence
                deleted = $false
                portalDeleteAutomationAvailable = $false
                portalVerificationRequired = $true
                cleanupVerified = $false
                sanitized = $true
                diagnostic = $true
                productionGate = $false
                recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
            }
            $exitCode = 2
        }

        if ($deleted) {
            $absence = $null
            $absenceErrorCode = $null
            try {
                $absence = Get-AbsenceEvidence -AppKey $appKey -TenantId $tenantId
            } catch {
                $absenceErrorCode = [string]$_.Exception.Message
                if ($absenceErrorCode -notmatch '^[a-z0-9-]{3,100}$') { $absenceErrorCode = 'absence-verification-failed' }
                $absence = [ordered]@{
                    resourceApiExactMatchesAfter = $null
                    cliExactMatchesAfter = $null
                    resourceApiQuerySucceeded = $false
                    cliAppListSucceeded = $false
                    verified = $false
                    errorCode = $absenceErrorCode
                    verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
                }
            }
            $result = [ordered]@{
                schemaVersion = 'eai.windows-diagnostic-cleanup.v1'
                action = $action
                runId = $runId
                platform = 'windows'
                appName = $appKey
                displayName = $enrollment.displayName
                resourceCreatedAt = $enrollment.resourceCreatedAt
                resourceIdSha256 = $enrollment.resourceIdSha256
                method = $method
                preDeleteValidation = [ordered]@{
                    enrollmentExactMatches = 1
                    createdDuringThisRun = $true
                    sourceVerified = $true
                    authoritativeChildQueriesComplete = $true
                    childQueries = $enrollment.childQueries
                    servicesBeforeDeletion = 0
                    verticalProductConfigsBeforeDeletion = 0
                    workflowExactMatchesBeforeDeletion = 0
                    setupExactMatchesBeforeDeletion = 0
                }
                v4Attempt = $v4Evidence
                deletion = $deletion
                absence = $absence
                deleted = $true
                portalDeleteAutomationAvailable = $false
                portalVerificationRequired = $true
                cleanupVerified = $false
                sanitized = $true
                diagnostic = $true
                productionGate = $false
                recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
            }
            $exitCode = if ($absence.verified) { 0 } else { 4 }
        }
    }
} catch {
    $errorCode = [string]$_.Exception.Message
    if ($errorCode -notmatch '^[a-z0-9-]{3,100}$') {
        $line = [int]$_.InvocationInfo.ScriptLineNumber
        $stackLine = 0
        $stackMatch = [regex]::Match([string]$_.ScriptStackTrace, '(?i)line\s+(\d+)')
        if ($stackMatch.Success) { [void][int]::TryParse($stackMatch.Groups[1].Value, [ref]$stackLine) }
        $errorCode = if ($line -gt 0 -and $stackLine -gt 0) {
            "guest-cleanup-failed-line-$line-stack-$stackLine"
        } elseif ($line -gt 0) {
            "guest-cleanup-failed-line-$line"
        } else {
            'guest-cleanup-failed'
        }
    }
    $result = [ordered]@{
        schemaVersion = 'eai.windows-diagnostic-cleanup.v1'
        action = if ($mutationMayHaveOccurred) { 'mutation-uncertain' } else { 'failed' }
        runId = if ($runId -match '^[0-9]{13}-[0-9a-f]{6}$') { $runId } else { '[INVALID]' }
        platform = 'windows'
        appName = if ($appKey -match '^[a-z0-9][a-z0-9-]{0,127}$') { $appKey } else { '[INVALID]' }
        errorCode = $errorCode
        deleted = $verifiedDeletion
        mutationState = if ($mutationMayHaveOccurred) { 'uncertain' } elseif ($verifiedDeletion) { 'verified-deleted' } else { 'not-applied' }
        retryMutationAutomatically = $false
        portalDeleteAutomationAvailable = $false
        portalVerificationRequired = $true
        cleanupVerified = $false
        sanitized = $true
        diagnostic = $true
        productionGate = $false
        recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $exitCode = 1
} finally {
    $tenantId = $null
    $gateBase64 = $null
}

[Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 12 -Compress))
exit $exitCode
