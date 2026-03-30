#!/bin/bash
# Usage: sudo ./eth-to-wlan.sh
# Press Ctrl+C to stop and revert all changes.
#
# DESIGN SUMMARY:
# This script bridges an upstream Wi-Fi connection to a downstream Ethernet port.
# Because a host process (like Waydroid) irrevocably locks port 67 (DHCP) across 0.0.0.0,
# standard DHCP relays or local dnsmasq servers will fail to bind.
#
# SOLUTION:
# 1. We create an isolated Network Namespace and use a `macvlan` interface to give
#    a lightweight `dnsmasq` instance its own clean port 67 to answer downstream requests.
# 2. We bypass buggy third-party ARP daemons (like `parprouted`) by configuring native
#    Linux kernel Proxy ARP and routing a tiny sliver of IPs (/28) directly to eth0.
# 3. We apply NAT (Masquerade) 100% of the time to bypass Wi-Fi Access Point MAC/IP spoofing protections.

# --- Error Handling ---
# Prints red text and exits immediately if a critical command fails.
error() {
  echo -e "\e[91m[-] FATAL ERROR: $1\e[0m" 1>&2
  exit 1
}

userinput_func() { # userinput function to display yad/cli prompts to the user
  local text="$1"
  [ -z "$text" ] && error "userinput_func(): requires a description"
  shift
  [ -z "$1" ] && error "userinput_func(): requires at least one output selection option"
  local text_lines=$(echo -e "$1" | wc -l)
  
  local uniq_selection=()
  local string string_echo
  #make a form button for each choice
  for string in "$@"; do
    #to address bash subprocess syntax errors, while making output match input, escape any double-quotes in the string down 3 layers
    string_echo="$(echo "$string" | sed 's/"/"\\"""\\\\""\\"""\\"/g')"
    uniq_selection+=(--field="$string:FBTN" "bash -c "\""echo "\"""\\""\"""\""$string_echo"\"""\\""\"""\"";kill "\$"YAD_PID"\""")
  done

  #make long lists of options scrollable, with a sensible window size
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

if [ "$EUID" -ne 0 ]; then
  error "Script must be run as root (use sudo)"
elif ! command -v yad >/dev/null || ! command -v dnsmasq >/dev/null || ! command -v tcpdump >/dev/null || ! command -v iptables >/dev/null ;then
  error "Please install the dependencies: yad dnsmasq tcpdump iptables"
fi

#Choose a network interface to share
options="$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | sort -u)"
if [ -z "$options" ];then
  error "Could not find any default network device that the kernel considers 'default'!"
else
  options="$(echo "$options" | tr '\n' ' ')"
fi

#handle command-line input
UPSTREAM_DEV="$1"
if [ ! -z "$UPSTREAM_DEV" ] && echo "$options" | grep -wF "$UPSTREAM_DEV" ;then
  echo "Using pre-selected upstream network interface: $UPSTREAM_DEV"
else
  if [ ! -z "$UPSTREAM_DEV" ];then
    echo "Warning: Ignoring your pre-selected upstream network interface ($UPSTREAM_DEV) because it does not appear on this list: $options"
  fi
  userinput_func "Choose a network interface to share" $options || error "Failed to launch GUI to select upstream network interface!\nYour options are: '$options'\nPlease specity one as the first argument to this script."
  UPSTREAM_DEV="$output"
fi

options="$(for dev in /sys/class/net/*; do [ -e "$dev/device" ] && [ ! -d "$dev/wireless" ] && echo "${dev##*/}"; done | grep -vFx "$UPSTREAM_DEV")"
if [ -z "$options" ];then
  error "Could not find any ethernet network devices to share a connection to!"
else
  options="$(echo "$options" | tr '\n' ' ')"
fi

#handle command-line input
DOWNSTREAM_DEV="$2"
if [ ! -z "$DOWNSTREAM_DEV" ] && echo "$options" | grep -wF "$DOWNSTREAM_DEV" ;then
  echo "Using pre-selected downstream network interface: $DOWNSTREAM_DEV"
else
  if [ ! -z "$DOWNSTREAM_DEV" ];then
    echo "Warning: Ignoring your pre-selected downstream network interface ($DOWNSTREAM_DEV) because it does not appear on this list: $options"
  fi
  userinput_func "Choose an Ethernet adapter to connect to downstream device(s)" $options || error "Failed to launch GUI to select downstream network interface!\nYour options are: '$options'\nPlease specity one as the second argument to this script."
  DOWNSTREAM_DEV="$output"
fi

echo "upstream $UPSTREAM_DEV"
echo "downstream $DOWNSTREAM_DEV"

cleanup() {
  echo -e "\n\n[!] Ctrl+C detected. Initiating teardown sequence..."
  
  # 1. Terminate isolated dnsmasq and monitoring tools.
  if [ -f /var/run/ns_dnsmasq.pid ]; then
    kill $(cat /var/run/ns_dnsmasq.pid) 2>/dev/null
    rm -f /var/run/ns_dnsmasq.pid
  fi

  # 2. Obliterate the namespace. This automatically cleans up the macvlan interface inside it.
  echo "[+] Removing network namespace 'dhcp_ns'..."
  ip netns del dhcp_ns 2>/dev/null

  # 3. Revert NAT and kernel routing flags to prevent unwanted network leakage later.
  echo "[+] Reverting IP routing, NAT rules, and proxy ARP kernel flags..."
  iptables -t nat -D POSTROUTING -o $UPSTREAM_DEV -j MASQUERADE 2>/dev/null
  sysctl -w net.ipv4.ip_forward=0 > /dev/null
  sysctl -w net.ipv4.conf.all.proxy_arp=0 > /dev/null
  sysctl -w net.ipv4.conf.$UPSTREAM_DEV.proxy_arp=0 > /dev/null
  sysctl -w net.ipv4.conf.$DOWNSTREAM_DEV.proxy_arp=0 > /dev/null

  # 4. Wipe our manual IPs and drop the physical link.
  echo "[+] Flushing and bringing down $DOWNSTREAM_DEV..."
  ip addr flush dev $DOWNSTREAM_DEV 2>/dev/null
  ip link set $DOWNSTREAM_DEV down

  # 5. Hand control back to NetworkManager so it can resume normal operations.
  echo "[+] Returning $DOWNSTREAM_DEV to NetworkManager control..."
  nmcli device set $DOWNSTREAM_DEV managed yes
  
  # 6. Bring physical link back up so NetworkManager can use it normally
  echo "[+] Bringing $DOWNSTREAM_DEV back up..."
  ip link set $DOWNSTREAM_DEV up
  
  echo "[✓] Teardown complete. System restored to normal."
  exit 0
}

# Trap standard exit signals to guarantee cleanup runs even if the script is interrupted.
trap cleanup INT TERM EXIT

echo "[+] Starting Wi-Fi to Ethernet Pseudobridge with Isolated DHCP..."

# Pre-cleanup in case a previous run crashed or was forcefully killed (SIGKILL).
ip netns del dhcp_ns 2>/dev/null
iptables -t nat -D POSTROUTING -o $UPSTREAM_DEV -j MASQUERADE 2>/dev/null

# Disconnect NetworkManager from eth0. If we don't do this, NM will detect the link
# state change when a device is plugged in, wipe our manual IPs, and try to request its own.
echo "[+] Setting $DOWNSTREAM_DEV to unmanaged state in NetworkManager..."
nmcli device set $DOWNSTREAM_DEV managed no || error "Failed to release $DOWNSTREAM_DEV from NetworkManager"

echo "[+] Bringing up $DOWNSTREAM_DEV physical link..."
ip link set $DOWNSTREAM_DEV up || error "Failed to bring up $DOWNSTREAM_DEV"
ip addr flush dev $DOWNSTREAM_DEV || error "Failed to flush $DOWNSTREAM_DEV addresses"

# --- Dynamic Subnet & Pool Calculation ---
UPSTREAM_DEV_CIDR=$(ip -4 addr show $UPSTREAM_DEV | awk '/inet / {print $2}' | head -n 1)
if [ -z "$UPSTREAM_DEV_CIDR" ]; then
    error "Could not find an IPv4 address for $UPSTREAM_DEV. Ensure you are connected to Wi-Fi."
fi
UPSTREAM_DEV_IP=$(echo $UPSTREAM_DEV_CIDR | cut -d/ -f1)
SUBNET=$(echo $UPSTREAM_DEV_IP | cut -d. -f1-3)
ROUTER_IP=$(ip route show default | awk '/default/ {print $3}' | head -n 1)

# Define a /28 subnet at the very top of the range (covers .240 to .255).
# This avoids DHCP pool collisions with the main upstream router.
DHCP_SUBNET="${SUBNET}.240/28"
DHCP_START="${SUBNET}.241"
DHCP_END="${SUBNET}.249"
DHCP_NS_IP="${SUBNET}.250" # The IP the namespace DHCP server will use to communicate.

echo "[+] Main Router Gateway detected: $ROUTER_IP"
echo "[+] Reserving isolated DHCP pool for downstream: $DHCP_START - $DHCP_END"

# --- Host Routing & Proxy ARP Configuration ---
echo "[+] Enabling IP forwarding and Proxy ARP..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null || error "Failed to enable ip_forward"
sysctl -w net.ipv4.conf.all.proxy_arp=1 > /dev/null || error "Failed to set global proxy_arp"
sysctl -w net.ipv4.conf.$UPSTREAM_DEV.proxy_arp=1 > /dev/null || error "Failed to set $UPSTREAM_DEV proxy_arp"
sysctl -w net.ipv4.conf.$DOWNSTREAM_DEV.proxy_arp=1 > /dev/null || error "Failed to set $DOWNSTREAM_DEV proxy_arp"

echo "[+] Cloning Wi-Fi IP ($UPSTREAM_DEV_IP) to $DOWNSTREAM_DEV to satisfy kernel routing..."
ip addr add $UPSTREAM_DEV_IP/32 dev $DOWNSTREAM_DEV || error "Failed to clone IP to $DOWNSTREAM_DEV"

echo "[+] Injecting static route for downstream pool ($DHCP_SUBNET) to $DOWNSTREAM_DEV..."
ip route add $DHCP_SUBNET dev $DOWNSTREAM_DEV || error "Failed to add static route for downstream pool"

# --- Namespace & MACVLAN Isolation Setup ---
echo "[+] Creating isolated network namespace 'dhcp_ns'..."
ip netns add dhcp_ns || error "Failed to create network namespace"

# Create a macvlan bridge. This creates a virtual network interface that shares the
# physical eth0 hardware but operates independently, allowing us to drop it into the namespace.
echo "[+] Spinning up macvlan interface on $DOWNSTREAM_DEV and binding to namespace..."
ip link add link $DOWNSTREAM_DEV name eth0_dhcp type macvlan mode bridge || error "Failed to create macvlan interface"
ip link set eth0_dhcp netns dhcp_ns || error "Failed to move macvlan to namespace"

echo "[+] Initializing namespace networking stack..."
ip netns exec dhcp_ns ip link set lo up || error "Failed to bring up loopback in namespace"
ip netns exec dhcp_ns ip link set eth0_dhcp up || error "Failed to bring up macvlan in namespace"
ip netns exec dhcp_ns ip addr add ${DHCP_NS_IP}/24 dev eth0_dhcp || error "Failed to assign IP to macvlan"

# --- Apply NAT (Masquerade) ---
echo "[+] Applying NAT (Masquerade) to bypass Wi-Fi AP Layer-2 restrictions..."
iptables -t nat -A POSTROUTING -o $UPSTREAM_DEV -j MASQUERADE || error "Failed to apply iptables NAT masquerade rule"

# Launch dnsmasq entirely inside the isolated namespace.
# Because it's isolated, it will successfully bind to port 67 on eth0_dhcp without hitting the Waydroid lock.
echo "[+] Launching isolated dnsmasq DHCP server..."
ip netns exec dhcp_ns /usr/sbin/dnsmasq \
  --conf-file=/dev/null \
  --bind-interfaces \
  --interface=eth0_dhcp \
  --except-interface=lo \
  --dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,12h \
  --dhcp-option=3,${ROUTER_IP} \
  --dhcp-option=6,8.8.8.8 \
  --pid-file=/var/run/ns_dnsmasq.pid || error "Failed to start dnsmasq in namespace"

echo "[==================================================]"
echo "[✓] Wi-Fi Pseudobridge is ACTIVE. Press Ctrl+C to safely teardown."
echo "[!] Awaiting downstream connection. Expected IP allocation: ~$DHCP_START"
echo "[==================================================]"

# Monitor and output DHCP (UDP 67/68) and ARP traffic in real-time.
tcpdump -i any "(udp and (port 67 or port 68)) or arp" -n || error "Failed to start tcpdump monitoring"
