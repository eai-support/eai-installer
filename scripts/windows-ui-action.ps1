Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# This helper deliberately has no text/value input action. It reads only the
# browser address bar to validate a fixed HTTPS origin, then finds, focuses, or
# invokes fixed UI Automation elements. It never reads a page form value.
# login-windows-guest.sh streams protected text through Parallels keyboard
# events after this helper has focused the approved field.

function Initialize-WindowsUiAutomation {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
}

function Get-EdgeProcessIds {
    $currentSessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $ids = @(
        Get-Process -Name "msedge" -ErrorAction SilentlyContinue |
            Where-Object {
                -not $_.HasExited -and $_.SessionId -eq $currentSessionId
            } |
            Select-Object -ExpandProperty Id -Unique
    )
    return $ids
}

function Get-UiControlType {
    param([Parameter(Mandatory = $true)][string]$Name)

    switch ($Name) {
        "Button" { return [System.Windows.Automation.ControlType]::Button }
        "Edit" { return [System.Windows.Automation.ControlType]::Edit }
        "Hyperlink" { return [System.Windows.Automation.ControlType]::Hyperlink }
        "Any" { return $null }
        default { throw "Unsupported UI Automation control type." }
    }
}

function Find-ExactEdgeElements {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][ValidateSet("Button", "Edit", "Hyperlink", "Any")][string]$ControlType,
        [bool]$RequireEnabled = $true
    )

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $type = Get-UiControlType -Name $ControlType
    $matches = @{}

    foreach ($processId in @(Get-EdgeProcessIds)) {
        foreach ($name in $Names) {
            $conditions = @(
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
                    [int]$processId
                ),
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty,
                    [string]$name
                )
            )
            if ($null -ne $type) {
                $conditions += [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    $type
                )
            }
            $condition = [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.Condition[]]$conditions
            )
            $found = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                $condition
            )
            for ($index = 0; $index -lt $found.Count; $index += 1) {
                $element = $found.Item($index)
                if ($element.Current.IsOffscreen -or
                    ($RequireEnabled -and -not $element.Current.IsEnabled)) {
                    continue
                }
                try {
                    $runtimeId = [string]::Join(".", $element.GetRuntimeId())
                } catch {
                    $runtimeId = "{0}:{1}:{2}" -f $processId, $name, $index
                }
                $matches[$runtimeId] = $element
            }
        }
    }

    return @($matches.Values)
}

function Wait-ExactEdgeElement {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][ValidateSet("Button", "Edit", "Hyperlink", "Any")][string]$ControlType,
        [Parameter(Mandatory = $true)][ValidateRange(1, 300)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $matches = @(Find-ExactEdgeElements -Names $Names -ControlType $ControlType)
        if ($matches.Count -gt 1) {
            throw "More than one visible approved UI element matched; refusing an ambiguous action."
        }
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Timed out waiting for the approved UI element."
}

function Test-ExactEdgeElement {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][ValidateSet("Button", "Edit", "Hyperlink", "Any")][string]$ControlType
    )

    return @(Find-ExactEdgeElements -Names $Names -ControlType $ControlType).Count -gt 0
}

function Test-ExactEdgeState {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][ValidateSet("Button", "Edit", "Hyperlink", "Any")][string]$ControlType,
        [Parameter(Mandatory = $true)][string]$ExpectedHost,
        [string]$ExpectedPath = ""
    )

    try {
        Assert-EdgeLocation -ExpectedHost $ExpectedHost -ExpectedPath $ExpectedPath
    } catch {
        return $false
    }
    $matches = @(Find-ExactEdgeElements -Names $Names -ControlType $ControlType)
    if ($matches.Count -gt 1) {
        throw "More than one visible approved destination element matched; refusing an ambiguous state."
    }
    return $matches.Count -eq 1
}

function Get-TopLevelWindow {
    param([Parameter(Mandatory = $true)]$Element)

    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $rootKey = Get-ElementRuntimeKey -Element $root
    $current = $Element
    while ($null -ne $current) {
        $parent = $walker.GetParent($current)
        if ($null -eq $parent) { break }
        if ((Get-ElementRuntimeKey -Element $parent) -ceq $rootKey) {
            if ($current.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) {
                throw "The Edge element is not contained by one top-level window."
            }
            $handle = [int64]$current.Current.NativeWindowHandle
            if ($handle -le 0) {
                throw "The Edge top-level window has no native HWND."
            }
            $roundTrip = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$handle)
            if ($null -eq $roundTrip -or
                (Get-ElementRuntimeKey -Element $roundTrip) -cne (Get-ElementRuntimeKey -Element $current)) {
                throw "The Edge top-level HWND does not round-trip to the same UI Automation window."
            }
            return $current
        }
        $current = $parent
    }
    throw "The Edge element top-level window could not be resolved."
}

