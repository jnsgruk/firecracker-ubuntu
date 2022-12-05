# This is a *very* trivial Makefile with almost no smarts in it at all.

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
mkfile_dir := $(dir $(mkfile_path))

oci:
	docker build \
		-t jnsgruk/firecracker-builder \
		-f $(mkfile_dir)/builder-image/Dockerfile \
		./builder-image

kernel:
	mkdir -p $(mkfile_dir)/build
	docker run \
		--rm \
		-v $(mkfile_dir)/build:/build \
		-v $(mkfile_dir)/config:/config \
		jnsgruk/firecracker-builder kernel

rootfs:
	mkdir -p $(mkfile_dir)/build
	docker run \
		--rm \
		--privileged \
		-v $(mkfile_dir)/build:/build \
		-v $(mkfile_dir)/config:/config \
		jnsgruk/firecracker-builder rootfs

all: oci kernel rootfs

clean:
	sudo rm -rf $(mkfile_dir)/build
