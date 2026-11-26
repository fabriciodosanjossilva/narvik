# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Narvik is a PowerShell daemon that automates VM snapshot backups to IBM Storage Protect
(dsmc) for VMs living on a VMware vCenter. It runs continuously on Windows Server 2019,
polling vCenter via PowerCLI, deciding which VMs need a backup, and launching/monitoring
`dsmc.exe` child processes.

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
- The root directory must already exist; Narvik never creates it. Below it Narvik creates
  its runtime layout, each folder only when its step runs: `log/narvik/` (main log +
  daily-rotated `old/` subfolders) when the log opens, `control/` (process lock) after the
  log is open, `log/vm/` (one log per VM backup) on the first backup, and `monitoring/`
  (status files for external tooling) after the state is loaded. Plus `config.json`
  and password files (`vcenter_password.txt`, SMTP password file) read from that same
  root. `config.example.json` at the repo root is a template for that `config.json`, not
  something the script reads directly.
- Operator control files, placed directly in the root directory while the daemon is
  running: `stop.txt` (graceful — finish active backups, then exit) and `abort.txt`
  (immediate — kill active backups and exit). Both are deleted by Narvik once acted on.
  `suspend.txt` blocks the start of new backups (incremental and full) while active ones
  continue; it is never deleted by Narvik — the operator removes it to resume.
- There is no test runner. `dsmc_path` in `config.json` is either an absolute path or a
  path relative to the root directory, and must point to an existing `.exe` file. Narvik
  runs `dsmc` with its own folder as the working directory (set on the child process only).
- `dsmc_use_preview: true` in config (the shipped default) makes Narvik pass `-preview`
  to dsmc so nothing is actually backed up — safe default for trying the daemon against
  a real vCenter.

## Testing against a real vCenter

**The vCenter reachable from the development machine is PRODUCTION. Do not change anything
on it.** No VM, datastore, tag, folder, resource pool, note, permission, power state or
configuration may be created, modified, moved or deleted, not even temporarily. Use only
read calls (`Get-*`, `Get-View` without side effects, `Get-TagAssignment`, `Connect-VIServer`
and `Disconnect-VIServer`). Do not run `Set-*`, `New-*`, `Remove-*`, `Move-*`, `Start-*`,
`Stop-*`, `Restart-*`, `Invoke-*`, `Set-PowerCLIConfiguration` with side effects on the
server, or any `dsmc` backup against it. Run the daemon end to end only against a
non-production vCenter.

Read-only probes and before/after comparisons against a real vCenter work from the
development machine. Use placeholders below (`<runtime-root>`, `<vcenter-host>`,
`<user>`); never write real hostnames, users or passwords into the repo.

- The runtime root (`<runtime-root>`, outside the repo) holds `config.json` and the
  password file named by `vcenter_password_file`. Read `vcenter_server`,
  `vcenter_port` and `vcenter_user` from `config.json`. Read the password file's trimmed
  contents into memory only; never print or log it.
- Connection, as the code does it (PowerCLI 13.x):
  `Import-Module VMware.VimAutomation.Core`,
  `Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Fail -Confirm:$false`,
  then `New-Object PSCredential(user, ConvertTo-SecureString $pw -AsPlainText -Force)` and
  `Connect-VIServer -Server ... -Port ... -Credential ...`. Finish with
  `Disconnect-VIServer -Server * -Confirm:$false`.
- Run probes from a script file under `$env:TEMP`, with `powershell -NoProfile
  -ExecutionPolicy Bypass -File <script>`. Keep probe scripts out of the repo. Piping a
  here-doc into `powershell -Command -` silently produced no output in some runs, so do
  not rely on it.
