[CmdletBinding()]
param([string]$SourcePath)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourcePath)) { $SourcePath = Join-Path $PSScriptRoot '..\MT-win-tools.ps1' }
Set-StrictMode -Version 2.0
$parseTokens = $null
$parseErrors = $null
$sourceAst = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $SourcePath), [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors -join [Environment]::NewLine) }
$script:TestFailures = 0
$script:TestCount = 0

# Extract only functions. Never execute the application's elevation or startup.
function Import-TestFunctions {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $node = $sourceAst.Find({ param($candidate) $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -eq $name }, $true)
        if (-not $node) { throw "Missing function: $name" }
        . ([scriptblock]::Create($node.Extent.Text))
    }
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    if (-not $caught -or $caught.Exception.Message -notmatch $Pattern) { throw "Expected failure matching $Pattern" }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:TestCount++
    try { & $Body; Write-Output "PASS $Name" }
    catch { $script:TestFailures++; Write-Output "FAIL $Name`: $($_.Exception.Message)" }
}

Test-Case 'OneDrive uninstall preserves user files and does not call the Windows rollback deletion guard' {
    . Import-TestFunctions @('Invoke-MTWinTweak')
    $script:UninstallCalls = 0
    function Stop-Process {}
    function Get-MTWinCallerProfilePath { 'C:\Users\Fixture' }
    function Test-Path { $true }
    function Invoke-MTWinNativeCommand { $script:UninstallCalls++ }
    function Remove-MTWinProtectedDirectory { throw 'Unexpected user-directory deletion' }
    function Get-Service { throw 'OneSync is unrelated to OneDrive' }
    $effect = Invoke-MTWinTweak -Id RemoveOneDrive
    Assert-True ($effect -eq 'Sign-out' -and $script:UninstallCalls -eq 1) 'OneDrive uninstall failed'
}
Test-Case 'Busy state disables keyboard as well as mouse interaction' {
    . Import-TestFunctions @('Set-MTWinBusy')
    $MainShell = [pscustomobject]@{ IsEnabled = $true }
    Set-MTWinBusy $true
    Assert-True (-not $MainShell.IsEnabled) 'Controls remain keyboard-enabled'
    Set-MTWinBusy $false
    Assert-True $MainShell.IsEnabled 'Controls were not restored'
}
Test-Case 'A running worker cannot be replaced by a second operation' {
    . Import-TestFunctions @('Start-MTWinUiOperation')
    $script:ActiveJob = [pscustomobject]@{ Kind = 'Tweaks' }
    function Clear-MTWinInlineConfirmation { throw 'A second job started' }
    Start-MTWinUiOperation -Kind Tweaks -Ids @('ActivityHistory')
    Assert-True ($script:ActiveJob.Kind -eq 'Tweaks') 'Active job was lost'
    $script:ActiveJob = $null
}
Test-Case 'Settings Home detects default, hidden, and show-only visibility' {
    . Import-TestFunctions @('Get-MTWinPreferenceState')
    foreach ($case in @(@('', $true), @('hide:home;about', $false), @('hide:about', $true), @('showonly:about', $false), @('showonly:home;about', $true))) {
        $script:Visibility = $case[0]
        function Get-MTWinSettingsPageVisibility { $script:Visibility }
        Assert-True ((Get-MTWinPreferenceState SettingsHome) -eq $case[1]) "Wrong state for $($case[0])"
    }
}
Test-Case 'Settings Home changes preserve other page visibility rules' {
    . Import-TestFunctions @('Set-MTWinSettingsHomeVisibility')
    function Get-MTWinSettingsPageVisibility { $script:Visibility }
    function Set-MTWinRegistryValue { param($Path, $Name, $Value, $Type) $script:WrittenVisibility = $Value }
    function Remove-MTWinRegistryValue { $script:WrittenVisibility = '<removed>' }
    foreach ($case in @(@('hide:home;about', $true, 'hide:about'), @('hide:about', $false, 'hide:about;home'), @('hide:home', $true, '<removed>'), @('showonly:about', $true, 'showonly:about;home'), @('show:home', $true, '<removed>'))) {
        $script:Visibility = $case[0]
        Set-MTWinSettingsHomeVisibility -Enabled $case[1]
        Assert-True ($script:WrittenVisibility -eq $case[2]) "Visibility rules were overwritten: $script:WrittenVisibility"
    }
}
Test-Case 'Cleanup summary distinguishes completed, skipped and failed operations and runs Disk Cleanup last' {
    . Import-TestFunctions @('Invoke-MTWinToolsOperationBatch', 'Format-MTWinBytes')
    $script:Executed = @()
    function Get-MTWinSystemFreeBytes { 0 }
    function Test-MTWinActiveServicing { $false }
    function Get-MTWinLocalUserProfiles {}
    function Get-MTWinOperationDisplayName { param($Id) $Id }
    function Write-MTWinStatus {}
    function Invoke-MTWinCleanupOperation {
        param($Id, $Context)
        $script:Executed += $Id
        if ($Id -eq 'skip') { return $false }
        if ($Id -eq 'fail') { throw 'fixture failure' }
        return $true
    }
    $result = Invoke-MTWinToolsOperationBatch -Kind Cleanup -Ids @('DiskCleanup', 'ok', 'skip', 'fail')
    Assert-True ($result.Failures -eq 1 -and $result.CompletedIds.Count -eq 2 -and $result.SkippedIds.Count -eq 1 -and $result.FailedIds.Count -eq 1) 'Incorrect operation counts'
    Assert-True ($script:Executed[-1] -eq 'DiskCleanup') 'Baseline cleanup did not run last'
}
Test-Case 'Missing worker summaries and nonterminating worker errors cannot report success' {
    . Import-TestFunctions @('Receive-MTWinOperationJobResult')
    $worker = [pscustomobject]@{ HadErrors = $false; Streams = [pscustomobject]@{ Error = @('fixture error') } }
    $worker | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value { param($async) }
    $job = [pscustomobject]@{ PowerShell = $worker; Async = $null }
    Assert-Throws { Receive-MTWinOperationJobResult $job } 'completion summary'
    $worker.HadErrors = $true
    Assert-Throws { Receive-MTWinOperationJobResult $job } 'fixture error'
}
Test-Case 'Hibernation refresh restores the enabled state and surfaces native failures' {
    . Import-TestFunctions @('Invoke-MTWinHibernationRefresh')
    $script:PowerCalls = @()
    function Get-ItemProperty { [pscustomobject]@{ HibernateEnabled = 1; HiberFileSizePercent = 75 } }
    function Test-Path { param($LiteralPath) $LiteralPath -like '*powercfg.exe' }
    function Invoke-MTWinNativeCommand {
        param($FilePath, $Arguments)
        $script:PowerCalls += ($Arguments -join ' ')
        if (($Arguments -join ' ') -eq '/hibernate off') { throw 'fixture native failure' }
    }
    Assert-Throws { Invoke-MTWinHibernationRefresh } 'fixture native failure'
    Assert-True ($script:PowerCalls -contains '/hibernate on') 'Enabled state was not restored'
    Assert-True ($script:PowerCalls -contains '/hibernate /size 75') 'Original hibernation size was not restored'
}
Test-Case 'Temporary service stop failure restores services already stopped' {
    . Import-TestFunctions @('Stop-MTWinServicesTemporarily', 'Restore-MTWinServiceStates')
    $script:Restored = @()
    function Get-Service { param($Name) [pscustomobject]@{ Status = 'Running' } }
    function Stop-Service { param($Name) if ($Name -eq 'second') { throw 'cannot stop second' } }
    function Start-Service { param($Name) $script:Restored += $Name }
    function Wait-MTWinServiceState {}
    Assert-Throws { Stop-MTWinServicesTemporarily @('first', 'second') } 'cannot stop second'
    Assert-True ($script:Restored -contains 'first') 'Previously stopped service was not restored'
}
Test-Case 'Registry-removal errors are reported; missing values are harmless' {
    . Import-TestFunctions @('Remove-MTWinRegistryValue')
    function Resolve-MTWinRegistryPath { param($Path) $Path }
    function Test-Path { $true }
    $key = [pscustomobject]@{}
    $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @('OverlayTestMode') }
    function Get-Item { $key }
    function Remove-ItemProperty { throw 'access denied' }
    Remove-MTWinRegistryValue 'HKLM:\Fixture' 'Absent'
    Assert-Throws { Remove-MTWinRegistryValue 'HKLM:\Fixture' 'OverlayTestMode' } 'access denied'
}
Test-Case 'Native exit codes distinguish a reboot-required success from failure' {
    . Import-TestFunctions @('Invoke-MTWinNativeCommand')
    $command = Join-Path $env:SystemRoot 'System32\cmd.exe'
    Invoke-MTWinNativeCommand $command @('/d', '/c', 'exit 3010') @(0, 3010)
    Assert-Throws { Invoke-MTWinNativeCommand $command @('/d', '/c', 'exit 5') } 'exit code 5'
}
Test-Case 'Cache cleanup skips root and nested junctions without deleting their targets' {
    . Import-TestFunctions @('Test-MTWinReparsePoint', 'Remove-MTWinDirectoryContents', 'Remove-MTWinMatchingFiles')
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('MTWin-tests-' + [guid]::NewGuid().ToString('N'))
    $cache = Join-Path $fixtureRoot 'cache'
    $outside = Join-Path $fixtureRoot 'outside'
    $junction = Join-Path $cache 'junction'
    New-Item -ItemType Directory -Path $cache, $outside | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $outside 'keep.log') -Value 'preserve'
        Set-Content -LiteralPath (Join-Path $cache 'delete.log') -Value 'delete'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        Remove-MTWinDirectoryContents $junction
        Assert-True (Test-Path -LiteralPath (Join-Path $outside 'keep.log')) 'Root junction target was deleted'
        Remove-MTWinMatchingFiles -Directory $cache -Patterns @('*.log') -Recurse
        Assert-True (Test-Path -LiteralPath (Join-Path $outside 'keep.log')) 'Recursive matching crossed a junction'
        Remove-MTWinDirectoryContents $cache
        Assert-True (Test-Path -LiteralPath (Join-Path $outside 'keep.log')) 'Nested junction target was deleted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $cache 'delete.log'))) 'Ordinary cache file was not deleted'
    }
    finally {
        if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction, $false) }
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolvedFixture.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixture) -notlike 'MTWin-tests-*') { throw 'Unexpected fixture cleanup path' }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
Test-Case 'The WPF interface loads with its footer outside the main app grid' {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $node = $sourceAst.Find({ param($candidate) $candidate -is [Management.Automation.Language.StringConstantExpressionAst] -and $candidate.Value.StartsWith('<Window xmlns=') }, $true)
    $window = [Windows.Markup.XamlReader]::Parse($node.Value)
    try {
        Assert-True ($window.FindName('SiteCredit').Parent -eq $window.FindName('RootGrid')) 'Footer is inside the centered app'
        Assert-True ($null -ne $window.FindName('RunTweaks')) 'Required action control is missing'
    }
    finally { $window.Close() }
}
Test-Case 'A background runspace executes a mocked operation and returns its real completion summary' {
    . Import-TestFunctions @($sourceAst.FindAll({ param($candidate) $candidate -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    function Invoke-MTWinTweak { param($Id) 'No restart' }
    $script:ActiveJob = $null
    Start-MTWinOperationJob -Kind Tweaks -Ids @('fixture')
    $job = $script:ActiveJob
    try {
        Assert-True ($job.Async.AsyncWaitHandle.WaitOne(10000)) 'Worker did not finish'
        $result = Receive-MTWinOperationJobResult -Job $job
        Assert-True ($result.Failures -eq 0 -and @($result.CompletedIds).Count -eq 1 -and $result.CompletedIds[0] -eq 'fixture') 'Worker summary is incorrect'
    }
    finally { $job.PowerShell.Dispose(); $job.Runspace.Dispose(); $script:ActiveJob = $null }
}

Write-Output "$script:TestCount tests; $script:TestFailures failures"
if ($script:TestFailures -gt 0) { exit 1 }
