#!/usr/bin/env bash
# build.sh <host> <source-dir> <prefix>
#
# Configures, builds and installs QEMU for one host:
#   darwin-arm64   native on macOS, with HVF
#   linux-amd64    native on Linux, with KVM
#   windows-amd64  cross-built with mingw-w64, with WHPX
# The configure arguments are written to <prefix>.configure, one per line,
# for the build manifest.
#
# Only what pvm runs is built: one system emulator and qemu-img, headless,
# with user networking, and virtio-9p where the host supports it. Features
# that would pull in more libraries are disabled explicitly, so a build never
# picks one up just because a library happened to be installed.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

host=${1:?usage: build.sh <host> <source-dir> <prefix>}
src=$(cd "${2:?}" && pwd)
prefix=${3:?}
case "$prefix" in /*) ;; *) prefix="$PWD/$prefix" ;; esac

common=(
  --prefix="$prefix"
  --enable-tools
  --enable-slirp
  --disable-user
  --disable-docs
  --disable-guest-agent
  --disable-gtk
  --disable-sdl
  --disable-sdl-image
  --disable-vnc-jpeg
  --disable-vnc-sasl
  --disable-spice
  --disable-opengl
  --disable-virglrenderer
  --disable-gnutls
  --disable-nettle
  --disable-gcrypt
  --disable-curl
  --disable-libssh
  --disable-capstone
  --disable-libusb
  --disable-usb-redir
  --disable-smartcard
  --disable-brlapi
  --disable-curses
  --disable-png
  --disable-lzo
  --disable-snappy
  --disable-bzip2
  --disable-rbd
  --disable-libiscsi
  --disable-libnfs
  --disable-rust
  --audio-drv-list=
)
case "$host" in
  darwin-arm64)
    extra=(--target-list=aarch64-softmmu --enable-hvf --enable-virtfs --disable-cocoa --disable-pvg)
    ;;
  linux-amd64)
    extra=(--target-list=x86_64-softmmu --enable-kvm --enable-virtfs --enable-attr --enable-cap-ng
           --disable-modules --disable-xen --disable-seccomp --disable-numa --disable-rdma
           --disable-linux-io-uring --disable-fuse --disable-vde --disable-netmap)
    ;;
  windows-amd64)
    extra=(--cross-prefix=x86_64-w64-mingw32- --target-list=x86_64-softmmu --enable-whpx --disable-virtfs)
    ;;
  *) die "unknown host $host" ;;
esac
args=("${common[@]}" "${extra[@]}")
printf '%s\n' "${args[@]}" | sed "s|^--prefix=.*|--prefix=<prefix>|" > "$prefix.configure"

# Everything compiled must come from the verified tarball, which is what the
# source asset publishes. meson may fetch a missing subproject on its own,
# so fail if configure or the build adds anything under subprojects/.
# (--disable-download would also stop QEMU's build venv from installing the
# Python build tools it lacks, which Homebrew cannot supply.)
subprojects() { find "$src/subprojects" -mindepth 1 -maxdepth 2 ! -name .wraplock | LC_ALL=C sort; }
before=$(subprojects)

build="$src/build-pvm"
mkdir -p "$build"
cd "$build"
"$src/configure" "${args[@]}"
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)
make -j"$jobs"
make install

added=$(comm -13 <(echo "$before") <(subprojects))
[ -z "$added" ] || die "the build fetched sources that are not in the QEMU tarball:
$added"
echo "installed QEMU for $host into $prefix"
