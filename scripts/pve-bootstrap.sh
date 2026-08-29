#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run ONCE on any Proxmox VE node (changes replicate cluster-wide via pmxcfs).
# Creates the terraform API user + token used by the bpg/proxmox provider.
#
# Privileges granted (Administrator on /):
#   - Sys.Audit + Sys.Modify      -> needed by proxmox_download_file
#   - Datastore.AllocateTemplate  -> needed to store the downloaded image
# Trim these to a dedicated role for production deployments.
# ---------------------------------------------------------------------------
set -euo pipefail

PVE_USER="terraform@pve"
PVE_TOKEN_NAME="provider"
TOKEN_ID="${PVE_USER}!${PVE_TOKEN_NAME}"

# 1. Dedicated user (idempotent). NOTE (field finding #15): pveum list
# output is version-dependent (PVE 9.x may draw table borders), so the
# original awk+$1 | grep -x guard missed an EXISTING user and the script
# died at pveum user add "already exists". Matching the userid as a WORD
# (grep -w) is format-agnostic: plain, bordered or json output all match.
if pveum user list | grep -qw "$PVE_USER"; then
  echo "[ok] user $PVE_USER already exists"
else
  pveum user add "$PVE_USER" --comment "Terraform automation (proxmox-automation repo)"
  echo "[+] created user $PVE_USER"
fi

# 2. Cluster-wide privileges
pveum acl modify / --users "$PVE_USER" --roles Administrator
echo "[ok] Administrator role granted on /"

# 3. API token (idempotent - value is only shown at creation time).
# Same word-match fix as step 1 (field finding #15).
if pveum user token list "$PVE_USER" | grep -qw "$PVE_TOKEN_NAME"; then
  echo "[ok] token $TOKEN_ID already exists"
  echo "    value is only displayed at creation time."
  echo "    to rotate it:"
  echo "      pveum user token remove $PVE_USER $PVE_TOKEN_NAME"
  echo "      pveum user token add  $PVE_USER $PVE_TOKEN_NAME --privsep 0"
else
  echo "[+] creating token $TOKEN_ID"
  pveum user token add "$PVE_USER" "$PVE_TOKEN_NAME" --privsep 0 --comment "bpg/proxmox provider token"
fi

cat <<EOF

Copy the token value printed above into terraform/terraform.tfvars:

  pve_api_token = "${TOKEN_ID}=<uuid-from-output>"

or export it for CI/CD:

  export PROXMOX_VE_API_TOKEN="${TOKEN_ID}=<uuid-from-output>"

EOF
