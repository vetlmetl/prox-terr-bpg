# ─── Persistent storage (CSI) ───────────────────────────────────────────────
# Two storage layers, one per physical tier of host `small`:
#   - Longhorn  -> default `longhorn` StorageClass: fast, replicated (x2) RWO
#     block on the local SSD. Requires the iscsi-tools/util-linux-tools image
#     extensions (baked into talos_schematic_id) and the kubelet mount below.
#   - csi-driver-nfs -> `nfs` StorageClass: big-capacity RWX/bulk on the 2 TB
#     NFS share. No image extension needed (in-kernel NFS client).
#
# The Longhorn and csi-driver-nfs *driver* manifests are fetched by Talos as
# extraManifests from the GitOps repo (see extra_manifests.tf) rather than
# vendored inline, to keep the machine config / plan clean. What remains here:
#   1. The `nfs` StorageClass — generated so server/share come from variables,
#      so it stays a (tiny) inlineManifest rather than a static URL.
#   2. The worker kubelet /var/lib/longhorn bind mount — machine config, not a
#      k8s manifest, so it cannot move to extraManifests.

locals {
  # Worker machine config. Overriding worker_machine_config_patches REPLACES the
  # module default (which only sets the install disk), so re-include the install
  # disk here — same gotcha as control_shared_patches in cluster_network.tf.
  # The extraMounts bind is Longhorn's data-path requirement on Talos.
  worker_machine_config_patches = [
    yamlencode({
      machine = {
        install = { disk = "/dev/vda" }
        kubelet = {
          extraMounts = [{
            destination = "/var/lib/longhorn"
            type        = "bind"
            source      = "/var/lib/longhorn"
            options     = ["bind", "rshared", "rw"]
          }]
        }
      }
    })
  ]

  # The env-specific `nfs` StorageClass for csi-driver-nfs, concat'd onto the
  # control-plane patches in main.tf. Parameterized by the NFS export, so it is
  # generated here rather than fetched as a static extraManifest. The driver
  # itself (provisioner nfs.csi.k8s.io) is an extraManifest (extra_manifests.tf);
  # this class just won't provision until that driver is up (both at bootstrap).
  storage_addon_patches = [
    yamlencode({
      cluster = {
        inlineManifests = [
          {
            # Not marked default — Longhorn is the default class.
            name = "csi-driver-nfs-storageclass"
            contents = yamlencode({
              apiVersion  = "storage.k8s.io/v1"
              kind        = "StorageClass"
              metadata    = { name = "nfs" }
              provisioner = "nfs.csi.k8s.io"
              parameters = {
                server = var.nfs_server
                share  = var.nfs_share
                # chmod each provisioned subdir 0777 so non-root pods can write
                # (NFS ignores fsGroup; without this a runAsNonRoot workload hits
                # permission-denied on the root-owned 0755 dir the driver creates).
                mountPermissions = "0777"
              }
              reclaimPolicy     = "Delete"
              volumeBindingMode = "Immediate"
              mountOptions      = ["nfsvers=4.1"]
            })
          },
        ]
      }
    })
  ]
}
