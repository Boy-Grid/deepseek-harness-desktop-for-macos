# 开源规划：DSH Desktop for macOS

> 目标：把一个自用的 macOS 启动器，打磨成面向大众的、合规的、可持续维护的开源产品。
> 本文是规划文档（非法律意见）；商标/许可条目均标注了"需核实"。
> **决策状态（v2）**：✅ 已锁定 / ⏳ 待定 / 🔲 已否决

---

## 0. 现状盘点

| 维度 | 现状 | 对开源的影响 |
|---|---|---|
| 代码 | `LauncherAgent.swift`（62KB 单文件）+ `launcher`（bash CLI） | 功能完整但难维护、难测试 |
| 构建 | `build.sh`：swiftc 编译 + **ad-hoc 签名**（`codesign -s -`） | 仅本机可用；第三方分发无法过 Gatekeeper |
| 安装 | 手动构建到 `~/Applications/DeepSeek Harness/`，无卸载、无更新 | 大众用户门槛高 |
| 运行时依赖 | 要求用户自装 `dsh`（`npm i -g @deepseek-ai/dsh`）+ Node.js | 大众用户最大摩擦点 |
| 品牌 | 应用名含 "DeepSeek Harness"，bundle ID `ai.deepseek.harness.launcher`，图标取自 DSH favicon | 商标敏感点（见 §2） |
| 仓库 | 无 LICENSE / CI / 测试 / issue 模板，README 仅中文 | 不可直接开源 |
| 上游 | DSH 为 MIT、dev preview、破坏性变更频繁 | 必须锁版本 |

> 这张表是**规划起点的快照**。M0 已消除的行：品牌（更名 + bundle ID + 窗口标题 + About 面板）、
> 仓库（LICENSE + 第三方声明 + 版本号）。仍然成立的行：代码单文件、构建仅 ad-hoc 签名、安装无
> 卸载无更新、运行时要用户自装。进度以 §8 为准。

---

## 1. 三个核心问题的直接回答

| # | 问题 | 结论 |
|---|---|---|
| Q1 | 是否应调整安装方式及安装位置？ | ✅ **是。** 分发方式锁定为 **GitHub Releases 发 DMG 安装包**，不上 App Store（🔲 App Store / 🔲 Homebrew Cask 主渠道）。安装位置收敛为 `/Applications`（或用户选择）；DMG 需要 Developer ID 签名 + 公证才能对大众可用。详见 §3。 |
| Q2 | 是否包含 DSH 安装及卸载能力？ | ✅ **是，且为"精简包 + 一键在线安装"**：DMG 内**不自带 Node.js**，app 首次启动时在线把 node + dsh 装进自己的状态目录（一键引导），并支持更新/卸载，绝不触碰用户自装的 dsh。详见 §4。 |
| Q3 | DSH 的开源协议是否允许？图标能否用？ | ✅ **代码：允许**（纯 MIT，Copyright © 2026 DeepSeek），义务是保留版权声明（`THIRD_PARTY_NOTICES.md`）。✅ **图标：保留派生 favicon，标注出处**；"DeepSeek / DeepSeek Harness" 名称与 logo 是 DeepSeek 商标，MIT 不覆盖商标，故保留非官方免责声明 + 更换 bundle ID 以降低风险。详见 §2。 |
| Q4 | 是否支持 dsh-mfw（多文件夹工作区）？ | ✅ **是，作为可切换的第二后端**，默认关闭。理由：多文件夹会**扩大 Agent 的写面**，这是安全语义的实质变化，不能是默认值；同时它多占约 300 MB 磁盘、且把 DSH 基线精确 pin 住。详见 §4.5。 |

---

## 2. 法律与合规（先决条件，最先做）

### 2.1 DSH 许可证分析（已核实）

