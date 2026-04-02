#!/bin/bash
# Usage: sudo ./eth-to-wlan.sh [upstream_wlan_or_usb] [downstream_eth]
# Press Ctrl+C to stop and revert all changes.

# DESIGN SUMMARY:
# This script shares an upstream connection (Wi-Fi or USB tethering) to a downstream Ethernet port.
#
# SOLUTION MECHANICS:
# 1. DHCP ISOLATION: Because host processes (like Waydroid, Docker, or libvirt) often irrevocably
#    lock port 67 (DHCP) on 0.0.0.0, standard local dnsmasq servers fail to bind. We solve this by
#    creating an isolated Network Namespace. A `macvlan` interface links this namespace to the
#    downstream adapter, giving `dnsmasq` a clean, dedicated environment to answer DHCP requests.
# 2. POLICY-BASED ROUTING (PBR): Instead of relying on buggy Proxy ARP daemons or bridging, the
#    script provisions a dynamic, dedicated /24 subnet (10.42.X.0/24). It uses PBR with custom
#    routing tables to forcefully route downstream traffic out the selected upstream gateway,
#    preventing multi-WAN conflicts with the host's default routing table.
# 3. NAT/MASQUERADE: Outbound traffic is MASQUERADED using `nftables` (with iptables fallback).
#    This is strictly required to bypass Wi-Fi Access Point MAC/IP spoofing protections, as APs
#    will drop frames containing the MAC addresses of downstream devices.
# 4. SERVICE DISCOVERY: Dynamically tweaks `avahi-daemon` to enable mDNS reflection across
#    subnets, allowing downstream devices to discover cast targets, TVs, or printers upstream.

# Determine GUI availability exactly once
USE_GUI=0
if { [ -n "$DISPLAY" ] || [ -n "$WAYLAND_DISPLAY" ]; } && command -v yad >/dev/null 2>&1; then
  USE_GUI=1
fi

DIRECTORY="$(readlink -f "$(dirname "$0")")"

#Track the original arguments given to the script in order to restart in an update
original_flags=("$@")

error() {
  echo -e "\e[91m[-] FATAL ERROR: $1\e[0m" 1>&2
  if [ "$USE_GUI" -eq 1 ]; then
    yad --title="Fatal Error" --window-icon=dialog-error --image=dialog-error \
        --text="$1" --button="Close:0" --center --borders=20 --fixed 2>/dev/null
  fi
  exit 1
}

warning() { #yellow text
  echo -e "\e[93m\e[5m◢◣\e[25m WARNING: $1\e[0m" 1>&2
}

update_check() { #check for updates and reload the script if necessary
  localhash="$(cd "$DIRECTORY" ; git rev-parse HEAD)"
  latesthash="$(git ls-remote https://github.com/Botspot/ethernet-hotspot HEAD | awk '{print $1}')"
  if [ "$localhash" != "$latesthash" ] && [ ! -z "$latesthash" ] && [ ! -z "$localhash" ];then
    echo "Auto-updating this script for the latest features and improvements..."
    (cd "$DIRECTORY"
    git restore . #abandon changes to tracked files (otherwise users who modified this script are left behind)
    git -c color.ui=always pull | cat #piping through cat makes git noninteractive
    exit "${PIPESTATUS[0]}")
    
    if [ $? == 0 ];then
      echo "git pull finished. Reloading script..."
      "$DIRECTORY/run.sh" "${original_flags[@]}"
      exit $?
    else
      warning "update_check: git pull failed. Continuing..."
    fi
  fi
}

