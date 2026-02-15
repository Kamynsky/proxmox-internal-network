# Proxmox Internal Network Setup Script

Automated script to create an internal bridge network on Proxmox VE and configure all LXC containers and VMs with internal networking for services like Traefik, Arr stack, Home Assistant, and more.

## 🎯 What This Script Does

1. **Discovers all containers and VMs** automatically by scanning `.conf` files
2. **Creates an internal bridge** (`vmbr1`) on your Proxmox host with no physical network connection
3. **Automatically adds network interfaces** to all discovered LXC containers and VMs
4. **Assigns IP addresses** based on VMID (e.g., VMID 104 → 10.0.0.104)
5. **Configures networking inside LXC containers** automatically (for Debian/Ubuntu-based containers)
6. **Tests connectivity** to verify everything works
7. **Creates backups** before making any changes with easy rollback capability
8. **Exports IP address list** to file for easy reference

## 🌟 Features

- ✅ **Auto-discovery** - Automatically finds all LXC and VM containers (no manual ID range needed)
- ✅ **Easy configuration** - Only 4 settings to customize at the top of the script
- ✅ **Smart duplicate detection** - Checks for existing interfaces by bridge name AND IP range
- ✅ **Automatic backup** - All configs backed up before modification
- ✅ **Error handling** - Automatic or manual rollback on errors
- ✅ **Verbose output** - See exactly what's happening
- ✅ **Network testing** - Ping tests verify connectivity
- ✅ **IP address export** - Generates list of all assignments for documentation
- ✅ **Supports both LXC and VMs** - Handles containers and virtual machines
- ✅ **Idempotent** - Safe to run multiple times (skips already configured)

## 📋 Prerequisites

- Proxmox VE 6.x or newer
- Root access to Proxmox host
- At least one LXC container or VM

## 🚀 Quick Start

### 1. Download the Script

```bash
cd /root/
wget https://raw.githubusercontent.com/Kamynsky/proxmox-internal-network/main/add_vmbr_to_pve_lxc_vm.sh
# or
curl -O https://raw.githubusercontent.com/Kamynsky/proxmox-internal-network/main/add_vmbr_to_pve_lxc_vm.sh
```

### 2. Configure Settings

Edit the configuration section at the top of the script:

```bash
nano add_vmbr_to_pve_lxc_vm.sh
```

```bash
#############################################
# Configuration Section - Edit these values
#############################################

BASE_IP="10.0.0"              # Base IP (first three octets)
SUBNET_MASK="24"              # Subnet mask (CIDR notation)
BRIDGE_NAME="vmbr1"           # Bridge name
BRIDGE_IP_LAST_OCTET="1"      # Last octet for bridge (10.0.0.1)
```

**That's it!** No need to specify VMID ranges - the script finds all containers automatically.

### 3. Run the Script

```bash
chmod +x add_vmbr_to_pve_lxc_vm.sh
./add_vmbr_to_pve_lxc_vm.sh
```

## 📖 How It Works

### Automatic Discovery

The script automatically scans for all containers and VMs:
- **LXC containers**: Scans `/etc/pve/lxc/*.conf`
- **VMs**: Scans `/etc/pve/qemu-server/*.conf`
- **No manual range needed**: Works with any VMIDs (100, 101, 150, 200, etc.)

Example output:
```
Discovering LXC containers and VMs...
Found:
  - 5 LXC container(s)
  - 3 VM(s)
  - Total: 8 container(s)/VM(s)

VMIDs to process: 100 101 104 105 110 200 201 250
```

### IP Address Assignment

The script uses a simple VMID-to-IP mapping:
- **VMID 100** → 10.0.0.100
- **VMID 104** → 10.0.0.104
- **VMID 150** → 10.0.0.150
- **VMID 250** → 10.0.0.250

The last octet always matches the VMID!

### IP Address Export

