<!-- SPDX-License-Identifier: AGPL-3.0-or-later OR Apache-2.0 -->
<!-- Copyright (c) 2025-2026 SPHARX Ltd. All Rights Reserved. -->

# `.github/` — AgentRT 仓库自动化与模板

> GitHub Actions 工作流、Issue / PR 模板及社区健康文件，服务于
> [AgentRT (AirymaxAgentRT)](https://atomgit.com/openairymax/agentrt) 管理仓库。

---

## 定位

本目录承载 **agentrt 管理仓库的发布平面（workflow 宿主）**。agentrt 是 Airymax 平台的
**AI Agent 运行时平台工程**——为 AI Agent 团队提供 OS 级运行时基础设施，定位类似于
JVM 之于语言、containerd 之于容器。

本管理仓库聚合 **7 个叶子仓库**（atoms / commons / cupolas / daemons / gateway /
heapstore / protocols）作为 git 子模块，对外提供微内核原语、认知循环、内存分层、
安全穹顶、IPC 协议、网关服务和常驻守护进程等 OS 级机制。

**拓扑约定（2026-09 架构裁决）**：`airymaxhub` 伞仓为纯容器（superproject），
**不承载任何流水线**；CI/CD（构建 / 测试 / codegen / SSoT / 镜像同步 / 平台矩阵发布）
全部下沉到本 agentrt 仓，因为 agentrt 的版本发布语义（VERSION / CHANGELOG /
7 叶子聚合）都以本仓为唯一宿主。atomgit 为 SSoT 主托管，GitHub / Gitee 仅为镜像
与执行面（按需经各自 API/MCP 同步，不做本地循环触发）。

## 目录内容

```
.github/
├── README.md          # 本文件
├── actions/           # 复合 action（复用模板，防 build-test/release 双实现漂移）
│   ├── lf-init-deps/        # 定向子模块检出（agentrt 7 叶子，release 额外 + sibling 数据）
│   ├── lf-build-container/  # Linux 容器腿统一构建模板（digest 钉版镜像 + 日志 annotation）
│   └── lf-package/          # tar.gz 打包统一模板（staging + sha256 + upload-artifact）
├── docker/
│   └── qemu-toolchain/      # 交叉编译工具链镜像（固化 apt+自编译 deps，提速 qemu 腿）
│       ├── ubuntu.Dockerfile      # arm64 / arm32 / amd64 容器腿用
│       └── debian-i386.Dockerfile # linux-x86-32 腿用
├── scripts/
│   ├── init-submodules.sh       # CI 依赖布局：7 叶子子模块 + release 期 sibling 数据
│   ├── sync-mirror.sh           # agentrt + 7 叶子 → GitHub / Gitee 镜像同步
│   ├── setup-release-environment.sh  # release environment + branch/tag policy 幂等配置（H3）
│   ├── ci-debug-dump.sh         # 失败步骤完整日志直传 ci-debug issue（排障拉取）
│   ├── build-tui.sh             # Rust TUI（agentrt-tui）构建
│   └── finalize-linux-libs.sh   # Linux 打包前运行库自包含收尾
└── workflows/
    ├── build-test.yml           # 构建 / 测试门禁（Linux 覆盖率 / macOS / Windows）
    ├── build-toolchain-images.yml  # 交叉工具链 GHCR 镜像构建推送（qemu 腿基础设施）
    ├── codegen-check.yml        # syscall.xml SSoT 漂移校验
    ├── release.yml              # 跨平台发布（7 产品腿 + riscv canary + 聚合 + e2e 门禁 + publish）
    └── sync-mirror.yml          # atomgit(SSoT) → GitHub / Gitee 镜像同步触发器
```

### 为什么是"四层结构"——看似复杂，实际是三类历史教训的收敛

流水线体量的来源不是"三条平台线各写一份"，而是把**每个平台腿的公共
步骤抽成一份模板**（复合 action / 脚本 / 镜像），四层各有单一职责：

1. **workflows**（编排层）只做"触发 × 跑哪些 job"。两个主 workflow：
   `build-test.yml` = 三平台高频门禁（Linux 覆盖率 / macOS / Windows 三个
   job），`release.yml` = 发布时的一次性跨平台构建 + 汇聚 publish（26 资产
   一次落库，manifest.latest 单点）。
2. **actions/**（复用层）：历史教训是同一段 shell 在 release.yml 和
   build-test.yml 各写一份，改一侧另一侧漂移 → 构建红。`lf-*` 把
   checkout/子模块、容器腿构建、tar.gz 打包收敛成单一权威模板（P3 收口）。
3. **docker/**（提速层）：qemu 交叉腿（arm64/arm32/i386）最初每轮在容器
   内从源码重编全部依赖（arm-64 实测 88 min），把环境固化进 GHCR 镜像后
   环境准备归零（0.1.11 E1 / 0.1.12 I1 实证）。
4. **scripts/**（细节层）：workflow YAML 难以承载的幂等配置（H3 release
   environment）、失败日志直传 issue（ci-debug-dump）、子模块布局等长逻辑。

**"为什么不拆 Windows / Linux / macOS 三条流水线"（0.1.13 结构定案）**：
拆线表面更清晰，实则每个平台要各自维护"触发条件 + 产物名 + 上传逻辑 +
环境变量 + Secrets"，与现在唯一的区别是把**已收敛的公共部分再拆散成三份
漂移源**。发布是跨平台原子事件（26 资产同一次落库 / tag 单点 / Environment
审批不下沉），拆成三条后 release 原子性要靠三线对齐，代价更高。当前形态 =
**一条发布流水线（release.yml）+ 三条门禁（build-test.yml 的 linux/macos/
windows job）+ 一套复用件（lf-* / 镜像 / 脚本）**，即"逻辑上三平台、物理
上一份"。release.yml 现约 1300 行（B9 治理评估成文：e2e-clean-room / U9 升级
路径 / REQUIRED_BIN 预检随 rc 实证持续叠加，编排复杂度仍在单文件承载范围内；
若继续增长再评估 workflow_call 拆腿，Environment 审批必须留在主文件）。

## 工作流

| workflow | 触发 | 说明 |
|----------|------|------|
| `build-test.yml` | `push main` / `pull_request` / `workflow_dispatch` | 三平台高频门禁：Linux（Debug + ctest + gcovr 覆盖率阈值）/ macOS（Homebrew）/ Windows（vcpkg + MSVC）。G2 达成（0.1.13）：windows ctest 35→全绿，`windows-build` 为 required 硬门禁 |
| `build-toolchain-images.yml` | `push main`（Dockerfile/相关变更）/ `workflow_dispatch` | 交叉工具链镜像（arm64/arm32/i386 容器腿）构建并推送 GHCR，digest 钉版供 release 腿引用 |
| `codegen-check.yml` | `push main` / `pull_request` / `workflow_dispatch` | `syscall_gen.py --check` 校验 `syscall.xml` 与生成产物漂移 |
| `release.yml` | `tag v*` 推送 / `workflow_dispatch`（输入 version） | 发布链（G1 起 windows 为 required gate）：linux-x86-64 / linux-arm-64 / linux-arm-32 / linux-x86-32 / linux-riscv-64（canary）/ macos-arm-64 / macos-x86-64 / windows-x86-64 → 聚合 `release` → **`e2e-clean-room`**（H2 洁净容器：安装 → daemon 群 → CLI 冒烟 + **U9 旧版升级路径**，publish 前置门禁）→ `publish`（Environment 审批：REQUIRED_BIN/SUBTREE 预检 + cosign/GPG 签名 + 26 资产一次落库 + manifest.latest）。publish 通过后拉取 stable manifest 的 prev 制品在下一 rc/发布自动回归 U9 |
| `sync-mirror.yml` | `push main` / `workflow_dispatch` | `sync-mirror.sh`：agentrt + 7 叶子从 atomgit(SSoT) 同步至 GitHub / Gitee（缺仓自动创建，atoms 私有，错误隔离汇总） |

## 布局与子模块

- agentrt 工作树根即 agentrt 源码；`git submodule update --init --recursive` 在根上
  一次性拉齐 7 个叶子（SHA 由 agentrt 树 gitlink 钉定）。私有叶子 `atoms` 经
  `GH_TOKEN`（org PAT，`~/.netrc`）认证。
- release 链额外克隆 sibling 数据到**历史相对路径**（`tools/` 与
  `agent-workload/{sdk,ecosystem}`，来自 GitHub 镜像期 clone，**GitHub 侧手动维护，
  见"镜像覆盖范围"节**），使打包 / 发布脚本的路径引用与伞仓时代一致、无需逐处改写：
  - `tools/`：`lib-builddeps.sh` / `ops/templates/*`（config 模板）/ `ops/bin/agentrt-bootstrap.sh` / `ci/release/publish-release.sh` 等；
  - `agent-workload/sdk/tui`：Rust TUI（`agentrt-tui`）构建源；
  - `agent-workload/ecosystem`：Python 运行时（agents / manager 配置 / markets maths-toolkit）。
- 构建源一律 `cmake -S .`（agentrt 即宿主根），不再有 `agent-workload/agentrt` 前缀。

## 脚本

### init-submodules.sh — CI 依赖布局

```bash
bash .github/scripts/init-submodules.sh               # 仅 7 叶子（build-test / codegen）
bash .github/scripts/init-submodules.sh agent-workload tools   # 叶子 + sibling 数据（release）
```

参数保持伞仓时代调用形式（`agent-workload` / `tools`），脚本内部重映射；私有叶子与
sibling clone 凭据统一走 `GH_TOKEN`。

### sync-mirror.sh — agentrt + 叶子双镜像同步

同步模型：源 = atomgit(SSoT)，`clone --mirror` 抓全量 refs 后仅 push **heads + tags**
（force 与 SSoT 一致，不透传 atomgit 平台内部 ref）；子模块树以各仓 `HEAD:.gitmodules`
BFS 解析；缺仓自动创建（atoms 私有）；每仓错误隔离、末尾汇总。

### 镜像覆盖范围（rc2 教训：tools 等 sibling 仓 GitHub 侧需手动维护）

`sync-mirror.yml` 只自动同步 **agentrt + 7 叶子**。发布链在 CI 克隆的 sibling 数据
（`_tools` / `agent-workload/{sdk,ecosystem}`，见下节）来自 **GitHub 镜像**，而
GitHub 侧并无自动同步这些仓的通道——rc2 实证：`github.com/openairymax/tools`
落后 5 提交、缺 `e2e-clean-room.sh`，导致 release 的 e2e job exit 127（脚本缺失），
publish 被正确阻塞但失败归因一度被误导为容器内阶段失败。

**维护要求**：tools / sdk / ecosystem / agent-workload / docs-closed 等顶层仓在
atomgit 提交后，若其内容被 GitHub 侧 CI 消费（release 打包脚本、bootstrap、
e2e 脚本、TUI/Python 运行时），须手动把 `main` 快进同步到 GitHub：

```bash
git -C <repo> push git@github.com:openairymax/<repo>.git main:main
```

无分叉时快进即可（镜像终态与 SSoT 一致）；分叉时须先对齐 SSoT 再推。
0.1.13 收口项：为这些仓补一条自动镜像通道（或在 release 链改用 atomgit 拉取），
避免依赖人工记忆。

### 发布 tag 与重复 Release run（H3/P19 SOP，2026-09-06 更正根因）

**根因更正**：publish-release.sh 并不回推 git tag；重复 run 的链条是——
atomgit Release API 建 release 时若 tag 尚不存在，服务端自动补建 tag（rc 资产内
`<tag>.tar/.zip` 源归档即服务端自动产物为证）→ sync-mirror 全量 tag 镜像推至
GitHub → tag push 再触发 `release.yml` 全链（rc.2 重复 run 33988925887 实证）。

**正式发布无重复的实证**：tag 先双端（atomgit+GitHub）打齐 → atomgit 建 release
复用既有 tag、GitHub 已有同 sha tag → sync 幂等 no-op（正式 v0.1.12 无 echo run）。

**SOP**：
1. 任何 rc/正式发布前**先双端打 tag**（atomgit + GitHub 指向同一 commit）再放行
   release 流程；
2. 若走 workflow_dispatch（main）且 publish 建了缺失 tag，随之出现的 echo Release
   run 按需取消（AIRY_FORCE_UPLOAD=1 保证即使并发重发产物亦一致，无害）；
3. sync-mirror 的 `--force` tag 推送保证两镜像终态与 SSoT 一致，无需人工干预。

## Secrets

| Secret | 用途 | 使用方 |
|--------|------|--------|
| `GH_TOKEN` | GitHub org PAT（建仓 / 推送 / 私有子仓认证；PAT 推送的 tag 可触发 `release.yml`，`GITHUB_TOKEN` 推送不会） | 全部 workflow |
| `GT_TOKEN` | Gitee 令牌（org 建仓 + 推送） | `sync-mirror.yml` |
| `ATOMGIT_TOKEN` | atomgit 令牌（私有子仓 mirror clone / 官方制品上传） | `sync-mirror.yml`、`release.yml` |
| `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` | 发布 GPG 签名（manifest `*.asc`） | `release.yml` |
| `COSIGN_PRIVATE_KEY` / `COSIGN_PASSWORD` | cosign 容器签名（tarball `*.sig`） | `release.yml` |

签名密钥初始化见 `tools/scripts/ci/release/init-signing-keys.sh`（release 期从
`tools/` sibling 取得）。

## 相关链接

| 资源 | 链接 |
|------|------|
| **主 README** | [agentrt/README.md](../README.md) |
| **中文 README** | [agentrt/README_zh.md](../README_zh.md) |
| **伞仓（纯容器）** | [airymaxhub](https://atomgit.com/openairymax/airymaxhub) |
| **构建系统** | [agentrt/cmake/](../cmake/) |

## 许可证

双许可证：**AGPL v3 + Apache 2.0**（SPDX: `AGPL-3.0-or-later OR Apache-2.0`）。
详见仓库根目录 [LICENSE](../LICENSE) 与 [NOTICE](../NOTICE)。

Copyright (c) 2025-2026 SPHARX Ltd. All Rights Reserved.
