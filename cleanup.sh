#!/usr/bin/env bash
set -euo pipefail
# Enable command logging if TRACE variable is set
[[ -z "${TRACE:-}" ]] || set -x
# Helper methods for pretty output
_info() { echo -e "\e[92m[INFO] ${1:-}\e[0m"; }

# Kill any dnsmasq processes started by the script
if [[ -e "$XDG_RUNTIME_DIR/firecracker/dnsmasq/pid" ]]; then
    pid="$(cat $XDG_RUNTIME_DIR/firecracker/dnsmasq/pid)"
    if [[ -d "/proc/${pid}" ]]; then
        sudo kill -9 "$pid"
        _info "Killed: dnsmasq (PID $pid)"
    fi
fi

# Kill each of the firecracker processes that are started
for d in "$(ls $PWD/vm)"; do
    pid="$(cat $XDG_RUNTIME_DIR/firecracker/${d}/firecracker.pid)"
    if [[ -d "/proc/${pid}" ]]; then
        sudo kill -9 "$pid"
        _info "Killed: firecracker (PID $pid)"
    fi
done

# If the PURGE variable is set, kill *all* firecracker processes
[[ -n "${PURGE:-}" ]] && sudo killall firecracker

# Clean up network interfaces that are created by the script
for iface in $(\ip --brief link | grep -Po "fctap0[^ ]+|fcbr[^ ]+"); do 
    sudo ip l del $iface;
    _info "Deleted interface: $iface"
done;

# Directories to delete
directories=("$(pwd)/vm" "$XDG_RUNTIME_DIR/firecracker")

# If the PURGE variable is set, then delete downloaded images too
[[ -n "${PURGE:-}" ]] && directories+=("$(pwd)/images")

for d in ${directories[@]}; do
    if [[ -d "$d" ]]; then
        rm -rf "$d"
        _info "Deleted directory: $d"
    fi
done

_info "Done"