- 仓库：`deepseek-ai/deepseek-harness`，LICENSE = **MIT**，`Copyright (c) 2026 DeepSeek`。
- MIT 授予：使用、复制、修改、合并、发布、分发、再许可、销售；唯一条件：**在所有副本或实质部分中保留版权声明与许可声明**。
- 对我们的含义：捆绑/分发 DSH 的代码或 npm 包、修改它、为它做二次开发，全部合法。**义务清单**：
  - `THIRD_PARTY_NOTICES.md` 中收录 DSH 的完整 MIT 声明；
  - 在线安装 node 二进制与 dsh 的 npm 依赖时，连带其许可证声明（DSH 仓库自带 `THIRD_PARTY_NOTICES.md`，直接引用/复制其内容即可）；
  - 不改写上游版权归属。

### 2.2 图标与名称：决策与风险控制（需核实官方品牌政策）

**✅ 已决策**：应用名 **"DSH Desktop for macOS"**；图标**保留由 DSH favicon 派生的现有图标**（`icon.icns` / `make-icon.py` 流程保留），并在文档中标注出处。

风险控制措施（仍须执行，成本极低）：
1. **出处标注**：README + About 面板 + `THIRD_PARTY_NOTICES.md` 注明"图标由 DeepSeek Harness Web UI 的 favicon 派生，DeepSeek Harness 为 DeepSeek 商标"；
2. **免责声明**：README/About 显著标注"非 DeepSeek 官方产品，与 DeepSeek 无关联（not affiliated with DeepSeek）"；
3. **bundle ID 必须改**：`ai.deepseek.harness.launcher` 是 DeepSeek 自有域名反写，最像官方、风险最高 → ✅ 已改为 `io.github.boy-grid-g.dsh-desktop`（M0 落地）；
4. 顺带核实 DSH 仓库/deepseek.com 是否有品牌使用政策，有则遵守。

> 说明：你的判断"官方不至于太小气"大概率成立，但商标风险是"不告你 ≠ 合法"；以上三条是零成本保险，不做白不做。

### 2.3 本项目自己的许可证

✅ **已决策：MIT**（与 DSH 一致、生态最友好、零解释成本）。首次 commit 前加入 `LICENSE`，作者署名你自己（不是 DeepSeek）。

### 2.4 隐私与合规声明

- 现状即无遥测、无网络上报（仅本地端口探测），写进 README/隐私声明作为卖点；
- 新增的网络行为只有：① 首次运行的运行时在线安装（node 官方源 / npm registry）；② 版本更新检查（GitHub Releases API，仅版本元数据）。两者在隐私声明中列明，不含用户数据。

### 2.5 不上 App Store 的原因（写进文档，避免被问）

- App Store 要求沙箱（App Sandbox）；本应用需 spawn 子进程、绑定本地端口、管理外部进程树，沙箱下不可行；
- 结论：**GitHub Releases 发 DMG + Developer ID 签名 + 公证**，是 macOS 官方认可的标准第三方分发方式。

---

## 3. Q1 展开：App 化 —— 安装方式与安装位置

### 3.1 现状与问题

- `build.sh` 手动构建 → 拷贝到 `~/Applications/DeepSeek Harness/`；ad-hoc 签名只解决本机运行，**换台机器就会被 Gatekeeper 拦**；
- 无版本号管理、无卸载、无更新通道。

### 3.2 ✅ 已决策：分发渠道（v2 修订）

| 渠道 | 受众 | 安装位置 | 说明 |
|---|---|---|---|
| **A. GitHub Releases 发 DMG**（主渠道） | 所有用户 | 挂载 DMG → 拖入 `/Applications`（无权限时回退 `~/Applications`） | Developer ID 签名 + **公证（notarize）** + 装订（staple）；DMG 内仅 app，不含 Node.js |
| **B. 源码构建**（保留并改进 `build.sh`） | 开发者/贡献者 | 任意 | 无签名环境时 ad-hoc 签名仅限本机调试 |
| ~~Homebrew Cask~~ | — | — | 🔲 非主渠道；若社区需要，后期可作贡献者自发维护项 |

- 应用内提供**卸载入口**：菜单「卸载 DSH Desktop」→ 移除 app、状态目录、在线安装的运行时（可选）、LaunchAgents（可选保留用户 dsh 数据）。

### 3.3 应用工程改进清单

