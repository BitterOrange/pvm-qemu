#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# make-source.sh <tag> <upstream-dir> <out-dir>
#
# Writes <out-dir>/pvm-qemu-<tag>-source.tar.gz, the corresponding source of
# QEMU in every build of the tag:
#   qemu-<version>.tar.xz and .sig   the verified upstream release
#   patches/                         the patches applied to it, if any
#   pvm-qemu-<commit>.tar            this repository at the tag: the build
#                                    and packaging scripts and configure flags
#   BUILD.md                         how the builds were made
# The sources of the libraries shipped next to QEMU are in each host's
# deps-source asset.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

tag=${1:?usage: make-source.sh <tag> <upstream-dir> <out-dir>}
upstream=${2:?}
out=${3:?}
load_release "$tag"
"$PVMQ_ROOT/script/verify-upstream.sh" --offline "$tag" "$upstream" >/dev/null

commit=$(git -C "$PVMQ_ROOT" rev-parse HEAD)
git -C "$PVMQ_ROOT" diff --quiet HEAD -- || die "the checkout has uncommitted changes; the source asset must match a commit"
epoch=${SOURCE_DATE_EPOCH:-$(git -C "$PVMQ_ROOT" log -1 --format=%ct)}

mkdir -p "$out"
stage=$(mktemp -d "${TMPDIR:-/tmp}/pvmq-source.XXXXXX")
trap 'rm -rf "$stage"' EXIT
name="pvm-qemu-$tag-source"
d="$stage/$name"
mkdir -p "$d"
cp "$upstream/qemu-$QEMU_VERSION.tar.xz" "$upstream/qemu-$QEMU_VERSION.tar.xz.sig" "$d/"
if [ -n "$PATCHES" ]; then
  mkdir -p "$d/patches"
  for p in $PATCHES; do cp "$PVMQ_ROOT/patches/$tag/$p" "$d/patches/"; done
fi
git -C "$PVMQ_ROOT" archive --format=tar --prefix="pvm-qemu-${commit:0:12}/" -o "$d/pvm-qemu-${commit:0:12}.tar" "$commit"

cat > "$d/BUILD.md" <<EOF
# Source of pvm-qemu $tag

This is the complete corresponding source of the QEMU binaries in the
pvm-qemu release $tag (QEMU $QEMU_VERSION).

- \`qemu-$QEMU_VERSION.tar.xz\` is the upstream release from
  https://download.qemu.org/, and \`qemu-$QEMU_VERSION.tar.xz.sig\` its
  signature by the QEMU release key $(cat "$PVMQ_ROOT/keys/FINGERPRINT").
  SHA-256: $QEMU_SHA256.
- \`patches/\` holds the patches applied to it, in order, each an upstream
  QEMU commit. $( [ -n "$PATCHES" ] && echo "This build applies: $PATCHES." || echo "This build applies none, so there is no patches/ directory." )
- \`pvm-qemu-${commit:0:12}.tar\` is the pvm-qemu repository at commit $commit,
  which the release was built from: \`script/build.sh\` has the configure
  arguments for each host, and the \`pack-*.sh\` scripts assemble the
  archives. \`.github/workflows/build.yml\` runs them.

To rebuild for a host, extract the QEMU tarball, apply the patches with
\`patch -p1 --fuzz=0\`, and run \`script/build.sh <host> <source-dir> <prefix>\`
followed by the matching \`script/pack-<os>.sh\`, as the workflow does.

The libraries shipped next to QEMU in each archive are listed in its
\`doc/THIRD-PARTY.txt\`; their sources are in the release asset
\`pvm-qemu-$tag-<host>-deps-source.tar\`.
EOF

python3 "$PVMQ_ROOT/script/mktar.py" --root "$stage" --entry "$name" --out "$out/$(source_asset "$tag")" --gzip --epoch "$epoch"
