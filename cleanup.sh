#!/usr/bin/env bash
set -euo pipefail
# Enable command logging if TRACE variable is set
[[ -z "${TRACE:-}" ]] || set -x
# Helper methods for pretty output
_info() { echo -e "\e[92m[INFO] ${1:-}\e[0m"; }

if [[ -e "$XDG_RUNTIME_DIR/firecracker/dnsmasq/pid" ]]; then
    pid="$(cat $XDG_RUNTIME_DIR/firecracker/dnsmasq/pid)"
    if [[ -d "/proc/${pid}" ]]; then
        sudo kill -9 "$pid"
        _info "Killed: dnsmasq (PID $pid)"
    fi
fi

for iface in $(\ip --brief link | grep -Po "fctap0[^ ]+|fcbr[^ ]+"); do 
    sudo ip l del $iface;
    _info "Deleted interface: $iface"
done;

directories=(
    # "$(pwd)/images"
    "$(pwd)/vm"
    "$XDG_RUNTIME_DIR/firecracker"
)

for d in ${directories[@]}; do
    if [[ -d "$d" ]]; then
        rm -rf "$d"
        _info "Deleted directory: $d"
    fi
done

_info "Done"