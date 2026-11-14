# Narvik tests

Two PowerShell suites, no build step and no CI:

| Suite | File | Needs |
| --- | --- | --- |
| Offline unit tests | `Invoke-NarvikUnitTest.ps1` | PowerShell 5.1 or later |
| End-to-end tests | `Invoke-NarvikVcenterTest.ps1` | PowerShell 5.1 or later, PowerCLI, the lab vCenter, a password file, `dsmc_fake.ps1` |

Neither suite is a substitute for a run on Windows Server with the real
`dsmc.exe` or Windows PowerShell 5.1. The gaps are listed at the end.

## Offline unit tests

```powershell
pwsh -NoProfile -File tests/Invoke-NarvikUnitTest.ps1
```

`Narvik.ps1` is a daemon whose entrypoint runs on load, so the suite cannot
dot-source it. It parses the file with the PowerShell AST, extracts the pure
helpers by name and exercises them with synthetic data. Nothing touches vCenter,
`dsmc` or the file system, so the suite runs anywhere PowerShell 5.1 or later is
available.

Exit code `0` means every check passed, `1` means at least one failed. The last
line prints `Unit tests: N passed, M failed.`

## End-to-end tests

```powershell
pwsh -NoProfile -File tests/Invoke-NarvikVcenterTest.ps1 -List
pwsh -NoProfile -File tests/Invoke-NarvikVcenterTest.ps1 -Phase Config
pwsh -NoProfile -File tests/Invoke-NarvikVcenterTest.ps1 -Phase Preconditions,Inventory,Control,Teardown
pwsh -NoProfile -File tests/Invoke-NarvikVcenterTest.ps1 -Phase All
```

Phases always run in the order below, whatever order is given on the command
line:

| Phase | What it covers |
| --- | --- |
| `Preconditions` | Parser, ASCII check, offline unit suite, `dsmc` stand-in, read-only source audit, vCenter connection and version, lab guard rails, storage policy availability. |
| `Inventory` | Read-only inventory collection, counts, tag reasons against live entities, every VM classified, no mutating vCenter task, tag rule on and off. |
| `Control` | `stop.txt`, `abort.txt`, second instance (exit code 3), configuration reload failure keeps the previous config. |
| `Config` | Configuration validation errors. These runs abort before connecting, so this phase works without vCenter. |
| `Fixtures` | Creates the `nk-` test VMs and folders. Needs the vCenter storage policy service. |
| `Tags` | Six-source tag opt-out rule, using fixtures plus tag assignments that already exist in the lab. |
| `Backup` | Incremental backup, `dsmc` command line, management class, preview on and off, Notes untouched. |
| `Full` | Full backup inside the full window, `control/last_full.json`, no repeated Full. |
| `Retry` | `ANS1715E` duplicate-GUID retry, plain failure backoff, one backup per host, `abort.txt` during a backup. |
| `Teardown` | Deletes only `nk-` VMs and folders from the manifest and removes the runtime roots. |

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every selected check passed (skips are allowed). |
| `1` | At least one check failed. |
| `2` | No check failed, but at least one check was blocked (for example the storage policy service is down, so fixtures cannot be created). |

`BLOCK` means a required lab condition is missing and only an operator can
restore it. `SKIP` means the check is outside this lab's permissions or
capabilities; see the gaps below.

### Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Phase` | `All` | Phase names, comma separated, or `All`. |
| `-VcenterServer` | `192.168.122.234` | Lab vCenter address. |
| `-VcenterPort` | `443` | vCenter port. |
| `-VcenterUser` | `administrator@vsphere.local` | vCenter user. |
| `-PasswordFile` | `../narvik_temp/vcenter_password.txt` | File containing the password. |
| `-RunRoot` | `../narvik_test/run` | Directory for the per-phase runtime roots and the fixture manifest. Must be outside the repository. |
| `-TagName` | tag with most assignments | Tag used for the opt-out rule. |
| `-DsmcPath` | `dsmc_fake.ps1` | `dsmc` stand-in. |
| `-TimeoutSeconds` | `300` | Timeout for one daemon wait. |
| `-Keep` | off | Keep the runtime roots and fixtures. |
| `-List` | off | Print the phases and exit. |

The password is read from the file and never printed. On Linux,
`dsmc_fake.ps1` must keep its shebang and executable bit so `Start-Process` can
run it through `pwsh`. On Windows, point `-DsmcPath` at a `.cmd` wrapper:
`Start-Process` cannot run a `.ps1` file directly.

### Guard rails

The suite enforces the same limits the operator set for the lab:

- It may only create, modify and delete **VMs and folders**.
- Everything it creates is named with the `nk-` prefix, and Teardown refuses to
  delete anything without that prefix.
- It never powers a VM on or off. Every fixture VM stays powered off.
- Every fixture disk is at most 1 GiB (`1048576` KB).
- It never creates, modifies or deletes any other entity type: datacenter,
  cluster, host, datastore, datastore cluster, network, resource pool, tag,
  permission, and so on.
- Tags are never created or assigned. Tag coverage uses only assignments that
  already exist in the lab.
