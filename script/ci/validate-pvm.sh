#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# validate-pvm.sh
#
# Installs the pvm release PVM_TAG (e.g. v1.3.6) with that release's own
# install.sh, which checks pvm's attestations with gh (GH_TOKEN). It also
# installs that release's own QEMU runtime, which validate.sh install then
# moves aside. Used by validate.yml.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

[[ "${PVM_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "PVM_TAG must be a pvm release tag such as v1.3.6"
script=$(mktemp)
curl -fsSL --proto '=https' "https://raw.githubusercontent.com/BitterOrange/pvm/$PVM_TAG/scripts/install.sh" -o "$script"
TAG=$PVM_TAG INSTALL_DIR="$HOME/.local/bin" sh "$script"
echo "$HOME/.local/bin" >> "$GITHUB_PATH"
"$HOME/.local/bin/pvm" version
