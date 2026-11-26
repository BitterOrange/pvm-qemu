#!/usr/bin/env python3
"""Write a reproducible tar archive of one directory.

    mktar.py --root PARENT --entry NAME --out FILE [--gzip] [--epoch N]

The archive holds NAME/ and everything below it, in sorted order, with
owner 0:0, no user or group names, and every mtime set to --epoch
(default: SOURCE_DATE_EPOCH, else 0). Directories get mode 0755; files get
0755 when they are executable (any exec bit, or .exe/.dll under bin/), else
0644. Symlinks and special files are refused: pvm accepts only regular files
and directories. With --gzip the stream is gzip-compressed with no name and
a zero timestamp, so the same tree always gives the same bytes.
"""

import argparse
import gzip
import io
import os
import stat
import sys
import tarfile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--entry", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--gzip", action="store_true")
    ap.add_argument("--epoch", type=int, default=int(os.environ.get("SOURCE_DATE_EPOCH", "0")))
    a = ap.parse_args()

    top = os.path.join(a.root, a.entry)
    if not os.path.isdir(top) or os.path.islink(top):
        sys.exit(f"error: {top} is not a directory")
    if "/" in a.entry or a.entry in ("", ".", ".."):
        sys.exit("error: --entry must be a single directory name")

    entries = []
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, a.root).replace(os.sep, "/")
        entries.append((rel_dir, dirpath))
        for name in sorted(filenames) + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            full = os.path.join(dirpath, name)
            entries.append((rel_dir + "/" + name, full))
    entries.sort(key=lambda e: e[0])

    raw = open(a.out, "wb")
    stream = gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) if a.gzip else raw
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for rel, full in entries:
            st = os.lstat(full)
            info = tarfile.TarInfo(rel)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = a.epoch
            if stat.S_ISDIR(st.st_mode):
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif stat.S_ISREG(st.st_mode):
                exe = bool(st.st_mode & 0o111)
                parts = rel.split("/")
                if len(parts) >= 3 and parts[1] == "bin" and rel.lower().endswith((".exe", ".dll")):
                    exe = True
                info.type = tarfile.REGTYPE
                info.mode = 0o755 if exe else 0o644
                info.size = st.st_size
                with open(full, "rb") as f:
                    tar.addfile(info, f)
            else:
                sys.exit(f"error: {rel} is not a regular file or directory")
    if a.gzip:
        stream.close()
    raw.close()
    print(f"wrote {a.out} ({len(entries)} entries)")


if __name__ == "__main__":
    main()
