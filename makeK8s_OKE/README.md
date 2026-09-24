# Deploy an OKE cluster for ScyllaDB

`makeBasicCluster.bash` provisions the OCI infrastructure needed by this repository:

- a VCN with a public control-plane subnet, private worker/pod subnet, and public load-balancer subnet;
- an OKE Enhanced Cluster with VCN-native pod networking;
- a general-purpose node pool labeled `scylla-operator`;
- a three-node Dense I/O pool labeled and tainted for ScyllaDB, spread across the three OCI fault domains;
- an optional application pool labeled and tainted for the sample applications.

The dedicated pool's cloud-init enables the kubelet static CPU manager policy. All pools disable the legacy IMDSv1 endpoint and use IMDSv2. The Dense I/O pool's local NVMe devices are prepared later by `setupK8s.bash` using `local-csi-driver/nodeconfigOKE.yaml`.

## Prerequisites

- OCI CLI configured with `oci setup config`.
- `kubectl`, `jq`, and `base64`.
- OCI permissions to create networking, OKE, and Compute resources in the target compartment.
- Dense I/O capacity for at least three nodes in the selected availability domain.

## Configure and create

```bash
cp makeK8s_OKE/oke.conf.example makeK8s_OKE/oke.conf
$EDITOR makeK8s_OKE/oke.conf
./makeK8s_OKE/makeBasicCluster.bash
```

`OCI_REGION` and `OCI_COMPARTMENT_OCID` are required. The Kubernetes version and availability domain are discovered when left empty. The script uses the OCI profile selected by `OCI_CLI_PROFILE`, waits for every OCI operation that later steps depend on, creates kubeconfig with OCI token version 2.0.0, embeds the selected OCI profile in its exec credentials, and renames the context to `${OKE_CLUSTER_NAME}-oke`. It writes to the single file named by `KUBECONFIG`, or to `${HOME}/.kube/config` when `KUBECONFIG` is unset.

For each pool, image discovery asks OKE for OL8 sources filtered by the cluster's Kubernetes version and configured architecture (`X86_64` by default). It then verifies that OKE supports the requested shape and that Compute's complete image-shape compatibility list contains that shape. Selection happens for every requested pool before the first node pool is created. `*_NODE_IMAGE_OCID` can pin a pool to a specific image; the override must be present in OKE's filtered sources and pass the same shape check. The legacy common `OKE_NODE_IMAGE_OCID` override is also accepted as a fallback for all pools.

OKE's supported shape set is narrower than Compute's general image compatibility set. In particular, OKE 1.36.1 in `us-sanjose-1` does not advertise `VM.DenseIO.E4.Flex`, even though Compute reports the OL8 OKE image as launch-compatible with that shape. The default `VM.DenseIO2.8` is an x86 fixed Dense I/O shape currently advertised by OKE; confirm current regional availability with `oci ce node-pool-options get` before choosing another shape.

The public API and load-balancer CIDRs default to `0.0.0.0/0` for an immediately usable example. Restrict `API_INGRESS_CIDR` and `LOAD_BALANCER_INGRESS_CIDR` in `oke.conf` for production use.

The optional application pool is disabled by default and uses an x86 shape/image when enabled. The sample application scripts already target its `application` node label; ensure the application images support `amd64`, or extend the provisioning script with a matching OKE aarch64 image before choosing an Arm application shape.

After creation, return to the repository root:

```bash
./setupK8s.bash
./deployScylla.bash
```

The top-level scripts detect the `-oke` context. Scylla racks are pinned to `oci.oraclecloud.com/fault-domain` values `FAULT-DOMAIN-1` through `FAULT-DOMAIN-3`; monitoring, Manager, and MinIO use OKE's `oci-bv` StorageClass.

## Backups

ScyllaDB Manager's documented S3-compatible provider list does not include OCI Object Storage. This repository therefore does not inject OCI Customer Secret Keys or claim native OCI Object Storage support. When backups are enabled on OKE, `init.conf` selects the supported in-cluster MinIO path. MinIO uses a 50 GiB `oci-bv` volume, matching OCI Block Volume's minimum size.

This example retains the repository's demo MinIO credentials (`minio` / `minio123`) on a cluster-internal endpoint. Replace them in both the Tenant and Manager agent configuration before using this outside an isolated test cluster.

Use an external backup target only after independently validating it against the exact ScyllaDB Manager version and configuring the agent templates yourself.

## Teardown

Delete the ScyllaDB deployment before deleting its OKE infrastructure:

```bash
./deployScylla.bash -x
./setupK8s.bash -x
./makeK8s_OKE/makeBasicCluster.bash -d
```

The provisioning script tags the VCN and cluster with `scylla_k8s_example_oke=${OKE_CLUSTER_NAME}`. Teardown only discovers tagged resources with the configured names, deletes the cluster and node pools first, then removes subnets, security lists, route tables, gateways, and the VCN in dependency order. This prevents `-d` from deleting an unrelated same-named cluster or VCN. It also removes the generated `${OKE_CLUSTER_NAME}-oke` kubeconfig context.

If creation stops after the cluster or some node pools are active, fix the configuration and resume without deleting working resources:

```bash
./makeK8s_OKE/makeBasicCluster.bash --resume
```

Resume requires the tagged cluster and VCN, rediscovers the generated network, verifies the existing cluster version/state, reuses ACTIVE same-named node pools, and creates only missing pools. It refuses a same-named pool in any non-ACTIVE state so that it cannot silently mutate or replace a failed live pool. A normal rerun detects the existing resources and directs you to `--resume` or teardown.

To discard a partial deployment instead, rerun with `-d` and then create it again. Untagged resources are intentionally outside the deletion scope.