userinput_func() {
  local text="$1"
  [ -z "$text" ] && error "userinput_func(): requires a description"
  shift
  [ -z "$1" ] && error "userinput_func(): requires at least one output selection option"
  
  # Fallback to CLI (read/select) if no GUI is available
  if [ "$USE_GUI" -eq 0 ]; then
    echo -e "\n=== $text ==="
    local PS3="Please enter the number of your choice: "
    select opt in "$@"; do
      if [ -n "$opt" ]; then
        output="$opt"
        return 0
      else
        echo "Invalid selection. Please try again."
      fi
    done
    return 1
  fi
  
  # GUI Logic
  local uniq_selection=()
  local string string_echo
  for string in "$@"; do
    string_echo="$(echo "$string" | sed 's/"/"\\"""\\\\""\\"""\\"/g')"
    uniq_selection+=(--field="$string:FBTN" "bash -c "\""echo "\"""\\""\"""\""$string_echo"\"""\\""\"""\"";kill "\$"YAD_PID"\""")
  done

  if [ "${#@}" -gt 10 ];then
    uniq_selection+=(--scroll --width=600 --height=400)
  fi
  
  if [ -z "${yadflags[*]}" ];then
    yadflags=(--title="Network interface sharing" --separator='\n')
  fi
  
  output=$(yad "${yadflags[@]}" --no-escape --undecorated --center --borders=20 \
    --text="$text" --form --no-buttons --fixed \
    "${uniq_selection[@]}")
  if [ -z "$output" ];then
    return 1
  else
    return 0
  fi
}

update_check

if [ "$EUID" -ne 0 ]; then
  error "Script must be run as root (use sudo)"
elif ! command -v dnsmasq >/dev/null || ! command -v tcpdump >/dev/null || ! command -v nft >/dev/null ;then
  error "Please install the dependencies: dnsmasq tcpdump nftables\n(Optional: 'yad' for GUI prompts)"
fi

# 1. Grab ONLY wireless or USB interfaces that are actively connected (have an IPv4 address)
options="$(for dev in /sys/class/net/*; do
  ifname="${dev##*/}"
  # Include wireless adapters, interfaces starting with 'usb', or adapters on a physical USB bus
  if [ -d "$dev/wireless" ] || [[ "$ifname" == usb* ]] || { [ -e "$dev/device" ] && readlink -f "$dev/device" | grep -q "usb"; }; then
    if ip -4 addr show dev "$ifname" 2>/dev/null | grep -q "inet "; then
      echo "$ifname"
    fi
  fi
done | tr '\n' ' ')"

if [ -z "$options" ]; then
  error "Could not find any actively connected Wi-Fi or USB adapters. Please connect to a network first!"
fi

UPSTREAM_DEV="$1"
if [ ! -z "$UPSTREAM_DEV" ] && echo "$options" | grep -wF "$UPSTREAM_DEV" >/dev/null ;then
  echo "Using pre-selected upstream network interface: $UPSTREAM_DEV"
else
  [ ! -z "$UPSTREAM_DEV" ] && warning "Ignoring pre-selected upstream interface ($UPSTREAM_DEV)."
  userinput_func "Choose an active Wi-Fi/USB interface to share" $options || error "Failed to get user input.\nPlease specify interface as first argument."
  UPSTREAM_DEV="$output"
fi

# 2. Grab Ethernet interfaces (Excludes the selected upstream interface)
options="$(for dev in /sys/class/net/*; do [ -e "$dev/device" ] && [ ! -d "$dev/wireless" ] && echo "${dev##*/}"; done | grep -vFx "$UPSTREAM_DEV" | tr '\n' ' ')"
if [ -z "$options" ];then
  error "Could not find any ethernet network devices to share a connection to!"
fi

DOWNSTREAM_DEV="$2"
if [ ! -z "$DOWNSTREAM_DEV" ] && echo "$options" | grep -wF "$DOWNSTREAM_DEV" >/dev/null ;then
  echo "Using pre-selected downstream network interface: $DOWNSTREAM_DEV"
else
  [ ! -z "$DOWNSTREAM_DEV" ] && warning "Ignoring pre-selected downstream interface ($DOWNSTREAM_DEV)."
  userinput_func "Choose an Ethernet adapter to connect to downstream device(s)" $options || error "Failed to get user input.\nPlease specify interface as second argument."
  DOWNSTREAM_DEV="$output"
fi

# 3. Dynamic Subnet & Instance Calculator
SUBNET_X=0
while [ $SUBNET_X -lt 255 ]; do
  if ! ip route show | grep -q "^10.42.$SUBNET_X.0/24"; then
    break
  fi
  SUBNET_X=$((SUBNET_X + 1))
done
if [ $SUBNET_X -eq 255 ]; then
  error "Could not find a free 10.42.X.0/24 subnet to host this connection."
fi

SUBNET_PREFIX="10.42.$SUBNET_X"
HOST_IP="$SUBNET_PREFIX.1"
DHCP_NS_IP="$SUBNET_PREFIX.2"
DHCP_START="$SUBNET_PREFIX.10"
DHCP_END="$SUBNET_PREFIX.100"

# Unique Instance Variables
TABLE_ID=$((100 + SUBNET_X))
NS_NAME="dhcp_ns_$SUBNET_X"
MACVLAN_NAME="macv_$SUBNET_X"
PID_FILE="/var/run/ns_dnsmasq_$SUBNET_X.pid"
AVAHI_BAK="/etc/avahi/avahi-daemon.conf.bak.pseudobridge_$SUBNET_X"
NAT_TABLE="pseudobridge_nat_$SUBNET_X"
FILTER_TABLE="pseudobridge_filter_$SUBNET_X"

# 4. Gateway Discovery for Policy-Based Routing
UPSTREAM_GW=$(ip -4 route show dev $UPSTREAM_DEV | awk '/default/ {print $3}' | head -n 1)
if [ -z "$UPSTREAM_GW" ]; then
  error "$UPSTREAM_DEV does not have a default gateway configured. Ensure it has internet access."
fi
UPSTREAM_SUBNET=$(ip -4 route show dev $UPSTREAM_DEV scope link | awk '{print $1}' | head -n 1)

cleanup() {
  trap - INT TERM EXIT
  echo -e "\n\n[!] Teardown sequence initiated for instance $SUBNET_X ($UPSTREAM_DEV -> $DOWNSTREAM_DEV)..."
  
  if [ -f "$PID_FILE" ]; then
    kill $(cat "$PID_FILE") 2>/dev/null
    rm -f "$PID_FILE"
  fi

  ip netns del $NS_NAME 2>/dev/null
  nft delete table ip $NAT_TABLE 2>/dev/null
  nft delete table ip $FILTER_TABLE 2>/dev/null
  
  iptables -D FORWARD -i "$DOWNSTREAM_DEV" -j ACCEPT 2>/dev/null
  iptables -D FORWARD -o "$DOWNSTREAM_DEV" -j ACCEPT 2>/dev/null
  iptables -D INPUT -i "$DOWNSTREAM_DEV" -j ACCEPT 2>/dev/null

  # Remove Policy-Based Routing Rules
  ip rule del from $HOST_IP/24 table $TABLE_ID 2>/dev/null
  ip route flush table $TABLE_ID 2>/dev/null

  if [ -f "$AVAHI_BAK" ]; then
    mv "$AVAHI_BAK" /etc/avahi/avahi-daemon.conf
    systemctl restart avahi-daemon 2>/dev/null
  fi

  ip addr flush dev $DOWNSTREAM_DEV 2>/dev/null
  ip link set $DOWNSTREAM_DEV down

  if command -v nmcli >/dev/null 2>&1; then
    nmcli device set $DOWNSTREAM_DEV managed yes
  fi
  
  ip link set $DOWNSTREAM_DEV up
  echo "[✓] Teardown complete for instance $SUBNET_X."
  exit 0
}

trap cleanup INT TERM EXIT

echo "[+] Starting Multi-WAN Pseudobridge ($UPSTREAM_DEV -> $DOWNSTREAM_DEV)..."

# Pre-cleanup instance variables
ip netns del $NS_NAME 2>/dev/null
nft delete table ip $NAT_TABLE 2>/dev/null
nft delete table ip $FILTER_TABLE 2>/dev/null
ip rule del from $HOST_IP/24 table $TABLE_ID 2>/dev/null

if command -v nmcli >/dev/null 2>&1; then
  nmcli device set $DOWNSTREAM_DEV managed no || error "Failed to release $DOWNSTREAM_DEV from NM"
  sleep 1
fi

ip link set $DOWNSTREAM_DEV up || error "Failed to bring up $DOWNSTREAM_DEV"
ip addr flush dev $DOWNSTREAM_DEV || error "Failed to flush $DOWNSTREAM_DEV addresses"
ip addr add $HOST_IP/24 dev $DOWNSTREAM_DEV || error "Failed to assign subnet IP"

echo "[+] Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null || error "Failed to enable global ip_forward"
sysctl -w net.ipv4.conf.$UPSTREAM_DEV.forwarding=1 > /dev/null
sysctl -w net.ipv4.conf.$DOWNSTREAM_DEV.forwarding=1 > /dev/null

echo "[+] Creating isolated network namespace '$NS_NAME'..."
ip netns add $NS_NAME || error "Failed to create network namespace"
ip link add link $DOWNSTREAM_DEV name $MACVLAN_NAME type macvlan mode bridge || error "Failed to create macvlan"
ip link set $MACVLAN_NAME netns $NS_NAME || error "Failed to move macvlan to namespace"

ip netns exec $NS_NAME ip link set lo up
ip netns exec $NS_NAME ip link set $MACVLAN_NAME up
ip netns exec $NS_NAME ip addr add ${DHCP_NS_IP}/24 dev $MACVLAN_NAME

echo "[+] Implementing Policy-Based Routing (Table $TABLE_ID)..."
echo "    -> Upstream Gateway: $UPSTREAM_GW"
ip rule add from $HOST_IP/24 table $TABLE_ID prio 1000
ip route add $UPSTREAM_SUBNET dev $UPSTREAM_DEV scope link table $TABLE_ID
ip route add $SUBNET_PREFIX.0/24 dev $DOWNSTREAM_DEV scope link table $TABLE_ID
ip route add default via $UPSTREAM_GW dev $UPSTREAM_DEV table $TABLE_ID

echo "[+] Applying Instance Firewall & NAT rules..."
nft add table ip $NAT_TABLE || error "Failed to create nat table"
nft add chain ip $NAT_TABLE postrouting { type nat hook postrouting priority 100 \; }
nft add rule ip $NAT_TABLE postrouting oifname "$UPSTREAM_DEV" masquerade || error "Failed to apply masquerade"

nft add table ip $FILTER_TABLE || error "Failed to create filter table"
# Allow Internet Forwarding
nft add chain ip $FILTER_TABLE forward { type filter hook forward priority 0 \; }
nft add rule ip $FILTER_TABLE forward iifname "$DOWNSTREAM_DEV" oifname "$UPSTREAM_DEV" accept || error "Failed to allow forward"
nft add rule ip $FILTER_TABLE forward iifname "$UPSTREAM_DEV" oifname "$DOWNSTREAM_DEV" accept || error "Failed to allow forward"
# Allow Local Host Input (for RustDesk/SSH)
nft add chain ip $FILTER_TABLE input { type filter hook input priority 0 \; }
nft add rule ip $FILTER_TABLE input iifname "$DOWNSTREAM_DEV" accept

# Fallback Legacy iptables
iptables -I FORWARD -i "$DOWNSTREAM_DEV" -j ACCEPT
iptables -I FORWARD -o "$DOWNSTREAM_DEV" -j ACCEPT
iptables -I INPUT -i "$DOWNSTREAM_DEV" -j ACCEPT

UPSTREAM_DNS=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | grep -v '^127\.' | head -n 1)
[ -z "$UPSTREAM_DNS" ] && UPSTREAM_DNS="8.8.8.8"

echo "[+] Launching isolated dnsmasq DHCP server..."
ip netns exec $NS_NAME /usr/sbin/dnsmasq \
  --conf-file=/dev/null \
  --bind-interfaces \
  --interface=$MACVLAN_NAME \
  --except-interface=lo \
  --dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h \
  --dhcp-option=3,${HOST_IP} \
  --dhcp-option=6,${UPSTREAM_DNS} \
  --pid-file="$PID_FILE" || error "Failed to start dnsmasq in namespace"

if command -v avahi-daemon >/dev/null && systemctl is-active --quiet avahi-daemon; then
  echo "[+] Enabling Avahi mDNS reflection for instance..."
  cp /etc/avahi/avahi-daemon.conf "$AVAHI_BAK"
  sed -i 's/.*enable-reflector.*/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
  grep -q "enable-reflector=yes" /etc/avahi/avahi-daemon.conf || sed -i '/^\[server\]/a enable-reflector=yes' /etc/avahi/avahi-daemon.conf
  systemctl restart avahi-daemon
fi

echo -e "\n[========== SYSTEM DIAGNOSTICS ==========]"
RP_UPSTREAM=$(cat /proc/sys/net/ipv4/conf/$UPSTREAM_DEV/rp_filter)
RP_ETH=$(cat /proc/sys/net/ipv4/conf/$DOWNSTREAM_DEV/rp_filter)
if [ "$RP_UPSTREAM" -eq 1 ] || [ "$RP_ETH" -eq 1 ]; then
  echo "[-] Relaxing Strict Reverse Path Filtering..."
  sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.$UPSTREAM_DEV.rp_filter=2 >/dev/null
  sysctl -w net.ipv4.conf.$DOWNSTREAM_DEV.rp_filter=2 >/dev/null
else
  echo "[✓] Reverse Path Filtering looks safe."
fi

IPTABLES_POL=$(iptables -L FORWARD -n | head -n 1)
if echo "$IPTABLES_POL" | grep -q "DROP"; then
  warning "Legacy iptables is defaulting to DROP. Fallback rules applied."
fi
echo "[========================================]"

echo "[✓] PBR Pseudobridge is ACTIVE: $DOWNSTREAM_DEV -> $UPSTREAM_DEV"
echo "[!] DHCP Subnet: $SUBNET_PREFIX.x (Gateway: $HOST_IP)"
echo "[==================================================]"

tcpdump -i any "icmp or (udp and (port 67 or port 68))" -n || error "Failed to start tcpdump monitoring"
