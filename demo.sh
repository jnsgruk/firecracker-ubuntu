#!/usr/bin/env bash
set -euo pipefail
# Enable command logging if TRACE variable is set
[[ -z "${TRACE:-}" ]] || set -x
# Helper methods for pretty output
_info() { echo -e "\e[92m[INFO]\t${1:-}\e[0m"; }
_warn() { echo -e "\e[33m[WARN]\t${1:-}\e[0m"; }
_error() { echo -e >&2 "\e[31m[ERROR]\t${1:-}\e[0m"; exit 1; }
_debug() { if [[ -n "${DEBUG:-}" ]]; then echo -e >&2 "[DEBG]\t${1:-}"; fi; }

# shellcheck source=default.conf
source "${FC_CONFIG:-default.conf}"

# Directories for the operation of this script
SERIES_DIR="$(pwd)/images/${FC_SERIES}"
DOWNLOAD_DIR="${SERIES_DIR}/downloads"
RUNTIME_DIR="${XDG_RUNTIME_DIR}/firecracker"
RUNTIME_VM_DIR="${RUNTIME_DIR}/${FC_HOSTNAME}"
VM_DIR="$(pwd)/vm/${FC_HOSTNAME}"

# Configuration files
USERDATA_FILE="$(pwd)/userdata.yaml"

# Filenames for cloud image artefacts
CI_ROOTFS_FILE="${FC_SERIES}-server-cloudimg-amd64-root.tar.xz"
CI_KERNEL_FILE="${FC_SERIES}-server-cloudimg-amd64-vmlinuz-generic"
CI_INITRD_FILE="${FC_SERIES}-server-cloudimg-amd64-initrd-generic"

# Filenames for other artefacts
SERIES_ROOTFS_FILE="${SERIES_DIR}/rootfs.${FC_SERIES}"
SERIES_KERNEL_FILE="${SERIES_DIR}/kernel.${FC_SERIES}"
SERIES_INITRD_FILE="${SERIES_DIR}/initrd.${FC_SERIES}"

# Filenames for VM artefacts
VM_ROOTFS_FILE="${VM_DIR}/disk.ext4"
VM_KERNEL_FILE="${VM_DIR}/vmlinux"
VM_INITRD_FILE="${VM_DIR}/initrd"

# Network interfaces for VM
TAP_IFACE_MAIN=""
TAP_IFACE_META=""
TAP_IFACE_META_MAC=""
TAP_IFACE_MAIN_MAC=""

# Filenames for firecracker
FIRECRACKER_SOCKET="${RUNTIME_VM_DIR}/firecracker.socket"
FIRECRACKER_LOG="${RUNTIME_VM_DIR}/firecracker.log"
FIRECRACKER_CONSOLE_LOG="${RUNTIME_VM_DIR}/firecracker.console.log"
FIRECRACKER_PID="${RUNTIME_VM_DIR}/firecracker.pid"

read -r -d '' USERDATA_TEMPLATE <<-EOF || true
#cloud-config
users:
  - name: ubuntu
    shell: /bin/bash
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - __KEY__
EOF

# Helper method for downloading a file to a location on disk
_download() {
	if [[ -f "$2" ]]; then
		_debug "File ${2} already exists; skipping download"
	else
		_info "Downloading: $1"
		curl -fsSL -o "$2" "$1"
		_debug "Downloaded ${1} to ${2}"
	fi
}

# Helper method for making a request to the firecracker API
_firecracker_api_call() {
	local method endpoint data
	method="$1"
	endpoint="$2"
	data="$3"

	curl --unix-socket "$FIRECRACKER_SOCKET" \
		-H "Accept: application/json" \
		-H "Content-Type: application/json" \
		-X "$method" "http://localhost/$endpoint" \
		-d "$data"
	
	_debug "Firecracker API request complete: $method $endpoint:\n$data"
}

check_dependencies() {
	# Ensure we have all the dependenices we need to run this demo
	deps=(firecracker yq jq dnsmasq)
	for d in "${deps[@]}"; do
		if ! command -v "$d" >/dev/null; then 
			_error "Could not find '$d' in \$PATH"
		fi
	done
}

