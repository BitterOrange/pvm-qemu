#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# darwin-build.sh <tag> <upstream-dir> <out-dir>
#
# Runs on a GitHub-hosted macos-15 runner: installs the build dependencies
# from Homebrew, builds, packs and signs, collects the library sources and
# finishes the tree at <out-dir>/tree/aarch64.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

tag=${1:?usage: darwin-build.sh <tag> <upstream-dir> <out-dir>}
upstream=${2:?}
out=${3:?}
load_release "$tag"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1

brew install --quiet gnupg ninja pkgconf glib pixman libslirp dtc python-setuptools
brew list --versions | sort > "$out/build-packages.txt"

src=$("$PVMQ_ROOT/script/prepare-source.sh" "$tag" "$upstream" "$out/src")
prefix="$(cd "$out" && pwd)/prefix"
"$PVMQ_ROOT/script/build.sh" darwin-arm64 "$src" "$prefix"
tree="$out/tree/aarch64"
"$PVMQ_ROOT/script/pack-darwin.sh" "$prefix" "$tree"
"$PVMQ_ROOT/script/collect-dep-sources.sh" darwin-arm64 "$tree" "$out/deps/$(basename "$(deps_asset "$tag" darwin-arm64)" .tar)"
cp "$out/build-packages.txt" "$tree/doc/build-packages.txt"
python3 "$PVMQ_ROOT/script/finish-tree.py" --tree "$tree" --tag "$tag" --host darwin-arm64 \
  --src "$src" --configure "$prefix.configure" --minos "$(cat "$tree.minos")" \
  --env "runner_image=${ImageOS:-macos}-${ImageVersion:-local}" --env "run_id=${GITHUB_RUN_ID:-local}" --env "commit=${GITHUB_SHA:-local}"
"$PVMQ_ROOT/script/check-closure.sh" darwin-arm64 "$tree"
