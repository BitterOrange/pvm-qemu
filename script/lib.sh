# shellcheck shell=bash
# Shared helpers, sourced by the other scripts.

# The repository root, wherever the caller runs from.
PVMQ_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() { echo "error: $*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# check_tag <tag>: a release tag is <qemu-version>-pvm<N>, where the QEMU
# version may carry an -rcN suffix.
check_tag() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?-pvm[0-9]+$ ]] || die "invalid tag '$1'; expected <qemu-version>-pvm<N>, e.g. 11.1.3-pvm1"
}

# load_release <tag>: reads releases/<tag>.env strictly and sets
# QEMU_VERSION, QEMU_SHA256 and PATCHES. The file is parsed, not sourced.
load_release() {
  local tag=$1 file key value
  check_tag "$tag"
  file="$PVMQ_ROOT/releases/$tag.env"
  [ -f "$file" ] || die "no release file releases/$tag.env"
  QEMU_VERSION="" QEMU_SHA256="" PATCHES=""
  local seen=" "
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || die "releases/$tag.env: bad line: $line"
    key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
    case "$seen" in *" $key "*) die "releases/$tag.env: $key set twice" ;; esac
    seen="$seen$key "
    case "$key" in
      QEMU_VERSION) QEMU_VERSION=$value ;;
      QEMU_SHA256) QEMU_SHA256=$value ;;
      PATCHES) PATCHES=$value ;;
      *) die "releases/$tag.env: unknown key $key" ;;
    esac
  done < "$file"
  [ "$QEMU_VERSION" = "${tag%-pvm*}" ] || die "releases/$tag.env: QEMU_VERSION=$QEMU_VERSION does not match tag $tag"
  [[ "$QEMU_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "releases/$tag.env: QEMU_SHA256 must be 64 lowercase hex digits"
  local p
  for p in $PATCHES; do
    [[ "$p" =~ ^[0-9]{4}-[A-Za-z0-9._-]+\.patch$ ]] || die "releases/$tag.env: bad patch name $p"
    [ -f "$PVMQ_ROOT/patches/$tag/$p" ] || die "patch patches/$tag/$p is missing"
  done
  export QEMU_VERSION QEMU_SHA256 PATCHES
}

# Release asset names.
host_asset() { echo "pvm-qemu-$1-$2.tar.gz"; }              # <tag> <host>
deps_asset() { echo "pvm-qemu-$1-$2-deps-source.tar"; }     # <tag> <host>
source_asset() { echo "pvm-qemu-$1-source.tar.gz"; }        # <tag>
