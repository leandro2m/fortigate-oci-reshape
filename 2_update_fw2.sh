#!/bin/bash
# =============================================================================
# reshape_vm.sh — Reshape any OCI VM: detach secondary VNICs, change shape,
#                 reattach VNICs with original config
#
# Usage    : Edit the variables below, then run: ./reshape_vm.sh
# Requires : oci cli, jq
# =============================================================================
 
# ---------------------------------------------------------------------------
# ⚙️  Configuration — edit these variables before running
# ---------------------------------------------------------------------------
INSTANCE_OCID="ocid1.instance.oc1.sa-bogota-1.anrgcljrskjhcsqczsflzsmrdufioxq5pb7m6cbu5fvldpj7sc7vkxeto7fa"
TARGET_SHAPE="VM.Standard.E5.Flex"
TARGET_OCPUS=4
TARGET_MEMORY_GB=64
BACKUP_FILE="vnic_backup_AT-BOG-PRD-CMP-FW2.json"
# ---------------------------------------------------------------------------
 
[ -z "$INSTANCE_OCID"    ] && echo "ERROR: INSTANCE_OCID is not set"    && exit 1
[ -z "$TARGET_SHAPE"     ] && echo "ERROR: TARGET_SHAPE is not set"     && exit 1
[ -z "$TARGET_OCPUS"     ] && echo "ERROR: TARGET_OCPUS is not set"     && exit 1
[ -z "$TARGET_MEMORY_GB" ] && echo "ERROR: TARGET_MEMORY_GB is not set" && exit 1
[ -z "$BACKUP_FILE"      ] && echo "ERROR: BACKUP_FILE is not set"      && exit 1
[ -f "$BACKUP_FILE"      ] || { echo "ERROR: Backup file not found: $BACKUP_FILE"; exit 1; }
 
# ---------------------------------------------------------------------------
# Load all values from backup — no hardcoding
# ---------------------------------------------------------------------------
COMPARTMENT_ID=$(jq -r '.compartment_id' "$BACKUP_FILE")
BACKUP_NAME=$(jq -r    '.instance_name'  "$BACKUP_FILE")
CURRENT_SHAPE=$(jq -r  '.shape'          "$BACKUP_FILE")
AVAIL_DOMAIN=$(jq -r   '.availability_domain' "$BACKUP_FILE")
 
# Secondary VNICs — loaded in attachment order: public → trust → hasync
# Order is enforced by matching display_name keywords; unmatched VNICs appended at end
mapfile -t _ALL_SECONDARY < <(jq -c '.vnics[] | select(.is_primary == false)' "$BACKUP_FILE")
 
SECONDARY_VNICS=()
declare -A _USED
 
# 1st: public
for V in "${_ALL_SECONDARY[@]}"; do
  NAME=$(echo "$V" | jq -r '.display_name' | tr '[:upper:]' '[:lower:]')
  if echo "$NAME" | grep -q "public"; then
    SECONDARY_VNICS+=("$V"); _USED["$V"]=1
  fi
done
 
# 2nd: trust
for V in "${_ALL_SECONDARY[@]}"; do
  NAME=$(echo "$V" | jq -r '.display_name' | tr '[:upper:]' '[:lower:]')
  if echo "$NAME" | grep -q "trust"; then
    SECONDARY_VNICS+=("$V"); _USED["$V"]=1
  fi
done
 
# 3rd: hasync / ha
for V in "${_ALL_SECONDARY[@]}"; do
  NAME=$(echo "$V" | jq -r '.display_name' | tr '[:upper:]' '[:lower:]')
  if echo "$NAME" | grep -qE "hasync|ha.sync|ha-sync"; then
    SECONDARY_VNICS+=("$V"); _USED["$V"]=1
  fi
done
 
# Remaining VNICs not matched by any keyword
for V in "${_ALL_SECONDARY[@]}"; do
  [ -z "${_USED[$V]}" ] && SECONDARY_VNICS+=("$V")