function Get-UniqueEdgeAddressContext {
    $element = Wait-ExactEdgeElement -Names @("Address and search bar") -ControlType "Edit" -TimeoutSeconds 2
    $pattern = $null
    if (-not $element.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref]$pattern
    )) {
        throw "The active Edge address bar does not expose UI Automation ValuePattern."
    }
    $rawValue = ([System.Windows.Automation.ValuePattern]$pattern).Current.Value
    $uri = $null
    if (-not [System.Uri]::TryCreate(
        [string]$rawValue,
        [System.UriKind]::Absolute,
        [ref]$uri
    )) {
        throw "The active Edge address is not an absolute URI."
    }
    if ($uri.Scheme -cne "https") {
        throw "The active Edge page is not HTTPS."
    }
    $window = Get-TopLevelWindow -Element $element
    if ($window.Current.ProcessId -ne $element.Current.ProcessId) {
        throw "The Edge address bar and top-level window do not share one process."
    }
    return [pscustomobject]@{
        Uri = $uri
        Element = $element
        Window = $window
        Hwnd = [int64]$window.Current.NativeWindowHandle
        WindowProcessId = [int]$window.Current.ProcessId
        WindowRuntimeKey = Get-ElementRuntimeKey -Element $window
    }
}

function Get-UniqueEdgeAddressUri {
    return (Get-UniqueEdgeAddressContext).Uri
}

function Assert-EdgeLocation {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedHost,
        [string]$ExpectedPath = ""
    )

    $uri = Get-UniqueEdgeAddressUri
    if ($uri.Host -ine $ExpectedHost) {
        throw "The active Edge page is not on the approved origin."
    }
    if (-not [string]::IsNullOrEmpty($ExpectedPath) -and
        $uri.AbsolutePath.TrimEnd("/") -ine $ExpectedPath.TrimEnd("/")) {
        throw "The active Edge page does not use the approved path."
    }
}

function Test-PortalReady {
    try {
        $uri = Get-UniqueEdgeAddressUri
    } catch {
        return $false
    }
    $normalizedPath = $uri.AbsolutePath.TrimEnd("/")
    if ($uri.Host -ine "admin-portal.myenterprise.ai" -or
        $normalizedPath -ine "/platform/getting-started") {
        return $false
    }
    $gettingStarted = Test-ExactEdgeElement -Names @("Getting started") -ControlType "Any"
    $allApps = Test-ExactEdgeElement -Names @("All apps") -ControlType "Any"
    return $gettingStarted -and $allApps
}

function Invoke-UiElement {
    param([Parameter(Mandatory = $true)]$Element)

    try {
        $Element.SetFocus()
    } catch {
        # Some web buttons expose InvokePattern without keyboard focusability.
    }
    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$pattern
    )) {
        throw "The approved button does not expose UI Automation InvokePattern."
    }
    ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
}

function Expand-UiElement {
    param([Parameter(Mandatory = $true)]$Element)

    try {
        $Element.SetFocus()
    } catch {
        # Split-button arrows need not be keyboard focusable.
    }
    $pattern = $null
    if (-not $Element.TryGetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
        [ref]$pattern
    )) {
        throw "The approved split-button arrow does not expose UI Automation ExpandCollapsePattern."
    }
    $expandPattern = [System.Windows.Automation.ExpandCollapsePattern]$pattern
    switch ($expandPattern.Current.ExpandCollapseState) {
        ([System.Windows.Automation.ExpandCollapseState]::Collapsed) {
            $expandPattern.Expand()
        }
        ([System.Windows.Automation.ExpandCollapseState]::Expanded) {
            return
        }
        default {
            throw "The approved split-button arrow is not in an exact expandable state."
        }
    }
}

function Focus-UiElement {
    param([Parameter(Mandatory = $true)]$Element)

    $Element.SetFocus()
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        if ($Element.Current.HasKeyboardFocus) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "The approved input field did not receive keyboard focus."
}

function Invoke-ExactEdgeButton {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$ExpectedHost = "",
        [string]$ExpectedPath = ""
    )

    $element = Wait-ExactEdgeElement -Names $Names -ControlType "Button" -TimeoutSeconds $TimeoutSeconds
    if (-not [string]::IsNullOrEmpty($ExpectedHost)) {
        Assert-EdgeLocation -ExpectedHost $ExpectedHost -ExpectedPath $ExpectedPath
    }
    Invoke-UiElement -Element $element
}

function Focus-ExactEdgeEdit {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$ExpectedHost = "",
        [string]$ExpectedPath = ""
    )

    $element = Wait-ExactEdgeElement -Names $Names -ControlType "Edit" -TimeoutSeconds $TimeoutSeconds
    if (-not [string]::IsNullOrEmpty($ExpectedHost)) {
        Assert-EdgeLocation -ExpectedHost $ExpectedHost -ExpectedPath $ExpectedPath
    }
    Focus-UiElement -Element $element
}

