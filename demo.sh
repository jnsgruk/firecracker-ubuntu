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
command -v jo >/dev/null || (echo "could not find jo in PATH"; exit 1)
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
  truncate -s "5G" "$GENERATED_DISK"
  # The ubuntu cloud image attempts a remount on the fs with label "cloudimg-rootfs" on boot
  mkfs.ext4 "$GENERATED_DISK" -L "cloudimg-rootfs" > /dev/null 2>&1
  # Mount the new disk image to a temporary directory
  tmpdir=$(mktemp -d)
  sudo mount "$GENERATED_DISK" -o loop "$tmpdir"
  # Extract the dowloaded disk image into the new disk image
  sudo tar -C "$tmpdir" -xf "${DOWNLOAD_DIR}/${IMAGE}"
  # Creating this override file stops systemd-netword-wait-online from waiting for the metadata
  # interface to be online, causing the boot to wait for long periods
  sudo mkdir -p $tmpdir/etc/systemd/system/systemd-networkd-wait-online.service.d
  cat <<EOF | sudo tee $tmpdir/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any
EOF
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

VM_DIR="$(pwd)/vm"
mkdir -p "$VM_DIR"
VM_ROOTFS="${VM_DIR}/vmdisk.ext4"
VM_KERNEL="${VM_DIR}/vmlinux"
VM_INITRD="${VM_DIR}/initrd"

if [[ ! -f "$VM_ROOTFS" ]]; then
  # If there is no vm directory, create one and move the built kernel image and rootfs
  # into the directory before we try to boot it
  if [[ ! -f "$VM_ROOTFS" ]]; then
    _info "Resizing disk image for VM"
    # Copy image and kernel
    cp "$GENERATED_DISK" "$VM_ROOTFS"
    # Resize image to 20G
    truncate -s "$FC_DISK" "$VM_ROOTFS"
    resize2fs "$VM_ROOTFS" >/dev/null 2>&1 || e2fsck -f "$VM_ROOTFS" >/dev/null 2>&1 || true
  fi
fi
[[ -e "$VM_KERNEL" ]] || ln -s "${DOWNLOAD_DIR}/vmlinux" "$VM_KERNEL"
[[ -e "$VM_INITRD" ]] || ln -s "${DOWNLOAD_DIR}/${INITRD}" "$VM_INITRD"

# Get the device name of the default gateway on the host
DEVICE_NAME="$(\ip route get 8.8.8.8 | grep uid |sed "s/.* dev \([^ ]*\) .*/\1/")"
# Generate a name for the tap interfaces
TAP_IFACE_MAIN="fctap0$(openssl rand -hex 2)"
TAP_IFACE_META="fctap0$(openssl rand -hex 2)"

# If there is no bridge interface, create one
BR_IFACE="fcbr0"
if ! ip l | grep -q "$BR_IFACE"; then
  sudo ip link add name "$BR_IFACE" type bridge
  sudo ip addr add 172.20.0.1/24 dev "$BR_IFACE"
  sudo ip link set "$BR_IFACE" up

  sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
  sudo iptables -t nat -A POSTROUTING -o "$DEVICE_NAME" -j MASQUERADE
  sudo iptables -I FORWARD -i "$BR_IFACE" -j ACCEPT
  sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi

# Create the main network interface for the VM
if ! ip l | grep -q "$TAP_IFACE_MAIN"; then
  sudo ip tuntap add dev "$TAP_IFACE_MAIN" mode tap 
  sudo ip link set "$TAP_IFACE_MAIN" up
  sudo ip link set "$TAP_IFACE_MAIN" master "$BR_IFACE"
fi

# Create a network interface for the MMDS
if ! ip l | grep -q "$TAP_IFACE_META"; then
  sudo ip tuntap add dev "$TAP_IFACE_META" mode tap
  sudo ip link set "$TAP_IFACE_META" up
fi

TAP_IFACE_MAIN_MAC="$(cat "/sys/class/net/${TAP_IFACE_MAIN}/address")"
TAP_IFACE_META_MAC="$(cat "/sys/class/net/${TAP_IFACE_META}/address")"

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

