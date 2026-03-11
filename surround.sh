#!/usr/bin/env bash
set -euo pipefail

# Default ports
PORTS_STR="80,443,554,5060,8000"

show_help() {
cat << EOF
Usage: ${0##*/} [OPTIONS]

A fast, concurrent network scanner for your local /24 subnet.
It automatically determines your default gateway, assigns the target network,
and probes 254 IP addresses across specified ports using an ICMP gate followed by HTTP/TCP port checks.

Options:
  -p PORTS    Comma-separated list of ports to scan. (Default: 80,443,554,5060,8000)
  --help      Show this manual and exit.

Example:
  ${0##*/} -p 80,22,443,8080
EOF
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p) PORTS_STR="$2"; shift ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; show_help >&2; exit 1 ;;
    esac
    shift
done

# Split ports by comma
IFS=',' read -ra PORTS_ARRAY <<< "$PORTS_STR"

# Find Router IP
# Handle potential multiple default routes by taking the first one
DEFAULT_ROUTE=$(ip route list | grep default | head -n 1)

if [[ -z "$DEFAULT_ROUTE" ]]; then
    echo "Error: No default route found. Exiting."
    exit 1
fi

ROUTER_IP=$(echo "$DEFAULT_ROUTE" | awk '{print $3}')
INTERFACE=$(echo "$DEFAULT_ROUTE" | awk '{print $5}')

if [[ -z "$ROUTER_IP" ]] || [[ -z "$INTERFACE" ]]; then
    echo "Error: Could not determine Router IP or Interface. Exiting."
    exit 1
fi

# Find Own IP
OWN_IP=$(ip -o -4 addr list "$INTERFACE" | awk '{print $4}' | cut -d/ -f1 | head -n 1)

if [[ -z "$OWN_IP" ]]; then
    echo "Error: Could not determine Own IP on interface $INTERFACE. Exiting."
    exit 1
fi

# Determine Target Network (first 3 octets)
TARGET_NETWORK=$(echo "$ROUTER_IP" | cut -d. -f1-3)

# Gather Host Info
DEVICE_NAME=$(hostname)
UPTIME=$(uptime -p 2>/dev/null || uptime -s 2>/dev/null || uptime)
if [[ -f /etc/os-release ]]; then
    DISTRO=$(source /etc/os-release && echo "$PRETTY_NAME")
else
    DISTRO=$(uname -srm)
fi

# Attempt to extract hardware model (works on almost all systemd/sysfs compatible Linux distros)
if [[ -r /sys/devices/virtual/dmi/id/product_name ]]; then
    HARDWARE_MODEL=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)
elif [[ -r /sys/firmware/devicetree/base/model ]]; then
    # Fallback for many ARM-based boards (like Raspberry Pi)
    HARDWARE_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null)
else
    HARDWARE_MODEL="Unknown/Restricted"
fi

# Print Info
echo "----------------------------------------"
echo "Device Name    : $DEVICE_NAME"
echo "Hardware       : $HARDWARE_MODEL"
echo "Distro         : $DISTRO"
echo "Uptime         : ${UPTIME#up }"
echo "Router IP      : $ROUTER_IP"
echo "Own IP         : $OWN_IP"
echo "----------------------------------------"
echo "Starting network scan..."
echo ""

# Scan Loop
{
    for i in {1..254}; do
        (
            local_ip="$TARGET_NETWORK.$i"
            if ping -c 1 -W 1 "$local_ip" >/dev/null 2>&1; then
                # Temporary directory for parallel port results
                tmpdir=$(mktemp -d)
                trap 'rm -rf "$tmpdir"' EXIT

                # Parallel MAC Address Lookup from warm ARP cache
                (
                    raw_mac=$(ip neigh show "$local_ip" 2>/dev/null | awk '{print $5}')
                    if [[ "$raw_mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
                        echo "$raw_mac" > "$tmpdir/mac"
                    else
                        echo "-----------------" > "$tmpdir/mac"
                    fi
                ) &

                for idx in "${!PORTS_ARRAY[@]}"; do
                    p="${PORTS_ARRAY[$idx]}"
                    (
                        # First check if the TCP port translates to open state with 0.5s timeout
                        if timeout 0.5 bash -c "echo >/dev/tcp/$local_ip/$p" 2>/dev/null; then
                            # Port is open. Try to grab HTTP status.
                            s=$(curl -Is --connect-timeout 0.5 --max-time 1 "http://$local_ip:$p" -o /dev/null -w "%{http_code}" 2>/dev/null || true)
                            
                            # If curl couldn't get a valid HTTP status (e.g., it's RTSP or SSH), mark as OPN
                            if [[ "${s:-000}" == "000" ]]; then
                                s="OPN"
                            fi
                        else
                            s="   "
                        fi
                        echo "$s" > "$tmpdir/$idx"
                    ) &
                done
                wait
                
                mac=$(cat "$tmpdir/mac" 2>/dev/null || echo "-----------------")
                printf -v res "%-15s [%-17s]" "$local_ip" "$mac"
                
                for idx in "${!PORTS_ARRAY[@]}"; do
                    p="${PORTS_ARRAY[$idx]}"
                    s=$(cat "$tmpdir/$idx" 2>/dev/null || echo "   ")
                    res="$res :$p = $s,"
                done
                # Print result, removing trailing comma
                echo "${res%,}"
            fi
        ) &
    done

    wait
} | sort -V
echo "Scan complete."