function Focus-ExactEdgePasswordEdit {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $conditions = @(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Edit
            ),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
                "i0118"
            ),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty,
                "Enter the password for {0}"
            ),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::IsPasswordProperty,
                $true
            )
        )
        $found = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.Condition[]]$conditions
            )
        )
        $approvedProcessIds = @(Get-EdgeProcessIds)
        $matches = @()
        for ($index = 0; $index -lt $found.Count; $index += 1) {
            $element = $found.Item($index)
            if ($approvedProcessIds -contains $element.Current.ProcessId -and
                -not $element.Current.IsOffscreen -and
                $element.Current.IsEnabled) {
                $matches += $element
            }
        }
        if ($matches.Count -gt 1) {
            throw "More than one visible approved password field matched; refusing an ambiguous action."
        }
        if ($matches.Count -eq 1) {
            Assert-EdgeLocation -ExpectedHost "enterpriseaiplatform.ciamlogin.com"
            Focus-UiElement -Element $matches[0]
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for the approved password field."
}

function Invoke-ExactEdgeHyperlink {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$ExpectedHost = "",
        [string]$ExpectedPath = ""
    )

    $element = Wait-ExactEdgeElement -Names $Names -ControlType "Hyperlink" -TimeoutSeconds $TimeoutSeconds
    if (-not [string]::IsNullOrEmpty($ExpectedHost)) {
        Assert-EdgeLocation -ExpectedHost $ExpectedHost -ExpectedPath $ExpectedPath
    }
    Invoke-UiElement -Element $element
}

function Invoke-OptionalExactEdgeButton {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [string]$ExpectedHost = "",
        [string]$ExpectedPath = ""
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $matches = @(Find-ExactEdgeElements -Names $Names -ControlType "Button")
        if ($matches.Count -gt 1) {
            throw "More than one visible approved UI element matched; refusing an ambiguous action."
        }
        if ($matches.Count -eq 1) {
            if (-not [string]::IsNullOrEmpty($ExpectedHost)) {
                Assert-EdgeLocation -ExpectedHost $ExpectedHost -ExpectedPath $ExpectedPath
            }
            Invoke-UiElement -Element $matches[0]
            return $true
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Dismiss-EdgeFirstRun {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)

    $approvedNames = @(
        "Start without your data",
        "Continue without signing in",
        "Confirm and continue",
        "Confirm and start browsing",
        "Skip and continue",
        "Accept and get started",
        "Not now"
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $matches = @(Find-ExactEdgeElements -Names $approvedNames -ControlType "Button")
        if ($matches.Count -gt 1) {
            throw "More than one visible Edge first-run action matched; refusing an ambiguous action."
        }
        if ($matches.Count -eq 1) {
            Invoke-UiElement -Element $matches[0]
            Start-Sleep -Milliseconds 750
            continue
        }
        $approvedLocation = $false
        try {
            Assert-EdgeLocation -ExpectedHost "www.enterpriseaigroup.com" -ExpectedPath "/sign-in"
            $approvedLocation = $true
        } catch {
            # Edge is still between approved first-run pages.
        }
        if ($approvedLocation) {
            if (Test-ExactEdgeElement -Names @("Continue with Email, Google, or Microsoft") -ControlType "Hyperlink") {
                return
            }
            # Edge's network error page retains the exact approved address and
            # exposes a single Refresh button. Retrying that exact origin is a
            # safe recovery from a transient snapshot/network race.
            $refreshMatches = @(Find-ExactEdgeElements -Names @("Refresh") -ControlType "Button")
            if ($refreshMatches.Count -gt 1) {
                throw "More than one visible Edge refresh action matched; refusing an ambiguous action."
            }
            if ($refreshMatches.Count -eq 1) {
                Invoke-UiElement -Element $refreshMatches[0]
                Start-Sleep -Seconds 2
                continue
            }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out while completing Edge first-run setup."
}

function Wait-PortalReady {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-PortalReady) {
            return
        }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for the authenticated portal controls."
}

function Test-PostSignInState {
    if (Test-PortalReady) {
        return $true
    }
    foreach ($name in @("Not now", "Yes")) {
        if (Test-ExactEdgeState -Names @($name) -ControlType "Button" -ExpectedHost "enterpriseaiplatform.ciamlogin.com") {
            return $true
        }
    }
    return $false
}

function Assert-PortalAppsLocation {
    [void](Get-PortalAppsContext)
}

function Get-PortalAppsContext {
    $context = Get-UniqueEdgeAddressContext
    $uri = $context.Uri
    if ($uri.Scheme -cne "https" -or
        $uri.Host -ine "admin-portal.myenterprise.ai" -or
        -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        $uri.AbsolutePath.TrimEnd("/") -ine "/platform/apps" -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "The active Edge page is not the exact approved Admin Portal apps page."
    }
    return $context
}

function Get-ElementRuntimeKey {
    param([Parameter(Mandatory = $true)]$Element)

    try {
        return [string]::Join(".", $Element.GetRuntimeId())
    } catch {
        $rect = $Element.Current.BoundingRectangle
        return ("{0}:{1}:{2}:{3}:{4}:{5}" -f @(
            $Element.Current.ProcessId,
            $Element.Current.ControlType.Id,
            $Element.Current.Name,
            $rect.X,
            $rect.Y,
            $rect.Width
        ))
    }
}

function Get-VisibleDescendantElements {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [string]$Name = "",
        [ValidateSet("Button", "Edit", "Hyperlink", "Any")][string]$ControlType = "Any",
        [bool]$RequireEnabled = $true
    )

    $conditions = @()
    if (-not [string]::IsNullOrEmpty($Name)) {
        $conditions += [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $Name
        )
    }
    $type = Get-UiControlType -Name $ControlType
    if ($null -ne $type) {
        $conditions += [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            $type
        )
    }
    $condition = if ($conditions.Count -eq 0) {
        [System.Windows.Automation.Condition]::TrueCondition
    } elseif ($conditions.Count -eq 1) {
        $conditions[0]
    } else {
        [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.Condition[]]$conditions
        )
    }
    $found = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $condition
    )
    $matches = @{}
    for ($index = 0; $index -lt $found.Count; $index += 1) {
        $element = $found.Item($index)
        if ($element.Current.IsOffscreen -or
            ($RequireEnabled -and -not $element.Current.IsEnabled)) {
            continue
        }
        $matches[(Get-ElementRuntimeKey -Element $element)] = $element
    }
    return @($matches.Values)
}

