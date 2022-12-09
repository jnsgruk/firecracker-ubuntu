#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${DEBUG:-}" ]]; then
    set -x
fi

if [[ ! -d /build ]]; then
    echo "Directory /build should be bind-mounted!"
    exit 1
fi

if [[ ! -f /config/kernel-config ]]; then
    echo "Path /config/kernel-config does not exist; should be bind mounted!"
    exit 1
fi

# Cleanup existing kernel builds
rm -rf /build/kernel
mkdir -p /build/{kernel,dist}
cd /build/kernel

# Extract the linux kernel source if it hasn't been already
if [[ ! -d "linux-source-$KERNEL_SOURCE_VERSION" ]]; then
    tar xvf /usr/src/linux-source-"$KERNEL_SOURCE_VERSION".tar.bz2
fi

# Copy the specific kernel config into place
cd "/build/kernel/linux-source-$KERNEL_SOURCE_VERSION"
cp /config/kernel-config .config

# Build the kernel
yes "" | make oldconfig || true
make -j "$(nproc)" deb-pkg

# Copy the built kernel image into the dist folder
cp "/build/kernel/linux-source-$KERNEL_SOURCE_VERSION/vmlinux" /build/dist/vmlinux