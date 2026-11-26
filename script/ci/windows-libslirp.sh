#!/usr/bin/env bash
# windows-libslirp.sh <prefix>
#
# Fedora has no mingw build of libslirp, which QEMU needs for user
# networking. This builds it for mingw-w64 from Fedora's own libslirp source
# RPM: the RPM's Fedora signature is checked, the spec must carry no patches
# (so the source is exactly the upstream tarball inside it), and the RPM is
# kept next to the install as <prefix>/pvm-source/ for the deps-source asset.
# Runs as root inside the Fedora mingw container.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

prefix=${1:?usage: windows-libslirp.sh <prefix>}
[ ! -e "$prefix" ] || die "$prefix already exists"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

dnf --quiet --enablerepo=fedora-source --enablerepo=updates-source download --source --destdir "$work" libslirp
srpm=$(find "$work" -maxdepth 1 -name 'libslirp-*.src.rpm' -print -quit)
[ -n "$srpm" ] || die "dnf did not download the libslirp source RPM"
fedora=$(rpm -E %fedora)
for key in /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-"$fedora"-primary /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-"$fedora"-x86_64; do
  [ -f "$key" ] && rpmkeys --import "$key"
done
rpmkeys --checksig "$srpm" | grep -Eq ': digests signatures OK$' || { rpmkeys --checksig -v "$srpm" >&2; die "$(basename "$srpm") does not carry a valid Fedora signature"; }

mkdir "$work/x"
(cd "$work/x" && rpm2cpio "$srpm" | cpio -idm --quiet)
spec=$(find "$work/x" -name '*.spec' -print -quit)
grep -Eq '^Patch[0-9]*:' "$spec" && die "the Fedora libslirp spec carries patches; this build would not match its source"
tarball=$(find "$work/x" -maxdepth 1 -name 'libslirp-*.tar.*' -print -quit)
[ -n "$tarball" ] || die "no libslirp tarball in $(basename "$srpm")"
tar -xf "$tarball" -C "$work"
src=$(find "$work" -maxdepth 1 -type d -name 'libslirp-*' -print -quit)

meson setup --cross-file=/usr/share/mingw/toolchain-mingw64.meson --prefix="$prefix" \
  --buildtype=release -Ddefault_library=shared "$work/build" "$src"
ninja -C "$work/build" install

mkdir -p "$prefix/pvm-source/licenses"
cp "$srpm" "$prefix/pvm-source/"
cp "$src"/COPYRIGHT* "$src"/LICENSE* "$prefix/pvm-source/licenses/" 2>/dev/null || true
[ -n "$(ls "$prefix/pvm-source/licenses")" ] || die "no license file in the libslirp source"
printf '%s\t%s\t%s\n' libslirp "$(rpm -qp --qf '%{VERSION}-%{RELEASE}' "$srpm" 2>/dev/null)" "$(rpm -qp --qf '%{LICENSE}' "$srpm" 2>/dev/null)" > "$prefix/pvm-source/PACKAGE"
echo "built libslirp from $(basename "$srpm") into $prefix"
