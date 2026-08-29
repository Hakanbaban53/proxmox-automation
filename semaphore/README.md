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
| Environment | `proxmox-lab` | the JSON from `env/proxmox.env.example` (the four PROXMOX_* variables) |
| Task Template | `Deploy VM` | Ansible, playbook `ansible/playbooks/deploy_vm.yml`, inventory + environment above, survey below |

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

- **"Storage verify (reboot)"** - playbook `ansible/playbooks/03_storage_verify.yml`, inventory `maintenance` (vm-test-01 and known VMs), no survey. Proves fstab/LVM survive a boot; run on demand, not in the deploy chain (it reboots the VM).
- **"Resize data disk"** (Phase 4d) - will wrap the two-command resize chain: `proxmox_disk state=resized` + re-run of 02_storage.yml (pvresize -> lvextend --resizefs). Survey: hostname, serial, new size.

## Security notes (lab now, habits for later)

- The Proxmox token lives in the Semaphore Environment, marked secret - not in git, not in task output.
- One keypair currently does two jobs (git access + VM login). Acceptable in the lab; the split - separate `repo-key` and `vm-key` entries in the Key Store - is a 5-minute change when this leaves the lab.
- sem-01's admin password is generated at install time (printed once by `sem-01-setup.sh`); change it on first login. LDAP/OIDC are available under Administration when a second operator joins.
