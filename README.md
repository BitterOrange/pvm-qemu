# pvm-qemu

QEMU builds for [pvm](https://github.com/BitterOrange/pvm), compiled in GitHub Actions from the signed upstream QEMU release, for the three hosts pvm runs on:

| Host | Accelerator | Archive |
|---|---|---|
| macOS arm64 | HVF | `pvm-qemu-<tag>-darwin-arm64.tar.gz` |
| Linux x86_64 | KVM | `pvm-qemu-<tag>-linux-amd64.tar.gz` |
| Windows x86_64 | WHPX | `pvm-qemu-<tag>-windows-amd64.tar.gz` |

These are not official QEMU releases. The project is not affiliated with the QEMU project; see [NOTICE](NOTICE).

pvm v1.4 and later install them with `pvm qemu install`, checked against digests pinned in each pvm release. pvm can also use the QEMU of your platform's own channel instead (Homebrew, your distribution, or a build linked from qemu.org); see pvm's documentation.

## Tags

A tag is `<qemu-version>-pvm<N>`, for example `11.1.3-pvm1`: QEMU 11.1.3, build 1. N goes up whenever the patches, configure flags or bundled libraries change for the same QEMU version. A tag on a QEMU release candidate, such as `11.2.0-rc1-pvm1`, is published as a prerelease and is never pinned by pvm.

Each tag has a release file, `releases/<tag>.env`:

```
QEMU_VERSION=11.1.3
QEMU_SHA256=<sha256 of qemu-11.1.3.tar.xz>
PATCHES=
```

`PATCHES` lists files in `patches/<tag>/`, applied in order. Every patch must be a commit that is already in upstream QEMU, named in an `Upstream: <commit>` line. Tags and releases are never moved or deleted.

## What a build is

`.github/workflows/build.yml` makes every build. For each tag:

1. **Source.** The tarball and its signature come from download.qemu.org. The tarball must carry a valid signature from QEMU's release key, whose fingerprint is pinned in `keys/FINGERPRINT`, and match the SHA-256 in the release file (`script/verify-upstream.sh`). Tamper tests prove the checks refuse a changed byte, a signature by another key, another key file and a wrong digest, and that a patch with mismatched context does not apply (`script/test-verify.sh`). Patches apply with no fuzz.
2. **Build.** `script/build.sh` holds the configure flags. Each build has one system emulator and `qemu-img`, headless, with user networking, and with every optional library feature pvm does not use disabled explicitly.
   - **macOS** builds on macos-15 against Homebrew's glib, pixman and libslirp. `script/pack-darwin.sh` copies those dylibs into `lib/`, rewrites their paths to `@executable_path/../lib`, and signs everything ad hoc. `qemu-system-aarch64` is signed last with only the `com.apple.security.hypervisor` entitlement, which HVF requires.
   - **Linux** builds in a digest-pinned ubuntu:24.04 container. `script/pack-linux.sh` ships the shared library closure including the ELF loader, and runs the executables through it from small sh wrappers, so the build does not depend on the host's libraries. As root on the runner host, `script/probe-linux.sh` starts a copy at another path with every system QEMU directory hidden, and proves it fails once its own firmware is removed. It also starts in debian:12 and fedora:45.
   - **Windows** cross-builds with mingw-w64 in the Fedora container that the QEMU tarball itself defines (`tests/docker/dockerfiles/fedora-win64-cross.docker`). `script/pack-windows.sh` ships every DLL from the mingw sysroot that the executables load. A Windows runner then runs the smoke test.
3. **Checks.** Before anything is archived, these must pass:
   - `script/check-closure.sh` fails if any shipped binary loads a library that is neither shipped nor part of the OS.
   - `script/finish-tree.py` refuses symlinks and missing files, and refuses any shipped library not listed with its package and license.
   - `script/smoke.py` checks `SHA256SUMS`, the version, and the accelerators, devices, netdevs and objects pvm uses. It checks that virtio-9p is present exactly where the build declares it. It runs `qemu-img convert -B` and `-b`, then starts QEMU paused under TCG with pvm's own command line, once with a user netdev and once with a stream netdev as in a cluster. Over QMP it adds a host forward, hot-plugs a NIC, and quits.
4. **Release.** `release.yml` runs only on a tag, on GitHub-hosted runners. Publishing waits for approval of the `release` environment. Then it writes `SHA256SUMS` over all assets, attests every asset with `actions/attest-build-provenance`, creates a draft release, and publishes it.

## Archive layout

Each archive holds one directory, `aarch64/` on macOS and `x86_64/` elsewhere, with regular files and directories only:

```
x86_64/
  bin/            qemu-system-x86_64[.exe], qemu-img[.exe]; on Windows also the DLLs,
                  on Linux the sh wrappers and the real executables (*.real)
  lib/            shared libraries (macOS, Linux)
  share/qemu/     firmware (macOS, Linux); on Windows bin/share/
  doc/            COPYING, COPYING.LIB, LICENSE, THIRD-PARTY.txt, SOURCE.txt,
                  licenses/, build-packages.txt
  pvm-qemu.json   the build manifest: tag, upstream tarball and key, patches,
                  configure flags, paths, declared capabilities, build environment
  VERSION         the tag
  SHA256SUMS      every other file
```

This is the runtime layout pvm v1.1 to v1.3 already accept. So the same archive can be tried under an existing pvm, and v1.4.x and v1.5.x releases can carry it under the old `pvm-qemu-runtime-*` names for clients that still upgrade the old way.

## Verifying a download

```
gh attestation verify pvm-qemu-11.1.3-pvm1-linux-amd64.tar.gz \
  --repo BitterOrange/pvm-qemu \
  --signer-workflow BitterOrange/pvm-qemu/.github/workflows/release.yml \
  --source-ref refs/tags/11.1.3-pvm1 --deny-self-hosted-runners
sha256sum -c SHA256SUMS --ignore-missing
```

pvm does not need `gh` on your machine for builds it pins: pvm's own CI has checked those attestations, and pvm compares the archive with the pinned SHA-256.

## Source

QEMU is licensed under the GNU GPL version 2, and the bundled libraries under their own licenses, listed in each archive's `doc/THIRD-PARTY.txt` with their texts in `doc/licenses/`. Every release publishes the complete corresponding source next to the binaries:

- `pvm-qemu-<tag>-source.tar.gz` holds the upstream QEMU tarball and its signature, the patches, this repository at the tag (build scripts and configure flags), and `BUILD.md`.
- `pvm-qemu-<tag>-<host>-deps-source.tar` holds the source of every library in that host's archive, as published by the distribution it came from: Ubuntu source packages, Homebrew formulae and their source, or Fedora source RPMs.

Releases are never deleted. Source assets stay as long as any binary of the tag is offered or pinned by a pvm release, and for at least three years after.

## Trying a build on a real machine

CI cannot run HVF or WHPX, so each build is also run by hand on real hosts. `script/validate.sh` does this under an unchanged pvm v1.3.x; use Git Bash on Windows.

```
script/validate.sh install pvm-qemu-11.1.3-pvm1-windows-amd64.tar.gz   # --no-attest for a CI artifact
script/validate.sh run --exit my-exit
script/validate.sh restore
```

`install` moves pvm's current runtime folder aside, never deletes it, and refuses while a VM runs from it. `run` creates a throwaway VM (`pvmqemu-check`) and runs:

- create, start and ssh;
- `/share` and `pvm mount` (macOS, Linux);
- a port map;
- an exit route with a tunnel-loss check, with `--exit`;
- a RAM snapshot and its restore (not on Windows: QEMU blocks migration of WHPX VMs, so pvm has no RAM snapshots there);
- compact;
- removal of the VM.

It writes a log to attach to the release discussion. `restore` puts the original runtime back.

The `validate` workflow, started by hand from the Actions tab, runs the same cycle on GitHub's runners, with the archives of a `ci` run under a pvm release (v1.3.6 by default):

- **Linux** runs under KVM, which GitHub's Linux runners provide, so it stands in for a real KVM host.
- **macOS** runs under TCG (`--allow-tcg`), because macOS runners cannot nest virtualization. It shows that the build works inside pvm, with its relocated libraries, its signatures, 9p and snapshots, but not that HVF starts it. That still needs a real Mac.

Neither job can test an exit route, since there is no VPS to route through.

## Making a release

1. Add `releases/<tag>.env` (and `patches/<tag>/` if any) in a pull request. CI builds every host from it and keeps the archives as workflow artifacts.
2. Run `script/validate.sh` with those artifacts on real HVF, KVM and WHPX hosts.
3. After merging, push the tag on the merge commit: `git tag -a 11.1.3-pvm1 -m "QEMU 11.1.3, build 1" && git push origin 11.1.3-pvm1`.
4. Approve the `release` environment when `release.yml` asks. The release is published once every asset is attested.
5. Pin the release in pvm (`internal/qemu/pvmqemu.json`) through a pvm pull request; pvm's CI checks the pins against these attestations.

## Repository settings

These are made by the maintainer in the GitHub settings, not by code:

- **Actions:**
  - the default `GITHUB_TOKEN` is read-only;
  - only GitHub-hosted runners are used; no self-hosted runner is registered;
  - fork pull requests from first-time contributors need approval.
- **Tags and branches:**
  - a tag ruleset on `*-pvm*`: only maintainers create tags, and nobody updates or deletes them;
  - `main` is protected and requires pull requests and the `ci` checks. A solo maintainer approves their own pull requests.
- **The `release` environment:**
  - the maintainer is a required reviewer, with self-review allowed;
  - deployments come only from tags matching `*-pvm*`.
- **Releases and security:**
  - immutable releases are on;
  - private vulnerability reporting is on.
