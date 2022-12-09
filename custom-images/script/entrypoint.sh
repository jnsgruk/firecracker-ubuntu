#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${DEBUG:-}" ]]; then
    set -x
fi

action="${1:-}"

usage() {
    echo "Firecracker Ubuntu Builder by @jnsgruk"
    echo 
    echo "Please specify either 'kernel' or 'rootfs'"
}

if [[ -z "$action" ]]; then
    usage
    exit 1
fi

if [[ "$1" == "kernel" ]]; then
    /opt/firecracker-builder/build-kernel.sh
elif [[ "$1" == "rootfs" ]]; then
    /opt/firecracker-builder/build-rootfs.sh
else
    usage
    exit 1
fi