tmpdir="$(mktemp -d)"
# Start Firecracker

SOCKET="${VM_DIR}/.firecracker.socket"
LOG="${VM_DIR}/.firecracker.log"
CONSOLE_OUTPUT="${VM_DIR}/.firecracker.console.log"
touch "$LOG"
rm -f "$SOCKET"
firecracker --api-sock "$SOCKET" --log-path "$LOG" --level "Debug" &> "$CONSOLE_OUTPUT" &
PID="$!"
echo "$PID" > "${VM_DIR}/.firecracker.pid"

# Wait for API server to start
while [[ ! -e "$SOCKET" ]]; do sleep 0.1s; done
_info "Started firecracker; log file ${LOG}; pid ${PID}"

function fccurl() {
  curl --unix-socket "$SOCKET" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -X "$1" "http://localhost/$2" -d "$3"
}
function fccurl_file() {
  curl --unix-socket "$SOCKET" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -X "$1" "http://localhost/$2" --data-binary @"$3"
}

# Setup the machine CPU/Memory
fccurl PUT "machine-config" "$(jo vcpu_count=${FC_CPUS} mem_size_mib=${FC_MEMORY})"

# Setup the root filesystem drive
fccurl PUT "drives/rootfs" \
  "$(jo drive_id=rootfs path_on_host=$VM_ROOTFS is_root_device=true is_read_only=false)"

# Setup the eth0 interface - this is for the MMDS
fccurl PUT "network-interfaces/eth0" \
  "$(jo iface_id=eth0 guest_mac=${TAP_IFACE_META_MAC} host_dev_name=${TAP_IFACE_META})"

# Set the interface for the MMDS
fccurl PUT "mmds/config" "$(jo network_interfaces\[\]=eth0)"

# Setup the eth1 interface - this is the main network adapter
fccurl PUT "network-interfaces/eth1" \
  "$(jo iface_id=eth1 guest_mac=${TAP_IFACE_MAIN_MAC} host_dev_name=${TAP_IFACE_MAIN})"

# Configure the boot source
cat <<EOF > "$tmpdir/netconf.yaml"
version: 2
ethernets:
  eth0:
    match:
       macaddress: ${TAP_IFACE_META_MAC}
    addresses:
      - 169.254.0.1/16
  eth1:
    match:
      macaddress: ${TAP_IFACE_MAIN_MAC}
    dhcp4: true
EOF
NETCONFIG="$(cat "$tmpdir/netconf.yaml" | gzip --stdout - | base64 -w0)"
KERNEL_OPTS="reboot=k panic=1 pci=off console=ttyS0 ds=nocloud-net;s=http://169.254.169.254/latest/ network-config=$NETCONFIG"

# Setup the eth1 interface - this is the main network adapter
fccurl PUT "boot-source" \
  "$(jo kernel_image_path=${VM_KERNEL} boot_args="${KERNEL_OPTS}" initrd_path=${VM_INITRD})"

# Metadata
cat <<EOF | jq --raw-input --slurp '{ "latest": { "meta-data": . }}' > "$tmpdir/meta.yaml"
instance-id: ${FC_HOSTNAME}
local-hostname: ${FC_HOSTNAME}
EOF

fccurl PUT "mmds" "$(cat "$tmpdir/meta.yaml")"

# Add user-data to metadata service
fccurl PATCH "mmds" \
  "$(cat user-data.yaml | jq --raw-input --slurp '{ "latest": { "user-data": . }}')"

# Start the VM
fccurl PUT "actions" "$(jo action_type=InstanceStart)"

rm -rf "$tmpdir"
while ! cat ./dnsmasq.leases | grep "$TAP_IFACE_MAIN_MAC"; do sleep 0.5s; done

ip=$(cat dnsmasq.leases | grep "$TAP_IFACE_MAIN_MAC" | cut -d" " -f3)
_info "Connect with ssh ubuntu@$ip"