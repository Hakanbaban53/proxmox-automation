# proxmox-automation

Zero-touch VM provisioning on Proxmox VE: Terraform-managed golden templates,
cloud-init networking, serial-tagged LVM/XFS data disks, and Ansible
configuration - all on shared NFS storage.

This repository is the companion code for the **Proxmox Automation Series** and
implements the automation described in the Phase 1 field guide
(`docs/phase-1-guide.pdf`), the Phase 2 storage guide
(`docs/phase-2-guide.pdf`), and the Phase 2 addendum
(`docs/phase-2-addendum-guide.pdf`).

## What Phase 1 does

With one `terraform apply`, this repo:

1. Downloads the Ubuntu 26.04 LTS cloud image **through the PVE API**
   (the node itself fetches it - no local `wget` + `qm importdisk` dance).
2. Builds a **golden template VM** on your shared NFS storage.
3. Clones a workload VM with **cloud-init** applied automatically:
   hostname, static IP/gateway/DNS, admin user, SSH public key.
4. Hands the VM over to **Ansible** for first contact (guest agent install,
   management marker file).

## What Phase 2 adds

DB-server storage layout, zero-touch and resize-aware:

1. **Four data disks** (`/var`, `/log`, `/data`, `/backup` roles) declared in
   Terraform with the `serial` attribute - sizes are tfvars knobs, not
   template properties.
2. Ansible `02_storage.yml` turns each serial-tagged disk into
   **PV -> VG -> LV -> XFS -> fstab** mount. The serial is resolved
   fresh on every run from the kernel view (`lsblk` SERIAL column -
   or `/dev/disk/by-id/*-<serial>` where the OS provides it); no
   `/dev/sdb` letter is ever persisted.
3. **Online resize in one move**: grow a size in tfvars -> `terraform apply`
   (API disk resize, no reboot) -> re-run the playbook: `pvresize` ->
   `lvextend --resizefs` -> `xfs_growfs` happen automatically.

The addendum adds three pieces on top, all three field-verified
(guide edition 3; Phase 2 closed):

4. **Single source of truth**: the disk layout lives in
   `ansible/inventory/group_vars/provisioned.yml`; the build playbook and the
   verify playbook read the same list and cannot drift apart.
5. **`03_storage_verify.yml`**: reboots the VM and PROVES the stack came back
   on its own - markers byte-for-byte, mounts mounted, LVs active, fstab
   lines present, serials re-resolved. `verify_reboot=false` skips the
   reboot for a no-downtime check.
6. **Growth workflow**: an optional fifth disk (`scratch01`, tfvars knob
   `scratch_disk_size_gb`) exercises the full attach -> mount path beyond
   the resize chain.

```
 terraform.tfvars: data_disk_size_gb = 20 -> 30
        |
 terraform apply  (online disk resize via PVE API)
        |
 ansible-playbook playbooks/02_storage.yml
        pvresize -> lvextend --resizefs -> xfs_growfs   (all no-ops if nothing grew)
        |
 df -h /srv/data                                    (bigger, zero downtime)
```

```
 you ──► terraform apply ──► PVE API ──► download image ─► build template
                                    │
                                    └──► clone VM ──► cloud-init ──► Ansible
                                         (static IP,   (hostname,    (guest
                                          NFS disk)     user, key)    agent)
```

## Verified versions (August 2026)

| Component   | Version    | Notes                                        |
|-------------|------------|----------------------------------------------|
| Proxmox VE  | 9.2 (>= 8.4 required) | the `import` content type + `import_from` disk import need PVE 8.4+; 8.0-8.3 fails at first apply (see guide ch. 7.2); 8.4 EOLs 2026-08-31, so go 9.x |
| Terraform   | 1.15.x     | `required_version >= 1.6.0`                  |
| bpg/proxmox | ~> 0.111.1 | uses the new `proxmox_download_file` resource |
| Ubuntu      | 26.04 LTS  | amd64v3 image needs x86-64-v3 CPU            |
| Ansible     | core 2.20  | Ubuntu repo package; builtin modules only in Phase 1      |

## Repository layout