done
 
SECONDARY_COUNT=${#SECONDARY_VNICS[@]}
 
# Primary VNIC info (for summary)
PRIMARY_VNIC=$(jq -c '.vnics[] | select(.is_primary == true)' "$BACKUP_FILE" | head -1)
PRIMARY_IP=$(echo "$PRIMARY_VNIC" | jq -r '.private_ip')
 
# Volumes (for summary)
mapfile -t VOLUMES < <(jq -c '.volumes[]' "$BACKUP_FILE")
 
# ---------------------------------------------------------------------------
# Colors & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
 
log()    { echo -e "${GREEN}  ✅ $1${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
die()    { echo -e "\n${RED}  ❌ FATAL: $1${NC}"; echo "     Script aborted."; exit 1; }
header() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  printf  "║  %-52s║\n" "$1"
  echo "╚══════════════════════════════════════════════════════╝"
}
confirm() {
  local ANSWER
  read -r -p "  $1 (yes/no): " ANSWER
  [ "$ANSWER" = "yes" ] && return 0 || return 1
}
 
# ---------------------------------------------------------------------------
# Banner — all values from backup/args, nothing hardcoded
# ---------------------------------------------------------------------------
clear
echo "╔══════════════════════════════════════════════════════╗"
printf "║  VM     : %-43s║\n" "$BACKUP_NAME"
printf "║  OCID   : ...%-40s║\n" "${INSTANCE_OCID: -40}"
printf "║  Shape  : %-43s║\n" "$CURRENT_SHAPE → $TARGET_SHAPE ($TARGET_OCPUS OCPU/${TARGET_MEMORY_GB}GB)"
printf "║  Backup : %-43s║\n" "$BACKUP_FILE"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Primary VNIC IP : %-34s║\n" "$PRIMARY_IP (will NOT be touched)"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Secondary VNICs to detach → reattach:               ║"
for V in "${SECONDARY_VNICS[@]}"; do
  printf "║    • %-25s IP: %-20s║\n" \
    "$(echo "$V" | jq -r '.display_name')" \
    "$(echo "$V" | jq -r '.private_ip')"
done
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Volumes (not modified):                             ║"
for VOL in "${VOLUMES[@]}"; do
  printf "║    • %-25s %s GB %-12s║\n" \
    "$(echo "$VOL" | jq -r '.display_name' | cut -c1-25)" \
    "$(echo "$VOL" | jq -r '.size_in_gbs')" \
    "$(echo "$VOL" | jq -r 'if .is_boot then "[boot]" else "[data]" end')"
done
echo "╚══════════════════════════════════════════════════════╝"
echo ""
confirm "Before proceeding back up the configuration of $BACKUP_NAME. Do you want to proceed?" || { echo "Aborted."; exit 0; }
 
# ===========================================================================
# STEP 1 — Validate OCID matches backup
# ===========================================================================
header "STEP 1/4 — Validate instance"
echo ""
 
LIVE_JSON=$(oci compute instance get --instance-id "$INSTANCE_OCID" --query 'data' 2>&1)
echo "$LIVE_JSON" | grep -q "ServiceError\|Error\|error" && die "Cannot reach OCI API.\n$LIVE_JSON"
 
LIVE_NAME=$(echo  "$LIVE_JSON" | jq -r '."display-name"')
LIVE_STATE=$(echo "$LIVE_JSON" | jq -r '."lifecycle-state"')
LIVE_SHAPE=$(echo "$LIVE_JSON" | jq -r '.shape')
 
[ "$LIVE_NAME"  != "$BACKUP_NAME" ] && die "OCID resolves to '$LIVE_NAME' but backup is for '$BACKUP_NAME'."
[ "$LIVE_STATE" != "RUNNING"      ] && die "Instance is '$LIVE_STATE'. Must be RUNNING."
 
log "Instance : $LIVE_NAME"
log "State    : $LIVE_STATE"
log "Shape    : $LIVE_SHAPE"
 
# ===========================================================================
# STEP 2 — Detach all secondary VNICs
# ===========================================================================
header "STEP 2/4 — Detach $SECONDARY_COUNT secondary VNIC(s)"
echo ""
echo "  VNICs to be detached:"
for V in "${SECONDARY_VNICS[@]}"; do
  printf "    - %-38s IP: %s\n" \
    "$(echo "$V" | jq -r '.display_name')" \
    "$(echo "$V" | jq -r '.private_ip')"
done
echo ""
confirm "Detach these $SECONDARY_COUNT VNICs now?" || die "User cancelled at detach step."
echo ""
 
for V in "${SECONDARY_VNICS[@]}"; do
  DNAME=$(echo      "$V" | jq -r '.display_name')
  VNIC_ID=$(echo    "$V" | jq -r '.vnic_id')
  ATTACH_ID=$(echo  "$V" | jq -r '.attachment_id')
  PRIVATE_IP=$(echo "$V" | jq -r '.private_ip')
 
  echo "  Detaching: $DNAME (IP: $PRIVATE_IP)"
 
  RESULT=$(oci compute instance detach-vnic \
    --compartment-id "$COMPARTMENT_ID" \
    --vnic-id        "$VNIC_ID" \
    --force 2>&1)
 
  # If VNIC is already gone, treat as success
  if echo "$RESULT" | grep -q "404\|NotFound\|does not exist"; then
    log "Already detached: $DNAME"
    echo ""
    continue
  fi
 
  echo "$RESULT" | grep -q "ServiceError\|Error\|error" \
    && die "Failed to detach $DNAME:\n$RESULT"
 
  # Initial wait before first poll — give OCI time to start processing
  echo "  Waiting for detachment..."
  sleep 15
 
  DETACHED=false
  for ATTEMPT in $(seq 1 24); do
    STATUS=$(oci compute vnic-attachment get \
      --vnic-attachment-id "$ATTACH_ID" \
      --query 'data."lifecycle-state"' \
      --raw-output 2>&1)
 
    if echo "$STATUS" | grep -q "404\|NotAuthorized\|does not exist\|No such"; then
      DETACHED=true; break
    fi
    if [ "$STATUS" = "DETACHED" ]; then
      DETACHED=true; break
    fi
 
    echo "    Status: $STATUS (attempt $ATTEMPT/24)..."
    sleep 15
  done
 
  [ "$DETACHED" = "true" ] && log "Detached: $DNAME" || die "Timeout waiting for $DNAME to detach."
 
  # Extra settle time between VNICs — avoids 409 Conflict on next detach
  echo "  Settling..."
  sleep 10
  echo ""
done
 
# Final settle after all detaches before shape change
echo "  Waiting for instance to settle after all detaches..."
sleep 20
 
# ===========================================================================
# STEP 3 — Reshape VM
# ===========================================================================
header "STEP 3/4 — Reshape to $TARGET_SHAPE ($TARGET_OCPUS OCPU / ${TARGET_MEMORY_GB}GB)"
echo ""
echo "  From : $LIVE_SHAPE"
echo "  To   : $TARGET_SHAPE — $TARGET_OCPUS OCPUs / ${TARGET_MEMORY_GB} GB RAM"
echo ""
confirm "Confirm shape change?" || die "User cancelled at reshape step."
 
# Retry on 409 Conflict — instance may still be processing VNIC detach
RESULT=""
for RETRY in $(seq 1 10); do
  RESULT=$(oci compute instance update \
    --instance-id  "$INSTANCE_OCID" \
    --shape        "$TARGET_SHAPE" \
    --shape-config "{\"ocpus\": $TARGET_OCPUS, \"memoryInGBs\": $TARGET_MEMORY_GB}" \
    --force 2>&1)
 
  if echo "$RESULT" | grep -q "currently being modified"; then
    echo "  Instance still processing, waiting 30s... (attempt $RETRY/10)"
    sleep 30
    continue
  fi
  break
done
 
echo "$RESULT" | grep -q "ServiceError\|Error\|error" && die "Shape change failed:\n$RESULT"
log "Shape change submitted. Polling for RUNNING..."
echo ""
 
for ATTEMPT in $(seq 1 36); do
  STATUS=$(oci compute instance get \
    --instance-id "$INSTANCE_OCID" \
    --query 'data."lifecycle-state"' \
    --raw-output 2>&1)
  [ "$STATUS" = "RUNNING" ] && { log "Instance is RUNNING"; break; }
  echo "  Status: $STATUS (attempt $ATTEMPT/36)..."
  sleep 10
  [ "$ATTEMPT" -eq 36 ] && die "Timeout waiting for RUNNING state."
done
 
# ===========================================================================
# STEP 4 — Reattach secondary VNICs with original config
# ===========================================================================
header "STEP 4/4 — Reattach $SECONDARY_COUNT secondary VNIC(s)"
echo ""
echo "  Reattaching with original config:"
for V in "${SECONDARY_VNICS[@]}"; do
  printf "    - %-38s IP: %s  NIC: %s\n" \
    "$(echo "$V" | jq -r '.display_name')" \
    "$(echo "$V" | jq -r '.private_ip')" \
    "$(echo "$V" | jq -r '.nic_index')"
done
echo ""
confirm "Reattach all $SECONDARY_COUNT VNICs?" || die "User cancelled at reattach step."
echo ""
 
NEWLY_ATTACHED_IDS="[]"
 
for V in "${SECONDARY_VNICS[@]}"; do
  DNAME=$(echo      "$V" | jq -r '.display_name')
  SUBNET=$(echo     "$V" | jq -r '.subnet_id')
  PRIVATE_IP=$(echo "$V" | jq -r '.private_ip')
  HOSTNAME=$(echo   "$V" | jq -r '.hostname_label // empty')
  SKIP_SD=$(echo    "$V" | jq -r '.skip_src_dst_check')
  NIC_IDX=$(echo    "$V" | jq -r '.nic_index')
 
  echo "  Attaching: $DNAME | IP: $PRIVATE_IP | NIC index: $NIC_IDX | Skip S/D check: true"
 
  ATTACH_ARGS=(
    --instance-id   "$INSTANCE_OCID"
    --subnet-id     "$SUBNET"
    --vnic-display-name "$DNAME"
    --private-ip    "$PRIVATE_IP"
    --nic-index     "$NIC_IDX"
    --skip-source-dest-check "true"
  )
  [ -n "$HOSTNAME" ] && ATTACH_ARGS+=(--hostname-label "$HOSTNAME")
 
 
  # Snapshot current attachment IDs before calling attach
  PRE_IDS=$(oci compute vnic-attachment list \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-id    "$INSTANCE_OCID" \
    --all 2>&1 | jq -r '[.data[].id] | @json')
 
  ATTACH_ERR=$(oci compute instance attach-vnic "${ATTACH_ARGS[@]}" 2>&1)
 
  # IP already allocated = VNIC was already attached (safe to continue)
  if echo "$ATTACH_ERR" | grep -q "has already been allocated"; then
    warn "$DNAME — IP $PRIVATE_IP already allocated, VNIC already attached. Skipping."
    echo ""
    continue
  fi
 
  echo "$ATTACH_ERR" | grep -q "ServiceError\|Error\|error" \
    && die "Failed to attach $DNAME:\n$ATTACH_ERR"
 
  # Find new attachment ID by diffing before/after list
  echo "  Finding new attachment ID..."
  NEW_ATTACH_ID=""
  for POLL in $(seq 1 15); do
    sleep 6
    POST_ATTACH=$(oci compute vnic-attachment list \
      --compartment-id "$COMPARTMENT_ID" \
      --instance-id    "$INSTANCE_OCID" \
      --all 2>&1)
 
    NEW_ATTACH_ID=$(echo "$POST_ATTACH" | jq -r \
      --argjson pre "$PRE_IDS" \
      '.data[] | select(."lifecycle-state" != "DETACHED") | select(.id as $id | ($pre | index($id)) == null) | .id' \
      | head -1)
 
    [ -n "$NEW_ATTACH_ID" ] && break
    echo "    Waiting for attachment to appear... ($POLL/15)"
  done
 
  [ -z "$NEW_ATTACH_ID" ] && die "Could not find new attachment ID for $DNAME."
  echo "  Attachment ID: $NEW_ATTACH_ID"
  NEWLY_ATTACHED_IDS=$(echo "$NEWLY_ATTACHED_IDS" | jq --arg id "$NEW_ATTACH_ID" ". += [$id]")
 
  # Poll until ATTACHED
  echo "  Waiting for ATTACHED state..."
  for ATTEMPT in $(seq 1 24); do
    STATUS=$(oci compute vnic-attachment get \
      --vnic-attachment-id "$NEW_ATTACH_ID" \
      --query 'data."lifecycle-state"' \
      --raw-output 2>&1)
    [ "$STATUS" = "ATTACHED" ] && break
    echo "    Status: $STATUS (attempt $ATTEMPT/24)..."
    sleep 10
    [ "$ATTEMPT" -eq 24 ] && die "Timeout waiting for $DNAME to attach."
  done
 
  # Verify IP matches expected
  NEW_VNIC_ID=$(oci compute vnic-attachment get \
    --vnic-attachment-id "$NEW_ATTACH_ID" \
    --query 'data."vnic-id"' --raw-output 2>&1)
  VERIFIED_IP=$(oci network vnic get \
    --vnic-id "$NEW_VNIC_ID" \
    --query 'data."private-ip"' --raw-output 2>&1)
 
  [ "$VERIFIED_IP" = "$PRIVATE_IP" ] \
    && log "Attached: $DNAME → IP verified: $VERIFIED_IP" \
    || warn "IP mismatch on $DNAME — expected $PRIVATE_IP, got $VERIFIED_IP"
  echo ""
done
 
# ===========================================================================
# Summary — built dynamically from backup, no hardcoded IPs
# ===========================================================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
printf "║  ✅ %-50s║\n" "$BACKUP_NAME reshape complete!"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Shape : %-43s║\n" "$TARGET_SHAPE ($TARGET_OCPUS OCPU / ${TARGET_MEMORY_GB}GB)"
echo "║                                                      ║"
echo "║  VNICs:                                              ║"
for V in "${SECONDARY_VNICS[@]}"; do
  printf "║    ✅ %-47s║\n" \
    "$(echo "$V" | jq -r '.display_name') — $(echo "$V" | jq -r '.private_ip')"
done
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Verify:                                             ║"
echo "║    □  VM reachable (ping / SSH / GUI)                ║"
echo "║    □  HA sync healthy                                ║"
echo "║  Expected NICs:                                      ║"
for V in $(jq -c '.vnics[]' "$BACKUP_FILE"); do
  printf "║    • %-25s IP: %-20s║\n" \
    "$(echo "$V" | jq -r '.display_name')" \
    "$(echo "$V" | jq -r '.private_ip')"
done
echo "║  Expected Volumes:                                   ║"
for VOL in "${VOLUMES[@]}"; do
  printf "║    • %-25s %s GB %-12s║\n" \
    "$(echo "$VOL" | jq -r '.display_name' | cut -c1-25)" \
    "$(echo "$VOL" | jq -r '.size_in_gbs')" \
    "$(echo "$VOL" | jq -r 'if .is_boot then "[boot]" else "[data]" end')"
done
echo "╚══════════════════════════════════════════════════════╝"