FROM ubuntu:22.04

ENV DEBIAN_FRONTEND noninteractive
ENV KERNEL_SOURCE_VERSION 5.15.0

WORKDIR /root

RUN apt-get update && \
    apt-get install -y \
        bc \
        bison \
        build-essential \
        cpio \
        debootstrap \
        fakeroot \
        flex \
        kmod \
        libelf-dev \
        libncurses5-dev \
        libssl-dev \
        linux-source-$KERNEL_SOURCE_VERSION \
        python3 \
        rsync \
        rsyslog \
        zstd

COPY script /opt/firecracker-builder

ENTRYPOINT [ "/opt/firecracker-builder/entrypoint.sh" ]
