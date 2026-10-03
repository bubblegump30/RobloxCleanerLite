# v0.2.0 — Deeper Cache Cleaning

Roblox Cleaner Lite is a portable Windows utility for previewing and removing
Roblox cache files, older logs and optional crash dumps.

## Included in v0.2.0

- Fourteen recognized cleanup locations.
- Optional deeper asset payload and shader cache cleaning.
- Deep scan preset that includes all file ages; deletion still requires confirmation.
- Live scan counts and cleanup progress.
- Default one-day retention, with seven-day, thirty-day and all-age options.
- Protection for installations, saved places, settings, recovery folders,
  credentials, storage databases and folder links.
- Cancellation and exportable scan/cleanup reports.

## Download and run

Extract `RobloxCleanerLite-v0.2.0-Windows.zip` and double-click
`Start-Roblox-Cleaner.cmd`. Close Roblox and Studio before cleaning.
The utility uses Windows PowerShell 5.1 and WPF; no additional runtime installation
or administrator rights are required.

Deletion is permanent. Roblox may redownload assets or rebuild shaders.

## Verification status

64 engine assertions passed on PowerShell 7.4.7 / Linux. PowerShell sources parsed,
XAML validated as XML and package integrity verified. The GitHub release workflow must pass Windows PowerShell 5.1 parsing, cleanup
regressions, WPF loading/layout and exact package checks before publication.
Manual desktop interaction testing remains pending. This is a preview release.

## Release asset SHA-256

`43acfa65c0bdec70e0108bf882a270a806b40bad2be0d9606c354ef71b5ac3a5`
