MT win tools v0.1.1

- Updated the shared Mick's Tools interface and restored bottom-of-window credits.
- Fixed OneDrive removal failing after uninstall; local OneDrive files and unrelated OneSync services are preserved.
- Fixed Settings Home visibility and state detection without overwriting other Settings page visibility rules.
- Disabled keyboard and mouse interaction during background operations and prevented duplicate workers.
- Separated completed, skipped, and failed operation counts; failed requests remain available to retry.
- Surfaced worker, registry, app-removal, service, Docker, and native-command failures instead of reporting success.
- Preserved hibernation settings during refresh and accepted DISM's reboot-required success code.
- Prevented cache cleanup from following junctions or symbolic links into unrelated directories.

Regression checks cover Windows PowerShell 5.1, PowerShell 7, WPF loading, background workers, and mocked Windows operations. Applying cleanup or configuration changes still depends on Windows edition, build, installed software, and administrator access.

Assets: standalone `MT-win-tools.ps1`, `MT-win-tools-v0.1.1.zip`, and unsigned `SHA256SUMS.txt`.
