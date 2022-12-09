# Ubuntu on Firecracker

The purpose of this project was to explore running Ubuntu with [Firecracker] as a general purpose
development machine. This is obviously not what Firecracker was developed for, but it was an
opportunity to learn a little about it!

At present, this project can download and start Ubuntu cloud images using firecracker, with support
for supplying a cloud-init file to customise the virtual machine. It relies upon [dnsmasq] to
dynamically address the VM it creates.

I took a lot of influence from [ubuntu-firecracker] by [@bkleiner], and this [blog] from
[@ahachete] in the making of this project.

Using this approach, I was able to deploy the [Canonical Observability Stack] with [Juju] on
[MicroK8s] inside a Firecracker VM:

![COS Lite on MicroK8s on Firecracker](.github/images/screenshot.png)

## Prerequisites

Before you can use or test this project, you'll need the following installed on your machine:

- [dnsmasq]
- [firecracker]
- [jq]
- [yq]

## Quick start

You can start the project on a clean machine with `./demo.sh`. You might want to adjust the
[userdata.yaml] before starting it to ensure the right SSH key is present.

This will do the following:

- Download and process the relevant Ubuntu cloud image (according to `FC_SERIES`)
- Create a network bridge device
- Start `dnsmasq` on that bridge
- Create two tap network interfaces for the VM (one for the metadata service, one for normal use)
- Create a folder structure for a VM, containing kernel, disk, initrd and a definition file
- Start firecracker and configure the VM over it's HTTP API
- Start the VM

By default, the [config] looks like so:

```bash
# Some configuration for the VM
FC_CPUS="${FC_CPUS:-8}"
FC_MEMORY="${FC_MEMORY:-16386}" # 16GB
FC_DISK="${FC_DISK:-20G}"
FC_HOSTNAME="${FC_HOSTNAME:-dev}"

# Which series of Ubuntu to boot
FC_SERIES="${FC_SERIES:-jammy}"

# Name of the bridge interface
FC_BRIDGE_IFACE="fcbr0"
```

Once you've run `./demo.sh`, you'll get instructions on how to connect to your VM.

To cleanup your machine, run `./cleanup.sh`. Note that this will delete all downloaded artefacts,
kill started processes, remove any network interfaces and delete the VM.

## TODO

- [ ] Output an accurate message with connection instructions on boot
- [ ] Resume VM and make sure existing interfaces are present
- [ ] Multiple VM support
- [ ] Better command line arg experience

- [x] Figure out how to run DHCP on a tap interface
- [x] Enable the use of standard Ubuntu cloud images
- [x] Enable cloud-init support
- [x] Add support for customising kernel and rootfs build

[@ahachete]: https://twitter.com/ahachete/
[@bkleiner]: https://github.com/bkleiner
[blog]: https://ongres.com/blog/automation-to-run-vms-based-on-vanilla-cloud-images-on-firecracker/
[canonical observability stack]: https://charmhub.io/topics/canonical-observability-stack
[config]: ./default.conf
[dnsmasq]: https://thekelleys.org.uk/dnsmasq/doc.html
[docker]: https://docs.docker.com/desktop/install/linux-install/
[firecracker]: https://github.com/firecracker-microvm/firecracker
[jq]: https://stedolan.github.io/jq/
[juju]: https://juju.is
[microk8s]: https://microk8s.io
[ubuntu-firecracker]: https://github.com/bkleiner/ubuntu-firecracker
[userdata.yaml]: ./userdata.yaml
[yq]: https://mikefarah.gitbook.io/yq/