function Find-ExactInvokableEdgeElements {
    param([Parameter(Mandatory = $true)][string[]]$Names)

    $matches = @{}
    foreach ($element in @(Find-ExactEdgeElements -Names $Names -ControlType "Any")) {
        $pattern = $null
        if ($element.TryGetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern,
            [ref]$pattern
        )) {
            $matches[(Get-ElementRuntimeKey -Element $element)] = $element
        }
    }
    return @($matches.Values)
}

function ConvertFrom-CleanupTargetBase64 {
    param(
        [Parameter(Mandatory = $true)][string]$AppKeyBase64,
        [Parameter(Mandatory = $true)][string]$DisplayNameBase64
    )

    try {
        $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
        $appKey = $utf8.GetString([Convert]::FromBase64String($AppKeyBase64))
        $displayName = $utf8.GetString([Convert]::FromBase64String($DisplayNameBase64))
    } catch {
        throw "The cleanup target encoding is invalid."
    }
    if ($appKey -cnotmatch '^test-windows-[0-9]{13}-[0-9a-f]{6}$' -or
        $appKey.Length -gt 128) {
        throw "The cleanup app key is not bound to a Windows release run."
    }
    if ([string]::IsNullOrWhiteSpace($displayName) -or
        $displayName.Length -gt 200 -or
        $displayName -match '[\x00-\x1f\x7f]') {
        throw "The cleanup display name is invalid."
    }
    return [pscustomobject]@{
        AppKey = $appKey
        DisplayName = $displayName
    }
}

function Test-RectanglesAreAdjacentSplitButtons {
    param(
        [Parameter(Mandatory = $true)]$Primary,
        [Parameter(Mandatory = $true)]$Arrow
    )

    $primaryRect = $Primary.Current.BoundingRectangle
    $arrowRect = $Arrow.Current.BoundingRectangle
    if ($primaryRect.IsEmpty -or $arrowRect.IsEmpty -or
        $primaryRect.Width -le 0 -or $primaryRect.Height -le 0 -or
        $arrowRect.Width -le 0 -or $arrowRect.Height -le 0) {
        return $false
    }
    $gap = $arrowRect.Left - $primaryRect.Right
    $primaryCenter = $primaryRect.Top + ($primaryRect.Height / 2)
    $arrowCenter = $arrowRect.Top + ($arrowRect.Height / 2)
    return $gap -ge -2 -and $gap -le 32 -and
        [Math]::Abs($primaryCenter - $arrowCenter) -le 4 -and
        $arrowRect.Width -le $primaryRect.Width
}

