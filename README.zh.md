# DSH Desktop for macOS

[![CI](https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

[English](README.md)

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI
一个原生 macOS 窗口：双击启动，在一个窗口里并行操作多个会话，实例的生命周期由应用
自己负责。

> **非官方项目。** 独立开源项目，与 DeepSeek 无隶属关系，也未获其背书。
> "DeepSeek" 与 "DeepSeek Harness" 是 DeepSeek 的商标。应用图标派生自 DeepSeek
> Harness Web UI 的 favicon，出处见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 为什么做这个

在终端里跑 `dsh web`、把页面留在浏览器标签里当然能用，只是那个标签是三十个里的一个；
服务比窗口活得久，却没人真的在管它；想同时开几个会话，就得开几个浏览器标签，而它们
共用同一份浏览器存储、互相打架。这个应用把 harness 变成一个正常的桌面程序：

- **一个窗口，多个会话。** 标题栏里最多 8 个标签，每个是独立的 WebView、有自己的
  存储，全部由同一个实例提供服务。
- **实例归应用管。** 需要时启动 `dsh`，退出时停掉——并且只停自己启动的那个
  （见 [SECURITY.md](SECURITY.md)）。
- **关窗不等于退出。** 实例继续跑，再打开是瞬间的事。从 Dock 退出或 ⌘Q 才会把两者
  一起收掉。
- **外链外放。** 任何不是本机 harness 的地址都交给系统默认浏览器，不会让窗口跳走。
- **可选的多文件夹工作区**，通过一个需要你显式选择的第二后端提供。

## 系统要求

- macOS 14 或更新（每标签的持久化存储用的是这个版本引入的 API）
- Node.js，以及你自己安装的 DeepSeek Harness——本应用**既不捆绑也不代为下载**运行时：
  ```sh
  npm install -g @deepseek-ai/dsh
  ```
- 仅多文件夹后端需要：Node.js 22+ 与 pnpm 11+（或 corepack）

## 安装

从 [Releases](https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos/releases)
下载磁盘映像，打开后把应用拖进「应用程序」。映像带 Developer ID 签名并已公证，打开时
不会被 Gatekeeper 拦。

建议校验一下下载到的东西：

```sh
shasum -a 256 -c SHA256SUMS
spctl --assess --type open --context context:primary-signature -v <dmg>
# 期望：accepted / source=Notarized Developer ID
```

## 从源码构建

```sh
git clone https://github.com/Boy-Grid/deepseek-harness-desktop-for-macos.git
cd deepseek-harness-desktop-for-macos
./build.sh --register
```

它会拷贝资源、编译 agent、签名，并刷新 LaunchServices。默认输出
`~/Applications/DSH Desktop.app`；`--output <路径>` 可以构建到别处且不注册。

部署目标取自 `Info.plist` 的 `LSMinimumSystemVersion`，构建后会校验二进制的 `minos`
与之一致。不显式传 `-target` 的话，`swiftc` 会把**构建机**的系统版本写进二进制，于是
这个包在任何比构建机更旧的系统上都起不来——而 plist 看起来还很宽容。

默认构建是 ad-hoc 签名，本地跑够用了。

### 发布

`scripts/make-dmg.sh` 从源码一路做到「打开时不会被 Gatekeeper 拦」的磁盘映像：通用
二进制（Apple Silicon 与 Intel）、Developer ID 签名、hardened runtime、安全时间戳、
经 Apple 公证，并把票据装订进映像。

```sh
./scripts/make-dmg.sh                  # 构建 --release、打包、公证、装订
./scripts/make-dmg.sh --skip-notarize  # 只出签名映像，用于试跑
```

公证凭据从钥匙串读，所以不会出现在命令行或仓库里的任何文件中。一次性配置：

```sh
xcrun notarytool store-credentials "dsh-desktop-notary" \
  --key <AuthKey_XXXXXXXXXX.p8> --key-id <Key ID> --issuer <Issuer ID>
```

公证只认 App Store Connect 的 **Team Key**；用 Individual Key 会拿到一个不解释原因的
401。

签名在维护者本机做，不在 CI 里。否则 Developer ID 私钥就得放进仓库 secrets——为了一年
省几次命令，把泄露后的影响面扩大得多。发布 workflow 只负责校验 tag 并开一个 draft，
映像在本地上传上去。

## 两个后端

| 后端 | 启动的东西 |
|---|---|
| `stock`（默认） | 你自己安装的 `dsh` |
| `mfw` | [dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace)，它准备一棵打了补丁的运行时，让**一个工作区可以包含多个分散的文件夹** |

在 **DSH Desktop → 偏好设置**（⌘,）里选，或者用命令行：

```sh
"$L" start --backend mfw     # 首次会准备约 300 MB 运行时（10–30 秒）
```

> ⚠️ **多文件夹后端会扩大 Agent 的写面**：工作区内的会话可以写入**全部**成员文件夹，
> 而不只是它自己的工作目录。这是安全语义的变化，所以它不是默认值，也绝不会被隐式
> 选中——应用会在首次运行时明确问你一次。

两个后端各有独立的状态目录，因此可以并行跑在不同端口上。它们默认共享 `$DSH_HOME`，
所以会话与凭据两边都能看到。

**版本错开守卫。** dsh-mfw 精确 pin 一个 dsh 基线。当这个基线与你已安装的 dsh 版本
错开时，启动器会拒绝在原版也在用的那个 home 下启动 mfw：更新的 dsh 可能已经把记录写
成了 pin 住的旧基线不认识的格式，而反方向同样是破坏性的——原版第一次重写工作区记录时
会把额外的成员列表剥掉。出路是用一个独立的 home（`--dsh-home <目录>`，或偏好设置里的
那一项），或者等 dsh-mfw rebase 到新基线。

## 偏好设置

⌘, 里有两项，改动都需要重启被托管的实例：

| 设置 | 说明 |
|---|---|
| **启动哪个 dsh** | 原版或多文件夹，附两个项目的链接 |
| **DSH home** | 会话与凭据的位置，默认 `~/.dsh`；也是基线错开时的出路 |

切换会先停掉正在跑的实例、再启动新的，然后重载全部标签。如果停不掉，会如实报告切换
失败，而不是悄悄什么都没做。

## 标签

`+`、⌘T 或右键菜单新建；最新的紧邻 `+`，更早的依次向右。用标签上的 ×、⌘W 或右键菜单
关闭。拖动可以重排。⌘R 重载当前标签，⇧⌘W 关闭窗口。

标签名默认跟随网页标题，harness 会在新建和切换会话时更新它。双击标签（或右键 →
重命名）可以自己命名；手动名优先于自动标题，并且会被记住。

### 为什么每个标签有自己的持久化存储

harness 的 Web UI 把当前会话记在 `localStorage` 的 `dsh.sessions.current` 里，并在页面
加载时读回来，而整个 UI 没有 URL 路由。如果共享一份存储，每个标签都会覆写这同一个键，
于是新开的标签、以及重启之后的所有标签，都会收敛到同一个会话上——而这恰恰是"开多个
标签"想避免的事。

所以每个标签有自己的 `WKWebsiteDataStore`，按标签的 UUID 标识，落在
`~/Library/WebKit/io.github.boy-grid.dsh-desktop/WebsiteDataStore/<uuid>/`。会话彼此
独立，页面级设置能活过重启，每个标签回到**它自己**上次的会话。关闭标签会连它的存储
一起删掉；崩溃遗留的孤立存储在下次启动时清理。

## 命令行

所有与实例生命周期有关的逻辑都在一个 shell 脚本里，GUI 也是调它。它单独用也有价值——
写脚本、开第二个实例、或者排查一次启动失败。

```sh
L="$HOME/Applications/DSH Desktop.app/Contents/MacOS/launcher"

"$L" status     # 在跑还是停了、哪个后端、哪个 home、端口归谁
"$L" start      # 未运行则启动，等到能响应
"$L" stop       # 停掉本启动器启动的那个实例
"$L" restart
"$L" open       # 在默认浏览器里打开
"$L" launch     # start + open
"$L" help
```

| 参数 | 环境变量 | 默认 |
|---|---|---|
| `--port <n>` | `DSH_LAUNCHER_PORT` | `3080` |
| `--backend <stock\|mfw>` | `DSH_LAUNCHER_BACKEND` | `stock` |
| `--dsh <path>` | `DSH_LAUNCHER_DSH` | 自动探测，结果缓存进状态目录 |
| `--mfw <path>` | `DSH_LAUNCHER_MFW` | 自动探测（仅 mfw 后端） |
| `--node <path>` | `DSH_LAUNCHER_NODE` | 自动探测并缓存 |
| `--dsh-home <dir>` | `DSH_LAUNCHER_DSH_HOME` | `$DSH_HOME`，未设则 `~/.dsh` |
| `--allow-version-skew` | `DSH_LAUNCHER_ALLOW_VERSION_SKEW=1` | 关 |
| `--state <dir>` | `DSH_LAUNCHER_STATE` | `~/Library/Application Support/DSH Desktop` |
| `--no-browser` | `DSH_LAUNCHER_NO_BROWSER=1` | 关（只影响 `open`/`launch`） |

状态按后端与端口分区——非 stock 后端多一级 `<backend>`，非默认端口多一级
`ports/<port>`——所以两个以不同方式启动的实例永远不会共用 pid 文件或日志：

```sh
"$L" --port 3099 start                    # 第二个实例
"$L" --port 3099 stop
```

GUI 是单实例的（LaunchServices 会激活已在运行的应用，而不是再起一个）；命令行不受限制。

**为什么要单独解析 node。** 双击启动的应用只拿到系统 PATH，所以用 nvm、volta 或装在
`~/.local` 里的 node 是看不见的——而 `dsh` 的 shim 是 `#!/usr/bin/env node`，会直接失败。
启动器自己解析 node，并以 `node <入口>` 的方式运行。子进程的 PATH 用的是 node 的
**realpath** 目录，因为 `pnpm` 与 `corepack` 装在真正的二进制旁边，而 `~/.local/bin`
这类 symlink 目录通常只有 `node`、`npm`、`npx`——这一点弄错的话，即使 mfw 的运行时已经
准备好了，它也会找不到包管理器。

## 安全模型

简版：应用记下自己启动的 pid，并在向任何进程发信号之前，先确认端口上的监听者确实属于
那个 pid 的进程树。被别人占着的端口——你在终端里起的 `dsh web`，或者一个复用了旧 pid
的无关进程——会被拒绝操作，而不是被停掉。细节与漏洞报告流程见 [SECURITY.md](SECURITY.md)。

## 测试

没有测试框架，也没有外部依赖；用替身 `dsh` 与替身 `dsh-mfw`，所以两者都没装的机器上
也能跑。

```sh
bash tests/run.sh          # 全部
bash tests/run.sh t-04     # 名字含 "t-04" 的
```

覆盖「只停自己启动的服务」这条承诺、归属判定、后端与路径解析、mfw 的几道守卫，
以及完整的启动流程。在本机跑不了的用例会显式列为 SKIP，不会安静地
算作通过。装了 `shellcheck` 就一并跑。

## 故障排查

启动失败会在对话框里给出原因，同时写进日志。日志目录在任何环节可能失败之前就已建好，
所以总有地方可查：

```sh
cat "$HOME/Library/Application Support/DSH Desktop/logs/web.log"   # 实例
cat "$HOME/Library/Application Support/DSH Desktop/logs/agent.log" # 应用
```

非默认端口或 mfw 后端要看 `mfw/` 与 `ports/<port>/` 下面；`"$L" status` 会打印它实际
解析出的状态目录。

## 仓库结构

```
main.swift              入口（顶层语句只能放这里）
LauncherAgent.swift     AppKit GUI：窗口、标题栏标签条、WebView、菜单
Preferences.swift       设置模型、首次运行询问、偏好设置窗口
TabStore.swift          每标签持久化存储：创建、删除、清理孤立项
launcher                实例生命周期：start/stop/status、双后端、状态目录
Info.plist              bundle 元数据；LSMinimumSystemVersion 决定构建目标
icon.icns, make-icon.py 应用图标与合成脚本
build.sh                组装、编译、签名、注册
tests/                  run.sh、lib/assert.sh、t-*.sh、fixtures/
.github/workflows/      CI：lint、测试、构建并校验 bundle
```

## 重新生成图标

图标派生自 harness Web UI 自己的 favicon（出处见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）：从运行中的实例取回、光栅化，再用
`make-icon.py` 合成到 macOS 风格的渐变圆角底上（纯 Python 标准库）。

```sh
curl -s http://127.0.0.1:3080/favicon.svg -o /tmp/favicon.svg
sed 's/width="50.000000" height="50.000000"/width="1024" height="1024"/' \
    /tmp/favicon.svg > /tmp/favicon_1024.svg
sips -s format png /tmp/favicon_1024.svg --out /tmp/logo_1024.png
python3 make-icon.py /tmp/logo_1024.png /tmp/icon_final_1024.png
# 之后：sips 生成各尺寸 → iconutil -c icns icon.iconset -o icon.icns
```

## 许可与致谢

MIT，见 [LICENSE](LICENSE)。被托管的 DeepSeek Harness 是 DeepSeek 自己的 MIT 项目。
第三方声明与图标出处见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；应用内
**DSH Desktop → 关于 DSH Desktop** 载有同样的声明。

欢迎贡献，见 [CONTRIBUTING.md](CONTRIBUTING.md)。
