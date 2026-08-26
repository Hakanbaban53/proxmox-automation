provider "proxmox" {
  # Endpoint of any node in the cluster (API is cluster-aware).
  endpoint = var.pve_endpoint

  # Dedicated API token created in Step 2 of the Phase 1 guide.
  # Tip: for CI/CD, export PROXMOX_VE_API_TOKEN instead of committing it.
  api_token = var.pve_api_token

  # Homelab clusters use self-signed certificates.
  # Install a proper CA chain in production and set this to false.
  insecure = var.pve_tls_insecure

  # SSH is NOT required for this Phase 1 setup:
  #   - image download  -> PVE download-url API (proxmox_download_file)
  #   - disk import     -> disk.import_from = native PVE 8.4+ "import-from"
  #                        API option (NOT file_id, which SSHes into the
  #                        node and runs `qm disk import` behind the scenes!)
  #   - cloud-init      -> native provider fields (initialization block)
  # Custom user-data snippets (Phase 4) will add an ssh {} block.
}