- The daemon itself must stay read only. `Preconditions` scans `Narvik.ps1` for
  vCenter write cmdlets and methods and fails if it finds one.

Any of those limits can only be lifted by the operator, explicitly.

### Fixtures and the `dsmc` stand-in

Fixtures are created from `dsmc_fake.ps1` hooks so failures are deterministic:

| Fixture | Purpose |
| --- | --- |
| `nk-e2e-inc` | Incremental backup and preview tests. |
| `nk-e2e-full` | Full backup inside the full window. |
| `nk-e2e-dup_dup` | First incremental attempt returns `ANS1715E`, retry must pass `-VMBACKUPUPDATEGUID -mode IFFull`. |
| `nk-e2e-err_err` | Every attempt fails; checks failure recording and backoff. |
| `nk-e2e-nodisk` | No disk; must be non-eligible. |
| `nk-e2e-size` | One disk of `1048064` KB (1023.5 MiB): at most 1 GiB but not a multiple of 1 MiB; must be non-eligible. |
| `nk-e2e-multi` | Disks span two datastore clusters; must be non-eligible. Created only when the lab has two datastore clusters. |
| `nk-e2e-name[01]` | Name with characters `dsmc` does not accept; must be non-eligible. |
| `nk-e2e-rp`, `nk-e2e-ds`, `nk-e2e-pod`, `nk-e2e-folder` | Tag-rule fixtures, created only when the lab already has a tagged resource pool, datastore, datastore cluster or VM folder that can host them. |

`dsmc_fake.ps1` also reads two environment variables, which the harness sets
only for the run that needs them:

- `DSMC_FAKE_PAUSE_SCALE` scales the simulated work time (`1` is the normal
  duration; the host-concurrency check uses a long run).
- `DSMC_FAKE_RANDOM_FAILURE_PERCENT` injects random failures (`0` disables
  them).

### Runtime roots

Each phase starts the daemon in its own runtime root under `-RunRoot`, for
example `../narvik_test/run/inventory`, `backup-incremental` or
`retry-duplicate`. Those directories, and the whole `-RunRoot` tree, are
removed by `Teardown`; the suite refuses to use a `-RunRoot` inside the
repository.

`Teardown` deletes the VMs and folders recorded in the fixture manifest, and
also sweeps any leftover `nk-` VM or folder that an interrupted run created
before it could record it. If a run is interrupted before `Teardown`, run
`-Phase Teardown` to clean up. `-Keep` is for debugging only and intentionally
leaves the lab dirty for the next run.

## Known gaps and blocked coverage

These are not failures of the suite; they are things this lab cannot currently
prove. Re-run the affected phase once the condition changes.

- **Storage policy service unavailable (`PRECOND-13` BLOCK).** `New-VM` fails
  with `PBM error occurred during PreCreateCheckCallback` when
  `https://192.168.122.234/pbm` is unreachable. In that state `Fixtures`, `Tags`,
  `Backup`, `Full` and `Retry` cannot run; `Config`, `Preconditions`,
  `Inventory`, `Control` and `Teardown` still do. Restoring the service needs a
  vCenter appliance administrator, not a test change. It was down once during
  development (`vmware-sps` stopped) and is available again.
- **Tag creation and assignment were denied.** The rule is verified with
  pre-existing assignments only: the `RP2` resource pool, the `DSC2` datastore
  cluster via `DS3`, and the `DS5`/`vcenter-700g` datastores. VM, folder and
  cluster tag positives stay `SKIP` (`TAGS-14`, `TAGS-15`, `TAGS-16`).
- **No `ClusterComputeResource` exists** in the lab. Creating one needs
  operator approval, so the cluster source of the tag rule has no live
  positive. The helper is covered by the offline unit tests.
- **Tag data unavailable fail-safe (`TAGS-17`).** Breaking the vAPI tag query
  without changing vCenter is not reliable, so the fail-safe path is covered by
  the offline unit tests (`ELIG-01`, `ELIG-02`, `ELIG-07`, `ELIG-08`).
- **Disk size not a multiple of 1 MiB.** `nk-e2e-size` is created with a disk
  of `1048064` KB (1023.5 MiB). `FIX-14` checks that vCenter kept that exact
  capacity instead of rounding it; if it rounds, the check fails with the real
  value so the fixture can be adjusted. Requires the storage policy service.
- **RDM and independent disks.** Creating them needs device or host setup
  outside the allowed VM/folder scope. Covered by unit tests only.
- **SMTP and email alerts.** The lab has no mail server, so alert delivery is
  not exercised; only the configuration validation is.
- **Multiple hosts.** The lab has a single standalone host, so cross-host
  concurrency is not exercised. The same-host rule is verified (`HOST-01` to
  `HOST-03`).
- **Full window on Windows.** The harness reaches the window by passing a
  system time zone through `TZ`. If the platform ignores it and no backup
  starts, the check is reported `SKIP` instead of failing.
- **Windows PowerShell 5.1 and the real `dsmc.exe`.** Neither can be validated
  on this Linux checkout. The suites run on `pwsh` 7 with `dsmc_fake.ps1`; do
  not claim 5.1 or real `dsmc` compatibility was tested.