- **名称与标识（M0）**：`CFBundleName = DSH Desktop`，`CFBundleDisplayName = DSH Desktop for macOS`；bundle ID 改为自有标识；`NSHumanReadableCopyright` 与 README 同步免责声明。
- **签名与公证**（需要 Apple Developer 账号，$99/年，⏳ 待确认）：
  - `Developer ID Application` 证书 + `--options runtime`（hardened runtime）+ `notarytool` 公证 + `stapler` 装订；
  - CI 中证书存 Actions secrets（p12 + 密码），公证用 App Store Connect API key；
  - `build.sh` 增加 `--release` 模式走完整链路，默认 ad-hoc 仅限本机调试。
- **DMG 制作**：`scripts/make-dmg.sh`（`hdiutil` 创建、可加背景图/Applications 快捷方式）；命名 `DSH-Desktop-<version>-macos-<arch>.dmg`；DMG 同样需签名 + 公证（公证对象是 DMG 内的 app，装订到 DMG）。
- **Info.plist 完善**：`CFBundleShortVersionString`/`CFBundleVersion` 与 git tag 联动；`LSMinimumSystemVersion` 明确（建议 12.0 起步，实测后定）；补本地化 DisplayName。
- **通用二进制**：`arm64 + x86_64`，覆盖 Intel Mac（CI 双架构构建或合并）。
- **更新机制**：初版做"检查更新"菜单（查 GitHub Releases API → 提示下载新 DMG）；稳定后上 **Sparkle**（要求 Developer ID 签名，已具备）。
- **偏好设置**：端口（默认 3080）、开机启动（LaunchAgent 可选）、退出时是否停止 dsh、更新渠道（稳定/预发布）。
- **本地化**：zh-Hans + en（至少 UI 与 README 双语）。
- **日志轮转**：`logs/` 按大小/天数轮转。

---

## 4. Q2 展开：DSH 运行时管理 —— 精简包 + 一键在线安装

### 4.1 现状

`launcher` 只做**探测**（PATH、`~/.npm/_npx/*`、缓存），找不到就提示用户手动 `npm install -g @deepseek-ai/dsh`。大众用户在此流失。

### 4.2 ✅ 已决策：包内不自带 Node.js，提供一键在线安装

- **DMG 内只有 app**（体积小、构建简单、无重分发 node 二进制的许可证负担）；
- **首次启动向导**：检测到系统无可用 dsh → 弹窗「需要 DeepSeek Harness 运行时（约 xx MB，需联网）」→ 一键下载安装 → 进度条 → 完成即启动；**完全不需要用户懂 npm/node**；
- 在线安装内容装入**状态目录**（`~/Library/Application Support/DSH Desktop/runtime/`）：
  - `node/`：nodejs.org 官方预编译二进制（按架构 arm64/x86_64），**下载后 SHA-256 校验**（校验和来自 nodejs.org 官方发布页）；
  - `dsh/`：`@deepseek-ai/dsh` 的 npm tarball（npm registry 下载 + 完整性校验），**锁版本**；
  - `.version` 记录当前版本；
- **运行时优先级**：`DSH_LAUNCHER_DSH` 显式指定 > 系统已有 dsh（用户自装，尊重之）> 托管运行时 > 引导在线安装；
- **更新**：菜单/CLI「检查 DSH 更新」→ 查 npm registry / GitHub Releases → 提示更新（先冒烟验证再切换）；
- **卸载**：只删自己在线装的运行时；系统自装 dsh **永不触碰**（沿用现有"不杀他人进程"的安全哲学）；
- **网络失败降级**：下载失败 → 弹窗给出两条出路：重试 / 显示手动安装指引（装 node + `npm i -g @deepseek-ai/dsh`）；
- **版本策略（重要）**：DSH 是 dev preview、破坏性变更频繁 → **锁定已验证版本**，新版本先做兼容性冒烟（启动 → 端口就绪 → UI 可达）再提示升级；不支持自动跨版本跳。

### 4.3 新 CLI 命令（扩展 `launcher`）

