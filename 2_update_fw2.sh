#!/bin/bash
# =============================================================================
# Reshape FW2 — FortiGate Passive
# Detach secondary VNICs, reshape to E5.Flex, reattach with original config
#
# Usage    : Edit the variables below, then run: ./2_update_fw2.sh
# Requires : oci cli, jq
# Backup   : Run ./1_fetch_vnic_info.sh first to generate the backup JSON
# =============================================================================

# ---------------------------------------------------------------------------
# ⚙️  Configuration — edit these variables before running
# ---------------------------------------------------------------------------
INSTANCE_OCID="ocid1.instance.oc1.iad.anuwcljtctshpiycozu4p5boirdkweobubugjrlrjehxtinlyeeiqusiyvoq"
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
# Load all values from backup
# ---------------------------------------------------------------------------
COMPARTMENT_ID=$(jq -r '.compartment_id'      "$BACKUP_FILE")
BACKUP_NAME=$(jq -r    '.instance_name'       "$BACKUP_FILE")
CURRENT_SHAPE=$(jq -r  '.shape'               "$BACKUP_FILE")
AVAIL_DOMAIN=$(jq -r   '.availability_domain' "$BACKUP_FILE")

# Secondary VNICs in attachment order: public → trust → hasync
mapfile -t _ALL_SECONDARY < <(jq -c '.vnics[] | select(.is_primary == false)' "$BACKUP_FILE")

SECONDARY_VNICS=()
declare -A _USED

for V in "${_ALL_SECONDARY[@]}"; do
  echo "$V" | jq -r '.display_name' | grep -qi "public"                 && { SECONDARY_VNICS+=("$V"); _USED["$V"]=1; }
done
for V in "${_ALL_SECONDARY[@]}"; do
  echo "$V" | jq -r '.display_name' | grep -qi "trust"                  && [ -z "${_USED[$V]}" ] && { SECONDARY_VNICS+=("$V"); _USED["$V"]=1; }
done
for V in "${_ALL_SECONDARY[@]}"; do
  echo "$V" | jq -r '.display_name' | grep -qiE "hasync|ha.sync|ha-sync" && [ -z "${_USED[$V]}" ] && { SECONDARY_VNICS+=("$V"); _USED["$V"]=1; }
done
for V in "${_ALL_SECONDARY[@]}"; do
  [ -z "${_USED[$V]}" ] && SECONDARY_VNICS+=("$V")
done

