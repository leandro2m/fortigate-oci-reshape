#!/bin/bash
# =============================================================================
# SCRIPT 1: Fetch all VNIC and Volume information from OCI instances by OCID
# VMs      : AT-BOG-PRD-CMP-FW1, AT-BOG-PRD-CMP-FW2
# Usage    : ./1_fetch_vnic_info.sh
# Output   : vnic_backup_<VM_NAME>.json per instance
# Requires : oci cli, jq
# =============================================================================

# ---------------------------------------------------------------------------
# ⚙️  Instance OCIDs to process
# ---------------------------------------------------------------------------
INSTANCE_OCIDS=(
  "ocid.FortiGate.VM.Active"   # FW1 - Active
  "ocid.FortiGate.VM.Passive"   # FW2 - Passive
)

# ---------------------------------------------------------------------------
# Helper: fetch info for a single VM by OCID
# ---------------------------------------------------------------------------
fetch_vm_info() {
  local INSTANCE_ID="$1"

  echo ""
  echo "============================================="
  echo " Processing OCID: $INSTANCE_ID"
  echo "============================================="

  # ---- 1. Get instance details --------------------------------------------
  echo ""
  echo "[1/5] Fetching instance details..."
  INSTANCE_JSON=$(oci compute instance get \
    --instance-id "$INSTANCE_ID" \
    --query 'data' 2>&1)

  if echo "$INSTANCE_JSON" | grep -q "ServiceError\|Error\|error"; then
    echo "  ERROR: Could not fetch instance details."
    echo "  $INSTANCE_JSON"
    return 1
  fi

  COMPARTMENT_ID=$(echo "$INSTANCE_JSON" | jq -r '."compartment-id"')
  VM_NAME=$(echo        "$INSTANCE_JSON" | jq -r '."display-name"')
  INSTANCE_SHAPE=$(echo "$INSTANCE_JSON" | jq -r '.shape')
  INSTANCE_AD=$(echo    "$INSTANCE_JSON" | jq -r '."availability-domain"')
  OUTPUT_FILE="vnic_backup_${VM_NAME}.json"

  echo "  ✅ Found instance"
  echo "  VM Name       : $VM_NAME"
  echo "  Shape         : $INSTANCE_SHAPE"
  echo "  Compartment   : $COMPARTMENT_ID"
  echo "  Avail. Domain : $INSTANCE_AD"

  # ---- 2. List VNIC attachments -------------------------------------------
  echo ""
  echo "[2/5] Listing VNIC attachments..."
  VNIC_ATTACHMENTS=$(oci compute vnic-attachment list \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-id    "$INSTANCE_ID" \
    --query 'data' 2>&1)

  if echo "$VNIC_ATTACHMENTS" | grep -q "ServiceError\|Error\|error"; then
    echo "  ERROR: Could not list VNIC attachments."
    echo "  $VNIC_ATTACHMENTS"
    return 1
  fi

  VNIC_COUNT=$(echo "$VNIC_ATTACHMENTS" | jq '. | length')
  echo "  Found $VNIC_COUNT VNIC(s)"

  # ---- 3. Fetch full VNIC details -----------------------------------------
  echo ""
  echo "[3/5] Fetching VNIC details..."
  VNICS_FULL="[]"

  for i in $(seq 0 $((VNIC_COUNT - 1))); do
    ATTACHMENT=$(echo "$VNIC_ATTACHMENTS" | jq ".[$i]")
    VNIC_ID=$(echo    "$ATTACHMENT" | jq -r '."vnic-id"')
    NIC_INDEX=$(echo  "$ATTACHMENT" | jq -r '."nic-index"')

    echo "  VNIC [$i] index=$NIC_INDEX : $VNIC_ID"

    VNIC_DETAIL=$(oci network vnic get \
      --vnic-id "$VNIC_ID" \
      --query 'data' 2>&1)

    if echo "$VNIC_DETAIL" | grep -q "ServiceError\|Error\|error"; then
      echo "  WARNING: Could not fetch details for VNIC $VNIC_ID"
      continue
    fi

    PRIVATE_IPS=$(oci network private-ip list \
      --vnic-id "$VNIC_ID" \
      --query 'data' 2>&1)

    MERGED=$(jq -n \
      --argjson attachment  "$ATTACHMENT" \
      --argjson vnic        "$VNIC_DETAIL" \
      --argjson private_ips "$PRIVATE_IPS" \
      '{
        attachment_id:      $attachment.id,
        vnic_id:            $attachment."vnic-id",
        nic_index:          $attachment."nic-index",
        vlan_tag:           $attachment."vlan-tag",
        display_name:       $vnic."display-name",
        hostname_label:     $vnic."hostname-label",
        subnet_id:          $vnic."subnet-id",
        mac_address:        $vnic."mac-address",
        is_primary:         $vnic."is-primary",
        skip_src_dst_check: $vnic."skip-source-dest-check",
        private_ip:         $vnic."private-ip",
        public_ip:          $vnic."public-ip",
        nsg_ids:            $vnic."nsg-ids",
        private_ip_details: $private_ips
      }')

    VNICS_FULL=$(echo "$VNICS_FULL" | jq ". += [$MERGED]")
  done

  # ---- 4. Fetch attached volumes (boot + data) ----------------------------
  echo ""
  echo "[4/5] Fetching attached volumes..."
  VOLUMES_FULL="[]"

  # Boot volume
  BOOT_ATTACH=$(oci compute boot-volume-attachment list \
    --compartment-id      "$COMPARTMENT_ID" \
    --availability-domain "$INSTANCE_AD" \
    --instance-id         "$INSTANCE_ID" \
    --query 'data[0]' 2>&1)

  if ! echo "$BOOT_ATTACH" | grep -q "ServiceError\|Error\|error"; then
    BOOT_VOL_ID=$(echo "$BOOT_ATTACH" | jq -r '."boot-volume-id" // empty')
    if [ -n "$BOOT_VOL_ID" ]; then
      BOOT_DETAIL=$(oci bv boot-volume get \
        --boot-volume-id "$BOOT_VOL_ID" \
        --query 'data' 2>&1)

      if ! echo "$BOOT_DETAIL" | grep -q "ServiceError\|Error\|error"; then
        BOOT_MERGED=$(jq -n \
          --argjson detail "$BOOT_DETAIL" \
          --arg attach_id "$(echo "$BOOT_ATTACH" | jq -r '.id')" \
          '{
            attachment_id:   $attach_id,
            volume_id:       $detail.id,
            attachment_type: "boot",
            device:          "/dev/sda",
            is_read_only:    false,
            is_boot:         true,
            display_name:    $detail."display-name",
            size_in_gbs:     $detail."size-in-gbs",
            vpus_per_gb:     ($detail."vpus-per-gb" // 10),
            lifecycle_state: $detail."lifecycle-state"
          }')
        VOLUMES_FULL=$(echo "$VOLUMES_FULL" | jq ". += [$BOOT_MERGED]")
        echo "  ✅ Boot volume : $(echo "$BOOT_DETAIL" | jq -r '."display-name"') — $(echo "$BOOT_DETAIL" | jq -r '."size-in-gbs"') GB"
      fi
    fi
  fi

  # Data volumes
  VOL_ATTACHMENTS=$(oci compute volume-attachment list \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-id    "$INSTANCE_ID" \
    --query 'data' 2>&1)

  if ! echo "$VOL_ATTACHMENTS" | grep -q "ServiceError\|Error\|error"; then
    VOL_COUNT=$(echo "$VOL_ATTACHMENTS" | jq '. | length')
    echo "  Found $VOL_COUNT data volume attachment(s)"

    for i in $(seq 0 $((VOL_COUNT - 1))); do
      VOL_ATTACH=$(echo "$VOL_ATTACHMENTS" | jq ".[$i]")
      VOLUME_ID=$(echo  "$VOL_ATTACH" | jq -r '."volume-id"')
      DEVICE=$(echo     "$VOL_ATTACH" | jq -r '.device // "n/a"')

      VOL_DETAIL=$(oci bv volume get \
        --volume-id "$VOLUME_ID" \
        --query 'data' 2>&1)

      if echo "$VOL_DETAIL" | grep -q "ServiceError\|Error\|error"; then
        echo "  WARNING: Could not fetch details for volume $VOLUME_ID"
        continue
      fi

      VOL_MERGED=$(jq -n \
        --argjson attach "$VOL_ATTACH" \
        --argjson detail "$VOL_DETAIL" \
        '{
          attachment_id:   $attach.id,
          volume_id:       $attach."volume-id",
          attachment_type: $attach."attachment-type",
          device:          ($attach.device // "n/a"),
          is_read_only:    $attach."is-read-only",
          is_boot:         false,
          display_name:    $detail."display-name",
          size_in_gbs:     $detail."size-in-gbs",
          vpus_per_gb:     $detail."vpus-per-gb",
          lifecycle_state: $detail."lifecycle-state"
        }')

      VOLUMES_FULL=$(echo "$VOLUMES_FULL" | jq ". += [$VOL_MERGED]")
      echo "  ✅ Data volume : $(echo "$VOL_DETAIL" | jq -r '."display-name"') — $(echo "$VOL_DETAIL" | jq -r '."size-in-gbs"') GB (device: $DEVICE)"
    done
  fi

  # ---- 5. Save backup JSON ------------------------------------------------
  echo ""
  echo "[5/5] Saving to $OUTPUT_FILE..."

  BACKUP=$(jq -n \
    --arg instance_id         "$INSTANCE_ID" \
    --arg instance_name       "$VM_NAME" \
    --arg compartment_id      "$COMPARTMENT_ID" \
    --arg shape               "$INSTANCE_SHAPE" \
    --arg availability_domain "$INSTANCE_AD" \
    --arg timestamp           "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson vnics           "$VNICS_FULL" \
    --argjson volumes         "$VOLUMES_FULL" \
    '{
      instance_id:         $instance_id,
      instance_name:       $instance_name,
      compartment_id:      $compartment_id,
      shape:               $shape,
      availability_domain: $availability_domain,
      captured_at:         $timestamp,
      vnics:               $vnics,
      volumes:             $volumes
    }')

  echo "$BACKUP" > "$OUTPUT_FILE"

  echo ""
  echo "============================================="
  echo " Summary: $VM_NAME"
  echo "============================================="
  echo ""
  echo "  VNICs:"
  echo "$BACKUP" | jq -r '.vnics[] | "    [\(if .is_primary then "PRIMARY  " else "SECONDARY" end)] \(.display_name) | IP: \(.private_ip) | NIC index: \(.nic_index) | NSGs: \(.nsg_ids | length)"'
  echo ""
  echo "  Volumes:"
  echo "$BACKUP" | jq -r '.volumes[] | "    [\(if .is_boot then "BOOT" else "DATA" end)] \(.display_name) | \(.size_in_gbs) GB | device: \(.device)"'
  echo ""
  echo "  ✅ Saved: $OUTPUT_FILE"
}

# ---------------------------------------------------------------------------
# Main: process all OCIDs
# ---------------------------------------------------------------------------
ERRORS=0

for OCID in "${INSTANCE_OCIDS[@]}"; do
  fetch_vm_info "$OCID" || ERRORS=$((ERRORS + 1))
done

echo ""
echo "============================================="
if [ "$ERRORS" -eq 0 ]; then
  echo "✅ All instances fetched successfully."
  echo ""
  echo "Output files:"
  ls vnic_backup_*.json 2>/dev/null | while read -r f; do echo "  → $f"; done
  echo ""
  echo "Next steps:"
  echo "  → ./2_update_fw2.sh   (Passive  — run first)"
  echo "  → ./3_update_fw1.sh   (Active   — run after FW2 is validated)"
else
  echo "⚠️  Completed with $ERRORS error(s). Review the output above."
fi
echo "============================================="