```sh
launcher dsh status            # 运行时来源（系统/托管）、版本、可更新版本
launcher dsh install           # 一键在线安装/修复托管运行时（node + dsh）
launcher dsh update            # 更新托管运行时（先冒烟后生效）
launcher dsh uninstall         # 删除托管运行时（不动系统 dsh）
launcher uninstall             # 卸载应用：app + 状态目录（--keep-runtime 可选）
```

---

## 4.5 Q4 展开：双后端（原版 DSH / dsh-mfw）

### 4.5.1 为什么是两个后端而不是两个 App

[dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace) 让 DSH 支持**多文件夹工作区**。它
不是一个插件，而是一个自带补丁运行时的启动器：首次运行会在缓存目录里 provision 一棵打了补丁的
DSH 安装树（约 300 MB），维护自己的 DSH profile（`mfw`），然后把参数原样交给 `dsh`。

关键性质是**它与原版共存**：用自己的 profile、不写用户的 `cordis.patch.yml`，但**共享同一个
`$DSH_HOME`**（会话与凭据双向可见）。所以对本应用来说，"原版 / mfw" 是同一个 App 的两种启动
方式，而不是两个产品——共用窗口、标签、进程管理与安全模型，只有「怎么起 dsh」这一层不同。

### 4.5.2 ✅ 已决策：可切换、默认原版、首次显式询问

| 项 | 决策 |
|---|---|
| 默认后端 | **原版 DSH**。多文件夹扩大写面是安全语义变化，不能默认开 |
| 切换位置 | 偏好设置里切换，附**两个仓库链接**（上游 DSH / dsh-mfw），便于用户自己判断 |
| 首次询问 | 首次安装后**显式询问一次**，说明能力与代价（写面、磁盘、基线 pin），选完记住 |
| DSH home | **可自定义**（`--dsh-home` / 偏好设置）。这是版本错开时的唯一出路，所以必须暴露 |
| 状态隔离 | 状态目录按 **(后端, 端口)** 分，避免两种后端共用 `web.pid` 与日志导致 pid 归属判定失真 |

### 4.5.3 版本错开守卫（硬约束）

dsh-mfw **精确 pin** 一个 DSH 基线（当前 `0.1.1-rc.2`），因为上游包之间用 `^` 区间互相引用，
不 pin 就会漂到新的 prerelease、让补丁变成 unused。后果：

> **当系统 dsh 的版本与 mfw 的基线已经错开时，禁止在同一个 `$DSH_HOME` 下从原版切到 mfw。**

原因是更新的原版 DSH 可能已经把 `$DSH_HOME` 里的记录写成新 schema，而 pin 在旧基线的 mfw 读它
的行为未定义。反方向的风险 mfw 自己也写明了：原版第一次写回记录时会把 `paths` 字段剥掉，成员集
合就没了（单向降级）。

所以切换前必须比对版本，错开时**拒绝切换**并给出两条出路：① 用独立的 DSH home；② 等 mfw 把补
丁集 rebase 到新基线。这条守卫在 `launcher` 层实现（GUI 与 CLI 共用一处判断）。

### 4.5.4 GUI 启动的两个实现约束（已实测）

1. **PATH 必须用 node 的 realpath 目录。** mfw 需要 pnpm ≥ 11，解析顺序是「PATH 上的 pnpm →
   corepack」，两者都只看 `PATH`。而 `~/.local/bin/node` 这类 symlink 目录里通常**只有
   node/npm/npx，没有 corepack 和 pnpm**（它们在 node 的真实安装目录里）。实测：注入 symlink
   目录 → `cannot find a usable pnpm`；注入 realpath 目录 → `pnpm 11.7.0 (PATH)`。
   而且 mfw 的 `prepare()` 无条件解析 pnpm，所以**运行时树已就绪也照样失败**——这不是只影响首次。
2. **首次 provision 要两段式。** provision 要跑 pnpm 装数百个包（实测 macOS 10–18 s，慢网更久），
   塞不进现有的 60 s 就绪超时。做法：先跑 `dsh-mfw provision`（输出进日志 + GUI 进度提示），成功
   后再 boot，boot 沿用原超时。

