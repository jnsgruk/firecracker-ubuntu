# Using Firecracker with custom images

This directory contains automation and instructions if you wish to build your own kernel and rootfs
for use with Firecracker. It is representative of a much more "bare-bones" and simple setup, and
was used during the development of the more advanced automation now at the root of this project.

## Quick start

In addition to [firecracker], you'll also need [firectl] installed for this.

There is a script included that will use the built kernel and rootfs to boot a simple, statically
addressed VM using `firectl`. It will automatically make any of the components it needs to using
the included Makefile.

To use it, run `./start-custom.sh`

## Building components

If you need to rebuild any of the individual components, you can use the included Makefile:

```
# Clone the repository
git clone https://github.com/jnsgruk/firecracker-ubuntu
cd firecracker-ubuntu/custom-images

# (Optional) Build the builder container image
# If you omit this step the image will be pulled from Docker Hub
make oci

# Build a kernel image
make kernel

# Build a rootfs
make rootfs
```

## Kernel configurations

Included with this repo are two kernel config files:

- [kernel-config-minimal]
- [kernel-config-jammy-modified]

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

[firecracker]: https://github.com/firecracker-microvm/firecracker
[firectl]: https://github.com/firecracker-microvm/firectl
[kernel-config-minimal]: ./config/kernel-config-minimal
[kernel-config-jammy-modified]: ./config/kernel-config-jammy-modified
