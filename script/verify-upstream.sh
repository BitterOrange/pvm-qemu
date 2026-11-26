#!/usr/bin/env bash
# verify-upstream.sh [--offline] <tag> <dir>
#
# Puts qemu-<version>.tar.xz and its .sig from download.qemu.org into <dir>
# (unless --offline, which only checks files already there) and requires all
# of these:
#   - keys/qemu-release.asc holds exactly one primary key, whose fingerprint
#     is the one in keys/FINGERPRINT;
#   - gpgv reports VALIDSIG for the tarball by that key;
#   - the tarball's SHA-256 equals QEMU_SHA256 in releases/<tag>.env.
# PVMQ_KEY and PVMQ_FINGERPRINT override the key files (used by the tamper
# tests only).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

offline=0
if [ "${1:-}" = --offline ]; then offline=1; shift; fi
tag=${1:?usage: verify-upstream.sh [--offline] <tag> <dir>}
dir=${2:?usage: verify-upstream.sh [--offline] <tag> <dir>}
load_release "$tag"

key=${PVMQ_KEY:-$PVMQ_ROOT/keys/qemu-release.asc}
want=$(tr -d ' \r\n' < "${PVMQ_FINGERPRINT:-$PVMQ_ROOT/keys/FINGERPRINT}")
[[ "$want" =~ ^[0-9A-F]{40}$ ]] || die "keys/FINGERPRINT must be 40 uppercase hex digits"

tarball="$dir/qemu-$QEMU_VERSION.tar.xz"
mkdir -p "$dir"
if [ "$offline" = 0 ]; then
  for f in "qemu-$QEMU_VERSION.tar.xz" "qemu-$QEMU_VERSION.tar.xz.sig"; do
    [ -f "$dir/$f" ] && continue
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 20 --retry 5 --retry-all-errors \
      -o "$dir/$f.part" "https://download.qemu.org/$f"
    mv "$dir/$f.part" "$dir/$f"
  done
fi
[ -f "$tarball" ] || die "$tarball is missing"
[ -f "$tarball.sig" ] || die "$tarball.sig is missing"

gnupghome=$(mktemp -d "${TMPDIR:-/tmp}/pvmq-gpg.XXXXXX")
trap 'rm -rf "$gnupghome"' EXIT
chmod 700 "$gnupghome"

# Exactly one primary key, and it must be the pinned one.
primaries=$(GNUPGHOME="$gnupghome" gpg --batch --quiet --show-keys --with-colons "$key" |
  awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}')
[ "$primaries" = "$want" ] || die "release key file does not hold exactly the pinned key $want (found: ${primaries:-none})"

GNUPGHOME="$gnupghome" gpg --batch --quiet --dearmor < "$key" > "$gnupghome/release.gpg"
status=$(gpgv --status-fd 1 --keyring "$gnupghome/release.gpg" "$tarball.sig" "$tarball" 2>"$gnupghome/gpgv.err") ||
  { cat "$gnupghome/gpgv.err" >&2; die "signature check of $(basename "$tarball") failed"; }
# VALIDSIG <signing-key fpr> ... <primary key fpr>
echo "$status" | awk -v want="$want" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == want {ok = 1} END {exit !ok}' ||
  die "no valid signature by $want on $(basename "$tarball")"

actual=$(sha256_of "$tarball")
[ "$actual" = "$QEMU_SHA256" ] || die "$(basename "$tarball") has SHA-256 $actual, releases/$tag.env pins $QEMU_SHA256"

echo "verified qemu-$QEMU_VERSION.tar.xz: signed by $want, sha256 $actual"
