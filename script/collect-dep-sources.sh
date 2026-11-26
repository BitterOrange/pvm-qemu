#!/usr/bin/env bash
# collect-dep-sources.sh <host> <tree> <out-dir>
#
# For every library a packer copied into <tree> (listed in <tree>.origins),
# finds the package it came from, downloads that package's source into
# <out-dir>, copies the package's license files into <tree>/doc/licenses,
# and writes <tree>/doc/THIRD-PARTY.txt. A library whose package or source
# cannot be found fails the build: everything shipped must have its source
# in the same release.
#
#   linux-amd64    dpkg and apt-get source (deb-src must be enabled)
#   darwin-arm64   Homebrew: brew fetch --build-from-source and the formula
#   windows-amd64  rpm and dnf download --source (Fedora mingw packages)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

host=${1:?usage: collect-dep-sources.sh <host> <tree> <out-dir>}
tree=${2:?}
out=${3:?}
origins="$tree.origins"
[ -f "$origins" ] || die "$origins not found; run the packer first"
mkdir -p "$out" "$tree/doc/licenses"
third="$tree/doc/THIRD-PARTY.txt"
{
  echo "Libraries shipped in this build, the package each one comes from, and"
  echo "its license. The source of every package listed here is in the"
  echo "release's $host deps-source asset; QEMU's own source is in the source"
  echo "asset. License texts are in doc/licenses."
  echo
  printf '%s\t%s\t%s\t%s\n' file package version license
} > "$third"

declare -A done_pkg=()

linux_owner() {
  local real=$1 orig=$2 p
  # dpkg -S prints "pkg[:arch][, pkg...]: path" lines, and for a diverted
  # file such as the ELF loader also "diversion by pkg from: path" lines.
  local owner
  for p in "$orig" "$real" "${orig#/usr}" "${real#/usr}" "/usr$orig"; do
    owner=$(dpkg -S "$p" 2>/dev/null | grep -v '^diversion ' | head -1 | sed -E 's/[:,].*//') || true
    [ -n "$owner" ] && { echo "$owner"; return 0; }
  done
  return 1
}

