#!/usr/bin/env python3
"""Check that a finished tree runs what pvm runs.

    smoke.py TREE [--accel tcg|hvf|kvm|whpx] [--skip-sums]

TREE is the <arch> directory of a build (aarch64 or x86_64), as extracted
from the archive. The checks, in order:

  1. SHA256SUMS matches every file and lists every file.
  2. `--version` reports the manifest's qemu_version.
  3. The help output lists the accelerators, machine, netdevs, devices and
     objects pvm uses, and agrees with the manifest's declares (virtio-9p
     present exactly when declared).
  4. qemu-img creates an overlay and converts it with both -B and -b.
  5. QEMU starts paused with pvm's own argv (smbios, a serial chardev socket
     with logfile, virtio disk and seed, rng, QMP, virtio-gpu, balloon with
     free-page reporting, the agent and stream ports, hotplug root ports and,
     where declared, a 9p fsdev), once with a user netdev and once with a
     stream netdev as in a cluster. Over QMP it then adds a host forward
     with hostfwd_add, hot-plugs a NIC onto a root port, and quits.

TCG is the default accelerator, so this runs on CI machines without
virtualization. On a real host, --accel hvf|kvm|whpx uses pvm's arguments
for that accelerator instead.
"""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

WINDOWS = sys.platform == "win32"
failures = []


def check(cond, what):
    print(("ok: " if cond else "FAIL: ") + what, flush=True)
    if not cond:
        failures.append(what)
    return cond


def run(argv, cwd=None, timeout=20):
    p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_sums(tree):
    listed = {}
    with open(os.path.join(tree, "SHA256SUMS"), encoding="utf-8") as f:
        for line in f:
            digest, rel = line.rstrip("\n").split("  ", 1)
            listed[rel] = digest
    present = set()
    for dirpath, _, filenames in os.walk(tree):
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), tree).replace(os.sep, "/")
            if rel != "SHA256SUMS":
                present.add(rel)
    check(present == set(listed), f"SHA256SUMS lists exactly the {len(present)} files in the tree")
    bad = [rel for rel, d in listed.items() if rel in present and sha256(os.path.join(tree, rel)) != d]
    check(not bad, "every file matches SHA256SUMS" + (f" (mismatch: {', '.join(bad[:5])})" if bad else ""))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class QMP:
    def __init__(self, endpoint, deadline):
        while True:
            try:
                if endpoint.startswith("tcp:"):
                    self.sock = socket.create_connection(("127.0.0.1", int(endpoint[4:])), timeout=5)
                else:
                    self.sock = socket.socket(socket.AF_UNIX)
                    self.sock.settimeout(5)
                    self.sock.connect(endpoint)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.1)
        self.f = self.sock.makefile("rwb")
        greeting = self.read()
        assert "QMP" in greeting, greeting
        self.cmd("qmp_capabilities")

    def read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise EOFError("QMP closed")
            msg = json.loads(line)
            if "event" not in msg:
                return msg

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.f.write(json.dumps(req).encode() + b"\n")
        self.f.flush()
        msg = self.read()
        if "error" in msg:
            raise RuntimeError(f"{name}: {msg['error'].get('desc')}")
        return msg.get("return")

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line})


def accel_args(accel, arm):
    """pvm's arguments for the accelerator (internal/qemu/accel.go)."""
    if accel == "tcg":
        return ["-accel", "tcg,thread=multi", "-cpu", "max"]
    if accel == "whpx":
        return ["-accel", "whpx,kernel-irqchip=off", "-machine", "vmport=off", "-cpu", "host,-xsave", "-no-reboot"]
    return ["-accel", accel, "-cpu", "host"]


