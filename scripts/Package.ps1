[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$sourcePath = Join-Path $projectRoot 'MT-win-tools.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
if ($source -notmatch '(?m)^# MT win tools v(\d+\.\d+\.\d+)\.') { throw 'The source must declare a three-part release version.' }
$releaseVersion = $matches[1]

$executable = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
& $executable -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'tests\Regression.Tests.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Regression tests failed. No release was packaged.' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$output = [IO.Path]::GetFullPath((Join-Path $projectRoot ('dist\v' + $releaseVersion)))
if (-not $output.StartsWith($projectRoot.TrimEnd('\') + '\dist\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected release output directory.' }
New-Item -ItemType Directory -Path $output -Force | Out-Null
$stage = Join-Path $output ('.package-' + [guid]::NewGuid().ToString('N'))
$archive = Join-Path $output ('MT-win-tools-v' + $releaseVersion + '.zip')
try {
    $bundle = Join-Path $stage 'MT-win-tools'
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    foreach ($file in @('MT-win-tools.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md', 'SECURITY.md')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $file) -Destination (Join-Path $bundle $file)
    }
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    $zipOutput = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $bundle -File | Sort-Object Name) {
            $entryName = 'MT-win-tools/' + $file.Name
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipOutput, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $zipOutput.Dispose() }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $output 'MT-win-tools.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'RELEASE_NOTES.md') -Destination (Join-Path $output 'release-notes.md') -Force

    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $entry = $zip.GetEntry('MT-win-tools/MT-win-tools.ps1')
        if (-not $entry) { throw 'The ZIP is missing the executable script.' }
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $zipHash = -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($zipHash -ne (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'The packaged script does not match the tested source.' }
        if ($zip.Entries.Count -ne 5) { throw 'Unexpected files in the release ZIP.' }
    }
    finally { $zip.Dispose() }

    $hashes = foreach ($file in @([IO.Path]::GetFileName($archive), 'MT-win-tools.ps1')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $output $file) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $file"
    }
    [IO.File]::WriteAllText((Join-Path $output 'SHA256SUMS.txt'), (($hashes -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output "Release v$releaseVersion is ready in $output"
}
finally {
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    if (-not $resolvedStage.StartsWith($output.TrimEnd('\') + '\.package-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected staging cleanup path.' }
    if (Test-Path -LiteralPath $resolvedStage) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force }
}
