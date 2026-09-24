#!/usr/bin/env bash

set -euo pipefail

scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../oke-lifecycle.bash
source "${scriptDir}/oke-lifecycle.bash"

OKE_CLUSTER_NAME=scylladb-demo
OKE_VCN_NAME=scylladb-demo-vcn
OKE_DISCOVERY_RETRY_ATTEMPTS=3
OKE_DISCOVERY_RETRY_DELAY_SECONDS=1
SCENARIO=""

sleep() {
  :
}

record() {
  local type=$1
  local name=$2
  local id=$3
  local state=$4
  local owner=$5
  jq -cn \
    --arg type "${type}" \
    --arg name "${name}" \
    --arg id "${id}" \
    --arg state "${state}" \
    --arg owner "${owner}" \
    '[{resource_type:$type,name:$name,id:$id,state:$state,owner:$owner}]'
}

list_oke_cluster_records() {
  case "${SCENARIO}" in
    active-owned)
      record "OKE cluster" "${OKE_CLUSTER_NAME}" cluster-active ACTIVE "${OKE_CLUSTER_NAME}"
      ;;
    active-unowned)
      record "OKE cluster" "${OKE_CLUSTER_NAME}" cluster-foreign ACTIVE another-owner
      ;;
    terminal|fully-deleted)
      record "OKE cluster" "${OKE_CLUSTER_NAME}" cluster-deleted DELETED "${OKE_CLUSTER_NAME}"
      ;;
    eventual)
      if ((OKE_DISCOVERY_ATTEMPT < 3)); then
        record "OKE cluster" "${OKE_CLUSTER_NAME}" cluster-deleting DELETING "${OKE_CLUSTER_NAME}"
      else
        printf '[]\n'
      fi
      ;;
    valid-resume)
      record "OKE cluster" "${OKE_CLUSTER_NAME}" cluster-live ACTIVE "${OKE_CLUSTER_NAME}"
      ;;
    *)
      printf '[]\n'
      ;;
  esac
}

list_oke_vcn_records() {
  case "${SCENARIO}" in
    terminal|fully-deleted)
      record "VCN" "${OKE_VCN_NAME}" vcn-terminated TERMINATED "${OKE_CLUSTER_NAME}"
      ;;
    valid-resume)
      record "VCN" "${OKE_VCN_NAME}" vcn-live AVAILABLE "${OKE_CLUSTER_NAME}"
      ;;
    *)
      printf '[]\n'
      ;;
  esac
}

assert_contains() {
  [[ $1 == *"$2"* ]] || {
    printf 'expected output to contain: %s\nactual: %s\n' "$2" "$1" >&2
    exit 1
  }
}

test_active_owned_collision() {
  local output
  SCENARIO=active-owned
  if output=$(oke_check_create_collisions 2>&1); then
    printf 'active owned collision unexpectedly passed\n' >&2
    return 1
  fi
  assert_contains "${output}" "state=ACTIVE"
  assert_contains "${output}" "owned(tag scylla_k8s_example_oke=scylladb-demo)"
}

test_active_unowned_collision() {
  local output
  SCENARIO=active-unowned
  if output=$(oke_check_create_collisions 2>&1); then
    printf 'active unowned collision unexpectedly passed\n' >&2
    return 1
  fi
  assert_contains "${output}" "ownership=unowned"
  assert_contains "${output}" "cluster-foreign"
}

test_terminal_stale_records() {
  local output
  SCENARIO=terminal
  output=$(oke_check_create_collisions 2>&1)
  assert_contains "${output}" "Ignoring terminal OCI record"
  assert_contains "${output}" "state=DELETED"
  assert_contains "${output}" "state=TERMINATED"
}

test_eventual_consistency_disappearance() {
  local output
  SCENARIO=eventual
  output=$(oke_check_create_collisions 2>&1)
  assert_contains "${output}" "Waiting for deleting OCI record"
  assert_contains "${output}" "state=DELETING"
}

set_available_resume_network() {
  OKE_VCN_OCID=vcn-live
  OKE_IGW_OCID=igw-live
  OKE_IGW_STATE=AVAILABLE
  OKE_NATGW_OCID=nat-live
  OKE_NATGW_STATE=AVAILABLE
  OKE_PUBLIC_RT_OCID=rt-public-live
  OKE_PUBLIC_RT_STATE=AVAILABLE
  OKE_PRIVATE_RT_OCID=rt-private-live
  OKE_PRIVATE_RT_STATE=AVAILABLE
  OKE_PUBLIC_SL_OCID=sl-public-live
  OKE_PUBLIC_SL_STATE=AVAILABLE
  OKE_PRIVATE_SL_OCID=sl-private-live
  OKE_PRIVATE_SL_STATE=AVAILABLE
  OKE_CP_SUBNET_OCID=subnet-cp-live
  OKE_CP_SUBNET_STATE=AVAILABLE
  OKE_WORKERS_SUBNET_OCID=subnet-workers-live
  OKE_WORKERS_SUBNET_STATE=AVAILABLE
  OKE_LB_SUBNET_OCID=subnet-lb-live
  OKE_LB_SUBNET_STATE=AVAILABLE
}

test_valid_partial_resume() {
  SCENARIO=valid-resume
  oke_select_resume_parents
  [[ ${OKE_RESUME_CLUSTER_OCID} == "cluster-live" ]]
  [[ ${OKE_RESUME_VCN_OCID} == "vcn-live" ]]
  set_available_resume_network
  oke_validate_resume_network
}

test_fully_deleted_deployment_is_not_resumable() {
  local output
  SCENARIO=fully-deleted
  if output=$(oke_select_resume_parents 2>&1); then
    printf 'fully deleted deployment unexpectedly resumed\n' >&2
    return 1
  fi
  assert_contains "${output}" "Resume ignored terminal OCI record"
}

test_teardown_verification_rejects_live_owned_parent() {
  local output
  SCENARIO=active-owned
  if output=$(oke_verify_no_live_owned_parents 2>&1); then
    printf 'teardown verification unexpectedly accepted a live owned parent\n' >&2
    return 1
  fi
  assert_contains "${output}" "Live owned resource remains after teardown"
  assert_contains "${output}" "cluster-active"
}

test_active_owned_collision
test_active_unowned_collision
test_terminal_stale_records
test_eventual_consistency_disappearance
test_valid_partial_resume
test_fully_deleted_deployment_is_not_resumable
test_teardown_verification_rejects_live_owned_parent
printf 'OKE lifecycle tests passed\n'
