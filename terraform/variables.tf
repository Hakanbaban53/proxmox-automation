# ---------------------------------------------------------------------------
# Proxmox VE connection
# ---------------------------------------------------------------------------

variable "pve_endpoint" {
  description = "Base URL of the Proxmox VE API (any cluster node)."
  type        = string
  default     = "https://192.168.122.11:8006/"
}

variable "pve_api_token" {
  description = <<-EOT
    API token for Terraform, format: "terraform@pve!provider=<uuid>".
    Create it once with scripts/pve-bootstrap.sh (run on any PVE node).
    Better: export PROXMOX_VE_API_TOKEN and leave this unset.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

variable "pve_tls_insecure" {
  description = "Accept self-signed TLS certificates (homelab default)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

variable "storage_id" {
  description = <<-EOT
    Shared NFS storage ID (Datacenter > Storage > ID column).
    Must have these content types enabled: Disk image, Container,
    Container template, Snippets, Import.
  EOT
  type        = string
  default     = "nfs-shared"
}

# ---------------------------------------------------------------------------
# Golden template (Ubuntu 26.04 LTS cloud image)
# ---------------------------------------------------------------------------

variable "template_node" {
  description = "Cluster node that downloads the image and hosts the template."
  type        = string
  default     = "pve-a"
}

variable "template_name" {
  description = "Name of the golden template VM."
  type        = string
  default     = "ubuntu-2604-tpl"
}

variable "template_vmid" {
  description = "Fixed VMID of the golden template; 9000 keeps it out of the workload range."
  type        = number
  default     = 9000
}

variable "cloud_image_url" {
  description = <<-EOT
    Ubuntu 26.04 LTS cloud image (qcow2).
    amd64v3 variant: requires a CPU with x86-64-v3 (AVX2/BMI2/FMA).
    Baseline fallback: https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img
  EOT
  type        = string
  default     = "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64v3.img"
}

variable "template_disk_size_gb" {
  description = "OS disk size of the template (clones inherit and can grow)."
  type        = number
  default     = 10
}

variable "cpu_type" {
  description = <<-EOT
    CPU type exposed to the guest.
    'x86-64-v3' is REQUIRED for Ubuntu 26.04 amd64v3 images and is
    live-migration safe. Use 'host' for nested-virt homelabs if unsure.
  EOT
  type        = string
  default     = "x86-64-v3"
}

# ---------------------------------------------------------------------------
# Workload VM
# ---------------------------------------------------------------------------

variable "vm_node" {
  description = "Cluster node where the workload VM runs."
  type        = string
  default     = "pve-a"
}

variable "vm_name" {
  description = "Hostname and VM name of the workload."
  type        = string
  default     = "vm-test-01"
}

variable "workload_vmid" {
  description = "Fixed VMID of the workload VM; must not collide with existing VMIDs."
  type        = number
  default     = 200
}

variable "vm_cpu_cores" {
  description = "vCPU cores of the workload VM."
  type        = number
  default     = 2
}

variable "vm_memory_mb" {
  description = "Dedicated memory (MiB) of the workload VM."
  type        = number
  default     = 2048
}

variable "vm_disk_size_gb" {
  description = "OS disk size of the workload VM (must be >= template disk)."
  type        = number
  default     = 10
}

variable "vm_bridge" {
  description = "Linux bridge for the VM NIC (e.g. vmbr0)."
  type        = string
  default     = "vmbr0"
}

variable "vlan_tag" {
  description = "802.1Q VLAN tag (maps to network_device.vlan_id); 0 = untagged. Ready for production trunks."
  type        = number
  default     = 0
}

variable "vm_ip_address" {
  description = "Static IPv4 address for the VM (no CIDR prefix)."
  type        = string
  default     = "192.168.122.50"
}

variable "vm_ip_cidr" {
  description = "Prefix length of the VM IPv4 address."
  type        = number
  default     = 24
}

variable "vm_ip_gateway" {
  description = "IPv4 gateway for the VM."
  type        = string
  default     = "192.168.122.1"
}

variable "dns_servers" {
  description = "Nameservers pushed via cloud-init (NAT gateway first, public fallback)."
  type        = list(string)
  default     = ["192.168.122.1", "1.1.1.1"]
}

variable "search_domain" {
  description = "DNS search domain pushed via cloud-init."
  type        = string
  default     = "lab.local"
}

variable "vm_username" {
  description = "Admin user created by cloud-init (passwordless sudo)."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key injected into the VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
