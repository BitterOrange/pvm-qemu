#!/usr/bin/env bash
# linux-build.sh <tag> <upstream-dir> <out-dir>
#
# Runs as root inside the pinned ubuntu:24.04 container (see build.yml):
# installs the build dependencies, builds, packs, collects the library
# sources and finishes the tree at <out-dir>/tree/x86_64. The isolated probe
# runs afterwards on the host, which this container cannot do.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

tag=${1:?usage: linux-build.sh <tag> <upstream-dir> <out-dir>}
upstream=${2:?}
out=${3:?}
load_release "$tag"
export DEBIAN_FRONTEND=noninteractive

sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update -q
apt-get install -y -q --no-install-recommends \
  build-essential pkg-config ninja-build python3 python3-venv python3-setuptools python3-wheel \
  bzip2 xz-utils flex bison \
  patch patchelf file ca-certificates gpg gpgv dpkg-dev \
  libglib2.0-dev libpixman-1-dev libslirp-dev libcap-ng-dev libattr1-dev libfdt-dev zlib1g-dev
dpkg-query -W -f '${Package}\t${Version}\n' | sort > "$out/build-packages.txt"

src=$("$PVMQ_ROOT/script/prepare-source.sh" "$tag" "$upstream" "$out/src")
prefix=/opt/pvm-qemu
"$PVMQ_ROOT/script/build.sh" linux-amd64 "$src" "$prefix"
tree="$out/tree/x86_64"
"$PVMQ_ROOT/script/pack-linux.sh" "$prefix" "$tree"
"$PVMQ_ROOT/script/collect-dep-sources.sh" linux-amd64 "$tree" "$out/deps/$(basename "$(deps_asset "$tag" linux-amd64)" .tar)"
cp "$out/build-packages.txt" "$tree/doc/build-packages.txt"
python3 "$PVMQ_ROOT/script/finish-tree.py" --tree "$tree" --tag "$tag" --host linux-amd64 \
  --src "$src" --configure "$prefix.configure" \
  --env "container_image=ubuntu:24.04@${CONTAINER_DIGEST:?}" --env "run_id=${GITHUB_RUN_ID:-local}" --env "commit=${GITHUB_SHA:-local}"
"$PVMQ_ROOT/script/check-closure.sh" linux-amd64 "$tree"
