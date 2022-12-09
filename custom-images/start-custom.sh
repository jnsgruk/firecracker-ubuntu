#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${DEBUG:-}" ]]; then
    set -x
fi

# Grab the machine config from a file
source "${FC_CONFIG:-default.conf}"

# Check for some dependencies
command -v firecracker >/dev/null || (echo "could not find 'firecracker' in PATH"; exit 1)
command -v firectl >/dev/null || (echo "could not find 'firectl' in PATH"; exit 1)
command -v docker >/dev/null || (echo "could not find 'docker' in PATH"; exit 1)

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

# Do some network interface setup if not already complete
if ! ip l | grep -q "$TAP_IFACE"; then
sudo ip tuntap add dev "$TAP_IFACE" mode tap user "$(whoami)"
sudo ip addr add 172.25.0.1/24 dev "$TAP_IFACE"
sudo ip link set "$TAP_IFACE" up
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -t nat -A POSTROUTING -o "$DEVICE_NAME" -j MASQUERADE
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$TAP_IFACE" -o "$DEVICE_NAME" -j ACCEPT
fi

KERNEL_OPTS="$KERNEL_OPTS ip=172.25.0.2::172.25.0.1:255.255.255.0::eth0:off"

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