#!/bin/bash
set -euo pipefail
if [[ -n "${DEBUG:-}" ]]; then
    set -x
fi

dpkg -i /mnt/root/linux*.deb

# TODO: remove this when cloud-init is working
echo "ubuntu" > /etc/hostname

# This essentially makes root passwordless - seems like a bad idea ;-)
# TODO: Change this once cloud-init provisioning works
passwd -d root

# TODO: Remove the autologin once cloud-init provisioning is working
mkdir /etc/systemd/system/serial-getty@ttyS0.service.d/
cat <<EOF > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root -o '-p -- \\u' --keep-baud 115200,38400,9600 %I xterm-256color
EOF

# Configure networking using netplan.
# TODO: Work out how to setup dhcp on the tap interface and simplify this
cat <<EOF > /etc/netplan/99_config.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - 172.20.0.2/24
      routes:
        - to: default
          via: 172.20.0.1
      nameservers:
        addresses:
          - 1.1.1.1
EOF

netplan generate

# Configure subgid/subuid for LXD
cat <<EOF > /etc/subuid
lxd:1000000:65536
root:1000000:65536
EOF
cp /etc/subuid /etc/subgid

# Add the alacritty terminfo profile
# TODO: Remove this when cloud-init provisioning is working
wget -q https://raw.githubusercontent.com/alacritty/alacritty/master/extra/alacritty.info
tic -xe alacritty,alacritty-direct ./alacritty.info
rm alacritty.info

# Create the ubuntu user
useradd -m -s /bin/bash ubuntu
mkdir -p /home/ubuntu/.ssh
# TODO: Remove this when cloud-init provisioning is working
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnd4bqCUEzrVkQBTVbQOKVBozJ2ZNJUFvWJFhLc7cST jnsgruk" >> /home/ubuntu/.ssh/authorized_keys

# Setup NOPASSWD sudo access for the ubuntu user
cat <<EOF > /etc/sudoers.d/99-ubuntu-user
# User rules for ubuntu
ubuntu ALL=(ALL) NOPASSWD:ALL
EOF
