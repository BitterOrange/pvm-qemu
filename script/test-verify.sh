#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# test-verify.sh <tag> <upstream-dir>
#
# Proves that the source checks fail when they should. Needs the verified
# tarball and signature in <upstream-dir>. Each case below must be refused;
# the script fails if any of them is accepted, or if the real files are not.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

tag=${1:?usage: test-verify.sh <tag> <upstream-dir>}
upstream=${2:?}
load_release "$tag"
verify="$PVMQ_ROOT/script/verify-upstream.sh"
name="qemu-$QEMU_VERSION.tar.xz"

work=$(mktemp -d "${TMPDIR:-/tmp}/pvmq-tamper.XXXXXX")
trap 'rm -rf "$work"' EXIT
failures=0

expect_refused() {
  local what=$1; shift
  if "$@" >"$work/out" 2>&1; then
    echo "FAIL: accepted $what" >&2
    cat "$work/out" >&2
    failures=$((failures + 1))
  else
    echo "ok: refused $what ($(tail -1 "$work/out"))"
  fi
}

"$verify" --offline "$tag" "$upstream" >/dev/null || die "the real tarball does not verify"
echo "ok: accepted the real tarball"

# One flipped byte in the middle of the tarball.
mkdir "$work/flip"
cp "$upstream/$name" "$upstream/$name.sig" "$work/flip/"
python3 - "$work/flip/$name" <<'PY'
import os, sys
path = sys.argv[1]
with open(path, "r+b") as f:
    f.seek(os.path.getsize(path) // 2)
    b = f.read(1)
    f.seek(-1, 1)
    f.write(bytes([b[0] ^ 0x01]))
PY
expect_refused "a tarball with one flipped byte" "$verify" --offline "$tag" "$work/flip"

# A valid signature, but by another key.
export GNUPGHOME="$work/gnupg"
mkdir "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key "pvm-qemu tamper test <test@example.com>" ed25519 sign never
other=$(gpg --batch --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}')
mkdir "$work/othersig"
cp "$upstream/$name" "$work/othersig/"
gpg --batch --quiet --detach-sign -o "$work/othersig/$name.sig" "$work/othersig/$name"
expect_refused "a signature by another key" "$verify" --offline "$tag" "$work/othersig"

# The other key substituted as the release key, with its own fingerprint.
gpg --batch --armor --export "$other" > "$work/other.asc"
echo "$other" > "$work/other.fpr"
expect_refused "a key file that is not the pinned key" \
  env PVMQ_KEY="$work/other.asc" "$verify" --offline "$tag" "$work/othersig"
expect_refused "a pinned fingerprint that the key file does not hold" \
  env PVMQ_FINGERPRINT="$work/other.fpr" "$verify" --offline "$tag" "$upstream"
unset GNUPGHOME

# A correctly signed tarball whose digest differs from the pin.
mkdir -p "$work/root/releases" "$work/root/script" "$work/root/keys"
cp "$PVMQ_ROOT"/script/*.sh "$work/root/script/"
cp "$PVMQ_ROOT"/keys/* "$work/root/keys/"
sed "s/^QEMU_SHA256=.*/QEMU_SHA256=$(printf '0%.0s' $(seq 64))/" "$PVMQ_ROOT/releases/$tag.env" > "$work/root/releases/$tag.env"
expect_refused "a digest that differs from releases/$tag.env" "$work/root/script/verify-upstream.sh" --offline "$tag" "$upstream"

# A patch whose context does not match exactly.
mkdir -p "$work/src" "$work/patches"
printf 'one\ntwo\nthree\nfour\nfive\n' > "$work/src/file.txt"
cat > "$work/patches/0001-test.patch" <<'EOF'
Upstream: 0123456789abcdef0123456789abcdef01234567
--- a/file.txt
+++ b/file.txt
@@ -1,5 +1,5 @@
 one
 two
-three
+THREE
 four
 changed
EOF
expect_refused "a patch whose context is off by one line" \
  "$PVMQ_ROOT/script/apply-patches.sh" "$work/patches" "$work/src" 0001-test.patch
grep -qx three "$work/src/file.txt" || { echo "FAIL: the refused patch changed the file" >&2; failures=$((failures + 1)); }

# A patch without its upstream commit.
sed '1d' "$work/patches/0001-test.patch" > "$work/patches/0002-test.patch"
expect_refused "a patch without an Upstream line" \
  "$PVMQ_ROOT/script/apply-patches.sh" "$work/patches" "$work/src" 0002-test.patch

[ "$failures" = 0 ] || die "$failures tamper case(s) were accepted"
echo "all tamper cases refused"
