# Ubuntu on Firecracker

The purpose of this project was to explore running Ubuntu with [Firecracker] as a general purpose
development machine. This is obviously not what Firecracker was developed for, but it was an
oppurtunity to learn a little about it!

At present, this project provides some basic automation for building a kernel image and rootfs that
firecracker can boot. 

I took a lot of influence from [ubuntu-firecracker](https://github.com/bkleiner/ubuntu-firecracker) by [@bkleiner](https://github.com/bkleiner) in the making of this project.

## Prerequisites

Before you can use or test this project, you'll need the following installed on your machine:

- [docker](https://docs.docker.com/desktop/install/linux-install/)
- [firecracker](https://github.com/firecracker-microvm/firecracker)
- [firectl](https://github.com/firecracker-microvm/firectl)

## Limitations and Caveats

This project is heavily tailored to my own use currently. In particular, the rootfs will contain my
SSH key by default! You can change that in `./script/provision.sh`. In a future update, I'm aiming
to enable `cloud-init` support for the VMs and will remove this!

## Getting Started

You can get going with the project in easy mode by just running `./demo.sh`. If you'd like to know
what's going on in the background, read on...

### Building the project

```bash
# Clone the repository
git clone https://github.com/jnsgruk/firecracker-ubuntu
cd firecracker-ubuntu

# (Optional) Build the builder container image
# If you omit this step the image will be pulled from Docker Hub
make oci

# Build a kernel image
make kernel

# Build a rootfs
make rootfs
```

### Start a VM

1. Create a folder for your VM kernel and disk image and copy some artefacts from the build process
   into it

```bash
mkdir -p vm
# Dopy image and kernel
cp build/dist/vmlinux build/dist/image.ext4 vm/
```

2.(Optional) Resize the disk image so that there is some space on the rootfs for you to install
packages, store files, etc.

```bash
# Resize image to 20G
truncate -s 20G vm/disk.ext4
resize2fs vm/disk.ext4
```

3. Create a `tap` interface for the VMs network interface:

```bash
# This will be the name of the firecracker tap interface
TAP_IFACE="fc-tap0"
# Change this to the name of your default network interface:
DEVICE_NAME="enp39s0" 

sudo ip addr add 172.20.0.1/24 dev "$TAP_IFACE"
sudo ip link set "$TAP_IFACE" up
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -t nat -A POSTROUTING -o "$DEVICE_NAME" -j MASQUERADE
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$TAP_IFACE" -o "$DEVICE_NAME" -j ACCEPT
```

4. Start the VM. In this case we start with 8 cores and 16GB RAM:

```bash
firectl \
    --ncpus "$CPUS" \
    --memory "$MEMORY" \
    --kernel="vm/vmlinux" \
    --root-drive="vm/disk.ext4" \
    --tap-device="$TAP_IFACE/$(cat /sys/class/net/$TAP_IFACE/address)" \
    --kernel-opts="init=/bin/systemd noapic reboot=k panic=1 pc
```

5. Enjoy your new VM! Take a look around...

## Kernel Configurations

Included with this repo are two kernel config files:

- [kernel-config-minimal](./config/kernel-config-minimal)
- [kernel-config-jammy-modified](./config/kernel-config-jammy-modified)

The former is a very minimal config that has just the features I needed for testing out running
LXD, [MicroK8s] and [Juju].

The latter was created by pulling the kernel config from the latest Ubuntu 22.04 cloud image and
making some minor modifications so that it would boot in this setup, so is more representative of a
"proper" Ubuntu kernel.

There is a symlink at `./config/kernel-config` that points to the minimal version by default. To
build the Ubuntu kernel, just remove the symlink and recreate it to point to the kernel config you
wish to use.

You can also use the OCI image to run `make menuconfig` to customise a config:

```bash
docker run \
    --rm \
    -v $(pwd)/build:/build \
    -v $(pwd)/config:/config \
    --entrypoint /bin/bash \
    -it jnsgruk/firecracker-builder

cd /build/kernel/linux-source-5.15.0/
# Run menuconfig, make any changes you need to
make menuconfig
# Copy the updated config into location in the config directory
cp /build/kernel/linux-source-5.15.0/.config /config/kernel-config

# Now exit the container and run the kernel build to use the new config
```

## TODO

- [ ] Figure out how to run DHCP on the tap interface
- [ ] Enable cloud-init support
- [ ] Add support for customising kernel and rootfs build
- [ ] Wrap firectl to run VMs in the background

[Firecracker]: https://firecracker-microvm.github.io/
[MicroK8s]: https://microk8s.io
[Juju]: https://juju.is