```
proxmox-automation/
├── terraform/                  # infrastructure as code
│   ├── versions.tf             # terraform + provider pins
│   ├── providers.tf            # PVE API connection (token, TLS)
│   ├── variables.tf            # every knob, documented
│   ├── template.tf             # image download + golden template
│   ├── vm.tf                   # workload clone + cloud-init
│   ├── outputs.tf              # VMID, IP, ready-to-run ssh command
│   └── terraform.tfvars.example# copy to terraform.tfvars and edit
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml        # community.general + ansible.posix (Phase 2)
│   ├── inventory/
│   │   ├── hosts.yml           # static for Phase 1
│   │   └── group_vars/
│   │       └── provisioned.yml # storage layout: ONE list, two playbooks
│   └── playbooks/
│       ├── 01_first_contact.yml
│       ├── 02_storage.yml      # serial disks -> LVM -> XFS -> fstab
│       └── 03_storage_verify.yml  # reboot + prove boot persistence
├── scripts/
│   ├── pve-bootstrap.sh        # API user + token (run on a PVE node)
│   └── check-cpu-v3.sh         # x86-64-v3 feature check (run on host)
├── docs/
│   ├── phase-1-guide.pdf       # step-by-step field guide (Phase 1)
│   ├── phase-2-guide.pdf       # serial disks + LVM/XFS + resize chain (Phase 2)
│   └── phase-2-addendum-guide.pdf  # group_vars + verify playbook + growth
└── README.md
```

## Quick start

Full walkthroughs: `docs/phase-1-guide.pdf` (provisioning) and
`docs/phase-2-guide.pdf` (storage). Condensed version:

```bash
# 0. On the machine that runs the VMs: verify CPU supports x86-64-v3
./scripts/check-cpu-v3.sh

# 0b. On any PVE node: check the version BEFORE anything else
pveversion    # must be >= 8.4 (9.2 verified). On 8.0-8.3 the first apply
              # dies after 10 min with "content type 'import' is not
              # supported by the Proxmox VE version" - upgrade first:
              #   bookworm pve-no-subscription repo -> apt full-upgrade (8.4)
              #   then sed bookworm->trixie -> apt full-upgrade (9.2)

# 1. On any PVE node: create the terraform API user + token
./scripts/pve-bootstrap.sh

# 2. Enable content types on the NFS storage (Datacenter > Storage):
#    Disk image, Container, Container template, Snippets, Import

# 3. On the control node (enter via `pct enter 900` on a PVE node;
#    the Ubuntu container template has NO default password): install tooling
sudo apt-get update && sudo apt-get install -y ansible
# if "ansible --version" fails with a locale error (minimal container):
sudo apt-get install -y locales && sudo locale-gen en_US.UTF-8 && sudo update-locale LANG=en_US.UTF-8
# terraform (HashiCorp repo; .asc key needs no gpg binary in minimal containers):
sudo wget -qO /usr/share/keyrings/hashicorp.asc https://apt.releases.hashicorp.com/gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.asc] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# 4. Configure and apply
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init
terraform plan
terraform apply

# 5. Ansible first contact
cd ../ansible
ansible provisioned -m ping
ansible-playbook playbooks/01_first_contact.yml

# 6. Phase 2 storage: serial disks -> LVM + XFS (needs the collections;
#    run after first contact so the VM is fully under management)
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/02_storage.yml

# 7. Phase 2 resize demo (online, no reboot):
#    edit terraform/terraform.tfvars -> data_disk_size_gb = 30
cd ../terraform && terraform apply    # ~10 s, disk resize while VM runs
cd ../ansible && ansible-playbook playbooks/02_storage.yml   # grows PV/LV/XFS
df -h /srv/data                        # proof

# 8. Phase 2 addendum: prove the stack survives a reboot
#    (expect a reboot every run; -e verify_reboot=false skips it)
ansible-playbook playbooks/03_storage_verify.yml

# 9. Phase 2 addendum: growth workflow (optional fifth disk)
#    terraform.tfvars: scratch_disk_size_gb = 5  -> terraform apply
#    (an apply may also re-download the cloud image, ~5 min, when
#    upstream re-publishes it; the VM itself is updated in-place)
cd ../terraform && terraform apply
#    then append the scratch01 entry to inventory/group_vars/provisioned.yml
cd ../ansible && ansible-playbook playbooks/02_storage.yml
ssh ubuntu@<vm-ip> "df -h /srv/scratch"   # receipt lives in the guest
#    if 02 reports scratch01 NOT FOUND: on the PVE node run
#    `qm shutdown 200 && qm start 200` (a new disk's serial MAY need a
#    full VM start; field run 1: it appeared immediately), then re-run
```

