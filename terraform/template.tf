# ---------------------------------------------------------------------------
# Ubuntu 26.04 LTS cloud image.
# The PVE node itself downloads the qcow2 via the download-url API
# (no local wget + qm importdisk anymore).
#
# IMPORTANT - PVE version requirements (bpg/proxmox v0.111):
#   * content_type = "import"  -> needs PVE >= 8.4 (provider checks 8.4,
#     see SupportImportContentType; on 8.0-8.3 the download task hangs/fails
#     with "content type 'import' is not supported")
#   * .qcow2 file names       -> "wrong file extension" error on PVE < 8.4
#   * disk.import_from         -> native API import, NO SSH needed, but the
#     image must be 'import' content type (so also PVE 8.4+)
# 'Import' content type must be enabled on the NFS storage first
# (Datacenter > Storage > nfs-shared > Edit > Content: add Import).
# ---------------------------------------------------------------------------
resource "proxmox_download_file" "ubuntu_image" {
  content_type = "import"
  datastore_id = var.storage_id
  node_name    = var.template_node
  url          = var.cloud_image_url
  file_name    = "ubuntu-2604-cloudimg.qcow2"

  # The default is 600 s (10 min). A ~700 MB cloud image over a slow
  # uplink can easily exceed that - the download task then dies with
  # "timeout while waiting for task ... to complete".
  upload_timeout = 3600

  # Re-download when the upstream image changed (image track: /current/).
  overwrite_unmanaged = true

  # Optional integrity check: take the hash from SHA256SUMS next to the image:
  #   checksum           = "<sha256-from-SHA256SUMS>"
  #   checksum_algorithm = "sha256"
}

# ---------------------------------------------------------------------------
# Golden template. Every workload VM is a full clone of this VM.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "ubuntu_template" {
  name        = var.template_name
  node_name   = var.template_node
  vm_id       = var.template_vmid
  description = "Ubuntu 26.04 LTS cloud-init template - managed by Terraform (proxmox-automation)"
  tags        = ["template", "terraform"]

  template = true

  # QEMU guest agent: lets PVE report IPs, run clean shutdowns, etc.
  # The agent binary itself is installed by Ansible after first boot.
  agent {
    enabled = true
  }

  cpu {
    cores = 2
    # Ubuntu 26.04 amd64v3 images require x86-64-v3 CPU features.
    # PVE's default (x86-64-v2-Auto) will crash-loop the guest kernel.
    type = var.cpu_type
  }

  memory {
    dedicated = 2048
  }

  # Ubuntu cloud images require the virtio-scsi-pci controller.
  scsi_hardware = "virtio-scsi-pci"

  disk {
    datastore_id = var.storage_id
    # import_from = native PVE 8.4+ API import (import-from= disk option):
    # no SSH credentials needed, works with the API token alone.
    # (The older file_id path SSHes into the node and runs `qm disk import`.)
    import_from = proxmox_download_file.ubuntu_image.id
    interface   = "scsi0"
    size        = var.template_disk_size_gb
    ssd         = true
    discard     = "on"
  }

  network_device {
    bridge  = var.vm_bridge
    vlan_id = var.vlan_tag > 0 ? var.vlan_tag : null
  }

  # Cloud images expect a serial console (OpenStack convention).
  serial_device {}
  vga {
    type = "serial0"
  }

  boot_order = ["scsi0"]

  depends_on = [proxmox_download_file.ubuntu_image]
}