After completion, the script exports all IP assignments to `/root/internal-network-ips.txt`:
```
=== Internal Network IP Assignments ===
Generated: Sun Feb 15 20:22:00 CET 2026
Bridge: vmbr1 (10.0.0.1/24)

LXC 100 (traefik): 10.0.0.100
LXC 104 (sonarr): 10.0.0.104
LXC 105 (radarr): 10.0.0.105
VM  108 (homeassistant): 10.0.0.108
VM  110 (truenas): 10.0.0.110
```

### Network Traffic Flow

```
┌─────────────────────────────────────────────┐
│           Proxmox Host (10.0.0.1)           │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │   vmbr1 (Internal Bridge)            │  │
│  │   - No physical NIC                  │  │
│  │   - Software-only                    │  │
│  └────┬──────────┬──────────┬───────────┘  │
│       │          │          │               │
│   ┌───▼───┐  ┌───▼───┐  ┌───▼───┐          │
│   │ LXC   │  │ LXC   │  │  VM   │          │
│   │ 100   │  │ 104   │  │ 150   │          │
│   │.100   │  │.104   │  │.150   │          │
│   └───────┘  └───────┘  └───────┘          │
│                                             │
│   All internal traffic stays within host   │
└─────────────────────────────────────────────┘
```

### Execution Steps

1. **Discovers all containers/VMs** by scanning config files
2. **Creates vmbr1 bridge** on Proxmox host (10.0.0.1/24)
3. **Backs up all configs** to timestamped directory
4. **Scans for existing** interfaces (skips duplicates)
5. **For each LXC container:**
   - Adds network interface to Proxmox config
   - Configures `/etc/network/interfaces` inside container
   - Reboots and tests connectivity
6. **For each VM:**
   - Adds network interface to Proxmox config
   - Prompts you to configure IP inside guest OS manually
7. **Tests connectivity** with ping to Proxmox host
8. **Provides summary** of all IP assignments
9. **Exports IP list** to `/root/internal-network-ips.txt`

## 🔧 Use Cases

### With Traefik Reverse Proxy
Perfect for routing internal traffic to services without going through your physical network:
```
Traefik (LXC 110, 10.0.0.110) → Sonarr (LXC 105, 10.0.0.105)
                               → Radarr (LXC 106, 10.0.0.106)
                               → Home Assistant (VM 108, 10.0.0.108)
```

### With Tailscale Subnet Router
Configure Tailscale LXC as subnet router to advertise `10.0.0.0/24`, allowing remote access to all internal services.

### With Pi-hole + OpenWrt
Set up local DNS records in Pi-hole pointing to the internal IPs for easy service access. Use the exported IP list for quick DNS configuration.

## 🛡️ Safety Features

### Automatic Backups
All configurations backed up to `/root/lxc-vm-backup-TIMESTAMP/` before any changes.

### Duplicate Detection
Checks for existing interfaces by:
- Bridge name match
- IP address in subnet range
- Active IP inside running containers

### Error Handling
If critical errors occur:
- Automatic rollback of all changes
- Restores from backup
- Reboots affected containers/VMs

### Manual Rollback
```bash
# Restore single container
cp /root/lxc-vm-backup-TIMESTAMP/104.conf /etc/pve/lxc/104.conf
pct reboot 104

# Restore all
cp /root/lxc-vm-backup-TIMESTAMP/*.conf /etc/pve/lxc/
```

## 📊 Example Output

