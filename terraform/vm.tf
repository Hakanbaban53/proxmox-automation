# ---------------------------------------------------------------------------
# Phase 1 workload: one test VM, cloned from the golden template,
# configured by cloud-init (hostname, static IP, user, SSH key).
# This is the block Phase 2 will extend with serial-tagged data disks
# and Phase 3 will follow up on with Ansible agent roles.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "test_vm" {
  name        = var.vm_name
  node_name   = var.vm_node
  vm_id       = var.workload_vmid
  description = "Phase 1 test VM - provisioned by proxmox-automation"
  tags        = ["phase1", "terraform"]

  clone {
    vm_id   = proxmox_virtual_environment_vm.ubuntu_template.vm_id
    full    = true # independent disk on NFS; linked clones are a Phase 5 topic
    retries = 3
  }

  agent {
    enabled = true
    # Ubuntu cloud images ship WITHOUT qemu-guest-agent. The provider polls
    # the agent for network interfaces after start AND on every refresh
    # (terraform plan/apply), waiting agent.timeout (default 15m) each time.
    # Until Ansible installs the agent (ch. 9), that is a dead 15-minute
    # wait per run. Skip it: this lab uses static IPs from tfvars, so
    # agent-based IP discovery adds nothing. Remove this block after the
    # agent is under management if you want ipv4_addresses in state.
    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    cores = var.vm_cpu_cores
    type  = var.cpu_type
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  scsi_hardware = "virtio-scsi-pci"

  # Resizes the cloned root disk to the requested size.
  disk {
    datastore_id = var.storage_id
    interface    = "scsi0"
    size         = var.vm_disk_size_gb
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge  = var.vm_bridge
    vlan_id = var.vlan_tag > 0 ? var.vlan_tag : null
  }

  serial_device {}
  vga {
    type = "serial0"
  }

  boot_order = ["scsi0"]

  initialization {
    datastore_id = var.storage_id

    # NOTE: no hostname here. Provider v0.111 removed initialization.hostname;
    # the cloud-init hostname comes from the VM name (must be a valid DNS name).

    dns {
      domain  = var.search_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${var.vm_ip_address}/${var.vm_ip_cidr}"
        gateway = var.vm_ip_gateway
      }
    }

    user_account {
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
      username = var.vm_username
    }
  }

  started  = true
  on_boot  = true
}
