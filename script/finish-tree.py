#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Complete a packed tree into its release form.

    finish-tree.py --tree DIR --tag TAG --host HOST --src QEMU_SRC
                   --configure FILE [--minos X] [--env KEY=VALUE ...]

Writes VERSION (the tag), doc/COPYING, doc/COPYING.LIB, doc/LICENSE,
doc/SOURCE.txt and pvm-qemu.json, then SHA256SUMS over every other file.
It fails when the tree breaks a rule that pvm relies on:

  - only regular files and directories, no symlinks;
  - the emulator, qemu-img and the firmware where pvm v1.3.x looks for them;
  - executables carry an exec bit (macOS and Linux);
  - every shipped library is listed in doc/THIRD-PARTY.txt.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "BitterOrange/pvm-qemu"

HOSTS = {
    "darwin-arm64": {
        "arch": "aarch64", "target": "aarch64-softmmu",
        "system": "bin/qemu-system-aarch64", "system_exec": "bin/qemu-system-aarch64",
        "img": "bin/qemu-img", "firmware_dir": "share/qemu",
        "firmware": "edk2-aarch64-code.fd", "accels": ["hvf", "tcg"], "virtio_9p": True,
    },
    "linux-amd64": {
        "arch": "x86_64", "target": "x86_64-softmmu",
        "system": "bin/qemu-system-x86_64", "system_exec": "bin/qemu-system-x86_64.real",
        "img": "bin/qemu-img", "firmware_dir": "share/qemu",
        "firmware": "bios-256k.bin", "accels": ["kvm", "tcg"], "virtio_9p": True,
    },
    "windows-amd64": {
        "arch": "x86_64", "target": "x86_64-softmmu",
        "system": "bin/qemu-system-x86_64.exe", "system_exec": "bin/qemu-system-x86_64.exe",
        "img": "bin/qemu-img.exe", "firmware_dir": "bin/share",
        "firmware": "bios-256k.bin", "accels": ["whpx", "tcg"], "virtio_9p": False,
    },
}


