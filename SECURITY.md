# Security policy

## Supported versions

The latest published version is supported for security fixes.

Development builds may change before release. Older versions may stop receiving fixes after a newer version is published.

## Reporting a vulnerability

Do not post credentials, private keys, recovery keys, sensitive registry exports, personal files or unredacted system logs in a public GitHub issue.

Use GitHub private vulnerability reporting if it is available for this repository.

A useful report should include:

- Affected MT win tools version
- Windows edition and build
- PowerShell version
- Description of the issue
- Steps to reproduce it
- Expected behavior
- Actual behavior
- Sanitized output or screenshots, if relevant

## Security model

MT win tools is a local Windows administration utility. It does not make network requests, operate an intermediary service or maintain user accounts.

The application requires administrator access because many cleanup and configuration operations modify protected files, services, registry locations or Windows components.

## Elevation

When elevation or an STA PowerShell process is required, the script writes its current source to a temporary file, calculates its SHA-256 hash and launches a small encoded bootstrap.

The elevated process reads the temporary file, verifies the exact bytes against the expected hash, removes the file and only then evaluates the verified source. A failed verification stops execution.

The application also uses a per-session single-instance guard.

## Destructive operations

Cleanup and system configuration can change or remove local data.

Higher-impact actions are marked in the interface and require explicit confirmation before execution. Confirmation does not make an operation reversible.

Windows Disk Cleanup is the baseline operation for every cleanup run. Other cleanup operations require selection.

The application does not provide a general rollback mechanism. Some changes can be reversed manually or through Windows restore and recovery features when those features remain available.

## System state

The application reads local Windows state to show preferences, choose supported actions and apply requested configuration.

MT win tools does not intentionally store a usage history, telemetry record or cloud state.

## Networking

MT win tools does not contain a download, update or telemetry client and does not intentionally send network requests.

Running the script through `irm ... | iex` causes PowerShell to retrieve the selected script from GitHub before MT win tools starts. The application itself does not perform that download.

Windows components opened or configured through the application may have their own networking behavior outside MT win tools.

## Security-sensitive areas

Security issues may include:

- Executing modified temporary elevation payloads
- Running a higher-impact operation without the required confirmation
- Applying an operation that was not selected or requested
- Unsafe command construction or argument handling
- Writing to an unintended file, registry path or user profile
- Exposing sensitive local information through output or logs
- Bypassing the single-instance or elevation integrity controls in a way that creates security impact

## Disclaimer

MT win tools changes Windows configuration and can perform destructive cleanup. Review selected actions and keep appropriate backups or recovery options for the system being modified.