fetch_cloud_image_artefacts() {
	# This function handles downloading the relevant kernel, initrd and rootfs
	mkdir -p "$DOWNLOAD_DIR"
	local base_url
	base_url="https://cloud-images.ubuntu.com/${FC_SERIES}/current"

	# Download the rootfs if it doesn't exist
	_download "${base_url}/${CI_ROOTFS_FILE}" "${DOWNLOAD_DIR}/${CI_ROOTFS_FILE}"
	# Download the kernel if it doesn't exist
	_download "${base_url}/unpacked/${CI_KERNEL_FILE}" "${DOWNLOAD_DIR}/${CI_KERNEL_FILE}"
	# Download the initrd if it doesn't exist
	_download "${base_url}/unpacked/${CI_INITRD_FILE}" "${DOWNLOAD_DIR}/${CI_INITRD_FILE}"
}

process_cloud_image_artefacts() {
	local tmpdir sdnd_override_dir
	# Check the disk image we generate is there; if not generate it
	if [[ ! -f "${SERIES_ROOTFS_FILE}" ]]; then
		_info "Generating disk image for series '${FC_SERIES}'"
		
		# Create a new rootfs file
		truncate -s "2G" "$SERIES_ROOTFS_FILE"
		# Create an ext4 filesystem from our rootfs file
		mkfs.ext4 "$SERIES_ROOTFS_FILE" -L "cloudimg-rootfs" > /dev/null 2>&1
		# Mount the new disk image to a temporary directory
		tmpdir="$(mktemp -d)"
		sudo mount "$SERIES_ROOTFS_FILE" -o loop "$tmpdir"
		# Extract the dowloaded disk image into the new disk image
		sudo tar -C "$tmpdir" -xf "${DOWNLOAD_DIR}/${CI_ROOTFS_FILE}"
		
		# Creating this override file stops systemd-netword-wait-online from waiting for the metadata
		# interface to be online, causing the boot to wait for long periods
		sdnd_override_dir="${tmpdir}/etc/systemd/system/systemd-networkd-wait-online.service.d"
		sudo mkdir -p "$sdnd_override_dir"
		cat <<-EOF | sudo tee "$sdnd_override_dir/override.conf" >/dev/null
				[Service]
				ExecStart=
				ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any
				EOF
		
		# Unmount and cleanup the tmpdir
		sudo umount "$tmpdir"
		rm -rf "$tmpdir"
	else
		_debug "File ${SERIES_ROOTFS_FILE} already exists; skipping generation"
	fi

	# Extract the vmlinux from the kernel image
	if [[ ! -f "${SERIES_KERNEL_FILE}" ]]; then
		_info "Extracting kernel image for series '${FC_SERIES}'"
		tmpdir="$(mktemp -d)"
		_debug "Downloading extract-vmlinux script from Github"
		_download "https://raw.githubusercontent.com/torvalds/linux/master/scripts/extract-vmlinux" "${tmpdir}/extract-vmlinux"
		bash "${tmpdir}/extract-vmlinux" "${DOWNLOAD_DIR}/${CI_KERNEL_FILE}" > "${SERIES_KERNEL_FILE}"
		rm -rf "$tmpdir"
	else
		_debug "File ${SERIES_KERNEL_FILE} already exists; skipping generation"
	fi

	# Copy the initrd into the series folder
	if [[ ! -f "${SERIES_INITRD_FILE}" ]]; then
		_info "Copying initrd file for'${FC_SERIES}'"
		cp "${DOWNLOAD_DIR}/${CI_INITRD_FILE}" "${SERIES_INITRD_FILE}"
	else
		_debug "File ${SERIES_INITRD_FILE} already exists; skipping copy"
	fi
}

