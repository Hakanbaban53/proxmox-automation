# proxmox-automation

Zero-touch VM provisioning on Proxmox VE: Terraform-managed golden templates,
cloud-init networking, and Ansible configuration - all on shared NFS storage.

This repository is the companion code for the **Proxmox Automation Series** and
implements the automation described in the Phase 1 field guide
(`docs/phase-1-guide.pdf`).

## What Phase 1 does

With one `terraform apply`, this repo:

1. Downloads the Ubuntu 26.04 LTS cloud image **through the PVE API**
   (the node itself fetches it - no local `wget` + `qm importdisk` dance).
2. Builds a **golden template VM** on your shared NFS storage.
3. Clones a workload VM with **cloud-init** applied automatically:
   hostname, static IP/gateway/DNS, admin user, SSH public key.
4. Hands the VM over to **Ansible** for first contact (guest agent install,
   management marker file).

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
│   ├── inventory/hosts.yml     # static for Phase 1
│   └── playbooks/
│       └── 01_first_contact.yml
├── scripts/
│   ├── pve-bootstrap.sh        # API user + token (run on a PVE node)
│   └── check-cpu-v3.sh         # x86-64-v3 feature check (run on host)
├── docs/
│   ├── phase-1-guide.pdf       # step-by-step field guide (English)
│   └── phase-1-guide-tr.pdf    # same guide in Turkish (Türkçe)
├── README.md
└── README.tr.md                # Turkish quick start
```

## Quick start

Full walkthrough: `docs/phase-1-guide.pdf` (Turkish edition: `docs/phase-1-guide-tr.pdf`). Condensed version:

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

## Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Golden template + Terraform clone + cloud-init + first contact | **this repo** |
| 2 | Multi-disk via disk `serial` attribute, LVM + XFS, online resize chain | planned |
| 3 | Agent roles: Zabbix Agent 2, Trend Micro, ManageEngine, rsyslog to QRadar | planned |
| 4 | Semaphore UI form-driven pipeline, dynamic inventory, phone_home | planned |
| 5 | Scale hardening: IPAM, parallelism limits, drift detection | planned |

## Notes for production

- Replace `Administrator` on `/` with a dedicated, narrowly scoped PVE role.
- Set `pve_tls_insecure = false` and install a proper CA chain.
- Move Terraform state to a remote backend (Consul, S3, HTTP) with locking.
- The homelab NAT bridge is not a production VLAN trunk: set `vlan_tag`
  and verify 802.1Q on the physical switch.