def die(msg):
    sys.exit(f"error: {msg}")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_env(tag):
    env = {}
    with open(os.path.join(ROOT, "releases", tag + ".env"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                k, _, v = line.partition("=")
                env[k] = v
    return env


def walk(tree):
    """Yield (relative posix path, full path) of every file, sorted."""
    out = []
    for dirpath, dirnames, filenames in os.walk(tree):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            st = os.lstat(full)
            rel = os.path.relpath(full, tree).replace(os.sep, "/")
            if stat.S_ISLNK(st.st_mode):
                die(f"{rel} is a symlink; the archive may hold only files and directories")
            if stat.S_ISREG(st.st_mode):
                out.append((rel, full))
            elif not stat.S_ISDIR(st.st_mode):
                die(f"{rel} is not a regular file or directory")
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--host", required=True, choices=sorted(HOSTS))
    ap.add_argument("--src", required=True, help="the QEMU source directory")
    ap.add_argument("--configure", required=True, help="file with the configure arguments")
    ap.add_argument("--minos", default="")
    ap.add_argument("--env", action="append", default=[], help="build_env KEY=VALUE")
    a = ap.parse_args()

    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?-pvm[0-9]+", a.tag):
        die(f"invalid tag {a.tag}")
    h = HOSTS[a.host]
    tree = a.tree
    if os.path.basename(os.path.normpath(tree)) != h["arch"]:
        die(f"the tree for {a.host} must be a directory named {h['arch']}")
    env = read_env(a.tag)
    version = env["QEMU_VERSION"]

    for rel in (h["system"], h["system_exec"], h["img"], h["firmware_dir"] + "/" + h["firmware"]):
        p = os.path.join(tree, rel)
        if not os.path.isfile(p) or os.path.getsize(p) == 0:
            die(f"{rel} is missing")

    doc = os.path.join(tree, "doc")
    os.makedirs(doc, exist_ok=True)
    for name in ("COPYING", "COPYING.LIB", "LICENSE"):
        shutil.copyfile(os.path.join(a.src, name), os.path.join(doc, name))
    third = os.path.join(doc, "THIRD-PARTY.txt")
    if not os.path.isfile(third):
        die("doc/THIRD-PARTY.txt is missing; run collect-dep-sources.sh first")

    source_assets = [f"pvm-qemu-{a.tag}-source.tar.gz", f"pvm-qemu-{a.tag}-{a.host}-deps-source.tar"]
    with open(os.path.join(doc, "SOURCE.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(
            f"This is QEMU {version}, built by the pvm-qemu project as {a.tag}.\n"
            "QEMU is licensed under the GNU General Public License, version 2\n"
            "(doc/COPYING); doc/LICENSE lists the licenses of its parts.\n\n"
            "The complete corresponding source is published in the same release:\n\n"
            f"  https://github.com/{REPO}/releases/tag/{a.tag}\n\n"
            f"  {source_assets[0]}\n"
            "      the upstream QEMU tarball and its signature, the patches, and\n"
            "      the build scripts of this repository at the tag\n"
            f"  {source_assets[1]}\n"
            "      the source of every library in doc/THIRD-PARTY.txt\n"
        )

    with open(os.path.join(ROOT, "keys", "FINGERPRINT"), encoding="utf-8") as f:
        fingerprint = f.read().strip()
    upstream_tarball = f"qemu-{version}.tar.xz"
    patches = []
    for p in env.get("PATCHES", "").split():
        path = os.path.join(ROOT, "patches", a.tag, p)
        with open(path, encoding="utf-8") as f:
            m = re.search(r"^Upstream: ([0-9a-f]{40})$", f.read(), re.M)
        patches.append({"file": p, "sha256": sha256(path), "upstream_commit": m.group(1)})
    with open(a.configure, encoding="utf-8") as f:
        configure = [l.strip() for l in f if l.strip()]
    build_env = {}
    for kv in a.env:
        k, sep, v = kv.partition("=")
        if not sep or not re.fullmatch(r"[a-z_]+", k):
            die(f"bad --env {kv}")
        build_env[k] = v
    if a.minos:
        build_env["macos_minos"] = a.minos

    manifest = {
        "schema": 1,
        "build": a.tag,
        "qemu_version": version,
        "host": a.host,
        "target": h["target"],
        "upstream": {"tarball": upstream_tarball, "sha256": env["QEMU_SHA256"], "signing_key": fingerprint},
        "patches": patches,
        "configure": configure,
        "system": h["system"],
        "system_exec": h["system_exec"],
        "img": h["img"],
        "firmware_dir": h["firmware_dir"],
        "declares": {"virtio_9p": h["virtio_9p"], "slirp": True, "accels": h["accels"]},
        "build_env": build_env,
        "source_assets": source_assets,
    }
    with open(os.path.join(tree, "pvm-qemu.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    with open(os.path.join(tree, "VERSION"), "w", encoding="utf-8", newline="\n") as f:
        f.write(a.tag + "\n")

    sums = os.path.join(tree, "SHA256SUMS")
    if os.path.exists(sums):
        os.remove(sums)
    files = walk(tree)

    listed = set()
    with open(third, encoding="utf-8") as f:
        for line in f:
            listed.add(line.split("\t", 1)[0])
    for rel, full in files:
        lib = (rel.startswith("lib/") and "/" not in rel[4:]) or (rel.startswith("bin/") and rel.lower().endswith(".dll"))
        if lib and rel not in listed:
            die(f"{rel} is not listed in doc/THIRD-PARTY.txt")
        if a.host != "windows-amd64" and rel.startswith("bin/") and not os.stat(full).st_mode & 0o111:
            die(f"{rel} is not executable")

    with open(sums, "w", encoding="utf-8", newline="\n") as f:
        for rel, full in files:
            f.write(f"{sha256(full)}  {rel}\n")
    print(f"finished {a.host} tree: {len(files)} files")


if __name__ == "__main__":
    main()