function Get-CreateAppSplitArrow {
    Assert-PortalAppsLocation
    $createMatches = @(Find-ExactEdgeElements -Names @("Create app") -ControlType "Button")
    if ($createMatches.Count -ne 1) {
        throw "The Admin Portal does not expose one unique exact Create app button."
    }
    $create = $createMatches[0]
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $ancestor = $walker.GetParent($create)
    $arrowMatches = @{}
    for ($depth = 0; $depth -lt 8 -and $null -ne $ancestor; $depth += 1) {
        $buttons = @(Get-VisibleDescendantElements -Root $ancestor -ControlType "Button")
        $createDescendants = @($buttons | Where-Object { $_.Current.Name -ceq "Create app" })
        if ($createDescendants.Count -eq 1 -and $buttons.Count -eq 2) {
            $arrow = @($buttons | Where-Object {
                (Get-ElementRuntimeKey -Element $_) -cne (Get-ElementRuntimeKey -Element $create)
            })
            if ($arrow.Count -eq 1 -and
                (Test-RectanglesAreAdjacentSplitButtons -Primary $create -Arrow $arrow[0])) {
                $arrowMatches[(Get-ElementRuntimeKey -Element $arrow[0])] = $arrow[0]
            }
        }
        $ancestor = $walker.GetParent($ancestor)
    }
    if ($arrowMatches.Count -ne 1) {
        throw "The exact Create app split-button arrow is missing or structurally ambiguous."
    }
    return @($arrowMatches.Values)[0]
}

function Get-ManageAppSearchEdit {
    $names = @(
        "Search",
        "Search apps",
        "Search apps...",
        "Search apps…",
        "Search app",
        "Search by name or key",
        "Search by app name or key",
        "Search by app name or key...",
        "Search by app name or key…",
        "Search apps by name or key",
        "Search apps by name or key...",
        "Search apps by name or key…"
    )
    $candidates = @(Find-ExactEdgeElements -Names $names -ControlType "Edit")
    $matches = @{}
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    foreach ($candidate in $candidates) {
        $ancestor = $walker.GetParent($candidate)
        for ($depth = 0; $depth -lt 8 -and $null -ne $ancestor; $depth += 1) {
            $manageElementsByRuntimeId = @{}
            foreach ($headingName in @("Manage app", "Manage apps")) {
                foreach ($manageElement in @(Get-VisibleDescendantElements -Root $ancestor -Name $headingName -ControlType "Any")) {
                    $manageElementsByRuntimeId[(Get-ElementRuntimeKey -Element $manageElement)] = $manageElement
                }
            }
            $manageElements = @($manageElementsByRuntimeId.Values)
            $headings = @($manageElements | Where-Object {
                $pattern = $null
                $invokable = $_.TryGetCurrentPattern(
                    [System.Windows.Automation.InvokePattern]::Pattern,
                    [ref]$pattern
                )
                $invokableAncestor = $false
                $headingAncestor = $walker.GetParent($_)
                for ($headingDepth = 0; $headingDepth -lt 4 -and $null -ne $headingAncestor; $headingDepth += 1) {
                    if ($headingAncestor.Current.Name -in @("Manage app", "Manage apps")) {
                        $ancestorPattern = $null
                        if ($headingAncestor.TryGetCurrentPattern(
                            [System.Windows.Automation.InvokePattern]::Pattern,
                            [ref]$ancestorPattern
                        )) {
                            $invokableAncestor = $true
                            break
                        }
                    }
                    $headingAncestor = $walker.GetParent($headingAncestor)
                }
                -not $invokable -and -not $invokableAncestor
            })
            if ($headings.Count -eq 1) {
                $matches[(Get-ElementRuntimeKey -Element $candidate)] = $candidate
                break
            }
            if ($headings.Count -gt 1) {
                throw "The Manage app heading is structurally ambiguous."
            }
            $ancestor = $walker.GetParent($ancestor)
        }
    }
    if ($matches.Count -gt 1) {
        throw "The Manage app search field is structurally ambiguous."
    }
    if ($matches.Count -eq 1) { return @($matches.Values)[0] }
    return $null
}

function Wait-ManageAppSearchEdit {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 300)][int]$TimeoutSeconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Assert-PortalAppsLocation
        $edit = Get-ManageAppSearchEdit
        if ($null -ne $edit) { return $edit }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for the exact Manage app search field."
}

function Get-ManageAppDialogWindow {
    Assert-PortalAppsLocation
    $matches = @(
        Find-ExactEdgeElements -Names @("Manage app", "Manage apps") -ControlType "Any" |
            Where-Object {
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window
            }
    )
    if ($matches.Count -gt 1) {
        throw "The Manage app modal is structurally ambiguous."
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Wait-ManageAppSurface {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 300)][int]$TimeoutSeconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Assert-PortalAppsLocation
        if ($null -ne (Get-ManageAppSearchEdit) -or
            $null -ne (Get-ManageAppDialogWindow)) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for the exact Manage app surface."
}

function Test-ExactTargetInSubtree {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)]$Target
    )

    $displayMatches = @(Get-VisibleDescendantElements -Root $Root -Name $Target.DisplayName -ControlType "Any")
    $keyMatches = @(Get-VisibleDescendantElements -Root $Root -Name $Target.AppKey -ControlType "Any")
    # The current Manage app table exposes the run-unique display name and an
    # exact accessible delete name, but not the app key. When a key is exposed
    # by another portal build it must still be unique. The following
    # confirmation dialog provides the mandatory exact app-key binding before
    # any destructive action is enabled.
    return $displayMatches.Count -eq 1 -and $keyMatches.Count -le 1
}

