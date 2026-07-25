# ─── Cluster manifests via Talos extraManifests (URL-fetched at bootstrap) ──
# Core cluster manifests — Argo CD (the GitOps engine) plus the cluster add-ons
# (metrics-server, Longhorn, csi-driver-nfs) — are NOT vendored inline. Talos
# fetches them by URL at bootstrap via cluster.extraManifests. This keeps the
# machine config (and therefore Terraform state and every `plan`) free of the
# large vendored YAML blobs (Longhorn alone is ~177 KB / 5k lines). The pinned,
# patched copies live in the GitOps repo under bootstrap/; see extra_manifest_urls.
#
# Based on the official Talos guide (which also uses extraManifests):
# https://docs.siderolabs.com/kubernetes-guides/advanced-guides/deploy-argocd
# We diverge by pinning versions (not `stable`) and pre-namespacing Argo CD into
# `argocd` (via kubectl kustomize) so it doesn't land in `default`.
#
# What stays elsewhere (deliberately NOT extraManifests):
#   - the `nfs` StorageClass — parameterized by var.nfs_server/nfs_share, so it
#     stays a small generated inlineManifest in storage.tf.
#   - Longhorn's machine-level prerequisites — the worker /var/lib/longhorn
#     kubelet mount (storage.tf) and the iscsi-tools/util-linux-tools image
#     extensions (talos_schematic_id) — these are machine config, not manifests.
#
# Note: Talos applies extraManifests (like inlineManifests) only at cluster
# BOOTSTRAP. On a from-scratch rebuild
# they are fetched automatically. Changing this list on an already-running
# cluster does NOT push it — per the Talos guide a control-plane REBOOT is
# required; simpler is `kubectl apply -f <url>` once (immediate, no reboot).
# Existing already-applied manifests are not pruned when removed from the list.
#
# Empty extra_manifest_urls (the default) disables all of the above — the
# cluster behaves as a bare Talos/k8s install.

locals {
  extra_manifest_patches = length(var.extra_manifest_urls) == 0 ? [] : [
    yamlencode({
      cluster = {
        extraManifests = var.extra_manifest_urls
      }
    })
  ]
}