setup_network_bridge() {
	local default_interface
	# Get the device name of the default gateway on the host
	default_interface="$(\ip route get 1.1.1.1 | grep uid | sed "s/.* dev \([^ ]*\) .*/\1/")"

	# If there is no bridge interface, create one
	if ! ip l | grep -q "$FC_BRIDGE_IFACE"; then
		# Create the interface, give it an address and bring it up
		sudo ip link add name "$FC_BRIDGE_IFACE" type bridge
		sudo ip addr add 172.20.0.1/24 dev "$FC_BRIDGE_IFACE"
		sudo ip link set "$FC_BRIDGE_IFACE" up
		# Setup the iptables and packet forwarding rules
		sudo sysctl -w net.ipv4.ip_forward=1 &> /dev/null
		sudo iptables -t nat -A POSTROUTING -o "$default_interface" -j MASQUERADE
		sudo iptables -I FORWARD -i "$FC_BRIDGE_IFACE" -j ACCEPT
		sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
		_info "Created bridge interface ${FC_BRIDGE_IFACE}"
	else
		_debug "Bridge interface ${FC_BRIDGE_IFACE} already exists"
	fi
}

start_dnsmasq() {
	local dnsmasq_dir dnsmasq_pid
	dnsmasq_dir="${RUNTIME_DIR}/dnsmasq"
	mkdir -p "${dnsmasq_dir}"

	# Check if there is already a PID file for dnsmasq
	if [[ -f "${dnsmasq_dir}/dnsmasq.pid" ]]; then
		dnsmasq_pid="$(cat "${dnsmasq_dir}/dnsmasq.pid")"
		# If the PID exists in /proc, assume dnsmasq is running okay and just return
		if [[ -d "/proc/${dnsmasq_pid}" ]]; then
			_debug "Found existing dnsmasq process; PID ${dnsmasq_pid}"
			return
		fi
	fi

	# Start dnsmasq for DHCP on the bridge
	sudo dnsmasq \
		--strict-order \
		--bind-interfaces \
		--log-facility="${dnsmasq_dir}/dnsmasq.log" \
		--pid-file="${dnsmasq_dir}/dnsmasq.pid" \
		--dhcp-leasefile="${dnsmasq_dir}/dnsmasq.leases" \
		--domain="firecracker" \
		--local="/firecracker/" \
		--except-interface="lo" \
		--interface="$FC_BRIDGE_IFACE" \
		--listen-address="172.20.0.1" \
		--dhcp-no-override \
		--dhcp-authoritative \
		--dhcp-range "172.20.0.2,172.20.0.100,infinite"
	
	dnsmasq_pid="$(cat "${dnsmasq_dir}/dnsmasq.pid")"
	_info "Started dnsmasq; PID ${dnsmasq_pid}; log "${dnsmasq_dir}/dnsmasq.log""
}

