#!/usr/bin/env bash
set -euo pipefail
# Enable command logging if DEBUG variable is set
[[ -z "${DEBUG:-}" ]] || set -x
# Helper methods for pretty output
_info() { echo -e "\e[92m[+] ${1:-}\e[0m"; }
_warn() { echo -e "\e[33m[-] ${1:-}\e[0m"; }
_error() { echo -e >&2 "\e[31m[!] ${1:-}\e[0m"; exit 1; }

# shellcheck source=default.conf
source "${FC_CONFIG:-default.conf}"

# Check for some dependencies
command -v firecracker >/dev/null || (echo "could not find firecracker in PATH"; exit 1)
command -v firectl >/dev/null || (echo "could not find firectl in PATH"; exit 1)
if [[ -z "${FC_DHCP:-}" ]]; then
  command -v dnsmasq >/dev/null || (echo "could not find dnsmasq in PATH"; exit 1)
fi

DOWNLOAD_DIR="$(pwd)/images/${FC_SERIES}"
mkdir -p "$DOWNLOAD_DIR"

IMAGE="${FC_SERIES}-server-cloudimg-amd64-root.tar.xz"
KERNEL="${FC_SERIES}-server-cloudimg-amd64-vmlinuz-generic"
INITRD="${FC_SERIES}-server-cloudimg-amd64-initrd-generic"

# Download the rootfs if it doesn't exist
if [[ ! -f "${DOWNLOAD_DIR}/${IMAGE}" ]]; then
  url="https://cloud-images.ubuntu.com/${FC_SERIES}/current/${IMAGE}"
  _info "Downloading: $url"
  curl -fsSL -o "${DOWNLOAD_DIR}/${IMAGE}" "$url"
fi

# Download the kernel if it doesn't exist
if [[ ! -f "${DOWNLOAD_DIR}/${KERNEL}" ]]; then
  url="https://cloud-images.ubuntu.com/${FC_SERIES}/current/unpacked/${KERNEL}"
  _info "Downloading: $url"
  curl -fsSL -o "${DOWNLOAD_DIR}/${KERNEL}" "$url"
fi

# Download the initrd if it doesn't exist
if [[ ! -f "${DOWNLOAD_DIR}/${INITRD}" ]]; then
  url="https://cloud-images.ubuntu.com/${FC_SERIES}/current/unpacked/${INITRD}"
  _info "Downloading: $url"
  curl -fsSL -o "${DOWNLOAD_DIR}/${INITRD}" "$url"
fi

# Check the disk image we generate is there; if not generate it
GENERATED_DISK="${DOWNLOAD_DIR}/disk.ext4"
if [[ ! -f "$GENERATED_DISK" ]]; then
  _info "Generating disk image from ${DOWNLOAD_DIR}/${IMAGE}"
  # Create a disk image we can use from the downloaded rootfs
  truncate -s "2G" "$GENERATED_DISK"
  mkfs.ext4 "$GENERATED_DISK" > /dev/null 2>&1
  # Mount the new disk image to a temporary directory
  tmpdir=$(mktemp -d)
  sudo mount "$GENERATED_DISK" -o loop "$tmpdir"
  # Extract the dowloaded disk image into the new disk image
  sudo tar -C "$tmpdir" -xf "${DOWNLOAD_DIR}/${IMAGE}"
  # Cleanup
  sudo umount "$tmpdir"
  rm -rf "$tmpdir"
fi

# Extract the vmlinux from the kernel image
if [[ ! -f "${DOWNLOAD_DIR}/vmlinux" ]]; then
  _info "Extracting vmlinux from ${DOWNLOAD_DIR}/${KERNEL}"
  tmpdir="$(mktemp -d)"
  curl -fsSL -o "${tmpdir}/extract-vmlinux" "https://raw.githubusercontent.com/torvalds/linux/master/scripts/extract-vmlinux"
  bash "${tmpdir}/extract-vmlinux" "${DOWNLOAD_DIR}/${KERNEL}" > "${DOWNLOAD_DIR}/vmlinux"
  rm -rf "$tmpdir"
fi

mkdir -p "$(pwd)/vm"
VM_ROOTFS="$(pwd)/vm/vmdisk.ext4"
VM_KERNEL="$(pwd)/vm/vmlinux"
VM_INITRD="$(pwd)/vm/initrd"

if [[ ! -f "$VM_ROOTFS" ]]; then
  # If there is no vm directory, create one and move the built kernel image and rootfs
  # into the directory before we try to boot it
  if [[ ! -f "$VM_ROOTFS" ]]; then
    _info "Resizing disk image for VM"
    # Copy image and kernel
    cp "$GENERATED_DISK" "$VM_ROOTFS"
    # Resize image to 20G
    truncate -s "$FC_DISK" "$VM_ROOTFS"
    resize2fs "$VM_ROOTFS" >/dev/null 2>&1 || e2fsck -f "$VM_ROOTFS" >/dev/null 2>&1
  fi

fi
[[ -e "$VM_KERNEL" ]] || ln -s "${DOWNLOAD_DIR}/vmlinux" "$VM_KERNEL"
[[ -e "$VM_INITRD" ]] || ln -s "${DOWNLOAD_DIR}/${INITRD}" "$VM_INITRD"

# Kernel command line for the VM
KERNEL_OPTS="init=/bin/systemd noapic reboot=k panic=1 pci=off console=ttyS0 systemd.hostname=${FC_HOSTNAME}"
# Get the device name of the default gateway on the host
DEVICE_NAME="$(\ip route get 8.8.8.8 | grep uid |sed "s/.* dev \([^ ]*\) .*/\1/")"
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

  KERNEL_OPTS="${KERNEL_OPTS} ip=172.20.0.2::172.20.0.1:255.255.255.0::eth0:off"
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

  KERNEL_OPTS="${KERNEL_OPTS} ip=dhcp"
fi

# Start the VM
firectl \
    --ncpus "$FC_CPUS" \
    --memory "$FC_MEMORY" \
    --kernel="$VM_KERNEL" \
    --initrd-path="$VM_INITRD" \
    --root-drive="$VM_ROOTFS" \
    --tap-device="${TAP_IFACE}/$(cat "/sys/class/net/${TAP_IFACE}/address")" \
    --kernel-opts="$KERNEL_OPTS"

# Cleanup and remove interfaces once the machine has gone down
sudo ip link del "$TAP_IFACE"

if [[ -n "${FC_DHCP:-}" ]]; then
  sudo kill -9 "$(cat dnsmasq.pid)"
  sudo ip link del "$BR_IFACE"
  sudo rm "$(pwd)/dnsmasq.pid"
fi