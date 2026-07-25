terraform {
  # Remote state on an S3-compatible object store.
  # Partial config: `bucket` is supplied at init via -backend-config=backend.hcl.
  # Credentials, region, and the S3 endpoint are read from environment variables:
  #   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION, AWS_ENDPOINT_URL_S3
  backend "s3" {
    key            = "prox-terr-bpg/terraform.tfstate"
    encrypt        = true
    use_lockfile   = true # native S3 state locking (Terraform >= 1.10); no DynamoDB needed
    use_path_style = true # most non-AWS S3 gateways require path-style addressing

    # The following skips are required for non-AWS S3-compatible providers,
    # which don't implement AWS-specific validation/metadata endpoints.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requester_charged      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }

  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.109.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }
}

# ─── Provider configuration ────────────────────────────────────────────────

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
  ssh {
    agent       = var.proxmox_ssh_agent
    private_key = file(var.proxmox_ssh_private_key)
    username    = var.proxmox_ssh_username
  }
}

# ─── Talos cluster module ──────────────────────────────────────────────────

module "talos" {
  # Personal fork of bbtechsys/talos/proxmox, pinned to a release tag. Adds the
  # required cluster_endpoint used below (not in the registry module).
  # Bump the tag to adopt fork changes.
  source = "git::https://github.com/vetlmetl/terraform-proxmox-talos.git?ref=v2.0.0"

  talos_cluster_name = var.cluster_name
  talos_version      = var.talos_version
  talos_schematic_id = var.talos_schematic_id
  control_nodes      = var.control_nodes
  worker_nodes       = var.worker_nodes

  proxmox_control_vm_disk_size = var.control_disk_size
  proxmox_worker_vm_disk_size  = var.worker_disk_size
  proxmox_image_datastore      = var.image_datastore
  proxmox_iso_datastore        = var.iso_datastore

  # VM sizing (cores/memory) and NIC placement (bridge/VLAN).
  proxmox_control_vm_cores  = var.control_vm_cores
  proxmox_worker_vm_cores   = var.worker_vm_cores
  proxmox_control_vm_memory = var.control_vm_memory
  proxmox_worker_vm_memory  = var.worker_vm_memory
  proxmox_network_bridge    = var.network_bridge
  proxmox_network_vlan_id   = var.network_vlan_id

  # Predictable node IPs via fixed MACs + router DHCP reservations.
  control_plane_mac_addresses = local.control_node_macs
  worker_mac_addresses        = local.worker_node_macs

  # HA Kubernetes API endpoint via a shared Talos VIP. See cluster_network.tf.
  cluster_endpoint = "https://${local.cluster_vip}:6443"

  # Subnet the nodes get DHCP addresses on; the module matches this to pick each
  # node's primary IP from the guest agent (the VIP above is excluded).
  node_ipv4_cidr = local.node_ipv4_cidr

  # Control-plane patches: network/VIP (cluster_network.tf), the generated `nfs`
  # StorageClass inlineManifest (storage.tf), and the URL-fetched cluster
  # manifests — Argo CD + metrics-server/Longhorn/csi-driver-nfs — via
  # cluster.extraManifests (extra_manifests.tf). Talos merges the list in order.
  control_machine_config_patches = concat(
    local.control_shared_patches,
    local.storage_addon_patches,
    local.extra_manifest_patches,
  )

  # Worker patches: install disk + the /var/lib/longhorn kubelet mount Longhorn
  # requires (storage.tf). Overriding this replaces the module default, so the
  # install disk is re-included there.
  worker_machine_config_patches = local.worker_machine_config_patches
}

# ─── Outputs ───────────────────────────────────────────────────────────────

output "talos_config" {
  description = "Talos configuration file"
  value       = module.talos.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig file"
  value       = module.talos.kubeconfig
  sensitive   = true
}
