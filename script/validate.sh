#!/usr/bin/env bash
# validate.sh - run a pvm-qemu build under an unchanged pvm v1.3.x on a real
# HVF, KVM or WHPX host. On Windows, run it from Git Bash.
#
#   validate.sh install <archive> [--no-attest]
#       Puts the archive's tree into pvm's runtime slot
#       (<PVM_HOME>/runtime/qemu/<arch>). The current slot is moved aside to
#       <arch>.pre-pvm-qemu, never deleted. Refuses while any QEMU runs from
#       the slot. The archive's attestation is checked with gh unless
#       --no-attest (for a CI artifact that is not a release yet).
#   validate.sh run [--vm NAME] [--image IMAGE] [--mem MB] [--cpus N]
#                   [--exit EXIT] [--keep] [--allow-tcg]
#       Runs the cycle on a new VM (default pvmqemu-check, ubuntu:26.04):
#       create with bake, start and readiness, ssh, the /share and pvm mount
#       9p paths (macOS, Linux), a port map, an exit route with a tunnel-loss
#       check (with --exit, interactive), a RAM snapshot and its restore (not
#       on Windows, where QEMU cannot migrate WHPX VMs),
#       compact, and removal (unless --keep). Logs to validate-<host>-<time>.log.
#       --mem and --cpus size the VM (pvm's defaults otherwise). --allow-tcg
#       skips the hardware accelerator check, for machines without one, such
#       as GitHub's macOS runners.
#   validate.sh restore
#       Puts the original slot back. The pvm-qemu tree is kept as
#       <arch>.pvm-qemu-<tag>-<time>.
#   validate.sh status
#       Shows what is in the slot and pvm daemon status.
set -euo pipefail

die() { echo "validate: $*" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)

case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) host=darwin-arm64 arch=aarch64 sys=qemu-system-aarch64 ;;
  Linux/x86_64) host=linux-amd64 arch=x86_64 sys=qemu-system-x86_64 ;;
  MINGW64_NT-*/x86_64|MSYS_NT-*/x86_64) host=windows-amd64 arch=x86_64 sys=qemu-system-x86_64.exe ;;
  *) die "unsupported host $(uname -s)/$(uname -m)" ;;
esac
pvm_home=${PVM_HOME:-$HOME/.pvm}
root="$pvm_home/runtime/qemu"
slot="$root/$arch"
saved="$root/$arch.pre-pvm-qemu"

pvm_version() { pvm version 2>/dev/null || true; }
require_v13() {
  local v; v=$(pvm_version)
  [[ "$v" == v1.3.* ]] || die "this checks a build under pvm v1.3.x; pvm version is '${v:-not found}'"
}

# Every running QEMU whose command line points into the slot.
qemu_from_slot() {
  if [ "$host" = windows-amd64 ]; then
    powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='$sys'\" | ForEach-Object { \$_.ExecutablePath }" 2>/dev/null |
      tr -d '\r' | grep -iF "$(cygpath -w "$slot")\\" || true
  else
    ps -eo pid=,args= | grep -F "$slot/" | grep -v grep || true
  fi
}
require_idle() {
  local running; running=$(qemu_from_slot)
  [ -z "$running" ] || die "QEMU still runs from $slot; stop those VMs first (pvm stop <vm>):
$running"
}
daemon_stop() { pvm daemon status >/dev/null 2>&1 && pvm daemon stop || true; }