```
========================================
Network Configuration Script
========================================
Configuration:
  Bridge: vmbr1
  Bridge IP: 10.0.0.1/24
  Network: 10.0.0.0/24
  IP Assignment: VMID = Last Octet
========================================

Discovering LXC containers and VMs...
Found:
  - 6 LXC container(s)
  - 2 VM(s)
  - Total: 8 container(s)/VM(s)

VMIDs to process: 100 101 104 105 106 110 150 200

Step 1: Creating vmbr1 bridge on Proxmox
✓ Bridge vmbr1 created successfully with IP 10.0.0.1/24

Step 4: Checking existing configurations
⚠ LXC 104: Already configured (found via bridge_name)
Found 1 container(s)/VM(s) already configured. These will be skipped.

=== Processing LXC Container 105 ===
Adding vmbr1 to LXC 105 with IP 10.0.0.105/24
  MAC address: 02:a3:45:67:89:ab
✓ SUCCESS: LXC 105 can reach Proxmox host at 10.0.0.1

=== Processing VM 150 ===
Adding vmbr1 to VM 150 as net1
  MAC address: 02:b4:56:78:9a:bc
✓ Network interface added to VM 150 configuration
  Configure IP 10.0.0.150/24 inside the guest OS

✓ Script completed successfully!

Exporting IP addresses to file...
✓ IP addresses exported to: /root/internal-network-ips.txt
```

## 🔍 Verification Commands

```bash
# Check bridge on host
ip addr show vmbr1

# View exported IP list
cat /root/internal-network-ips.txt

# Check LXC container network
pct exec 104 -- ip addr show
pct exec 104 -- ping -c 3 10.0.0.1

# Check VM (from inside guest OS)
ip addr show
ping -c 3 10.0.0.1
```

## ⚠️ Important Notes

### For LXC Containers
- ✅ Network configured **automatically** (if using `/etc/network/interfaces`)
- ⚠️ Containers using **systemd-networkd** or **netplan** require manual configuration

### For VMs
- ⚠️ Network interface added to Proxmox config, but you **must configure IP inside guest OS manually**
- For Linux VMs: Edit `/etc/network/interfaces` or netplan config
- For Windows VMs: Configure via Network Settings GUI

### VMID Range
- ✅ **Works with any VMID** - no range restrictions
- ✅ **Skips gaps automatically** - VMIDs 100, 105, 150 work fine
- ⚠️ **High VMIDs need larger subnet** - VMID 250+ requires BASE_IP that supports it

### Network Isolation
- Internal traffic stays **entirely within Proxmox host** (doesn't touch physical network)
- Containers/VMs can still access internet via their primary interface (vmbr0)
- No gateway needed on vmbr1 for internal-only communication

## 🐛 Troubleshooting

### Container can't reach Proxmox host
```bash
# Check if interface is up
pct exec 104 -- ip addr show

# Check if bridge exists
ip addr show vmbr1

# Manually bring up interface
pct exec 104 -- ifup eth1
```

### VM network not working
VMs require manual configuration inside the guest OS. The script only adds the interface to Proxmox config.

### Script fails with permission error
Make sure you're running as root on the Proxmox host (not inside a container).

### High VMID numbers (200+)
Make sure your subnet can accommodate high IPs. Default `/24` subnet only supports IPs up to `.254`.

## 📝 Configuration Examples

### Different Network Range
```bash
BASE_IP="192.168.100"
SUBNET_MASK="24"
BRIDGE_IP_LAST_OCTET="1"
# Results in 192.168.100.1/24 bridge
# VMIDs get 192.168.100.X where X = VMID
```

### Different Bridge Name
```bash
BRIDGE_NAME="vmbr2"
# Creates vmbr2 instead of vmbr1
```

### Larger Subnet for High VMIDs
```bash
BASE_IP="10.0.0"
SUBNET_MASK="23"
# Supports IPs up to 10.0.1.254 (VMID 510)
```

## 📄 Generated Files

After running the script, you'll find:

| File | Description |
|------|-------------|
| `/root/lxc-vm-backup-TIMESTAMP/` | Backup directory with original configs |
| `/root/lxc-vm-network-errors.log` | Error log (if any errors occurred) |
| `/root/internal-network-ips.txt` | **Exported list of all IP assignments** |

## 📄 License

MIT License - Feel free to use and modify

## 🤝 Contributing

Issues and pull requests welcome!

**Made with ❤️ for the self-hosted community**
