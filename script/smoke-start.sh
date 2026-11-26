#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# smoke-start.sh <x86_64-tree>
#
# A minimal start test for a Linux build that needs nothing but sh: QEMU
# must still be running 3 s after a paused TCG start with a user netdev,
# virtio-net and virtio-gpu. Used where smoke.py cannot run: inside other
# distributions' containers and in the isolated probe.
set -eu
tree=${1:?usage: smoke-start.sh <x86_64-tree>}
log=$(mktemp)
"$tree/bin/qemu-system-x86_64" -machine q35,accel=tcg -display none \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 -device virtio-gpu-pci -S >"$log" 2>&1 &
pid=$!
sleep 3
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  rm -f "$log"
  echo "QEMU started from $tree"
else
  wait "$pid" 2>/dev/null || true
  cat "$log" >&2
  rm -f "$log"
  echo "error: QEMU from $tree did not start" >&2
  exit 1
fi
