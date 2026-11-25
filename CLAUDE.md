# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Narvik is a PowerShell daemon that automates VM snapshot backups to IBM Storage Protect
(dsmc) for VMs living on a VMware vCenter. It runs continuously on Windows Server 2019,
polling vCenter via PowerCLI, deciding which VMs need a backup, and launching/monitoring
`dsmc.exe` child processes. `dsmc_fake.ps1` is a stand-in for the real `dsmc.exe` used for
local/manual testing without IBM Storage Protect or a real backup target.

`Narvik.ps1` is a thin entry point: it declares the shared `$script:`-scoped state, dot-
sources every file under `lib/Narvik.*.ps1` (resolved from `$PSScriptRoot`, so the whole
folder must be deployed together), and runs the top-level `try/catch/finally` that calls
`Initialize-Narvik` then `Invoke-NarvikMain`. All ~90 functions live in `lib/`, grouped by
concern — see Architecture below. There are no modules/classes in the PowerShell sense;
every file is dot-sourced into the same script scope, so `$script:`-scoped variables
(config, vCenter cache, active jobs, per-VM state, alert-suppression timestamps, etc.)
are shared across all of them exactly as if the code were still one file. Because
PowerShell resolves function calls at invocation time rather than at parse time, a
function in one `lib/` file can freely call a function defined in another regardless of
dot-source order — the only requirement is that every file is sourced before
`Invoke-NarvikMain` runs. Grouping into files is therefore about readability, not a
dependency order to preserve when editing.

There is no build system, package manager, or automated test suite in this repo — it's
plain PowerShell. `README.md` is the authoritative, very detailed description of
behavior (backup eligibility rules, scheduling, alerting, error handling); read it before
changing logic, since the exact wording there (error codes, thresholds, precedence rules)
is the spec.

## Running / exercising the code

- Requires Windows PowerShell 5.1+ and the `VMware.VimAutomation.Core` PowerCLI module
  (checked and imported at startup; the script throws a fatal error and exits if either
  is missing).
- Entry point: `Narvik.ps1 <directory>` (positional). `RootPath` is mandatory but not
  declared `Mandatory` in the param block on purpose — a missing value must go through
  the normal fatal-error/stdout path (`Throw-NarvikFatal`), not PowerShell's interactive
  prompt.
- The root directory is where Narvik creates its runtime layout: `control/` (process
  lock), `log/narvik/` (main log + daily-rotated `old/` subfolders), `log/vm/` (one log
  per VM backup), `monitoring/` (status files for external tooling), plus `config.json`
  and password files (`vcenter_password.txt`, SMTP password file) read from that same
  root. `config.example.json` at the repo root is a template for that `config.json`, not
  something the script reads directly.
- Operator control files, placed directly in the root directory while the daemon is
  running: `stop.txt` (graceful — finish active backups, then exit) and `abort.txt`
  (immediate — kill active backups and exit). Both are deleted by Narvik once acted on.
- There is no test runner. To exercise the daemon manually, point `dsmc_path` in
  `config.json` at `dsmc_fake.ps1` instead of the real `dsmc.exe`. Read the large header
  comment in `dsmc_fake.ps1` first — it documents the exact fake behavior (which VM-name
  substrings trigger failures, duplicate-GUID retries, critical errors, random failures,
  Notes-block updates) and the environment variables that control timing/determinism for
  automated runs (`DSMC_FAKE_PAUSE_SCALE`, `DSMC_FAKE_RANDOM_FAILURE_PERCENT`,
  `DSMC_FAKE_RUNTIME_ROOT`).
- `dsmc_use_preview: true` in config (the shipped default) makes Narvik pass `-preview`
  to dsmc so nothing is actually backed up — safe default for trying the daemon against
  a real vCenter.

## Architecture

Functions are named `Verb-NarvikNoun` (all prefixed `Narvik`) and split across `lib/` by
concern — logging/path/ACL primitives (`Narvik.Core.ps1`), config loading/reload
(`Narvik.Config.ps1`), JSON state persistence (`Narvik.State.ps1`), log/directory/process-
lock bootstrap (`Narvik.Startup.ps1`), SMTP alerting (`Narvik.Mail.ps1`), PowerCLI
inventory collection and caching (`Narvik.VCenter.ps1`), eligibility rules and their
config-derived accessors (`Narvik.Eligibility.ps1`), the `Send-Narvik*Alerts` functions
(`Narvik.Alerts.ps1`), backup scheduling (`Narvik.Scheduling.ps1`), `dsmc` job execution
and monitoring (`Narvik.Backup.ps1`), and the daemon's main loop
(`Narvik.MainLoop.ps1`). The sections below walk through the actual call flow across
these files.

