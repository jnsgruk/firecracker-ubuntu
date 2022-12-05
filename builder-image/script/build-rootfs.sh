#!/bin/bash
set -euo pipefail
if [[ -n "${DEBUG:-}" ]]; then
    set -x
fi

if [[ ! -d /build ]]; then
    echo "Directory /build should be bind-mounted!"
    exit 1
fi

ROOTFS="/root/rootfs"
DIST="/build/dist"
RELEASE="jammy"

mkdir -p "$DIST" "$ROOTFS"

truncate -s 2G "$DIST/image.ext4"
mkfs.ext4 "$DIST/image.ext4"
mount "$DIST/image.ext4" "$ROOTFS"

package_list=(
    apparmor
    apt
    bridge-utils
    curl
    dbus-user-session
    dns-root-data
    dnsmasq-base
    dnsutils
    iptables
    libfuse2
    libip6tc2
    libnetfilter-conntrack3
    libnfnetlink0
    libnftnl11
    libpam-cgfs
    net-tools
    netplan.io
    openssh-server
    rsync
    snapd
    uidmap
    unzip
    vim
    wget
)

pkgs="$(IFS=, ; echo "${package_list[*]}")"
components="main,universe"

if ! debootstrap --components="$components" --include "$pkgs" "$RELEASE" "$ROOTFS" http://archive.ubuntu.com/ubuntu/; then
    # Try to catch errors when debootstrap fails and output the log
    cat "$ROOTFS/debootstrap/debootstrap.log"
    exit 1
fi

# Move the debs from the bind mounted build directory
# to somewhere in the container filesystem - without this
# they don't seem to be visible in the chroot
cp /build/kernel/linux*.deb /root

mount --bind / "$ROOTFS/mnt"
chroot "$ROOTFS" /bin/bash /mnt/opt/firecracker-builder/provision.sh

umount -R "$ROOTFS"
