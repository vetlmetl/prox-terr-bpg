# ─── Cluster variables ─────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,61}[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be a valid DNS name (lowercase alphanumeric with hyphens, 3–63 characters)."
  }
}

variable "talos_version" {
  description = "Talos version to deploy"
  type        = string

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.talos_version))
    error_message = "Talos version must be in semver format (e.g., 1.9.5)."
  }
}

variable "talos_schematic_id" {
  # Talos Factory schematic (https://factory.talos.dev) — determines which
  # system extensions are baked into the node image. The default here carries
  # qemu-guest-agent + iscsi-tools + util-linux-tools (the last two are required
  # by Longhorn; see storage.tf). Changing this changes the image => node
  # reinstall (destroy + apply), not an in-place update.
  description = "Talos Factory schematic ID (selects baked-in system extensions)"
  type        = string
  default     = "88d1f7a5c4f1d3aba7df787c448c1d3d008ed29cfb34af53fa0df4336a56040b"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.talos_schematic_id))
    error_message = "Schematic ID must be a 64-character hex string."
  }
}

variable "control_nodes" {
  description = "Map of control node names to Proxmox node names"
  type        = map(string)

  validation {
    condition     = length(var.control_nodes) > 0
    error_message = "At least one control node must be defined."
  }
}

variable "worker_nodes" {
  description = "Map of worker node names to Proxmox node names"
  type        = map(string)
}

# ─── Compute variables ────────────────────────────────────────────────────
# VM CPU/memory sizing. Defaults match the module's own defaults, so leaving
# these unset preserves current behaviour.

variable "control_vm_cores" {
  description = "Number of CPU cores per control-plane VM"
  type        = number
  default     = 4

  validation {
    condition     = var.control_vm_cores >= 1
    error_message = "Control VM cores must be at least 1."
  }
}

variable "worker_vm_cores" {
  description = "Number of CPU cores per worker VM"
  type        = number
  default     = 4

  validation {
    condition     = var.worker_vm_cores >= 1
    error_message = "Worker VM cores must be at least 1."
  }
}

variable "control_vm_memory" {
  description = "Memory in MB per control-plane VM"
  type        = number
  default     = 4096

  validation {
    condition     = var.control_vm_memory >= 2048
    error_message = "Control VM memory must be at least 2048 MB."
  }
}

variable "worker_vm_memory" {
  description = "Memory in MB per worker VM"
  type        = number
  default     = 4096

  validation {
    condition     = var.worker_vm_memory >= 2048
    error_message = "Worker VM memory must be at least 2048 MB."
  }
}

# ─── Network variables ────────────────────────────────────────────────────

variable "network_bridge" {
  description = "Proxmox network bridge the node NICs attach to"
  type        = string
  default     = "vmbr0"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]+$", var.network_bridge))
    error_message = "Network bridge must be an alphanumeric interface name (e.g. vmbr0)."
  }
}

variable "network_vlan_id" {
  description = "VLAN ID to tag the node NICs with; null leaves them untagged"
  type        = number
  default     = null

  validation {
    condition     = var.network_vlan_id == null || (var.network_vlan_id >= 1 && var.network_vlan_id <= 4094)
    error_message = "VLAN ID must be between 1 and 4094, or null for no tag."
  }
}

# ─── Storage variables ────────────────────────────────────────────────────

variable "control_disk_size" {
  description = "Disk size in GB for control plane VMs"
  type        = number

  validation {
    condition     = var.control_disk_size >= 10
    error_message = "Control node disk size must be at least 10 GB."
  }
}

variable "worker_disk_size" {
  description = "Disk size in GB for worker VMs"
  type        = number

  validation {
    condition     = var.worker_disk_size >= 5
    error_message = "Worker node disk size must be at least 5 GB."
  }
}

variable "image_datastore" {
  description = "Datastore for Talos image storage"
  type        = string
}

variable "iso_datastore" {
  description = "Datastore for ISO storage"
  type        = string
}

# ─── Persistent storage (CSI) ─────────────────────────────────────────────
# Longhorn (SSD-backed, in-cluster replicated block) is deployed as a Talos
# inlineManifest and needs no root variables. The NFS CSI driver's StorageClass
# is environment-specific, so its backing share is configured here. See
# storage.tf.

variable "nfs_server" {
  description = "Hostname/IP of the NFS server that backs the `nfs` StorageClass (must be reachable from the worker subnet)"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]+$", var.nfs_server))
    error_message = "NFS server must be a bare hostname or IP (no scheme or port)."
  }
}

variable "nfs_share" {
  description = "Exported path on the NFS server used for dynamically provisioned PVCs (e.g. /mnt/pool/k8s)"
  type        = string

  validation {
    condition     = can(regex("^/", var.nfs_share))
    error_message = "NFS share must be an absolute path starting with '/'."
  }
}

# ─── Cluster manifests (Talos extraManifests) ──────────────────────────────
# Raw URLs Talos fetches at cluster bootstrap via cluster.extraManifests (see
# extra_manifests.tf): Argo CD (the GitOps engine) + the app-of-apps root, plus
# the cluster add-ons (metrics-server, Longhorn, csi-driver-nfs). Hosting these
# by URL instead of vendoring them inline keeps the machine config / plan clean.
# All live in the GitOps repo under bootstrap/. Empty = a bare cluster.

variable "extra_manifest_urls" {
  description = "Raw https URLs Talos fetches at bootstrap (cluster.extraManifests): Argo CD + root app + cluster add-ons (metrics-server, Longhorn, csi-driver-nfs), all hosted under bootstrap/ in the GitOps repo. Empty installs none."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for u in var.extra_manifest_urls : can(regex("^https://", u))])
    error_message = "Each extra manifest URL must be an https:// URL."
  }
}

# ─── Proxmox connection variables ─────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string

  validation {
    condition     = can(regex("^https?://[a-zA-Z0-9._-]+(:\\d+)?$", var.proxmox_endpoint))
    error_message = "Proxmox endpoint must be a valid URL (e.g., https://proxmox.example.com)."
  }
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification for the Proxmox API"
  type        = bool
  default     = false
}

variable "proxmox_ssh_agent" {
  description = "Use SSH agent for Proxmox SSH connections"
  type        = bool
  default     = false
}

variable "proxmox_ssh_private_key" {
  description = "Path to the SSH private key for Proxmox connections"
  type        = string

  validation {
    condition     = can(file(var.proxmox_ssh_private_key))
    error_message = "The SSH private key file must exist at the specified path."
  }
}

variable "proxmox_ssh_username" {
  description = "SSH username for Proxmox connections"
  type        = string

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.proxmox_ssh_username))
    error_message = "SSH username must be a valid Unix username."
  }
}

variable "proxmox_api_token" {
  description = "Proxmox API token (e.g. terraform@pam!provision=<uuid>). Supply via the TF_VAR_proxmox_api_token env var to keep it out of shell history."
  type        = string
}
