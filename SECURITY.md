# Security

## Reporting

Report a vulnerability in these builds or in this repository's workflows privately, through GitHub's "Report a vulnerability" on the Security tab. A vulnerability in QEMU itself belongs to the QEMU project: https://www.qemu.org/contribute/security-process/

## What this project guarantees

- **Upstream source.** Every build starts from a QEMU release tarball from download.qemu.org. It must carry a valid signature from QEMU's release key, whose fingerprint is pinned in `keys/FINGERPRINT`, and match the SHA-256 committed in `releases/<tag>.env` before the tag. CI proves both checks reject tampered input.
- **Patches.** Only commits already merged in upstream QEMU are applied, each named by its upstream commit, with no fuzz.
- **Where builds run.** Release builds run only from protected `*-pvm*` tags, on GitHub-hosted runners, with all actions pinned by commit SHA. No self-hosted runner is attached to this repository. Only the publishing job can write releases, create attestations or request an OIDC token, and it waits for the maintainer's approval of the `release` environment.
- **Provenance.** Every published asset carries a build-provenance attestation from `.github/workflows/release.yml` at its tag, and is listed in the release's `SHA256SUMS`. Releases are published draft-first and are immutable once published. No tag is moved or deleted.
- **Contents.** Every shipped binary's library closure is checked to stay inside the archive or the operating system. Every shipped library is listed with its package and license, and its source is published in the same release. macOS binaries are signed ad hoc with only the `com.apple.security.hypervisor` entitlement. Windows binaries are not Authenticode-signed.
- **Withdrawal.** A build with a known security or data-loss problem is withdrawn by pvm, which refuses to start new VMs with a build its release lists as withdrawn. Its release here stays, so existing users can still verify and inspect it, and the release notes say why it was withdrawn.

## What it does not guarantee

- These builds include QEMU's own vulnerabilities until a new QEMU release fixes them and a new tag is built. pvm aims to re-pin within 14 days of an upstream stable or security release that affects the shipped configuration.
- Bundled libraries are as current as the distribution or Homebrew was when the build ran. A library fix needs a new build (`-pvm<N+1>`).
- The checks prove where an archive came from and that it was not changed. They do not protect a machine whose user or administrator replaces files after installation; pvm's own per-start checks catch accidental changes only.
