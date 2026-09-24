#!/usr/bin/env bash

# Provision an OCI OKE cluster using the topology recommended by the
# ScyllaDB Operator OKE reference deployment.
#
# Usage:
#   cp makeK8s_OKE/oke.conf.example makeK8s_OKE/oke.conf
#   $EDITOR makeK8s_OKE/oke.conf
#   ./makeK8s_OKE/makeBasicCluster.bash
#   ./makeK8s_OKE/makeBasicCluster.bash -d

set -o pipefail
trap 'rc=$?; printf "* * * %s failed at line %d (exit %d)\n" "${BASH_SOURCE[0]##*/}" "${LINENO}" "$rc" >&2' ERR

scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
configFile="${OKE_CONFIG_FILE:-${scriptDir}/oke.conf}"

die() {
  printf "* * * Error: %s\n" "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" > /dev/null 2>&1 || die "required command '$1' was not found"
}

run_oci() {
  if ! oci "$@" --profile "${OCI_CLI_PROFILE}"; then
    die "OCI command failed: oci $*"
  fi
}

capture_oci() {
  local variableName=$1
  local value
  shift
  if ! value=$(oci "$@" --profile "${OCI_CLI_PROFILE}"); then
    die "OCI lookup failed: oci $*"
  fi
  [[ ${value} == "null" || ${value} == "None" ]] && value=""
  printf -v "${variableName}" '%s' "${value}"
}

# shellcheck source=oke-image-selection.bash
source "${scriptDir}/oke-image-selection.bash" \
  || die "could not load OKE image-selection helpers"

run_kubectl() {
  if ! kubectl "$@"; then
    die "kubectl command failed: kubectl $*"
  fi
}