SECONDARY_COUNT=${#SECONDARY_VNICS[@]}
PRIMARY_IP=$(jq -r '.vnics[] | select(.is_primary == true) | .private_ip' "$BACKUP_FILE")
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
# Banner
# ---------------------------------------------------------------------------
clear
echo "╔══════════════════════════════════════════════════════╗"
printf "║  %-52s║\n" "Reshape FW2 — FortiGate Passive"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  VM     : %-43s║\n" "$BACKUP_NAME"
printf "║  Shape  : %-43s║\n" "$CURRENT_SHAPE → $TARGET_SHAPE ($TARGET_OCPUS OCPU/${TARGET_MEMORY_GB}GB)"
printf "║  Backup : %-43s║\n" "$BACKUP_FILE"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  ⚠️   %-48s║\n" "FW1 (Active) will NOT be touched by this script"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Primary VNIC : %-37s║\n" "$PRIMARY_IP (NOT touched)"
echo "║  Secondary VNICs to detach → reattach:               ║"
for V in "${SECONDARY_VNICS[@]}"; do
  printf "║    • %-25s IP: %-20s║\n"     "$(echo "$V" | jq -r '.display_name')"     "$(echo "$V" | jq -r '.private_ip')"
done
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Volumes (not modified):                             ║"
for VOL in "${VOLUMES[@]}"; do
  printf "║    • %-25s %s GB %-12s║\n"     "$(echo "$VOL" | jq -r '.display_name' | cut -c1-25)"     "$(echo "$VOL" | jq -r '.size_in_gbs')"     "$(echo "$VOL" | jq -r 'if .is_boot then "[boot]" else "[data]" end')"
done
echo "╚══════════════════════════════════════════════════════╝"
echo ""
confirm "Proceed with the full shape change workflow?" || { echo "Aborted."; exit 0; }

# ===========================================================================
# STEP 1 — Validate instance
# ===========================================================================
header "STEP 1/4 — Validate instance"
echo ""

LIVE_JSON=$(oci compute instance get --instance-id "$INSTANCE_OCID" --query 'data' 2>&1)
echo "$LIVE_JSON" | grep -q "ServiceError\|Error\|error" && die "Cannot reach OCI API.\n$LIVE_JSON"

LIVE_NAME=$(echo  "$LIVE_JSON" | jq -r '."display-name"')
LIVE_STATE=$(echo "$LIVE_JSON" | jq -r '."lifecycle-state"')
LIVE_SHAPE=$(echo "$LIVE_JSON" | jq -r '.shape')

[ "$LIVE_NAME"  != "$BACKUP_NAME" ] && die "OCID resolves to '$LIVE_NAME' but backup is for '$BACKUP_NAME'."
[ "$LIVE_STATE" != "RUNNING"       ] && die "Instance is '$LIVE_STATE'. Must be RUNNING."

log "Instance : $LIVE_NAME"
log "State    : $LIVE_STATE"
log "Shape    : $LIVE_SHAPE"

# ===========================================================================
# STEP 2 — Detach secondary VNICs (using live OCI data)
# ===========================================================================
header "STEP 2/4 — Detach $SECONDARY_COUNT secondary VNIC(s)"
echo ""
echo "  VNICs to be detached:"
for V in "${SECONDARY_VNICS[@]}"; do
  printf "    - %-38s IP: %s\n"     "$(echo "$V" | jq -r '.display_name')"     "$(echo "$V" | jq -r '.private_ip')"
done
echo ""
confirm "Detach these $SECONDARY_COUNT VNICs now?" || die "User cancelled at detach step."
echo ""

# Fetch LIVE attachment IDs from OCI — never rely on stale backup IDs
echo "  Fetching live VNIC attachments from OCI..."
LIVE_ATTACHMENTS=$(oci compute vnic-attachment list   --compartment-id "$COMPARTMENT_ID"   --instance-id    "$INSTANCE_OCID"   --all 2>&1)

echo "$LIVE_ATTACHMENTS" | grep -q "ServiceError\|Error\|error"   && die "Could not fetch live VNIC attachments.\n$LIVE_ATTACHMENTS"

echo "  Live attachments:"
echo "$LIVE_ATTACHMENTS" | jq -r   '.data[] | select(."lifecycle-state" != "DETACHED") | "    \(."lifecycle-state") | \(."display-name" // "null") | \(.id)"'
echo ""

for V in "${SECONDARY_VNICS[@]}"; do
  DNAME=$(echo      "$V" | jq -r '.display_name')
  PRIVATE_IP=$(echo "$V" | jq -r '.private_ip')

  # Resolve current attachment ID from live OCI data
  ATTACH_ID=$(echo "$LIVE_ATTACHMENTS" | jq -r     --arg name "$DNAME"     '.data[] | select(."display-name" == $name) | select(."lifecycle-state" != "DETACHED") | .id'     | head -1)

  if [ -z "$ATTACH_ID" ]; then
    warn "$DNAME — no active attachment found. Already detached. Skipping."
    echo ""
    continue
  fi

  echo "  Detaching : $DNAME"
  echo "  IP        : $PRIVATE_IP"
  echo "  Attach ID : $ATTACH_ID"

  RESULT=$(oci compute vnic-attachment delete     --vnic-attachment-id "$ATTACH_ID"     --force 2>&1)

  if echo "$RESULT" | grep -q "404\|NotFound\|does not exist"; then
    log "Already detached: $DNAME"
    echo ""
    continue
  fi

  echo "$RESULT" | grep -q "ServiceError\|Error\|error"     && die "Failed to detach $DNAME:\n$RESULT"

  echo "  Waiting for detachment..."
  sleep 15

  DETACHED=false
  for ATTEMPT in $(seq 1 24); do
    STATUS=$(oci compute vnic-attachment get       --vnic-attachment-id "$ATTACH_ID"       --query 'data."lifecycle-state"'       --raw-output 2>&1)

    echo "$STATUS" | grep -q "404\|NotAuthorized\|does not exist\|No such" && { DETACHED=true; break; }
    [ "$STATUS" = "DETACHED" ] && { DETACHED=true; break; }

    echo "    Status: $STATUS (attempt $ATTEMPT/24)..."
    sleep 15
  done

  [ "$DETACHED" = "true" ] && log "Detached: $DNAME" || die "Timeout waiting for $DNAME to detach."
  echo "  Settling..."
  sleep 10
  echo ""
done

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

RESULT=""
for RETRY in $(seq 1 10); do
  RESULT=$(oci compute instance update     --instance-id  "$INSTANCE_OCID"     --shape        "$TARGET_SHAPE"     --shape-config "{\"ocpus\": $TARGET_OCPUS, \"memoryInGBs\": $TARGET_MEMORY_GB}"     --force 2>&1)

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
  STATUS=$(oci compute instance get     --instance-id "$INSTANCE_OCID"     --query 'data."lifecycle-state"'     --raw-output 2>&1)
  [ "$STATUS" = "RUNNING" ] && { log "Instance is RUNNING"; break; }
  echo "  Status: $STATUS (attempt $ATTEMPT/36)..."
  sleep 10
  [ "$ATTEMPT" -eq 36 ] && die "Timeout waiting for RUNNING state."
done

# ===========================================================================
# STEP 4 — Reattach secondary VNICs (public → trust → hasync)
# ===========================================================================
header "STEP 4/4 — Reattach $SECONDARY_COUNT secondary VNIC(s)"
echo ""
echo "  Reattach order: public → trust → hasync"
for V in "${SECONDARY_VNICS[@]}"; do
  printf "    - %-38s IP: %s  NIC: %s\n"     "$(echo "$V" | jq -r '.display_name')"     "$(echo "$V" | jq -r '.private_ip')"     "$(echo "$V" | jq -r '.nic_index')"
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

  echo "  Attaching: $DNAME | IP: $PRIVATE_IP | NIC: $NIC_IDX | Skip S/D: $SKIP_SD"

  ATTACH_ARGS=(
    --instance-id            "$INSTANCE_OCID"
    --subnet-id              "$SUBNET"
    --vnic-display-name      "$DNAME"
    --private-ip             "$PRIVATE_IP"
    --nic-index              "$NIC_IDX"
    --skip-source-dest-check "true"
  )
  [ -n "$HOSTNAME" ] && ATTACH_ARGS+=(--hostname-label "$HOSTNAME")

  # Snapshot attachment IDs before attaching
  PRE_IDS=$(oci compute vnic-attachment list     --compartment-id "$COMPARTMENT_ID"     --instance-id    "$INSTANCE_OCID"     --all 2>&1 | jq -r '[.data[].id] | @json')

  ATTACH_ERR=$(oci compute instance attach-vnic "${ATTACH_ARGS[@]}" 2>&1)

  if echo "$ATTACH_ERR" | grep -q "has already been allocated"; then
    warn "$DNAME — IP $PRIVATE_IP already allocated. VNIC already attached. Skipping."
    echo ""
    continue
  fi

  echo "$ATTACH_ERR" | grep -q "ServiceError\|Error\|error"     && die "Failed to attach $DNAME:\n$ATTACH_ERR"

  # Find new attachment ID by diffing before/after
  echo "  Finding new attachment ID..."
  NEW_ATTACH_ID=""
  for POLL in $(seq 1 15); do
    sleep 6
    POST_ATTACH=$(oci compute vnic-attachment list       --compartment-id "$COMPARTMENT_ID"       --instance-id    "$INSTANCE_OCID"       --all 2>&1)

    NEW_ATTACH_ID=$(echo "$POST_ATTACH" | jq -r       --argjson pre "$PRE_IDS"       '.data[] | select(."lifecycle-state" != "DETACHED") | select(.id as $id | ($pre | index($id)) == null) | .id'       | head -1)

    [ -n "$NEW_ATTACH_ID" ] && break
    echo "    Waiting for attachment to appear... ($POLL/15)"
  done

  [ -z "$NEW_ATTACH_ID" ] && die "Could not find new attachment ID for $DNAME."
  echo "  Attachment ID: $NEW_ATTACH_ID"
  NEWLY_ATTACHED_IDS=$(echo "$NEWLY_ATTACHED_IDS" | jq --arg id "$NEW_ATTACH_ID" ". += [$id]")

  echo "  Waiting for ATTACHED state..."
  for ATTEMPT in $(seq 1 24); do
    STATUS=$(oci compute vnic-attachment get       --vnic-attachment-id "$NEW_ATTACH_ID"       --query 'data."lifecycle-state"'       --raw-output 2>&1)
    [ "$STATUS" = "ATTACHED" ] && break
    echo "    Status: $STATUS (attempt $ATTEMPT/24)..."
    sleep 10
    [ "$ATTEMPT" -eq 24 ] && die "Timeout waiting for $DNAME to attach."
  done

  NEW_VNIC_ID=$(oci compute vnic-attachment get     --vnic-attachment-id "$NEW_ATTACH_ID"     --query 'data."vnic-id"' --raw-output 2>&1)
  VERIFIED_IP=$(oci network vnic get     --vnic-id "$NEW_VNIC_ID"     --query 'data."private-ip"' --raw-output 2>&1)

  [ "$VERIFIED_IP" = "$PRIVATE_IP" ]     && log "Attached: $DNAME → IP verified: $VERIFIED_IP"     || warn "IP mismatch on $DNAME — expected $PRIVATE_IP, got $VERIFIED_IP"
  echo ""
done

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
printf "║  ✅ %-50s║\n" "$BACKUP_NAME reshape complete!"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Shape : %-43s║\n" "$TARGET_SHAPE ($TARGET_OCPUS OCPU / ${TARGET_MEMORY_GB}GB)"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Expected NICs:                                      ║"
for V in $(jq -c '.vnics[]' "$BACKUP_FILE"); do
  printf "║    • %-25s IP: %-20s║\n"     "$(echo "$V" | jq -r '.display_name')"     "$(echo "$V" | jq -r '.private_ip')"
done
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Expected Volumes:                                   ║"
for VOL in "${VOLUMES[@]}"; do
  printf "║    • %-25s %s GB %-12s║\n"     "$(echo "$VOL" | jq -r '.display_name' | cut -c1-25)"     "$(echo "$VOL" | jq -r '.size_in_gbs')"     "$(echo "$VOL" | jq -r 'if .is_boot then "[boot]" else "[data]" end')"
done
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Verify:                                             ║"
echo "║    □  VM reachable (ping / SSH / FortiGate GUI)      ║"
echo "║    □  HA sync healthy                                ║"
echo "║    □  All NICs present with correct IPs              ║"
echo "║    □  Volumes attached and mounted                   ║"
echo "╚══════════════════════════════════════════════════════╝"
