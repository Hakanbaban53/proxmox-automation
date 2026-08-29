#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phase 4: create sem-01 - the Semaphore UI container.
#
# RUN ON: pve-a (any PVE node with the nfs-shared storage), as root.
# WHAT IT DOES:
#   1. creates unprivileged LXC 901 "sem-01" from the Ubuntu 26.04
#      template already downloaded to nfs-shared (the same one ctrl-01
#      came from - phase 1, chapter 5)
#   2. gives it a static IP (.20 turned out to be occupied in the field
#      lab, so the default is .21; ping -c2 192.168.122.21 first and
#      edit CT_IP below if your lab says otherwise)
#   3. pushes and runs sem-01-setup.sh inside it (Semaphore + Ansible +
#      collections + service user + systemd + deploy keypair)
#
# Sizing rationale (a real question with a boring answer): Semaphore is a
# single Go binary with an embedded SQLite database; the Ansible runs
# happen in the SAME container. 2 vCPU / 2 GB runs the lab comfortably;
# give it 4 GB when task history grows into the tens of thousands or you
# add remote runners. 16 GB of disk because job output is kept in the DB.
#
# Why an LXC and not a VM: no kernel of its own to update, starts in
# seconds, snapshot before upgrades is one command. Nothing Semaphore
# does needs its own kernel.
#
# --features nesting=1: the Ubuntu 26.04 template ships systemd 259,
# and pct warns "You may need to enable nesting" without the feature
# (seen on sem-01, 28 Aug 2026). Harmless on an unprivileged CT, and
# it answers a warning that would be questioned on every rebuild.
# ---------------------------------------------------------------------------
set -euo pipefail

CT_ID=901
CT_NAME=sem-01
CT_IP=192.168.122.21
CT_GW=192.168.122.1
CT_cores=2
CT_MEMORY=2048
CT_SWAP=512
CT_DISK=16
STORAGE=nfs-shared
# The Ubuntu 26.04 LXC template downloaded in phase 1. Verify with:
#   pveam list nfs-shared
# and adjust the filename if yours differs. The name below is the
# lab's actual file (field-verified 28 Aug 2026); the version suffix
# (-26.04-1) bumps whenever the template is updated.
TEMPLATE=nfs-shared:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v pct >/dev/null || { echo "Run this on a Proxmox node (pct not found)."; exit 1; }
[ -d "/dev/.pcs" ] || true
pct status "$CT_ID" >/dev/null 2>&1 && { echo "CT $CT_ID already exists - aborting."; exit 1; }
pveam list "$STORAGE" 2>/dev/null | grep -q "$(basename "$TEMPLATE" .tar.zst)" \
  || { echo "Template $TEMPLATE not found on $STORAGE. Check: pveam list $STORAGE"; exit 1; }

echo ">>> Creating CT $CT_ID ($CT_NAME) on $STORAGE ..."
pct create "$CT_ID" "$TEMPLATE" \
  --hostname "$CT_NAME" \
  --cores "$CT_cores" --memory "$CT_MEMORY" --swap "$CT_SWAP" \
  --rootfs "${STORAGE}:${CT_DISK}" \
  --net0 "name=eth0,bridge=vmbr0,ip=${CT_IP}/24,gw=${CT_GW}" \
  --unprivileged 1 \
  --features nesting=1 \
  --onboot 1 \
  --start 1 \
  --tags pipeline-managed

echo ">>> Waiting for the container network ..."
sleep 10

echo ">>> Pushing sem-01-setup.sh and running it inside $CT_NAME ..."
pct push "$CT_ID" "$SCRIPT_DIR/sem-01-setup.sh" /root/sem-01-setup.sh --perms 700
pct exec "$CT_ID" -- /root/sem-01-setup.sh

echo
echo ">>> Done. Semaphore UI: http://$CT_IP:3000"
echo ">>> If the setup script printed a generated admin password, use it"
echo ">>> with login 'admin' on first sign-in, then change it."