create_vm() {
	_info "Creating virtual machine"
	mkdir -p "$VM_DIR"

	if [[ ! -f "$VM_ROOTFS_FILE" ]]; then
		_debug "Creating and resizing disk image: '${VM_ROOTFS_FILE}' to '${FC_DISK}'"
		# If there is no vm directory, create one and move the built kernel image and rootfs
		# into the directory before we try to boot it
		# Copy the series rootfs into the VM directory
		cp "$SERIES_ROOTFS_FILE" "$VM_ROOTFS_FILE"
		# Resize image to specified size
		truncate -s "$FC_DISK" "$VM_ROOTFS_FILE"
		resize2fs "$VM_ROOTFS_FILE" >/dev/null 2>&1 || e2fsck -fpy "$VM_ROOTFS_FILE" >/dev/null 2>&1
	else
		_debug "VM disk image '$VM_ROOTFS_FILE' already exists; skipping creation"
	fi

	# Create symlinks for the kernel and initrd files
	if [[ ! -e "$VM_KERNEL_FILE" ]]; then
			_debug "Symlinking kernel '${SERIES_KERNEL_FILE}' to '${VM_KERNEL_FILE}'"
		 ln -s "$SERIES_KERNEL_FILE" "$VM_KERNEL_FILE"
	else
		_debug "VM kernel symlink '$VM_KERNEL_FILE' already exists; skipping creation"
	fi

	if [[ ! -e "$VM_INITRD_FILE" ]]; then
		_debug "Symlinking initrd '${SERIES_INITRD_FILE}' to '${VM_INITRD_FILE}'"
		ln -s "$SERIES_INITRD_FILE" "$VM_INITRD_FILE"
	else
		_debug "VM initrd symlink '$VM_KERNEL_FILE' already exists; skipping creation"
	fi

	_info "Creating network interfaces for virtual machine"
	# Generate a name for the tap interfaces
	TAP_IFACE_MAIN="fctap0$(openssl rand -hex 2)"
	TAP_IFACE_META="fctap0$(openssl rand -hex 2)"

	# Create the main network interface for the VM
	if ! ip l | grep -q "$TAP_IFACE_MAIN"; then
		sudo ip tuntap add dev "$TAP_IFACE_MAIN" mode tap 
		TAP_IFACE_MAIN_MAC="$(cat "/sys/class/net/${TAP_IFACE_MAIN}/address")"
		_info "Created tap interface '${TAP_IFACE_MAIN}' with MAC '${TAP_IFACE_MAIN_MAC}'"
		
		sudo ip link set "$TAP_IFACE_MAIN" up
		_debug "Set interface '$TAP_IFACE_MAIN' up"
		
		sudo ip link set "$TAP_IFACE_MAIN" master "$FC_BRIDGE_IFACE"
		_info "Added tap interface '${TAP_IFACE_MAIN}' to bridge '${FC_BRIDGE_IFACE}'"
	fi

	# Create a network interface for the MMDS
	if ! ip l | grep -q "$TAP_IFACE_META"; then
		sudo ip tuntap add dev "$TAP_IFACE_META" mode tap
		TAP_IFACE_META_MAC="$(cat "/sys/class/net/${TAP_IFACE_META}/address")"
		_info "Created tap interface '${TAP_IFACE_META}' with MAC '${TAP_IFACE_META_MAC}'"
		
		sudo ip link set "$TAP_IFACE_META" up
		_debug "Set interface '$TAP_IFACE_META' up"
	fi

	cat <<-EOF | jq > "$VM_DIR/vm.json"
	{
		"name": "$FC_HOSTNAME",
		"specs": {
			"vcpu_count": $FC_CPUS,
			"mem_size_mib": $FC_MEMORY
		},
		"interfaces": [
			{
				"iface_id": "eth0",
				"host_dev_name": "$TAP_IFACE_META",
				"guest_mac": "$TAP_IFACE_META_MAC"
			},
			{
				"iface_id": "eth1",
				"host_dev_name": "$TAP_IFACE_MAIN",
				"guest_mac": "$TAP_IFACE_MAIN_MAC"
			}
		],
		"boot_sources": {
			"kernel_image_path": "$VM_KERNEL_FILE",
			"initrd_path": "$VM_INITRD_FILE"
		},
		"disks": {
			"rootfs": {
				"drive_id": "rootfs",
				"path_on_host": "$VM_ROOTFS_FILE",
				"is_root_device": true,
				"is_read_only": false
			}
		}
	}
	EOF

	_debug "Virtual machine created with config: \n$(cat "${VM_DIR}/vm.json" | jq)"
}

start_firecracker() {
	local pid
	_info "Starting firecracker"
	mkdir -p "${RUNTIME_VM_DIR}"
	touch "$FIRECRACKER_LOG"
	rm -f "$FIRECRACKER_SOCKET"

	# Start firecracker
	firecracker \
		--api-sock "$FIRECRACKER_SOCKET" \
		--log-path "$FIRECRACKER_LOG" \
		--level "Debug" &> "$FIRECRACKER_CONSOLE_LOG" &
	
	pid="$!"
	echo "$pid" > "${FIRECRACKER_PID}"

	# Wait for API server to start
	while [[ ! -e "$FIRECRACKER_SOCKET" ]]; do sleep 0.1s; done
	_info "Started firecracker; PID $pid; log ${FIRECRACKER_LOG}"
}