validate_positive_integer() {
  [[ $2 =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer (got '$2')"
}

delete_context() {
  local contextName="${OKE_CLUSTER_NAME}-oke"
  local currentContext
  currentContext=$(kubectl config current-context 2>/dev/null) || currentContext=""
  if [[ ${currentContext} == "${contextName}" ]]; then
    kubectl config unset current-context > /dev/null 2>&1 || true
  fi
  kubectl config delete-context "${contextName}" > /dev/null 2>&1 || true
}

lookup_cluster() {
  capture_oci OKE_CLUSTER_OCID ce cluster list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --name "${OKE_CLUSTER_NAME}" \
    --all \
    --query "data[?\"freeform-tags\".scylla_k8s_example_oke=='${OKE_CLUSTER_NAME}'] | [0].id" \
    --raw-output
}

lookup_name_collisions() {
  capture_oci existingCluster ce cluster list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --name "${OKE_CLUSTER_NAME}" \
    --all \
    --query 'data[0].id' \
    --raw-output
  capture_oci existingVcn network vcn list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --display-name "${OKE_VCN_NAME}" \
    --all \
    --query 'data[0].id' \
    --raw-output
}

require_active_node_pool() {
  local poolName=$1
  local poolState
  capture_oci poolState ce node-pool list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --cluster-id "${OKE_CLUSTER_OCID}" \
    --query "data[?name=='${poolName}'] | [0].\"lifecycle-state\"" \
    --raw-output
  [[ ${poolState} == "ACTIVE" ]] \
    || die "OKE node pool ${poolName} did not become ACTIVE (state: ${poolState:-missing})"
}

lookup_node_pool_state() {
  local outputVariable=$1
  local poolName=$2
  capture_oci "${outputVariable}" ce node-pool list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --cluster-id "${OKE_CLUSTER_OCID}" \
    --all \
    --query "data[?name=='${poolName}'] | [0].\"lifecycle-state\"" \
    --raw-output
}

lookup_network() {
  capture_oci OKE_VCN_OCID network vcn list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --display-name "${OKE_VCN_NAME}" \
    --all \
    --query "data[?\"freeform-tags\".scylla_k8s_example_oke=='${OKE_CLUSTER_NAME}'] | [0].id" \
    --raw-output

  OKE_IGW_OCID=""
  OKE_NATGW_OCID=""
  OKE_PUBLIC_RT_OCID=""
  OKE_PRIVATE_RT_OCID=""
  OKE_PUBLIC_SL_OCID=""
  OKE_PRIVATE_SL_OCID=""
  OKE_CP_SUBNET_OCID=""
  OKE_WORKERS_SUBNET_OCID=""
  OKE_LB_SUBNET_OCID=""
  [[ -z ${OKE_VCN_OCID} ]] && return 0

  capture_oci OKE_IGW_OCID network internet-gateway list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-igw" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_NATGW_OCID network nat-gateway list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-natgw" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_PUBLIC_RT_OCID network route-table list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-public" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_PRIVATE_RT_OCID network route-table list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-private" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_PUBLIC_SL_OCID network security-list list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-public" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_PRIVATE_SL_OCID network security-list list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-private" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_CP_SUBNET_OCID network subnet list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-cp" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_WORKERS_SUBNET_OCID network subnet list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-workers" \
    --query 'data[0].id' \
    --raw-output
  capture_oci OKE_LB_SUBNET_OCID network subnet list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-lb" \
    --query 'data[0].id' \
    --raw-output
}

delete_oke() {
  printf "Deleting OKE cluster and network resources for %s\n" "${OKE_CLUSTER_NAME}"
  lookup_cluster
  if [[ -n ${OKE_CLUSTER_OCID} ]]; then
    run_oci ce cluster delete \
      --region "${OCI_REGION}" \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --force \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 30 \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED
    delete_context
  else
    printf "OKE cluster %s was not found\n" "${OKE_CLUSTER_NAME}"
  fi

  lookup_network
  if [[ -z ${OKE_CLUSTER_OCID} && -n ${OKE_VCN_OCID} ]]; then
    delete_context
  fi
  if [[ -z ${OKE_VCN_OCID} ]]; then
    printf "VCN %s was not found\n" "${OKE_VCN_NAME}"
    return 0
  fi

  [[ -n ${OKE_LB_SUBNET_OCID} ]] && run_oci network subnet delete \
    --region "${OCI_REGION}" --subnet-id "${OKE_LB_SUBNET_OCID}" \
    --force --wait-for-state TERMINATED
  [[ -n ${OKE_WORKERS_SUBNET_OCID} ]] && run_oci network subnet delete \
    --region "${OCI_REGION}" --subnet-id "${OKE_WORKERS_SUBNET_OCID}" \
    --force --wait-for-state TERMINATED
  [[ -n ${OKE_CP_SUBNET_OCID} ]] && run_oci network subnet delete \
    --region "${OCI_REGION}" --subnet-id "${OKE_CP_SUBNET_OCID}" \
    --force --wait-for-state TERMINATED

  [[ -n ${OKE_PUBLIC_SL_OCID} ]] && run_oci network security-list delete \
    --region "${OCI_REGION}" --security-list-id "${OKE_PUBLIC_SL_OCID}" \
    --force --wait-for-state TERMINATED
  [[ -n ${OKE_PRIVATE_SL_OCID} ]] && run_oci network security-list delete \
    --region "${OCI_REGION}" --security-list-id "${OKE_PRIVATE_SL_OCID}" \
    --force --wait-for-state TERMINATED

  [[ -n ${OKE_PRIVATE_RT_OCID} ]] && run_oci network route-table delete \
    --region "${OCI_REGION}" --rt-id "${OKE_PRIVATE_RT_OCID}" \
    --force --wait-for-state TERMINATED
  [[ -n ${OKE_PUBLIC_RT_OCID} ]] && run_oci network route-table delete \
    --region "${OCI_REGION}" --rt-id "${OKE_PUBLIC_RT_OCID}" \
    --force --wait-for-state TERMINATED

  [[ -n ${OKE_NATGW_OCID} ]] && run_oci network nat-gateway delete \
    --region "${OCI_REGION}" --nat-gateway-id "${OKE_NATGW_OCID}" \
    --force --wait-for-state TERMINATED
  [[ -n ${OKE_IGW_OCID} ]] && run_oci network internet-gateway delete \
    --region "${OCI_REGION}" --ig-id "${OKE_IGW_OCID}" \
    --force --wait-for-state TERMINATED

  run_oci network vcn delete \
    --region "${OCI_REGION}" --vcn-id "${OKE_VCN_OCID}" \
    --force --wait-for-state TERMINATED
  printf "Deleted OKE infrastructure for %s\n" "${OKE_CLUSTER_NAME}"
}

create_oke() {
  targetContext="${OKE_CLUSTER_NAME}-oke"
  if [[ ${RESUME_EXISTING} == true ]]; then
    lookup_cluster
    [[ -n ${OKE_CLUSTER_OCID} ]] \
      || die "cannot resume: tagged OKE cluster ${OKE_CLUSTER_NAME} was not found"
    lookup_network
    [[ -n ${OKE_VCN_OCID} && -n ${OKE_CP_SUBNET_OCID} && -n ${OKE_WORKERS_SUBNET_OCID} && -n ${OKE_LB_SUBNET_OCID} ]] \
      || die "cannot resume: one or more tagged OKE network resources could not be found"
    capture_oci existingK8sVersion ce cluster get \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --region "${OCI_REGION}" \
      --query 'data."kubernetes-version"' \
      --raw-output
    if [[ -n ${K8S_VERSION} && ${K8S_VERSION} != "${existingK8sVersion}" ]]; then
      die "cannot resume: configured K8S_VERSION ${K8S_VERSION} differs from cluster version ${existingK8sVersion}"
    fi
    K8S_VERSION="${existingK8sVersion}"
    capture_oci clusterState ce cluster get \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --region "${OCI_REGION}" \
      --query 'data."lifecycle-state"' \
      --raw-output
    [[ ${clusterState} == "ACTIVE" ]] \
      || die "cannot resume: OKE cluster is not ACTIVE (state: ${clusterState:-missing})"
    if [[ -z ${OCI_AD} ]]; then
      capture_oci OCI_AD iam availability-domain list \
        --region "${OCI_REGION}" \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --query 'data[0].name' \
        --raw-output
    fi
    [[ -n ${OCI_AD} ]] || die "could not determine an OCI availability domain"
    printf "Resuming OKE %s (%s) in %s\n" "${OKE_CLUSTER_NAME}" "${K8S_VERSION}" "${OCI_REGION}"
  else
    if kubectl config get-contexts -o name 2>/dev/null | grep -Fxq "${targetContext}"; then
      die "kubeconfig context ${targetContext} already exists; remove it or choose another OKE_CLUSTER_NAME"
    fi

    lookup_name_collisions
    if [[ -n ${existingCluster} || -n ${existingVcn} ]]; then
      die "resources named ${OKE_CLUSTER_NAME} already exist; use --resume for a tagged partial deployment, or -d before recreating it"
    fi
    if [[ -z ${K8S_VERSION} ]]; then
      capture_oci K8S_VERSION ce cluster-options get \
        --cluster-option-id all \
        --region "${OCI_REGION}" \
        --query 'data."kubernetes-versions" | sort(@) | [-1]' \
        --raw-output
    fi
  [[ -n ${K8S_VERSION} ]] || die "could not determine a supported OKE Kubernetes version"

  if [[ -z ${OCI_AD} ]]; then
    capture_oci OCI_AD iam availability-domain list \
      --region "${OCI_REGION}" \
      --compartment-id "${OCI_COMPARTMENT_OCID}" \
      --query 'data[0].name' \
      --raw-output
  fi
  [[ -n ${OCI_AD} ]] || die "could not determine an OCI availability domain"

  printf "Creating OKE %s (%s) in %s\n" "${OKE_CLUSTER_NAME}" "${K8S_VERSION}" "${OCI_REGION}"
  printf "Using availability domain %s and three fault domains for ScyllaDB\n" "${OCI_AD}"

  capture_oci OKE_VCN_OCID network vcn create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --display-name "${OKE_VCN_NAME}" \
    --cidr-blocks "[\"${VCN_CIDR}\"]" \
    --dns-label okevcn \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_VCN_OCID} ]] || die "VCN creation completed but its OCID could not be found"

  capture_oci OKE_IGW_OCID network internet-gateway create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --is-enabled true \
    --display-name "${OKE_CLUSTER_NAME}-igw" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_NATGW_OCID network nat-gateway create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-natgw" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_IGW_OCID} && -n ${OKE_NATGW_OCID} ]] || die "gateway OCID lookup failed"

  capture_oci OKE_PUBLIC_RT_OCID network route-table create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-public" \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${OKE_IGW_OCID}\"}]" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_PRIVATE_RT_OCID network route-table create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-rt-private" \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"${OKE_NATGW_OCID}\"}]" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_PUBLIC_RT_OCID} && -n ${OKE_PRIVATE_RT_OCID} ]] || die "route table OCID lookup failed"

  PUBLIC_INGRESS_RULES=$(jq -cn \
    --arg apiCidr "${API_INGRESS_CIDR}" \
    --arg lbCidr "${LOAD_BALANCER_INGRESS_CIDR}" \
    --arg vcnCidr "${VCN_CIDR}" \
    '[
      {source:$apiCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:6443,max:6443}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:443,max:443}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:8000,max:8000}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:9042,max:9042}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:9142,max:9142}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:10000,max:10000}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:19042,max:19042}}},
      {source:$lbCidr,sourceType:"CIDR_BLOCK",protocol:"6",isStateless:false,tcpOptions:{destinationPortRange:{min:19142,max:19142}}},
      {source:$vcnCidr,sourceType:"CIDR_BLOCK",protocol:"all",isStateless:false}
    ]') || die "failed to build public security-list rules"
  PRIVATE_INGRESS_RULES=$(jq -cn --arg vcnCidr "${VCN_CIDR}" \
    '[{source:$vcnCidr,sourceType:"CIDR_BLOCK",protocol:"all",isStateless:false}]') \
    || die "failed to build private security-list rules"
  EGRESS_RULES='[{"destination":"0.0.0.0/0","destinationType":"CIDR_BLOCK","protocol":"all","isStateless":false}]'

  capture_oci OKE_PUBLIC_SL_OCID network security-list create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-public" \
    --egress-security-rules "${EGRESS_RULES}" \
    --ingress-security-rules "${PUBLIC_INGRESS_RULES}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_PRIVATE_SL_OCID network security-list create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-sl-private" \
    --egress-security-rules "${EGRESS_RULES}" \
    --ingress-security-rules "${PRIVATE_INGRESS_RULES}" \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_PUBLIC_SL_OCID} && -n ${OKE_PRIVATE_SL_OCID} ]] || die "security list OCID lookup failed"

  capture_oci OKE_CP_SUBNET_OCID network subnet create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-cp" \
    --cidr-block "${CONTROL_PLANE_SUBNET_CIDR}" \
    --dns-label cp \
    --route-table-id "${OKE_PUBLIC_RT_OCID}" \
    --security-list-ids "[\"${OKE_PUBLIC_SL_OCID}\"]" \
    --prohibit-public-ip-on-vnic false \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_WORKERS_SUBNET_OCID network subnet create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-workers" \
    --cidr-block "${WORKER_SUBNET_CIDR}" \
    --dns-label workers \
    --route-table-id "${OKE_PRIVATE_RT_OCID}" \
    --security-list-ids "[\"${OKE_PRIVATE_SL_OCID}\"]" \
    --prohibit-public-ip-on-vnic true \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  capture_oci OKE_LB_SUBNET_OCID network subnet create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --display-name "${OKE_CLUSTER_NAME}-subnet-lb" \
    --cidr-block "${LOAD_BALANCER_SUBNET_CIDR}" \
    --dns-label lb \
    --route-table-id "${OKE_PUBLIC_RT_OCID}" \
    --security-list-ids "[\"${OKE_PUBLIC_SL_OCID}\"]" \
    --prohibit-public-ip-on-vnic false \
    --wait-for-state AVAILABLE \
    --query 'data.id' \
    --raw-output
  [[ -n ${OKE_CP_SUBNET_OCID} && -n ${OKE_WORKERS_SUBNET_OCID} && -n ${OKE_LB_SUBNET_OCID} ]] \
    || die "subnet OCID lookup failed"

  run_oci ce cluster create \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --vcn-id "${OKE_VCN_OCID}" \
    --name "${OKE_CLUSTER_NAME}" \
    --kubernetes-version "${K8S_VERSION}" \
    --type ENHANCED_CLUSTER \
    --endpoint-subnet-id "${OKE_CP_SUBNET_OCID}" \
    --endpoint-public-ip-enabled true \
    --service-lb-subnet-ids "[\"${OKE_LB_SUBNET_OCID}\"]" \
    --cluster-pod-network-options '[{"cniType":"OCI_VCN_IP_NATIVE"}]' \
    --freeform-tags "${OKE_RESOURCE_TAGS}" \
    --max-wait-seconds 1800 \
    --wait-interval-seconds 30 \
    --wait-for-state SUCCEEDED \
    --wait-for-state FAILED
  lookup_cluster
  [[ -n ${OKE_CLUSTER_OCID} ]] || die "OKE cluster creation completed but its OCID could not be found"
  capture_oci clusterState ce cluster get \
    --cluster-id "${OKE_CLUSTER_OCID}" \
    --region "${OCI_REGION}" \
    --query 'data."lifecycle-state"' \
    --raw-output
  [[ ${clusterState} == "ACTIVE" ]] \
    || die "OKE cluster did not become ACTIVE (state: ${clusterState:-missing})"
  fi

  select_oke_node_image GENERAL_NODE_IMAGE_SELECTED system \
    "${GENERAL_NODE_SHAPE}" "${GENERAL_NODE_ARCH}" "${GENERAL_NODE_IMAGE_OCID}"
  select_oke_node_image SCYLLA_NODE_IMAGE_SELECTED scylla \
    "${SCYLLA_NODE_SHAPE}" "${SCYLLA_NODE_ARCH}" "${SCYLLA_NODE_IMAGE_OCID}"
  if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
    select_oke_node_image APPLICATION_NODE_IMAGE_SELECTED application \
      "${APPLICATION_NODE_SHAPE}" "${APPLICATION_NODE_ARCH}" "${APPLICATION_NODE_IMAGE_OCID}"
  fi
  printf "Validated OKE images for all requested node-pool shapes\n"

  lookup_node_pool_state existingSystemPoolState system
  if [[ ${existingSystemPoolState} == "ACTIVE" ]]; then
    printf "Reusing ACTIVE system node pool\n"
  elif [[ -n ${existingSystemPoolState} ]]; then
    die "system node pool already exists in state ${existingSystemPoolState}; resolve or delete that pool before resuming"
  else
    generalShapeArgs=()
    if [[ ${GENERAL_NODE_SHAPE} == *.Flex ]]; then
      generalShapeArgs=(--node-shape-config "{\"ocpus\":${GENERAL_NODE_OCPUS},\"memoryInGBs\":${GENERAL_NODE_MEMORY_GBS}}")
    fi
    run_oci ce node-pool create \
      --region "${OCI_REGION}" \
      --compartment-id "${OCI_COMPARTMENT_OCID}" \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --name system \
      --kubernetes-version "${K8S_VERSION}" \
      --node-shape "${GENERAL_NODE_SHAPE}" \
      "${generalShapeArgs[@]}" \
      --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"${GENERAL_NODE_IMAGE_SELECTED}\",\"bootVolumeSizeInGBs\":${NODE_BOOT_VOLUME_GBS}}" \
      --placement-configs "[{\"availabilityDomain\":\"${OCI_AD}\",\"subnetId\":\"${OKE_WORKERS_SUBNET_OCID}\"}]" \
      --pod-subnet-ids "[\"${OKE_WORKERS_SUBNET_OCID}\"]" \
      --size "${GENERAL_NODE_COUNT}" \
      --initial-node-labels '[{"key":"scylla.scylladb.com/node-type","value":"scylla-operator"}]' \
      --node-metadata '{"areLegacyImdsEndpointsDisabled":"true"}' \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 30 \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED
    require_active_node_pool system
  fi

  CLOUD_INIT_BASE64=$(base64 <<'EOF' | tr -d '\n'
#!/bin/bash
set -euo pipefail
curl --fail -H "Authorization: Bearer Oracle" -L0 \
  http://169.254.169.254/opc/v2/instance/metadata/oke_init_script \
  | base64 --decode > /var/run/oke-init.sh
bash /var/run/oke-init.sh --kubelet-extra-args "--cpu-manager-policy=static"
EOF
  ) || die "failed to encode the OKE Scylla node cloud-init"

  lookup_node_pool_state existingScyllaPoolState scylla
  if [[ ${existingScyllaPoolState} == "ACTIVE" ]]; then
    printf "Reusing ACTIVE scylla node pool\n"
  elif [[ -n ${existingScyllaPoolState} ]]; then
    die "scylla node pool already exists in state ${existingScyllaPoolState}; resolve or delete that pool before resuming"
  else
    scyllaShapeArgs=()
    if [[ ${SCYLLA_NODE_SHAPE} == *.Flex ]]; then
      scyllaShapeArgs=(--node-shape-config "{\"ocpus\":${SCYLLA_NODE_OCPUS},\"memoryInGBs\":${SCYLLA_NODE_MEMORY_GBS}}")
    fi
    run_oci ce node-pool create \
      --region "${OCI_REGION}" \
      --compartment-id "${OCI_COMPARTMENT_OCID}" \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --name scylla \
      --kubernetes-version "${K8S_VERSION}" \
      --node-shape "${SCYLLA_NODE_SHAPE}" \
      "${scyllaShapeArgs[@]}" \
      --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"${SCYLLA_NODE_IMAGE_SELECTED}\",\"bootVolumeSizeInGBs\":${NODE_BOOT_VOLUME_GBS}}" \
      --placement-configs "[{\"availabilityDomain\":\"${OCI_AD}\",\"subnetId\":\"${OKE_WORKERS_SUBNET_OCID}\",\"faultDomains\":[\"FAULT-DOMAIN-1\",\"FAULT-DOMAIN-2\",\"FAULT-DOMAIN-3\"]}]" \
      --pod-subnet-ids "[\"${OKE_WORKERS_SUBNET_OCID}\"]" \
      --size "${SCYLLA_NODE_COUNT}" \
      --initial-node-labels '[{"key":"scylla.scylladb.com/node-type","value":"scylla"}]' \
      --node-metadata "{\"user_data\":\"${CLOUD_INIT_BASE64}\",\"areLegacyImdsEndpointsDisabled\":\"true\"}" \
      --max-wait-seconds 1800 \
      --wait-interval-seconds 30 \
      --wait-for-state SUCCEEDED \
      --wait-for-state FAILED
    require_active_node_pool scylla
  fi

  if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
    lookup_node_pool_state existingApplicationPoolState application
    if [[ ${existingApplicationPoolState} == "ACTIVE" ]]; then
      printf "Reusing ACTIVE application node pool\n"
    elif [[ -n ${existingApplicationPoolState} ]]; then
      die "application node pool already exists in state ${existingApplicationPoolState}; resolve or delete that pool before resuming"
    else
      applicationShapeArgs=()
      if [[ ${APPLICATION_NODE_SHAPE} == *.Flex ]]; then
        applicationShapeArgs=(--node-shape-config "{\"ocpus\":${APPLICATION_NODE_OCPUS},\"memoryInGBs\":${APPLICATION_NODE_MEMORY_GBS}}")
      fi
      run_oci ce node-pool create \
        --region "${OCI_REGION}" \
        --compartment-id "${OCI_COMPARTMENT_OCID}" \
        --cluster-id "${OKE_CLUSTER_OCID}" \
        --name application \
        --kubernetes-version "${K8S_VERSION}" \
        --node-shape "${APPLICATION_NODE_SHAPE}" \
        "${applicationShapeArgs[@]}" \
        --node-source-details "{\"sourceType\":\"IMAGE\",\"imageId\":\"${APPLICATION_NODE_IMAGE_SELECTED}\",\"bootVolumeSizeInGBs\":${NODE_BOOT_VOLUME_GBS}}" \
        --placement-configs "[{\"availabilityDomain\":\"${OCI_AD}\",\"subnetId\":\"${OKE_WORKERS_SUBNET_OCID}\"}]" \
        --pod-subnet-ids "[\"${OKE_WORKERS_SUBNET_OCID}\"]" \
        --size "${APPLICATION_NODE_COUNT}" \
        --initial-node-labels '[{"key":"scylla.scylladb.com/node-type","value":"application"}]' \
        --node-metadata '{"areLegacyImdsEndpointsDisabled":"true"}' \
        --max-wait-seconds 1800 \
        --wait-interval-seconds 30 \
        --wait-for-state SUCCEEDED \
        --wait-for-state FAILED
      require_active_node_pool application
    fi
  fi

  if kubectl config get-contexts -o name 2>/dev/null | grep -Fxq "${targetContext}"; then
    [[ ${RESUME_EXISTING} == true ]] \
      || die "kubeconfig context ${targetContext} already exists"
    run_kubectl config use-context "${targetContext}"
  else
    mkdir -p "$(dirname "${OKE_KUBECONFIG_FILE}")" \
      || die "could not create the kubeconfig directory"
    run_oci ce cluster create-kubeconfig \
      --region "${OCI_REGION}" \
      --cluster-id "${OKE_CLUSTER_OCID}" \
      --file "${OKE_KUBECONFIG_FILE}" \
      --token-version 2.0.0 \
      --kube-endpoint PUBLIC_ENDPOINT \
      --with-auth-context

    generatedContext=$(kubectl config current-context 2>/dev/null) \
      || die "OCI created kubeconfig, but kubectl has no current context"
    if [[ ${generatedContext} != "${targetContext}" ]]; then
      run_kubectl config rename-context "${generatedContext}" "${targetContext}"
    fi
    run_kubectl config use-context "${targetContext}"
  fi
  run_kubectl wait --for=condition=Ready nodes --all --timeout=20m
  run_kubectl taint nodes -l scylla.scylladb.com/node-type=scylla \
    scylla-operator.scylladb.com/dedicated=scyllaclusters:NoSchedule --overwrite
  if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
    run_kubectl taint nodes -l scylla.scylladb.com/node-type=application \
      scylla-operator.scylladb.com/dedicated=application:NoSchedule --overwrite
  fi

  actualScyllaNodes=$(kubectl get nodes -l scylla.scylladb.com/node-type=scylla -o name | wc -l | tr -d ' ')
  [[ ${actualScyllaNodes} -eq ${SCYLLA_NODE_COUNT} ]] \
    || die "expected ${SCYLLA_NODE_COUNT} Scylla nodes, found ${actualScyllaNodes}"
  faultDomainCount=$(kubectl get nodes -l scylla.scylladb.com/node-type=scylla -o json \
    | jq -r '.items[].metadata.labels["oci.oraclecloud.com/fault-domain"] // empty' \
    | sort -u | wc -l | tr -d ' ')
  [[ ${faultDomainCount} -eq 3 ]] \
    || die "expected Scylla nodes in three OCI fault domains, found ${faultDomainCount}"

  printf "\nOKE cluster %s is ready in context %s\n" "${OKE_CLUSTER_NAME}" "${targetContext}"
  kubectl get nodes \
    -L scylla.scylladb.com/node-type \
    -L oci.oraclecloud.com/fault-domain
  printf "\nNext: from the repository root run ./setupK8s.bash, then ./deployScylla.bash\n"
}

require_command oci
require_command kubectl
require_command jq
require_command base64
require_command grep

[[ -r ${configFile} ]] \
  || die "configuration file ${configFile} was not found; copy oke.conf.example to oke.conf"
# shellcheck source=/dev/null
source "${configFile}" || die "could not source ${configFile}"

: "${OCI_REGION:?OCI_REGION must be set in ${configFile}}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID must be set in ${configFile}}"
: "${OKE_CLUSTER_NAME:?OKE_CLUSTER_NAME must be set in ${configFile}}"
[[ ${OCI_COMPARTMENT_OCID} == ocid1.compartment.* && ${OCI_COMPARTMENT_OCID} != *replace-me* ]] \
  || die "OCI_COMPARTMENT_OCID must be a real compartment OCID"

OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
OKE_VCN_NAME="${OKE_VCN_NAME:-${OKE_CLUSTER_NAME}-vcn}"
OKE_KUBECONFIG_FILE="${KUBECONFIG:-${HOME}/.kube/config}"
K8S_VERSION="${K8S_VERSION:-}"
OCI_AD="${OCI_AD:-}"
GENERAL_NODE_SHAPE="${GENERAL_NODE_SHAPE:-VM.Standard.E4.Flex}"
GENERAL_NODE_OCPUS="${GENERAL_NODE_OCPUS:-4}"
GENERAL_NODE_MEMORY_GBS="${GENERAL_NODE_MEMORY_GBS:-32}"
GENERAL_NODE_COUNT="${GENERAL_NODE_COUNT:-1}"
GENERAL_NODE_ARCH="${GENERAL_NODE_ARCH:-X86_64}"
GENERAL_NODE_IMAGE_OCID="${GENERAL_NODE_IMAGE_OCID:-${OKE_NODE_IMAGE_OCID:-}}"
SCYLLA_NODE_SHAPE="${SCYLLA_NODE_SHAPE:-VM.DenseIO2.8}"
SCYLLA_NODE_OCPUS="${SCYLLA_NODE_OCPUS:-8}"
SCYLLA_NODE_MEMORY_GBS="${SCYLLA_NODE_MEMORY_GBS:-128}"
SCYLLA_NODE_COUNT="${SCYLLA_NODE_COUNT:-3}"
SCYLLA_NODE_ARCH="${SCYLLA_NODE_ARCH:-X86_64}"
SCYLLA_NODE_IMAGE_OCID="${SCYLLA_NODE_IMAGE_OCID:-${OKE_NODE_IMAGE_OCID:-}}"
CREATE_APPLICATION_POOL="${CREATE_APPLICATION_POOL:-false}"
APPLICATION_NODE_SHAPE="${APPLICATION_NODE_SHAPE:-VM.Standard.E4.Flex}"
APPLICATION_NODE_OCPUS="${APPLICATION_NODE_OCPUS:-2}"
APPLICATION_NODE_MEMORY_GBS="${APPLICATION_NODE_MEMORY_GBS:-16}"
APPLICATION_NODE_COUNT="${APPLICATION_NODE_COUNT:-1}"
APPLICATION_NODE_ARCH="${APPLICATION_NODE_ARCH:-X86_64}"
APPLICATION_NODE_IMAGE_OCID="${APPLICATION_NODE_IMAGE_OCID:-${OKE_NODE_IMAGE_OCID:-}}"
NODE_BOOT_VOLUME_GBS="${NODE_BOOT_VOLUME_GBS:-100}"
VCN_CIDR="${VCN_CIDR:-10.0.0.0/16}"
CONTROL_PLANE_SUBNET_CIDR="${CONTROL_PLANE_SUBNET_CIDR:-10.0.0.0/24}"
WORKER_SUBNET_CIDR="${WORKER_SUBNET_CIDR:-10.0.1.0/24}"
LOAD_BALANCER_SUBNET_CIDR="${LOAD_BALANCER_SUBNET_CIDR:-10.0.2.0/24}"
API_INGRESS_CIDR="${API_INGRESS_CIDR:-0.0.0.0/0}"
LOAD_BALANCER_INGRESS_CIDR="${LOAD_BALANCER_INGRESS_CIDR:-0.0.0.0/0}"

[[ ${OKE_CLUSTER_NAME} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
  || die "OKE_CLUSTER_NAME must be a lowercase DNS-style name"
[[ ${OKE_KUBECONFIG_FILE} != *:* ]] \
  || die "KUBECONFIG must name one file, not a colon-separated list"
export KUBECONFIG="${OKE_KUBECONFIG_FILE}"
OKE_RESOURCE_TAGS=$(jq -cn --arg name "${OKE_CLUSTER_NAME}" \
  '{scylla_k8s_example_oke:$name}') \
  || die "could not build OCI resource ownership tags"

validate_positive_integer GENERAL_NODE_COUNT "${GENERAL_NODE_COUNT}"
validate_positive_integer SCYLLA_NODE_COUNT "${SCYLLA_NODE_COUNT}"
validate_positive_integer NODE_BOOT_VOLUME_GBS "${NODE_BOOT_VOLUME_GBS}"
[[ ${SCYLLA_NODE_COUNT} -eq 3 ]] \
  || die "SCYLLA_NODE_COUNT must be exactly 3 for the fixed three-rack deployment"
[[ ${SCYLLA_NODE_SHAPE} == *DenseIO* ]] \
  || die "SCYLLA_NODE_SHAPE must be a DenseIO shape with local NVMe storage"
if [[ ${GENERAL_NODE_SHAPE} == *.Flex ]]; then
  validate_positive_integer GENERAL_NODE_OCPUS "${GENERAL_NODE_OCPUS}"
  validate_positive_integer GENERAL_NODE_MEMORY_GBS "${GENERAL_NODE_MEMORY_GBS}"
fi
if [[ ${SCYLLA_NODE_SHAPE} == *.Flex ]]; then
  validate_positive_integer SCYLLA_NODE_OCPUS "${SCYLLA_NODE_OCPUS}"
  validate_positive_integer SCYLLA_NODE_MEMORY_GBS "${SCYLLA_NODE_MEMORY_GBS}"
fi
if [[ ${SCYLLA_NODE_SHAPE} == "VM.DenseIO.E4.Flex" ]]; then
  case "${SCYLLA_NODE_OCPUS}:${SCYLLA_NODE_MEMORY_GBS}" in
    8:128|16:256|32:512) ;;
    *) die "VM.DenseIO.E4.Flex supports 8:128, 16:256, or 32:512 OCPU:memory" ;;
  esac
fi
if [[ ${CREATE_APPLICATION_POOL} == true ]]; then
  validate_positive_integer APPLICATION_NODE_COUNT "${APPLICATION_NODE_COUNT}"
  if [[ ${APPLICATION_NODE_SHAPE} == *.Flex ]]; then
    validate_positive_integer APPLICATION_NODE_OCPUS "${APPLICATION_NODE_OCPUS}"
    validate_positive_integer APPLICATION_NODE_MEMORY_GBS "${APPLICATION_NODE_MEMORY_GBS}"
  fi
elif [[ ${CREATE_APPLICATION_POOL} != false ]]; then
  die "CREATE_APPLICATION_POOL must be true or false"
fi

if ! oci iam region list --profile "${OCI_CLI_PROFILE}" > /dev/null 2>&1; then
  die "OCI CLI profile ${OCI_CLI_PROFILE} is not authenticated; run 'oci setup config'"
fi

RESUME_EXISTING=false
case "${1:-}" in
  "")
    create_oke
    ;;
  -r|--resume)
    RESUME_EXISTING=true
    create_oke
    ;;
  -d|-x)
    delete_oke
    ;;
  *)
    die "usage: ${BASH_SOURCE[0]##*/} [--resume|-r|-d|-x]"
    ;;
esac
