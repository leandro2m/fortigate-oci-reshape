# OCI FortiGate VM Reshape Automation

Bash scripts to automate the reshaping of FortiGate Active/Passive HA virtual machines on Oracle Cloud Infrastructure (OCI).

Oracle Cloud does not allow changing the shape (VM type) of an instance that has more than one secondary VNIC attached. These scripts handle the full workflow automatically:

1. Fetch current VNIC and volume configuration
2. Detach secondary VNICs
3. Reshape the VM to the target shape
4. Reattach all VNICs restoring the original IPs, names, subnets, and network settings

---

## Repository Structure

```
.
├── README.md
├── 1_fetch_vnic_info.sh     # Fetch and backup VNIC/volume config for both VMs
├── 2_update_fw2.sh          # Reshape FortiGate Passive (FW2) — run first
└── 3_update_fw1.sh          # Reshape FortiGate Active  (FW1) — run after FW2 is validated
```

---

## Prerequisites

| Requirement | Details |
|---|---|
| OCI CLI | Installed and configured (`oci setup config`) |
| `jq` | JSON processor — `sudo apt install jq` or `brew install jq` |
| IAM permissions | `manage instance-family` and `manage virtual-network-family` in the target compartment |
| OCI Cloud Shell | Recommended — CLI and jq are pre-installed |
| FortiGate access | SSH or GUI access to both FW1 and FW2 before starting |
| Local admin account | A local username/password admin account (no MFA) must exist on both FW1 and FW2 **before starting** — required to recover console access if MFA blocks login after VM reshape |

---

## Instance Reference

| VM | Role | OCID |
|---|---|---|
| AT-BOG-PRD-CMP-FW2 | FortiGate Passive | `OCID` |
| AT-BOG-PRD-CMP-FW1 | FortiGate Active  | `OCID` |

---

## Network Interfaces

Each FortiGate VM has 4 VNICs. The primary (mgmt) is never touched. The 3 secondary VNICs are detached and reattached in the following order:

| Order | Interface | Role |
|---|---|---|
| Primary | mgmt | Management — **never detached** |
| 1st | public | WAN / Untrust |
| 2nd | trust | LAN / Internal |
| 3rd | hasync | HA Synchronization |

---

## Full Procedure

⚠️ **Production environment.** Follow each step in order. Do not proceed to the next step until the current one is fully validated.

---

### CRITICAL — Create a Local Administrator Account Before Starting

🚨 **Very Critical**

 If your FortiGate configuration has **MFA (Multi-Factor Authentication) enabled**, you **will lose console access** after the factory reset and configuration restore unless a local-only administrator account exists.

 After the reattachment of the NICs, it requires to have access to the local interface of the FortiGAte to execute the command `execute factoryreset keepvmlicense`,. If you don't have local admin account without MFA **you are locked out of the FortiGate console**.

**Before running any script**, create a dedicated local administrator account with a username and password only (no MFA) on both FW1 and FW2:

#### Via FortiGate CLI (SSH)
```bash
config system admin
    edit "rescue-admin"
        set password <strong-password>
        set accprofile "super_admin"
        set vdom "root"
    next
end
```

#### Via FortiGate GUI
1. Go to **System → Administrators → Create New**
2. Set **Type** to `Local User`
3. Enter a username (e.g., `rescue-admin`) and a strong password
4. Assign the `super_admin` profile
5. **Do not enable Two-factor Authentication**
6. Click **OK**

✅ Repeat on both **FW1** and **FW2**. This account will survive the configuration restore and allows console access even when MFA blocks the primary admin account. Remove it after the procedure is complete.

---

### PHASE 1 — Backup FortiGate Configuration

Before making any changes, back up the full configuration of **both** firewalls.

#### Via FortiGate GUI
1. Log in to the FortiGate management interface
2. Go to **Dashboard → Status → System Information**
3. Click **Backup** and select **Local PC**
4. Download and save the `.conf` file
5. Repeat for both FW1 and FW2

#### Via FortiGate CLI (SSH)
```bash
execute backup config tftp <filename.conf> <tftp_server_ip>
```

💾 Store the backup files in a safe location before proceeding. Label them clearly:
  - `FW1_backup_<date>.conf`
  - `FW2_backup_<date>.conf`

---

### PHASE 2 — Verify HA Synchronization

Confirm that FW2 (Passive) is fully synchronized with FW1 (Active) before starting.

#### Via FortiGate CLI (SSH to FW1)
```bash
get system ha status
```

Expected output — both nodes must show `in-sync`:
```
  AT-BOG-PRD-CMP-FW1(updated): in-sync
  AT-BOG-PRD-CMP-FW2(updated): in-sync
```