configure_vm() {
	local vconf netconfig metadata cmdline data
	vconf="$VM_DIR/vm.json"
	
	# Setup the machine CPU/Memory
	_firecracker_api_call PUT "machine-config" "$(jq .specs "$vconf")"

	# Setup the root filesystem drive
	_firecracker_api_call PUT "drives/rootfs" "$(jq .disks.rootfs "$vconf")"

	# Setup the eth0 interface - this is for the MMDS
	data="$(jq '.interfaces[] | select(.iface_id=="eth0")' "$vconf")"
	_firecracker_api_call PUT "network-interfaces/eth0" "$data"

	# Setup the eth1 interface - this will be the main network interface for the vm
	data="$(jq '.interfaces[] | select(.iface_id=="eth1")' "$vconf")"
	_firecracker_api_call PUT "network-interfaces/eth1" "$data"

	# Set the interface for the MMDS
	_firecracker_api_call PUT "mmds/config" '{"network_interfaces": ["eth0"]}'

	# Configure the boot source
	read -r -d '' netconfig <<-EOF || true
	{
		"version": 2,
		"ethernets": {
			"eth0": {
				"match": {
					"macaddress": "$(jq -r '.interfaces[]|select(.iface_id=="eth0")|.guest_mac' "$vconf")"
				},
				"addresses": ["169.254.0.1/16"]
			},
			"eth1": {
				"match": {
					"macaddress": "$(jq -r '.interfaces[]|select(.iface_id=="eth1")|.guest_mac' "$vconf")"
				},
				"dhcp4": true
			}
		}
	}
	EOF
	
	cmdline="reboot=k panic=1 pci=off console=ttyS0"
	# Add the nocloud datasource for cloud-init to the kernel command line
	cmdline="${cmdline} ds=nocloud-net;s=http://169.254.169.254/latest/"
	# Add the network-config to the kernel command line (gzipped and base64 encoded)
	cmdline="${cmdline} network-config=$(echo $netconfig | yq -P . | gzip -c - | base64 -w0)"

	# Send the boot sources to the firecracker API
	data="$(jq --arg c "$cmdline" '.boot_sources + {"boot_args": $c}' "$vconf")"
	_firecracker_api_call PUT "boot-source" "$data"

	# Set some metadata on the MMDS
	read -r -d '' metadata <<-EOF || true
	{
		"local-hostname": "${FC_HOSTNAME}"
	}
	EOF

	data="$(echo "$metadata" | yq -P . | jq --raw-input --slurp '{ "latest": { "meta-data": . }}')"
	_firecracker_api_call PUT "mmds" "$data"

	# If there is a provided userdata file, then use it; otherwise generate one
	if [[ -f "$USERDATA_FILE" ]]; then
		data="$(cat "$USERDATA_FILE" | jq --raw-input --slurp '{ "latest": { "user-data": . }}')"
		_firecracker_api_call PATCH "mmds" "$data"
	else
		_info "Generating an SSH key for the VM"
		# Generate an ssh-key for use with the VM
		ssh-keygen -t ed25519 -q -N "ubuntu@${FC_HOSTNAME}" -f "${VM_DIR}/id_25519"
		# Update the userdata template with the new key
		userdata="$(echo "$USERDATA_TEMPLATE" | sed -e "s/__KEY__/$(cat "$VM_DIR/id_25519.pub")/g")"
		# Configure firecracker with the userdata
		data="$(echo "$userdata" | jq --raw-input --slurp '{ "latest": { "user-data": . }}')"
		_firecracker_api_call PATCH "mmds" "$data"
	fi

	# Start the VM
	_firecracker_api_call PUT "actions" "{\"action_type\": \"InstanceStart\"}"
}

main() {
	check_dependencies
	fetch_cloud_image_artefacts
	process_cloud_image_artefacts
	setup_network_bridge
	start_dnsmasq
	create_vm
	start_firecracker
	configure_vm
}

main