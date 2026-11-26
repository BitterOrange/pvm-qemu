#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
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
        mkdir -p "$out/$pkg" "$tree/doc/licenses/$pkg"
        # Homebrew installs from its JSON API, with no local homebrew-core
        # checkout, so take everything from the API's own record: the
        # formula file at the commit the API was built from and the source
        # tarball, each checked against the digest Homebrew publishes.
        brew info --json=v2 "$pkg" > "$out/$pkg/info.json"
        python3 - "$out/$pkg" "$pkg" "$ver" <<'PY' || die "cannot collect the source of $pkg"
import hashlib, json, os, re, sys, time, urllib.request
out, pkg, ver = sys.argv[1:4]
f = json.load(open(os.path.join(out, "info.json")))["formulae"][0]

def get(url):
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "pvm-qemu-ci"})
            return urllib.request.urlopen(req, timeout=120).read()
        except OSError as e:
            if attempt == 2:
                sys.exit(f"{url}: {e}")
            time.sleep(5 * (attempt + 1))

def fetch(url, sha256, dest):
    data = get(url)
    got = hashlib.sha256(data).hexdigest()
    if got != sha256:
        sys.exit(f"{url}: sha256 {got}, Homebrew publishes {sha256}")
    open(os.path.join(out, dest), "wb").write(data)

stable = f["versions"]["stable"] + (f"_{f['revision']}" if f.get("revision") else "")
if stable != ver:
    sys.exit(f"{pkg}: installed {ver}, but the formula now builds {stable}; the source would not match")
core = f"https://raw.githubusercontent.com/Homebrew/homebrew-core/{f['tap_git_head']}"
rb = f["ruby_source_path"]
fetch(f"{core}/{rb}", f["ruby_source_checksum"]["sha256"], os.path.basename(rb))
lines = open(os.path.join(out, os.path.basename(rb)), encoding="utf-8").read().splitlines()

# Inline patches (patch :DATA) are in the formula file itself. Resource and
# patch blocks name more sources: a url with its sha256, or a file in
# homebrew-core, fetched at the same commit as the formula. Anything else
# fails, so nothing the build used is left out.
start = re.compile(r'^(\s*)(resource\s+"([^"]+)"|patch(\s+:p\d+)?)\s+do\s*$')
i = 0
while i < len(lines):
    m = start.match(lines[i])
    if not m:
        i += 1
        continue
    indent, what = m.group(1), m.group(2)
    body = []
    i += 1
    while i < len(lines) and lines[i] != indent + "end":
        body.append(lines[i])
        i += 1
    text = "\n".join(body)
    url = re.search(r'^\s*url\s+"([^"]+)"', text, re.M)
    sha = re.search(r'^\s*sha256\s+"([0-9a-f]{64})"', text, re.M)
    local = re.search(r'^\s*file\s+"([^"]+)"', text, re.M)
    if url and sha:
        name = os.path.basename(url.group(1).split("?")[0])
        if what.startswith("patch"):
            name = "patch-" + name
        fetch(url.group(1), sha.group(1), name)
    elif local and what.startswith("patch"):
        data = get(f"{core}/{local.group(1)}")
        open(os.path.join(out, "patch-" + os.path.basename(local.group(1))), "wb").write(data)
    else:
        sys.exit(f"{pkg}: cannot collect the source of the formula's {what} block")
src = f["urls"]["stable"]
if src.get("using") or not src.get("checksum"):
    sys.exit(f"{pkg}: the formula's source is not a checksummed download")
fetch(src["url"], src["checksum"], os.path.basename(src["url"].split("?")[0]))
lic = f.get("license") or ""
open(os.path.join(out, "LICENSE-SPDX"), "w").write((lic if isinstance(lic, str) else json.dumps(lic)) + "\n")
PY
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