Startup/shutdown:
- `Initialize-Narvik`: resolves and validates `RootPath`, sets up directories, acquires
  a single-instance process lock (`Acquire-NarvikProcessLock` — a second instance in the
  same root is refused), opens the log, loads persisted state
  (`Load-NarvikState`/`Load-NarvikLastFull`/`Load-NarvikIndependentDisks`), reads
  config, checks administrator privilege if configured, and imports PowerCLI.
- `Invoke-NarvikMain`: the daemon's `while ($true)` loop, polling every 10 seconds. Each
  iteration: handle control files → reload config
  (`Update-NarvikRuntimeConfig`, re-read every cycle; an invalid reload keeps the last
  good config) → refresh/consult the vCenter inventory cache
  (`Update-NarvikVCenterCache`) → recompute eligibility when the cache refreshed
  (`Update-NarvikEligibility`) → reap finished jobs (`Complete-NarvikJobs`,
  `Read-NarvikJobOutput`) → start new backups up to `max_backup_threads`
  (`Select-NarvikNextBackup` + `Start-NarvikBackupJob`) → write monitoring/stats files.
- The outer `try/catch/finally` around `Initialize-Narvik`/`Invoke-NarvikMain` is the
  only top-level error boundary: any uncaught exception becomes a fatal exit that logs
  the stack trace, stops active jobs, and emails the full log
  (`Send-NarvikFatalEmail`), and `finally` always kills stray child processes and
  releases the process lock.

Inventory and eligibility:
- `Get-NarvikVCenterData` (the largest function, ~800 lines) walks vCenter via PowerCLI
  to build the inventory snapshot: VMs/templates, hosts, clusters, resource pools,
  datastore clusters, VM folders (with full path including datacenter), VMFS datastores,
  and disks — plus, when the opt-out tag rule is configured, the tag assignments needed
  to apply it. This result is cached for an hour (`Update-NarvikVCenterCache`) and
  retried on failure after a minute, so a flaky vCenter doesn't stall backups; a tag-rule
  change invalidates the cache early.
- `Update-NarvikEligibility` turns that inventory into `$script:EligibleVMs` /
  `$script:NonEligibleVMs` / `$script:PendingVMs`, applying the exclusion rules
  documented in `README.md` (RDM disks, unsupported/duplicate names, disk size not a
  multiple of 1 MiB, non-VMFS datastore, ambiguous/missing datastore-cluster-to-mgmt-class
  mapping, opt-out tag) and sends the associated alert emails
  (`Send-Narvik*Alerts` functions) with per-category suppression windows tracked in
  `$script:State`.
- `Select-NarvikNextBackup` orders pending VMs by cluster priority, then resource pool
  priority, then full folder path, respecting per-cluster thread caps
  (`Test-NarvikClusterAtCapacity`), the one-backup-per-ESXi-host rule
  (`Test-NarvikHostActive`), and failure backoff (`Test-NarvikBackoffActive`).

Backup execution:
- `Start-NarvikBackupJob` builds the `dsmc backup vm` command line (quoting via
  `Quote-NarvikWindowsArgument`, optional `-optfile`/`-asnodename`/`-VMBACKUPUPDATEGUID`/
  `-mode IFFull`) and launches it as a background job, logging to a per-VM file under
  `log/vm/`.
- `Complete-NarvikJobs`/`Read-NarvikJobOutput`/`Invoke-NarvikAnsErrorScan` monitor
  running jobs, scan output for `ANS<digits>E` codes, and determine success purely from
  exit code 0 plus "backed-up objects" appearing in the output — matching the logic
  `dsmc_fake.ps1` emulates for testing. `ANS1715E` triggers the self-healing
  duplicate-GUID retry (`Set-NarvikDuplicateGuid` → next attempt adds
  `-VMBACKUPUPDATEGUID -mode IFFull`).
- Last-backup timestamps are read back from the VM's vCenter Notes field
  (`ConvertFrom-NarvikVmNotes`, parsing the `<Last Backup (IBM Spectrum Protect)>`
  block), not from local state — local state (`$script:State`, `$script:LastFull`,
  `$script:IndependentDisks`) only tracks failure backoff, duplicate-GUID flags, alert
  suppression timestamps, and independent-disk tracking, persisted as JSON under the
  root directory.

When changing eligibility, scheduling, or alerting logic, cross-check the relevant
bullet in `README.md` first — it specifies exact thresholds, formats (e.g. the Notes
block's date format and required fields), and precedence rules (e.g. tag exclusion is
checked before other eligibility rules) that the implementation must match exactly.