附带要求：mfw 要求 **Node ≥ 22**，且它用 `spawn(process.execPath, …)` 启动 dsh——**本应用用哪个
node 跑它，就决定了 dsh 用哪个 node**，所以 node 版本校验从"可选"变成"必需"。mfw 模式下也**不能
传 `--profile`**（mfw 自己会传 `--profile mfw --patch overlay.yml`）。

### 4.5.5 后续可选：原生多选目录面板

mfw 为了支持多选目录，**禁用了 DSH 的 native picker**，改用页内 browse UI。作为原生 App，本项目
可以提供 `NSOpenPanel` 多选面板——这是 d4m + mfw 组合独有的差异化点。但它需要一个 host 侧插件 +
本地 IPC 才能接上 `onPicked(paths[])` 契约，复杂度不低，**明确排在分发链路之后**。

---

## 5. 工程化改造（开源仓库必备）

### 5.1 仓库结构

```
deepseek-harness-desktop-for-macos/
├── LICENSE                  # ✅ MIT，署名 Boy-Grid
├── THIRD_PARTY_NOTICES.md   # DSH MIT 声明 + favicon 出处标注 + 在线安装依赖声明
├── README.md                # 重写：双语、功能截图、安装、FAQ、免责声明
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md
├── CHANGELOG.md             # semver
├── Sources/                 # LauncherAgent.swift 拆分为模块：
│   ├── App/                 #   启动、Dock、单实例、About 面板
│   ├── UI/                  #   窗口、标签栏、动画、偏好设置
│   ├── Web/                 #   WKWebView 管理、外链策略、JS 注入
│   ├── DSH/                 #   后端解析（stock/mfw）、运行时探测/在线安装/版本
│   └── Update/              #   更新检查
├── cli/launcher             # 现有 bash CLI（或迁移到 Sources/CLI）
├── scripts/build.sh         # --release（签名+公证）/ --debug（ad-hoc）
├── scripts/make-dmg.sh      # DMG 打包 + 装订
├── tests/                   # ✅ 已落地：run.sh + lib/assert.sh + t-*.sh + fixtures/（纯 bash，见 §5.3）
├── .github/workflows/       # ✅ CI 已落地（§5.2）；⏳ 发布流水线等 Apple 账号
└── make-icon.py             # 保留（favicon 派生图标流程，文档标注出处）
```

### 5.2 CI（GitHub Actions）—— ✅ 已落地

`.github/workflows/ci.yml`，两个 job，都在 `macos-latest` 上：

| job | 内容 |
|---|---|
| **test** | `brew install shellcheck` + `bash tests/run.sh`（见 §5.3）。装 Node 22 只为跑替身服务 |
| **build** | `./build.sh` → 断言 bundle 结构、`plutil -lint`、bundle ID 与 CFBundleName、`codesign --verify --strict`、**bundle 内的 launcher 与仓库里的逐字节一致**（陈旧副本在双击之前是看不见的）、以及原地重建不应清空模块缓存 |

只跑 macOS：launcher 依赖 `lsof`、"Application Support" 状态目录，被驱动的又是 Cocoa bundle，别的平台没有可验的东西。

**尚未落地**：发布流水线（打 tag → 签名 → 公证 → DMG → `SHA256SUMS` → Release）等 Apple 账号，见 M4。证书管理：p12 + 密码放 Actions secrets；公证用 `notarytool`（App Store Connect API key）。

### 5.3 测试策略

`tests/run.sh` 跑全部 `tests/t-*.sh`，**零外部依赖**（不引入 bats：应用本身没有运行时依赖，CI 也不该为了检查它去装一个）。跳过的用例会在汇总里重复列出——在这台机器上跑不了的用例不能读成通过。

