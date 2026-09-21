# MT win tools

Part of Mick's Tools.

A Windows cleanup and configuration utility built as a single PowerShell script.

## Features

- Selectable cleanup for temporary data, Windows caches and aggressive cleanup tasks
- Automatic Windows Disk Cleanup baseline on every cleanup run
- Privacy, debloat, Explorer, performance, system, input, network and device tweaks
- Windows preference toggles with current-state detection
- DNS presets and Multiplane Overlay configuration
- Shortcuts to Windows Settings and system-management tools
- Inline confirmation for higher-impact actions
- Dark, light and system appearance
- Responsive WPF interface
- No analytics, telemetry, accounts or update service

## Requirements

- Windows
- Windows PowerShell 5.1 or PowerShell 7 on Windows
- Administrator approval

Windows 11 is the primary target. Availability and behavior can vary by Windows edition and build.

## Usage

The script requests administrator approval automatically when required. No installation or external PowerShell modules are required.

### Quick run

Run the tagged release directly from GitHub:

```powershell
irm https://raw.githubusercontent.com/micknorj/MT-win-tools/v0.1/MT-win-tools.ps1 | iex
```

This retrieves and executes the tagged script immediately. Use a release tag rather than `main` when a fixed version is required.

### Local file

Run a local copy with Windows PowerShell:

```powershell
powershell -NoProfile -File .\MT-win-tools.ps1
```

Or with PowerShell 7:

```powershell
pwsh -NoProfile -File .\MT-win-tools.ps1
```

A script downloaded through a browser may have the Windows Internet-zone mark. Unblock the file before running it:

```powershell
Unblock-File .\MT-win-tools.ps1
.\MT-win-tools.ps1
```

If using the release ZIP, unblock the archive before extracting it so the extracted files do not inherit the mark:

```powershell
Unblock-File .\MT-win-tools-v0.1.zip
Expand-Archive .\MT-win-tools-v0.1.zip
Set-Location .\MT-win-tools-v0.1\MT-win-tools
.\MT-win-tools.ps1
```

## Cleanup

Optional cleanup tasks run only when selected. Windows Disk Cleanup runs automatically as the baseline cleanup operation.

Actions marked as higher impact require confirmation inside the application. Completed cleanup operations are not automatically reversible.

## Privacy

MT win tools runs locally and does not make network requests, send telemetry or operate an intermediary service.

System state is read only as needed to display or apply the requested Windows changes. The application does not maintain an account, cloud profile or usage history.

## Security

The script requests elevation only when needed and verifies its temporary relaunch payload before evaluating it in the elevated process.

Higher-impact operations require explicit in-application confirmation. See the [security policy](SECURITY.md) for the security model and vulnerability reporting guidance.

## Limitations

- Windows only
- Administrator access is required for normal use
- Some controls are unavailable on certain Windows editions or builds
- Some changes require Explorer restart, sign-out or Windows restart before they are fully visible
- Cleanup, debloat and system changes may remove data, recovery options or Windows components
- There is no general rollback system; create a restore point or backup when appropriate
- Windows policies managed by an organization may override or prevent changes

## Development

The project has no build step or external dependencies.

To run a PowerShell syntax check from the repository root:

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\MT-win-tools.ps1),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
$errors
```

No output indicates that the PowerShell parser found no syntax errors. Interface behavior still requires testing on Windows because the application uses WPF and Windows APIs.

## Changelog

See the [changelog](CHANGELOG.md).

## License

Licensed under the [MIT License](LICENSE).

Copyright © 2026 micknorj.
