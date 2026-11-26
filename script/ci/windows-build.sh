#!/usr/bin/env bash
# windows-build.sh <tag> <upstream-dir> <out-dir>
#
# Runs as root inside the Fedora mingw-w64 container built from the QEMU
# tarball's own tests/docker/dockerfiles/fedora-win64-cross.docker (see
# build.yml): cross-builds, packs, collects the library sources and
# finishes the tree at <out-dir>/tree/x86_64.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

tag=${1:?usage: windows-build.sh <tag> <upstream-dir> <out-dir>}
upstream=${2:?}
out=${3:?}
load_release "$tag"

# The upstream image has what QEMU's own CI builds with; add what this
# build needs on top and fail if any of it is unavailable.
dnf install -y -q --setopt=install_weak_deps=False \
  mingw64-glib2 mingw64-pixman mingw64-zlib mingw64-libfdt \
  patch gnupg2 python3 findutils file cpio
rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' | sort > "$out/build-packages.txt"

# libslirp has no mingw package in Fedora; build it from Fedora's source RPM.
# It goes under the mingw sysroot, because the mingw pkg-config prefixes
# the sysroot to every path that does not already start with it.
slirp=/usr/x86_64-w64-mingw32/sys-root/mingw/opt/pvm-deps/libslirp
"$PVMQ_ROOT/script/ci/windows-libslirp.sh" "$slirp"
printf 'libslirp (built)\t%s\n' "$(cut -f2 "$slirp/pvm-source/PACKAGE")" >> "$out/build-packages.txt"
export PKG_CONFIG_PATH="$slirp/lib/pkgconfig"
export PVMQ_DLL_DIRS="$slirp/bin"

src=$("$PVMQ_ROOT/script/prepare-source.sh" "$tag" "$upstream" "$out/src")
prefix=/opt/pvm-qemu-win
"$PVMQ_ROOT/script/build.sh" windows-amd64 "$src" "$prefix"
tree="$out/tree/x86_64"
"$PVMQ_ROOT/script/pack-windows.sh" "$prefix" "$tree"
"$PVMQ_ROOT/script/collect-dep-sources.sh" windows-amd64 "$tree" "$out/deps/$(basename "$(deps_asset "$tag" windows-amd64)" .tar)"
cp "$out/build-packages.txt" "$tree/doc/build-packages.txt"
python3 "$PVMQ_ROOT/script/finish-tree.py" --tree "$tree" --tag "$tag" --host windows-amd64 \
  --src "$src" --configure "$prefix.configure" \
  --env "container_image=${CONTAINER_IMAGE:?}" --env "run_id=${GITHUB_RUN_ID:-local}" --env "commit=${GITHUB_SHA:-local}"
"$PVMQ_ROOT/script/check-closure.sh" windows-amd64 "$tree"