| 文件 | 覆盖 | 断言数 |
|---|---|---|
| `t-01-resolve` | `realpath_of`、`child_path`、`node_major`、`pkg_version`、`proc_tree`、`port_listener` 降级 | 19 |
| `t-02-args` | 后端校验、状态目录分区（含 stock+3080 沿用历史路径）、DSH_HOME 解析与 isolated 判定、help 覆盖全部选项 | 28 |
| `t-03-mfw-guards` | 版本错开守卫五种情形、Node 门槛、包管理器缺失、mfw 不传 `--profile`。**全程用假 node / 假 dsh / 假 dsh-mfw**，两者都没装的机器上也能跑 | 19 |
| `t-04-safety` | 「只停自己启动的服务」：无 pid 记录、死 pid、活 pid 但不是监听者（pid 复用）、确属自己、端口空闲 | 19 |
| `t-05-lint` | `bash -n`、shellcheck（`-x` 跟进 source）、中文旁未加花括号的变量引用、`set -u` 仍在、Info.plist 与 M0 身份决策 | 39 |
| `t-06-boot` | 启动全程：参数构造、PATH 与 DSH_HOME 传递、pid 记录、就绪轮询、归属、停止、子进程立刻退出时快速报错。用 `fixtures/fake-dsh.mjs` 与 `fake-mfw.mjs` 替身，不需要真的装 DSH | 26 |

两条工程约定：

- **加断言必做反向验证。** 把实现改回缺陷版本，确认断言真的会红，再恢复。归属检查、`proc_tree`、花括号规则、`run.sh` 自身的失败检测都这么验过——其中 `run.sh` 一开始判的是 `tee` 的退出码，任何失败都会被读成通过，是靠反向验证抓出来的。
- **能用替身就不用真环境。** 真 dsh 是 dev preview，装它会把 CI 的稳定性绑在上游的发版节奏上。替身覆盖了 launcher 这一侧的全部逻辑，真 dsh 的联调放在发布前的手工验收。

**尚未落地**：Swift 侧 XCTest（要先把纯逻辑从 AppKit 里抽出来，见 M3）、托管运行时的断网降级冒烟（M5）、macOS 12/13 与 Intel 的兼容性矩阵。

### 5.4 安全清单（保持并强化）

- 维持"只杀自己启动的进程、他人占用的端口绝不碰"（现有设计很好，需测试覆盖）；
- 在线下载强制 HTTPS + SHA-256 校验（node 官方校验和 + npm registry integrity）；
- 不 shell 拼接用户输入（现有 CLI 已注意；Swift 侧同样要求）；
- 托管运行时目录权限收紧（`700`）；
- 若启用 LaunchAgent（开机启动），提供一键关闭。

---

## 6. 发布与分发

1. **GitHub Releases 资产**：`DSH-Desktop-<version>-macos-<arch>.dmg`（arm64 / x86_64）+ `SHA256SUMS` + 更新说明；
2. **README 即落地页**：下载链接 + 安装三步 + 截图 + FAQ + 免责声明；
3. **版本节奏**：跟随 DSH 发布节奏做适配验证（每次上游发版跑兼容性冒烟，把"已验证版本"写进 release notes）；
4. **发布 checklist**：冒烟全过 → 公证通过 → 干净机器下载 DMG 双击可开 → 升级路径（旧版 → 新版）→ 首次运行在线安装运行时全流程。

---

## 7. 社区与治理（可裁剪）

- issue 模板（bug / feature / 兼容性问题）、PR 模板、标签体系；
- GitHub Discussions 作为问答区；
- 维护者文档：如何发版、如何适配新 DSH 版本；
- DCO（Developer Certificate of Origin）勾选即可（个人项目不必上 CLA）。

---

## 8. 路线图与里程碑

**排序原则是依赖方向：底层结构 → 自动化验证 → 上层 UI → 分发。** 双后端（§4.5）动的是
`launcher` 最底层的进程与路径解析，所以它必须排在签名公证与 DMG **之前**——否则每次改结构都要
重跑一遍发布链路的验证。

