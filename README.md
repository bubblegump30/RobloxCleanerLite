# Roblox Cleaner Lite v0.2.0

A small, portable Windows utility that previews Roblox caches, older logs and
optional Roblox crash dumps before deleting anything. Uses Windows' built-in
PowerShell 5.1 and WPF. No installation, Python, extra runtime download,
administrator rights, telemetry, scheduled task or background service.

## Start

1. Extract the complete ZIP into a folder.
2. Double-click **Start-Roblox-Cleaner.cmd**.
3. Click **Scan**, then **Preview files** to inspect the selection.
4. Close Roblox, Studio and Roblox installers. Click **Clean selected** and
   confirm the exact number and size of files.

For stronger cleaning, click **Deep scan** instead of Scan. This selects asset
caches, logs and the Deep cache category, and changes the age filter to **Include
all ages**. It only scans; review the preview and confirm cleanup separately.
The crash-dump switch retains your selection and remains off on first launch.

Windows 10/11 desktop is the intended platform. Keep all package files together.
Do not run the launcher from inside the ZIP. The launcher sets execution policy
only for its own PowerShell process; it does not change your system policy.
If an organization blocks scripts, its policy takes precedence.

## Included

- Black and purple desktop interface with keyboard focus and scalable text.
- Separate switches for asset caches, deep caches, older logs and crash dumps.
- Expanded coverage: **14 recognized locations**, including asset payload folders
  and exact shader cache files.
- Default retention: keep the newest **1 day**. Optional 7 days, 30 days or all ages.
- One-click **Deep scan** preset for a larger selection at all ages.
- File preview with paths, counts and data sizes. Scan notices disclose inaccessible
  or linked locations; missing folders show **Not found**.
- Scan and cleanup run on a worker so the interface stays available.
- Live entry counts during scanning, file progress during cleanup, cancellation,
  process checks and exportable local text reports.
- A higher 250,000-entry scan cap; capped or cancelled scans cannot clean.
- Source code and regression tests.

Crash dumps are off by default. Scan totals include all recognized categories;
the large selected total includes only checked categories. Sizes are logical file
data sizes; the actual change in free disk space may differ.

## Exact cleanup scope

Only existing files in the following locations are considered:

| Location | Eligible files |
| --- | --- |
| `%LOCALAPPDATA%\Roblox\logs` | `.log` files, subject to age filter |
| `%LOCALAPPDATA%\Roblox\Cache` | Asset cache files, subject to age filter and protected-file exclusions |
| `%TEMP%\Roblox\http` | HTTP cache files, with the same exclusions |
| `%TEMP%\Roblox\sounds` | Sound cache files, with the same exclusions |
| `%LOCALAPPDATA%\CrashDumps` | Direct children named `RobloxPlayerBeta.exe.<number>.dmp`, `RobloxStudioBeta.exe.<number>.dmp`, or the equivalent Player/Studio names |
| `%LOCALAPPDATA%\Roblox\http` | Additional HTTP cache, subject to the age filter and protected-file exclusions |
| `%LOCALAPPDATA%\Roblox\sounds` | Additional sound cache, with the same exclusions |
| `%TEMP%\Roblox\Cache` | Additional temporary asset cache, with the same exclusions |
| `%LOCALAPPDATA%\Roblox\rbx-storage` | Deep cache: asset payload files; protected file types and names remain excluded |
| `%LOCALAPPDATA%\Roblox\rbx-storage-sc` | Deep cache: secondary asset payload files, with the same exclusions |
| `%TEMP%\Roblox\rbx-storage` | Deep cache: temporary asset payload files, with the same exclusions |
| `%TEMP%\Roblox\rbx-storage-sc` | Deep cache: temporary secondary payloads, with the same exclusions |
| `%LOCALAPPDATA%\Roblox` | Deep cache: only direct `shadercache.bin` and `shadercachevk.bin` files |
| `%TEMP%\Roblox` | Deep cache: only direct `shadercache.bin` and `shadercachevk.bin` files |

Some Roblox installations use different cache paths; these are left alone. This
version does not cover Microsoft Store app package folders or custom bootstrapper
cache paths.

The tool does not delete the Roblox installation, Versions folder, ClientSettings,
the whole Roblox temp folder, browser cookies, credentials, screenshots or
`rbx-storage` databases. It does not alter FastFlags, the registry or Roblox program files.
Saved-place/model extensions, scripts, executable files, settings and database
extensions are excluded even within a recognized cache. Autosave, recovery and
ClientSettings folder names are excluded. Folder links, junctions and read-only
files are left alone. Cache folders themselves are never removed.

Deep cache is off at startup. It removes eligible payload files and specific
shader binaries, but retains the `rbx-storage.db` index and its sidecars. Roblox
may redownload asset payloads or recompile shaders afterward. This is a partial
cache cleanup, not a full database reset. Storage databases can also hold Studio
usage preferences. The tool does not delete arbitrary files directly inside the
main Roblox folder or search installed version folders.

Cleanup uses the previewed file list. Files added after the scan are not deleted.
Files whose length or last-write time changed are skipped. Each attempted path is
rechecked for its allowed root, file type and linked ancestors. Locked or
inaccessible files are skipped and appear in the cleanup report.

The tool checks for processes whose names begin with Roblox before deletion and
between batches of 50 files. It stops if it detects Roblox reopening; avoid
launching Roblox while cleanup runs. No process is forcibly closed.

Deletion is permanent and does not use the Recycle Bin. The confirmation dialog
states this. Cleaning cache may cause assets to download again. Keep logs and
dumps you need for an active support investigation. This tool makes no FPS or
performance improvement claims.

## Verification

The cleanup engine was exercised against generated fixture files with PowerShell
7.4.7 on Linux. Tests cover exact category selection, retained work, age filters,
file changes after preview, path escapes, folder links and parent replacement,
cancellation, scan limits, and Roblox opening during cleanup. All PowerShell
files were parsed and the XAML was checked as XML. **64 assertions passed**;
one Windows-specific exclusive-file-lock test was skipped on Linux.

**Windows desktop UI, Windows PowerShell 5.1 execution and Windows exclusive-file
locks still require a Windows run.** The included regression test suite tests
the exclusive-file case when run on Windows. No actual user Roblox files were
cleaned during development.

To run the tests on Windows, open PowerShell inside the extracted folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Cleaner.ps1
```

Tests use their own newly generated temporary directory and remove that directory
afterward. They do not target your Roblox installation.

For a desktop smoke test: launch the tool, resize it, navigate using Tab, scan,
inspect the preview, change the age filter, cancel a scan, export a report and
verify that opening Roblox blocks cleaning. A cleanup confirmation can be
declined without deleting anything.

## Source references

- [Roblox log locations](https://create.roblox.com/docs/studio/debugging)
- [Roblox cache locations reported in Studio debugging](https://devforum.roblox.com/t/http-429-causes-assets-to-fail-loading-making-it-impossible-to-keep-working/4809887)
- [Studio storage database usage](https://devforum.roblox.com/t/where-is-the-autocomplete-usage-frequency-stored/3466354)
- [PowerShell file enumeration](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/get-childitem?view=powershell-5.1)
- [PowerShell file deletion](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/remove-item?view=powershell-5.1)

Independent utility; not affiliated with Roblox Corporation.
