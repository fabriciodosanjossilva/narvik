# Description

Narvik is a backup automation for "IBM Storage Protect for VMWare" on Windows Server.

## Features

- Unattended daemon: runs continuously, no external scheduler needed.
  Stopping is graceful: `stop.txt` lets active backups finish, `abort.txt`
  kills them and exits immediately.
- Automatic inventory: reads VMs, templates, hosts, datastore clusters, VM
  folders, datacenters, datastores and hard disks, using only VMFS datastores;
  other datastore types and non-VM folders are ignored. VM folder paths include
  the datacenter. When the opt-out rule is
  configured, it also reads the assignments of that single tag per entity type
  (VM and template, VMFS datastore, datastore cluster, VM folder, host, cluster
  and resource pool); caches the result for an hour and retries a failed
  collection after a minute, so a flaky vCenter never halts backups for long.
  The cache is refreshed as soon as the configured tag
  changes, so enabling or changing the opt-out rule does not wait for it to
  expire. Narvik only reads from vCenter: it never creates, reconfigures or
  deletes anything there.
- Policy by placement: each datastore cluster maps to an IBM Storage
  Protect management class, so the backup policy follows where the VM lives.
- Incremental backups: backs up any eligible VM whose last incremental
  backup, read from the `<Last Backup (IBM Spectrum Protect)>` block that
  `dsmc` writes to the VM Notes, is older than the nightly 20:00 baseline.
  The block must contain `Status='Successful'`, a `Last Run Time` in
  `MM/DD/YYYY HH:MM:SS` format and a `Type`; line endings are treated as
  spaces. A Full block also counts as the last incremental.
- Automatic full backups: repeats an "Incremental Forever - Full" backup when
  the last full, read from a Notes block whose `Type` ends in `- Full` or
  recorded after a successful full backup, is more than 30 days old, only
  during the off-hours window (weekends or before 08:00) and always oldest
  first; incrementals take priority over fulls.
- dsmc options: `dsmc_opt_file` adds `-optfile=<file>` to the backup command
  and `dsmc_asnodename` adds `-asnodename=<name>`. Both are optional and are
  omitted from the command line when not configured.
- Concurrency control: caps simultaneous `dsmc` processes
  (`max_backup_threads`) and never starts two backups on the same ESXi host
  at the same time.
- Cluster and resource pool priority, with caps: `priority_clusters` assigns
  each ESXi cluster an integer priority from -100 to 100; `priority_resource_pools`
  assigns a priority to a resource pool inside a named cluster; and
  `cluster_max_threads` sets a per-cluster concurrency cap (default 1000).
  Eligible VMs are ordered by cluster priority first, then resource pool
  priority, then the full VM folder path including the datacenter; higher
  priorities come first and negative ones last. VMs outside a cluster or a
  resource pool use priority 0. The per-cluster `max_threads` is an extra limit
  on concurrent backups, on top of the global thread limit and the one-per-host
  rule. Config entries naming a cluster or resource pool that does not exist
  in vCenter are logged and reported by email at most once every 24 hours.
- Failure backoff: a VM that keeps failing is retried with an increasing
  delay (one minute, then quadrupling on every further failure), capped at
  12 hours, instead of hammering the backup server.
- Self-healing: detects dsmc error `ANS1715E` and retries the VM with
  `-VMBACKUPUPDATEGUID` and `-mode IFFull`; a backup only counts as
  successful when `dsmc` exits 0 and reports backed-up objects in its output.
- dsmc error scanning: every line of a finished backup containing an
  `ANS<digits>E` code is logged as a warning, starting at the code and running
  to the end of the line. The critical codes `ANS1030E`, `ANS1706E`,
  `ANS4169E` and `ANS4200E` are also emailed with the timestamp and the VM
  being backed up; the same error type is not emailed again for 6 hours.
- Knows the special cases that snapshot backups cannot serve, and excludes
  (with an alert) VMs that have RDM disks, names unsupported by the backup
  command, duplicate names, disks whose size is not a multiple of 1 MiB,
  disks on a datastore that is not VMFS, or no single datastore cluster with a
  management class mapping. The disk size alert names each affected disk, its
  current size in KiB and the corrected size (rounded up to the next multiple
  of 1 MiB) in KiB, plus the manual command to resize it with
  `Set-HardDisk -capacityKB`. The single cluster is decided from the VM's
  disks: a disk on a datastore outside every datastore cluster, or disks
  spanning more than one cluster, also makes the VM ineligible, while ISO
  images attached to CD/DVD drives are ignored; a VM without disks is not
  eligible.
- Independent disks: eligible VMs that carry independent disks are still
  backed up but trigger an email alert, since snapshots may not capture them
  consistently.
- Opt-out by tag: a configurable vSphere tag (such as
  `NAO_FAZER_BACKUP_POR_SNAPSHOT`) removes a VM from backups when it is on the
  VM itself, its cluster, its resource pool, the host running it, its own VM
  folder or any VMFS datastore or datastore cluster backing its disks; a tag on
  an ancestor folder does not apply, and folders for datastores, hosts, networks
  or other non-VM entities are never read. Tag exclusion is checked before the
  VM's own eligibility rules, so a tagged VM is not reported for unrelated
  reasons
  such as an unsupported name or disk size. Only that tag is read from vCenter,
  and only while the rule is configured. If the rule is configured and the tag
  assignments cannot be read, no VM is backed up rather than risk one the
  operator asked to skip. A configured tag that does not exist in vCenter also
  stops every backup, logged as an error (not emailed) until the tag exists or
  the rule is cleared: silently ignoring the exclusion is never an option.
- VMware Live Site Recovery placeholder VMs are skipped silently.
- Email alerts: duplicate names, inventory rule violations, disk sizes not
  aligned to 1 MiB, independent disks, critical dsmc errors and fatal errors
  are mailed through SMTP (optional SSL and authentication, credentials read
  from files); a fatal exit attaches the full log.
- Monitoring hooks: writes `eligible_count.txt`, `eligible_vms.txt` and
  `pending_count.txt` so external tooling can watch the queue.
- Logs: one log per VM backup plus a daily-rotated main log; the main log is
  checked for write access before the configuration is read, and Narvik exits
  with a fatal error if it cannot be written. Setting `debug` to `true` in the
  configuration enables detailed decision logs
  (inventory cache use, scheduling skips, backoff, full-backup window and
  alert suppression) for troubleshooting.
- Operations friendly: the configuration is re-read every cycle and an
  invalid reload keeps the last good one; a second instance in the same
  runtime root is refused; passwords live in files, not in the config; and
  the daemon ships in preview mode so nothing is actually backed up until
  the operator opts in.
