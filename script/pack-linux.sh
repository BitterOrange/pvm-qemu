#!/usr/bin/env bash
# pack-linux.sh <prefix> <dest>
#
# Turns a QEMU installed under <prefix> into a relocatable tree at <dest>
# (normally .../x86_64): the real executables, their shared library closure
# including the ELF loader, sh wrappers that run the executables through the
# bundled loader, and the x86 firmware. Each copied library's original path
# is written to <dest>.origins for the source collection.
#
# Derived from pvm's script/qemu/pack-linux-runtime.sh.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

prefix=${1:?usage: pack-linux.sh <prefix> <dest>}
dest=${2:?}
system="$prefix/bin/qemu-system-x86_64"
img="$prefix/bin/qemu-img"
[ -x "$system" ] || die "$system not found"
[ -x "$img" ] || die "$img not found"
command -v patchelf >/dev/null 2>&1 || die "patchelf is required"
[ ! -e "$dest" ] || die "$dest already exists"

mkdir -p "$dest/bin" "$dest/lib" "$dest/share/qemu"
cp "$system" "$dest/bin/qemu-system-x86_64.real"
cp "$img" "$dest/bin/qemu-img.real"
"$PVMQ_ROOT/script/copy-firmware.sh" x86_64 "$prefix/share/qemu" "$dest/share/qemu"

origins="$dest.origins"
: > "$origins"
declare -A seen=()
queue=("$dest/bin/qemu-system-x86_64.real" "$dest/bin/qemu-img.real")
while [ ${#queue[@]} -gt 0 ]; do
  cur=${queue[0]}
  queue=("${queue[@]:1}")
  if ldd "$cur" 2>/dev/null | grep -q 'not found'; then
    ldd "$cur" >&2 || true
    die "unresolved shared library in $cur"
  fi
  while IFS= read -r dep; do
    [ -f "$dep" ] || continue
    name=$(basename "$dep")
    [ -z "${seen[$name]:-}" ] || continue
    seen[$name]=1
    cp -L "$dep" "$dest/lib/$name"
    printf '%s\t%s\t%s\n' "lib/$name" "$(readlink -f "$dep")" "$dep" >> "$origins"
    queue+=("$dest/lib/$name")
  done < <(ldd "$cur" 2>/dev/null | awk '/=> \// {print $3} /^\t\// {print $1}')
done
loader=$(patchelf --print-interpreter "$system")
[ -f "$loader" ] || die "cannot find the ELF interpreter $loader"
loader_name=$(basename "$loader")
if [ -z "${seen[$loader_name]:-}" ]; then
  cp -L "$loader" "$dest/lib/$loader_name"
  printf '%s\t%s\t%s\n' "lib/$loader_name" "$(readlink -f "$loader")" "$loader" >> "$origins"
fi

patchelf --set-rpath '$ORIGIN/../lib' "$dest/bin/qemu-system-x86_64.real" "$dest/bin/qemu-img.real"
for name in qemu-system-x86_64 qemu-img; do
  data=""
  [ "$name" = qemu-system-x86_64 ] && data=' -L "$here/../share/qemu"'
  cat > "$dest/bin/$name" <<EOF
#!/bin/sh
here=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
exec "\$here/../lib/$loader_name" --library-path "\$here/../lib" "\$here/$name.real"$data "\$@"
EOF
  chmod 0755 "$dest/bin/$name"
done
chmod 0755 "$dest/bin/"*.real "$dest/lib/$loader_name"

"$dest/bin/qemu-system-x86_64" --version >/dev/null
"$dest/bin/qemu-img" --version >/dev/null
echo "packed $(wc -l < "$origins") libraries into $dest"
