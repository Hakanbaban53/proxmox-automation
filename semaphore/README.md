# Semaphore wiring - the request form and its plumbing

This directory documents the Semaphore side of Phase 4: how the UI on
**sem-01** (CT 901, 192.168.122.21) is wired to this repository so that a
VM request becomes a running, agented, verified VM with **one form
submission**. The step-by-step (screens-level) walkthrough lives in the
Phase 4 guide (`docs/phase-4-semaphore-guide.pdf`); this file is the
compact reference you keep next to the UI.

## Why Semaphore (the Phase 4 decision, in one paragraph)

The original plan was a custom web UI. Two findings redirected it:
AWX's last stable release is 24.6.1 from **July 2024** (releases paused
during a large-scale refactoring, verified 28 Aug 2026) while Semaphore
ships every 1-2 weeks (v2.19.11: 27 Aug 2026) - and Semaphore's survey
variables turned out to be TYPED forms (string / integer / enum /
multiline text / secret), which covers everything the request form needs.
The wheel already exists and it is round; we stopped inventing it.

## The objects (created once, in the UI)

| Semaphore object | Name | Content |
|---|---|---|
| Key Store | `deploy-key` | the private half of `/home/semaphore/.ssh/id_ed25519` on sem-01 (its public half is authorized for `git` on ctrl-01 AND injected into every new VM by cloud-init) |
| Repository | `proxmox-automation` | `ssh://git@192.168.122.10/srv/git/proxmox-automation.git`, access key `deploy-key`, branch `main` |
| Inventory | `provisioning` | the content of `ansible/inventory/provisioning.yml` (localhost + EMPTY `provisioned` group - the deploy play fills it at runtime) |
| Variable Group | `proxmox-lab` | the JSON from `env/proxmox.env.example` (the four PROXMOX_* variables). v2.19 note (field finding #8, 29 Aug): Variable Group JSON values reach the playbook as EXTRA-VARS, not process env vars - so `vars/lab-environment.yml` reads each secret as env-var OR extra-var, and either delivery path feeds the pipeline |
| Task Template | `Deploy VM` | Ansible, playbook `ansible/playbooks/deploy_vm.yml`, inventory + variable group above, survey below |

## The form (survey variables on "Deploy VM")

| Field | Type | Values / example | Notes |
|---|---|---|---|
| `vm_profile` | enum | `db-standard`, `web-small`, `app-medium`, `custom` | the preset layer - most requests stop here |
| `vm_hostname` | string | `vm-app-01` | lowercase DNS-safe; doubles as the PVE VM name |
| `vm_ip` | string | `192.168.122.60` | dotted IPv4, no CIDR |
| `vm_vlan` | integer | `0` | 0 = untagged |
| `vm_vcpu` | enum | `2`, `4`, `8`, `16`, `32` | custom profile only; others ignore it |
| `vm_ram_gb` | enum | `4`, `8`, `16`, `32`, `64`, `128` | custom profile only |
| `vm_disks` | text (multiline) | see below | custom disks; overrides the profile's list |

Why enums for vCPU/RAM instead of free numbers: the form can only offer
what the pipeline allows. "Customer wants 7 vCPU" is a conversation, not
a form value - and the assert in 00_provision_vm.yml re-checks every
value server-side because `--extra-vars` and the API bypass the form.

The `vm_disks` JSON (the only free-form field, custom requests only):

```json
[
  {"role": "data",   "size_gb": 1024},
  {"role": "log",    "size_gb": 50},
  {"role": "backup", "size_gb": 500}
]
```

Allowed roles: `var`, `log`, `data`, `backup`, `app`, `scratch`. The
serials (`data01`, ...), VGs (`vg_data`), LVs and mount points
(`/srv/data`) are DERIVED from the role - they cannot be mistyped in the
form because they are never typed in the form.

## What one form submission runs

`deploy_vm.yml` chains the phase playbooks in order; a green run ends
with the delivery checklist (07), whose receipt line is the handover
record:

```
00  clone + cloud-init + serial disks   (Proxmox API, no Terraform)
01  first contact: guest agent, marker
02  storage: serial -> PV/VG/LV/XFS/mount      (skips itself: no disks)
04  Zabbix Agent 2
05  rsyslog -> QRadar pattern (disk-assisted queue)
06  security agents (marker contract)
07  delivery checklist - mounts up, services active, ESTAB, tagged message
```

The audit story: Semaphore keeps every task - who launched it, when,
with which form values, full output. That is the "kim, ne zaman, hangi
parametreler" record the manual process never had.

## Separate templates worth creating

- **"Health Audit" (Phase 5b)** - playbook `ansible/playbooks/08_health_audit.yml`, the SAME inventory (`provisioning`) and environment (`proxmox-lab`) as "Deploy VM", **no survey**. It is the morning/evening health check: cluster quorum, node pressure, fleet budget, the `pipeline-managed` fleet, drift against its own baseline, guest services/filesystems over SSH - and a digest that is ALWAYS printed to the task log, plus mailed when msmtp is configured (one-time setup: `scripts/sem-01-msmtp.sh`, then set `audit_mail_from`/`audit_mail_to` in `vars/lab-environment.yml`). Run it once manually before scheduling; the first run establishes the baseline (`INFO` lines only), so expect a green task with a digest in the log. **Scheduling**: create the schedule for 07:00 and 19:00 - check the project sidebar for the schedule feature on this instance (v2.19.11); if the UI has none, a host crontab on sem-01 hitting the tasks API is the fallback (verify the exact POST schema against the swagger at `/api/` first). Check `date` on sem-01: cron times are server-local (add +3h if the server runs UTC and the digests should arrive at Turkish 07:00/19:00).
- **"Storage verify (reboot)"** - playbook `ansible/playbooks/03_storage_verify.yml`, inventory `maintenance` (vm-test-01 and known VMs), no survey. Proves fstab/LVM survive a boot; run on demand, not in the deploy chain (it reboots the VM).
- **"Resize data disk"** (Phase 4d) - will wrap the two-command resize chain: `proxmox_disk state=resized` + re-run of 02_storage.yml (pvresize -> lvextend --resizefs). Survey: hostname, serial, new size.

Reading an audit run: the task ends **red when a CRITICAL or WARN finding exists** - that is the design ("a human should read the digest"), not a crash. The digest text is in the log either way; pure-INFO runs (drift lines, first-baseline notes) end green. The baseline file lives at `$HOME/proxmox-audit-baseline/fleet.yml` under the user Semaphore runs ansible as - delete it to reset drift detection to a first run.

## The task queue, observed (Phase 5c field finding)

Semaphore v2.19.11 runs **one task at a time** - there is no parallelism
knob in the UI or the docs. Field-proven 30 Aug 2026: two Deploy VM
submissions back to back did not race; the second sat in the queue and was
then refused at the admission gate reading the first's committed state
(exact live budget math). A Health Audit fired mid-deploy likewise started
only after the deploy's tail (reconstructed from task-internal timestamps).
Two consequences:

- The admission gate's check-then-act window is **unreachable from the
  UI** - the queue is an accidental mutex. The race stays reachable only
  via CLI/API (two `ansible-playbook` processes), which is why a post-apply
  re-verify stays optional defense-in-depth for production, not a lab
  requirement.
- A long deploy queues **everything** behind it, scheduled audits included
  - the morning/evening digest waits out a running deploy. Acceptable in
  the lab; plan maintenance windows in production.

## Security notes (lab now, habits for later)

- The Proxmox token lives in the Semaphore Variable Group (`proxmox-lab`), marked secret - not in git, not in task output. After a rotation (see the Phase 4 guide, chapter 5): update the `PROXMOX_TOKEN_SECRET` value here FIRST - it is the live pipeline consumer; `terraform.tfvars` copies are hygiene, needed only if Terraform runs again.
- One keypair currently does two jobs (git access + VM login). Acceptable in the lab; the split - separate `repo-key` and `vm-key` entries in the Key Store - is a 5-minute change when this leaves the lab.
- sem-01's admin password is generated at install time (printed once by `sem-01-setup.sh`); change it on first login. LDAP/OIDC are available under Administration when a second operator joins.
