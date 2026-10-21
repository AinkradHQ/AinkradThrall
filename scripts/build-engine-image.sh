#!/bin/sh
# Builds the guest image Thrall's own engine boots: a raw arm64 kernel, an
# initramfs and an ext4 root filesystem carrying dockerd, containerd and socat.
#
#   scripts/build-engine-image.sh [OUT_DIR]     (default: build/engine-image)
#
# Writes Image, initramfs, rootfs.img and manifest.json (SHA-256 of each),
# plus thrall-engine-image.tar.gz, the release asset the plugin downloads.
# bsdtar keeps rootfs.img sparse both ways: 2 GiB apparent, ~300 MB on disk.
#
# Build-time only: it needs a Docker engine to run an arm64 Alpine container,
# which is where apk, mkinitfs and mke2fs live. The image it produces is what
# lets a Mac WITHOUT any engine run containers; the build machine is not that
# Mac.
#
# Why a raw `Image` and not Alpine's `vmlinuz-virt`: on aarch64 that file is an
# EFI zboot wrapper (PE header + gzip payload), and VZLinuxBootLoader only
# boots the raw arm64 Image. The payload offset and size sit at bytes 8 and 12
# of the zboot header, so unwrapping is one dd + gunzip.
set -eu

ALPINE=3.22
OUT=${1:-build/engine-image}
ROOTFS_SIZE=2G
PACKAGES="alpine-base linux-virt docker docker-openrc socat e2fsprogs"

command -v docker >/dev/null || { echo "build-engine-image: needs docker to build" >&2; exit 1; }
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)

docker run --rm --platform linux/arm64 \
  -v "$OUT:/out" -v "$HERE/engine-image:/overlay:ro" \
  -e ROOTFS_SIZE="$ROOTFS_SIZE" -e PACKAGES="$PACKAGES" \
  "alpine:$ALPINE" sh -euc '
apk add -q mkinitfs e2fsprogs >/dev/null
R=/rootfs
mkdir -p $R/etc/apk
cp -r /etc/apk/keys $R/etc/apk/
cp /etc/apk/repositories $R/etc/apk/
apk add -q --root $R --initdb $PACKAGES >/dev/null

cp -r /overlay/. $R/
chmod 755 $R/etc/init.d/thrall-data $R/etc/init.d/thrall-socket $R/etc/init.d/thrall-power $R/etc/init.d/thrall-home
echo thrall > $R/etc/hostname
echo "hvc0::respawn:/sbin/getty -L 0 hvc0 vt100" >> $R/etc/inittab

chroot $R sh -c "
  for s in devfs dmesg mdev hwdrivers; do rc-update -q add \$s sysinit; done
  for s in modules sysctl hostname bootmisc syslog cgroups; do rc-update -q add \$s boot; done
  for s in networking thrall-data thrall-home docker thrall-socket thrall-power; do rc-update -q add \$s default; done
  for s in mount-ro killprocs savecache; do rc-update -q add \$s shutdown; done
"

KVER=$(ls $R/lib/modules)
mkinitfs -q -b $R -F "base virtio ext4" -o /out/initramfs "$KVER"

Z=$R/boot/vmlinuz-virt
OFF=$(od -An -tu4 -j8 -N4 $Z | tr -d " ")
LEN=$(od -An -tu4 -j12 -N4 $Z | tr -d " ")
dd if=$Z bs=1 skip=$OFF count=$LEN status=none | gunzip > /out/Image

rm -rf $R/boot/* $R/var/cache/apk/*
rm -f /out/rootfs.img
mke2fs -q -t ext4 -L thrall-root -d $R /out/rootfs.img $ROOTFS_SIZE
echo "$KVER" > /out/kernel-version
'

cd "$OUT"
{
  printf '{\n  "alpine": "%s",\n  "kernel": "%s",\n  "files": {\n' "$ALPINE" "$(cat kernel-version)"
  sep=""
  for f in Image initramfs rootfs.img; do
    printf '%s    "%s": "%s"' "$sep" "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"
    sep=",
"
  done
  printf '\n  }\n}\n'
} > manifest.json
rm kernel-version
tar -czf thrall-engine-image.tar.gz Image initramfs rootfs.img manifest.json
echo "build-engine-image: wrote $OUT"
shasum -a 256 thrall-engine-image.tar.gz
