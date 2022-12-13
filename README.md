# embr

The purpose of this project was to explore running Ubuntu with [Firecracker] as a general purpose
development machine. This is obviously not what Firecracker was developed for, but it was an
opportunity to learn a little about it!

At present, `embr` can download and start Ubuntu cloud images using firecracker, with support
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

You can start the project on a clean machine with `./embr launch`.

This will do the following:

- Download and process the relevant Ubuntu cloud image (latest LTS by default)
- Create a network bridge device
- Start `dnsmasq` on that bridge
- Create two tap network interfaces for the VM (one for the metadata service, one for normal use)
- Create a folder structure for a VM, containing kernel, disk, initrd and a definition file
- Start firecracker and configure the VM over it's HTTP API
- Start the VM

With no arguments, `embr` will create a VM with 8 CPUs, 16GB RAM and a 20GB disk.

Once you've run `./embr launch`, you'll get instructions on how to connect to your VM.

To cleanup your machine, run `./embr clean`. Note that this will, kill started processes, remove
any network interfaces and delete the VM.

## Customising your machine

The `embr launch` command takes a number of arguments such that you can customise the CPUS, memory,
disk and series that is used:

```
$ ./embr launch --help
embr is a tool for creating and launching Ubuntu virtual machines with Firecracker.

USAGE:
        embr launch [OPTIONS]

OPTIONS:
        -n, --name <name>
                Hostname of the virtual machine to create.
                Default: dev

        -c, --cpus <cpus>
                Number of virtual CPUs to assign to the VM
                Default: 8

        -m, --memory <mem>
                Amount of memory in GB to assign to the VM.
                Default: 16

        -d, --disk <disk>
                Size of disk for the VM in GB.
                Default: 20

        -f, --cloud-init <file>
                Filename of the cloud-init user data file to use for provisioning.
                Default: userdata.yaml

        -s, --series <series>
                The Ubuntu series codename to use. E.g. xenial, bionic, focal, jammy
                Default: jammy

        -h, --help
                Display this help message.
```

## TODO

- [ ] Resume VM and make sure existing interfaces are present
- [ ] Multiple VM support
  - [x] Store VMs in separate directories
  - [ ] Start / stop VMs independently
  - [ ] Status command to show running, IP, etc.
- [ ] Stop being a maniac and write this in Go

### Done

- [x] Better command line arg experience
- [x] Output an accurate message with connection instructions on boot
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