def start_test(m, tree, work, accel, cluster):
    """Start QEMU paused with pvm's argv, poke it over QMP, quit."""
    arm = m["target"].startswith("aarch64")
    system = os.path.join(tree, m["system"])
    fw = os.path.join(tree, m["firmware_dir"])
    name = "cluster" if cluster else "user"
    d = os.path.join(work, name)
    os.makedirs(d)
    disk = os.path.join(d, "disk.qcow2")
    seed = os.path.join(d, "seed.img")
    rc, out = run([os.path.join(tree, m["img"]), "create", "-q", "-f", "qcow2", disk, "1G"])
    if not check(rc == 0, f"{name}: qemu-img create the disk"):
        print(out)
        return
    with open(seed, "wb") as f:
        f.truncate(1 << 20)

    def endpoint(tag):
        return "tcp:%d" % free_port() if WINDOWS else os.path.join(d, tag + ".sock")

    def chardev(cid, ep, logfile=""):
        if ep.startswith("tcp:"):
            s = f"socket,id={cid},host=127.0.0.1,port={ep[4:]},server=on,wait=off,nodelay=on"
        else:
            s = f"socket,id={cid},path={ep},server=on,wait=off"
        return s + (f",logfile={logfile}" if logfile else "")

    qmp_ep = endpoint("qmp")
    args = []
    if arm:
        vars_fd = os.path.join(d, "vars.fd")
        with open(vars_fd, "wb") as f:
            f.truncate(64 << 20)
        args += ["-machine", "virt",
                 "-drive", "if=pflash,format=raw,readonly=on,file=" + os.path.join(fw, "edk2-aarch64-code.fd"),
                 "-drive", "if=pflash,format=raw,file=" + vars_fd]
    else:
        args += ["-machine", "q35"]
    args += ["-L", fw] + accel_args(accel, arm)
    args += ["-smbios", "type=0,vendor=Dell Inc.,version=2.7.0,date=03/16/2023",
             "-smbios", "type=1,manufacturer=Dell Inc.,product=OptiPlex 7010,version=01",
             "-smbios", "type=2,manufacturer=Dell Inc.,product=0GY6YJ,version=A01",
             "-smbios", "type=3,manufacturer=Dell Inc.,version=01"]
    args += ["-m", "512", "-smp", "2", "-display", "none",
             "-chardev", chardev("ser0", endpoint("serial"), os.path.join(d, "console.log")),
             "-serial", "chardev:ser0",
             "-drive", f"file={disk},format=qcow2,if=virtio,cache=writeback,discard=unmap,detect-zeroes=unmap",
             "-drive", f"file={seed},format=raw,if=virtio,readonly=on",
             "-object", "rng-builtin,id=rng0" if WINDOWS else "rng-random,id=rng0,filename=/dev/urandom",
             "-device", "virtio-rng-pci,rng=rng0",
             "-qmp", (f"tcp:127.0.0.1:{qmp_ep[4:]},server=on,wait=off" if WINDOWS else f"unix:{qmp_ep},server=on,wait=off"),
             "-device", "virtio-gpu-pci",
             "-device", "virtio-balloon-pci,free-page-reporting=on",
             "-device", "virtio-serial-pci",
             "-chardev", chardev("pvmagent", endpoint("agent")),
             "-device", "virtserialport,chardev=pvmagent,name=pvm.agent",
             "-chardev", chardev("pvmstream", endpoint("stream")),
             "-device", "virtserialport,chardev=pvmstream,name=pvm.stream"]

    listener = None
    accepted = []
    if cluster:
        if WINDOWS:
            listener = socket.socket()
            listener.bind(("127.0.0.1", 0))
            netdev = "stream,id=net0,server=off,addr.type=inet,addr.host=127.0.0.1,addr.port=%d" % listener.getsockname()[1]
        else:
            path = os.path.join(d, "link.sock")
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(path)
            netdev = f"stream,id=net0,server=off,addr.type=unix,addr.path={path}"
        listener.listen(1)
        threading.Thread(target=lambda: accepted.append(listener.accept()), daemon=True).start()
        args += ["-device", "pcie-root-port,id=rp-link,bus=pcie.0,addr=0x1e.0,chassis=96",
                 "-netdev", netdev,
                 "-device", "virtio-net-pci,id=nic0,netdev=net0,mac=52:54:00:12:34:56,bus=rp-link"]
    else:
        args += ["-netdev", "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:%d-:22" % free_port(),
                 "-device", "virtio-net-pci,netdev=net0"]
    for i in range(2):
        mf = ",multifunction=on" if i == 0 else ""
        args += ["-device", f"pcie-root-port,id=rp{10 + i},bus=pcie.0,addr=0x8.{i},chassis={i + 1}{mf}"]
    if m["declares"]["virtio_9p"] and not cluster:
        share = os.path.join(d, "share")
        os.makedirs(share)
        args += ["-device", "pcie-root-port,id=rp-share,bus=pcie.0,addr=0x10,chassis=128",
                 "-fsdev", f"local,id=fs0,path={share},security_model=none,readonly=off",
                 "-device", "virtio-9p-pci-non-transitional,id=fs0,fsdev=fs0,mount_tag=share,bus=rp-share"]
    args += ["-S"]

    log = open(os.path.join(d, "qemu.log"), "w")
    proc = subprocess.Popen([system] + args, stdout=log, stderr=subprocess.STDOUT)
    ok = False
    try:
        time.sleep(3)
        if not check(proc.poll() is None, f"{name}: QEMU is still running 3 s after start ({accel})"):
            return
        q = QMP(qmp_ep, time.time() + 10)
        status = q.cmd("query-status")
        check(status.get("status") == "prelaunch", f"{name}: QMP query-status is prelaunch (got {status.get('status')})")
        if cluster:
            check(bool(accepted), f"{name}: the stream netdev connected to its peer")
        else:
            port = free_port()
            out = q.hmp(f"hostfwd_add net0 tcp:127.0.0.1:{port}-:{port}")
            check(out.strip() == "", f"{name}: hostfwd_add succeeds silently")
            # Read the rows as pvm's parseHostForwards does: the FD column
            # is a socket handle, printed in hex on Windows.
            out = q.hmp("info usernet")
            rows = [l.split() for l in out.splitlines()]
            listed = any(len(f) >= 4 and f[0] == "TCP[HOST_FORWARD]" and f[2] == "127.0.0.1" and f[3] == str(port) for f in rows)
            if not check(listed, f"{name}: info usernet lists the new forward"):
                print(out)
        q.cmd("netdev_add", type="user", id="hp0")
        q.cmd("device_add", driver="virtio-net-pci", id="hpnic", netdev="hp0", bus="rp10")
        check(True, f"{name}: hot-plugged a NIC onto a root port")
        try:
            q.cmd("quit")
        except (EOFError, OSError):
            pass
        proc.wait(timeout=10)
        ok = check(proc.returncode == 0, f"{name}: QEMU quit cleanly (exit {proc.returncode})")
    except Exception as e:  # report and fall through to the log
        check(False, f"{name}: {type(e).__name__}: {e}")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        log.close()
        if listener:
            listener.close()
        if not ok:
            with open(os.path.join(d, "qemu.log"), encoding="utf-8", errors="replace") as f:
                print(f"--- {name} qemu.log ---\n{f.read()}--- end ---")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tree")
    ap.add_argument("--accel", default="tcg", choices=["tcg", "hvf", "kvm", "whpx"])
    ap.add_argument("--skip-sums", action="store_true", help="skip the SHA256SUMS check (local experiments)")
    a = ap.parse_args()
    tree = os.path.abspath(a.tree)
    with open(os.path.join(tree, "pvm-qemu.json"), encoding="utf-8") as f:
        m = json.load(f)
    want = {"darwin-arm64": ("darwin", "arm64"), "linux-amd64": ("linux", "x86_64"), "windows-amd64": ("win32", "amd64")}[m["host"]]
    here = (sys.platform, platform.machine().lower())
    if here != want:
        sys.exit(f"error: this is a {m['host']} build; it cannot run on {here[0]}/{here[1]}")
    system = os.path.join(tree, m["system"])
    img = os.path.join(tree, m["img"])
    print(f"smoke test of {m['build']} ({m['host']}) at {tree}")

    if not a.skip_sums:
        check_sums(tree)

    rc, out = run([system, "--version"])
    v = re.search(r"QEMU emulator version (\S+)", out)
    if "-rc" in m["qemu_version"]:
        check(rc == 0 and v is not None, f"--version runs ({v.group(1) if v else out.strip()})")
    else:
        check(rc == 0 and v is not None and v.group(1) == m["qemu_version"],
              f"--version reports {m['qemu_version']} (got {v.group(1) if v else out.strip()!r})")
    rc, out = run([img, "--version"])
    check(rc == 0 and "qemu-img version" in out, "qemu-img --version runs")

    def help_of(opt):
        rc, out = run([system, opt, "help"])
        return out if rc == 0 else ""

    accels = {w.strip() for w in help_of("-accel").splitlines()[1:]}
    for acc in m["declares"]["accels"]:
        check(acc in accels, f"-accel help lists {acc}")
    machines = {l.split()[0] for l in help_of("-machine").splitlines()[1:] if l.strip()}
    check(("virt" if m["target"].startswith("aarch64") else "q35") in machines, "-machine help lists pvm's machine")
    netdevs = {w.strip() for w in help_of("-netdev").splitlines()[1:]}
    for nd in ("user", "stream"):
        check(nd in netdevs, f"-netdev help lists {nd}")
    devices = set(re.findall(r'^name "([^"]+)"', help_of("-device"), re.M))
    for dev in ("virtio-net-pci", "virtio-rng-pci", "virtio-serial-pci", "virtserialport",
                "virtio-balloon-pci", "virtio-gpu-pci", "pcie-root-port", "virtio-blk-pci"):
        check(dev in devices, f"-device help lists {dev}")
    has9p = "virtio-9p-pci-non-transitional" in devices
    check(has9p == m["declares"]["virtio_9p"],
          f"virtio-9p is {'present' if has9p else 'absent'}, as the manifest declares")
    objects = {w.strip() for w in help_of("-object").splitlines()[1:]}
    rng = "rng-builtin" if WINDOWS else "rng-random"
    check(rng in objects, f"-object help lists {rng}")
    check(os.path.isfile(os.path.join(tree, m["firmware_dir"], "bios-256k.bin" if m["target"].startswith("x86") else "edk2-aarch64-code.fd")),
          "the firmware is in firmware_dir")

    work = tempfile.mkdtemp(prefix="pq", dir=None if WINDOWS else "/tmp")
    try:
        img_cmd = lambda *args: run([img] + list(args), cwd=work)
        rc1, o1 = img_cmd("create", "-q", "-f", "qcow2", "base.qcow2", "64M")
        rc2, o2 = img_cmd("create", "-q", "-f", "qcow2", "-b", "base.qcow2", "-F", "qcow2", "top.qcow2")
        check(rc1 == 0 and rc2 == 0, "qemu-img creates a base and an overlay" + ("" if rc1 == rc2 == 0 else f": {o1}{o2}"))
        for flag in ("-B", "-b"):
            out_img = f"out{flag[1]}.qcow2"
            rc, out = img_cmd("convert", "-f", "qcow2", "-O", "qcow2", flag, "base.qcow2", "-F", "qcow2", "top.qcow2", out_img)
            info = {}
            if rc == 0:
                rc_i, o = img_cmd("info", "--output=json", out_img)
                info = json.loads(o) if rc_i == 0 else {}
            check(rc == 0 and info.get("backing-filename") == "base.qcow2",
                  f"qemu-img convert {flag} keeps the backing file" + ("" if rc == 0 else f": {out.strip()}"))
        start_test(m, tree, work, a.accel, cluster=False)
        start_test(m, tree, work, a.accel, cluster=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        sys.exit(f"{len(failures)} check(s) failed")
    print("all checks passed")


if __name__ == "__main__":
    main()
