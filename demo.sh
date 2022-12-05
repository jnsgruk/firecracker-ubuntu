#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${DEBUG:-}" ]]; then
    set -x
fi

# Specs for the VM
CPUS="8"
MEMORY="16386" # 16GB
DISK="20G"

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
  truncate -s "$DISK" vm/image.ext4
  resize2fs vm/image.ext4
fi

TAP_IFACE="fc-tap0"
DEVICE_NAME="enp39s0"

# Do some network interface setup if not already complete
if ! ip l | grep -q "$TAP_IFACE"; then
  sudo ip addr add 172.20.0.1/24 dev "$TAP_IFACE"
  sudo ip link set "$TAP_IFACE" up
  sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
  sudo iptables -t nat -A POSTROUTING -o "$DEVICE_NAME" -j MASQUERADE
  sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  sudo iptables -A FORWARD -i "$TAP_IFACE" -o "$DEVICE_NAME" -j ACCEPT
fi

# Start the VM
firectl \
    --ncpus "$CPUS" \
    --memory "$MEMORY" \
    --kernel="vm/vmlinux" \
    --root-drive="vm/image.ext4" \
    --tap-device="$TAP_IFACE/$(cat /sys/class/net/$TAP_IFACE/address)" \
    --kernel-opts="init=/bin/systemd noapic reboot=k panic=1 pci=off console=ttyS0"