| 里程碑 | 内容 | 预估 |
|---|---|---|
| **M0 法律与品牌** | LICENSE（MIT）、THIRD_PARTY_NOTICES（含 favicon 出处）、更名 "DSH Desktop for macOS"、bundle ID、窗口标题去商标、About 面板、版本号归零、文档只描述已实现行为 | 0.5–1 天 |
| **M1 双后端** | `launcher` 后端抽象（stock/mfw）、node realpath 注入 PATH、Node ≥ 22 校验、两段式 provision、版本错开守卫、DSH home 自定义、per-(后端,端口) 状态目录、owner 判定改完整子树 | 1–2 天 |
| **M2 工程化与 CI** | ✅ 测试套件（6 文件 / 150 断言，覆盖"绝不杀他人进程"、归属判定、后端与路径解析、启动全程）+ shellcheck + 自定义 lint + GitHub Actions 两个 job。⏳ 剩 CONTRIBUTING/SECURITY、双语 README | 1–2 天 |
| **M3 应用正规化** | ✅ 偏好设置（后端切换 + 首次询问 + DSH home）、每标签持久存储 + 标签重命名、退出改异步（不再卡 UI）、部署目标与 plist 对齐。⏳ 剩 `LauncherAgent.swift` 继续拆模块（已分出 `main`/`Preferences`/`TabStore`）、卸载入口、日志轮转 | 2–3 天 |
| **M4 分发** | Apple Developer 账号、Developer ID 签名 + 公证 + 装订、通用二进制、DMG 制作、SHA256SUMS、Release 自动化、检查更新（后期 Sparkle） | 3–5 天（含账号审批等待） |
| **M5 托管运行时** | 一键在线安装 node + dsh/dsh-mfw、首次运行向导、断网降级、`launcher dsh` 子命令、磁盘占用如实告知（双层缓存 350 MB+） | 3–5 天 |
| **M6 社区** | 模板、Discussions、FAQ、发布 checklist 固化 | 1–2 天 |

**总计：约 2–3 周业余时间。** M0 是最短但最不能省的一步——决定项目能不能"合法地"叫这个名字、
用这个图标。**Apple Developer 账号有审批等待，应在 M1 开工时并行提交申请。**

---

## 9. 决策记录与待定项

### ✅ 已锁定
| 项 | 决策 |
|---|---|
| 分发渠道 | GitHub Releases 发 DMG；不上 App Store；cask 非主渠道 |
| 应用名 | DSH Desktop for macOS（CFBundleName = DSH Desktop） |
| 图标 | 保留派生 favicon + 出处标注 + 免责声明 |
| 项目许可证 | MIT |
| 安装包内容 | 精简：不含 Node.js；提供一键在线安装运行时（M5） |
| **身份归属** | 统一到主号 **`Boy-Grid`**：LICENSE 署名、bundle ID `io.github.boy-grid.dsh-desktop`、仓库 `Boy-Grid/deepseek-harness-desktop-for-macos`。理由：与 [dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace) 同号才成生态；bundle ID 一旦随 DMG 发出就不能再改（等于换应用身份，状态目录与更新链会断） |
| **仓库名 vs 产品名** | 仓库名 `deepseek-harness-desktop-for-macos`（**搜索曝光**：用户搜的是 "deepseek harness desktop macos"），产品显示名保持 `DSH Desktop for macOS`。这个拆分是有意的：仓库名属于**描述性/指名式提及**（"给 X 用的桌面端"），配合免责声明属于低风险用法；而**应用自称**才是商标最敏感的位置，所以那里不带上游名 |
| **git 历史** | 首次公开前重写全部 commit 作者为 `Boy-Grid <172345750+Boy-Grid@users.noreply.github.com>`（旧身份 `grid@localhost` 不会关联到账号）。**公开之后改为正常新 commit，不再改写历史** |
| **双后端** | 原版 / mfw 可切换，默认原版，首次显式询问一次，附两个仓库链接；DSH home 可自定义；版本错开时禁止同 home 切到 mfw（见 §4.5） |
| **WebView 存储** | 改**持久**，且**每个标签一个独立的持久 store**（按标签 UUID 标识）。不能共享一个：DSH web UI 把当前会话记在 localStorage 的 `dsh.sessions.current` 并在加载时读回，且 UI 没有 URL 路由——共享一个 store 会让所有标签收敛到同一个会话，多标签并行就没了。附带好处是重启后每个标签回到各自的会话。关闭标签即删除其存储，崩溃遗留的孤立存储下次启动清理。随之**恢复标签手动重命名**（手动名优先于自动标题，并随标签持久化） |
| **最低系统版本** | **macOS 14.0**。带标识的 `WKWebsiteDataStore` 是 14 引入的，而代码本来就在用 `NSApplication.activate()`（也是 14+）。此前 plist 写 12.0 却从未被强制，属于失真的承诺 |
| **首个版本号** | `0.1.0`（此前 `Info.plist` 写着 1.0.0 但一次都没发过）。与 dsh-mfw 的节奏对齐，也如实传达"上游是 dev preview" |

