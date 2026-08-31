# proxmox-automation

Zero-touch VM delivery on Proxmox VE: Ansible-native provisioning of
golden-template clones (Phase 4; Terraform through Phase 3), cloud-init
networking, serial-tagged LVM/XFS data disks, the full agent layer, and a
Semaphore UI request form - all on shared NFS storage.

This repository is the companion code for the **Proxmox Automation Series** and
implements the automation described in the Phase 1 field guide
(`docs/phase-1-guide.pdf`), the Phase 2 storage guide
(`docs/phase-2-guide.pdf`), the Phase 2 addendum
(`docs/phase-2-addendum-guide.pdf`), the Phase 3 agents guide
(`docs/phase-3-agents-guide.pdf`, edition 3: field-verified twice -
standalone 28 Aug 2026 and inside the pipeline 29 Aug 2026),
and the Phase 4 delivery guide (`docs/phase-4-semaphore-guide.pdf`,
edition 2: the plan round of 28 Aug plus the 29 Aug pipeline
campaign, findings #7-#19 and run #37's first full green with its
receipts), and the Phase 5 hardening guide
(`docs/phase-5-hardening-guide.pdf`: the admission gate's four
field-proven branches, the health audit with its baseline, mailed
digest and scheduler, and the queue-as-mutex concurrency findings,
all closed 30 Aug 2026).

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

## What Phase 3 adds

The agent layer, delivered as three more numbered playbooks (all
ansible.builtin, `requirements.yml` unchanged):

1. **`04_zabbix_agent.yml`** - Zabbix Agent 2 from the official repo,
   pinned to the 7.0 LTS major (the only current major publishing
   Ubuntu 26.04 packages; live-checked). The playbook reads the apt
   version election back (`apt policy`) and asserts the agent really
   came from repo.zabbix.com, then verifies service, port, a local
   `zabbix_agent2 -t agent.version` metric and the rendered config.
2. **`05_rsyslog_forward.yml`** - rsyslog (the 26.04 cloud image ships
   it; the install task is a zero-cost guard) plus an `omfwd`
   forwarding rule in the QRadar pattern: TCP, disk-assisted queue,
   retry forever. Validates the config with
   `rsyslogd -N1` and smoke-tests the path with a tagged `logger`
   message.
3. **`06_security_agents.yml`** - Trend Micro and ManageEngine as
   **stub installers behind a marker contract**: the harness (dirs,
   script, one-shot execution, verification, drift alarm) is real,
   the payload is an echo until the licenses arrive.