function Get-ExactAppDeleteControl {
    param([Parameter(Mandatory = $true)]$Target)

    Assert-PortalAppsLocation
    $deleteName = "Delete {0}" -f $Target.DisplayName
    $deleteMatches = @(Find-ExactInvokableEdgeElements -Names @($deleteName))
    if ($deleteMatches.Count -gt 1) {
        throw "The exact app delete control is ambiguous."
    }
    if ($deleteMatches.Count -eq 0) {
        throw "The exact app delete control is not available."
    }
    $delete = $deleteMatches[0]
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $ancestor = $walker.GetParent($delete)
    $boundedRows = @{}
    for ($depth = 0; $depth -lt 10 -and $null -ne $ancestor; $depth += 1) {
        if (Test-ExactTargetInSubtree -Root $ancestor -Target $Target) {
            $deletes = @(Get-VisibleDescendantElements -Root $ancestor -Name $deleteName -ControlType "Any")
            if ($deletes.Count -eq 1) {
                $boundedRows[(Get-ElementRuntimeKey -Element $delete)] = $delete
                break
            }
        }
        $ancestor = $walker.GetParent($ancestor)
    }
    if ($boundedRows.Count -ne 1) {
        throw "The delete control is not bounded to one row containing the exact run-unique app name."
    }
    return @($boundedRows.Values)[0]
}

function Wait-ExactAppDeleteControl {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)][ValidateRange(1, 300)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            return Get-ExactAppDeleteControl -Target $Target
        } catch {
            if ($_.Exception.Message -match 'ambiguous') { throw }
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for the exact app delete control."
}

function Get-DeleteConfirmationState {
    param([Parameter(Mandatory = $true)]$Target)

    $context = Get-PortalAppsContext
    $finalMatches = @(Get-VisibleDescendantElements -Root $context.Window -Name "Delete permanently" -ControlType "Button" -RequireEnabled $false)
    if ($finalMatches.Count -gt 1) {
        throw "The permanent-delete control is ambiguous."
    }
    if ($finalMatches.Count -eq 0) {
        throw "The permanent-delete control is not available."
    }
    $final = $finalMatches[0]
    $headingName = "Delete {0}?" -f $Target.DisplayName
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $ancestor = $walker.GetParent($final)
    $states = @()
    for ($depth = 0; $depth -lt 10 -and $null -ne $ancestor; $depth += 1) {
        $headings = @(Get-VisibleDescendantElements -Root $ancestor -Name $headingName -ControlType "Any")
        $keyNames = @(
            $Target.AppKey,
            ("Type {0} to confirm" -f $Target.AppKey),
            ("Type {0} to confirm:" -f $Target.AppKey),
            ("Enter {0} to confirm" -f $Target.AppKey),
            ("Enter {0} to confirm:" -f $Target.AppKey)
        )
        $keysByRuntimeId = @{}
        foreach ($keyName in $keyNames) {
            foreach ($keyElement in @(Get-VisibleDescendantElements -Root $ancestor -Name $keyName -ControlType "Any")) {
                $keysByRuntimeId[(Get-ElementRuntimeKey -Element $keyElement)] = $keyElement
            }
        }
        $keys = @($keysByRuntimeId.Values)
        $edits = @(Get-VisibleDescendantElements -Root $ancestor -ControlType "Edit")
        $finals = @(Get-VisibleDescendantElements -Root $ancestor -Name "Delete permanently" -ControlType "Button" -RequireEnabled $false)
        if ($headings.Count -eq 1 -and $keys.Count -ge 1 -and
            $edits.Count -eq 1 -and $finals.Count -eq 1) {
            $editWindow = Get-TopLevelWindow -Element $edits[0]
            $finalWindow = Get-TopLevelWindow -Element $final
            if ((Get-ElementRuntimeKey -Element $editWindow) -cne $context.WindowRuntimeKey -or
                (Get-ElementRuntimeKey -Element $finalWindow) -cne $context.WindowRuntimeKey -or
                [int64]$editWindow.Current.NativeWindowHandle -ne $context.Hwnd -or
                [int64]$finalWindow.Current.NativeWindowHandle -ne $context.Hwnd -or
                $final.Current.ProcessId -ne $context.WindowProcessId -or
                $edits[0].Current.ProcessId -ne $context.WindowProcessId) {
                throw "The delete dialog, address bar, and permanent-delete button do not share one exact Edge HWND and process."
            }
            $states += [pscustomobject]@{
                Root = $ancestor
                Edit = $edits[0]
                Final = $final
                Window = $context.Window
                WindowHandle = $context.Hwnd
                WindowProcessId = $context.WindowProcessId
                WindowRuntimeKey = $context.WindowRuntimeKey
                FinalRuntimeKey = Get-ElementRuntimeKey -Element $final
            }
            break
        }
        $ancestor = $walker.GetParent($ancestor)
    }
    if ($states.Count -ne 1) {
        throw "The permanent-delete dialog is not available with one exact app binding."
    }
    return $states[0]
}