while IFS=$'\t' read -r file real orig; do
  [ -n "$file" ] || continue
  case "$host" in
    linux-amd64)
      pkg=$(linux_owner "$real" "${orig:-$real}") || die "no package owns $real ($file)"
      ver=$(dpkg-query -W -f '${Version}' "$pkg")
      srcpkg=$(dpkg-query -W -f '${source:Package}' "$pkg")
      srcver=$(dpkg-query -W -f '${source:Version}' "$pkg")
      lic="licenses/$pkg.copyright"
      if [ -z "${done_pkg[$pkg]:-}" ]; then
        cp -L "/usr/share/doc/$pkg/copyright" "$tree/doc/$lic" || die "$pkg has no copyright file"
        if [ -z "${done_pkg[src:$srcpkg]:-}" ]; then
          mkdir -p "$out/$srcpkg"
          (cd "$out/$srcpkg" && apt-get source --download-only "$srcpkg=$srcver") ||
            die "cannot download the source of $srcpkg $srcver"
          done_pkg[src:$srcpkg]=1
        fi
        done_pkg[$pkg]=1
      fi
      ;;
    darwin-arm64)
      [[ "$real" =~ ^/opt/homebrew/Cellar/([^/]+)/([^/]+)/ ]] || die "$file comes from $real, not a Homebrew keg"
      pkg=${BASH_REMATCH[1]} ver=${BASH_REMATCH[2]}
      lic="licenses/$pkg/"
      if [ -z "${done_pkg[$pkg]:-}" ]; then
        info=$(brew info --json=v2 "$pkg")
        stable=$(echo "$info" | python3 -c 'import json,sys; f=json.load(sys.stdin)["formulae"][0]; print(f["versions"]["stable"] + ("_" + str(f["revision"]) if f.get("revision") else ""))')
        [ "$stable" = "$ver" ] || die "$pkg: installed $ver but the formula now builds $stable; the source would not match"
        mkdir -p "$out/$pkg" "$tree/doc/licenses/$pkg"
        brew cat "$pkg" > "$out/$pkg/$pkg.rb"
        echo "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["formulae"][0].get("license") or "")' > "$out/$pkg/LICENSE-SPDX"
        # The formula (with any inline patches), its source, and whatever
        # else brew reports downloading for it, such as external patches.
        fetched=$(HOMEBREW_NO_AUTO_UPDATE=1 brew fetch --build-from-source --retry "$pkg" 2>&1) || { echo "$fetched" >&2; die "cannot fetch the source of $pkg"; }
        main=$(brew --cache --build-from-source "$pkg")
        [ -f "$main" ] || { echo "$fetched" >&2; die "the source of $pkg is not at $main after brew fetch"; }
        cp "$main" "$out/$pkg/"
        while IFS= read -r path; do
          [ -f "$path" ] && [ "$path" != "$main" ] && cp "$path" "$out/$pkg/"
        done < <(echo "$fetched" | sed -nE 's/^(Downloaded to|Already downloaded): (.*)$/\2/p')
        found=0
        for f in /opt/homebrew/Cellar/"$pkg"/"$ver"/{COPYING*,LICENSE*,LICENCE*,COPYRIGHT*,NOTICE*}; do
          [ -f "$f" ] || continue
          cp "$f" "$tree/doc/licenses/$pkg/"
          found=1
        done
        [ "$found" = 1 ] || cp "$out/$pkg/LICENSE-SPDX" "$tree/doc/licenses/$pkg/LICENSE-SPDX"
        done_pkg[$pkg]=1
      fi
      ;;
    windows-amd64)
      built="$(dirname "$(dirname "$real")")/pvm-source"
      if [ -f "$built/PACKAGE" ]; then
        # A library this build compiled from a Fedora source RPM
        # (script/ci/windows-libslirp.sh).
        IFS=$'\t' read -r pkg ver license < "$built/PACKAGE"
        lic="licenses/$pkg/"
        if [ -z "${done_pkg[$pkg]:-}" ]; then
          mkdir -p "$tree/doc/licenses/$pkg"
          cp "$built"/licenses/* "$tree/doc/licenses/$pkg/"
          cp "$built"/*.src.rpm "$out/"
          done_pkg[$pkg]=1
        fi
        printf '%s\t%s\t%s\t%s\n' "$file" "$pkg (built from the Fedora source RPM)" "$ver" "$license" >> "$third"
        continue
      fi
      rpm -qf "$real" >/dev/null 2>&1 || die "no package owns $real ($file)"
      read -r pkg ver srpm < <(rpm -qf --qf '%{NAME} %{VERSION}-%{RELEASE} %{SOURCERPM}\n' "$real" | head -1)
      lic="licenses/$pkg/"
      if [ -z "${done_pkg[$pkg]:-}" ]; then
        mkdir -p "$tree/doc/licenses/$pkg"
        n=0
        while IFS= read -r f; do
          [ -f "$f" ] || continue
          cp "$f" "$tree/doc/licenses/$pkg/"
          n=$((n + 1))
        done < <(rpm -qL "$pkg")
        [ "$n" -gt 0 ] || rpm -q --qf '%{LICENSE}\n' "$pkg" > "$tree/doc/licenses/$pkg/LICENSE-SPDX"
        if [ ! -f "$out/$srpm" ]; then
          dnf --quiet --enablerepo=fedora-source --enablerepo=updates-source download --source --destdir "$out" "$pkg-$ver" ||
            die "cannot download the source of $pkg $ver"
          [ -f "$out/$srpm" ] || die "dnf did not download $srpm"
        fi
        done_pkg[$pkg]=1
      fi
      ;;
    *) die "unknown host $host" ;;
  esac
  case "$host" in
    windows-amd64) license=$(rpm -q --qf '%{LICENSE}' "$pkg") ;;
    darwin-arm64) license=$(cat "$out/$pkg/LICENSE-SPDX") ;;
    *) license="see doc/$lic" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$file" "$pkg" "$ver" "${license:-see doc/$lic}" >> "$third"
done < "$origins"

echo "listed $(($(wc -l < "$third") - 6)) libraries; sources in $out"
