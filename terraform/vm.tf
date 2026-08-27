# ---------------------------------------------------------------------------
# Workload VM: cloned from the golden template, configured by cloud-init
# (Phase 1), plus serial-tagged LVM data disks (Phase 2).
# Phase 3 follows up with Ansible agent roles.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "test_vm" {
  name        = var.vm_name
  node_name   = var.vm_node
  vm_id       = var.workload_vmid
  description = "Proxmox automation lab VM - terraform + cloud-init + ansible"
  tags        = ["terraform", "phase2"]

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

  # -------------------------------------------------------------------------
  # Phase 2: data disks, DB-server practice (one disk per mount point).
  #
  # `serial` is the stable disk identity: PVE passes it to the guest,
  # where the kernel reports it in the lsblk SERIAL column (and as
  # /dev/disk/by-id/*-<serial> wherever the guest's udev provides that
  # alias). Ansible resolves serial -> device fresh on every run and
  # never persists a /dev/sdX letter - /dev/sdb, /dev/sdc ... ordering is
  # NOT stable across reboots and disk additions, which is exactly the
  # guessing game this pipeline replaces.
  #
  # Sizes live in tfvars: a resize is a one-line edit + apply. Disks are
  # workload parameters, NOT template properties - the golden template
  # stays lean and per-VM sizes come from the (future) request form.
  #
  # Growing these later is an ONLINE operation: the provider issues an
  # API disk-resize (no ForceNew, no VM recreation) and Ansible's storage
  # playbook (02_storage.yml) extends PV -> LV -> XFS on re-run.
  # Shrinking is impossible BY DESIGN: the provider refuses ("Cannot
  # shrink ... it is not supported") and XFS cannot shrink either.
  # -------------------------------------------------------------------------
  disk {
    datastore_id = var.storage_id
    interface    = "scsi1"
    size         = var.var_disk_size_gb
    serial       = "var01"
    ssd          = true
    discard      = "on"
  }

  disk {
    datastore_id = var.storage_id
    interface    = "scsi2"
    size         = var.log_disk_size_gb
    serial       = "log01"
    ssd          = true
    discard      = "on"
  }

  disk {
    datastore_id = var.storage_id
    interface    = "scsi3"
    size         = var.data_disk_size_gb
    serial       = "data01"
    ssd          = true
    discard      = "on"
  }

  disk {
    datastore_id = var.storage_id
    interface    = "scsi4"
    size         = var.backup_disk_size_gb
    serial       = "backup01"
    ssd          = true
    discard      = "on"
  }

  # -------------------------------------------------------------------------
  # Phase 2 addendum: the optional fifth disk (growth workflow).
  #
  # scratch_disk_size_gb = 0 removes the block entirely (dynamic block with
  # an empty for_each); any value > 0 creates a serial-tagged scratch disk
  # exactly like the four above. The mount is an Ansible-side concern: add
  # the scratch01 entry to group_vars/provisioned.yml so 02_storage.yml
  # picks it up.
  #
  # A NEWLY attached disk's serial MAY reach the guest kernel only at
  # the next FULL VM start (field run 1 of the growth workflow: it
  # appeared immediately and no restart was needed; resize of existing
  # disks is always online). If the apply attaches scsi5 to a running
  # VM and the storage playbook reports scratch01 NOT FOUND, run on
  # the PVE node:
  #   qm shutdown 200 && qm start 200     (a guest-OS reboot is NOT enough)
  # Growing an EXISTING disk (data_disk_size_gb 20 -> 30) stays fully
  # online - that is the field difference between resizing a disk and
  # attaching a new one.
  # -------------------------------------------------------------------------
  dynamic "disk" {
    for_each = var.scratch_disk_size_gb > 0 ? [var.scratch_disk_size_gb] : []
    content {
      datastore_id = var.storage_id
      interface    = "scsi5"
      size         = disk.value
      serial       = "scratch01"
      ssd          = true
      discard      = "on"
    }
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
