#!/usr/bin/env bash
# release-notes.sh <tag>
#
# Prints the release notes: what the build is, its patches, how to verify
# the assets, and where the source is.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

tag=${1:?usage: release-notes.sh <tag>}
load_release "$tag"
repo=${GH_REPO:-BitterOrange/pvm-qemu}

cat <<EOF
QEMU $QEMU_VERSION built for [pvm](https://github.com/BitterOrange/pvm) from the signed upstream release. This is not an official QEMU release, and the pvm-qemu project is not affiliated with the QEMU project.

Upstream: \`qemu-$QEMU_VERSION.tar.xz\`, SHA-256 \`$QEMU_SHA256\`, signed by the QEMU release key \`$(cat "$PVMQ_ROOT/keys/FINGERPRINT")\`.

EOF
if [ -n "$PATCHES" ]; then
  echo "Patches (each an upstream QEMU commit):"
  echo
  for p in $PATCHES; do
    c=$(sed -nE 's/^Upstream: ([0-9a-f]{40})$/\1/p' "$PVMQ_ROOT/patches/$tag/$p" | head -1)
    echo "- \`$p\` (upstream $c)"
  done
else
  echo "Patches: none; this is stock QEMU $QEMU_VERSION."
fi
cat <<EOF

| Host | Archive |
|---|---|
| macOS arm64 (HVF) | \`$(host_asset "$tag" darwin-arm64)\` |
| Linux x86_64 (KVM) | \`$(host_asset "$tag" linux-amd64)\` |
| Windows x86_64 (WHPX) | \`$(host_asset "$tag" windows-amd64)\` |

pvm v1.4 and later install the build they pin with \`pvm qemu install\`; a build that your pvm does not pin needs \`pvm qemu install $tag --unpinned\`, which checks the attestation with gh.

Verify an asset by hand:

\`\`\`
gh attestation verify <asset> --repo $repo --signer-workflow $repo/.github/workflows/release.yml --source-ref refs/tags/$tag --deny-self-hosted-runners
sha256sum -c SHA256SUMS --ignore-missing
\`\`\`

Source: \`$(source_asset "$tag")\` holds the upstream tarball, its signature, the patches and this repository at the tag; each \`*-deps-source.tar\` holds the source of the libraries shipped in that host's archive, which its \`doc/THIRD-PARTY.txt\` lists. The "Source code" archives that GitHub adds to every release hold only this repository's scripts, not QEMU.
EOF