function Test-DeleteConfirmationVisible {
    param([Parameter(Mandatory = $true)]$Target)

    try {
        [void](Get-DeleteConfirmationState -Target $Target)
        return $true
    } catch {
        if ($_.Exception.Message -match 'not available') { return $false }
        throw
    }
}

function Assert-DeleteConfirmationValue {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Target
    )

    $pattern = $null
    if (-not $State.Edit.TryGetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern,
        [ref]$pattern
    )) {
        throw "The exact delete confirmation field does not expose a readable value."
    }
    $value = ([System.Windows.Automation.ValuePattern]$pattern).Current.Value
    if ($value -cne $Target.AppKey) {
        throw "The exact app key has not been typed into the delete confirmation field."
    }
    if (-not $State.Final.Current.IsEnabled -or $State.Final.Current.IsOffscreen) {
        throw "The permanent-delete control is not enabled and visible."
    }
}

function Invoke-WindowsUiAction {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "edge-first-run",
            "invoke-public-email",
            "invoke-portal-microsoft",
            "focus-email",
            "invoke-next",
            "focus-password",
            "invoke-sign-in",
            "invoke-edge-not-now",
            "invoke-ms-yes",
            "probe-portal-ready",
            "wait-portal-ready",
            "wait-platform-apps",
            "invoke-create-app-split-arrow",
            "invoke-manage-app",
            "probe-manage-app-search",
            "focus-manage-app-search",
            "invoke-exact-app-delete",
            "focus-delete-confirmation",
            "assert-delete-ready"
        )]
        [string]$Action,

        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 30,

        [string]$AppKeyBase64 = "",

        [string]$DisplayNameBase64 = ""
    )

    Initialize-WindowsUiAutomation
    $targetActions = @(
        "invoke-exact-app-delete",
        "focus-delete-confirmation",
        "assert-delete-ready"
    )
    $target = $null
    if ($targetActions -contains $Action) {
        $target = ConvertFrom-CleanupTargetBase64 `
            -AppKeyBase64 $AppKeyBase64 -DisplayNameBase64 $DisplayNameBase64
    } elseif (-not [string]::IsNullOrEmpty($AppKeyBase64) -or
        -not [string]::IsNullOrEmpty($DisplayNameBase64)) {
        throw "Cleanup target values are not accepted by this UI action."
    }
    switch ($Action) {
        "edge-first-run" {
            Dismiss-EdgeFirstRun -TimeoutSeconds $TimeoutSeconds
        }
        "invoke-public-email" {
            if (-not (Test-ExactEdgeState -Names @("Sign in with Microsoft") -ControlType "Button" -ExpectedHost "admin-portal.myenterprise.ai" -ExpectedPath "/login")) {
                Invoke-ExactEdgeHyperlink -Names @(
                    "Continue with Email, Google, or Microsoft"
                ) -TimeoutSeconds $TimeoutSeconds -ExpectedHost "www.enterpriseaigroup.com" -ExpectedPath "/sign-in"
            }
        }
        "invoke-portal-microsoft" {
            if (-not (Test-ExactEdgeState -Names @(
                "Email address",
                "Enter your email, phone, or Skype.",
                "Email, phone, or Skype"
            ) -ControlType "Edit" -ExpectedHost "enterpriseaiplatform.ciamlogin.com")) {
                Invoke-ExactEdgeButton -Names @("Sign in with Microsoft") -TimeoutSeconds $TimeoutSeconds -ExpectedHost "admin-portal.myenterprise.ai" -ExpectedPath "/login"
            }
        }
        "focus-email" {
            Focus-ExactEdgeEdit -Names @(
                "Email address",
                "Enter your email, phone, or Skype.",
                "Email, phone, or Skype"
            ) -TimeoutSeconds $TimeoutSeconds -ExpectedHost "enterpriseaiplatform.ciamlogin.com"
        }
        "invoke-next" {
            if (-not (Test-ExactEdgeState -Names @("Enter the password for {0}") -ControlType "Edit" -ExpectedHost "enterpriseaiplatform.ciamlogin.com")) {
                Invoke-ExactEdgeButton -Names @("Next") -TimeoutSeconds $TimeoutSeconds -ExpectedHost "enterpriseaiplatform.ciamlogin.com"
            }
        }
        "focus-password" {
            Focus-ExactEdgePasswordEdit -TimeoutSeconds $TimeoutSeconds
        }
        "invoke-sign-in" {
            if (-not (Test-PostSignInState)) {
                Invoke-ExactEdgeButton -Names @("Sign in") -TimeoutSeconds $TimeoutSeconds -ExpectedHost "enterpriseaiplatform.ciamlogin.com"
            }
        }
        "invoke-edge-not-now" {
            [void](Invoke-OptionalExactEdgeButton -Names @("Not now") -TimeoutSeconds $TimeoutSeconds -ExpectedHost "enterpriseaiplatform.ciamlogin.com")
        }
        "invoke-ms-yes" {
            [void](Invoke-OptionalExactEdgeButton -Names @("Yes") -TimeoutSeconds $TimeoutSeconds -ExpectedHost "enterpriseaiplatform.ciamlogin.com")
        }
        "probe-portal-ready" {
            if (Test-PortalReady) {
                [Console]::Out.WriteLine("EAI_PORTAL_READY")
            } else {
                [Console]::Out.WriteLine("EAI_PORTAL_NOT_READY")
            }
        }
        "wait-portal-ready" {
            Wait-PortalReady -TimeoutSeconds $TimeoutSeconds
        }
        "wait-platform-apps" {
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            do {
                try {
                    Assert-PortalAppsLocation
                    $create = @(Find-ExactEdgeElements -Names @("Create app") -ControlType "Button")
                    $allApps = @(Find-ExactEdgeElements -Names @("All apps") -ControlType "Any")
                    if ($create.Count -eq 1 -and $allApps.Count -ge 1) { break }
                    if ($create.Count -gt 1) { throw "The exact Create app control is ambiguous." }
                } catch {
                    if ([DateTime]::UtcNow -ge $deadline) { throw }
                }
                Start-Sleep -Milliseconds 250
            } while ([DateTime]::UtcNow -lt $deadline)
            Assert-PortalAppsLocation
            $create = @(Find-ExactEdgeElements -Names @("Create app") -ControlType "Button")
            if ($create.Count -ne 1) {
                throw "Timed out waiting for the exact Admin Portal apps controls."
            }
        }
        "invoke-create-app-split-arrow" {
            Assert-PortalAppsLocation
            $manage = @(Find-ExactInvokableEdgeElements -Names @("Manage app"))
            if ($manage.Count -gt 1) {
                throw "The exact Manage app menu action is ambiguous."
            }
            if ($manage.Count -eq 0) {
                $arrow = Get-CreateAppSplitArrow
                Expand-UiElement -Element $arrow
            }
            $manage = @(Find-ExactInvokableEdgeElements -Names @("Manage app"))
            if ($manage.Count -ne 1) {
                throw "The exact Manage app menu action did not become uniquely available."
            }
        }
        "invoke-manage-app" {
            Assert-PortalAppsLocation
            if ($null -eq (Get-ManageAppSearchEdit) -and
                $null -eq (Get-ManageAppDialogWindow)) {
                $manage = @(Find-ExactInvokableEdgeElements -Names @("Manage app"))
                if ($manage.Count -ne 1) {
                    throw "The exact Manage app menu action is missing or ambiguous."
                }
                Invoke-UiElement -Element $manage[0]
            }
            Wait-ManageAppSurface -TimeoutSeconds $TimeoutSeconds
        }
        "probe-manage-app-search" {
            Wait-ManageAppSurface -TimeoutSeconds $TimeoutSeconds
            if ($null -ne (Get-ManageAppSearchEdit)) {
                [Console]::Out.WriteLine("EAI_MANAGE_APP_SEARCH_PRESENT")
            } elseif ($null -ne (Get-ManageAppDialogWindow)) {
                [Console]::Out.WriteLine("EAI_MANAGE_APP_SEARCH_ABSENT")
            } else {
                throw "The exact Manage app surface changed during its search-state probe."
            }
        }
        "focus-manage-app-search" {
            $edit = Wait-ManageAppSearchEdit -TimeoutSeconds $TimeoutSeconds
            Focus-UiElement -Element $edit
        }
        "invoke-exact-app-delete" {
            if (-not (Test-DeleteConfirmationVisible -Target $target)) {
                $delete = Wait-ExactAppDeleteControl -Target $target -TimeoutSeconds $TimeoutSeconds
                Invoke-UiElement -Element $delete
            }
            [void](Get-DeleteConfirmationState -Target $target)
        }
        "focus-delete-confirmation" {
            $state = Get-DeleteConfirmationState -Target $target
            Focus-UiElement -Element $state.Edit
        }
        "assert-delete-ready" {
            $state = Get-DeleteConfirmationState -Target $target
            Assert-DeleteConfirmationValue -State $state -Target $target
        }
    }
    [Console]::Out.WriteLine("WINDOWS_UI_ACTION_OK")
}
