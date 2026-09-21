& {
[CmdletBinding()]
param()

# MT win tools v0.1.
# Windows PowerShell 5.1 and PowerShell 7 on Windows are supported.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# Capture the body of this literal script block. This remains available when the
# outer file is executed normally or when its contents are passed to iex.
$script:MTWinToolsSourceBody = $MyInvocation.MyCommand.ScriptBlock.ToString()

function Test-MTWinAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-MTWinPowerShellExecutable {
    $name = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $candidate = Join-Path $PSHOME $name

    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Get-MTWinSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return -join ($algorithm.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $algorithm.Dispose()
    }
}

function Start-MTWinRelaunch {
    param(
        [Parameter(Mandatory = $true)][string]$SourceBody,
        [Parameter(Mandatory = $true)][bool]$Elevate
    )

    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ('MT-win-tools-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $launched = $false
    $payload = "& {`r`n$SourceBody`r`n}`r`n"
    $utf8 = [Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes($payload)
    $expectedHash = Get-MTWinSha256 -Bytes $bytes
    $callerSid = $env:MT_WIN_TOOLS_CALLER_SID
    if ([string]::IsNullOrWhiteSpace($callerSid)) {
        $callerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }

    try {
        [IO.File]::WriteAllBytes($tempPath, $bytes)

        # The elevated process executes this small encoded bootstrap, not the
        # user-writable temporary file directly. It verifies the exact bytes,
        # removes the file, and only then evaluates the already-loaded source.
        $escapedPath = $tempPath.Replace("'", "''")
        $escapedSid = $callerSid.Replace("'", "''")
        $bootstrap = @"
`$path = '$escapedPath'
`$expected = '$expectedHash'
`$callerSid = '$escapedSid'
try {
    `$bytes = [IO.File]::ReadAllBytes(`$path)
    `$sha = [Security.Cryptography.SHA256]::Create()
    try {
        `$actual = -join (`$sha.ComputeHash(`$bytes) | ForEach-Object { `$_.ToString('x2') })
    }
    finally {
        `$sha.Dispose()
    }
    if (`$actual -ne `$expected) {
        throw 'The temporary elevation payload failed verification.'
    }
    `$source = [Text.Encoding]::UTF8.GetString(`$bytes)
    Remove-Item -LiteralPath `$path -Force -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable('MT_WIN_TOOLS_CALLER_SID', `$callerSid, 'Process')
    Invoke-Expression `$source
}
catch {
    Write-Error (`"MT win tools could not start: `" + `$_.Exception.Message)
}
finally {
    Remove-Item -LiteralPath `$path -Force -ErrorAction SilentlyContinue
}
"@

        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
        $arguments = '-NoLogo -NoProfile -Sta -EncodedCommand ' + $encoded
        $start = @{
            FilePath = Get-MTWinPowerShellExecutable
            ArgumentList = $arguments
        }

        if ($Elevate) {
            $start['Verb'] = 'RunAs'
        }

        Start-Process @start | Out-Null
        $launched = $true
        return $true
    }
    catch [System.ComponentModel.Win32Exception] {
        if ($Elevate -and $_.Exception.NativeErrorCode -eq 1223) {
            Write-Host "MT win tools was not started because administrator approval was declined."
        }
        else {
            Write-Warning ("MT win tools could not be relaunched: " + $_.Exception.Message)
        }
        return $false
    }
    catch {
        Write-Warning ("MT win tools could not be relaunched: " + $_.Exception.Message)
        return $false
    }
    finally {
        # On success, the child removes the file before evaluating the payload.
        # On failure or UAC cancellation, the original process removes it here.
        if (-not $launched) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($env:OS -ne 'Windows_NT') {
    Write-Error "MT win tools requires Windows."
    return
}

if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    Write-Error "MT win tools requires Windows PowerShell 5.1 or later."
    return
}

if ([string]::IsNullOrWhiteSpace($env:MT_WIN_TOOLS_CALLER_SID)) {
    $env:MT_WIN_TOOLS_CALLER_SID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

$isAdministrator = Test-MTWinAdministrator
$isSta = ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA)

if (-not $isAdministrator -or -not $isSta) {
    $reason = if (-not $isAdministrator) { 'Requesting administrator approval...' } else { 'Starting the interface in an STA PowerShell process...' }
    Write-Host $reason
    [void](Start-MTWinRelaunch -SourceBody $script:MTWinToolsSourceBody -Elevate (-not $isAdministrator))
    return
}

$createdNew = $false
$instanceMutex = $null
try {
    $instanceMutex = [Threading.Mutex]::new($true, 'Local\MT-win-tools.Application', [ref]$createdNew)
}
catch {
    Write-Error ("MT win tools could not create its instance guard: " + $_.Exception.Message)
    return
}

if (-not $createdNew) {
    Write-Host "MT win tools is already running in this Windows session."
    $instanceMutex.Dispose()
    return
}

function Write-MTWinStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info'
    )

    $prefix = switch ($Level) {
        'Success' { '[Completed]' }
        'Warning' { '[Skipped]' }
        'Error' { '[Failed]' }
        default { '[Running]' }
    }

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        default { 'Cyan' }
    }

    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Format-MTWinBytes {
    param([Int64]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

function Get-MTWinSystemFreeBytes {
    try {
        $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop
        return [Int64]$drive.FreeSpace
    }
    catch {
        return 0
    }
}

function Test-MTWinReparsePoint {
    param([System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Remove-MTWinDirectoryContents {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -lt 4) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if (-not (Test-MTWinReparsePoint $_)) {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
            }
        }
        catch {
            # Locked, protected, and in-use items are left in place.
        }
    }
}

function Remove-MTWinFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not (Test-MTWinReparsePoint $item)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
    }
    catch {
    }
}

function Remove-MTWinMatchingFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Patterns,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Directory)) { return }

    foreach ($pattern in $Patterns) {
        $parameters = @{
            LiteralPath = $Directory
            Filter = $pattern
            File = $true
            Force = $true
            ErrorAction = 'SilentlyContinue'
        }
        if ($Recurse) { $parameters['Recurse'] = $true }

        Get-ChildItem @parameters | ForEach-Object {
            try {
                if (-not (Test-MTWinReparsePoint $_)) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                }
            }
            catch {
            }
        }
    }
}

function Get-MTWinLocalUserProfiles {
    try {
        return @(
            Get-CimInstance Win32_UserProfile -ErrorAction Stop |
                Where-Object {
                    (-not $_.Special) -and
                    (-not [string]::IsNullOrWhiteSpace($_.LocalPath)) -and
                    (Test-Path -LiteralPath $_.LocalPath)
                } |
                Select-Object -ExpandProperty LocalPath
        )
    }
    catch {
        $usersRoot = Join-Path $env:SystemDrive 'Users'
        if (-not (Test-Path -LiteralPath $usersRoot)) { return @() }

        return @(
            Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('Default', 'Default User', 'Public', 'All Users', 'defaultuser0') } |
                Select-Object -ExpandProperty FullName
        )
    }
}

function Test-MTWinPendingServicingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )

    foreach ($key in $keys) {
        if (Test-Path $key) { return $true }
    }

    return (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'WinSxS\pending.xml'))
}

function Test-MTWinActiveServicing {
    if (Test-MTWinPendingServicingReboot) { return $true }

    foreach ($name in @('TiWorker', 'TrustedInstaller', 'MoUsoCoreWorker', 'SetupHost', 'setupprep', 'Windows10UpgraderApp', 'WindowsUpdateBox')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
    }

    return $false
}

function Wait-MTWinServiceState {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Running', 'Stopped')][string]$State,
        [int]$TimeoutSeconds = 30
    )

    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        $desired = [System.ServiceProcess.ServiceControllerStatus]::$State
        $service.WaitForStatus($desired, [TimeSpan]::FromSeconds($TimeoutSeconds))
    }
    catch {
    }
}

function Stop-MTWinServicesTemporarily {
    param([string[]]$Names)

    $states = @{}
    foreach ($name in $Names) {
        try {
            $service = Get-Service -Name $name -ErrorAction Stop
            $states[$name] = [string]$service.Status
            if ($service.Status -ne 'Stopped') {
                Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
                Wait-MTWinServiceState -Name $name -State Stopped
            }
        }
        catch {
        }
    }
    return $states
}

function Restore-MTWinServiceStates {
    param([hashtable]$States)

    foreach ($name in $States.Keys) {
        if ($States[$name] -eq 'Running') {
            try {
                Start-Service -Name $name -ErrorAction SilentlyContinue
                Wait-MTWinServiceState -Name $name -State Running
            }
            catch {
            }
        }
    }
}

function Remove-MTWinProtectedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $allowed = @(
        (Join-Path $env:SystemDrive 'Windows.old'),
        (Join-Path $env:SystemDrive '$WINDOWS.~BT'),
        (Join-Path $env:SystemDrive '$WINDOWS.~WS'),
        (Join-Path $env:SystemDrive '$GetCurrent'),
        (Join-Path $env:SystemDrive '$SysReset')
    )
    $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowedNormalized = @($allowed | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })

    if ($normalized -notin $allowedNormalized) {
        throw "Refusing protected-directory deletion outside the allow-list: $Path"
    }

    Write-Host "Removing: $Path"
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return
    }
    catch {
    }

    $takeown = Join-Path $env:SystemRoot 'System32\takeown.exe'
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if ((Test-Path -LiteralPath $takeown) -and (Test-Path -LiteralPath $icacls)) {
        & $takeown /F $Path /R /D Y 2>&1 | Out-Null
        & $icacls $Path /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $Path) {
        throw "Could not completely remove $Path"
    }
}

function Clear-MTWinChromiumCachesForProfile {
    param([Parameter(Mandatory = $true)][string]$UserData)

    if (-not (Test-Path -LiteralPath $UserData)) { return }
    $fixedProfiles = @('Default', 'Guest Profile', 'System Profile')

    Get-ChildItem -LiteralPath $UserData -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { ($fixedProfiles -contains $_.Name) -or ($_.Name -like 'Profile *') } |
        ForEach-Object {
            $profilePath = $_.FullName
            foreach ($cache in @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'GraphiteDawnCache', 'GrShaderCache')) {
                Remove-MTWinDirectoryContents (Join-Path $profilePath $cache)
            }
        }

    foreach ($cache in @('ShaderCache', 'GrShaderCache', 'DawnCache', 'GraphiteDawnCache')) {
        Remove-MTWinDirectoryContents (Join-Path $UserData $cache)
    }
}

function Clear-MTWinCallerRecycleBin {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $callerSid = $env:MT_WIN_TOOLS_CALLER_SID

    if ([string]::IsNullOrWhiteSpace($callerSid) -or $callerSid -eq $currentSid) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        return
    }

    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($drive.Root)) { continue }
        $recycleRoot = Join-Path $drive.Root '$Recycle.Bin'
        $callerBin = Join-Path $recycleRoot $callerSid
        Remove-MTWinDirectoryContents $callerBin
    }
}

function Invoke-MTWinHibernationRefresh {
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    $hiberFile = Join-Path $env:SystemDrive 'hiberfil.sys'

    try {
        $power = Get-ItemProperty -Path $powerKey -ErrorAction Stop
    }
    catch {
        Write-Warning 'Hibernation state could not be read.'
        return $false
    }

    $enabled = $false
    if ($null -ne $power.PSObject.Properties['HibernateEnabled']) {
        $enabled = ([int]$power.HibernateEnabled -ne 0)
    }
    elseif (Test-Path -LiteralPath $hiberFile) {
        $enabled = $true
    }

    if (-not $enabled) {
        Write-Host 'Hibernation is disabled; leaving it disabled.'
        return $false
    }

    $sizePercent = $null
    if ($null -ne $power.PSObject.Properties['HiberFileSizePercent']) {
        try { $sizePercent = [int]$power.HiberFileSizePercent } catch { $sizePercent = $null }
    }

    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path -LiteralPath $powercfg)) {
        Write-Warning 'powercfg.exe is unavailable.'
        return $false
    }

    Write-Host 'Recreating hiberfil.sys and restoring the enabled state.'
    try {
        & $powercfg /hibernate off 2>&1 | Out-Host
        for ($i = 0; $i -lt 30; $i++) {
            if (-not (Test-Path -LiteralPath $hiberFile)) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        & $powercfg /hibernate on 2>&1 | Out-Host
        if ($null -ne $sizePercent) {
            if ($sizePercent -lt 40) {
                & $powercfg /hibernate /size 0 2>&1 | Out-Null
                & $powercfg /hibernate /type reduced 2>&1 | Out-Null
            }
            elseif (($sizePercent -ge 50) -and ($sizePercent -le 100)) {
                & $powercfg /hibernate /type full 2>&1 | Out-Null
                & $powercfg /hibernate /size $sizePercent 2>&1 | Out-Null
            }
            else {
                & $powercfg /hibernate /type full 2>&1 | Out-Null
            }
        }
    }

    return $true
}

function Invoke-MTWinCleanupOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $profiles = $Context.UserProfiles
    $activeServicing = [bool]$Context.ActiveServicing

    switch ($Id) {
        'TemporaryFiles' {
            if ($env:TEMP) { Remove-MTWinDirectoryContents $env:TEMP }
            if ($env:LOCALAPPDATA) { Remove-MTWinDirectoryContents (Join-Path $env:LOCALAPPDATA 'Temp') }
            Remove-MTWinDirectoryContents (Join-Path $env:SystemRoot 'Temp')
            Remove-MTWinDirectoryContents (Join-Path $env:SystemRoot 'Downloaded Program Files')
            foreach ($profile in $profiles) { Remove-MTWinDirectoryContents (Join-Path $profile 'AppData\Local\Temp') }
        }
        'CrashReports' {
            Remove-MTWinDirectoryContents (Join-Path $env:SystemRoot 'Minidump')
            Remove-MTWinDirectoryContents (Join-Path $env:SystemRoot 'LiveKernelReports')
            Remove-MTWinFile (Join-Path $env:SystemRoot 'MEMORY.DMP')
            Remove-MTWinDirectoryContents (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')
            Remove-MTWinDirectoryContents (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue')
            Remove-MTWinDirectoryContents (Join-Path $env:ProgramData 'Microsoft\Windows\WER\Temp')
            foreach ($profile in $profiles) { Remove-MTWinDirectoryContents (Join-Path $profile 'AppData\Local\CrashDumps') }
        }
        'ServicingLogs' {
            Remove-MTWinMatchingFiles (Join-Path $env:SystemRoot 'Logs\CBS') @('CbsPersist*.log', 'CbsPersist*.cab', '*.bak')
            Remove-MTWinMatchingFiles (Join-Path $env:SystemRoot 'Logs\DISM') @('*.log', '*.bak')
            if ($activeServicing) {
                Write-Warning 'Active servicing detected; Windows Update and setup logs were left in place.'
            }
            else {
                Remove-MTWinMatchingFiles (Join-Path $env:SystemRoot 'Logs\WindowsUpdate') @('*.etl', '*.log') -Recurse
                Remove-MTWinMatchingFiles (Join-Path $env:SystemRoot 'Logs\MoSetup') @('*.etl', '*.log') -Recurse
                Remove-MTWinMatchingFiles (Join-Path $env:SystemRoot 'Panther') @('*.etl', '*.log') -Recurse
            }
        }
        'ShaderCaches' {
            foreach ($profile in $profiles) { Remove-MTWinDirectoryContents (Join-Path $profile 'AppData\Local\D3DSCache') }
        }
        'BrowserCaches' {
            $edgeRunning = [bool](Get-Process -Name msedge -ErrorAction SilentlyContinue)
            $chromeRunning = [bool](Get-Process -Name chrome -ErrorAction SilentlyContinue)
            $braveRunning = [bool](Get-Process -Name brave -ErrorAction SilentlyContinue)
            $firefoxRunning = [bool](Get-Process -Name firefox -ErrorAction SilentlyContinue)

            foreach ($profile in $profiles) {
                if (-not $edgeRunning) { Clear-MTWinChromiumCachesForProfile (Join-Path $profile 'AppData\Local\Microsoft\Edge\User Data') }
                if (-not $chromeRunning) { Clear-MTWinChromiumCachesForProfile (Join-Path $profile 'AppData\Local\Google\Chrome\User Data') }
                if (-not $braveRunning) { Clear-MTWinChromiumCachesForProfile (Join-Path $profile 'AppData\Local\BraveSoftware\Brave-Browser\User Data') }
                if (-not $firefoxRunning) {
                    $firefoxProfiles = Join-Path $profile 'AppData\Local\Mozilla\Firefox\Profiles'
                    if (Test-Path -LiteralPath $firefoxProfiles) {
                        Get-ChildItem -LiteralPath $firefoxProfiles -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                            Remove-MTWinDirectoryContents (Join-Path $_.FullName 'cache2')
                            Remove-MTWinDirectoryContents (Join-Path $_.FullName 'startupCache')
                        }
                    }
                }
            }
            if ($edgeRunning) { Write-Host 'Edge cache skipped because Edge is running.' }
            if ($chromeRunning) { Write-Host 'Chrome cache skipped because Chrome is running.' }
            if ($braveRunning) { Write-Host 'Brave cache skipped because Brave is running.' }
            if ($firefoxRunning) { Write-Host 'Firefox cache skipped because Firefox is running.' }
        }
        'ExplorerCaches' {
            $explorerWasRunning = [bool](Get-Process -Name explorer -ErrorAction SilentlyContinue)
            if ($explorerWasRunning) {
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 750
            }
            try {
                foreach ($profile in $profiles) {
                    Remove-MTWinMatchingFiles (Join-Path $profile 'AppData\Local\Microsoft\Windows\Explorer') @('thumbcache_*.db', 'iconcache_*.db')
                }
            }
            finally {
                if ($explorerWasRunning) { Start-Process (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction SilentlyContinue }
            }
        }
        'RecycleBin' {
            Clear-MTWinCallerRecycleBin
        }
        'ChkdskFragments' {
            Get-ChildItem -LiteralPath ($env:SystemDrive + '\') -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^FOUND\.\d+$' } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
        'BranchCache' {
            $manifest = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\BranchCache\BranchCache.psd1'
            $module = $null
            if (Test-Path -LiteralPath $manifest) {
                $module = Import-Module $manifest -PassThru -ErrorAction SilentlyContinue
            }
            $command = if ($module) { Get-Command -Name Clear-BCCache -Module $module.Name -ErrorAction SilentlyContinue } else { $null }
            if ($command) {
                & $command -Force -ErrorAction SilentlyContinue | Out-Null
            }
            else {
                Write-Host 'BranchCache is not installed or enabled.'
                return $false
            }
        }
        'WindowsUpdateCache' {
            if ($activeServicing) {
                Write-Warning 'Active servicing or a pending servicing reboot was detected; update caches were left in place.'
                return $false
            }

            $states = Stop-MTWinServicesTemporarily @('BITS', 'wuauserv')
            try { Remove-MTWinDirectoryContents (Join-Path $env:SystemRoot 'SoftwareDistribution\Download') }
            finally { Restore-MTWinServiceStates $states }

            $manifest = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\DeliveryOptimization\DeliveryOptimization.psd1'
            $module = $null
            if (Test-Path -LiteralPath $manifest) {
                $module = Import-Module $manifest -PassThru -ErrorAction SilentlyContinue
            }
            $command = if ($module) { Get-Command -Name Delete-DeliveryOptimizationCache -Module $module.Name -ErrorAction SilentlyContinue } else { $null }
            if ($command) {
                $cacheParameters = @{ Force = $true; ErrorAction = 'SilentlyContinue' }
                if ($command.Parameters.ContainsKey('IncludePinnedFiles')) {
                    $cacheParameters['IncludePinnedFiles'] = $true
                }
                & $command @cacheParameters | Out-Null
            }

            $doStates = Stop-MTWinServicesTemporarily @('DoSvc')
            try {
                Remove-MTWinMatchingFiles (Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Logs') @('*.etl', '*.log') -Recurse
            }
            finally { Restore-MTWinServiceStates $doStates }
        }
        'PreviousWindows' {
            if ($activeServicing) {
                Write-Warning 'Active servicing or a pending servicing reboot was detected; rollback files were left in place.'
                return $false
            }
            foreach ($path in @(
                (Join-Path $env:SystemDrive 'Windows.old'),
                (Join-Path $env:SystemDrive '$WINDOWS.~BT'),
                (Join-Path $env:SystemDrive '$WINDOWS.~WS'),
                (Join-Path $env:SystemDrive '$GetCurrent'),
                (Join-Path $env:SystemDrive '$SysReset')
            )) { Remove-MTWinProtectedDirectory $path }
        }
        'HibernationRefresh' {
            if (-not (Invoke-MTWinHibernationRefresh)) { return $false }
        }
        'DeveloperCaches' {
            foreach ($profile in $profiles) {
                foreach ($relativePath in @(
                    'AppData\Local\npm-cache',
                    'AppData\Local\pnpm\store',
                    'AppData\Local\Yarn\Cache',
                    'AppData\Local\Yarn\Berry\cache',
                    'AppData\Local\pip\Cache',
                    'AppData\Local\NuGet\Cache',
                    'AppData\Local\NuGet\v3-cache',
                    'AppData\Local\NuGet\plugins-cache',
                    'AppData\Local\Temp\NuGetScratch',
                    '.nuget\packages',
                    '.gradle\caches',
                    '.gradle\wrapper\dists',
                    '.m2\repository'
                )) {
                    Remove-MTWinDirectoryContents (Join-Path $profile $relativePath)
                }
            }

            # Only execute Docker from its standard protected installation path.
            # This avoids running user-writable package-manager shims as administrator.
            $dockerCandidates = @()
            if ($env:ProgramFiles) { $dockerCandidates += (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe') }
            if (${env:ProgramFiles(x86)}) { $dockerCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\resources\bin\docker.exe') }
            $docker = $dockerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($docker) {
                Write-Host 'Cleaning Docker build cache...'
                & $docker builder prune --all --force 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) { Write-Warning "Docker returned exit code $LASTEXITCODE." }
            }
        }
        'ComponentStore' {
            if ($activeServicing) {
                Write-Warning 'Active servicing or a pending servicing reboot was detected; component cleanup was skipped.'
                return $false
            }
            $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
            if (-not (Test-Path -LiteralPath $dism)) { throw 'dism.exe is unavailable.' }
            & $dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "DISM returned exit code $LASTEXITCODE." }
        }
        'RestorePoints' {
            $vssadmin = Join-Path $env:SystemRoot 'System32\vssadmin.exe'
            if (-not (Test-Path -LiteralPath $vssadmin)) { throw 'vssadmin.exe is unavailable.' }
            & $vssadmin delete shadows "/for=$env:SystemDrive" /all /quiet 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "vssadmin returned exit code $LASTEXITCODE." }
        }
        'EventLogs' {
            $wevtutil = Join-Path $env:SystemRoot 'System32\wevtutil.exe'
            if (-not (Test-Path -LiteralPath $wevtutil)) { throw 'wevtutil.exe is unavailable.' }
            & $wevtutil el 2>$null | ForEach-Object { & $wevtutil cl $_ 2>$null }
        }
        'DiskCleanup' {
            $cleanmgr = Join-Path $env:SystemRoot 'System32\cleanmgr.exe'
            if (-not (Test-Path -LiteralPath $cleanmgr)) {
                Write-Warning 'Disk Cleanup is unavailable on this Windows version.'
                return $false
            }
            Write-Host 'Running built-in Disk Cleanup with default settings.'
            Start-Process -FilePath $cleanmgr -ArgumentList @('/VERYLOWDISK', '/d', $env:SystemDrive) -Wait -ErrorAction Stop
        }
        default { throw "Unknown cleanup operation: $Id" }
    }

    return $true
}

function Set-MTWinRegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'Binary')][string]$Type = 'DWord'
    )

    $resolvedPath = Resolve-MTWinRegistryPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        New-Item -Path $resolvedPath -Force -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -Path $resolvedPath -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

function Remove-MTWinRegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $resolvedPath = Resolve-MTWinRegistryPath -Path $Path
    if (Test-Path -LiteralPath $resolvedPath) {
        Remove-ItemProperty -LiteralPath $resolvedPath -Name $Name -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-MTWinRegistryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path.StartsWith('HKCU:\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $sid = $env:MT_WIN_TOOLS_CALLER_SID
        if ($sid -match '^S-1-\d+(?:-\d+)+$') {
            $userRoot = 'Registry::HKEY_USERS\' + $sid
            if (Test-Path -LiteralPath $userRoot) {
                return ($userRoot + '\' + $Path.Substring(6))
            }
        }
    }

    return $Path
}

function Get-MTWinWindowsBuild {
    try {
        return [int](Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -ErrorAction Stop)
    }
    catch {
        return [Environment]::OSVersion.Version.Build
    }
}

function Get-MTWinCallerProfilePath {
    $sid = $env:MT_WIN_TOOLS_CALLER_SID
    if ($sid -match '^S-1-\d+(?:-\d+)+$') {
        try {
            $profilePath = Get-ItemPropertyValue -Path ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sid) -Name ProfileImagePath -ErrorAction Stop
            return [Environment]::ExpandEnvironmentVariables([string]$profilePath)
        }
        catch { }
    }
    return $env:USERPROFILE
}

function Set-MTWinServiceStartup {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Automatic', 'Manual', 'Disabled')][string]$StartupType
    )

    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($service) {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        if ($StartupType -eq 'Disabled' -and $service.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        }
        return $true
    }
    Write-Host "$Name is unavailable on this Windows version."
    return $false
}

function Restart-MTWinExplorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ErrorAction SilentlyContinue | Out-Null
}

function Invoke-MTWinNativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int[]]$SuccessCodes = @(0)
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { throw "$([IO.Path]::GetFileName($FilePath)) is unavailable." }
    & $FilePath @Arguments 2>&1 | Out-Host
    if ($SuccessCodes -notcontains $LASTEXITCODE) {
        throw "$([IO.Path]::GetFileName($FilePath)) returned exit code $LASTEXITCODE."
    }
}

function Remove-MTWinAppxPackage {
    param([Parameter(Mandatory = $true)][string]$Name)

    $getCommand = Get-Command Get-AppxPackage -ErrorAction SilentlyContinue
    $removeCommand = Get-Command Remove-AppxPackage -ErrorAction SilentlyContinue
    if (-not $getCommand -or -not $removeCommand) { Write-Host 'App package management is unavailable.'; return }
    Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue | ForEach-Object {
        if ($removeCommand.Parameters.ContainsKey('AllUsers')) {
            Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue
        }
        else {
            Remove-AppxPackage -Package $_.PackageFullName -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-MTWinTweak {
    param([Parameter(Mandatory = $true)][string]$Id)

    switch ($Id) {
        'ActivityHistory' {
            $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
            Set-MTWinRegistryValue $path 'EnableActivityFeed' 0
            Set-MTWinRegistryValue $path 'PublishUserActivities' 0
            Set-MTWinRegistryValue $path 'UploadUserActivities' 0
            return 'System restart'
        }
        'DisableHibernation' {
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HibernateEnabled' 0
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' 'ShowHibernateOption' 0
            Invoke-MTWinNativeCommand (Join-Path $env:SystemRoot 'System32\powercfg.exe') @('/hibernate', 'off')
            return 'System restart'
        }
        'RemoveWidgets' {
            if ((Get-MTWinWindowsBuild) -lt 22000) { Write-Warning 'Widgets are only available on Windows 11.'; return $null }
            Get-Process -Name '*Widget*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            foreach ($name in @('Microsoft.WidgetsPlatformRuntime', 'MicrosoftWindows.Client.WebExperience')) {
                Remove-MTWinAppxPackage $name
            }
            return 'Explorer restart'
        }
        'PreviousStartMenu' {
            if ((Get-MTWinWindowsBuild) -lt 22000) { Write-Warning 'The previous Start menu layout applies only to Windows 11.'; return $null }
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\3036241548' 'EnabledState' 1
            return 'System restart'
        }
        'DisableStoreSearchRecommendations' {
            $profile = Get-MTWinCallerProfilePath
            $database = Join-Path $profile 'AppData\Local\Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState\store.db'
            if (-not (Test-Path -LiteralPath $database)) { Write-Warning 'Microsoft Store data was not found for the launching user.'; return $null }
            Invoke-MTWinNativeCommand (Join-Path $env:SystemRoot 'System32\icacls.exe') @($database, '/deny', '*S-1-1-0:(F)')
            return 'Microsoft Store restart'
        }
        'DisableLocationTracking' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' String
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}' 'SensorPermissionState' 0
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration' 'Status' 0
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\Maps' 'AutoUpdateEnabled' 0
            [void](Set-MTWinServiceStartup 'lfsvc' Disabled)
            return 'System restart'
        }
        'SetServicesManual' {
            [void](Set-MTWinServiceStartup 'CscService' Disabled)
            [void](Set-MTWinServiceStartup 'DiagTrack' Disabled)
            [void](Set-MTWinServiceStartup 'MapsBroker' Manual)
            [void](Set-MTWinServiceStartup 'StorSvc' Manual)
            [void](Set-MTWinServiceStartup 'SharedAccess' Disabled)
            $memory = [int64](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' ([int64]($memory / 1KB)) QWord
            return 'System restart'
        }
        'DebloatBrave' {
            $path = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
            $values = @{ BraveRewardsDisabled=1; BraveWalletDisabled=1; BraveVPNDisabled=1; BraveAIChatEnabled=0; BraveStatsPingEnabled=0; BraveNewsDisabled=1; BraveTalkDisabled=1; TorDisabled=1; BraveP3AEnabled=0; UrlKeyedAnonymizedDataCollectionEnabled=0; SafeBrowsingExtendedReportingEnabled=0; MetricsReportingEnabled=0 }
            foreach ($name in $values.Keys) { Set-MTWinRegistryValue $path $name $values[$name] }
            return 'Brave restart'
        }
        'DisableRdpUnsignedWarnings' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\Client' 'RedirectionWarningDialogVersion' 1
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Terminal Server Client' 'RdpLaunchConsentAccepted' 1
            return 'Remote Desktop restart'
        }
        'DebloatEdge' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0
            $path = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
            $values = @{ PersonalizationReportingEnabled=0; ShowRecommendationsEnabled=0; HideFirstRunExperience=1; UserFeedbackAllowed=0; ConfigureDoNotTrack=1; AlternateErrorPagesEnabled=0; EdgeCollectionsEnabled=0; EdgeShoppingAssistantEnabled=0; MicrosoftEdgeInsiderPromotionEnabled=0; ShowMicrosoftRewards=0; WebWidgetAllowed=0; DiagnosticData=0; EdgeAssetDeliveryServiceEnabled=0; WalletDonationEnabled=0; DefaultBrowserSettingsCampaignEnabled=0 }
            foreach ($name in $values.Keys) { Set-MTWinRegistryValue $path $name $values[$name] }
            Set-MTWinRegistryValue ($path + '\ExtensionInstallBlocklist') '1' 'ofefcgjbeghpigppfmkologfjadafddi' String
            return 'Edge restart'
        }
        'DisableConsumerFeatures' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
            return 'Sign-out'
        }
        'DisableTelemetry' {
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Input\TIPC' 'Enabled' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0
            Remove-MTWinRegistryValue 'HKCU:\Software\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds'
            if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction SilentlyContinue }
            [void](Set-MTWinServiceStartup 'DiagTrack' Disabled)
            [void](Set-MTWinServiceStartup 'WerSvc' Disabled)
            [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')
            return 'System restart'
        }
        'DisableDeliveryOptimization' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
            return 'System restart'
        }
        'RemoveEdge' {
            Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue
            $roots = @()
            if (${env:ProgramFiles(x86)}) { $roots += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application') }
            if ($env:ProgramFiles) { $roots += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application') }
            $setup = $roots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
                Get-ChildItem -LiteralPath $_ -Filter setup.exe -Recurse -File -ErrorAction SilentlyContinue
            } | Sort-Object FullName -Descending | Select-Object -First 1
            if (-not $setup) { Write-Warning 'Microsoft Edge setup was not found.'; return $null }
            Invoke-MTWinNativeCommand $setup.FullName @('--uninstall', '--system-level', '--force-uninstall', '--delete-profile')
            return 'System restart'
        }
        'DisableBitLocker' {
            if (-not (Get-Command Disable-BitLocker -ErrorAction SilentlyContinue)) { Write-Warning 'BitLocker management is unavailable on this edition.'; return $null }
            Disable-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop | Out-Null
            Write-Host 'BitLocker decryption will continue in Windows.'
            return 'No restart'
        }
        'UseUtcHardwareClock' {
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' ([int64]1) QWord
            return 'System restart'
        }
        'RemoveOneDrive' {
            Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
            $profile = Get-MTWinCallerProfilePath
            $candidates = @(
                (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'),
                (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'),
                (Join-Path $profile 'AppData\Local\Microsoft\OneDrive\OneDriveSetup.exe')
            )
            $setup = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if (-not $setup) { Write-Warning 'OneDrive setup was not found.'; return $null }
            Invoke-MTWinNativeCommand $setup @('/uninstall') @(0, 3010)
            foreach ($path in @(
                (Join-Path $profile 'OneDrive'),
                (Join-Path $profile 'AppData\Local\Microsoft\OneDrive'),
                (Join-Path $env:ProgramData 'Microsoft OneDrive'),
                (Join-Path $env:SystemDrive 'OneDriveTemp')
            )) { Remove-MTWinProtectedDirectory $path }
            Get-Service -Name 'OneSyncSvc*' -ErrorAction SilentlyContinue | ForEach-Object { Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue }
            return 'Sign-out'
        }
        'DisableExplorerHomeGallery' {
            foreach ($clsid in @('{f874310e-b6b7-47dc-bc84-b9e6b38f5903}', '{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}')) {
                Set-MTWinRegistryValue ('HKCU:\Software\Classes\CLSID\' + $clsid) 'System.IsPinnedToNameSpaceTree' 0
            }
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
            return 'Explorer restart'
        }
        'BestVisualPerformance' {
            Set-MTWinRegistryValue 'HKCU:\Control Panel\Desktop' 'DragFullWindows' '0' String
            Set-MTWinRegistryValue 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '200' String
            Set-MTWinRegistryValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' String
            Set-MTWinRegistryValue 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' String
            foreach ($pair in @(@('ListviewAlphaSelect',0), @('ListviewShadow',0), @('TaskbarAnimations',0), @('TaskbarMn',0), @('ShowTaskViewButton',0))) {
                Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' $pair[0] $pair[1]
            }
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 3
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
            Set-MTWinRegistryValue 'HKCU:\Control Panel\Desktop' 'UserPreferencesMask' ([byte[]](144,18,3,128,16,0,0,0)) Binary
            return 'Sign-out'
        }
        'DisableReservedStorage' {
            Invoke-MTWinNativeCommand (Join-Path $env:SystemRoot 'System32\dism.exe') @('/Online', '/Set-ReservedStorageState', '/State:Disabled') @(0, 3010)
            return 'System restart'
        }
        'CreateRestorePoint' {
            if (-not (Get-Command Checkpoint-Computer -ErrorAction SilentlyContinue)) { Write-Warning 'System Restore is unavailable on this edition.'; return $null }
            Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction SilentlyContinue | Out-Null
            Checkpoint-Computer -Description 'MT win tools' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop | Out-Null
            return 'No restart'
        }
        'EnableEndTask' {
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1
            return 'Explorer restart'
        }
        'DisableStorageSense' {
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0
            return 'Sign-out'
        }
        'DisableWindowsAI' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'hide:aicomponents' String
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsNotepad' 'DisableAIFeatures' 1
            foreach ($name in @('Microsoft.Copilot', 'Microsoft.MicrosoftOfficeHub', 'MicrosoftWindows.Client.AIX')) {
                Remove-MTWinAppxPackage $name
            }
            [void](Set-MTWinServiceStartup 'WSAIFabricSvc' Disabled)
            if (Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction SilentlyContinue) {
                Disable-WindowsOptionalFeature -Online -FeatureName Recall -NoRestart -ErrorAction SilentlyContinue | Out-Null
            }
            return 'System restart'
        }
        'DisableWpbt' {
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1
            return 'System restart'
        }
        'PreventCompanionApps' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata' 'PreventDeviceMetadataFromNetwork' 1
            return 'System restart'
        }
        'BlockRazerInstaller' {
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' 'DisableCoInstallers' 1
            $path = Join-Path $env:SystemRoot 'Installer\Razer'
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
            Invoke-MTWinNativeCommand (Join-Path $env:SystemRoot 'System32\icacls.exe') @($path, '/deny', '*S-1-1-0:(W)')
            return 'System restart'
        }
        'BlockLogitechAssistant' {
            Stop-Process -Name logi_download_assistant -Force -ErrorAction SilentlyContinue
            $path = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'LogiDownloadAssistant' } else { $null }
            if (-not $path) { throw 'Program Files is unavailable.' }
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
            Invoke-MTWinNativeCommand (Join-Path $env:SystemRoot 'System32\icacls.exe') @($path, '/deny', '*S-1-1-0:(W)')
            return 'System restart'
        }
        'DisableNotificationsCalendar' {
            Set-MTWinRegistryValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
            return 'Sign-out'
        }
        'ClassicContextMenu' {
            $path = Resolve-MTWinRegistryPath 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
            if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
            Set-Item -LiteralPath $path -Value '' -Force -ErrorAction Stop
            return 'Explorer restart'
        }
        'PreferIPv4' {
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 32
            return 'System restart'
        }
        'DisableTeredo' {
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 1
            Invoke-MTWinNativeCommand (Join-Path $env:SystemRoot 'System32\netsh.exe') @('interface', 'teredo', 'set', 'state', 'disabled')
            return 'System restart'
        }
        'DisableIPv6' {
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 255
            Get-NetAdapter -ErrorAction Stop | Disable-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Out-Null
            return 'System restart'
        }
        'DisableBackgroundApps' {
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
            return 'Sign-out'
        }
        'DisableFolderDiscovery' {
            $shell = Resolve-MTWinRegistryPath 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell'
            Remove-Item -LiteralPath (Join-Path $shell 'Bags') -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $shell 'BagMRU') -Recurse -Force -ErrorAction SilentlyContinue
            Set-MTWinRegistryValue 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' String
            return 'Sign-out'
        }
        'EnableUltimatePerformance' {
            Invoke-MTWinNativeCommand (Join-Path $env:SystemRoot 'System32\powercfg.exe') @('-duplicatescheme', 'e9a42b02-d5df-448d-aa00-03f14749eb61')
            return 'No restart'
        }
        'DisableUltimatePerformance' {
            $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
            $output = & $powercfg /list 2>&1
            foreach ($line in $output) {
                if ($line -match '([0-9a-fA-F-]{36}).*Ultimate Performance') {
                    & $powercfg /delete $matches[1] 2>&1 | Out-Host
                }
            }
            return 'No restart'
        }
        'DisableGameDvr' {
            Set-MTWinRegistryValue 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
            return 'Application restart'
        }
        'DisablePowerThrottling' {
            Set-MTWinRegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
            return 'System restart'
        }
        'DisableSuggestions' {
            $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            foreach ($name in @('SoftLandingEnabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled')) { Set-MTWinRegistryValue $path $name 0 }
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
            Set-MTWinRegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
            return 'Sign-out'
        }
        'DisableRecentItems' {
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 0
            Set-MTWinRegistryValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoRecentDocsHistory' 1
            return 'Explorer restart'
        }
        default { throw "Unknown tweak: $Id" }
    }
}

function Get-MTWinPreferenceDescriptor {
    param([Parameter(Mandatory = $true)][string]$Id)

    switch ($Id) {
        'DetailedBSOD' { return @{ Effect='System restart'; Settings=@(
            @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name='DisplayParameters'; Type='DWord'; On=1; Off=0; RemoveOff=$false },
            @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name='DisableEmoticon'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'BatteryPercentage' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='IsBatteryPercentageEnabled'; Type='DWord'; On=1; Off=0; RemoveOff=$true }) } }
        'DarkWindowsTheme' { return @{ Effect='Sign-out'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name='AppsUseLightTheme'; Type='DWord'; On=0; Off=1; RemoveOff=$false },
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name='SystemUsesLightTheme'; Type='DWord'; On=0; Off=1; RemoveOff=$false }) } }
        'ShowFileExtensions' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='HideFileExt'; Type='DWord'; On=0; Off=1; RemoveOff=$false }) } }
        'ShowHiddenFiles' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='Hidden'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'VerboseLogon' { return @{ Effect='System restart'; Settings=@(
            @{ Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name='VerboseStatus'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'NewOutlook' { return @{ Effect='Outlook restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Office\16.0\Outlook\Preferences'; Name='UseNewOutlook'; Type='DWord'; On=1; Off=0; RemoveOff=$false },
            @{ Path='HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General'; Name='HideNewOutlookToggle'; Type='DWord'; On=0; Off=1; RemoveOff=$false },
            @{ Path='HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Options\General'; Name='DoNewOutlookAutoMigration'; Type='DWord'; On=0; Off=0; RemoveOff=$false },
            @{ Path='HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Preferences'; Name='NewOutlookMigrationUserSetting'; Type='DWord'; On=0; Off=0; RemoveOff=$true }) } }
        'AlwaysShowScrollbars' { return @{ Effect='Application restart'; Settings=@(
            @{ Path='HKCU:\Control Panel\Accessibility'; Name='DynamicScrollbars'; Type='DWord'; On=0; Off=1; RemoveOff=$false }) } }
        'MouseAcceleration' { return @{ Effect='Sign-out'; Settings=@(
            @{ Path='HKCU:\Control Panel\Mouse'; Name='MouseSpeed'; Type='String'; On='1'; Off='0'; RemoveOff=$false },
            @{ Path='HKCU:\Control Panel\Mouse'; Name='MouseThreshold1'; Type='String'; On='6'; Off='0'; RemoveOff=$false },
            @{ Path='HKCU:\Control Panel\Mouse'; Name='MouseThreshold2'; Type='String'; On='10'; Off='0'; RemoveOff=$false }) } }
        'NumLock' { return @{ Effect='Sign-out'; Settings=@(
            @{ Path='Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard'; Name='InitialKeyboardIndicators'; Type='String'; On='2'; Off='0'; RemoveOff=$false },
            @{ Path='HKCU:\Control Panel\Keyboard'; Name='InitialKeyboardIndicators'; Type='String'; On='2'; Off='0'; RemoveOff=$false }) } }
        'WindowSnapping' { return @{ Effect='Sign-out'; Settings=@(
            @{ Path='HKCU:\Control Panel\Desktop'; Name='WindowArrangementActive'; Type='String'; On='1'; Off='0'; RemoveOff=$false }) } }
        'ModernStandbyNetwork' { return @{ Effect='System restart'; Settings=@(
            @{ Path='HKCU:\Software\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9'; Name='ACSettingIndex'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'S3Sleep' { return @{ Effect='System restart'; Settings=@(
            @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\Power'; Name='PlatformAoAcOverride'; Type='DWord'; On=0; Off=0; RemoveOff=$true }) } }
        'SettingsHome' { return @{ Effect='Settings restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name='SettingsPageVisibility'; Type='String'; On='show:home'; Off='hide:home'; RemoveOff=$false }) } }
        'BingSearch' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name='BingSearchEnabled'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'LoginAcrylic' { return @{ Effect='System restart'; Settings=@(
            @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='DisableAcrylicBackgroundOnLogon'; Type='DWord'; On=0; Off=1; RemoveOff=$false }) } }
        'DisableLockScreen' { return @{ Effect='System restart'; Settings=@(
            @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'; Name='NoLockScreen'; Type='DWord'; On=1; Off=0; RemoveOff=$true }) } }
        'StartRecommendations' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name='HideRecommendedSection'; Type='DWord'; On=0; Off=1; RemoveOff=$false },
            @{ Path='HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education'; Name='IsEducationEnvironment'; Type='DWord'; On=0; Off=1; RemoveOff=$false },
            @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name='HideRecommendedSection'; Type='DWord'; On=0; Off=1; RemoveOff=$false }) } }
        'DisableStickyKeys' { return @{ Effect='Sign-out'; Settings=@(
            @{ Path='HKCU:\Control Panel\Accessibility\StickyKeys'; Name='Flags'; Type='String'; On='506'; Off='58'; RemoveOff=$false }) } }
        'CenteredTaskbar' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='TaskbarAl'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'TaskbarSearch' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name='SearchboxTaskbarMode'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'TaskViewButton' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='ShowTaskViewButton'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'GameMode' { return @{ Effect='Application restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\GameBar'; Name='AllowAutoGameMode'; Type='DWord'; On=1; Off=0; RemoveOff=$false },
            @{ Path='HKCU:\Software\Microsoft\GameBar'; Name='AutoGameModeEnabled'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'LongPaths' { return @{ Effect='Application restart'; Settings=@(
            @{ Path='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; Name='LongPathsEnabled'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'ClockSeconds' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='ShowSecondsInSystemClock'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'DisableAeroShake' { return @{ Effect='Sign-out'; Settings=@(
            @{ Path='HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name='DisallowShaking'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'ExplorerCompactView' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='UseCompactMode'; Type='DWord'; On=1; Off=0; RemoveOff=$false }) } }
        'RemoveStartupDelay' { return @{ Effect='Sign-out'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name='StartupDelayInMSec'; Type='DWord'; On=0; Off=0; RemoveOff=$true }) } }
        'ClassicAltTab' { return @{ Effect='Explorer restart'; Settings=@(
            @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name='AltTabSettings'; Type='DWord'; On=1; Off=0; RemoveOff=$true }) } }
        default { throw "Unknown preference: $Id" }
    }
}

function Get-MTWinPreferenceState {
    param([Parameter(Mandatory = $true)][string]$Id)

    $descriptor = Get-MTWinPreferenceDescriptor $Id
    foreach ($setting in $descriptor.Settings) {
        $path = Resolve-MTWinRegistryPath $setting.Path
        try { $value = Get-ItemPropertyValue -LiteralPath $path -Name $setting.Name -ErrorAction Stop }
        catch { return $false }
        if ([string]$value -ne [string]$setting.On) { return $false }
    }
    return $true
}

function Invoke-MTWinPreference {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $descriptor = Get-MTWinPreferenceDescriptor $Id
    foreach ($setting in $descriptor.Settings) {
        if ($Enabled) {
            Set-MTWinRegistryValue $setting.Path $setting.Name $setting.On $setting.Type
        }
        elseif ($setting.RemoveOff) {
            Remove-MTWinRegistryValue $setting.Path $setting.Name
        }
        else {
            Set-MTWinRegistryValue $setting.Path $setting.Name $setting.Off $setting.Type
        }
    }
    return $descriptor.Effect
}

function Invoke-MTWinChoice {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Value
    )

    if ($Id -eq 'MPO') {
        $dwm = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
        $drivers = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        switch ($Value) {
            'Enabled' { Remove-MTWinRegistryValue $dwm 'OverlayTestMode'; Remove-MTWinRegistryValue $drivers 'DisableOverlays' }
            'Compatibility mode' { Set-MTWinRegistryValue $dwm 'OverlayTestMode' 5; Remove-MTWinRegistryValue $drivers 'DisableOverlays' }
            'Disabled' { Set-MTWinRegistryValue $dwm 'OverlayTestMode' 5; Set-MTWinRegistryValue $drivers 'DisableOverlays' 1 }
            default { throw "Unknown MPO setting: $Value" }
        }
        return 'System restart'
    }

    if ($Id -eq 'DNS') {
        $presets = @{
            'Google'=@('8.8.8.8','8.8.4.4','2001:4860:4860::8888','2001:4860:4860::8844')
            'Cloudflare'=@('1.1.1.1','1.0.0.1','2606:4700:4700::1111','2606:4700:4700::1001')
            'Cloudflare Malware'=@('1.1.1.2','1.0.0.2','2606:4700:4700::1112','2606:4700:4700::1002')
            'Cloudflare Family'=@('1.1.1.3','1.0.0.3','2606:4700:4700::1113','2606:4700:4700::1003')
            'OpenDNS'=@('208.67.222.222','208.67.220.220','2620:119:35::35','2620:119:53::53')
            'Quad9'=@('9.9.9.9','149.112.112.112','2620:fe::fe','2620:fe::9')
            'AdGuard'=@('94.140.14.14','94.140.15.15','2a10:50c0::ad1:ff','2a10:50c0::ad2:ff')
            'AdGuard Family'=@('94.140.14.15','94.140.15.16','2a10:50c0::bad1:ff','2a10:50c0::bad2:ff')
        }
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')
        if ($adapters.Count -eq 0) { throw 'No active network adapters were found.' }
        foreach ($adapter in $adapters) {
            if ($Value -eq 'Automatic (DHCP)') {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction Stop
            }
            elseif ($presets.ContainsKey($Value)) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $presets[$Value] -ErrorAction Stop
            }
            else { throw "Unknown DNS preset: $Value" }
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        return 'Network reconnect'
    }

    throw "Unknown choice: $Id"
}

function Get-MTWinOperationDisplayName {
    param([Parameter(Mandatory = $true)][string]$Id)

    $names = @{
        TemporaryFiles='Temporary files'; CrashReports='Crash dumps and error reports';
        ServicingLogs='Servicing and setup logs'; ShaderCaches='Shader caches';
        BrowserCaches='Browser caches'; ExplorerCaches='Explorer icon and thumbnail caches';
        RecycleBin='Recycle Bin'; ChkdskFragments='CHKDSK fragments'; BranchCache='BranchCache';
        WindowsUpdateCache='Windows Update caches'; PreviousWindows='Previous Windows files';
        HibernationRefresh='Hibernation file refresh'; DeveloperCaches='Developer caches';
        ComponentStore='Component store ResetBase'; RestorePoints='Restore points and shadow copies';
        EventLogs='Windows Event Logs'; DiskCleanup='Built-in Disk Cleanup';
        ActivityHistory='Disable Activity History'; DisableHibernation='Disable hibernation and Fast Startup';
        RemoveWidgets='Remove Widgets'; PreviousStartMenu='Enable previous Start menu layout';
        DisableStoreSearchRecommendations='Disable Microsoft Store search recommendations';
        DisableLocationTracking='Disable location tracking'; SetServicesManual='Set selected services to manual or disabled';
        DebloatBrave='Debloat Brave Browser'; DisableRdpUnsignedWarnings='Disable RDP unsigned-file warnings';
        DebloatEdge='Debloat Microsoft Edge'; DisableConsumerFeatures='Disable Windows consumer features';
        DisableTelemetry='Disable Windows telemetry'; DisableDeliveryOptimization='Disable Delivery Optimization peer sharing';
        RemoveEdge='Remove Microsoft Edge'; DisableBitLocker='Disable BitLocker'; UseUtcHardwareClock='Use UTC hardware clock';
        RemoveOneDrive='Remove Microsoft OneDrive'; DisableExplorerHomeGallery='Remove Explorer Home and Gallery';
        BestVisualPerformance='Use best-performance visual effects'; DisableReservedStorage='Disable Reserved Storage';
        CreateRestorePoint='Create a system restore point'; EnableEndTask='Enable End task on the taskbar';
        DisableStorageSense='Disable Storage Sense'; DisableWindowsAI='Disable and remove Windows AI features';
        DisableWpbt='Disable WPBT execution'; PreventCompanionApps='Prevent device companion apps';
        BlockRazerInstaller='Block Razer automatic installer'; BlockLogitechAssistant='Block Logitech Download Assistant';
        DisableNotificationsCalendar='Disable notifications and calendar'; ClassicContextMenu='Enable classic context menu';
        PreferIPv4='Prefer IPv4 over IPv6'; DisableTeredo='Disable Teredo'; DisableIPv6='Disable IPv6';
        DisableBackgroundApps='Disable background apps'; DisableFolderDiscovery='Disable Explorer folder discovery';
        EnableUltimatePerformance='Add Ultimate Performance power plan'; DisableUltimatePerformance='Remove Ultimate Performance power plan';
        DisableGameDvr='Disable background game capture'; DisablePowerThrottling='Disable power throttling';
        DisableSuggestions='Disable suggestions and consumer content'; DisableRecentItems='Disable recent items';
        DetailedBSOD='Detailed blue-screen information'; BatteryPercentage='Battery percentage'; DarkWindowsTheme='Dark Windows theme';
        ShowFileExtensions='File extensions'; ShowHiddenFiles='Hidden files'; VerboseLogon='Verbose sign-in status';
        NewOutlook='New Outlook'; AlwaysShowScrollbars='Always-visible scrollbars'; MouseAcceleration='Mouse acceleration';
        NumLock='Num Lock at sign-in'; WindowSnapping='Window snapping'; ModernStandbyNetwork='Modern Standby networking';
        S3Sleep='S3 sleep'; SettingsHome='Settings Home'; BingSearch='Bing search in Start'; LoginAcrylic='Sign-in acrylic';
        DisableLockScreen='Disable lock screen'; StartRecommendations='Start recommendations'; DisableStickyKeys='Disable Sticky Keys shortcut';
        CenteredTaskbar='Centered taskbar'; TaskbarSearch='Taskbar search'; TaskViewButton='Task View button'; GameMode='Game Mode';
        LongPaths='Long Win32 paths'; ClockSeconds='Taskbar clock seconds'; DisableAeroShake='Disable Aero Shake';
        ExplorerCompactView='Explorer compact view'; RemoveStartupDelay='Remove startup delay'; ClassicAltTab='Classic Alt+Tab';
        MPO='Multiplane Overlay'; DNS='DNS preset'
    }

    if ($Id -match '^Preference\|([^|]+)\|([01])$') {
        $name = if ($names.ContainsKey($matches[1])) { $names[$matches[1]] } else { $matches[1] }
        $state = if ($matches[2] -eq '1') { 'On' } else { 'Off' }
        return "${name}: $state"
    }
    if ($Id -match '^Choice\|([^|]+)\|(.+)$') {
        $name = if ($names.ContainsKey($matches[1])) { $names[$matches[1]] } else { $matches[1] }
        return "${name}: $($matches[2])"
    }
    if ($names.ContainsKey($Id)) { return $names[$Id] }
    return $Id
}

function Invoke-MTWinToolsOperationBatch {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Cleanup', 'Tweaks')][string]$Kind,
        [Parameter(Mandatory = $true)][string[]]$Ids
    )

    $failures = 0
    $effects = @()
    $freeBefore = 0

    if ($Kind -eq 'Cleanup') {
        $freeBefore = Get-MTWinSystemFreeBytes
        $context = @{
            ActiveServicing = Test-MTWinActiveServicing
            UserProfiles = @(Get-MTWinLocalUserProfiles)
        }

        Write-Host ''
        Write-Host "MT win tools | Cleanup" -ForegroundColor White
        Write-Host "System drive: $env:SystemDrive"
        Write-Host "Free before: $(Format-MTWinBytes $freeBefore)"
        if ($context.ActiveServicing) {
            Write-Warning 'Windows servicing activity or a pending servicing reboot was detected. Servicing-sensitive operations will be skipped.'
        }

        $orderedIds = @($Ids | Where-Object { $_ -ne 'DiskCleanup' })
        if ($Ids -contains 'DiskCleanup') { $orderedIds += 'DiskCleanup' }

        foreach ($id in $orderedIds) {
            $displayName = Get-MTWinOperationDisplayName $id
            Write-MTWinStatus -Message $displayName
            try {
                $completed = Invoke-MTWinCleanupOperation -Id $id -Context $context
                if ($completed -eq $false) {
                    Write-MTWinStatus -Message $displayName -Level Warning
                }
                else {
                    Write-MTWinStatus -Message $displayName -Level Success
                }
            }
            catch {
                $failures++
                Write-MTWinStatus -Message ("$displayName - " + $_.Exception.Message) -Level Error
            }
        }

        $freeAfter = Get-MTWinSystemFreeBytes
        Write-Host ''
        Write-Host "Free after:  $(Format-MTWinBytes $freeAfter)"
        if ($freeBefore -gt 0 -and $freeAfter -ge $freeBefore) {
            Write-Host "Reclaimed:   $(Format-MTWinBytes ($freeAfter - $freeBefore))"
        }
        elseif ($freeBefore -gt 0) {
            Write-Host 'Reclaimed: disk accounting changed while cleanup was running.'
        }
    }
    else {
        Write-Host ''
        Write-Host "MT win tools | Tweaks" -ForegroundColor White
        foreach ($id in $Ids) {
            $displayName = Get-MTWinOperationDisplayName $id
            Write-MTWinStatus -Message $displayName
            try {
                if ($id -match '^Preference\|([^|]+)\|([01])$') {
                    $effect = Invoke-MTWinPreference -Id $matches[1] -Enabled ($matches[2] -eq '1')
                }
                elseif ($id -match '^Choice\|([^|]+)\|(.+)$') {
                    $effect = Invoke-MTWinChoice -Id $matches[1] -Value $matches[2]
                }
                else {
                    $effect = Invoke-MTWinTweak -Id $id
                }
                if ($null -eq $effect) {
                    Write-MTWinStatus -Message $displayName -Level Warning
                }
                else {
                    if ([string]$effect -ne 'No restart' -and -not [string]::IsNullOrWhiteSpace([string]$effect)) { $effects += $effect }
                    Write-MTWinStatus -Message $displayName -Level Success
                }
            }
            catch {
                $failures++
                Write-MTWinStatus -Message ("$displayName - " + $_.Exception.Message) -Level Error
            }
        }

        $effects = @($effects | Sort-Object -Unique)
        if ($effects -contains 'Explorer restart') {
            Write-Host 'Restarting Explorer to apply selected changes.'
            Restart-MTWinExplorer
            $effects = @($effects | Where-Object { $_ -ne 'Explorer restart' })
        }
        foreach ($effect in $effects) {
            Write-Host "$effect required for one or more selected changes." -ForegroundColor Yellow
        }
    }

    [pscustomobject]@{
        Kind = $Kind
        Failures = $failures
        Effects = $effects
    }
}

function Start-MTWinOperationJob {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Cleanup', 'Tweaks')][string]$Kind,
        [Parameter(Mandatory = $true)][string[]]$Ids
    )

    $functionNames = @(
        'Write-MTWinStatus', 'Format-MTWinBytes', 'Get-MTWinSystemFreeBytes',
        'Test-MTWinReparsePoint', 'Remove-MTWinDirectoryContents', 'Remove-MTWinFile',
        'Remove-MTWinMatchingFiles', 'Get-MTWinLocalUserProfiles',
        'Test-MTWinPendingServicingReboot', 'Test-MTWinActiveServicing',
        'Wait-MTWinServiceState', 'Stop-MTWinServicesTemporarily',
        'Restore-MTWinServiceStates', 'Remove-MTWinProtectedDirectory',
        'Clear-MTWinChromiumCachesForProfile', 'Clear-MTWinCallerRecycleBin',
        'Invoke-MTWinHibernationRefresh', 'Invoke-MTWinCleanupOperation',
        'Resolve-MTWinRegistryPath', 'Set-MTWinRegistryValue', 'Remove-MTWinRegistryValue',
        'Get-MTWinWindowsBuild', 'Get-MTWinCallerProfilePath', 'Set-MTWinServiceStartup',
        'Restart-MTWinExplorer', 'Invoke-MTWinNativeCommand', 'Remove-MTWinAppxPackage', 'Invoke-MTWinTweak',
        'Get-MTWinPreferenceDescriptor', 'Invoke-MTWinPreference', 'Invoke-MTWinChoice',
        'Get-MTWinOperationDisplayName', 'Invoke-MTWinToolsOperationBatch'
    )

    $runspace = $null
    $powerShell = $null
    try {
        $state = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($name in $functionNames) {
            $definition = (Get-Command -Name $name -CommandType Function -ErrorAction Stop).Definition
            $entry = [Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, $definition)
            $state.Commands.Add($entry)
        }

        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($Host, $state)
        $runspace.Open()
        $powerShell = [PowerShell]::Create()
        $powerShell.Runspace = $runspace
        [void]$powerShell.AddCommand('Invoke-MTWinToolsOperationBatch').AddParameter('Kind', $Kind).AddParameter('Ids', $Ids)

        $script:ActiveJob = [pscustomobject]@{
            Kind = $Kind
            PowerShell = $powerShell
            Runspace = $runspace
            Async = $powerShell.BeginInvoke()
            Total = $Ids.Count
        }
    }
    catch {
        if ($powerShell) { $powerShell.Dispose() }
        if ($runspace) {
            try { $runspace.Close() } catch { }
            $runspace.Dispose()
        }
        throw
    }
}

$cleanupDefinitions = @(
    [pscustomobject]@{ Category='Temporary data'; Id='TemporaryFiles'; Name='Delete temporary files'; Risk=$false },
    [pscustomobject]@{ Category='Temporary data'; Id='CrashReports'; Name='Delete crash dumps and error reports'; Risk=$true },
    [pscustomobject]@{ Category='Temporary data'; Id='ServicingLogs'; Name='Delete servicing and setup logs'; Risk=$false },
    [pscustomobject]@{ Category='Temporary data'; Id='ShaderCaches'; Name='Delete shader caches'; Risk=$false },
    [pscustomobject]@{ Category='Temporary data'; Id='BrowserCaches'; Name='Delete browser caches'; Risk=$false },
    [pscustomobject]@{ Category='Temporary data'; Id='ExplorerCaches'; Name='Rebuild Explorer icon and thumbnail caches'; Risk=$false },
    [pscustomobject]@{ Category='Temporary data'; Id='RecycleBin'; Name='Empty the Recycle Bin'; Risk=$true },
    [pscustomobject]@{ Category='Windows cleanup'; Id='ChkdskFragments'; Name='Delete CHKDSK recovery fragments'; Risk=$true },
    [pscustomobject]@{ Category='Windows cleanup'; Id='BranchCache'; Name='Clear BranchCache'; Risk=$false },
    [pscustomobject]@{ Category='Windows cleanup'; Id='WindowsUpdateCache'; Name='Clear Windows Update caches'; Risk=$false },
    [pscustomobject]@{ Category='Windows cleanup'; Id='HibernationRefresh'; Name='Rebuild the hibernation file'; Risk=$true },
    [pscustomobject]@{ Category='Aggressive cleanup'; Id='PreviousWindows'; Name='Delete previous Windows installations'; Risk=$true },
    [pscustomobject]@{ Category='Aggressive cleanup'; Id='DeveloperCaches'; Name='Delete developer and Docker caches'; Risk=$true },
    [pscustomobject]@{ Category='Aggressive cleanup'; Id='ComponentStore'; Name='Reset the Windows component store'; Risk=$true },
    [pscustomobject]@{ Category='Aggressive cleanup'; Id='RestorePoints'; Name='Delete restore points and shadow copies'; Risk=$true },
    [pscustomobject]@{ Category='Aggressive cleanup'; Id='EventLogs'; Name='Clear Windows Event Logs'; Risk=$true }
)

$tweakDefinitions = @(
    [pscustomobject]@{ Category='Privacy'; Id='DisableTelemetry'; Name='Disable Windows telemetry'; Risk=$false },
    [pscustomobject]@{ Category='Privacy'; Id='ActivityHistory'; Name='Disable Activity History'; Risk=$false },
    [pscustomobject]@{ Category='Privacy'; Id='DisableLocationTracking'; Name='Disable location tracking'; Risk=$false },
    [pscustomobject]@{ Category='Privacy'; Id='DisableConsumerFeatures'; Name='Disable Windows consumer features'; Risk=$false },
    [pscustomobject]@{ Category='Privacy'; Id='DisableSuggestions'; Name='Disable suggestions and welcome content'; Risk=$false },
    [pscustomobject]@{ Category='Privacy'; Id='DisableDeliveryOptimization'; Name='Disable update peer sharing'; Risk=$false },
    [pscustomobject]@{ Category='Privacy'; Id='DisableBackgroundApps'; Name='Disable background apps'; Risk=$false },
    [pscustomobject]@{ Category='Windows debloat'; Id='RemoveWidgets'; Name='Remove Windows Widgets'; Risk=$true },
    [pscustomobject]@{ Category='Windows debloat'; Id='DisableWindowsAI'; Name='Disable and remove Windows AI features'; Risk=$true },
    [pscustomobject]@{ Category='Windows debloat'; Id='RemoveOneDrive'; Name='Remove Microsoft OneDrive'; Risk=$true },
    [pscustomobject]@{ Category='Windows debloat'; Id='RemoveEdge'; Name='Remove Microsoft Edge'; Risk=$true },
    [pscustomobject]@{ Category='Windows debloat'; Id='DebloatEdge'; Name='Debloat Microsoft Edge'; Risk=$false },
    [pscustomobject]@{ Category='Windows debloat'; Id='DebloatBrave'; Name='Debloat Brave Browser'; Risk=$false },
    [pscustomobject]@{ Category='Windows debloat'; Id='DisableStoreSearchRecommendations'; Name='Disable Microsoft Store search recommendations'; Risk=$true },
    [pscustomobject]@{ Category='Windows debloat'; Id='DisableNotificationsCalendar'; Name='Disable notifications and calendar'; Risk=$false },
    [pscustomobject]@{ Category='Windows behavior'; Id='PreviousStartMenu'; Name='Enable the previous Start menu layout'; Risk=$false },
    [pscustomobject]@{ Category='Windows behavior'; Id='ClassicContextMenu'; Name='Enable the classic context menu'; Risk=$false },
    [pscustomobject]@{ Category='Windows behavior'; Id='DisableExplorerHomeGallery'; Name='Remove Explorer Home and Gallery'; Risk=$false },
    [pscustomobject]@{ Category='Windows behavior'; Id='DisableFolderDiscovery'; Name='Disable Explorer folder discovery'; Risk=$false },
    [pscustomobject]@{ Category='Windows behavior'; Id='DisableRecentItems'; Name='Disable recent and frequent items'; Risk=$false },
    [pscustomobject]@{ Category='Windows behavior'; Id='EnableEndTask'; Name='Enable End task on the taskbar'; Risk=$false },
    [pscustomobject]@{ Category='Windows behavior'; Id='DisableStorageSense'; Name='Disable Storage Sense'; Risk=$false },
    [pscustomobject]@{ Category='Performance'; Id='BestVisualPerformance'; Name='Use best-performance visual effects'; Risk=$false },
    [pscustomobject]@{ Category='Performance'; Id='DisablePowerThrottling'; Name='Disable power throttling'; Risk=$false },
    [pscustomobject]@{ Category='Performance'; Id='DisableGameDvr'; Name='Disable background game capture'; Risk=$false },
    [pscustomobject]@{ Category='Performance'; Id='DisableHibernation'; Name='Disable hibernation and Fast Startup'; Risk=$true },
    [pscustomobject]@{ Category='Performance'; Id='DisableReservedStorage'; Name='Disable Windows Reserved Storage'; Risk=$false },
    [pscustomobject]@{ Category='Performance'; Id='EnableUltimatePerformance'; Name='Add the Ultimate Performance power plan'; Risk=$false },
    [pscustomobject]@{ Category='Performance'; Id='DisableUltimatePerformance'; Name='Remove the Ultimate Performance power plan'; Risk=$false },
    [pscustomobject]@{ Category='System'; Id='SetServicesManual'; Name='Set selected services to manual or disabled'; Risk=$false },
    [pscustomobject]@{ Category='System'; Id='CreateRestorePoint'; Name='Create a system restore point'; Risk=$false },
    [pscustomobject]@{ Category='System'; Id='DisableBitLocker'; Name='Disable BitLocker on the Windows drive'; Risk=$true },
    [pscustomobject]@{ Category='System'; Id='UseUtcHardwareClock'; Name='Use UTC for the hardware clock'; Risk=$false },
    [pscustomobject]@{ Category='System'; Id='DisableWpbt'; Name='Disable WPBT firmware execution'; Risk=$false },
    [pscustomobject]@{ Category='System'; Id='PreventCompanionApps'; Name='Prevent automatic device companion apps'; Risk=$false },
    [pscustomobject]@{ Category='System'; Id='DisableRdpUnsignedWarnings'; Name='Disable RDP unsigned-file warnings'; Risk=$true },
    [pscustomobject]@{ Category='Device installers'; Id='BlockRazerInstaller'; Name='Block the Razer automatic installer'; Risk=$true },
    [pscustomobject]@{ Category='Device installers'; Id='BlockLogitechAssistant'; Name='Block Logitech Download Assistant'; Risk=$true },
    [pscustomobject]@{ Category='Network'; Id='PreferIPv4'; Name='Prefer IPv4 over IPv6'; Risk=$false },
    [pscustomobject]@{ Category='Network'; Id='DisableTeredo'; Name='Disable Teredo tunneling'; Risk=$false },
    [pscustomobject]@{ Category='Network'; Id='DisableIPv6'; Name='Disable IPv6 on all adapters'; Risk=$true }
)

$preferenceDefinitions = @(
    [pscustomobject]@{ Category='Windows'; Id='DetailedBSOD'; Name='Show detailed blue-screen information' },
    [pscustomobject]@{ Category='Windows'; Id='BatteryPercentage'; Name='Show battery percentage' },
    [pscustomobject]@{ Category='Windows'; Id='VerboseLogon'; Name='Show verbose sign-in status' },
    [pscustomobject]@{ Category='Windows'; Id='NewOutlook'; Name='Use the new Outlook' },
    [pscustomobject]@{ Category='Windows'; Id='SettingsHome'; Name='Show Settings Home' },
    [pscustomobject]@{ Category='Windows'; Id='BingSearch'; Name='Use Bing in Start search' },
    [pscustomobject]@{ Category='Windows'; Id='DisableLockScreen'; Name='Disable the lock screen' },
    [pscustomobject]@{ Category='Windows'; Id='StartRecommendations'; Name='Show Start recommendations' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='ShowFileExtensions'; Name='Show file extensions' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='ShowHiddenFiles'; Name='Show hidden files' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='CenteredTaskbar'; Name='Center taskbar icons' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='TaskbarSearch'; Name='Show taskbar search' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='TaskViewButton'; Name='Show the Task View button' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='ClockSeconds'; Name='Show seconds in the taskbar clock' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='ExplorerCompactView'; Name='Use Explorer compact view' },
    [pscustomobject]@{ Category='Explorer and taskbar'; Id='ClassicAltTab'; Name='Use classic Alt+Tab' },
    [pscustomobject]@{ Category='Appearance'; Id='DarkWindowsTheme'; Name='Use the dark Windows theme' },
    [pscustomobject]@{ Category='Appearance'; Id='AlwaysShowScrollbars'; Name='Always show Windows scrollbars' },
    [pscustomobject]@{ Category='Appearance'; Id='LoginAcrylic'; Name='Use acrylic on the sign-in screen' },
    [pscustomobject]@{ Category='Input and desktop'; Id='MouseAcceleration'; Name='Enable mouse acceleration' },
    [pscustomobject]@{ Category='Input and desktop'; Id='NumLock'; Name='Enable Num Lock at sign-in' },
    [pscustomobject]@{ Category='Input and desktop'; Id='WindowSnapping'; Name='Enable window snapping' },
    [pscustomobject]@{ Category='Input and desktop'; Id='DisableStickyKeys'; Name='Disable the Sticky Keys shortcut' },
    [pscustomobject]@{ Category='Input and desktop'; Id='DisableAeroShake'; Name='Disable Aero Shake' },
    [pscustomobject]@{ Category='Performance and compatibility'; Id='GameMode'; Name='Enable Game Mode' },
    [pscustomobject]@{ Category='Performance and compatibility'; Id='LongPaths'; Name='Enable long Win32 paths' },
    [pscustomobject]@{ Category='Performance and compatibility'; Id='ModernStandbyNetwork'; Name='Allow networking during Modern Standby' },
    [pscustomobject]@{ Category='Performance and compatibility'; Id='S3Sleep'; Name='Use S3 sleep when supported' },
    [pscustomobject]@{ Category='Performance and compatibility'; Id='RemoveStartupDelay'; Name='Remove the startup application delay' }
)

$choiceDefinitions = @(
    [pscustomobject]@{ Id='DNS'; Name='DNS preset'; Options=@('No change','Automatic (DHCP)','Google','Cloudflare','Cloudflare Malware','Cloudflare Family','OpenDNS','Quad9','AdGuard','AdGuard Family') },
    [pscustomobject]@{ Id='MPO'; Name='Multiplane Overlay'; Options=@('No change','Enabled','Compatibility mode','Disabled') }
)

$systemAppDefinitions = @(
    [pscustomobject]@{ Category='Settings'; Name='Windows Settings'; Kind='Uri'; Target='ms-settings:'; Arguments='' },
    [pscustomobject]@{ Category='Settings'; Name='System information'; Kind='Uri'; Target='ms-settings:about'; Arguments='' },
    [pscustomobject]@{ Category='Settings'; Name='Installed apps'; Kind='Uri'; Target='ms-settings:appsfeatures'; Arguments='' },
    [pscustomobject]@{ Category='Settings'; Name='Storage settings'; Kind='Uri'; Target='ms-settings:storagesense'; Arguments='' },
    [pscustomobject]@{ Category='Settings'; Name='Network settings'; Kind='Uri'; Target='ms-settings:network-status'; Arguments='' },
    [pscustomobject]@{ Category='Settings'; Name='Privacy settings'; Kind='Uri'; Target='ms-settings:privacy'; Arguments='' },
    [pscustomobject]@{ Category='Settings'; Name='Windows Security'; Kind='Uri'; Target='ms-settings:windowsdefender'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Control Panel'; Kind='System32'; Target='control.exe'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Programs and Features'; Kind='System32'; Target='control.exe'; Arguments='appwiz.cpl' },
    [pscustomobject]@{ Category='System management'; Name='Windows Features'; Kind='System32'; Target='OptionalFeatures.exe'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Device Manager'; Kind='Msc'; Target='devmgmt.msc'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Task Manager'; Kind='System32'; Target='taskmgr.exe'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Disk Management'; Kind='Msc'; Target='diskmgmt.msc'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Computer Management'; Kind='Msc'; Target='compmgmt.msc'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Services'; Kind='Msc'; Target='services.msc'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='System Configuration'; Kind='System32'; Target='msconfig.exe'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='Registry Editor'; Kind='System32'; Target='regedit.exe'; Arguments='' },
    [pscustomobject]@{ Category='System management'; Name='System Properties'; Kind='System32'; Target='control.exe'; Arguments='sysdm.cpl' },
    [pscustomobject]@{ Category='System management'; Name='Power Options'; Kind='System32'; Target='control.exe'; Arguments='powercfg.cpl' },
    [pscustomobject]@{ Category='System management'; Name='Environment Variables'; Kind='System32'; Target='rundll32.exe'; Arguments='sysdm.cpl,EditEnvironmentVariables' },
    [pscustomobject]@{ Category='System management'; Name='Network Connections'; Kind='System32'; Target='control.exe'; Arguments='ncpa.cpl' },
    [pscustomobject]@{ Category='Administration'; Name='Advanced Firewall'; Kind='Msc'; Target='wf.msc'; Arguments='' },
    [pscustomobject]@{ Category='Administration'; Name='Event Viewer'; Kind='Msc'; Target='eventvwr.msc'; Arguments='' },
    [pscustomobject]@{ Category='Administration'; Name='Resource Monitor'; Kind='System32'; Target='resmon.exe'; Arguments='' },
    [pscustomobject]@{ Category='Administration'; Name='Group Policy Editor'; Kind='Msc'; Target='gpedit.msc'; Arguments='' }
)

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
}
catch {
    Write-Error ("MT win tools could not load the Windows desktop interface: " + $_.Exception.Message)
    return
}

if (-not ('MTWinTools.NativeMethods' -as [type])) {
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace MTWinTools {
    public static class NativeMethods {
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    }
}
'@
    }
    catch {
        # The interface remains functional if title-bar theming is unavailable.
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MT win tools" Width="1120" Height="780" MinWidth="680" MinHeight="560"
        WindowStartupLocation="CenterScreen" WindowState="Maximized" ResizeMode="CanResize"
        Background="{DynamicResource PageBrush}"
        FontFamily="Segoe UI" FontSize="16" TextOptions.TextFormattingMode="Display"
        SnapsToDevicePixels="True" UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="AppearanceButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
            <Setter Property="Background" Value="{DynamicResource RaisedBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="Padding" Value="14,0"/>
            <Setter Property="Height" Value="40"/>
            <Setter Property="MinWidth" Value="154"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" ClipToBounds="True">
                            <Grid>
                                <Border x:Name="HoverOverlay" Background="{DynamicResource ControlBrush}" CornerRadius="8" Opacity="0" IsHitTestVisible="False"/>
                                <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="HoverOverlay" Property="Opacity" Value="0.09"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="TextButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="Padding" Value="9,0"/>
            <Setter Property="MinHeight" Value="36"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" ClipToBounds="True">
                            <Grid>
                                <Border x:Name="HoverOverlay" Background="{DynamicResource RaisedBrush}" CornerRadius="5" Opacity="0" IsHitTestVisible="False"/>
                                <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="HoverOverlay" Property="Opacity" Value="1"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.36"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PrimaryButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Foreground" Value="{DynamicResource SurfaceBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="Padding" Value="15,0"/>
            <Setter Property="MinHeight" Value="42"/>
            <Setter Property="MinWidth" Value="132"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}"/>
                            <Border x:Name="HoverOverlay" Background="{DynamicResource SurfaceBrush}" CornerRadius="10" Opacity="0" IsHitTestVisible="False"/>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="HoverOverlay" Property="Opacity" Value="0.18"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.36"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0.12" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="NavButtonStyle" TargetType="ToggleButton">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Padding" Value="12,0"/>
            <Setter Property="MinHeight" Value="46"/>
            <Setter Property="Margin" Value="0,0,0,4"/>
            <Setter Property="FontSize" Value="15"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
                            <ContentPresenter x:Name="Content" Margin="{TemplateBinding Padding}" Opacity="0.74"
                                              HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource ControlBrush}"/>
                                <Setter TargetName="Content" Property="Opacity" Value="1"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsMouseOver" Value="True"/>
                                    <Condition Property="IsChecked" Value="False"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="Content" Property="Opacity" Value="1"/>
                                <MultiTrigger.EnterActions>
                                    <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Content" Storyboard.TargetProperty="Opacity" From="0.74" To="1" Duration="0:0:0.14" FillBehavior="Stop"/></Storyboard></BeginStoryboard>
                                </MultiTrigger.EnterActions>
                            </MultiTrigger>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsMouseOver" Value="False"/>
                                    <Condition Property="IsChecked" Value="False"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="Content" Property="Opacity" Value="0.74"/>
                                <MultiTrigger.EnterActions>
                                    <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Content" Storyboard.TargetProperty="Opacity" From="1" To="0.74" Duration="0:0:0.14" FillBehavior="Stop"/></Storyboard></BeginStoryboard>
                                </MultiTrigger.EnterActions>
                            </MultiTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SubmenuButtonStyle" TargetType="ToggleButton">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="MinHeight" Value="34"/>
            <Setter Property="Margin" Value="0,0,0,2"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7">
                            <ContentPresenter x:Name="Content" Margin="{TemplateBinding Padding}" Opacity="0.54"
                                              HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Chrome" Property="Background" Value="{DynamicResource RaisedBrush}"/>
                                <Setter TargetName="Content" Property="Opacity" Value="1"/>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsMouseOver" Value="True"/>
                                    <Condition Property="IsChecked" Value="False"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="Content" Property="Opacity" Value="1"/>
                                <MultiTrigger.EnterActions>
                                    <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Content" Storyboard.TargetProperty="Opacity" From="0.54" To="1" Duration="0:0:0.14" FillBehavior="Stop"/></Storyboard></BeginStoryboard>
                                </MultiTrigger.EnterActions>
                            </MultiTrigger>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsMouseOver" Value="False"/>
                                    <Condition Property="IsChecked" Value="False"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="Content" Property="Opacity" Value="0.54"/>
                                <MultiTrigger.EnterActions>
                                    <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Content" Storyboard.TargetProperty="Opacity" From="1" To="0.54" Duration="0:0:0.14" FillBehavior="Stop"/></Storyboard></BeginStoryboard>
                                </MultiTrigger.EnterActions>
                            </MultiTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="CardCheckBoxStyle" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="{DynamicResource ControlBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="Padding" Value="14,11"/>
            <Setter Property="MinHeight" Value="62"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Border x:Name="Card" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10"/>
                            <Border x:Name="HoverOverlay" Background="{DynamicResource TextBrush}" CornerRadius="10" Opacity="0" IsHitTestVisible="False"/>
                            <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True"><Setter TargetName="Card" Property="Background" Value="{DynamicResource SelectedBrush}"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="HoverOverlay" Property="Opacity" Value="0.09"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Card" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0.16" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="PreferenceToggleStyle" TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="{DynamicResource ControlBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="Padding" Value="14,10"/>
            <Setter Property="MinHeight" Value="62"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid>
                            <Border x:Name="Card" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10"/>
                            <Border x:Name="HoverOverlay" Background="{DynamicResource TextBrush}" CornerRadius="10" Opacity="0" IsHitTestVisible="False"/>
                            <Grid Margin="{TemplateBinding Padding}">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
                                <ContentPresenter Grid.Column="0" VerticalAlignment="Center" Margin="0,0,14,0"/>
                                <Border x:Name="Track" Grid.Column="1" Width="40" Height="24" CornerRadius="12"
                                        Background="{DynamicResource RaisedBrush}" HorizontalAlignment="Right" VerticalAlignment="Center">
                                    <Ellipse x:Name="Thumb" Width="16" Height="16" Margin="4" HorizontalAlignment="Left" Fill="{DynamicResource MutedBrush}" RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform><TranslateTransform x:Name="ThumbTranslate" X="0"/></Ellipse.RenderTransform>
                                    </Ellipse>
                                </Border>
                            </Grid>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Card" Property="Background" Value="{DynamicResource SelectedBrush}"/>
                                <Setter TargetName="Track" Property="Background" Value="{DynamicResource TextBrush}"/>
                                <Setter TargetName="Thumb" Property="Fill" Value="{DynamicResource SurfaceBrush}"/>
                                <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ThumbTranslate" Storyboard.TargetProperty="X" To="16" Duration="0:0:0.14"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
                                <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="ThumbTranslate" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Card" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0.16" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ComboToggleStyle" TargetType="ToggleButton">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="{DynamicResource RaisedBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="Chrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10"/>
                            <Border x:Name="HoverOverlay" Background="{DynamicResource TextBrush}" CornerRadius="10" Opacity="0" IsHitTestVisible="False"/>
                            <Grid Margin="12,0,12,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="18"/></Grid.ColumnDefinitions>
                                <ContentPresenter Grid.Column="0" VerticalAlignment="Center" HorizontalAlignment="Left"
                                                  Content="{Binding SelectionBoxItem, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"
                                                  ContentTemplate="{Binding SelectionBoxItemTemplate, RelativeSource={RelativeSource AncestorType={x:Type ComboBox}}}"/>
                                <Path Grid.Column="1" Width="8" Height="5" Stretch="Fill" Fill="{DynamicResource MutedBrush}" HorizontalAlignment="Right" VerticalAlignment="Center"
                                      Data="M 0 0 L 4 4 L 8 0 Z"/>
                            </Grid>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Chrome" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0.16" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="Item" Background="{TemplateBinding Background}" CornerRadius="7" ClipToBounds="True">
                            <Grid>
                                <Border x:Name="HoverOverlay" Background="{DynamicResource ControlBrush}" CornerRadius="7" Opacity="0" IsHitTestVisible="False"/>
                                <ContentPresenter Margin="{TemplateBinding Padding}"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="Item" Property="Background" Value="{DynamicResource SelectedBrush}"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="{DynamicResource RaisedBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="MinWidth" Value="150"/>
            <Setter Property="Height" Value="42"/>
            <Setter Property="MaxDropDownHeight" Value="320"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton x:Name="ToggleButton" Style="{StaticResource ComboToggleStyle}" Focusable="False" ClickMode="Press"
                                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
                            <Popup x:Name="Popup" Placement="Bottom" AllowsTransparency="True" PopupAnimation="Fade" Focusable="False"
                                   IsOpen="{TemplateBinding IsDropDownOpen}">
                                <Border Margin="0,6,0,0" Padding="6" MinWidth="{Binding ActualWidth, ElementName=ToggleButton}" MaxHeight="{TemplateBinding MaxDropDownHeight}"
                                        Background="{DynamicResource PanelBrush}" CornerRadius="10" BorderBrush="{DynamicResource RaisedBrush}" BorderThickness="1">
                                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter TargetName="ToggleButton" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SystemAppButtonStyle" TargetType="Button">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="{DynamicResource ControlBrush}"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="2"/>
            <Setter Property="Padding" Value="14,11"/>
            <Setter Property="MinHeight" Value="62"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="Card" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10"/>
                            <Border x:Name="HoverOverlay" Background="{DynamicResource TextBrush}" CornerRadius="10" Opacity="0" IsHitTestVisible="False"/>
                            <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="HoverOverlay" Property="Opacity" Value="0.09"/></Trigger>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Card" Property="BorderBrush" Value="{DynamicResource FocusBrush}"/></Trigger>
                            <EventTrigger RoutedEvent="MouseEnter">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0.16" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                            <EventTrigger RoutedEvent="MouseLeave">
                                <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="HoverOverlay" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                            </EventTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>


        <!-- Minimal Mick's Tools scrollbar: native WPF behavior with themed chrome. -->
        <Style x:Key="ScrollTrackButtonStyle" TargetType="{x:Type RepeatButton}">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="IsTabStop" Value="False"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type RepeatButton}">
                        <Border Background="Transparent"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="VerticalScrollThumbStyle" TargetType="{x:Type Thumb}">
            <Setter Property="MinHeight" Value="48"/>
            <Setter Property="Background" Value="{DynamicResource ControlBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Grid Background="Transparent" SnapsToDevicePixels="True">
                            <Border x:Name="ThumbVisual" Margin="3,0" Background="{TemplateBinding Background}" CornerRadius="2"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThumbVisual" Property="Background" Value="{DynamicResource MutedBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="HorizontalScrollThumbStyle" TargetType="{x:Type Thumb}">
            <Setter Property="MinWidth" Value="48"/>
            <Setter Property="Background" Value="{DynamicResource ControlBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Grid Background="Transparent" SnapsToDevicePixels="True">
                            <Border x:Name="ThumbVisual" Margin="0,3" Background="{TemplateBinding Background}" CornerRadius="2"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="ThumbVisual" Property="Background" Value="{DynamicResource MutedBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Width" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Grid Background="Transparent" SnapsToDevicePixels="True">
                            <Track x:Name="PART_Track"
                                   Orientation="{TemplateBinding Orientation}"
                                   Minimum="{TemplateBinding Minimum}"
                                   Maximum="{TemplateBinding Maximum}"
                                   Value="{TemplateBinding Value}"
                                   ViewportSize="{TemplateBinding ViewportSize}"
                                   IsDirectionReversed="True"
                                   Focusable="False">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton x:Name="DecreaseButton" Style="{StaticResource ScrollTrackButtonStyle}" Command="{x:Static ScrollBar.PageUpCommand}"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb x:Name="ScrollThumb" Style="{StaticResource VerticalScrollThumbStyle}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton x:Name="IncreaseButton" Style="{StaticResource ScrollTrackButtonStyle}" Command="{x:Static ScrollBar.PageDownCommand}"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Orientation" Value="Horizontal">
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                                <Setter TargetName="DecreaseButton" Property="Command" Value="{x:Static ScrollBar.PageLeftCommand}"/>
                                <Setter TargetName="IncreaseButton" Property="Command" Value="{x:Static ScrollBar.PageRightCommand}"/>
                                <Setter TargetName="ScrollThumb" Property="Style" Value="{StaticResource HorizontalScrollThumbStyle}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="Height" Value="10"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- Overlay scrollbar: keeps the content viewport width unchanged when a bar appears. -->
        <Style x:Key="OverlayScrollViewerStyle" TargetType="{x:Type ScrollViewer}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollViewer}">
                        <Grid Background="{TemplateBinding Background}" SnapsToDevicePixels="True">
                            <ScrollContentPresenter x:Name="PART_ScrollContentPresenter"
                                                    Margin="{TemplateBinding Padding}"
                                                    Content="{TemplateBinding Content}"
                                                    ContentTemplate="{TemplateBinding ContentTemplate}"
                                                    ContentStringFormat="{TemplateBinding ContentStringFormat}"
                                                    CanContentScroll="{TemplateBinding CanContentScroll}"
                                                    KeyboardNavigation.DirectionalNavigation="Local"/>
                            <ScrollBar x:Name="PART_VerticalScrollBar"
                                       Panel.ZIndex="2"
                                       HorizontalAlignment="Right"
                                       VerticalAlignment="Stretch"
                                       Orientation="Vertical"
                                       Maximum="{TemplateBinding ScrollableHeight}"
                                       ViewportSize="{TemplateBinding ViewportHeight}"
                                       Value="{Binding VerticalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                                       Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
                            <ScrollBar x:Name="PART_HorizontalScrollBar"
                                       Panel.ZIndex="2"
                                       HorizontalAlignment="Stretch"
                                       VerticalAlignment="Bottom"
                                       Orientation="Horizontal"
                                       Maximum="{TemplateBinding ScrollableWidth}"
                                       ViewportSize="{TemplateBinding ViewportWidth}"
                                       Value="{Binding HorizontalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                                       Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid x:Name="RootGrid">
        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

        <Grid x:Name="AppGrid" Grid.Row="0" Margin="24,20,24,14" MaxWidth="1120" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

        <Grid x:Name="HeaderGrid" Grid.Row="0" Margin="4,0,4,20">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" VerticalAlignment="Bottom">
                <TextBlock Text="Mick's Tools" Foreground="{DynamicResource MutedBrush}" FontSize="14" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock x:Name="TitleText" Text="MT win tools" Foreground="{DynamicResource TextBrush}" FontSize="32" FontWeight="SemiBold"/>
            </StackPanel>
            <Button x:Name="AppearanceButton" Grid.Column="1" Style="{StaticResource AppearanceButtonStyle}" VerticalAlignment="Bottom" AutomationProperties.Name="Appearance"/>
        </Grid>

        <Border x:Name="MainShell" Grid.Row="1" MaxHeight="720" MinHeight="320" HorizontalAlignment="Stretch" VerticalAlignment="Stretch"
                Background="{DynamicResource SurfaceBrush}" CornerRadius="24" Padding="12">
            <Border.Effect><DropShadowEffect BlurRadius="48" ShadowDepth="18" Opacity="0.28" Color="#000000"/></Border.Effect>
            <Grid x:Name="ShellGrid">
                <Grid.ColumnDefinitions><ColumnDefinition Width="214"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="0"/><RowDefinition Height="0"/></Grid.RowDefinitions>

                <Border x:Name="RailPanel" Grid.Column="0" Grid.Row="0" Background="{DynamicResource PanelBrush}" CornerRadius="12" Padding="10">
                    <ScrollViewer x:Name="RailScroll" Style="{StaticResource OverlayScrollViewerStyle}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False">
                        <StackPanel x:Name="MainNavPanel">
                            <ToggleButton x:Name="NavCleanup" Content="Cleanup" Style="{StaticResource NavButtonStyle}" IsChecked="True"/>
                            <ToggleButton x:Name="NavTweaks" Style="{StaticResource NavButtonStyle}">
                                <Grid>
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <TextBlock Text="Tweaks" VerticalAlignment="Center"/>
                                    <TextBlock x:Name="TweaksExpandMark" Grid.Column="1" Text="+" Foreground="{DynamicResource SubtleBrush}" FontSize="18" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                </Grid>
                            </ToggleButton>
                            <Border x:Name="TweakSubmenu" Visibility="Collapsed" Margin="8,2,0,4" Padding="8,0,0,0"
                                    BorderBrush="{DynamicResource SelectedBrush}" BorderThickness="1,0,0,0">
                                <StackPanel x:Name="TweakSubmenuItems">
                                    <ToggleButton x:Name="NavTweakPrivacy" Content="Privacy" Style="{StaticResource SubmenuButtonStyle}" IsChecked="True"/>
                                    <ToggleButton x:Name="NavTweakDebloat" Content="Debloat" Style="{StaticResource SubmenuButtonStyle}"/>
                                    <ToggleButton x:Name="NavTweakExplorer" Content="Explorer" Style="{StaticResource SubmenuButtonStyle}"/>
                                    <ToggleButton x:Name="NavTweakPerformance" Content="Performance" Style="{StaticResource SubmenuButtonStyle}"/>
                                    <ToggleButton x:Name="NavTweakSystem" Content="System" Style="{StaticResource SubmenuButtonStyle}"/>
                                    <ToggleButton x:Name="NavTweakAppearance" Content="Appearance" Style="{StaticResource SubmenuButtonStyle}"/>
                                    <ToggleButton x:Name="NavTweakInput" Content="Input" Style="{StaticResource SubmenuButtonStyle}"/>
                                    <ToggleButton x:Name="NavTweakNetwork" Content="Network" Style="{StaticResource SubmenuButtonStyle}"/>
                                    <ToggleButton x:Name="NavTweakDevices" Content="Devices" Style="{StaticResource SubmenuButtonStyle}"/>
                                </StackPanel>
                            </Border>
                            <ToggleButton x:Name="NavSystemApps" Content="System Apps" Style="{StaticResource NavButtonStyle}"/>
                        </StackPanel>
                    </ScrollViewer>
                </Border>

                <Grid x:Name="WorkspaceHost" Grid.Column="2" Grid.Row="0">
                    <Border x:Name="CleanupPanel" Background="{DynamicResource PanelBrush}" CornerRadius="12">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/><RowDefinition Height="68"/></Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="{DynamicResource ToolbarBrush}" CornerRadius="12,12,0,0">
                                <Grid x:Name="CleanupHeaderGrid" Margin="20,0,18,0">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                                        <TextBlock Text="Cleanup" Foreground="{DynamicResource TextBrush}" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                        <TextBlock x:Name="CleanupSelectionText" Text="0 selected" Foreground="{DynamicResource SubtleBrush}" FontSize="13" Margin="10,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                        <Button x:Name="CleanupSelectAll" Content="Select all" Style="{StaticResource TextButtonStyle}"/>
                                        <Button x:Name="CleanupClear" Content="Clear" Style="{StaticResource TextButtonStyle}" Margin="2,0,0,0"/>
                                    </StackPanel>
                                </Grid>
                            </Border>
                            <ScrollViewer x:Name="CleanupScroll" Grid.Row="1" Style="{StaticResource OverlayScrollViewerStyle}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False" Padding="22,22,10,10">
                                <StackPanel x:Name="CleanupGrid"/>
                            </ScrollViewer>
                            <Border Grid.Row="2" Background="{DynamicResource ToolbarBrush}" CornerRadius="0,0,12,12">
                                <Grid x:Name="CleanupActionFrame" Margin="16,12,16,12">
                                    <Grid x:Name="CleanupActionPanel">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock x:Name="CleanupStatusText" Grid.Column="0" Text="" Foreground="{DynamicResource SubtleBrush}" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,14,0"/>
                                        <Button x:Name="RunCleanup" Grid.Column="1" Content="Run Cleanup" Style="{StaticResource PrimaryButtonStyle}" IsEnabled="False" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid x:Name="CleanupConfirmPanel" Visibility="Collapsed">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock x:Name="CleanupConfirmText" Grid.Column="0" Foreground="{DynamicResource SubtleBrush}" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,14,0"/>
                                        <Button x:Name="CleanupConfirmCancel" Grid.Column="1" Content="Cancel" Style="{StaticResource TextButtonStyle}" Margin="0,0,2,0"/>
                                        <Button x:Name="CleanupConfirmContinue" Grid.Column="2" Content="Continue" Style="{StaticResource PrimaryButtonStyle}"/>
                                    </Grid>
                                </Grid>
                            </Border>
                        </Grid>
                    </Border>

                    <Border x:Name="TweaksPanel" Background="{DynamicResource PanelBrush}" CornerRadius="12" Visibility="Collapsed">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/><RowDefinition Height="68"/></Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="{DynamicResource ToolbarBrush}" CornerRadius="12,12,0,0">
                                <Grid x:Name="TweaksHeaderGrid" Margin="20,0,18,0">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                                        <TextBlock x:Name="TweaksPanelTitle" Text="Privacy" Foreground="{DynamicResource TextBrush}" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
                                        <TextBlock x:Name="TweaksSelectionText" Text="0 selected" Foreground="{DynamicResource SubtleBrush}" FontSize="13" Margin="10,0,0,0" VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                        <Button x:Name="TweaksSelectAll" Content="Select all" Style="{StaticResource TextButtonStyle}"/>
                                        <Button x:Name="TweaksClear" Content="Reset" Style="{StaticResource TextButtonStyle}" Margin="2,0,0,0"/>
                                    </StackPanel>
                                </Grid>
                            </Border>
                            <ScrollViewer x:Name="TweaksScroll" Grid.Row="1" Style="{StaticResource OverlayScrollViewerStyle}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False" Padding="22,22,10,10">
                                <StackPanel>
                                    <StackPanel x:Name="TweakPrivacyGrid"/>
                                    <StackPanel x:Name="TweakDebloatGrid" Visibility="Collapsed"/>
                                    <StackPanel x:Name="TweakExplorerGrid" Visibility="Collapsed"/>
                                    <StackPanel x:Name="TweakPerformanceGrid" Visibility="Collapsed"/>
                                    <StackPanel x:Name="TweakSystemGrid" Visibility="Collapsed"/>
                                    <StackPanel x:Name="TweakAppearanceGrid" Visibility="Collapsed"/>
                                    <StackPanel x:Name="TweakInputGrid" Visibility="Collapsed"/>
                                    <StackPanel x:Name="TweakNetworkGrid" Visibility="Collapsed"/>
                                    <StackPanel x:Name="TweakDevicesGrid" Visibility="Collapsed"/>
                                </StackPanel>
                            </ScrollViewer>
                            <Border Grid.Row="2" Background="{DynamicResource ToolbarBrush}" CornerRadius="0,0,12,12">
                                <Grid x:Name="TweaksActionFrame" Margin="16,12,16,12">
                                    <Grid x:Name="TweaksActionPanel">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock x:Name="TweaksStatusText" Grid.Column="0" Text="" Foreground="{DynamicResource SubtleBrush}" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,14,0"/>
                                        <Button x:Name="RunTweaks" Grid.Column="1" Content="Run Tweaks" Style="{StaticResource PrimaryButtonStyle}" IsEnabled="False" VerticalAlignment="Center"/>
                                    </Grid>
                                    <Grid x:Name="TweaksConfirmPanel" Visibility="Collapsed">
                                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                        <TextBlock x:Name="TweaksConfirmText" Grid.Column="0" Foreground="{DynamicResource SubtleBrush}" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,14,0"/>
                                        <Button x:Name="TweaksConfirmCancel" Grid.Column="1" Content="Cancel" Style="{StaticResource TextButtonStyle}" Margin="0,0,2,0"/>
                                        <Button x:Name="TweaksConfirmContinue" Grid.Column="2" Content="Continue" Style="{StaticResource PrimaryButtonStyle}"/>
                                    </Grid>
                                </Grid>
                            </Border>
                        </Grid>
                    </Border>

                    <Border x:Name="SystemAppsPanel" Background="{DynamicResource PanelBrush}" CornerRadius="12" Visibility="Collapsed">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="52"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="{DynamicResource ToolbarBrush}" CornerRadius="12,12,0,0">
                                <TextBlock x:Name="SystemAppsHeaderText" Text="System Apps" Foreground="{DynamicResource TextBrush}" FontSize="15" FontWeight="SemiBold" Margin="20,0" VerticalAlignment="Center"/>
                            </Border>
                            <ScrollViewer x:Name="SystemAppsScroll" Grid.Row="1" Style="{StaticResource OverlayScrollViewerStyle}" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False" Padding="22,22,10,10">
                                <StackPanel x:Name="SystemAppsGrid"/>
                            </ScrollViewer>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>
        </Border>

        <TextBlock x:Name="LocalNote" Grid.Row="2" Text="Review selections before running. Explorer, sign-in, or a restart may be needed to finish selected changes."
                   Foreground="{DynamicResource SubtleBrush}" FontSize="13" TextWrapping="Wrap" TextAlignment="Center" Margin="12,14,12,0"/>
        </Grid>

        <TextBlock x:Name="SiteCredit" Grid.Row="1" HorizontalAlignment="Center" Foreground="{DynamicResource SubtleBrush}" FontSize="13" Margin="0,12,0,14">
            <Run Text="&#169; 2026 micknorj &#183; Mick's Tools &#183; "/><Hyperlink x:Name="GitHubLink" NavigateUri="https://github.com/micknorj" Foreground="{DynamicResource MutedBrush}" FontWeight="SemiBold" TextDecorations="{x:Null}">GitHub</Hyperlink>
        </TextBlock>
    </Grid>
</Window>
'@

$reader = [Xml.XmlNodeReader]::new($xaml)
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
}
finally {
    $reader.Close()
}

$controlNames = @(
    'RootGrid', 'AppGrid', 'HeaderGrid', 'TitleText', 'AppearanceButton', 'MainShell', 'ShellGrid', 'RailPanel', 'RailScroll', 'MainNavPanel',
    'NavCleanup', 'NavTweaks', 'TweaksExpandMark', 'TweakSubmenu', 'TweakSubmenuItems', 'NavTweakPrivacy', 'NavTweakDebloat', 'NavTweakExplorer',
    'NavTweakPerformance', 'NavTweakSystem', 'NavTweakAppearance', 'NavTweakInput', 'NavTweakNetwork', 'NavTweakDevices', 'NavSystemApps',
    'WorkspaceHost', 'CleanupPanel', 'TweaksPanel', 'SystemAppsPanel', 'CleanupGrid', 'SystemAppsGrid', 'CleanupHeaderGrid', 'TweaksHeaderGrid', 'SystemAppsHeaderText',
    'TweakPrivacyGrid', 'TweakDebloatGrid', 'TweakExplorerGrid', 'TweakPerformanceGrid', 'TweakSystemGrid', 'TweakAppearanceGrid',
    'TweakInputGrid', 'TweakNetworkGrid', 'TweakDevicesGrid', 'TweaksPanelTitle', 'CleanupSelectionText', 'TweaksSelectionText',
    'CleanupScroll', 'TweaksScroll', 'SystemAppsScroll', 'CleanupStatusText', 'TweaksStatusText', 'CleanupSelectAll', 'CleanupClear', 'RunCleanup',
    'CleanupActionFrame', 'CleanupActionPanel', 'CleanupConfirmPanel', 'CleanupConfirmText', 'CleanupConfirmCancel', 'CleanupConfirmContinue',
    'TweaksSelectAll', 'TweaksClear', 'RunTweaks', 'TweaksActionFrame', 'TweaksActionPanel', 'TweaksConfirmPanel', 'TweaksConfirmText', 'TweaksConfirmCancel', 'TweaksConfirmContinue',
    'LocalNote', 'SiteCredit', 'GitHubLink'
)
foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value $window.FindName($name) -Scope Script
}

function New-MTWinBrush {
    param([Parameter(Mandatory = $true)][string]$Color)
    return [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($Color))
}

function Get-MTWinSystemUsesLightTheme {
    try {
        $path = Resolve-MTWinRegistryPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        return ((Get-ItemPropertyValue -Path $path -Name AppsUseLightTheme -ErrorAction Stop) -ne 0)
    }
    catch {
        return $false
    }
}

function Set-MTWinTitleBarTheme {
    param([bool]$Dark)

    try {
        if (-not ('MTWinTools.NativeMethods' -as [type])) { return }
        $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        if ($handle -eq [IntPtr]::Zero) { return }
        $value = if ($Dark) { 1 } else { 0 }
        $result = [MTWinTools.NativeMethods]::DwmSetWindowAttribute($handle, 20, [ref]$value, 4)
        if ($result -ne 0) {
            [void][MTWinTools.NativeMethods]::DwmSetWindowAttribute($handle, 19, [ref]$value, 4)
        }
    }
    catch {
    }
}

function Set-MTWinAppearance {
    param(
        [ValidateSet('System', 'Light', 'Dark')][string]$Mode,
        [bool]$Animate = $true
    )

    $script:AppearanceMode = $Mode
    $light = if ($Mode -eq 'System') { Get-MTWinSystemUsesLightTheme } else { $Mode -eq 'Light' }
    $script:CurrentLightTheme = $light

    if ($light) {
        $colors = @{
            PageBrush='#eef0ee'; SurfaceBrush='#f8f9f7'; PanelBrush='#ecefeb'; RaisedBrush='#e1e5e1';
            ControlBrush='#d9ded9'; SelectedBrush='#cbd2cc'; TextBrush='#222725'; MutedBrush='#525c57';
            SubtleBrush='#6f7974'; FocusBrush='#332a503d'; ToolbarBrush='#e6eae6'; WarningBrush='#7d642f'
        }
    }
    else {
        $colors = @{
            PageBrush='#0b0d0f'; SurfaceBrush='#14171a'; PanelBrush='#1a1e22'; RaisedBrush='#22272d';
            ControlBrush='#272d34'; SelectedBrush='#343c45'; TextBrush='#f4f6f8'; MutedBrush='#b7bec6';
            SubtleBrush='#8f98a2'; FocusBrush='#47b5cde6'; ToolbarBrush='#1e2328'; WarningBrush='#e2c17d'
        }
    }

    # Never mutate a brush already resolved through DynamicResource: WPF may
    # freeze it. For an animated switch, create a fresh brush whose base value
    # is already the target color, animate from the currently rendered color,
    # then let FillBehavior=Stop reveal the target base value at completion.
    foreach ($key in $colors.Keys) {
        $targetColor = [Windows.Media.ColorConverter]::ConvertFromString($colors[$key])
        $current = $window.TryFindResource($key)
        $startColor = $targetColor
        if ($Animate -and $current -is [Windows.Media.SolidColorBrush]) {
            $startColor = $current.Color
        }

        $brush = [Windows.Media.SolidColorBrush]::new($targetColor)
        if ($Animate -and $startColor -ne $targetColor) {
            $animation = [Windows.Media.Animation.ColorAnimation]::new()
            $animation.From = $startColor
            $animation.To = $targetColor
            $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(140))
            $animation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
            $animation.EasingFunction = [Windows.Media.Animation.CubicEase]::new()
            $brush.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $animation)
        }
        $window.Resources[$key] = $brush
    }

    $targetShadowOpacity = if ($light) { 0.12 } else { 0.28 }
    $startShadowOpacity = $targetShadowOpacity
    if ($Animate -and $MainShell.Effect -is [Windows.Media.Effects.DropShadowEffect]) {
        $startShadowOpacity = $MainShell.Effect.Opacity
    }

    $shadow = New-Object Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 48
    $shadow.ShadowDepth = 18
    $shadow.Opacity = $targetShadowOpacity
    $shadow.Color = [Windows.Media.Colors]::Black
    if ($Animate -and $startShadowOpacity -ne $targetShadowOpacity) {
        $shadowAnimation = [Windows.Media.Animation.DoubleAnimation]::new()
        $shadowAnimation.From = $startShadowOpacity
        $shadowAnimation.To = $targetShadowOpacity
        $shadowAnimation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(140))
        $shadowAnimation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
        $shadowAnimation.EasingFunction = [Windows.Media.Animation.CubicEase]::new()
        $shadow.BeginAnimation([Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $shadowAnimation)
    }
    $MainShell.Effect = $shadow

    $separator = [char]183
    $AppearanceButton.Content = "Appearance $separator $Mode"
    [Windows.Automation.AutomationProperties]::SetName($AppearanceButton, "Appearance: $Mode")

    # DWM caption theming has no interpolated API; it changes discretely while
    # the WPF client colors animate.
    Set-MTWinTitleBarTheme -Dark (-not $light)
}

function New-MTWinSectionHeading {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][Windows.Controls.StackPanel]$Grid
    )

    $heading = New-Object Windows.Controls.TextBlock
    $heading.Text = $Text
    $heading.FontSize = 17
    $heading.FontWeight = [Windows.FontWeights]::SemiBold
    $heading.Margin = if ($Grid.Children.Count -eq 0) { '0,0,0,14' } else { '0,14,0,14' }
    $heading.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
    $Grid.Children.Add($heading) | Out-Null
}

function New-MTWinCardContent {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Risk = $false
    )

    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $Name
    $title.FontSize = 15
    $title.FontWeight = [Windows.FontWeights]::Medium
    $title.LineHeight = 20
    $title.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
    $title.TextWrapping = 'Wrap'
    $title.VerticalAlignment = 'Center'

    if (-not $Risk) { return $title }

    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))

    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 7
    $dot.Height = 7
    $dot.Margin = '0,0,9,0'
    $dot.VerticalAlignment = 'Center'
    $dot.SetResourceReference([Windows.Shapes.Shape]::FillProperty, 'WarningBrush')
    $grid.Children.Add($dot) | Out-Null

    [Windows.Controls.Grid]::SetColumn($title, 1)
    $grid.Children.Add($title) | Out-Null
    return $grid
}

function New-MTWinSystemAppContent {
    param([Parameter(Mandatory = $true)][string]$Name)

    $grid = New-Object Windows.Controls.Grid
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
    $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='Auto' }))

    $title = New-Object Windows.Controls.TextBlock
    $title.Text = $Name
    $title.FontSize = 15
    $title.FontWeight = [Windows.FontWeights]::Medium
    $title.TextWrapping = 'Wrap'
    $title.VerticalAlignment = 'Center'
    $title.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextBrush')
    $grid.Children.Add($title) | Out-Null

    $mark = New-Object Windows.Shapes.Path
    $mark.Data = [Windows.Media.Geometry]::Parse('M 1,7 L 7,1 M 3,1 L 7,1 L 7,5')
    $mark.Width = 10
    $mark.Height = 10
    $mark.Stretch = 'Uniform'
    $mark.StrokeThickness = 1.5
    $mark.Margin = '12,0,1,0'
    $mark.VerticalAlignment = 'Center'
    $mark.SetResourceReference([Windows.Shapes.Shape]::StrokeProperty, 'SubtleBrush')
    [Windows.Controls.Grid]::SetColumn($mark, 1)
    $grid.Children.Add($mark) | Out-Null
    return $grid
}

function Add-MTWinSelectionCards {
    param(
        [Parameter(Mandatory = $true)][Windows.Controls.StackPanel]$Grid,
        [Parameter(Mandatory = $true)][Windows.Controls.ScrollViewer]$Scroll,
        [Parameter(Mandatory = $true)][object[]]$Definitions,
        [Parameter(Mandatory = $true)][hashtable]$ControlMap
    )

    $currentCategory = $null
    $wrap = $null
    foreach ($definition in $Definitions) {
        if ($definition.Category -ne $currentCategory) {
            $currentCategory = $definition.Category
            New-MTWinSectionHeading -Text $currentCategory -Grid $Grid
            $wrap = New-Object Windows.Controls.WrapPanel
            $Grid.Children.Add($wrap) | Out-Null
        }

        $checkBox = New-Object Windows.Controls.CheckBox
        $checkBox.Style = $window.FindResource('CardCheckBoxStyle')
        $checkBox.Tag = $definition.Id
        $checkBox.Content = New-MTWinCardContent -Name $definition.Name -Risk ([bool]$definition.Risk)
        $checkBox.Margin = '0,0,10,10'
        $wrap.Children.Add($checkBox) | Out-Null
        $ControlMap[$definition.Id] = $checkBox
        $script:ResponsiveCards.Add([pscustomobject]@{ Control=$checkBox; Scroll=$Scroll }) | Out-Null
    }
}

function Add-MTWinPreferenceCards {
    param(
        [Parameter(Mandatory = $true)][Windows.Controls.StackPanel]$Grid,
        [Parameter(Mandatory = $true)][Windows.Controls.ScrollViewer]$Scroll,
        [Parameter(Mandatory = $true)][object[]]$Definitions
    )

    $currentCategory = $null
    $wrap = $null
    foreach ($definition in $Definitions) {
        if ($definition.Category -ne $currentCategory) {
            $currentCategory = $definition.Category
            New-MTWinSectionHeading -Text $currentCategory -Grid $Grid
            $wrap = New-Object Windows.Controls.WrapPanel
            $Grid.Children.Add($wrap) | Out-Null
        }

        $toggle = New-Object Windows.Controls.CheckBox
        $toggle.Style = $window.FindResource('PreferenceToggleStyle')
        $toggle.Tag = $definition.Id
        $toggle.Content = New-MTWinCardContent -Name $definition.Name
        $toggle.Margin = '0,0,10,10'
        $toggle.IsChecked = [bool](Get-MTWinPreferenceState $definition.Id)
        $script:PreferenceInitial[$definition.Id] = [bool]$toggle.IsChecked
        $script:PreferenceControls[$definition.Id] = $toggle
        $wrap.Children.Add($toggle) | Out-Null
        $script:ResponsiveCards.Add([pscustomobject]@{ Control=$toggle; Scroll=$Scroll }) | Out-Null
    }
}

function Add-MTWinChoiceRows {
    param(
        [Parameter(Mandatory = $true)][Windows.Controls.StackPanel]$Grid,
        [Parameter(Mandatory = $true)][Windows.Controls.ScrollViewer]$Scroll,
        [Parameter(Mandatory = $true)][object[]]$Definitions,
        [string]$SectionName = 'Network and graphics'
    )

    New-MTWinSectionHeading -Text $SectionName -Grid $Grid
    $wrap = New-Object Windows.Controls.WrapPanel
    $Grid.Children.Add($wrap) | Out-Null

    foreach ($definition in $Definitions) {
        $border = New-Object Windows.Controls.Border
        $border.MinHeight = 68
        $border.CornerRadius = 10
        $border.Padding = 14
        $border.Margin = '0,0,10,10'
        $border.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'ControlBrush')

        $row = New-Object Windows.Controls.Grid
        $row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='*' }))
        $row.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width='190' }))
        $row.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height='Auto' }))
        $row.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height='0' }))
        $label = New-MTWinCardContent -Name $definition.Name
        $row.Children.Add($label) | Out-Null

        $combo = New-Object Windows.Controls.ComboBox
        $combo.Tag = $definition.Id
        foreach ($option in $definition.Options) { [void]$combo.Items.Add($option) }
        $combo.SelectedIndex = 0
        $combo.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($combo, 1)
        $row.Children.Add($combo) | Out-Null
        $border.Child = $row
        $wrap.Children.Add($border) | Out-Null
        $script:ChoiceControls[$definition.Id] = $combo
        $script:ChoiceLayouts.Add([pscustomobject]@{ Border=$border; Grid=$row; Combo=$combo }) | Out-Null
        $script:ResponsiveCards.Add([pscustomobject]@{ Control=$border; Scroll=$Scroll; MaxColumns=2 }) | Out-Null
    }
}

function Add-MTWinSystemAppCards {
    param(
        [Parameter(Mandatory = $true)][Windows.Controls.StackPanel]$Grid,
        [Parameter(Mandatory = $true)][Windows.Controls.ScrollViewer]$Scroll
    )

    $currentCategory = $null
    $wrap = $null
    foreach ($definition in $systemAppDefinitions) {
        if ($definition.Category -ne $currentCategory) {
            $currentCategory = $definition.Category
            New-MTWinSectionHeading -Text $currentCategory -Grid $Grid
            $wrap = New-Object Windows.Controls.WrapPanel
            $Grid.Children.Add($wrap) | Out-Null
        }

        $button = New-Object Windows.Controls.Button
        $button.Style = $window.FindResource('SystemAppButtonStyle')
        $button.Tag = $definition
        $button.Content = New-MTWinSystemAppContent -Name $definition.Name
        $button.Margin = '0,0,10,10'
        $button.Add_Click({
            $sender = $args[0]
            Start-MTWinSystemApp -Definition $sender.Tag
        })
        $wrap.Children.Add($button) | Out-Null
        $script:ResponsiveCards.Add([pscustomobject]@{ Control=$button; Scroll=$Scroll }) | Out-Null
    }
}

function Resize-MTWinCards {
    foreach ($item in $script:ResponsiveCards) {
        $available = $item.Scroll.ViewportWidth
        if ($available -le 0) { $available = $item.Scroll.ActualWidth - 32 }
        $maxColumns = if ($null -ne $item.PSObject.Properties['MaxColumns']) { [int]$item.MaxColumns } else { 3 }

        if ($maxColumns -le 2) {
            if ($available -ge 520) { $width = [Math]::Floor(($available - 20) / 2) }
            else { $width = [Math]::Max(220, $available - 10) }
        }
        else {
            if ($available -ge 780) { $width = [Math]::Floor(($available - 30) / 3) }
            elseif ($available -ge 520) { $width = [Math]::Floor(($available - 20) / 2) }
            else { $width = [Math]::Max(220, $available - 10) }
        }
        $item.Control.Width = $width
    }
}

function Set-MTWinCompactNavigation {
    param([bool]$Compact)

    if ($Compact) {
        $ShellGrid.ColumnDefinitions[0].Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $ShellGrid.ColumnDefinitions[1].Width = [Windows.GridLength]::new(0)
        $ShellGrid.ColumnDefinitions[2].Width = [Windows.GridLength]::new(0)
        $ShellGrid.RowDefinitions[0].Height = [Windows.GridLength]::Auto
        $ShellGrid.RowDefinitions[1].Height = [Windows.GridLength]::new(8)
        $ShellGrid.RowDefinitions[2].Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        [Windows.Controls.Grid]::SetColumn($RailPanel, 0)
        [Windows.Controls.Grid]::SetRow($RailPanel, 0)
        [Windows.Controls.Grid]::SetColumn($WorkspaceHost, 0)
        [Windows.Controls.Grid]::SetRow($WorkspaceHost, 2)
        $RailPanel.Padding = '8'
        $RailScroll.VerticalScrollBarVisibility = 'Disabled'
        $RailScroll.HorizontalScrollBarVisibility = 'Hidden'
        $RailScroll.PanningMode = 'HorizontalOnly'
        $MainNavPanel.Orientation = 'Horizontal'
        $TweakSubmenuItems.Orientation = 'Horizontal'
        $TweakSubmenu.Margin = '0'
        $TweakSubmenu.Padding = '0'
        $TweakSubmenu.BorderThickness = '0'
        $TweaksExpandMark.Visibility = 'Collapsed'
        foreach ($control in $script:PrimaryNavControls) { $control.Margin = '0,0,4,0' }
        foreach ($control in $script:TweakNavControls.Values) {
            $control.Margin = '0,0,4,0'
            $control.HorizontalContentAlignment = 'Center'
        }
    }
    else {
        $ShellGrid.ColumnDefinitions[0].Width = [Windows.GridLength]::new(214)
        $ShellGrid.ColumnDefinitions[1].Width = [Windows.GridLength]::new(12)
        $ShellGrid.ColumnDefinitions[2].Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $ShellGrid.RowDefinitions[0].Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $ShellGrid.RowDefinitions[1].Height = [Windows.GridLength]::new(0)
        $ShellGrid.RowDefinitions[2].Height = [Windows.GridLength]::new(0)
        [Windows.Controls.Grid]::SetColumn($RailPanel, 0)
        [Windows.Controls.Grid]::SetRow($RailPanel, 0)
        [Windows.Controls.Grid]::SetColumn($WorkspaceHost, 2)
        [Windows.Controls.Grid]::SetRow($WorkspaceHost, 0)
        $RailPanel.Padding = '10'
        $RailScroll.VerticalScrollBarVisibility = 'Auto'
        $RailScroll.HorizontalScrollBarVisibility = 'Disabled'
        $RailScroll.PanningMode = 'VerticalOnly'
        $MainNavPanel.Orientation = 'Vertical'
        $TweakSubmenuItems.Orientation = 'Vertical'
        $TweakSubmenu.Margin = '8,2,0,4'
        $TweakSubmenu.Padding = '8,0,0,0'
        $TweakSubmenu.BorderThickness = '1,0,0,0'
        $TweaksExpandMark.Visibility = 'Visible'
        foreach ($control in $script:PrimaryNavControls) { $control.Margin = '0,0,0,4' }
        foreach ($control in $script:TweakNavControls.Values) {
            $control.Margin = '0,0,0,2'
            $control.HorizontalContentAlignment = 'Left'
        }
    }
}

function Update-MTWinResponsiveLayout {
    # RootGrid is the actual WPF client area. Window.ActualWidth includes the
    # native resize frame, so responsive sizing is based on the drawable area.
    $clientWidth = $RootGrid.ActualWidth
    $clientHeight = $RootGrid.ActualHeight
    if ($clientWidth -le 0 -or $clientHeight -le 0) { return }

    $compact = ($clientWidth -le 980)
    $narrow = ($clientWidth -le 720)

    # Size against the real client area rather than the outer native Window.
    # Keep only the desktop and compact responsive layouts.
    $pageHorizontalMargin = if ($compact) { 16.0 } else { 24.0 }
    $availableWidth = [Math]::Max(600.0, $clientWidth - ($pageHorizontalMargin * 2.0))
    $AppGrid.Width = [Math]::Min(1120.0, $availableWidth)
    $AppGrid.HorizontalAlignment = 'Center'
    $AppGrid.VerticalAlignment = if ($compact) { 'Top' } else { 'Center' }

    if ($compact -ne $script:IsCompactNavigation) {
        $script:IsCompactNavigation = $compact
        Set-MTWinCompactNavigation -Compact $compact
    }

    # The web prototype stacks choice controls at 720px and below.
    foreach ($layout in $script:ChoiceLayouts) {
        if ($narrow) {
            $layout.Grid.ColumnDefinitions[0].Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $layout.Grid.ColumnDefinitions[1].Width = [Windows.GridLength]::new(0)
            $layout.Grid.RowDefinitions[1].Height = [Windows.GridLength]::Auto
            [Windows.Controls.Grid]::SetColumn($layout.Combo, 0)
            [Windows.Controls.Grid]::SetRow($layout.Combo, 1)
            [Windows.Controls.Grid]::SetColumnSpan($layout.Combo, 2)
            $layout.Combo.Margin = '0,10,0,0'
            $layout.Combo.HorizontalAlignment = 'Stretch'
            $layout.Border.MinHeight = 112
        }
        else {
            $layout.Grid.ColumnDefinitions[0].Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
            $layout.Grid.ColumnDefinitions[1].Width = [Windows.GridLength]::new(190)
            $layout.Grid.RowDefinitions[1].Height = [Windows.GridLength]::new(0)
            [Windows.Controls.Grid]::SetColumn($layout.Combo, 1)
            [Windows.Controls.Grid]::SetRow($layout.Combo, 0)
            [Windows.Controls.Grid]::SetColumnSpan($layout.Combo, 1)
            $layout.Combo.Margin = '0'
            $layout.Combo.HorizontalAlignment = 'Stretch'
            $layout.Border.MinHeight = 68
        }
    }

    # Give the app block an exact height inside RootGrid's usable client row.
    # Header and disclaimer use Auto rows; the shell owns the remaining star row.
    # This prevents either text row from being clipped when the window is restored.
    $rootAppRowHeight = $RootGrid.RowDefinitions[0].ActualHeight
    if ($rootAppRowHeight -le 0) { $rootAppRowHeight = $clientHeight }
    $availableAppHeight = [Math]::Max(0.0, $rootAppRowHeight - 34.0) # AppGrid top + bottom margins.
    $AppGrid.Height = [Math]::Min(826.0, $availableAppHeight)
    $MainShell.MinHeight = 320.0
    $MainShell.Height = [double]::NaN

        $AppGrid.Margin = if ($compact) { '16,20,16,14' } else { '24,20,24,14' }
        $HeaderGrid.Margin = '4,0,4,20'
        $MainShell.Padding = '12'
        $CleanupHeaderGrid.Margin = '20,0,18,0'
        $TweaksHeaderGrid.Margin = '20,0,18,0'
        $SystemAppsHeaderText.Margin = '20,0'
        $CleanupScroll.Padding = '22,22,10,10'
        $TweaksScroll.Padding = '22,22,10,10'
        $SystemAppsScroll.Padding = '22,22,10,10'
        $CleanupActionFrame.Margin = '16,12,16,12'
        $TweaksActionFrame.Margin = '16,12,16,12'
        $LocalNote.Margin = '12,14,12,0'
        $SiteCredit.Margin = '0,28,0,14'
        $TitleText.FontSize = 32
        $AppearanceButton.Height = 40
        $AppearanceButton.Padding = '14,0'
        $AppearanceButton.FontSize = 14
        $AppearanceButton.MinWidth = 154
        $CleanupSelectAll.Padding = '9,0'
        $CleanupClear.Padding = '9,0'
        $TweaksSelectAll.Padding = '9,0'
        $TweaksClear.Padding = '9,0'
        foreach ($control in $script:PrimaryNavControls) {
            $control.MinHeight = 46
            $control.Padding = '12,0'
        }
        foreach ($control in $script:TweakNavControls.Values) {
            $control.MinHeight = 34
            $control.Padding = '10,0'
        }

    $window.Dispatcher.BeginInvoke([action]{ Resize-MTWinCards }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

function Get-MTWinSelectedIds {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ControlMap,
        [Parameter(Mandatory = $true)][object[]]$Definitions
    )

    return @(
        foreach ($definition in $Definitions) {
            $control = $ControlMap[[string]$definition.Id]
            if ($null -ne $control -and $control.IsChecked -eq $true) { [string]$definition.Id }
        }
    )
}

function Get-MTWinQueuedTweakIds {
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($id in @(Get-MTWinSelectedIds $script:TweakControls $tweakDefinitions)) { $ids.Add($id) }
    foreach ($definition in $preferenceDefinitions) {
        if ($script:PreferenceDirty.ContainsKey($definition.Id)) {
            $value = if ($script:PreferenceControls[$definition.Id].IsChecked -eq $true) { '1' } else { '0' }
            $ids.Add(('Preference|' + $definition.Id + '|' + $value))
        }
    }
    foreach ($definition in $choiceDefinitions) {
        $control = $script:ChoiceControls[$definition.Id]
        if ($control.SelectedIndex -gt 0) { $ids.Add(('Choice|' + $definition.Id + '|' + [string]$control.SelectedItem)) }
    }
    return @($ids)
}

function Get-MTWinVisibleTweakActionControls {
    $categories = @($script:TweakViewMap[$script:CurrentTweakView].Actions)
    return @(
        foreach ($definition in $tweakDefinitions) {
            if ($categories -contains $definition.Category) { $script:TweakControls[$definition.Id] }
        }
    )
}

function Update-MTWinSelectAllLabels {
    $cleanupControls = @($script:CleanupControls.Values)
    $cleanupAll = ($cleanupControls.Count -gt 0 -and @($cleanupControls | Where-Object { $_.IsChecked -ne $true }).Count -eq 0)
    $CleanupSelectAll.Content = if ($cleanupAll) { 'Deselect all' } else { 'Select all' }

    $visible = @(Get-MTWinVisibleTweakActionControls)
    $tweaksAll = ($visible.Count -gt 0 -and @($visible | Where-Object { $_.IsChecked -ne $true }).Count -eq 0)
    $TweaksSelectAll.Content = if ($tweaksAll) { 'Deselect all' } else { 'Select all' }
    $TweaksSelectAll.Visibility = if ($visible.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $TweaksSelectAll.IsEnabled = ($visible.Count -gt 0 -and $null -eq $script:ActiveJob)
}

function Update-MTWinSelectionState {
    if ($null -ne $script:PendingConfirmation) { Clear-MTWinInlineConfirmation }
    $cleanupCount = @(Get-MTWinSelectedIds $script:CleanupControls $cleanupDefinitions).Count
    $tweakCount = @(Get-MTWinQueuedTweakIds).Count
    $CleanupSelectionText.Text = "$cleanupCount selected"
    $TweaksSelectionText.Text = "$tweakCount selected"
    # Built-in Disk Cleanup is the baseline cleanup and always runs last.
    $RunCleanup.IsEnabled = ($null -eq $script:ActiveJob)
    $RunTweaks.IsEnabled = ($tweakCount -gt 0 -and $null -eq $script:ActiveJob)
    Update-MTWinSelectAllLabels
}

function Set-MTWinBusy {
    param([bool]$Busy)
    $MainShell.IsHitTestVisible = -not $Busy
}

function Clear-MTWinInlineConfirmation {
    $script:PendingConfirmation = $null
    $CleanupConfirmPanel.Visibility = 'Collapsed'
    $TweaksConfirmPanel.Visibility = 'Collapsed'
    $CleanupActionPanel.Visibility = 'Visible'
    $TweaksActionPanel.Visibility = 'Visible'
}

function Show-MTWinInlineConfirmation {
    param(
        [ValidateSet('Cleanup', 'Tweaks')][string]$Kind,
        [Parameter(Mandatory = $true)][string[]]$Ids,
        [Parameter(Mandatory = $true)][int]$RiskCount
    )

    Clear-MTWinInlineConfirmation
    $script:PendingConfirmation = [pscustomobject]@{ Kind=$Kind; Ids=@($Ids) }
    $noun = if ($RiskCount -eq 1) { 'action' } else { 'actions' }

    if ($Kind -eq 'Cleanup') {
        $CleanupConfirmText.Text = "$RiskCount risky cleanup $noun may not be reversible. Continue?"
        $CleanupActionPanel.Visibility = 'Collapsed'
        $CleanupConfirmPanel.Visibility = 'Visible'
    }
    else {
        $TweaksConfirmText.Text = "$RiskCount risky tweak $noun can remove software, protection, or system features. Continue?"
        $TweaksActionPanel.Visibility = 'Collapsed'
        $TweaksConfirmPanel.Visibility = 'Visible'
    }
}

function Start-MTWinUiOperation {
    param(
        [ValidateSet('Cleanup', 'Tweaks')][string]$Kind,
        [Parameter(Mandatory = $true)][string[]]$Ids
    )

    Clear-MTWinInlineConfirmation
    Set-MTWinBusy $true
    $selectionText = if ($Kind -eq 'Cleanup') { $CleanupSelectionText } else { $TweaksSelectionText }
    $statusText = if ($Kind -eq 'Cleanup') { $CleanupStatusText } else { $TweaksStatusText }
    $selectionText.Text = 'Running...'
    $statusText.Text = if ($Kind -eq 'Cleanup') { "Running | $($Ids.Count) operations" } else { "Running | $($Ids.Count) selected" }

    try {
        Start-MTWinOperationJob -Kind $Kind -Ids $Ids
        $script:JobTimer.Start()
    }
    catch {
        Set-MTWinBusy $false
        Write-MTWinStatus -Message $_.Exception.Message -Level Error
        $statusText.Text = 'Could not start | ' + $_.Exception.Message
        Update-MTWinSelectionState
    }
}

function Show-MTWinElementFade {
    param([Parameter(Mandatory = $true)][Windows.UIElement]$Element)

    $Element.Opacity = 1
    $Element.Visibility = 'Visible'
    $animation = [Windows.Media.Animation.DoubleAnimation]::new()
    $animation.From = 0
    $animation.To = 1
    $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(140))
    $animation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
    $animation.EasingFunction = [Windows.Media.Animation.CubicEase]::new()
    $Element.BeginAnimation([Windows.UIElement]::OpacityProperty, $animation)
}

function Set-MTWinTweaksExpanded {
    param([bool]$Expanded)

    $script:TweaksExpanded = $Expanded
    if ($Expanded) {
        Show-MTWinElementFade -Element $TweakSubmenu
    }
    else {
        $TweakSubmenu.Visibility = 'Collapsed'
    }
    $TweaksExpandMark.Text = if ($Expanded) { '-' } else { '+' }
}

function Show-MTWinTweakView {
    param([ValidateSet('Privacy','Debloat','Explorer','Performance','System','Appearance','Input','Network','Devices')][string]$Name)

    if ($null -ne $script:PendingConfirmation) { Clear-MTWinInlineConfirmation }
    $script:CurrentTweakView = $Name
    foreach ($key in $script:TweakViewControls.Keys) {
        $view = $script:TweakViewControls[$key]
        if ($key -eq $Name) {
            $view.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
            $view.Opacity = 1
            $view.Visibility = 'Visible'
        }
        else { $view.Visibility = 'Collapsed' }
    }
    foreach ($key in $script:TweakNavControls.Keys) { $script:TweakNavControls[$key].IsChecked = ($key -eq $Name) }
    $TweaksPanelTitle.Text = $Name
    $TweaksScroll.ScrollToTop()
    Update-MTWinSelectionState
    $window.Dispatcher.BeginInvoke([action]{ Resize-MTWinCards }, [Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
}

function Show-MTWinPanel {
    param([ValidateSet('Cleanup', 'Tweaks', 'SystemApps')][string]$Name)

    if ($null -ne $script:PendingConfirmation) { Clear-MTWinInlineConfirmation }
    $NavCleanup.IsChecked = ($Name -eq 'Cleanup')
    $NavTweaks.IsChecked = ($Name -eq 'Tweaks')
    $NavSystemApps.IsChecked = ($Name -eq 'SystemApps')

    # Submenu clicks call Show-MTWinPanel Tweaks before selecting the category.
    # If Tweaks is already visible, avoid collapsing/recreating the same visual
    # tree in the same dispatcher turn; that was another source of flicker.
    if ($script:CurrentPanel -eq $Name) {
        if ($Name -eq 'Tweaks' -and -not $script:TweaksExpanded) { Set-MTWinTweaksExpanded $true }
        return
    }

    $CleanupPanel.Visibility = 'Collapsed'
    $TweaksPanel.Visibility = 'Collapsed'
    $SystemAppsPanel.Visibility = 'Collapsed'

    if ($Name -eq 'Cleanup') {
        Set-MTWinTweaksExpanded $false
        $CleanupPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $CleanupPanel.Opacity = 1
        $CleanupPanel.Visibility = 'Visible'
        $CleanupScroll.ScrollToTop()
    }
    elseif ($Name -eq 'Tweaks') {
        Set-MTWinTweaksExpanded $true
        $TweaksPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $TweaksPanel.Opacity = 1
        $TweaksPanel.Visibility = 'Visible'
        Show-MTWinTweakView $script:CurrentTweakView
    }
    else {
        Set-MTWinTweaksExpanded $false
        $SystemAppsPanel.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $SystemAppsPanel.Opacity = 1
        $SystemAppsPanel.Visibility = 'Visible'
        $SystemAppsScroll.ScrollToTop()
    }

    $script:CurrentPanel = $Name
    $window.Dispatcher.BeginInvoke([action]{ Resize-MTWinCards }, [Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
}

function Start-MTWinSystemApp {
    param([Parameter(Mandatory = $true)]$Definition)

    try {
        if ($Definition.Kind -eq 'Uri') {
            Start-Process -FilePath $Definition.Target -ErrorAction Stop | Out-Null
        }
        elseif ($Definition.Kind -eq 'Msc') {
            $consolePath = Join-Path $env:SystemRoot ('System32\' + $Definition.Target)
            $mmc = Join-Path $env:SystemRoot 'System32\mmc.exe'
            if (-not (Test-Path -LiteralPath $consolePath)) { throw "$($Definition.Name) is unavailable on this Windows edition." }
            Start-Process -FilePath $mmc -ArgumentList ('"' + $consolePath + '"') -ErrorAction Stop | Out-Null
        }
        else {
            $target = Join-Path $env:SystemRoot ('System32\' + $Definition.Target)
            if (-not (Test-Path -LiteralPath $target)) { throw "$($Definition.Name) is unavailable on this Windows version." }
            if ([string]::IsNullOrWhiteSpace($Definition.Arguments)) {
                Start-Process -FilePath $target -ErrorAction Stop | Out-Null
            }
            else {
                Start-Process -FilePath $target -ArgumentList $Definition.Arguments -ErrorAction Stop | Out-Null
            }
        }
        Write-MTWinStatus -Message ("Opened " + $Definition.Name) -Level Success
    }
    catch {
        Write-MTWinStatus -Message ($Definition.Name + ' - ' + $_.Exception.Message) -Level Error
    }
}

$script:CleanupControls = @{}
$script:TweakControls = @{}
$script:PreferenceControls = @{}
$script:PreferenceInitial = @{}
$script:PreferenceDirty = @{}
$script:ChoiceControls = @{}
$script:ResponsiveCards = [Collections.Generic.List[object]]::new()
$script:ChoiceLayouts = [Collections.Generic.List[object]]::new()
$script:ActiveJob = $null
$script:PendingConfirmation = $null
$script:AppearanceMode = 'System'
$script:CurrentPanel = 'Cleanup'
$script:CurrentTweakView = 'Privacy'
$script:TweaksExpanded = $false
$script:IsCompactNavigation = $false

$script:PrimaryNavControls = @($NavCleanup, $NavTweaks, $NavSystemApps)
$script:TweakNavControls = @{
    Privacy=$NavTweakPrivacy; Debloat=$NavTweakDebloat; Explorer=$NavTweakExplorer; Performance=$NavTweakPerformance;
    System=$NavTweakSystem; Appearance=$NavTweakAppearance; Input=$NavTweakInput; Network=$NavTweakNetwork; Devices=$NavTweakDevices
}
$script:TweakViewControls = @{
    Privacy=$TweakPrivacyGrid; Debloat=$TweakDebloatGrid; Explorer=$TweakExplorerGrid; Performance=$TweakPerformanceGrid;
    System=$TweakSystemGrid; Appearance=$TweakAppearanceGrid; Input=$TweakInputGrid; Network=$TweakNetworkGrid; Devices=$TweakDevicesGrid
}
$script:TweakViewMap = @{
    Privacy=@{ Actions=@('Privacy') }
    Debloat=@{ Actions=@('Windows debloat') }
    Explorer=@{ Actions=@('Windows behavior') }
    Performance=@{ Actions=@('Performance') }
    System=@{ Actions=@('System') }
    Appearance=@{ Actions=@() }
    Input=@{ Actions=@() }
    Network=@{ Actions=@('Network') }
    Devices=@{ Actions=@('Device installers') }
}

Add-MTWinSelectionCards -Grid $CleanupGrid -Scroll $CleanupScroll -Definitions $cleanupDefinitions -ControlMap $script:CleanupControls
Add-MTWinSelectionCards -Grid $TweakPrivacyGrid -Scroll $TweaksScroll -Definitions @($tweakDefinitions | Where-Object { $_.Category -eq 'Privacy' }) -ControlMap $script:TweakControls
Add-MTWinSelectionCards -Grid $TweakDebloatGrid -Scroll $TweaksScroll -Definitions @($tweakDefinitions | Where-Object { $_.Category -eq 'Windows debloat' }) -ControlMap $script:TweakControls
Add-MTWinSelectionCards -Grid $TweakExplorerGrid -Scroll $TweaksScroll -Definitions @($tweakDefinitions | Where-Object { $_.Category -eq 'Windows behavior' }) -ControlMap $script:TweakControls
Add-MTWinPreferenceCards -Grid $TweakExplorerGrid -Scroll $TweaksScroll -Definitions @($preferenceDefinitions | Where-Object { $_.Category -eq 'Explorer and taskbar' })
Add-MTWinSelectionCards -Grid $TweakPerformanceGrid -Scroll $TweaksScroll -Definitions @($tweakDefinitions | Where-Object { $_.Category -eq 'Performance' }) -ControlMap $script:TweakControls
Add-MTWinPreferenceCards -Grid $TweakPerformanceGrid -Scroll $TweaksScroll -Definitions @($preferenceDefinitions | Where-Object { $_.Category -eq 'Performance and compatibility' })
Add-MTWinSelectionCards -Grid $TweakSystemGrid -Scroll $TweaksScroll -Definitions @($tweakDefinitions | Where-Object { $_.Category -eq 'System' }) -ControlMap $script:TweakControls
Add-MTWinPreferenceCards -Grid $TweakSystemGrid -Scroll $TweaksScroll -Definitions @($preferenceDefinitions | Where-Object { $_.Category -eq 'Windows' })
Add-MTWinPreferenceCards -Grid $TweakAppearanceGrid -Scroll $TweaksScroll -Definitions @($preferenceDefinitions | Where-Object { $_.Category -eq 'Appearance' })
Add-MTWinPreferenceCards -Grid $TweakInputGrid -Scroll $TweaksScroll -Definitions @($preferenceDefinitions | Where-Object { $_.Category -eq 'Input and desktop' })
Add-MTWinSelectionCards -Grid $TweakNetworkGrid -Scroll $TweaksScroll -Definitions @($tweakDefinitions | Where-Object { $_.Category -eq 'Network' }) -ControlMap $script:TweakControls
Add-MTWinChoiceRows -Grid $TweakNetworkGrid -Scroll $TweaksScroll -Definitions $choiceDefinitions
Add-MTWinSelectionCards -Grid $TweakDevicesGrid -Scroll $TweaksScroll -Definitions @($tweakDefinitions | Where-Object { $_.Category -eq 'Device installers' }) -ControlMap $script:TweakControls
Add-MTWinSystemAppCards -Grid $SystemAppsGrid -Scroll $SystemAppsScroll

foreach ($control in @($script:CleanupControls.Values) + @($script:TweakControls.Values)) {
    $control.Add_Checked({ Update-MTWinSelectionState })
    $control.Add_Unchecked({ Update-MTWinSelectionState })
}
foreach ($control in $script:PreferenceControls.Values) {
    $control.Add_Checked({
        $id = [string]$args[0].Tag
        if (($args[0].IsChecked -eq $true) -eq $script:PreferenceInitial[$id]) { $script:PreferenceDirty.Remove($id) } else { $script:PreferenceDirty[$id] = $true }
        Update-MTWinSelectionState
    })
    $control.Add_Unchecked({
        $id = [string]$args[0].Tag
        if (($args[0].IsChecked -eq $true) -eq $script:PreferenceInitial[$id]) { $script:PreferenceDirty.Remove($id) } else { $script:PreferenceDirty[$id] = $true }
        Update-MTWinSelectionState
    })
}
foreach ($control in $script:ChoiceControls.Values) { $control.Add_SelectionChanged({ Update-MTWinSelectionState }) }

# WPF's default pixel scrolling is noticeably fast for these dense card lists.
# Use a fixed, modest distance per standard wheel notch while preserving
# high-resolution wheel deltas. This is deliberately not animated.
$script:WheelScrollPixels = 44.0
function Add-MTWinVerticalWheelTuning {
    param([Parameter(Mandatory = $true)][Windows.Controls.ScrollViewer]$ScrollViewer)

    $ScrollViewer.Add_PreviewMouseWheel({
        param($sender, $eventArgs)
        if ($sender -eq $RailScroll -and $script:IsCompactNavigation) { return }
        $notches = [double]$eventArgs.Delta / 120.0
        $target = $sender.VerticalOffset - ($notches * $script:WheelScrollPixels)
        $target = [Math]::Max(0.0, [Math]::Min($sender.ScrollableHeight, $target))
        $sender.ScrollToVerticalOffset($target)
        $eventArgs.Handled = $true
    })
}

foreach ($scrollViewer in @($RailScroll, $CleanupScroll, $TweaksScroll, $SystemAppsScroll)) {
    Add-MTWinVerticalWheelTuning -ScrollViewer $scrollViewer
}

# WPF does not translate a vertical mouse wheel into horizontal scrolling.
# In compact navigation, scroll the horizontal rail with the wheel while the
# scrollbar remains hidden.
$RailScroll.Add_PreviewMouseWheel({
    param($sender, $eventArgs)
    if (-not $script:IsCompactNavigation) { return }
    $step = [double]$eventArgs.Delta / 2.0
    $sender.ScrollToHorizontalOffset($sender.HorizontalOffset - $step)
    $eventArgs.Handled = $true
})

$NavCleanup.Add_Click({ Show-MTWinPanel Cleanup })
$NavTweaks.Add_Click({
    if ($script:CurrentPanel -eq 'Tweaks') {
        $NavTweaks.IsChecked = $true
        Set-MTWinTweaksExpanded (-not $script:TweaksExpanded)
    }
    else {
        Show-MTWinPanel Tweaks
    }
})
$NavSystemApps.Add_Click({ Show-MTWinPanel SystemApps })

$NavTweakPrivacy.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Privacy })
$NavTweakDebloat.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Debloat })
$NavTweakExplorer.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Explorer })
$NavTweakPerformance.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Performance })
$NavTweakSystem.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView System })
$NavTweakAppearance.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Appearance })
$NavTweakInput.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Input })
$NavTweakNetwork.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Network })
$NavTweakDevices.Add_Click({ Show-MTWinPanel Tweaks; Show-MTWinTweakView Devices })

$CleanupSelectAll.Add_Click({
    $controls = @($script:CleanupControls.Values)
    $all = ($controls.Count -gt 0 -and @($controls | Where-Object { $_.IsChecked -ne $true }).Count -eq 0)
    foreach ($control in $controls) { $control.IsChecked = -not $all }
})
$CleanupClear.Add_Click({
    foreach ($control in $script:CleanupControls.Values) { $control.IsChecked = $false }
})
$TweaksSelectAll.Add_Click({
    $controls = @(Get-MTWinVisibleTweakActionControls)
    $all = ($controls.Count -gt 0 -and @($controls | Where-Object { $_.IsChecked -ne $true }).Count -eq 0)
    foreach ($control in $controls) { $control.IsChecked = -not $all }
})
$TweaksClear.Add_Click({
    foreach ($control in $script:TweakControls.Values) { $control.IsChecked = $false }
    foreach ($definition in $preferenceDefinitions) { $script:PreferenceControls[$definition.Id].IsChecked = $script:PreferenceInitial[$definition.Id] }
    foreach ($control in $script:ChoiceControls.Values) { $control.SelectedIndex = 0 }
    $script:PreferenceDirty.Clear()
    Update-MTWinSelectionState
})

$RunCleanup.Add_Click({
    $ids = @(Get-MTWinSelectedIds $script:CleanupControls $cleanupDefinitions)
    # Disk Cleanup is always included as the final baseline operation and is
    # intentionally not exposed as a selectable card.
    $ids += 'DiskCleanup'

    $risky = @($cleanupDefinitions | Where-Object { ($ids -contains $_.Id) -and $_.Risk })
    if ($risky.Count -gt 0) {
        Show-MTWinInlineConfirmation -Kind Cleanup -Ids $ids -RiskCount $risky.Count
        return
    }

    Start-MTWinUiOperation -Kind Cleanup -Ids $ids
})

$RunTweaks.Add_Click({
    $ids = @(Get-MTWinQueuedTweakIds)
    if ($ids.Count -eq 0) { return }

    $actionIds = @(Get-MTWinSelectedIds $script:TweakControls $tweakDefinitions)
    $risky = @($tweakDefinitions | Where-Object { ($actionIds -contains $_.Id) -and $_.Risk })
    if ($risky.Count -gt 0) {
        Show-MTWinInlineConfirmation -Kind Tweaks -Ids $ids -RiskCount $risky.Count
        return
    }

    Start-MTWinUiOperation -Kind Tweaks -Ids $ids
})

$CleanupConfirmCancel.Add_Click({ Clear-MTWinInlineConfirmation })
$TweaksConfirmCancel.Add_Click({ Clear-MTWinInlineConfirmation })
$CleanupConfirmContinue.Add_Click({
    if ($null -eq $script:PendingConfirmation -or $script:PendingConfirmation.Kind -ne 'Cleanup') { return }
    $ids = @($script:PendingConfirmation.Ids)
    Start-MTWinUiOperation -Kind Cleanup -Ids $ids
})
$TweaksConfirmContinue.Add_Click({
    if ($null -eq $script:PendingConfirmation -or $script:PendingConfirmation.Kind -ne 'Tweaks') { return }
    $ids = @($script:PendingConfirmation.Ids)
    Start-MTWinUiOperation -Kind Tweaks -Ids $ids
})

$AppearanceButton.Add_Click({
    $next = switch ($script:AppearanceMode) {
        'System' { 'Light' }
        'Light' { 'Dark' }
        default { 'System' }
    }
    Set-MTWinAppearance $next
})

if ($null -ne $GitHubLink) {
    $GitHubLink.Add_RequestNavigate({
        param($sender, $eventArgs)
        try { Start-Process -FilePath $eventArgs.Uri.AbsoluteUri -ErrorAction Stop | Out-Null } catch { }
        $eventArgs.Handled = $true
    })
}

$script:JobTimer = New-Object Windows.Threading.DispatcherTimer
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$script:JobTimer.Add_Tick({
    if ($null -eq $script:ActiveJob) { return }

    if (-not $script:ActiveJob.Async.IsCompleted) { return }

    $script:JobTimer.Stop()
    $job = $script:ActiveJob
    $script:ActiveJob = $null
    $activeStatusText = if ($job.Kind -eq 'Cleanup') { $CleanupStatusText } else { $TweaksStatusText }
    $result = $null
    $jobFailed = $false
    try {
        $output = @($job.PowerShell.EndInvoke($job.Async))
        if ($output.Count -gt 0) { $result = $output[-1] }
    }
    catch {
        $jobFailed = $true
        Write-MTWinStatus -Message $_.Exception.Message -Level Error
    }
    finally {
        $job.PowerShell.Dispose()
        $job.Runspace.Close()
        $job.Runspace.Dispose()
    }

    Set-MTWinBusy $false
    $failureCount = if ($result) { [int]$result.Failures } else { 0 }
    if ($jobFailed) {
        Write-MTWinStatus -Message ($job.Kind + ' stopped because of an unexpected error.') -Level Error
        $activeStatusText.Text = 'Stopped | unexpected error'
    }
    elseif ($failureCount -gt 0) {
        Write-MTWinStatus -Message ("$($result.Kind) finished with $failureCount failed operation(s).") -Level Error
        $activeStatusText.Text = "Finished | $failureCount failed"
    }
    else {
        $completedKind = if ($result) { $result.Kind } else { $job.Kind }
        Write-MTWinStatus -Message ($completedKind + ' finished.') -Level Success
        $activeStatusText.Text = "Finished | $($job.Total) completed"
    }

    if ($job.Kind -eq 'Tweaks') {
        foreach ($definition in $preferenceDefinitions) {
            $state = [bool](Get-MTWinPreferenceState $definition.Id)
            $script:PreferenceInitial[$definition.Id] = $state
            $script:PreferenceControls[$definition.Id].IsChecked = $state
        }
        $script:PreferenceDirty.Clear()
        foreach ($control in $script:ChoiceControls.Values) { $control.SelectedIndex = 0 }
    }
    Update-MTWinSelectionState
})

$systemThemeHandler = [Microsoft.Win32.UserPreferenceChangedEventHandler]{
    param($sender, $eventArgs)
    if ($script:AppearanceMode -eq 'System') {
        $window.Dispatcher.BeginInvoke([action]{ Set-MTWinAppearance System }) | Out-Null
    }
}

$window.Add_SourceInitialized({ Set-MTWinAppearance -Mode System -Animate $false })
$window.Add_Loaded({
    Update-MTWinResponsiveLayout
    Resize-MTWinCards
})
$window.Add_SizeChanged({
    $window.Dispatcher.BeginInvoke([action]{ Update-MTWinResponsiveLayout }, [Windows.Threading.DispatcherPriority]::Background) | Out-Null
})
[Microsoft.Win32.SystemEvents]::add_UserPreferenceChanged($systemThemeHandler)

$window.Add_Closing({
    param($sender, $eventArgs)
    if ($null -ne $script:ActiveJob) {
        $eventArgs.Cancel = $true
        $statusText = if ($script:ActiveJob.Kind -eq 'Cleanup') { $CleanupStatusText } else { $TweaksStatusText }
        $statusText.Text = 'Running | finish the current operation before closing'
        Write-MTWinStatus -Message 'Finish the current operation before closing MT win tools.' -Level Warning
    }
})

$window.Add_Closed({
    $script:JobTimer.Stop()
    [Microsoft.Win32.SystemEvents]::remove_UserPreferenceChanged($systemThemeHandler)
})

try {
    Write-Host "MT win tools" -ForegroundColor White
    Write-Host 'Administrator session ready. Select actions in the graphical window.'
    Update-MTWinSelectionState
    [void]$window.ShowDialog()
}
finally {
    if ($instanceMutex) {
        try { $instanceMutex.ReleaseMutex() } catch { }
        $instanceMutex.Dispose()
    }
}
}