---

### PHASE 3 — Fetch OCI VNIC and Volume Configuration

From OCI Cloud Shell, run the fetch script to capture the current network and volume config for both VMs:

```bash
./1_fetch_vnic_info.sh
```

**Expected output files:**
```
vnic_backup_AT-BOG-PRD-CMP-FW2.json
vnic_backup_AT-BOG-PRD-CMP-FW1.json
```

Review the summary output to confirm all 4 VNICs and volumes are captured correctly for each VM.

---

### PHASE 4 — Reshape FW2 (FortiGate Passive)

Run the FW2 reshape script from OCI Cloud Shell:

```bash
./2_update_fw2.sh
```

The script will prompt for confirmation at each step:

| Step | Action |
|---|---|
| 1/4 | Validate instance is RUNNING and matches the backup |
| 2/4 | Detach secondary VNICs: public, trust, hasync |
| 3/4 | Reshape to VM.Standard.E5.Flex (4 OCPUs / 64 GB RAM) |
| 4/4 | Reattach VNICs with original IPs and config |

Expected duration: **15–25 minutes**

---

### PHASE 5 — Factory Reset FW2 (Keeping VM License)

After the reshape completes and FW2 is back in RUNNING state, connect to **FW2 via SSH or OCI Serial Console** and run:

```
execute factoryreset keepvmlicense
```

⚠️ This command resets the FortiGate OS configuration to factory defaults while retaining the OCI VM license. The firewall will reboot automatically.

This step is required after a reshape so that FortiGate can re-detect the new virtual hardware and correctly re-map its internal port assignments.

Wait for FW2 to fully reboot before proceeding. This typically takes **3–5 minutes**.

---

### PHASE 6 — Restore FW2 Configuration

Once FW2 has rebooted after the factory reset, restore the backup taken in Phase 1.

#### Via FortiGate GUI
1. Log in to FW2 management interface
2. Go to **Dashboard → Status → System Information**
3. Click **Restore** and select the backup file `FW2_backup_<date>.conf`
4. Click **OK** and wait for the firewall to apply the configuration and reboot

#### Via FortiGate CLI (SSH)
```bash
execute restore config tftp <FW2_backup_filename.conf> <tftp_server_ip>
```

Wait for FW2 to fully reload the configuration before proceeding.

---

### PHASE 7 — Validate FW2

After the configuration restore, verify FW2 is fully operational before touching FW1.

**OCI Console checks:**
- [ ] FW2 instance is in **RUNNING** state with shape `VM.Standard.E5.Flex`
- [ ] All 4 VNICs are shown as **Attached** with correct IPs:

| Interface | Expected IP |
|---|---|
| mgmt (primary) | 10.50.194.3 |
| public | 10.50.194.36 |
| trust | 10.50.194.68 |
| hasync | 10.50.194.99 |

**FortiGate checks (SSH to FW1 — Active):**
```bash
get system ha status
```

- [ ] FW2 reachable (ping / SSH / FortiGate GUI)
- [ ] FortiGate GUI accessible on FW2
- [ ] HA sync status shows **in-sync**
- [ ] Firewall policies and routing restored correctly

❌ **Do not proceed to FW1** until all checks above pass.

---

### PHASE 8 — Reshape FW1 (FortiGate Active)

⚠️ **Traffic impact:** During FW1 reshape, the HA cluster will fail over to FW2. Expect a brief traffic interruption. Confirm FW2 is fully healthy and in-sync before running this step.

```bash
./3_update_fw1.sh
```

Same 4-step workflow as FW2 (validate → detach → reshape → reattach).

Expected duration: **15–25 minutes**

---

### PHASE 9 — Factory Reset FW1 (Keeping VM License)

After the FW1 reshape completes, connect to **FW1 via SSH or OCI Serial Console** and run:

```
execute factoryreset keepvmlicense
```

Wait for FW1 to fully reboot (**3–5 minutes**) before proceeding.

---

### PHASE 10 — Restore FW1 Configuration

Restore the FW1 configuration backup taken in Phase 1.

#### Via FortiGate GUI
1. Log in to FW1 management interface
2. Go to **Dashboard → Status → System Information**
3. Click **Restore** and select `FW1_backup_<date>.conf`
4. Wait for the firewall to apply the configuration and reboot

#### Via FortiGate CLI (SSH)
```bash
execute restore config tftp <FW1_backup_filename.conf> <tftp_server_ip>
```

---

### PHASE 11 — Final Validation

Verify the full HA cluster is operational after both reshapes.

