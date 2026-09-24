#!/usr/bin/env bash

# Lifecycle-aware OCI discovery helpers for makeBasicCluster.bash.
# The caller provides capture_oci and the OKE/OCI configuration variables.

oke_normalize_cluster_records() {
  local raw=${1:-}
  [[ -n ${raw} ]] || raw='{"data":[]}'
  jq -c --arg name "${OKE_CLUSTER_NAME}" '
    [
      (.data // [])[]
      | select(.name == $name)
      | {
          resource_type: "OKE cluster",
          name: .name,
          id: .id,
          state: (."lifecycle-state" // "UNKNOWN"),
          owner: (."freeform-tags".scylla_k8s_example_oke // "")
        }
    ]
  ' <<< "${raw}"
}

oke_normalize_vcn_records() {
  local raw=${1:-}
  [[ -n ${raw} ]] || raw='{"data":[]}'
  jq -c --arg name "${OKE_VCN_NAME}" '
    [
      (.data // [])[]
      | select(."display-name" == $name)
      | {
          resource_type: "VCN",
          name: ."display-name",
          id: .id,
          state: (."lifecycle-state" // "UNKNOWN"),
          owner: (."freeform-tags".scylla_k8s_example_oke // ""),
          default_route_table_id: (."default-route-table-id" // ""),
          default_security_list_id: (."default-security-list-id" // ""),
          default_dhcp_options_id: (."default-dhcp-options-id" // "")
        }
    ]
  ' <<< "${raw}"
}

list_oke_cluster_records() {
  local raw
  capture_oci raw ce cluster list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --name "${OKE_CLUSTER_NAME}" \
    --all \
    --output json
  oke_normalize_cluster_records "${raw}"
}

list_oke_vcn_records() {
  local raw
  capture_oci raw network vcn list \
    --region "${OCI_REGION}" \
    --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --display-name "${OKE_VCN_NAME}" \
    --all \
    --output json
  oke_normalize_vcn_records "${raw}"
}

oke_terminal_records() {
  jq -c '
    [
      .[]
      | select((.state | ascii_upcase) == "DELETED"
          or (.state | ascii_upcase) == "TERMINATED")
    ]
  ' <<< "$1"
}

oke_live_records() {
  jq -c '
    [
      .[]
      | select((.state | ascii_upcase) != "DELETED"
          and (.state | ascii_upcase) != "TERMINATED")
    ]
  ' <<< "$1"
}

oke_transitioning_records() {
  jq -c '
    [
      .[]
      | select((.state | ascii_upcase) == "DELETING"
          or (.state | ascii_upcase) == "TERMINATING")
    ]
  ' <<< "$1"
}

oke_nontransitioning_records() {
  jq -c '
    [
      .[]
      | select((.state | ascii_upcase) != "DELETING"
          and (.state | ascii_upcase) != "TERMINATING")
    ]
  ' <<< "$1"
}

oke_owned_records() {
  jq -c --arg owner "${OKE_CLUSTER_NAME}" \
    '[.[] | select(.owner == $owner)]' <<< "$1"
}

oke_unowned_records() {
  jq -c --arg owner "${OKE_CLUSTER_NAME}" \
    '[.[] | select(.owner != $owner)]' <<< "$1"
}

oke_record_count() {
  jq -r 'length' <<< "$1"
}

oke_join_records() {
  jq -cn --argjson first "$1" --argjson second "$2" \
    '$first + $second'
}

oke_report_records() {
  local prefix=$1
  local records=$2
  local line
  while IFS= read -r line; do
    [[ -n ${line} ]] && printf '%s: %s\n' "${prefix}" "${line}" >&2
  done < <(
    jq -r --arg expectedOwner "${OKE_CLUSTER_NAME}" '
      .[]
      | "\(.resource_type) name=\(.name) ocid=\(.id) state=\(.state) ownership="
        + if .owner == $expectedOwner then
            "owned(tag scylla_k8s_example_oke=\(.owner))"
          elif .owner == "" then
            "unowned(tag missing)"
          else
            "unowned(tag scylla_k8s_example_oke=\(.owner))"
          end
    ' <<< "${records}"
  )
}

oke_check_create_collisions() {
  local attempts=${OKE_DISCOVERY_RETRY_ATTEMPTS:-6}
  local delaySeconds=${OKE_DISCOVERY_RETRY_DELAY_SECONDS:-10}
  local attempt
  local clusterRecords
  local vcnRecords
  local allRecords
  local terminalRecords
  local liveRecords
  local transitioningRecords
  local nontransitioningRecords
  local unownedRecords

  OKE_LIFECYCLE_ERROR=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    OKE_DISCOVERY_ATTEMPT=${attempt}
    clusterRecords=$(list_oke_cluster_records) || return 1
    vcnRecords=$(list_oke_vcn_records) || return 1
    allRecords=$(oke_join_records "${clusterRecords}" "${vcnRecords}") || return 1
    terminalRecords=$(oke_terminal_records "${allRecords}") || return 1
    liveRecords=$(oke_live_records "${allRecords}") || return 1

    if [[ $(oke_record_count "${liveRecords}") -eq 0 ]]; then
      if [[ $(oke_record_count "${terminalRecords}") -gt 0 ]]; then
        oke_report_records "Ignoring terminal OCI record" "${terminalRecords}"
      fi
      return 0
    fi

    transitioningRecords=$(oke_transitioning_records "${liveRecords}") || return 1
    nontransitioningRecords=$(oke_nontransitioning_records "${liveRecords}") || return 1
    if [[ $(oke_record_count "${nontransitioningRecords}") -gt 0 ]]; then
      oke_report_records "Create collision" "${liveRecords}"
      unownedRecords=$(oke_unowned_records "${liveRecords}") || return 1
      if [[ $(oke_record_count "${unownedRecords}") -gt 0 ]]; then
        OKE_LIFECYCLE_ERROR="live unowned same-named OCI resources block creation; rename them or choose another OKE_CLUSTER_NAME"
      else
        OKE_LIFECYCLE_ERROR="live tagged OCI resources block creation; use --resume for a valid partial deployment, or -d before recreating it"
      fi
      return 1
    fi

    if ((attempt == attempts)); then
      oke_report_records "Create collision after bounded wait" "${transitioningRecords}"
      OKE_LIFECYCLE_ERROR="same-named OCI resources are still deleting after ${attempts} discovery attempts; wait for OCI and rerun --preflight"
      return 1
    fi

    if ((attempt == 1)); then
      oke_report_records "Waiting for deleting OCI record" "${transitioningRecords}"
    fi
    sleep "${delaySeconds}"
  done
}

oke_select_resume_parents() {
  local clusterRecords
  local vcnRecords
  local liveClusters
  local liveVcns
  local ownedClusters
  local ownedVcns
  local allRecords
  local terminalRecords

  OKE_LIFECYCLE_ERROR=""
  clusterRecords=$(list_oke_cluster_records) || return 1
  vcnRecords=$(list_oke_vcn_records) || return 1
  liveClusters=$(oke_live_records "${clusterRecords}") || return 1
  liveVcns=$(oke_live_records "${vcnRecords}") || return 1
  ownedClusters=$(oke_owned_records "${liveClusters}") || return 1
  ownedVcns=$(oke_owned_records "${liveVcns}") || return 1

  if [[ $(oke_record_count "${liveClusters}") -ne 1 \
      || $(oke_record_count "${liveVcns}") -ne 1 \
      || $(oke_record_count "${ownedClusters}") -ne 1 \
      || $(oke_record_count "${ownedVcns}") -ne 1 ]]; then
    allRecords=$(oke_join_records "${clusterRecords}" "${vcnRecords}") || return 1
    terminalRecords=$(oke_terminal_records "${allRecords}") || return 1
    if [[ $(oke_record_count "${terminalRecords}") -gt 0 ]]; then
      oke_report_records "Resume ignored terminal OCI record" "${terminalRecords}"
    fi
    if [[ $(oke_record_count "${liveClusters}") -gt 0 ]]; then
      oke_report_records "Resume cluster candidate" "${liveClusters}"
    fi
    if [[ $(oke_record_count "${liveVcns}") -gt 0 ]]; then
      oke_report_records "Resume VCN candidate" "${liveVcns}"
    fi
    OKE_LIFECYCLE_ERROR="cannot resume: expected exactly one live tagged OKE cluster and VCN; use normal create for a fully deleted deployment"
    return 1
  fi

  OKE_RESUME_CLUSTER_OCID=$(jq -r '.[0].id' <<< "${ownedClusters}")
  OKE_RESUME_CLUSTER_STATE=$(jq -r '.[0].state' <<< "${ownedClusters}")
  OKE_RESUME_VCN_OCID=$(jq -r '.[0].id' <<< "${ownedVcns}")
  OKE_RESUME_VCN_STATE=$(jq -r '.[0].state' <<< "${ownedVcns}")

  if [[ ${OKE_RESUME_CLUSTER_STATE} != "ACTIVE" \
      || ${OKE_RESUME_VCN_STATE} != "AVAILABLE" ]]; then
    oke_report_records "Invalid resume parent" \
      "$(oke_join_records "${ownedClusters}" "${ownedVcns}")"
    OKE_LIFECYCLE_ERROR="cannot resume: the tagged OKE cluster must be ACTIVE and its VCN must be AVAILABLE"
    return 1
  fi
}

oke_validate_resume_network() {
  local resourceType
  local ocidVariable
  local stateVariable
  local resourceOcid
  local resourceState
  local resourceTypeAndVariables
  local invalid=false
  local resourceVariables=(
    "internet-gateway:OKE_IGW_OCID:OKE_IGW_STATE"
    "nat-gateway:OKE_NATGW_OCID:OKE_NATGW_STATE"
    "public-route-table:OKE_PUBLIC_RT_OCID:OKE_PUBLIC_RT_STATE"
    "private-route-table:OKE_PRIVATE_RT_OCID:OKE_PRIVATE_RT_STATE"
    "public-security-list:OKE_PUBLIC_SL_OCID:OKE_PUBLIC_SL_STATE"
    "private-security-list:OKE_PRIVATE_SL_OCID:OKE_PRIVATE_SL_STATE"
    "control-plane-subnet:OKE_CP_SUBNET_OCID:OKE_CP_SUBNET_STATE"
    "worker-subnet:OKE_WORKERS_SUBNET_OCID:OKE_WORKERS_SUBNET_STATE"
    "load-balancer-subnet:OKE_LB_SUBNET_OCID:OKE_LB_SUBNET_STATE"
  )

  OKE_LIFECYCLE_ERROR=""
  for resourceTypeAndVariables in "${resourceVariables[@]}"; do
    IFS=: read -r resourceType ocidVariable stateVariable \
      <<< "${resourceTypeAndVariables}"
    resourceOcid=${!ocidVariable:-}
    resourceState=${!stateVariable:-}
    if [[ -z ${resourceOcid} || ${resourceState} != "AVAILABLE" ]]; then
      printf 'Invalid resume network resource: type=%s ocid=%s state=%s ownership=inherited(tagged-vcn=%s)\n' \
        "${resourceType}" "${resourceOcid:-missing}" "${resourceState:-missing}" \
        "${OKE_VCN_OCID:-missing}" >&2
      invalid=true
    fi
  done

  if [[ ${invalid} == true ]]; then
    OKE_LIFECYCLE_ERROR="cannot resume: the tagged VCN does not contain one live AVAILABLE instance of every expected gateway, route table, security list, and subnet"
    return 1
  fi
}

oke_verify_no_live_owned_parents() {
  local attempts=${OKE_DISCOVERY_RETRY_ATTEMPTS:-6}
  local delaySeconds=${OKE_DISCOVERY_RETRY_DELAY_SECONDS:-10}
  local attempt
  local clusterRecords
  local vcnRecords
  local liveClusters
  local liveVcns
  local ownedClusters
  local ownedVcns
  local ownedLive

  OKE_LIFECYCLE_ERROR=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    OKE_DISCOVERY_ATTEMPT=${attempt}
    clusterRecords=$(list_oke_cluster_records) || return 1
    vcnRecords=$(list_oke_vcn_records) || return 1
    liveClusters=$(oke_live_records "${clusterRecords}") || return 1
    liveVcns=$(oke_live_records "${vcnRecords}") || return 1
    ownedClusters=$(oke_owned_records "${liveClusters}") || return 1
    ownedVcns=$(oke_owned_records "${liveVcns}") || return 1
    ownedLive=$(oke_join_records "${ownedClusters}" "${ownedVcns}") || return 1
    if [[ $(oke_record_count "${ownedLive}") -eq 0 ]]; then
      return 0
    fi
    if ((attempt == attempts)); then
      oke_report_records "Live owned resource remains after teardown" "${ownedLive}"
      OKE_LIFECYCLE_ERROR="teardown did not converge after ${attempts} discovery attempts"
      return 1
    fi
    sleep "${delaySeconds}"
  done
}
