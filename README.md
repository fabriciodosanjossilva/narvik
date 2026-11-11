# Description

Narvik is a backup automation for "IBM Storage Protect for VMWare" on Windows Server.

## Features

- Unattended daemon: runs continuously, no external scheduler needed.
  Stopping is graceful: `stop.txt` lets active backups finish, `abort.txt`
  kills them and exits immediately.
- Automatic inventory: collects VMs, hosts, datastores, datastore clusters
  and tags from vCenter, caches the result for an hour and retries a failed
  collection after a minute, so a flaky vCenter never halts backups for long.
- Policy by placement: each datastore cluster maps to an IBM Storage
  Protect management class, so the backup policy follows where the VM lives.
- Incremental backups: backs up any eligible VM whose last backup, read from
  the timestamp `dsmc` writes to the VM Notes, is older than the nightly
  20:00 baseline.
- Automatic full backups: repeats an "Incremental Forever - Full" backup when
  the last one is more than 30 days old, only during the off-hours window
  (weekends or before 08:00) and always oldest first; incrementals take
  priority over fulls.
- Concurrency control: caps simultaneous `dsmc` processes
  (`max_backup_threads`) and never starts two backups on the same ESXi host
  at the same time.
- Failure backoff: a VM that keeps failing is retried with an increasing
  delay, capped at 12 hours, instead of hammering the backup server.
- Self-healing: detects dsmc error `ANS1715E` and retries the VM with
  `-VMBACKUPUPDATEGUID` and `-mode IFFull`; a backup only counts as
  successful when `dsmc` exits 0 and reports backed-up objects in its output.
- Knows the special cases that snapshot backups cannot serve, and excludes
  (with an alert) VMs that have RDM disks, names unsupported by the backup
  command, duplicate names, or no single datastore cluster with a management
  class mapping. The single cluster is decided from the VM's disks: a disk on
  a datastore outside every datastore cluster, or disks spanning more than
  one cluster, also makes the VM ineligible, while ISO images attached to
  CD/DVD drives are ignored; a VM without disks is not eligible.
- Independent disks: eligible VMs that carry independent disks are still
  backed up but trigger an email alert, since snapshots may not capture them
  consistently.
- Opt-out by tag: a configurable vSphere tag (such as
  `NAO_FAZER_BACKUP_POR_SNAPSHOT`) on a VM, datastore or datastore cluster
  removes it from backups.
- VMware Live Site Recovery placeholder VMs are skipped silently.
- Email alerts: duplicate names, inventory rule violations, independent
  disks and fatal errors are mailed through SMTP (optional SSL and
  authentication, credentials read from files); a fatal exit attaches the
  full log.
- Monitoring hooks: writes `eligible_count.txt`, `eligible_vms.txt` and
  `pending_count.txt` so external tooling can watch the queue.
- Logs: one log per VM backup plus a daily-rotated main log.
- Operations friendly: the configuration is re-read every cycle and an
  invalid reload keeps the last good one; a second instance in the same
  runtime root is refused; passwords live in files, not in the config; and
  the daemon ships in preview mode so nothing is actually backed up until
  the operator opts in.