## Key design decisions

| Decision | Why |
|----------|-----|
| `proxmox_download_file` (not the deprecated `proxmox_virtual_environment_download_file`) | The old resource is removed in provider v1.0 |
| `upload_timeout = 3600` on the download | Provider default 600 s races slow links on an ~820 MB image |
| `disk.import_from` (not `file_id`) | Native PVE 8.4+ `import-from` API option; `file_id` SSHes into the node (`qm disk import`) and API tokens cannot SSH |
| `scsi_hardware = "virtio-scsi-pci"` | Required by Ubuntu cloud images; enables online disk resize (Phase 2) |
| `cpu_type = "x86-64-v3"` | Ubuntu 26.04 amd64v3 images crash on the PVE default `x86-64-v2-Auto` |
| Serial console (`serial_device` + `vga serial0`) | Official cloud-image convention; fixes blank consoles |
| Full clone on NFS | Independent disks, matches production DB-server practice |
| Fixed VMIDs (template 9000, workload 200) | Deterministic references in docs, HA groups and rules; lab VMs keep the low range |
| Native `initialization` block (no custom snippets yet) | No SSH access to PVE nodes required in Phase 1 |
| Guest agent installed by Ansible, not cloud-init | Keeps user-data snippet-free; Ansible is idempotent anyway |
| `agent { wait_for_ip { disabled = true } }` | Cloud images ship without the agent; the provider would otherwise poll it for 15 min (default `agent.timeout`) after start **and on every refresh**. Static-IP design does not need agent IP discovery. Remove the block after Ansible installs the agent if you want `ipv4_addresses` in state |
| Data disks tagged with `serial` (var01/log01/data01/backup01) | `/dev/sdb`-style letters are not stable across reboots/additions; the serial is the disk's identity in the guest, resolved fresh on every playbook run from the kernel view (`lsblk` SERIAL column, or `/dev/disk/by-id/*-<serial>` where the OS provides it), ending the "resize-by-trial-and-error to find which disk is /data" game |
| One VG/LV per disk (`vg_data/lv_data`, `size = 100%VG`) | Resize chain stays unambiguous: disk grows -> its VG grows -> its LV grows; `lvol` + `resizefs: true` runs `lvextend --resizefs` (XFS grows online) |
| `filesystem: fstype=lvm, resizefs: true` per disk | community.general's way to say `pvcreate` (first run) + `pvresize` (every re-run) - the resize chain needs no manual commands |
| Data disk sizes are tfvars, not template properties | The golden template stays lean; per-VM sizes come from the request form (Phase 4) |
| Lab mounts under `/srv/*` | Production DB pattern mounts `/var /log /data /backup`; mounting a fresh FS over a **live** `/var` needs an rsync migration first - noted, deliberately out of lab scope |
| Grow-only storage (`lvol shrink: false`) | The provider hard-errors on disk shrink and XFS cannot shrink; the playbook matches that reality instead of fighting it |
| Storage layout in `group_vars/provisioned.yml`, not playbook `vars:` | One list feeds the build (02) and the verify (03) playbooks; `--extra-vars` can still override for experiments |
| Verify playbook reboots by design (`03_storage_verify.yml`) | fstab entries and LVM activation only prove themselves at boot; "should survive" is a weaker claim than "verified to survive" |
| Fifth disk opt-in via `scratch_disk_size_gb = 0` + dynamic block | Growth stays declarative: the knob removes the disk block entirely when unused; mounting it is an Ansible-side concern (group_vars entry) |

## Troubleshooting

Field-tested failures and their root causes:

| Symptom | Cause | Fix |
|---|---|---|
| Apply dies with `VM convert to template ... you can't convert a template to a template` | A stale VM/template already holds VMID 9000. The provider's create task fails with "already exists", but its retry helper treats that error as *already done* (`vms.go`: `WithAlreadyDoneCheck(ErrorContains("already exists"))`), so the import/convert steps run against the **leftover object** and blow up at conversion | On a PVE node: `qm destroy 9000` (check `qm list \| grep 9000` first). Re-running `terraform apply` self-heals: refresh marks the tainted resource deleted ("Objects have changed outside of Terraform") and recreates it cleanly |
| 02_storage.yml v1 fails with "Expected exactly one device" although `lsblk` shows `SERIAL=var01...` | Field finding (Ubuntu 26.04 guest, virtio-scsi): the kernel reports the serials and `qm showcmd` proves the running QEMU carries them (`serial=var01` on each scsi-hd device), but the guest never materialized `/dev/disk/by-id/*-<serial>` symlinks - v1 depended on them | Fixed in playbook v2: serials are resolved from the kernel view (`lsblk -J`); by-id is no longer required |
| `lsblk -o NAME,SIZE,SERIAL` shows EMPTY serials for the data disks | The running QEMU process predates the serial reaching the VM config - PVE applies `serial` at VM start, not to a disk already attached to a running VM | On a PVE node: `qm shutdown 200 && qm start 200` (full QEMU restart - a guest-OS reboot does not restart QEMU). Confirm with `qm showcmd 200 --pretty \| grep serial`, then re-run the playbook |
| `02_storage.yml`: serial found but the mapping looks wrong | `/dev/sdb` letters vs serial mismatch | `lsblk -o NAME,SERIAL` shows the mapping; the playbook re-resolves serial to device on every run and never persists a `/dev/sdX` name |
| XFS shrink needed | Provider hard-errors on disk shrink; XFS cannot shrink | Grow-only by design; to shrink, migrate data and recreate the disk |
| SSH after a VM rebuild warns `REMOTE HOST IDENTIFICATION HAS CHANGED` | Recreated VM = new host keys (expected with clones from a fresh template) | `ssh-keygen -f ~/.ssh/known_hosts -R 192.168.122.50`, reconnect, accept the new key |
| 02_storage.yml reports `scratch01` (or any NEWLY added disk) NOT FOUND right after `terraform apply` | A newly attached disk's serial MAY reach the guest kernel only at the next FULL VM start (field run 1: it appeared immediately; resizing existing disks is always online) | On a PVE node: `qm shutdown 200 && qm start 200`, then re-run the playbook |
| `terraform apply` announces `1 to destroy` and takes ~5 minutes | Upstream re-published the cloud image; `proxmox_download_file` re-downloads it on size change. The destroy targets the file artifact, NOT the VM (updated in-place) | Harmless; pin the artifact with `overwrite=false` in `template.tf` if you prefer reproducibility |
| `df -h /srv/scratch` on ctrl-01 answers `No such file or directory` | The mount lives in the guest, not on the control node (field footnote from the growth run) | Read the receipt from the guest: `ssh ubuntu@<vm-ip> "df -h /srv/scratch"` |
| 03_storage_verify.yml reboots the VM | By design: that is the test (boot persistence) | Add `-e verify_reboot=false` for a no-downtime check (marker test becomes same-session) |
| `03_storage_verify.yml`: `data_disks is not defined` | Play ran outside the repo's ansible.cfg / inventory, so `group_vars/provisioned.yml` was not loaded | Run from `ansible/` with the repo's `ansible.cfg`, or point `-i inventory/hosts.yml` explicitly |

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Golden template + Terraform clone + cloud-init + first contact | **done, field-verified** (guide: `docs/phase-1-guide.pdf`) |
| 2 | Multi-disk via disk `serial` attribute, LVM + XFS, online resize chain | **done, field-verified end to end, closed** (guide: `docs/phase-2-guide.pdf`; addendum edition 3: `docs/phase-2-addendum-guide.pdf` - group_vars + verify + growth all field-run; growth: 02 `ok=15 changed=5`, 03 `ok=28 changed=2 failed=0` with every device letter rotated at boot) |
| 3 | Agent roles: Zabbix Agent 2, Trend Micro, ManageEngine, rsyslog to QRadar | planned |
| 4 | Semaphore UI form-driven pipeline, dynamic inventory, phone_home | planned |
| 5 | Scale hardening: IPAM, parallelism limits, drift detection | planned |

## Notes for production

- Replace `Administrator` on `/` with a dedicated, narrowly scoped PVE role.
- Set `pve_tls_insecure = false` and install a proper CA chain.
- Move Terraform state to a remote backend (Consul, S3, HTTP) with locking.
- The homelab NAT bridge is not a production VLAN trunk: set `vlan_tag`
  and verify 802.1Q on the physical switch.
