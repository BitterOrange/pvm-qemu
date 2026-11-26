# pvm-qemu Agent 指南

与用户同语言回复。本仓库只做一件事：从上游签名源码构建 pvm 使用的 QEMU，并连同完整对应源码发布。改动前先读 README.md 和相关脚本。

## 地图

- `releases/<tag>.env`：每个 tag 的 QEMU 版本、上游 tarball SHA256 和补丁列表；tag 为 `<QEMU 版本>-pvm<N>`。
- `patches/<tag>/`：该 tag 依次应用的补丁，每个都必须是上游已合入的提交（`Upstream: <commit>` 行）。
- `keys/`：QEMU 发布公钥和固定指纹。
- `script/`：校验（`verify-upstream.sh`、`test-verify.sh`）、构建（`build.sh` 集中所有 configure 参数）、打包（`pack-darwin.sh`、`pack-linux.sh`、`pack-windows.sh`）、检查（`check-closure.sh`、`finish-tree.py`、`smoke.py`、`probe-linux.sh`）、源码（`collect-dep-sources.sh`、`make-source.sh`）、发布（`mktar.py`、`release-notes.sh`）和真机验证（`validate.sh`）。`script/ci/` 是各平台在 CI 里的入口。
- `.github/workflows/`：`build.yml` 被 `ci.yml`（不发布）和 `release.yml`（唯一发布的 workflow）调用。

## 硬约束

1. 上游 tarball 必须同时通过固定指纹的 GPG 签名校验和 `releases/<tag>.env` 中的 SHA256 校验，任何一项都不得跳过或改为警告。补丁只能是上游已合入的提交，`--fuzz=0` 应用。
2. 只有 `release.yml` 发布，只在受保护的 `*-pvm*` tag 上、GitHub 托管 runner 中运行，经 `release` 环境审批，先建 draft 再发布。不添加 self-hosted runner，不给其他 job 写权限，所有 action 按 commit SHA 固定。
3. 已发布的 tag 和 release 不移动、不删除；源码资产在其二进制仍被提供或被 pvm 固定期间及之后至少三年保留。修正问题发新的 `-pvm<N+1>`。
4. 每个随包发布的库都必须列入 `doc/THIRD-PARTY.txt`，其源码进入同一 release 的 deps-source 资产；库闭包只能落在归档内或操作系统中。检查失败就让构建失败，不降级为警告。
5. 归档只含普通文件和目录，保持 pvm v1.1 至 v1.3 能接受的布局（`<arch>/bin`、固件位置、`VERSION`、`SHA256SUMS`）。改布局前先确认 pvm 侧的兼容影响。
6. macOS 只做 ad-hoc 签名，`qemu-system-aarch64` 只带 `com.apple.security.hypervisor` entitlement，不引入依赖密钥的签名路径。
7. 公开内容中不出现真实 IP、个人路径、token 或主机名；上游公开的密钥指纹、发布摘要和镜像摘要是公开校验值，可以入库。

## 交付

- 不提交二进制、tarball、构建输出或临时文件；`git status` 只应含预期源码变化。
- 改脚本后至少运行 `bash -n`、`shellcheck -S warning` 和 `python3 -m py_compile`；能在本机跑的检查（如 `test-verify.sh`、对现有 QEMU 运行 `smoke.py --skip-sums`）要跑。完整构建以 CI 为准，HVF、KVM、WHPX 的真机结果以 `validate.sh` 日志为准；交付说明写清实际验证了什么、没验证什么。
- 提交、推送、打 tag 和发版都要用户明确要求；提交信息中不加入 agent 身份或 co-author 信息。仓库和 GitHub 设置由维护者手动完成。