**FortiGate CLI (SSH to FW1):**
```bash
get system ha status
```

Expected — both nodes showing `in-sync`:
```
  AT-BOG-PRD-CMP-FW1(updated): in-sync
  AT-BOG-PRD-CMP-FW2(updated): in-sync
```

**Full checklist:**
- [ ] Both VMs in **RUNNING** state with shape `VM.Standard.E5.Flex`
- [ ] HA sync healthy between FW1 and FW2
- [ ] Traffic flowing correctly through the firewall cluster
- [ ] All 4 NICs on both VMs present with correct IPs
- [ ] Volumes attached and mounted on both VMs
- [ ] FortiGate policies and routing fully restored

---

## Procedure Summary

| Phase | Action | Executed by |
|---|---|---|
| **0** | **Create local admin account (no MFA) on FW1 and FW2** | **FortiGate Admin** |
| 1 | Backup FortiGate config (FW1 + FW2) | FortiGate Admin |
| 2 | Verify HA sync is healthy | FortiGate Admin |
| 3 | Run `1_fetch_vnic_info.sh` | OCI Cloud Shell |
| 4 | Run `2_update_fw2.sh` — reshape FW2 | OCI Cloud Shell |
| 5 | `execute factoryreset keepvmlicense` on FW2 | FortiGate CLI |
| 6 | Restore FW2 configuration backup | FortiGate Admin |
| 7 | Validate FW2 fully operational and in-sync | FortiGate Admin |
| 8 | Run `3_update_fw1.sh` — reshape FW1 | OCI Cloud Shell |
| 9 | `execute factoryreset keepvmlicense` on FW1 | FortiGate CLI |
| 10 | Restore FW1 configuration backup | FortiGate Admin |
| 11 | Final validation of both nodes | FortiGate Admin |

---

## Target Shape

| Parameter | Value |
|---|---|
| Shape | `VM.Standard.E5.Flex` |
| OCPUs | 4 |
| Memory | 64 GB |

To change the target shape, edit the variables at the top of scripts 2 and 3:

```bash
TARGET_SHAPE="VM.Standard.E5.Flex"
TARGET_OCPUS=4
TARGET_MEMORY_GB=64
```

---

## How It Works

### Detach (Step 2)

The script queries OCI **live** for current attachment IDs — it never relies on the backup file for detach operations, avoiding failures due to stale IDs:

```bash
oci compute vnic-attachment delete --vnic-attachment-id <live_id> --force
```

The script polls every 15 seconds until the attachment is confirmed removed, with a settling period between each VNIC.

### Reshape (Step 3)

```bash
oci compute instance update \
  --shape "VM.Standard.E5.Flex" \
  --shape-config '{"ocpus": 4, "memoryInGBs": 64}'
```

If OCI returns a `409 Conflict` (instance still processing a previous operation), the script automatically retries up to 10 times with a 30-second wait between attempts.

### Reattach (Step 4)

VNICs are reattached using the backup JSON as the source of truth for private IP, subnet, display name, NIC index, skip source/destination check, hostname label, and NSG assignments. The new attachment ID is resolved by comparing the VNIC list before and after the attach call. If a VNIC IP is already allocated from a previous partial run, the script skips it safely.

---

## Troubleshooting

| Error | Cause | Solution |
|---|---|---|
| `409 Conflict — instance is currently being modified` | OCI still processing a previous operation | Script retries automatically. If persistent, wait 2–3 min and re-run |
| `IP address has already been allocated` | VNIC already attached from a previous run | Script skips safely and continues |
| VNIC appears attached in console but script skips it | OCI propagation delay | Wait 30 seconds and verify in console |
| FortiGate not responding after reshape | Interface remapping inside FortiOS | Run `execute factoryreset keepvmlicense` and restore config backup |
| Console access lost after config restore | MFA re-enabled by restored config and MFA provider unreachable | Log in with the local rescue admin account (no MFA). If not created beforehand, use OCI Serial Console and the FortiGate factory-default credentials to create a local admin before re-applying the config |
| HA out of sync after restore | HA sync still propagating | Wait 3–5 minutes after config restore |

---

## Important Notes

- The **primary (mgmt) VNIC is never detached** at any point
- Scripts 2 and 3 are completely independent — running one has zero effect on the other VM
- Always run `1_fetch_vnic_info.sh` immediately before any reshape to ensure the backup is current
- The backup JSON is used for reattach config only — detach always uses live OCI data
- `execute factoryreset keepvmlicense` is required after each reshape to allow FortiGate to re-detect the new virtual hardware

---

## Author

Leandro Momesso
