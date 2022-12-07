#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${DEBUG:-}" ]]; then
    set -x
fi

# Grab the machine config from a file
source "${FC_CONFIG:-default.conf}"

# Check for some dependencies
command -v firecracker >/dev/null || (echo "could not find firecracker in PATH"; exit 1)
command -v firectl >/dev/null || (echo "could not find firectl in PATH"; exit 1)
if [[ -z "${FC_DHCP:-}" ]]; then
  command -v dnsmasq >/dev/null || (echo "could not find dnsmasq in PATH"; exit 1)
fi

# Check if the linux kernel and disk images are built, and build them if not
if [[ ! -f "./build/dist/vmlinux" ]] || [[ ! -f "./build/dist/image.ext4" ]]; then
  make all
fi

# If there is no vm directory, create one and move the built kernel image and rootfs
# into the directory before we try to boot it
if [[ ! -d "./vm" ]]; then
  mkdir -p vm
  # Copy image and kernel
  cp build/dist/vmlinux build/dist/image.ext4 vm/
  # Resize image to 20G
  truncate -s "$FC_DISK" vm/image.ext4
  resize2fs vm/image.ext4
fi

# Kernel command line for the VM
KERNEL_OPTS="init=/bin/systemd noapic reboot=k panic=1 pci=off console=ttyS0 systemd.hostname=${FC_HOSTNAME}"

# Get the device name of the default gateway on the host
DEVICE_NAME="$(\ip route get 8.8.8.8 |grep uid |sed "s/.* dev \([^ ]*\) .*/\1/")"
# Generate a name for the tap interface
TAP_IFACE="fctap0$(openssl rand -hex 2)"

if [[ -z "${FC_DHCP:-}" ]]; then
  # Do some network interface setup if not already complete
  if ! ip l | grep -q "$TAP_IFACE"; then
    sudo ip tuntap add dev "$TAP_IFACE" mode tap user "$(whoami)"
    sudo ip addr add 172.20.0.1/24 dev "$TAP_IFACE"
    sudo ip link set "$TAP_IFACE" up
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    sudo iptables -t nat -A POSTROUTING -o "$DEVICE_NAME" -j MASQUERADE
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i "$TAP_IFACE" -o "$DEVICE_NAME" -j ACCEPT
  fi

  KERNEL_OPTS="$KERNEL_OPTS ip=172.20.0.2::172.20.0.1:255.255.255.0::eth0:off"
else
  BR_IFACE="fcbr0"
  
  # If there is no bridge interface, create one
  if ! ip l | grep -q "$BR_IFACE"; then
    sudo ip link add name "$BR_IFACE" type bridge
    sudo ip addr add 172.20.0.1/24 dev "$BR_IFACE"
    sudo ip link set "$BR_IFACE" up

    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
    sudo iptables -t nat -A POSTROUTING -o "$DEVICE_NAME" -j MASQUERADE
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i "$BR_IFACE" -o "$DEVICE_NAME" -j ACCEPT
  fi

  # Create a tap interface for the specific VM, add it to the bridge
  if ! ip l | grep -q "$TAP_IFACE"; then
    sudo ip tuntap add dev "$TAP_IFACE" mode tap # user "$(whoami)"
    sudo ip link set "$TAP_IFACE" master "$BR_IFACE"
    sudo ip link set "$TAP_IFACE" up
  fi

  # Start dnsmasq for DHCP/DNS on the bridge
  sudo dnsmasq \
    --strict-order \
    --bind-interfaces \
    --log-facility="$(pwd)/dnsmasq.log" \
    --pid-file="$(pwd)/dnsmasq.pid" \
    --dhcp-leasefile="$(pwd)/dnsmasq.leases" \
    --dhcp-hostsfile="$(pwd)/dnsmasq.hosts" \
    --domain=firecracker \
    --local=/firecracker/ \
    --except-interface=lo \
    --interface="$BR_IFACE" \
    --listen-address=172.20.0.1 \
    --dhcp-no-override \
    --dhcp-authoritative \
    --dhcp-range 172.20.0.2,172.20.0.100,infinite

  KERNEL_OPTS="$KERNEL_OPTS ip=dhcp"
fi

# Start the VM
firectl \
    --ncpus "$FC_CPUS" \
    --memory "$FC_MEMORY" \
    --kernel="vm/vmlinux" \
    --root-drive="vm/image.ext4" \
    --tap-device="$TAP_IFACE/$(cat "/sys/class/net/$TAP_IFACE/address")" \
    --kernel-opts="$KERNEL_OPTS"


# Cleanup and remove interfaces once the machine has gone down
sudo ip link del "$TAP_IFACE"

if [[ -n "${FC_DHCP:-}" ]]; then
  sudo kill -9 "$(cat dnsmasq.pid)"
  sudo ip link del "$BR_IFACE"
  sudo rm "$(pwd)/dnsmasq.pid"
fi