All knobs live in `ansible/playbooks/vars/agent-layer.yml`, loaded by
plays 04/05/06/07 via `vars_files` - one source of truth for BOTH run
modes: static CLI runs against the repo inventory AND deploy runs through
Semaphore's own generated inventory, where the repo's `group_vars` never
loads (field finding #18, run #31). Lab stand-ins: ctrl-01 is both the log
receiver (one socat
line, port 5514 - run it under `nohup`, it dies with its SSH session
otherwise; field-proven) and the polling host for `zabbix-get`
(add the official 7.0 repo to ctrl-01 first: universe has no
zabbix-get package for 26.04); an optional one-LXC Zabbix server
recipe is in the guide.

## What Phase 4 adds

The delivery pipeline: one form submission on a ready-made UI, no custom
web app to maintain, no Terraform state file either.

1. **Ansible-native provisioning** (`00_provision_vm.yml`): clone + specs
   + cloud-init + serial-tagged data disks through `community.proxmox`
   alone (proxmox_kvm / proxmox_disk / proxmox_vm_info, collection 2.0.0).
   Terraform is retired to `terraform/` for reference - the state-file
   dance with externally-deleted VMs is over.
2. **Profiles** (`playbooks/vars/profiles.yml`): `db-standard`,
   `web-small`, `app-medium`, `custom` - the preset layer of the request
   form. Disk serials/VGs/LVs/mounts are DERIVED from the role, so the
   form cannot mistype them.
3. **Semaphore UI** on its own LXC (sem-01, `scripts/create-sem-01.sh` +
   `sem-01-setup.sh`): typed survey form (enum/integer/text), full task
   audit (who/when/which values/output), job history. Why not AWX: its
   last stable release is 24.6.1 from July 2024 (releases paused during
   a large-scale refactoring - verified 28 Aug 2026); Semaphore ships
   every 1-2 weeks (v2.19.11: 27 Aug 2026).
4. **The delivery gate** (`07_delivery_check.yml`): mounts up, agents
   active, forwarding ESTABLISHED, a tagged `faz4-<hostname>` test
   message - green output IS the handover record.

```
 engineer ──► Semaphore form (profile, hostname, IP, VLAN, disks JSON)
                │
                ▼  deploy_vm.yml (one chain, one audit record)
   00 clone+cloud-init+serial disks ──► 01 guest agent ──► 02 LVM/XFS
   ──► 04 Zabbix ──► 05 rsyslog->QRadar ──► 06 Trend/ME stubs ──► 07 gate
                                                                    │
     VM delivered ◄── green receipt ─────────────────────────────────┘
```

## Verified versions (August 2026)

| Component   | Version    | Notes                                        |
|-------------|------------|----------------------------------------------|
| Proxmox VE  | 9.2 (>= 8.4 required) | the `import` content type + `import_from` disk import need PVE 8.4+; 8.0-8.3 fails at first apply (see guide ch. 7.2); 8.4 EOLs 2026-08-31, so go 9.x |
| Terraform   | 1.15.x     | `required_version >= 1.6.0`                  |
| bpg/proxmox | ~> 0.111.1 | uses the new `proxmox_download_file` resource |
| Ubuntu      | 26.04 LTS  | amd64v3 image needs x86-64-v3 CPU            |
| Ansible     | core 2.20  | Ubuntu repo package; builtin modules only in Phase 1      |
| zabbix-agent2 | 7.0.30 (7.0 LTS repo) | pinned major 7.0: the only current major publishing resolute (26.04) packages as of Aug 2026; universe fallback is 7.0.22 |
| community.proxmox | 2.0.0 | Phase 4: proxmox content split from community.general into its own collection; needs python3-proxmoxer + python3-requests |
| Semaphore UI | 2.19.11 | Phase 4: .deb from GitHub releases; SQLite default dialect; config `port` must be a STRING; the setup script's password generator must be pipefail-safe (field-found on sem-01: `tr | head -c` aborts the script under `set -euo pipefail`) |

## Repository layout

```
proxmox-automation/
├── ansible.cfg                # ROOT cfg: used when running from repo root (how
│                              # Semaphore runs); deploys use inventory/provisioning.yml
├── terraform/                  # RETIRED for provisioning (Phase 4 went Ansible-
│   ...                         # native); kept runnable for reference
├── ansible/
│   ├── ansible.cfg             # cd ansible && ... (maintenance runs, hosts.yml)
│   ├── requirements.yml        # community.general + ansible.posix + community.proxmox
│   ├── inventory/
│   │   ├── hosts.yml           # KNOWN VMs (maintenance runs)
│   │   ├── provisioning.yml    # localhost + EMPTY provisioned group (deploy flow;
│   │   │                       # filled at runtime by add_host)
│   │   └── group_vars/
│   │       └── provisioned.yml # storage layout (data_disks) + verify_reboot;
│                           # Phase 3 agent knobs moved to playbooks/vars/
│                           # agent-layer.yml (finding #18: Semaphore's own
│                           # inventory never loads group_vars)
│   └── playbooks/
│       ├── 00_provision_vm.yml # Phase 4: Ansible-native clone+cloud-init+disks
│       ├── deploy_vm.yml       # Phase 4: THE entry point (Semaphore runs this)
│       ├── 01_first_contact.yml
│       ├── 02_storage.yml      # serial disks -> LVM -> XFS -> fstab
│       ├── 03_storage_verify.yml  # reboot + prove boot persistence
│       ├── 04_zabbix_agent.yml    # Zabbix Agent 2: pinned repo + verification ladder
│       ├── 05_rsyslog_forward.yml # rsyslog -> TCP forward with disk queue (QRadar pattern)
│       ├── 06_security_agents.yml # Trend/ManageEngine stub installers, marker contract
│       ├── 07_delivery_check.yml  # Phase 4: the handover gate
│       ├── vars/                   # agent-layer.yml (Phase 3 knobs) + profiles.yml
│       │                           # + lab-environment.yml (Phase 4/5)
│       ├── tasks/                  # wait_for_apt.yml (first-boot apt lock gate)
│       └── templates/              # the series' first Jinja2 templates
├── semaphore/                 # Phase 4: UI wiring reference
│   ├── README.md              # survey design + object wiring + security notes
│   └── env/proxmox.env.example # the four PROXMOX_* variables (paste into UI)
├── scripts/
│   ├── pve-bootstrap.sh        # API user + token (run on a PVE node)
│   ├── check-cpu-v3.sh         # x86-64-v3 feature check (run on host)
│   ├── create-sem-01.sh        # Phase 4: LXC 901 (run on pve-a)
│   └── sem-01-setup.sh         # Phase 4: Semaphore+Ansible inside sem-01
├── docs/
│   ├── phase-1-guide.pdf       # step-by-step field guide (Phase 1)
│   ├── phase-2-guide.pdf       # serial disks + LVM/XFS + resize chain (Phase 2)
│   ├── phase-2-addendum-guide.pdf  # group_vars + verify playbook + growth
│   ├── phase-3-agents-guide.pdf    # agent layer: Zabbix Agent 2, rsyslog, stubs
│   └── phase-4-semaphore-guide.pdf # delivery pipeline: form -> VM -> receipt
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

# 10. Phase 3: agent layer. Receiver first, session-proof, on ctrl-01:
sudo apt-get install -y socat
nohup socat -u TCP-LISTEN:5514,reuseaddr,fork \
  OPEN:/tmp/qradar-stub.log,creat,append >/dev/null 2>&1 &

# 11. The three playbooks (builtin-only, any order, all idempotent;
#     field-run recaps, 28 Aug 2026):
ansible-playbook playbooks/04_zabbix_agent.yml    # ok=19 changed=5 (image ships /etc/apt/keyrings and apt's postinst starts the service, so two predicted changes never happen), re-run ok=18 changed=0
ansible-playbook playbooks/05_rsyslog_forward.yml # ok=13 changed=3, re-run ok=12 changed=0, then:
grep phase3-test /tmp/qradar-stub.log             # the tagged lines from vm-test-01 (if the receiver was down: they arrive late, via the queue)
ansible-playbook playbooks/06_security_agents.yml # ok=8 changed=3, re-run ok=8 changed=0

# 12. Optional last-mile proof from ctrl-01 (no server needed;
#     universe has no zabbix-get, add the official 7.0 repo first):
sudo apt-get install -y zabbix-get && zabbix_get -s 192.168.122.50 -k agent.version
#     -> 7.0.30

# 13. Phase 4: the delivery pipeline. Semaphore UI on its own LXC
#     (full walkthrough: docs/phase-4-semaphore-guide.pdf):
#     a) on pve-a: create the container and install everything in it:
bash scripts/create-sem-01.sh          # -> Semaphore at http://192.168.122.21:3000
#     b) on ctrl-01: host the repo for Semaphore (git over SSH):
useradd -m -s /usr/bin/git-shell git && mkdir -p /srv/git
git init --bare --initial-branch=main /srv/git/proxmox-automation.git
# authorize sem-01's deploy key (printed by sem-01-setup.sh step 7):
DEPLOY_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICaUb7zvNq8LGILOM96t9LeOBVjLjXuHnrydb+0k6fdU semaphore@sem-01"
echo "$DEPLOY_KEY" > /home/git/.ssh/authorized_keys
chown git:git /home/git/.ssh/authorized_keys && chmod 600 /home/git/.ssh/authorized_keys
# refresh the working copy from the CURRENT zip, then publish
# (plain `git init` still defaults to master - hence -b main; the
# bare repo and every Semaphore object expect main):
#   cd /root/proxmox-automation
#   git init -b main && git add -A && git commit -m "phase 4"
#   git push /srv/git/proxmox-automation.git main
#   chown -R git:git /srv/git/proxmox-automation.git
#   git config --global --add safe.directory /srv/git/proxmox-automation.git
#     c) in Semaphore (sem-01:3000): project -> Key Store / Repository /
#        Inventory / Environment / Task Template, survey variables per
#        semaphore/README.md, then fill the form once and press Run.
#     d) or CLI-first, no UI, same pipeline (lab smoke test, small disks):
cd ansible && ansible-playbook -i inventory/provisioning.yml playbooks/deploy_vm.yml \
  -e vm_profile=custom -e vm_hostname=vm-faz4-01 -e vm_ip=192.168.122.60 \
  -e vm_vcpu=2 -e vm_ram_gb=4 \
  -e 'vm_disks=[{"role":"data","size_gb":10}]'
#     the run ends with the 07 delivery receipt; the receiver-side proof:
#     grep faz4-vm-faz4-01 /tmp/qradar-stub.log   (on ctrl-01)
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
| Admission gates read LIVE state, not a registry (Phase 5a) | the API is the truth: a registry is a second thing that can drift; IP collision + capacity are answerable from `ipconfig0`/`config` of every VM, so the gates ship without any state file. The intent record arrives with 5b's drift audit, where comparing intent-vs-live is the actual job |
| The audit's memory is its own baseline, not VM notes (Phase 5b) | the plan was intent-in-VM-notes, but community.proxmox 2.0.0's `proxmox_kvm` has NO `notes` parameter (source-verified) - so the audit snapshots the managed fleet itself after each run (`$HOME/proxmox-audit-baseline/fleet.yml` on the runner). Drift = live vs last-audit, and the baseline is the ONLY thing that can notice a deleted managed VM: live state cannot remember what no longer exists |
| The `pipeline-managed` tag IS the fleet registry (Phase 5b) | set by play 00 at deploy time, read from live `config.tags` by the audit - membership lives on the cluster, not in a file; a manual `qm set --tags` shows up as drift, not as an error |
| Audit prints the digest BEFORE mailing, asserts LAST (Phase 5b) | the digest lands in the task log even when mail is unconfigured/broken (the log cannot fail, the mailbox can); the verdict assert runs after print AND mail, so a red task always means the digest is already readable; red = CRITICAL/WARN findings, pure-INFO runs (drift lines, first baseline) stay green |
| IP liveness probe is `wait_for :22`, not ping | a pure Python socket - iputils-ping is often missing in LXC runners; port 22 is what the pipeline itself needs reachable. Catches what `ipconfig0` cannot see: manual VMs, DHCP machines, CTs, anything with sshd squatting the address |
| Capacity budget counts ALLOCATED qemu VMs (templates + CTs excluded) | `config.memory/cores` is what PVE owes a VM whether it runs or not (cluster resources read maxmem=0 for stopped VMs - unusable for budgeting); the target's own allocation is excluded on adoption re-runs so the same VM is never counted twice |
| Ansible-native provisioning, Terraform retired (Phase 4) | No state file to reconcile with VMs that live and die outside the pipeline; `community.proxmox` 2.0.0 covers clone + specs + serial disks natively |
| Clone and configure are TWO tasks (`proxmox_kvm`) | In the module's clone branch only format/full/pool/snapname/storage/target reach the API - spec params passed alongside `clone` are silently dropped; specs go in via a follow-up `update: true` (with `update_unsafe: true`, else `net`/`ide` are skipped) |
| Playbook-level "VM exists?" guard (`proxmox_vm_info`) | The module's clone mode does not check the target NAME (a re-run would clone again under the next free VMID); the guard makes the whole chain re-runnable |
| `ide2: <storage>:cloudinit` on the clone | The Phase 1 template has no cloud-init drive (initialization lived on the workload); the Ansible path creates it explicitly, and ipconfig/sshkeys/ciuser render into it |
| Semaphore over AWX (and over a custom UI) | AWX's last stable release is 24.6.1 (Jul 2024, releases paused); Semaphore ships weekly and its typed survey covers the whole request form; a custom UI would be another system to own |
| Survey enums for vCPU/RAM, derived serials | The form can only offer what the pipeline allows; serials/VGs/LVs/mounts are derived from the role, never typed by a human |
| SQLite dialect for Semaphore | The project's own default: no database server to run in the LXC; Postgres is an env-var switch if HA/remote runners arrive |
| Every request re-validated by asserts | Forms are UX; `--extra-vars` and the API bypass them - the playbook is the gate |
| Storage layout in `group_vars/provisioned.yml`, not playbook `vars:` | One list feeds the build (02) and the verify (03) playbooks; `--extra-vars` can still override for experiments |
| Verify playbook reboots by design (`03_storage_verify.yml`) | fstab entries and LVM activation only prove themselves at boot; "should survive" is a weaker claim than "verified to survive" |
| Fifth disk opt-in via `scratch_disk_size_gb = 0` + dynamic block | Growth stays declarative: the knob removes the disk block entirely when unused; mounting it is an Ansible-side concern (group_vars entry) |
| Agent layer hand-rolled, not the community.zabbix role | the repo pin is explicit (7.0 LTS is the only current major publishing 26.04 packages), ctrl-01 installs no new collections, and the transcript stays visible; swap path documented in the Phase 3 guide |
| apt version election asserted, not assumed | universe also ships zabbix-agent2 (7.0.22); with the official repo added apt elects 7.0.30, and 04 re-reads `apt policy` every run to prove it |
| rsyslog forwarding via an omfwd action with a disk-assisted queue | the naive `*.* @@host:port` line loses messages while the receiver is down; LinkedList + queue.filename spills to /var/spool/rsyslog and retries forever. Field-proven 28 Aug 2026: the receiver died with its SSH session, the queue kept 193 KB across an rsyslog restart and delivered 942 lines late with original timestamps |
| Stub installers behind a marker contract | the pipeline (deploy, run once, verify, upgrade semantics) is testable without licenses; only the payload is stubbed, and the swap-in keeps the marker byte-for-byte |
| Phase 3 is ansible.builtin only | requirements.yml unchanged; the sandbox validation covers exactly what the field runs |
| Lab receiver on port 5514, not 514 | an unprivileged port means no root daemon for the socat stub; production QRadar is a one-variable switch |

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
| 04 fails: apt update 404 on `repo.zabbix.com/.../dists/resolute/Release` | Zabbix has not published this Ubuntu release for the pinned major (8.0/8.2 lack resolute as of Aug 2026) | keep `zabbix_agent_version` on a major that publishes for your release; live-check with `curl -sI <url>` |
| 04's election assert fails (candidate 7.0.22 from archive.ubuntu.com) | the official repo lost the apt election: key or sources line wrong | check `/etc/apt/keyrings/zabbix-official-repo.asc` + `/etc/apt/sources.list.d/zabbix-official-repo.list`, `apt update`, re-run |
| 05 green but `/tmp/qradar-stub.log` stays empty | socat not running (field-proven cause: it died with the SSH session that started it), wrong port, or a TCP listener against the `udp` knob | check the guest-side `/var/log/syslog` line first (proves rsyslog), then `ss -tlnp \| grep 5514`, then `rsyslog_forward_protocol`; restart with the nohup form |
| receiver file never appears although socat is LISTENing | socat creates the file on the FIRST inbound connection; rsyslog retries a suspended action every ~30 s | wait a minute and re-check; `ss -tn \| grep 5514` on the guest proves the wire |
| receiver works, then dies some time later | a foreground one-liner dies with the SSH session that spawned it (SIGHUP) | run it session-proof: `nohup socat ... >/dev/null 2>&1 &` (learned the honest way, 28 Aug 2026) |
| `zabbix-get` fails to install on ctrl-01: `Unable to locate package` | Ubuntu 26.04 universe carries no zabbix-get; only the official Zabbix repo publishes it | give ctrl-01 the 7.0 repo (guide ch. 2), or take the heavy path: the binary also ships inside `zabbix-server-pgsql` |
| `wc -l` on the receiver file shows hundreds of lines after an outage | the rule forwards everything, so the backlog holds every syslog line from the outage window, including Ansible's per-command logging | normal by design; grep for the tag, do not count lines (field receipt: 942) |
| `rsyslogd -N1` fails mentioning the queue and a work directory | the base `/etc/rsyslog.conf` lacks `global(workDirectory=...)`; `queue.filename` needs it | set it to `/var/spool/rsyslog` or drop `queue.filename` (Ubuntu's packaged conf ships it) |
| 06's marker assert fails after a version bump | the drift alarm doing its job: old marker, new desired version | intended; force reinstall: `ansible provisioned -m file -a "path=/opt/TrendMicro/.installed state=absent" -b`, then re-run |
| A server's Zabbix polls time out although 04 is green | `Server=` does not list the polling host; the agent silently drops untrusted polls | add the IP to `zabbix_agent_server` (comma-separated list), or poll from ctrl-01 with `zabbix-get` |
| 03_storage_verify.yml reboots the VM | By design: that is the test (boot persistence) | Add `-e verify_reboot=false` for a no-downtime check (marker test becomes same-session) |
| `03_storage_verify.yml`: `data_disks is not defined` | Play ran outside the repo's ansible.cfg / inventory, so `group_vars/provisioned.yml` was not loaded | Run from `ansible/` with the repo's `ansible.cfg`, or point `-i inventory/hosts.yml` explicitly |
| `sem-01-setup.sh` stops before step 1/8 after `tr: write error: Broken pipe` (field-found on sem-01, 28 Aug 2026) | `tr ... | head -c 16` under `set -euo pipefail`: head closes the pipe after 16 bytes, tr dies, pipefail aborts the script through the command substitution; the sandbox missed it because it passed the password as an argument | fixed in the script (head reads a bounded block first, cut trims last); workaround on an already-pushed copy: pass the password as the script's first argument |
| `ansible-galaxy` / `ansible-playbook` inside sem-01 dies with `Ansible could not initialize the preferred locale: unsupported locale setting` (field-found on sem-01, 28 Aug 2026) | `pct exec` inherits the calling shell's `LANG=en_US.UTF-8`, which the minimal LXC has not generated; ansible-core refuses an invalid locale (the perl locale warnings in the same output are the cosmetic cousin) | fixed in the script (exports `LANG=C.UTF-8`, installs `locales`, runs `locale-gen en_US.UTF-8`); ad-hoc fix: `pct exec 901 -- env LANG=C.UTF-8 <command>` or generate the locale once inside the CT |
| `journalctl -u semaphore` shows `Cannot Find configuration! Use --config parameter to point to a JSON or YAML file` and the unit loops on `activating (auto-restart)` (field-found on sem-01, 28 Aug 2026; restart counter 445 after one hour) | the message is the binary's catch-all for an UNREADABLE config, not only a missing one: root-created state meets a non-root unit. The migrations and admin creation ran as root so `semaphore.db` is root-owned, and `config.json` is 640 root:root; the `User=semaphore` unit can read neither. The sandbox validation ran the binary directly as its own user and never exercised the unit's identity | fixed in the script (config chgrp'd to the service user; data dir chown'd recursively after the migrations); ad-hoc fix: `pct exec 901 -- bash -c 'chown root:semaphore /etc/semaphore/config.json; chown -R semaphore:semaphore /var/lib/semaphore; systemctl restart semaphore'` |
| `ansible-galaxy collection install` inside sem-01 answers "Nothing to do. All requested collections are already installed" although community.proxmox 2.0.0 is absent | Ubuntu's `ansible` package bundles older collections (community.proxmox 1.4.0 and friends) in the system path; an unpinned bare name lets galaxy consider the requirement satisfied by them | `requirements.yml` pins `community.proxmox >= 2.0.0`; the semaphore user's `~/.ansible/collections` also wins the runtime search order, which is where `--force` (or the pinned re-run) puts 2.0.0 |
| First sign-in shows "Failed to create session"; dev tools show POST `/api/auth/login` answering HTTP 500 (field-found on sem-01, 28 Aug 2026, fourth bug of the same install) | v2.19 signs session cookies and requires two secrets in config.json: `cookie_hash` and `cookie_encryption` (the pre-2.19 names `cookie_hash_key`/`cookie_encryption_key` still in blogs do NOT work; the json tags were read from the binary). The server starts, the form renders, bcrypt passes - then cookie encoding fails. The sandbox validated HTTP 200 but never exercised the login endpoint | fixed in the script (config written with both keys generated via pipefail-safe `od -N`); ad-hoc fix: generate two values, rewrite config.json with `"cookie_hash": "<64 hex>"` + `"cookie_encryption": "<32 hex>"`, keep 640 root:semaphore ownership, `systemctl restart semaphore` |
| `git push /srv/git/proxmox-automation.git main` answers `error: src refspec main does not match any` (field-found on ctrl-01, 28 Aug 2026; guide errata) | plain `git init` still defaults to branch `master` (the default changes only in Git 3.0); the bare repo, the push command, and the Semaphore repository object all say `main` | on the already-committed copy: `git branch -m master main`, then push; the corrected guide ch. 4 and this quick start use `git init -b main` from the start |
| `authorized_keys` ends up empty (a later clone from sem-01 answers `Permission denied (publickey)`); copy-pasting the original guide block also produced `chmod: missing operand` (field-found on ctrl-01, 28 Aug 2026; guide errata) | two errata in the original guide ch. 4 block: the `<sem-01 deploy public key>` placeholder was silently eaten by the PDF renderer (the guide library's `esc()` escaped nothing, and the parser treats `<word>` as markup), and the 89-char `chown ... && chmod ...` line wrapped across two PDF lines, so the pasted `chmod` ran without its operand | fixed in this edition (the real deploy key is written into the block, every line stays short enough not to wrap, `esc()` escapes for real); ad-hoc on an existing box: `echo "<deploy key>" > /home/git/.ssh/authorized_keys`, then `chown` and `chmod` as separate lines |
| first clone/pull from sem-01 answers `fatal: detected dubious ownership in repository at '/srv/git/proxmox-automation.git'` | git (>= 2.35.2, CVE-2022-24765) refuses to serve a repository owned by a different user: the bare repo was created by root, the SSH side runs as `git` | `chown -R git:git /srv/git/proxmox-automation.git`; root's local-path push keeps working via `git config --global --add safe.directory /srv/git/proxmox-automation.git` |
| A run's pull phase prints repeated `error: object file .git/objects/<xx>/<yy>... is empty` and `fetch-pack: invalid index-pack output`, then proceeds with `Cloning into 'repository_<n>_<template>'` and finishes green (field-found, run #55, 30 Aug 2026) | a fetch into the task's cached clone was interrupted mid-write (a stopped run or a reboot during the pull), leaving a truncated object; Semaphore detects the unusable cache and falls back to a FRESH clone from the git remote - the run is unaffected | none needed - it already re-cloned; if it recurs on EVERY run, delete the stale cache dir for that template (`repository_*_<template>` under `/var/lib/semaphore/tmp/`) and let the next run re-clone |
| Semaphore run hangs ~5 min at 01's "Wait for any lingering apt/dpkg activity" and fails with `stdout: ["unattended-upgr"]` after every retry (field-found, run #30, 29 Aug 2026) | the gate matched process NAMES, but on Ubuntu 26.04 `unattended-upgr` is the PERMANENT unattended-upgrades.service daemon that never leaves `ps` - all 60 samples saw only the idle daemon and zero apt/dpkg workers, so the loop could never clear | gate v3 is lock-based: `fuser` on the dpkg/apt locks plus `systemctl is-active apt-daily(.upgrade)`; name matching is demoted to a fuser-less fallback that deliberately excludes the daemon; busy polls print the reason; window 90x10 s |
| Re-running the deploy on an EXISTING running VM: "Apply the VM specification" succeeds in ~3 s but "Wait for SSH" then times out for the full 600 s (field-found, run #32, 29 Aug 2026; reproducible on every adoption, never on fresh clones) | the apply task resubmits `net0` WITHOUT a macaddr, so PVE regenerates the MAC and hot-replaces the NIC on the running VM; the guest KEEPS its IP (field probes: ping answered, guest agent answered, sshd listening) but the controller's SSH path breaks | the lookup task now extracts the existing MAC from `config.net0` and the apply pins it with `macaddr=`; fresh clones are unchanged; with the pin the same adoption path passed in ~10 s (run #36) |
| Deploy run dies in 04's pre-task assert: `zabbix_agent_version is undefined`, although static CLI runs of the same plays pass (field-found, run #31, 29 Aug 2026) | Semaphore runs ansible with its OWN generated inventory, so the repo's `inventory/group_vars/provisioned.yml` never loads on the deploy path; add_host hostvars (data_disks) DO arrive - which is why 01-03 passed - but group-scope agent vars do not | agent layer moved to `ansible/playbooks/vars/agent-layer.yml`, loaded by plays 04/05/06/07 via `vars_files` (the same pattern 00 already used for profiles); group_vars keeps storage only; one source of truth for both run modes |
| 04 dies at "Add the pinned Zabbix apt repository" with `Unsupported parameters for (ansible.builtin.apt_repository) module: lock_timeout` (field-found, run #36, 29 Aug 2026) | the earlier dpkg-lock hardening added `lock_timeout: 1800` to all five apt call sites - but only `apt` accepts it (core 2.12+); `apt_repository` rejects it during module argument validation. Latent because no pipeline run had ever reached this task before | parameter removed from the `apt_repository` task only (the four real `apt` sites keep it); the v3 lock-based gate included just above already cleared the race |
| Deploy dies in 00 at "Admission control": `already assigned to VMID 103 (vm-faz4-01)` | another VM's `ipconfig0` already holds the requested IP (Phase 5a collision gate) | pick another IP or retire that VM; the refusal happens BEFORE the clone, so nothing was created - re-run with the corrected form is safe |
| Deploy dies in 00 at "Admission control": `something is ALIVE there (TCP/22 answered)` | no VM holds the IP in `ipconfig0`, but a machine answers on port 22 - a manual VM, a DHCP box, an LXC or anything else with sshd (the liveness probe; ipconfig0 cannot see these) | pick another IP; if you know the squatter is stale, retire it first |
| Deploy dies in 00 at "Admission control": `budget exceeded` (fleet would pass `N/M vCPU` or `K/L GB`) | adding the request would push ALLOCATED non-template qemu vCPU/RAM past `capacity_max_vcpu`/`capacity_max_ram_gb` (templates and CTs are infrastructure, excluded by design) | lower the request, decommission a VM, or raise the budget in `vars/lab-environment.yml` after checking the node's real headroom |
| Health Audit task ends RED (Phase 5b) | by design: a CRITICAL or WARN finding exists (stopped managed VM, SSH unreachable, service down, hot filesystem, CT down, quorum, budget exceeded by manual change) - the full digest with every finding is in the task log above the verdict, and in the mail if msmtp is configured | read the digest's FINDINGS section; fix what it names; the next audit clears the line. Pure-INFO runs (drift lines, "new since last audit") end GREEN - they are notes, not alarms |
| Health Audit dies at its very FIRST task: `couldn't resolve module/action 'community.proxmox.proxmox_cluster_status_info'` while Deploy VM keeps running green (field-found, first 5b run, 30 Aug 2026) | the runner's `community.proxmox` collection predates 2.0.0 - the machine was serving Ubuntu's deb-bundled 1.4.0 from dist-packages, which has every module Deploy VM needs but not 08's newer cluster/node info modules; a user-path galaxy install is NOT enough if it lands outside the service user's real HOME (`/home/semaphore`, not `/var/lib/semaphore`) | on sem-01 (as root): `sudo ansible-galaxy collection install community.proxmox:2.0.0 -p /usr/share/ansible/collections --force` - the HOME-independent system search path, visible to every runner context; then re-run - the setup script now installs the pinned 2.0.0 there for rebuilds |
| Health Audit dies at `Read the node status`: `Requires proxmoxer 2.3 or newer; found version 2.2.0` (field-found, first 5b run, 30 Aug 2026) | community.proxmox 2.0.0's newer info modules declare a Python-client floor that Ubuntu 26.04's `python3-proxmoxer` (2.2.0) does not meet; the deploy path never noticed because `proxmox_kvm`/`proxmox_vm_info` do not declare the floor | on sem-01 (as root): `sudo pip3 install --break-system-packages 'proxmoxer==2.3.0'`, verify with `python3 -c "import proxmoxer; print(proxmoxer.__version__)"`, re-run - the pip copy in /usr/local shadows the apt one (pure-Python, no daemon) |
| Health Audit digest never arrives by mail | `msmtp` is not installed/configured on the runner (or `audit_mail_to` is empty in `vars/lab-environment.yml`) - the audit degrades to log-only and says so as an INFO line | run `scripts/sem-01-msmtp.sh` on sem-01 once (Gmail app password), set `audit_mail_from`/`audit_mail_to`, re-run - the digest prints to the log either way. Hand-rolled setups beware: msmtp treats an unopenable `logfile` as FATAL and the audit runs it as the `semaphore` user - the script pre-creates `/var/log/msmtp.log` with the right ownership; do the same by hand (`chown semaphore:semaphore /var/log/msmtp.log`) or the first mailed audit goes red at the mail step |
| Health Audit goes RED with `AUDIT CRITICAL: ... vanished since the last audit` for a VM you deleted on purpose (field-proven 30 Aug 2026) | the baseline remembered the VM from the previous run - exactly its job (live state cannot see a deletion). Deleted-managed-VM is CRITICAL severity BY DESIGN (new-VM drift is the INFO curiosity; a managed VM disappearing out-of-pipeline is the alarm), so the task ends red and the mail subject carries CRITICAL - that is the verdict assert doing its job, not a crash | nothing to fix; confirm the deletion was yours, then run the audit once more - the baseline refreshed at the end of the red run already dropped the VM, so the next run is quiet (observed: CRITICAL run, then a green `0 critical / 0 warn / 0 info` run) |
| Health Audit goes red at `Mail the digest` with `msmtp: authentication failed ... 535 5.7.8 Username and Password not accepted` (field-found 30 Aug 2026) | the Gmail app password in `/home/semaphore/.msmtprc` was revoked or rotated. A configured-but-broken mail path is FATAL by design - an alerting channel that fails silently is worthless - and no digest is lost: it is already printed to the task log above the mail step | either re-arm mail (new app password via `scripts/sem-01-msmtp.sh`) or retire it gracefully: set `audit_mail_to: ""` in `vars/lab-environment.yml` - the audit returns to log-only mode and says so as an INFO line |

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Golden template + Terraform clone + cloud-init + first contact | **done, field-verified** (guide: `docs/phase-1-guide.pdf`) |
| 2 | Multi-disk via disk `serial` attribute, LVM + XFS, online resize chain | **done, field-verified end to end, closed** (guide: `docs/phase-2-guide.pdf`; addendum edition 3: `docs/phase-2-addendum-guide.pdf` - group_vars + verify + growth all field-run; growth: 02 `ok=15 changed=5`, 03 `ok=28 changed=2 failed=0` with every device letter rotated at boot) |
| 3 | Agent roles: Zabbix Agent 2, Trend Micro, ManageEngine, rsyslog to QRadar | **done, field-verified end to end, closed** (guide edition 3: `docs/phase-3-agents-guide.pdf`; proven TWICE - standalone 28 Aug 2026: every runbook step green, 04 `ok=19 changed=5`, 05 `ok=13 changed=3`, 06 `ok=8 changed=3`, all re-runs clean, `zabbix_get` answered 7.0.30, and an accidental receiver outage proved the disk queue (193 KB survived an rsyslog restart, 942 lines late-delivered with original timestamps); then inside the Phase 4 pipeline 29 Aug 2026: the first two pipeline attempts died in these very plays and became repo fixes - finding #18 (Semaphore's own inventory never loads group_vars -> vars/agent-layer.yml via vars_files on 04/05/06/07) and finding #19 (apt_repository rejects lock_timeout; the defense stays on apt tasks only) - and run #37, the first full pipeline green, reproduced the standalone arithmetic exactly (guest `changed=11` = 04's five + 05's three + 06's three) while the pipeline's delivery tag landed at the receiver minutes later) |
| 4 | Request form: Semaphore UI on its own LXC, Ansible-native provisioning (Terraform retired), delivery gate | **done, field-verified end to end, closed** (guide: `docs/phase-4-semaphore-guide.pdf`; first full pipeline green 29 Aug 2026 - Semaphore form to delivery-checked VM: clone and adopt with a pinned MAC, guest agent, data01 storage stack, zabbix-agent2, rsyslog forward with the receiver-side receipt in hand, stub markers, delivery gate all green; four install-time field bugs fixed en route as in phase 3's story, then four pipeline findings closed the loop: the name-based apt gate, adoption MAC regeneration, the Semaphore inventory never loading group_vars, and an apt_repository parameter overreach) |
| 5 | Scale hardening: admission control (5a), drift/health audit + mail (5b), parallelism stress (5c) | **5a field-proven 4/4 branches** (guide: `docs/phase-5-hardening-guide.pdf`; admission gates in play 00: live IP-collision check, TCP/22 liveness probe, allocated-capacity budget - test A admitted 5/8 vCPU 7/16 GB with correct live math incl. VMs invisible to repo history; test B refused the collision naming VMID 103, test C refused the squatter at the runner's own IP (probe answered, no `ipconfig0` owner), test D refused the budget at 7/8 vCPU and 23/16 GB with exact live math; all refusals died BEFORE the clone with zero `qm list` footprint and `changed=0`); **5b field-proven end to end** (`08_health_audit.yml`: cluster quorum + node pressure, fleet budget, the `pipeline-managed` fleet, drift vs its own baseline (deleted-VM detection included), read-only guest layer (services/filesystems/uptime), digest ALWAYS printed to the log + mailed via msmtp (`scripts/sem-01-msmtp.sh`), verdict red only on CRITICAL/WARN, knobs in `vars/lab-environment.yml`; field chain 30 Aug 2026: first run wrote the baseline, second proved drift-zero with a byte-identical baseline rewrite (idempotent three runs running), the mailed digest landed in the inbox with the template's own subject line, and a scheduler-driven fire produced the quiet-fleet `0 critical / 0 warn / 0 info` digest - the reboot detector (uptime < 1h) fired on three real lab reboots en route; production schedule 07:00/19:00 TR = UTC 04:00/16:00); **5c field-proven, closed** (30 Aug 2026 - the admission TOCTOU is unreachable through the UI because the Semaphore task queue serializes everything: two back-to-back same-template submits did NOT race - the first ran the full pipeline green (fresh clone vm-c-01, VMID 104) while the second WAITED and was then refused at the admission gate reading the first's committed state with exact live math (9/8 vCPU, 15/16 GB) - the queue is an accidental admission mutex; a Health Audit fired mid-deploy (cross-template probe) likewise started only after the deploy's tail, per task-internal timestamps - the queue is global, the remaining race vectors are CLI/API only, and the post-apply re-verify fix stays documented defense-in-depth rather than a lab requirement; the same closing window field-proved the deleted-VM alarm (out-of-pipeline `qm destroy` of a managed VM -> red task + `AUDIT CRITICAL ... vanished since the last audit` + mailed digest - CRITICAL by design, only the baseline can remember a deletion) and its self-heal (next audit quiet `0/0/0`, the line gone via baseline refresh), plus the mail-retirement branch (revoked Gmail app password -> red at the mail step with 535-5.7.8, fatal by design; retired gracefully via `audit_mail_to: ""` -> log-only INFO mode)); a custom-UI track was explored and dropped 30 Aug 2026 - Semaphore stays the only face |

## Notes for production

- Replace `Administrator` on `/` with a dedicated, narrowly scoped PVE role.
- Set `pve_tls_insecure = false` and install a proper CA chain.
- Move Terraform state to a remote backend (Consul, S3, HTTP) with locking.
- The homelab NAT bridge is not a production VLAN trunk: set `vlan_tag`
  and verify 802.1Q on the physical switch.
- Semaphore's task queue ran strictly one task at a time in the field
  (30 Aug 2026: an audit fired mid-deploy started only after the deploy
  finished; two same-template submits serialized so the second read the
  first's committed state). The admission race is therefore UI-unreachable
  - but a long deploy queues scheduled audits behind it; plan maintenance
  windows accordingly.
