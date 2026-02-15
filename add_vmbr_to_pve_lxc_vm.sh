#!/bin/bash

#############################################
# Configuration Section - Edit these values
#############################################

# Network configuration
BASE_IP="10.0.0"              # Base IP (first three octets)
SUBNET_MASK="24"              # Subnet mask (CIDR notation)
BRIDGE_NAME="vmbr1"           # Bridge name
BRIDGE_IP_LAST_OCTET="1"      # Last octet for bridge (e.g., 1 for 10.0.0.1)

# Derived values (don't edit these)
BRIDGE_IP="${BASE_IP}.${BRIDGE_IP_LAST_OCTET}/${SUBNET_MASK}"
BRIDGE_IP_SHORT="${BASE_IP}.${BRIDGE_IP_LAST_OCTET}"

#############################################
# End of Configuration Section
#############################################

BACKUP_DIR="/root/lxc-vm-backup-$(date +%Y%m%d-%H%M%S)"
ERROR_LOG="/root/lxc-vm-network-errors.log"
IP_EXPORT_FILE="/root/internal-network-ips.txt"
CONTAINERS_MODIFIED=()
VMS_MODIFIED=()
HAS_ERRORS=0

# Function to generate random MAC address
generate_mac() {
    printf '02:%02x:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# Function to get all LXC VMIDs
get_lxc_vmids() {
    local vmids=()
    for conf in /etc/pve/lxc/*.conf; do
        if [ -f "$conf" ]; then
            local vmid=$(basename "$conf" .conf)
            vmids+=($vmid)
        fi
    done
    echo "${vmids[@]}" | tr ' ' '\n' | sort -n
}

# Function to get all VM VMIDs
get_vm_vmids() {
    local vmids=()
    for conf in /etc/pve/qemu-server/*.conf; do
        if [ -f "$conf" ]; then
            local vmid=$(basename "$conf" .conf)
            vmids+=($vmid)
        fi
    done
    echo "${vmids[@]}" | tr ' ' '\n' | sort -n
}

# Function to get all VMIDs (both LXC and VM)
get_all_vmids() {
    {
        get_lxc_vmids
        get_vm_vmids
    } | sort -n | uniq
}

# Function to check if IP is in our subnet
is_ip_in_subnet() {
    local ip=$1
    # Check if IP starts with our BASE_IP
    if [[ "$ip" =~ ^${BASE_IP}\. ]]; then
        return 0
    fi
    return 1
}

# Function to check if LXC has interface in our IP range
lxc_has_internal_interface() {
    local vmid=$1
    local config="/etc/pve/lxc/${vmid}.conf"

    # Check for bridge name
    if grep -q "bridge=${BRIDGE_NAME}" "$config" 2>/dev/null; then
        echo "bridge_name"
        return 0
    fi

    # Check for IP in our range
    while IFS= read -r line; do
        if [[ "$line" =~ ip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            local found_ip="${BASH_REMATCH[1]}"
            if is_ip_in_subnet "$found_ip"; then
                echo "ip_range"
                return 0
            fi
        fi
    done < "$config"

    return 1
}

# Function to check if VM has interface in our IP range
vm_has_internal_interface() {
    local vmid=$1
    local config="/etc/pve/qemu-server/${vmid}.conf"

    # Check for bridge name
    if grep -q "bridge=${BRIDGE_NAME}" "$config" 2>/dev/null; then
        echo "bridge_name"
        return 0
    fi

    return 1
}

# Function to check if interface exists inside running LXC
lxc_interface_configured_inside() {
    local vmid=$1
    local ip_to_check="${BASE_IP}.${vmid}"

    # Check if container is running
    if ! pct status $vmid | grep -q "running"; then
        return 1
    fi

    # Check if IP exists on any interface
    if pct exec $vmid -- ip addr show 2>/dev/null | grep -q "$ip_to_check"; then
        return 0
    fi

    return 1
}

# Function to revert all changes
revert_changes() {
    echo ""
    echo "========================================"
    echo "ERROR DETECTED - REVERTING ALL CHANGES"
    echo "========================================"
    echo ""

    # Revert LXC containers
    for VMID in "${CONTAINERS_MODIFIED[@]}"; do
        CONFIG_FILE="/etc/pve/lxc/${VMID}.conf"
        BACKUP_FILE="$BACKUP_DIR/${VMID}.conf"

        if [ -f "$BACKUP_FILE" ]; then
            echo "Restoring LXC $VMID configuration..."
            cp "$BACKUP_FILE" "$CONFIG_FILE"

            if pct status $VMID | grep -q "running"; then
                echo "Restarting LXC $VMID..."
                pct reboot $VMID
            fi
        fi
    done

    # Revert VMs
    for VMID in "${VMS_MODIFIED[@]}"; do
        CONFIG_FILE="/etc/pve/qemu-server/${VMID}.conf"
        BACKUP_FILE="$BACKUP_DIR/${VMID}-vm.conf"

        if [ -f "$BACKUP_FILE" ]; then
            echo "Restoring VM $VMID configuration..."
            cp "$BACKUP_FILE" "$CONFIG_FILE"

            if qm status $VMID | grep -q "running"; then
                echo "Restarting VM $VMID..."
                qm reboot $VMID
            fi
        fi
    done

    echo ""
    echo "All changes have been reverted."
    echo "Original configurations restored from: $BACKUP_DIR"
    echo "Error log available at: $ERROR_LOG"
    echo ""
    echo "Note: $BRIDGE_NAME bridge was created on the host. To remove it manually:"
    echo "  1) Go to Proxmox web UI -> Node -> System -> Network"
    echo "  2) Select $BRIDGE_NAME and click Remove"
    echo "  3) Click Apply Configuration"
    exit 1
}

# Function to handle errors
handle_error() {
    local VMID=$1
    local ERROR_MSG=$2

    echo "✗ ERROR on $VMID: $ERROR_MSG" | tee -a "$ERROR_LOG"
    HAS_ERRORS=1
}

# Trap errors
trap 'echo "Script interrupted or error occurred. Check $ERROR_LOG for details."' ERR

echo "========================================"
echo "Network Configuration Script"
echo "========================================"
echo "Configuration:"
echo "  Bridge: $BRIDGE_NAME"
echo "  Bridge IP: $BRIDGE_IP"
echo "  Network: ${BASE_IP}.0/${SUBNET_MASK}"
echo "  IP Assignment: VMID = Last Octet (e.g., VMID 104 -> ${BASE_IP}.104)"
echo "========================================"
echo ""

# Discover all VMIDs
echo "Discovering LXC containers and VMs..."
ALL_VMIDS=($(get_all_vmids))
LXC_COUNT=$(get_lxc_vmids | wc -l)
VM_COUNT=$(get_vm_vmids | wc -l)

if [ ${#ALL_VMIDS[@]} -eq 0 ]; then
    echo "✗ No LXC containers or VMs found!"
    exit 1
fi

echo "Found:"
echo "  - $LXC_COUNT LXC container(s)"
echo "  - $VM_COUNT VM(s)"
echo "  - Total: ${#ALL_VMIDS[@]} container(s)/VM(s)"
echo ""
echo "VMIDs to process: ${ALL_VMIDS[@]}"
echo ""

echo "========================================"
echo "Step 1: Creating $BRIDGE_NAME bridge on Proxmox"
echo "========================================"
echo ""

# Check if bridge already exists
if ip link show $BRIDGE_NAME &>/dev/null; then
    echo "✓ Bridge $BRIDGE_NAME already exists"

    if ip addr show $BRIDGE_NAME | grep -q "$BRIDGE_IP_SHORT"; then
        echo "✓ Bridge $BRIDGE_NAME already has IP $BRIDGE_IP"
    else
        echo "⚠ Bridge $BRIDGE_NAME exists but may have different IP configuration"
        ip addr show $BRIDGE_NAME | grep "inet "
    fi
else
    echo "Creating bridge $BRIDGE_NAME..."

    NETWORK_CONFIG="/etc/network/interfaces.d/${BRIDGE_NAME}"

    if [ ! -f "$NETWORK_CONFIG" ]; then
        echo "Creating network configuration file..."
        cat > "$NETWORK_CONFIG" << EOF
# Internal network bridge
auto $BRIDGE_NAME
iface $BRIDGE_NAME inet static
    address $BRIDGE_IP
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF

        echo "✓ Configuration file created: $NETWORK_CONFIG"
    fi

    echo "Activating bridge $BRIDGE_NAME..."
    if ifup $BRIDGE_NAME 2>/dev/null || (ip link add name $BRIDGE_NAME type bridge && ip addr add $BRIDGE_IP dev $BRIDGE_NAME && ip link set $BRIDGE_NAME up); then
        echo "✓ Bridge $BRIDGE_NAME created successfully with IP $BRIDGE_IP"
    else
        echo "✗ CRITICAL: Failed to create bridge $BRIDGE_NAME"
        echo "Please create it manually via Proxmox web UI:"
        echo "  1) Go to Node -> System -> Network"
        echo "  2) Click Create -> Linux Bridge"
        echo "  3) Name: $BRIDGE_NAME, IP: $BRIDGE_IP, Leave 'Bridge ports' empty"
        echo "  4) Click Create and Apply Configuration"
        exit 1
    fi
fi

echo ""
echo "Bridge status:"
ip addr show $BRIDGE_NAME
echo ""
echo "========================================"
echo ""

# Create backup directory
echo "Step 2: Creating backup directory"
echo "========================================"
mkdir -p "$BACKUP_DIR"
echo "Backup directory: $BACKUP_DIR"
echo ""

# Initialize error log
echo "=== LXC/VM Network Configuration Error Log ===" > "$ERROR_LOG"
echo "Date: $(date)" >> "$ERROR_LOG"
echo "Configuration: Bridge=$BRIDGE_NAME, IP=$BRIDGE_IP, Network=${BASE_IP}.0/${SUBNET_MASK}" >> "$ERROR_LOG"
echo "" >> "$ERROR_LOG"

# Backup all configs before making changes
echo "Step 3: Backing up LXC and VM configurations"
echo "========================================"
for VMID in "${ALL_VMIDS[@]}"; do
    LXC_CONFIG="/etc/pve/lxc/${VMID}.conf"
    VM_CONFIG="/etc/pve/qemu-server/${VMID}.conf"

    if [ -f "$LXC_CONFIG" ]; then
        if cp "$LXC_CONFIG" "$BACKUP_DIR/${VMID}.conf" 2>/dev/null; then
            echo "Backed up LXC config for VMID $VMID"
        else
            echo "✗ CRITICAL: Failed to backup LXC $VMID" | tee -a "$ERROR_LOG"
            exit 1
        fi
    fi

    if [ -f "$VM_CONFIG" ]; then
        if cp "$VM_CONFIG" "$BACKUP_DIR/${VMID}-vm.conf" 2>/dev/null; then
            echo "Backed up VM config for VMID $VMID"
        else
            echo "✗ CRITICAL: Failed to backup VM $VMID" | tee -a "$ERROR_LOG"
            exit 1
        fi
    fi
done

echo "Backup completed!"
echo ""
echo "========================================"
echo "Step 4: Checking existing configurations"
echo "========================================"
echo ""

# Check for existing configurations
echo "Scanning for existing interfaces in IP range ${BASE_IP}.0/${SUBNET_MASK}..."
SKIP_COUNT=0

for VMID in "${ALL_VMIDS[@]}"; do
    LXC_CONFIG="/etc/pve/lxc/${VMID}.conf"
    VM_CONFIG="/etc/pve/qemu-server/${VMID}.conf"

    if [ -f "$LXC_CONFIG" ]; then
        REASON=$(lxc_has_internal_interface $VMID)
        if [ $? -eq 0 ]; then
            echo "⚠ LXC $VMID: Already configured (found via $REASON)"
            SKIP_COUNT=$((SKIP_COUNT + 1))
        fi

        if lxc_interface_configured_inside $VMID; then
            echo "⚠ LXC $VMID: IP ${BASE_IP}.${VMID} already configured inside container"
        fi
    fi

    if [ -f "$VM_CONFIG" ]; then
        REASON=$(vm_has_internal_interface $VMID)
        if [ $? -eq 0 ]; then
            echo "⚠ VM $VMID: Already configured (found via $REASON)"
            SKIP_COUNT=$((SKIP_COUNT + 1))
        fi
    fi
done

if [ $SKIP_COUNT -gt 0 ]; then
    echo ""
    echo "Found $SKIP_COUNT container(s)/VM(s) already configured. These will be skipped."
else
    echo "No existing configurations found. All containers/VMs will be processed."
fi

echo ""
echo "========================================"
echo "Step 5: Configuring LXC containers and VMs"
echo "========================================"
echo ""

# Process each VMID
for VMID in "${ALL_VMIDS[@]}"; do
    LXC_CONFIG="/etc/pve/lxc/${VMID}.conf"
    VM_CONFIG="/etc/pve/qemu-server/${VMID}.conf"

    # IP address is based on VMID
    IP_ADDRESS="${BASE_IP}.${VMID}"

    # Generate random MAC address
    MAC_ADDRESS=$(generate_mac)

    # Check if it's an LXC container
    if [ -f "$LXC_CONFIG" ]; then
        echo "=== Processing LXC Container $VMID ==="

        # Check if already configured
        REASON=$(lxc_has_internal_interface $VMID)
        if [ $? -eq 0 ]; then
            echo "✓ LXC $VMID already has internal network configured (via $REASON), skipping"
            echo ""
            continue
        fi

        # Find the highest net number
        HIGHEST_NET=$(grep -oP 'net\K[0-9]+' "$LXC_CONFIG" | sort -n | tail -1)

        if [ -z "$HIGHEST_NET" ]; then
            NEXT_NET=0
        else
            NEXT_NET=$((HIGHEST_NET + 1))
        fi

        echo "Adding $BRIDGE_NAME to LXC $VMID with IP ${IP_ADDRESS}/${SUBNET_MASK} as net${NEXT_NET}"
        echo "  MAC address: $MAC_ADDRESS"

        if echo "net${NEXT_NET}: name=eth${NEXT_NET},bridge=${BRIDGE_NAME},firewall=1,hwaddr=${MAC_ADDRESS},ip=${IP_ADDRESS}/${SUBNET_MASK},type=veth" >> "$LXC_CONFIG"; then
            CONTAINERS_MODIFIED+=($VMID)
        else
            handle_error "LXC $VMID" "Failed to modify Proxmox config file"
            revert_changes
        fi

        # Configure network inside container if running
        if pct status $VMID | grep -q "running"; then
            echo "Configuring network inside LXC $VMID..."

            # Check if already configured inside
            if lxc_interface_configured_inside $VMID; then
                echo "✓ IP ${IP_ADDRESS} already configured inside container, skipping internal config"
            else
                pct exec $VMID -- bash -c "[ -f /etc/network/interfaces ] && cp /etc/network/interfaces /etc/network/interfaces.backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null

                if pct exec $VMID -- test -f /etc/network/interfaces 2>/dev/null; then
                    if ! pct exec $VMID -- grep -q "eth${NEXT_NET}" /etc/network/interfaces 2>/dev/null; then
                        echo "Adding eth${NEXT_NET} configuration to /etc/network/interfaces"
                        if ! pct exec $VMID -- bash -c "cat >> /etc/network/interfaces << EOF

# Internal network on $BRIDGE_NAME
auto eth${NEXT_NET}
iface eth${NEXT_NET} inet static
    address ${IP_ADDRESS}/${SUBNET_MASK}
EOF" 2>/dev/null; then
                            handle_error "LXC $VMID" "Failed to configure network inside container"
                            revert_changes
                        fi
                    fi

                    pct exec $VMID -- ifup eth${NEXT_NET} 2>/dev/null || echo "Interface will be active after reboot"
                else
                    echo "Container uses different network configuration (systemd-networkd/netplan)"
                    echo "Manual configuration required inside LXC $VMID"
                fi
            fi

            echo "Rebooting LXC $VMID..."
            pct reboot $VMID 2>/dev/null
            sleep 5

            # Wait for container
            COUNTER=0
            while [ $COUNTER -lt 30 ]; do
                if pct status $VMID | grep -q "running"; then
                    echo "LXC $VMID is up!"
                    break
                fi
                sleep 1
                COUNTER=$((COUNTER + 1))
            done

            if pct status $VMID | grep -q "running"; then
                sleep 3

                echo ""
                echo "=== Network Test for LXC $VMID ==="

                if pct exec $VMID -- ping -c 3 -W 2 $BRIDGE_IP_SHORT 2>/dev/null; then
                    echo "✓ SUCCESS: LXC $VMID can reach Proxmox host at $BRIDGE_IP_SHORT"
                else
                    handle_error "LXC $VMID" "Cannot reach Proxmox host"
                    echo "✗ FAILED: LXC $VMID cannot reach Proxmox host"
                fi
                echo ""
            fi
        else
            echo "LXC $VMID is not running, skipping network configuration inside container"
        fi

        echo "---"
        echo ""

    # Check if it's a VM
    elif [ -f "$VM_CONFIG" ]; then
        echo "=== Processing VM $VMID ==="

        # Check if already configured
        REASON=$(vm_has_internal_interface $VMID)
        if [ $? -eq 0 ]; then
            echo "✓ VM $VMID already has internal network configured (via $REASON), skipping"
            echo ""
            continue
        fi

        # Find the highest net number
        HIGHEST_NET=$(grep -oP 'net\K[0-9]+' "$VM_CONFIG" | sort -n | tail -1)

        if [ -z "$HIGHEST_NET" ]; then
            NEXT_NET=0
        else
            NEXT_NET=$((HIGHEST_NET + 1))
        fi

        echo "Adding $BRIDGE_NAME to VM $VMID as net${NEXT_NET}"
        echo "  MAC address: $MAC_ADDRESS"
        echo "  Note: You will need to configure IP ${IP_ADDRESS}/${SUBNET_MASK} inside the VM manually"

        # Add network interface to VM config
        if echo "net${NEXT_NET}: virtio=${MAC_ADDRESS},bridge=${BRIDGE_NAME},firewall=1" >> "$VM_CONFIG"; then
            VMS_MODIFIED+=($VMID)
            echo "✓ Network interface added to VM $VMID configuration"
            echo "  After VM restart, configure IP ${IP_ADDRESS}/${SUBNET_MASK} inside the guest OS"
        else
            handle_error "VM $VMID" "Failed to modify VM config file"
            revert_changes
        fi

        # Optionally restart VM if running
        if qm status $VMID | grep -q "running"; then
            echo ""
            echo "VM $VMID is running. The new interface will be available after restart."
            echo "To apply changes now:"
            echo "  qm reboot $VMID"
            echo "Then configure network inside the guest OS with IP: ${IP_ADDRESS}/${SUBNET_MASK}"
        else
            echo "VM $VMID is not running. Start it and configure IP ${IP_ADDRESS}/${SUBNET_MASK} inside guest OS."
        fi

        echo "---"
        echo ""
    fi
done

# Check if any errors occurred
if [ $HAS_ERRORS -eq 1 ]; then
    echo ""
    echo "========================================"
    echo "⚠ WARNINGS/ERRORS DETECTED"
    echo "========================================"
    echo "Some containers/VMs encountered errors during configuration."
    echo "Error log: $ERROR_LOG"
    echo ""
    echo "Do you want to:"
    echo "  1) Keep changes (default - errors might be non-critical)"
    echo "  2) Revert all changes to original state"
    echo ""
    read -p "Enter choice [1/2]: " -t 30 CHOICE || CHOICE=1

    if [ "$CHOICE" = "2" ]; then
        revert_changes
    else
        echo "Keeping changes. Review error log for details: $ERROR_LOG"
    fi
fi

echo ""
echo "========================================"
echo "✓ Script completed successfully!"
echo "========================================"
echo "Processed ${#ALL_VMIDS[@]} container(s)/VM(s)."
echo ""
echo "Backup location: $BACKUP_DIR"
echo "Error log: $ERROR_LOG"
echo ""
echo "=== Internal Network Configuration ==="
echo "Bridge: $BRIDGE_NAME"
echo "Proxmox host IP: $BRIDGE_IP"
echo "Network: ${BASE_IP}.0/${SUBNET_MASK}"
echo ""

# Export IP addresses to file
echo "Exporting IP addresses to file..."
echo "=== Internal Network IP Assignments ===" > "$IP_EXPORT_FILE"
echo "Generated: $(date)" >> "$IP_EXPORT_FILE"
echo "Bridge: $BRIDGE_NAME ($BRIDGE_IP)" >> "$IP_EXPORT_FILE"
echo "" >> "$IP_EXPORT_FILE"

for VMID in "${ALL_VMIDS[@]}"; do
    LXC_CONFIG="/etc/pve/lxc/${VMID}.conf"
    VM_CONFIG="/etc/pve/qemu-server/${VMID}.conf"

    if [ -f "$LXC_CONFIG" ]; then
        # Get container name
        NAME=$(pct config $VMID 2>/dev/null | grep "^hostname:" | cut -d: -f2 | tr -d ' ')
        if [ -z "$NAME" ]; then
            NAME="lxc-$VMID"
        fi
        echo "LXC $VMID ($NAME): ${BASE_IP}.${VMID}" >> "$IP_EXPORT_FILE"
    elif [ -f "$VM_CONFIG" ]; then
        # Get VM name
        NAME=$(qm config $VMID 2>/dev/null | grep "^name:" | cut -d: -f2 | tr -d ' ')
        if [ -z "$NAME" ]; then
            NAME="vm-$VMID"
        fi
        echo "VM  $VMID ($NAME): ${BASE_IP}.${VMID}" >> "$IP_EXPORT_FILE"
    fi
done

echo ""
echo "✓ IP addresses exported to: $IP_EXPORT_FILE"
echo ""

echo "=== IP Address Assignments (VMID = IP Last Octet) ==="
for VMID in "${ALL_VMIDS[@]}"; do
    LXC_CONFIG="/etc/pve/lxc/${VMID}.conf"
    VM_CONFIG="/etc/pve/qemu-server/${VMID}.conf"

    if [ -f "$LXC_CONFIG" ]; then
        echo "  LXC $VMID -> ${BASE_IP}.${VMID}/${SUBNET_MASK}"
    elif [ -f "$VM_CONFIG" ]; then
        echo "  VM  $VMID -> ${BASE_IP}.${VMID}/${SUBNET_MASK} (configure manually inside guest)"
    fi
done
echo ""
echo "=== Important Notes ==="
echo "IP addressing: VMID matches last octet (e.g., VMID 104 = ${BASE_IP}.104)"
echo "LXC: Network configured automatically (if using /etc/network/interfaces)"
echo "VMs:  Network interface added, but IP must be configured inside guest OS"
echo "      Gateway: Leave empty for internal-only, or use $BRIDGE_IP_SHORT for routing"
echo ""
echo "=== Quick Verification ==="
echo "LXC: pct exec <VMID> -- ip addr show"
echo "LXC: pct exec <VMID> -- ping -c 3 $BRIDGE_IP_SHORT"
echo "VM:  Connect via console and configure network manually"
echo "Host: ip addr show $BRIDGE_NAME"
echo "IPs: cat $IP_EXPORT_FILE"