### ❌ 试过又撤掉的

| 项 | 为什么撤 |
|---|---|
| **「启动工作目录」偏好项** | 原以为它决定新会话的默认工作目录——那是照 dsh-mfw 里一句注释（"DSH derives a session's default working directory from where it was launched"）做的推断，没查证就写进了 UI。实际查证：`dsh-tool-bash` 的 `resolveWorkdir()` 取 `policy.workspaceRoot`，其次是会话头的 `cwd`；web UI 建会话时的 `cwd` 来自**工作区行**；`process.cwd()` 只有 **headless 模式**用来播种会话（`dsh-headless/lib/index.js:72`），以及 `dsh-bash-local` 里的第三层兜底；目录选择器起点是 `homedir()`。也就是说这个设置在本应用的实际路径上不改变任何可观察行为——一个不改变行为、还配着错误说明的旋钮比没有更糟。**保留**的只是「不把 `/` 继承给子进程」这个卫生性修复，固定为主目录，不再暴露为设置 |

### ⏳ 待定（开工前需要）
1. ⏳ Apple Developer 账号：用户确认将申请（$99/年）；账号到位前先发未签名 DMG。**M1 开工时并行提交申请**；
2. ✅ 仓库名：`deepseek-harness-desktop-for-macos`（与本地目录名一致，见上表"仓库名 vs 产品名"）。

---

## 10. 风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| DSH dev preview 破坏性变更 | 高 | 版本锁定 + 每次上游发版跑兼容性冒烟 |
| **标签栏对齐依赖上游内部 CSS class**（`[class*="centerCol"]`，0.5 s 轮询注入 JS） | 中–高 | 上游改样式即静默失效（降级为不对齐，不崩）。需显式降级路径 + 日志 + 一条冒烟检查；这是转正后最高频的适配点 |
| **mfw 基线与系统 dsh 错开** | 中 | 版本错开守卫（§4.5.3）：拒绝在同一 DSH home 下切到 mfw，给出独立 home / 等 rebase 两条出路 |
| **mfw 扩大 Agent 写面** | 中 | 默认关闭 + 首次显式询问 + 偏好设置里再次提示 + README/About 写明；照抄 dsh-mfw 的安全须知口径 |
| **依赖 DSH 的 localStorage 键名 `dsh.sessions.current`** | 中 | 每标签独立存储的必要性建立在这个上游实现细节上。上游若改成 URL 路由，独立存储会从"必需"退化为"可选"，不会坏，只是多余 |
| **WebKit 静态 API 的初始化时序** | 低 | 在首个 WKWebView 之前调用 `WKWebsiteDataStore` 的类方法会崩（主 RunLoop 尚未初始化）。已把孤立存储清理挪到窗口建立之后，并在代码注释里写明因果 |
| 商标异议（保留 favicon） | 低–中 | 出处标注 + 免责声明 + 自有 bundle ID（M0 解决）；官方若正式提出，替换为独立图标（make-icon.py 流程仍在，成本低） |
| 签名/公证维护成本 | 中 | CI 自动化 + 证书备份流程 + $99/年预算 |
| 首次在线安装体验（网络/体积） | 中 | 进度条 + 断网降级 + 手动安装指引；按架构只下载所需二进制 |
| 官方将来出桌面版 | 中 | 差异化定位：本地多标签工作台、运行时管理、CLI 生态；保持跟随官方 API 变化 |
| 单人维护 burnout | 中 | 明确 scope、欢迎贡献、发布节奏放慢（跟随 DSH 而非每天发版） |
