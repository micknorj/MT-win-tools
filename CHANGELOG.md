# Changelog

Notable changes to MT win tools.

## 0.1.1 - 2026-10-08

- Updated the shared interface and restored bottom-of-window credits.
- Fixed OneDrive uninstall, Settings Home visibility, and busy keyboard interaction.
- Fixed completion counts and retry state for failed or skipped operations.
- Reported worker, service, registry, app-removal, and native-command failures.
- Restored hibernation settings after refresh; accepted DISM's reboot-required success code.
- Prevented cache cleanup from following root or nested junctions and symbolic links.
- Added regression checks for both PowerShell editions and a validated release ZIP/checksum command.

## 0.1 - 2026-09-21

Initial public release.

### Added

- Selectable Windows cleanup with automatic Disk Cleanup baseline
- Privacy, debloat, Explorer, performance, system, appearance, input, network and device configuration
- Windows preference toggles, DNS presets and Multiplane Overlay choices
- Windows Settings and system-management shortcuts
- Automatic administrator relaunch with temporary-payload verification
- Single-instance guard and background operation execution

### Interface

- Mick's Tools WPF design language
- Dark, light and system appearance
- Responsive desktop layout
- Expandable tweak navigation
- Inline confirmation for higher-impact actions
- Themed overlay scrollbars with tuned wheel scrolling
- Consistent content width across sections

### Safety

- Higher-impact cleanup and tweak controls are identified before execution
- Confirmation remains inside the application rather than using unrelated native dialogs
- Operations are user-selected except for the Windows Disk Cleanup baseline