- Before/after comparison of an inventory change: dot-source `lib/Narvik.*.ps1` in the
  same order as `Narvik.ps1`, set `$script:RootPath`, `$script:Config`
  (`Import-NarvikConfig -Path <runtime-root>\config.json`), `$script:LogLevel = 'DEBUG'`,
  and stub `Save-NarvikLastFull` and `Write-NarvikMonitoringFiles` as no-ops so nothing
  is written to the runtime root. Then call `Get-NarvikVCenterData`, set
  `$script:VCache` to its result, call `Update-NarvikEligibility`, and dump VMs, disks,
  `$script:EligibleVMs` and `$script:NonEligibleVMs` to JSON. Diff the two dumps.
  Expect differences in live fields (`HostName` after vMotion, `Notes`/`LastBackup`
  after a backup) that are unrelated to the change; eligibility should match.
- Reference measurements (1,609 VMs, 39 templates, 7,443 disks, 1,080 VM folders,
  135 datastores, 38 datastore clusters): `Get-VM` ~1 s, `Get-HardDisk -VM` ~3–6 s,
  `Get-TagAssignment` per entity type ~0.2–0.5 s, whole `Get-NarvikVCenterData` ~42 s
  after the batched reads below (it was ~90–105 s before).

Performance rule learned from measurement: a property read through `.ExtensionData`,
or a navigation property such as a folder's `.Parent`, is loaded lazily, with one vCenter
round trip per object (~35–40 ms each here). Inside an inventory loop that costs
minutes. Prefer:
- the `*Id` properties that PowerCLI already has (`Folder.ParentId`, `FolderId`,
  `ResourcePoolId`, `VMHostId`), which are read without a round trip;
- one `Get-View -ViewType <Type> -Property <paths>` call for everything else, indexed by
  `MoRef.Value`. Always include an always-set property such as `Config.Name` alongside
  `Config.ManagedBy`/`Config.Annotation`. Without it, vCenter omits the `config` object
  for VMs with neither ManagedBy nor Annotation, and `Config` comes back `$null`.

Measure a change with the `DEBUG` timing lines already in `Get-NarvikVCenterData`
(`VM candidates read`, `VM processing finished`, `vCenter inventory collection total`)
before and after.

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
- `Initialize-Narvik`: resolves and validates `RootPath` (must exist; not created), sets the
  directory paths (`Set-NarvikDirectoryPaths`, no folders created), runs the read-only part
  of the single-instance check (`Test-NarvikProcessLockFree`, before the log so a second
  instance cannot rotate the running instance's log), reads and validates config
  (`Update-NarvikRuntimeConfig`, before the log exists: an invalid config is fatal on stdout
  and does not rotate the old log), opens the log (`Initialize-NarvikLog`, which creates
  `log/narvik/` and `old/` and copies the stdout lines buffered in `$script:StartupLog` into
  it), creates `control/` and writes the lock (`Write-NarvikProcessLock`, a second instance
  is refused), loads persisted state (`Load-NarvikState`/`Load-NarvikLastFull`/
  `Load-NarvikIndependentDisks`), creates `monitoring/`, checks administrator privilege if
  configured, and imports PowerCLI.
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
  (`Test-NarvikHostActive`), and failure backoff (`Test-NarvikBackoffActive`). All
  these checks live in `Test-NarvikVmAllocable`. If the strict pass (one backup per
  host) finds nothing, a fallback pass repeats the checks with the host rule relaxed,
  allowing up to `$script:SharedHostMaxBackups` (4, set in `Narvik.ps1`) running
  backups per host in total.

Backup execution:
- `Start-NarvikBackupJob` builds the `dsmc backup vm` command line (quoting via
  `Quote-NarvikWindowsArgument`, optional `-optfile`/`-asnodename`/`-VMBACKUPUPDATEGUID`/
  `-mode IFFull`) and launches it as a background job, logging to a per-VM file under
  `log/vm/`.
- `Complete-NarvikJobs`/`Read-NarvikJobOutput`/`Invoke-NarvikAnsErrorScan` monitor
  running jobs, scan output for `ANS<digits>E` codes, and determine success purely from
  exit code 0 plus "backed-up objects" appearing in the output. `ANS1715E` triggers the self-healing
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