cmd_install() {
  local archive=${1:?usage: validate.sh install <archive> [--no-attest]} attest=1
  [ "${2:-}" = --no-attest ] && attest=0
  [ -f "$archive" ] || die "$archive not found"
  local name; name=$(basename "$archive")
  [[ "$name" =~ ^pvm-qemu-([0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?-pvm[0-9]+)-$host\.tar\.gz$ ]] ||
    die "$name is not a pvm-qemu archive for $host"
  local tag=${BASH_REMATCH[1]}
  require_v13
  if [ "$attest" = 1 ]; then
    gh attestation verify "$archive" --repo BitterOrange/pvm-qemu \
      --signer-workflow BitterOrange/pvm-qemu/.github/workflows/release.yml \
      --source-ref "refs/tags/$tag" --deny-self-hosted-runners --hostname github.com ||
      die "attestation check failed"
  fi
  [ ! -e "$saved" ] && [ ! -L "$saved" ] || die "$saved exists: a previous validation was not restored (validate.sh restore)"
  require_idle
  mkdir -p "$root"
  local stage; stage=$(mktemp -d "$root/.pvmq-validate.XXXXXX")
  tar -xzf "$archive" -C "$stage"
  [ "$(ls "$stage")" = "$arch" ] || { rm -rf "$stage"; die "the archive does not hold exactly $arch/"; }
  [ "$(cat "$stage/$arch/VERSION")" = "$tag" ] || { rm -rf "$stage"; die "VERSION in the archive is not $tag"; }
  (cd "$stage/$arch" && if command -v sha256sum >/dev/null; then sha256sum -c --quiet SHA256SUMS; else shasum -a 256 -c --quiet SHA256SUMS; fi) ||
    { rm -rf "$stage"; die "the extracted files do not match SHA256SUMS"; }
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    "$(command -v python3 || command -v python)" "$here/smoke.py" "$stage/$arch" || { rm -rf "$stage"; die "smoke test failed"; }
  fi
  daemon_stop
  require_idle
  if [ -e "$slot" ] || [ -L "$slot" ]; then mv "$slot" "$saved"; fi
  mv "$stage/$arch" "$slot"
  rmdir "$stage"
  echo "installed $tag into $slot; the previous slot is $saved"
  pvm daemon start
  pvm daemon status
}

cmd_restore() {
  [ -e "$saved" ] || [ -L "$saved" ] || die "nothing to restore: $saved does not exist"
  require_idle
  daemon_stop
  require_idle
  local tag; tag=$(cat "$slot/VERSION" 2>/dev/null || echo unknown)
  local keep
  keep="$root/$arch.pvm-qemu-$tag-$(date +%Y%m%d%H%M%S)"
  mv "$slot" "$keep"
  mv "$saved" "$slot"
  echo "restored the original slot; the pvm-qemu tree is kept at $keep"
  pvm daemon start
  pvm daemon status
}

cmd_status() {
  echo "pvm: $(pvm_version)"
  echo "slot: $slot"
  [ -f "$slot/VERSION" ] && echo "  VERSION $(cat "$slot/VERSION")"
  [ -f "$slot/pvm-qemu.json" ] && echo "  pvm-qemu build" || echo "  not a pvm-qemu build"
  [ -e "$saved" ] && echo "saved original: $saved"
  pvm daemon status || true
}

cmd_run() {
  local vm=pvmqemu-check image=ubuntu:26.04 exit_name="" keep=0 allow_tcg=0
  local size=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --vm) vm=$2; shift 2 ;;
      --image) image=$2; shift 2 ;;
      --exit) exit_name=$2; shift 2 ;;
      --keep) keep=1; shift ;;
      --mem|--cpus) size+=("$1" "$2"); shift 2 ;;
      --allow-tcg) allow_tcg=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  require_v13
  [ -f "$slot/pvm-qemu.json" ] || die "$slot is not a pvm-qemu build; run validate.sh install first"
  local log; log="$PWD/validate-$host-$(date +%Y%m%d%H%M%S).log"
  local fails=0
  exec > >(tee -a "$log") 2>&1
  echo "validate $(cat "$slot/VERSION") on $host with pvm $(pvm_version), vm $vm, image $image"
  step() {
    local what=$1; shift
    local t0; t0=$(date +%s)
    echo "== $what"
    if "$@"; then echo "ok: $what ($(( $(date +%s) - t0 )) s)"; else echo "FAIL: $what"; fails=$((fails + 1)); return 1; fi
  }
  in_vm() { pvm ssh "$vm" "$@"; }
  pvm ls 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx "$vm" && die "VM $vm already exists; choose another with --vm"

  hw_accel() {
    local line; line=$(pvm daemon status | grep -i 'accel:')
    echo "$line"
    [ -n "$line" ] && ! echo "$line" | grep -qi tcg
  }
  vm_status() { pvm ls 2>/dev/null | awk -v vm="$vm" '$1 == vm {print $4}'; }
  # A snapshot counts only when the VM stopped and snapshot ls lists it
  # unconsumed; a failed snapshot leaves the VM running with its memory
  # intact, which would make the restore checks pass by themselves.
  snapshot_saved() {
    pvm snapshot create "$vm" || return 1
    [ "$(vm_status)" = stopped ] || { echo "the VM is $(vm_status), not stopped"; return 1; }
    pvm snapshot ls "$vm" | awk -v vm="$vm" '$1 == vm && $NF == "false" {ok = 1} END {exit !ok}' ||
      { pvm snapshot ls "$vm"; echo "snapshot ls does not list an unconsumed snapshot of $vm"; return 1; }
  }
  snapshot_restored() {
    pvm start "$vm" || return 1
    pvm snapshot ls "$vm" | awk -v vm="$vm" '$1 == vm && $NF == "true" {ok = 1} END {exit !ok}' ||
      { pvm snapshot ls "$vm"; echo "the start did not consume the snapshot"; return 1; }
  }
  from_slot() { [ -n "$(qemu_from_slot)" ]; }
  share_works() { in_vm "echo $1 > /share/pvmq-test" && grep -qx "$1" "$pvm_home/vms/$vm/share/pvmq-test"; }
  mount_works() { pvm mount "$vm" "$2:/home/dev/pvmq" && in_vm 'cat /home/dev/pvmq/from-host' | grep -qx "$1"; }
  map_works() { pvm map "$vm" 18734:18734 && sleep 2 && curl -fsS -m 10 -o /dev/null http://127.0.0.1:18734/; }
  egress() { in_vm 'curl -fsS -m 15 -o /dev/null https://example.com/'; }
  no_egress() { ! in_vm 'curl -fsS -m 10 -o /dev/null https://example.com/'; }
  egress_back() { in_vm 'curl -fsS -m 30 -o /dev/null --retry 5 --retry-all-errors https://example.com/'; }
  ram_kept() { in_vm 'cat /dev/shm/pvmq-mark' | grep -qx "$1"; }

  step "create $vm (bakes the golden image if needed)" pvm create --image "$image" --name "$vm" --user dev "${size[@]}" || { echo "cannot continue"; exit 1; }
  if [ "$allow_tcg" = 1 ]; then
    echo "accelerator not checked (--allow-tcg): $(pvm daemon status | grep -i accel)"
  else
    step "daemon reports a hardware accelerator, not tcg" hw_accel || true
  fi
  step "ssh runs a command" in_vm 'uname -a && nproc && free -m | head -2' || true
  step "QEMU runs from the slot" from_slot || true
  if [ "$host" != windows-amd64 ]; then
    local mark mdir
    mark="pvmq-$RANDOM$RANDOM"
    mdir=$(mktemp -d)
    echo "$mark" > "$mdir/from-host"
    step "/share is the VM's 9p share" share_works "$mark" || true
    step "pvm mount adds a 9p mount" mount_works "$mark" "$mdir" || true
    step "pvm mount rm removes it" pvm mount rm "$vm" /home/dev/pvmq || true
    rm -rf "$mdir"
  fi
  in_vm 'nohup python3 -m http.server 18734 >/dev/null 2>&1 &' || true
  step "port map reaches a server in the VM" map_works || true
  pvm map rm 18734 >/dev/null 2>&1 || true
  if [ -n "$exit_name" ]; then
    step "route through $exit_name" pvm route "$vm" --via "$exit_name" || true
    step "egress works through $exit_name" egress || true
    if [ -t 0 ]; then
      read -r -p "Stop the exit agent on the VPS now, then press Enter. " _
      sleep 25
      step "with the tunnel down the VM has no network (fail-closed)" no_egress || true
      read -r -p "Start the exit agent again, then press Enter. " _
      sleep 25
      step "egress recovers when the tunnel is back" egress_back || true
    else
      echo "skipped the tunnel-loss check: not a terminal"
    fi
  fi
  if [ "$host" = windows-amd64 ]; then
    # QEMU's WHPX backend registers a migration blocker for every VM
    # ("missing dirty memory tracking support"), in every release so far.
    echo "skipped RAM snapshots: QEMU cannot migrate WHPX VMs, so pvm has no RAM snapshots on native Windows"
  else
    local ram
    ram="pvmq-ram-$RANDOM$RANDOM"
    in_vm "echo $ram > /dev/shm/pvmq-mark" || true
    if step "snapshot create stops the VM and saves a snapshot" snapshot_saved; then
      step "start restores the snapshot" snapshot_restored || true
      step "RAM content survived the snapshot" ram_kept "$ram" || true
    else
      echo "skipped the restore checks: no snapshot was saved"
    fi
  fi
  step "stop" pvm stop "$vm" || true
  step "compact" pvm compact "$vm" || true
  step "start after compact" pvm start "$vm" || true
  step "ssh after compact" in_vm true || true
  if [ "$host" = windows-amd64 ]; then
    echo "by hand on Windows: pvm app $vm xterm opens a window (if the VM has apps), then close it"
  fi
  if [ "$keep" = 0 ]; then
    step "remove $vm" pvm rm "$vm" -y || true
  fi
  echo "== $fails failure(s); log: $log"
  [ "$fails" = 0 ]
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  run) shift; cmd_run "$@" ;;
  restore) shift; cmd_restore ;;
  status) shift; cmd_status ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
