# Talos Kubernetes on Proxmox

This is the Terraform I use to build my home-lab Kubernetes cluster: [Talos
Linux](https://www.talos.dev/) on Proxmox VE, six VMs, highly available. The
Proxmox host sits behind my router (which has a public IP), and I use the cluster
to run small projects and expose a few of them to the internet.

It leans on the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox)
and [`siderolabs/talos`](https://registry.terraform.io/providers/siderolabs/talos)
providers, and calls my own fork of the `bbtechsys/talos/proxmox` module.

## What it builds

Three control-plane nodes and three workers, so etcd keeps quorum and the control
plane survives a node dropping out. I reach the Kubernetes API through a shared
Talos VIP (`192.168.88.200`) instead of any single node, so when the VM holding
the VIP goes away the address just moves and `kubectl` keeps working.

Node IPs are predictable: every VM has a fixed MAC and my router hands out the
matching address as a DHCP reservation. I keep the nodes on DHCP on purpose.
Talos' static-IP config fights the module's guest-agent IP discovery, and once
stranded a node on me during a test, so reservations turned out to be the calmer
path.

| Role      | VM name        | IP               | MAC                 |
| --------- | -------------- | ---------------- | ------------------- |
| VIP (API) | —              | `192.168.88.200` | managed by Talos    |
| control-0 | test-control-0 | `192.168.88.201` | `bc:24:11:88:02:01` |
| control-1 | test-control-1 | `192.168.88.202` | `bc:24:11:88:02:02` |
| control-2 | test-control-2 | `192.168.88.203` | `bc:24:11:88:02:03` |
| worker-0  | test-worker-0  | `192.168.88.204` | `bc:24:11:88:02:04` |
| worker-1  | test-worker-1  | `192.168.88.205` | `bc:24:11:88:02:05` |
| worker-2  | test-worker-2  | `192.168.88.206` | `bc:24:11:88:02:06` |

The VM names are the keys of `control_nodes` / `worker_nodes` in
`terraform.tfvars`; Talos picks its own node hostnames. My gateway is
`192.168.88.1` and DNS is `192.168.88.101`. All of this lives in
`cluster_network.tf`.

## How things get into the cluster

Terraform builds the VMs and the Talos machine config, and that's roughly where
its job ends. Anything running *inside* the cluster arrives one of two ways.

First, a handful of core manifests are fetched by Talos at boot through
`cluster.extraManifests`: Argo CD itself, metrics-server, Longhorn, and the NFS
CSI driver. I keep them as pinned YAML in my separate GitOps repo,
[`gitops-k8s`](https://gitlab.com/vetlmetl/gitops-k8s), and just point Terraform
at their raw URLs with `extra_manifest_urls`. I moved these out of the machine
config deliberately — inlining Longhorn alone dumped ~5k lines into every plan
and into state.

Second, once Argo CD is up it takes over. An app-of-apps reconciles the `apps/`
folder in the GitOps repo, which today is sealed-secrets and a GitLab CI runner.
So the cluster's actual workloads are GitOps, not Terraform, and I add new ones by
committing to that repo rather than touching this one.

The only manifest Terraform still generates inline is the `nfs` StorageClass,
because its server and share come from my tfvars.

## Storage

Two CSI layers:

| StorageClass         | Driver         | Backing                   | Modes | Use                                   |
| -------------------- | -------------- | ------------------------- | ----- | ------------------------------------- |
| `longhorn` (default) | Longhorn       | worker SSDs (×2 replicas) | RWO   | Fast, replicated block for app state. |
| `nfs`                | csi-driver-nfs | external NFS share        | RWX   | Bulk / shared volumes, backup targets. |

Longhorn needs the `iscsi-tools` and `util-linux-tools` Talos extensions baked
into the image (via `talos_schematic_id`) and a `/var/lib/longhorn` kubelet bind
mount on the workers. Both are already set — the mount in `storage.tf`, the
schematic in `terraform.tfvars`.

NFS is environment-specific, so I set `nfs_server` and `nfs_share` in
`terraform.tfvars`. The export has to allow the node subnet with `rw` and
`no_root_squash` (the provisioner makes per-volume subdirectories as root), e.g.:

```
/srv/k8s  192.168.88.200/28(rw,sync,no_subtree_check,no_root_squash)
```

The `nfs` StorageClass sets `mountPermissions: "0777"` so non-root pods can write,
since NFS ignores `fsGroup`.

## What's in here

- `main.tf` — providers, S3 backend, and the module call.
- `variables.tf` — input variables and their validation.
- `cluster_network.tf` — the VIP, the MAC/IP maps, and the Talos config patches.
- `storage.tf` — the worker Longhorn mount and the generated `nfs` StorageClass.
- `extra_manifests.tf` — the `cluster.extraManifests` list (`extra_manifest_urls`).
- `backend.hcl.example` — template for the backend config.

`terraform.tfvars`, `backend.hcl`, every `*.tfstate`, and `.terraform/` are
gitignored, because they hold secrets or details of my network.

## Before you apply

- Terraform 1.10 or newer (the S3 backend uses `use_lockfile`).
- A Proxmox VE cluster reachable over the API, plus an API token.
- An S3-compatible bucket for state (I've used MinIO and Garage).
- `talosctl` and `kubectl`.
- DHCP reservations for the MACs above, with `192.168.88.200–.220` kept out of the
  dynamic pool and `.200` left unmapped for the VIP.
- An NFS server exporting a share to the node subnet, if you want the `nfs` class.

The Proxmox API token does not go in `terraform.tfvars` (a tfvars value would
shadow the environment). I pass it through the environment instead:

```bash
export TF_VAR_proxmox_api_token='terraform@pam!provision=<uuid>'
```

The S3 backend reads its credentials from the environment at init time:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=...
export AWS_ENDPOINT_URL_S3=...
```

## Running it

```bash
cp backend.hcl.example backend.hcl     # set bucket = "<your-bucket>"
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

To talk to the cluster afterwards:

```bash
terraform output -raw kubeconfig  > kubeconfig
terraform output -raw talos_config > talosconfig
kubectl --kubeconfig kubeconfig get nodes -o wide
```

Both outputs are sensitive and point at the VIP. To check the HA actually works,
power off whichever control node currently holds `192.168.88.200` — `kubectl`
should recover within a few seconds as the VIP moves.

## Rebuilding from scratch

Anything that recreates every VM at once — a new `talos_schematic_id`, a Talos
image change, or a `terraform destroy` — has to go in two steps. In one shot the
Talos provider trips an inconsistent-plan error (node IPs aren't known at plan
time), and the fresh cluster can be left unbootstrapped:

```bash
# 1. Create the VMs first, so their IPs are known before the config step.
terraform apply \
  -target=module.talos.proxmox_virtual_environment_vm.talos_control_vm \
  -target=module.talos.proxmox_virtual_environment_vm.talos_worker_vm

# 2. Apply the rest (machine config, bootstrap, kubeconfig).
terraform apply

# 3. If the API never comes up (kubectl -> connection refused on VIP:6443 for
#    more than ~5 min), the bootstrap resource went stale — force it:
terraform apply \
  -replace='module.talos.talos_machine_bootstrap.talos_bootstrap' \
  -replace='module.talos.talos_cluster_kubeconfig.talos_kubeconfig'
```

On a fresh cluster Talos fetches the `extra_manifest_urls` for me, so Argo CD and
the storage/metrics add-ons come back on their own.

## The module fork

`main.tf` points `module "talos"` at my fork,
[`vetlmetl/terraform-proxmox-talos`](https://github.com/vetlmetl/terraform-proxmox-talos),
pinned by release tag (`?ref=vX.Y.Z`) rather than the registry. I forked it
because my setup needs a required `cluster_endpoint` — the VIP override — that
isn't in the upstream module. To pull in a module change I make it in the fork,
tag a SemVer release, bump the `?ref=` here, and run `terraform init -upgrade`.

## A note on security

Treat `terraform.tfstate`, `terraform.tfvars`, and `backend.hcl` as secrets; they
are gitignored for that reason. I don't expose the Kubernetes API (`6443`) or the
Talos API (`50000`) to the internet — workloads go out through an ingress
controller with only `80/443` forwarded on the router.

## License

[MIT](LICENSE). Copyright (c) 2026 vetl.
