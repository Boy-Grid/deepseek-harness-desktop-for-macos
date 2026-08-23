# DSH Desktop for macOS

> **非官方声明**：本应用是独立开源项目，**与 DeepSeek 官方无关联**（not affiliated
> with, endorsed by, or sponsored by DeepSeek）。"DeepSeek" 与 "DeepSeek Harness"
> 为 DeepSeek 的商标；本应用图标由 DeepSeek Harness Web UI 的 favicon 派生，
> 出处与声明见 `THIRD_PARTY_NOTICES.md`。

一个 macOS 应用：双击即可拉起 DeepSeek Harness Web UI 并在**内置窗口**
（系统 WebView）中打开，不再使用浏览器标签页；窗口标题栏带**多标签栏**（与页面
中心列实时对齐），
可同时开多个页面、并行操作多个会话；应用进程在 **Dock 常驻**（普通图标，
无角标），与窗口构成**单向绑定**：关闭窗口不影响 Dock 图标与实例，右键退出
则连窗口带实例一起收掉；重复打开只会激活已有实例，不会起第二个进程。

## 使用方式

### 双击启动（人类用户）

双击 `DSH Desktop.app`（或从 Spotlight / 启动台打开）：

1. 应用进程（LauncherAgent）常驻 **Dock**，图标即 DSH 网页标志，无角标；
2. 探测 `http://127.0.0.1:3080`：没有服务则后台拉起 `dsh --profile web`
   （日志写入状态目录的 `logs/web.log`），最多等待 60 秒就绪；
3. 在**内置窗口**（WKWebView）中打开 Web UI——不再打开浏览器标签页；
   支持 ⌘C/⌘V/⌘X/⌘A/⌘Z 等标准快捷键（菜单栏含完整"编辑"菜单）；
4. **多标签页**（标签行**内嵌于窗口标题栏**、与红绿灯同一行；chrome 区高度为可调
   常量，当前 40pt；条带的**左右位置与宽度和页面中心列实时对齐**——向 WebView 注入
   JS 读取 `centerCol` 元素的实时 DOM 几何，拖拽侧栏时标签行跟随同步，永不越出窗口；
   条带内从左到右 = **[+] [滚动区]**，滚动区内容**右锚定**，标签按**从右向左**排列；
   ×/＋ 为 SF Symbols、光学居中）：
   - **新建**：`+` 按钮 / ⌘T / 右键→新建标签页；新标签出现在**最左端**、
     紧邻 `+`，旧标签依次向右移（最老的标签在最右端）；标签过多时横向
     滚动，切换时自动把目标标签滚入视野；
   - **关闭**：标签上的 × / ⌘W / 右键→关闭；关闭后自动激活相邻标签；
     关到 0 个时显示空状态（点大"+"新建）；上限 **8** 个；
   - **命名**：标签名默认**自动跟随网页标题**（DSH 会在新建/切换会话时更新标题）；
     **双击标签**或右键→重命名可手动改名，改名后不再被自动标题覆盖，名字随标签一起
     持久化；
   - **每个标签有自己的持久化存储**：页面内的偏好、主题等重启后仍在，且各标签互不
     干扰——重启后每个标签会回到**它自己**上次的会话（原理见下节）；
   - 右键菜单：重命名 / 关闭标签页 / 关闭其他标签页 / 新建标签页；
   - **拖拽排序**：按住标签横向拖动（位移 >4pt 触发，不会误触窗口拖动），被拖
     标签浮起跟随鼠标，越过相邻标签中点时其余标签以共享动画让位；拖到滚动区
     边缘 96pt 内会自动滚动继续拖；松手归位并提交新顺序（自动标题/选中状态
     跟随原标签）；
   - **滚轮横滑**：鼠标悬在标签行上时，滚轮/触控板纵向滚动映射为标签行横向
     滚动（×4 系数；上滚向左、下滚向右）；方向自动遵循系统"自然滚动"设置
     （读取 scrollingDelta，AppKit 已内置偏好换算）；
   - ⌘R 重新加载当前标签；⇧⌘W 关闭窗口；
   - 每个标签是**独立的页面**（独立 WebView 与浏览器存储），可各自操作
     不同的会话，并行工作；所有标签共用同一个实例；
   - 页面内"新开窗口"请求（同源）自动转为新标签；外链仍在系统浏览器打开；
   - **动画**：新建标签从 `+` 侧滑入淡入，关闭标签左滑淡出，其余受影响的标签
     在同一动画组内同步滑动让位（0.25s）；滚动区左右两端有**溢出淡入出指示**
     ——内容超出对应一侧时渐变淡入，滚到尽头时淡出；
5. **外链外放**：窗口内点击任何非本机 Harness 的网址（如 agent 发给你的链接）
   会转交**系统默认浏览器**打开，不会在窗口内跳转；
6. **单向绑定（Dock → 窗口）**：
   - 关闭窗口（红色关闭按钮）→ **不影响** Dock 图标与实例，
     实例继续运行，随时可再点开；
   - **右键 Dock 图标 → 退出**（或 ⌘Q）→ 窗口随之关闭，并先停掉应用自己
     拉起的 dsh 实例再退出；非本应用启动的实例不会被误杀；
7. **再次打开**（重复双击 / Spotlight / 点击 Dock 图标）不会起第二个进程，
   只会确保实例在跑并重新打开窗口；
   - **缩放动画与内容同步**：绿点最大化切换由应用自行逐帧驱动
     （60fps setFrame），WebView 视口随窗口每一帧同步变形，不再"动画结束后
     闪现到最终状态"；
8. 无任何通知打扰；仅当启动失败时弹出对话框，显示失败原因与日志路径。

### 命令行（给 agent 用）

```sh
APP="$HOME/Applications/DSH Desktop.app"
L="$APP/Contents/MacOS/launcher"

"$L" status              # running/stopped、端口、占用者（是否由本应用管理）
"$L" start               # 未运行则启动，等待就绪
"$L" stop                # 停止自己启动的实例（绝不碰别人占的端口）
"$L" restart             # 停止并重新启动
"$L" open                # 在默认浏览器中打开（终端用途；GUI 已改用内置窗口）
"$L" launch              # 等价于：start + open，无通知
```

### 多实例（CLI）

CLI **保留多开能力**：每个端口一个独立实例，互不干扰。非默认端口且未指定
`--state` 时，自动使用独立的 per-port 状态目录
（`.../DSH Desktop/ports/<端口>`），pid、日志各自独立：

```sh
"$L" --port 3099 start        # 实例 A：状态在 .../ports/3099/
"$L" --port 3100 start        # 实例 B：状态在 .../ports/3100/
"$L" --port 3099 status       # 各自查询
"$L" --port 3100 stop         # 各自停止
```

> GUI（双击）是单实例的——单实例限制只作用于 Dock/LaunchServices 层；
> 命令行不受限制。指定 `--state` 可完全自定义状态目录位置。

环境变量 / 参数覆盖（**双击启动时使用默认值**；env 覆盖仅对 CLI 和直接运行
agent 生效，例如 `env DSH_LAUNCHER_PORT=3099 .../LauncherAgent`）：

| 变量 | 参数 | 默认 |
|---|---|---|
| `DSH_LAUNCHER_PORT` | `--port <n>` | `3080` |
| `DSH_LAUNCHER_BACKEND` | `--backend <stock\|mfw>` | `stock`（见下节） |
| `DSH_LAUNCHER_DSH` | `--dsh <path>` | 自动探测（PATH、`~/.npm/_npx/*/...`，结果缓存到状态目录） |
| `DSH_LAUNCHER_MFW` | `--mfw <path>` | 自动探测 `dsh-mfw`（PATH、npx 缓存），仅 mfw 后端用 |
| `DSH_LAUNCHER_NODE` | `--node <path>` | 自动探测（PATH、nvm/volta/fnm/`~/.local/bin`/brew，缓存到状态目录） |
| `DSH_LAUNCHER_DSH_HOME` | `--dsh-home <dir>` | `$DSH_HOME`，未设则 `~/.dsh` |
| `DSH_LAUNCHER_ALLOW_VERSION_SKEW=1` | `--allow-version-skew` | 关（见下节的版本错开守卫） |
| `DSH_LAUNCHER_STATE` | `--state <dir>` | `~/Library/Application Support/DSH Desktop` |
| `DSH_LAUNCHER_NO_BROWSER=1` | `--no-browser` | 仅影响 CLI 的 `open`/`launch`（GUI 已用内置窗口，不涉及浏览器） |

> **为什么需要单独解析 node**：双击启动的应用 PATH 只有系统默认值
> （`/usr/bin:/bin:/usr/sbin:/sbin`），nvm/`~/.local` 等安装的 node 不在其中，
> 而 `dsh` 的 shim 是 `#!/usr/bin/env node`，会直接启动失败。应用会显式解析
> node 并用 `node <dsh入口>` 直接执行，子进程也会带上 node **realpath** 所在的
> 目录——`pnpm` 与 `corepack` 装在真正的 node 旁边，而 `~/.local/bin` 这类
> symlink 目录通常只有 `node`/`npm`/`npx`，mfw 后端因此会找不到包管理器。

### 两个后端：原版 DSH 与 dsh-mfw

| 后端 | 启动的东西 |
|---|---|
| `stock`（默认） | 你自己安装的 `dsh` |
| `mfw` | [dsh-mfw](https://github.com/Boy-Grid/dsh-multi-folder-workspace)，它准备一棵打了补丁的 dsh 运行时，让**一个工作区可以包含多个分散的文件夹** |

```sh
"$L" start --backend mfw            # 首次会准备约 300 MB 运行时（联网，10–30 s）
"$L" status --backend mfw           # 状态目录、DSH home、归属
```

两个后端的状态目录是分开的（`.../DSH Desktop/mfw/...`），所以可以并行跑在不同
端口上，互不干扰；`$DSH_HOME` 则默认共享，会话与凭据两边都能看到。

> ⚠️ **mfw 会扩大 Agent 的写面**：工作区内的会话可以写入**全部成员文件夹**，
> 而不只是它自己的工作目录。所以它不是默认值，需要你显式选择。
>
> **版本错开守卫**：dsh-mfw 精确 pin 一个 dsh 基线。当它与你已安装的 dsh 版本
> 已经错开时，启动器会**拒绝**在原版也在用的那个 `$DSH_HOME` 下启动 mfw——更新
> 的 dsh 可能已把记录写成新格式，而反方向（原版重写记录）会把成员列表剥掉。
> 出路是 `--dsh-home <独立目录>`，或等 dsh-mfw rebase 到新基线。

## 测试

零外部依赖，不需要装 DSH 也能跑（用替身 dsh / 替身 dsh-mfw）：

```sh
bash tests/run.sh          # 全部
bash tests/run.sh t-04     # 只跑名字含 t-04 的
```

6 个文件 / 150 条断言，重点覆盖「只停自己启动的服务」这条安全承诺、归属判定、
后端与路径解析、以及完整的启动流程。跑不了的用例会显式列为 SKIP，不会读成通过。
`shellcheck` 装了就一并跑。CI 见 `.github/workflows/ci.yml`。

## 偏好设置

菜单栏 **「DSH Desktop → 偏好设置…」**（⌘,）三项：

| 设置 | 说明 |
|---|---|
| **启动哪个 DSH** | 原版 / 多文件夹工作区（dsh-mfw），附两个项目仓库链接。切换会提示"需要重启实例"，同意后自动 stop → start → 重载全部标签 |
| **DSH home** | 会话与凭据的位置，默认 `~/.dsh`。两个后端默认共享；当 dsh-mfw 的基线与已安装 dsh 版本错开时，必须在这里指定独立目录才能启动 mfw |

> 顺带一提：双击启动的应用其进程工作目录是 `/`（实测确认），本应用给 dsh 子进程改成
> 用户主目录——继承一个 `/` 会让任何相对路径写入落到磁盘根。这纯粹是卫生问题，**不**
> 决定会话里工具的执行目录：那个由工作区决定（`dsh-tool-bash` 的 `resolveWorkdir` 取
> `policy.workspaceRoot`，其次是会话头的 `cwd`），只有 headless 模式会用启动位置去
> 播种会话。所以这里没有对应的设置项。

**首次安装后会显式询问一次**要用哪个后端，说明各自能力与代价，之后不再打扰。默认是
原版——多文件夹工作区会扩大 Agent 的写面（工作区内的会话可写入全部成员文件夹），
这是安全语义的变化，不该由默认值替你决定。

### 为什么是"每个标签一个持久化存储"

DSH web UI 把**当前会话记在 localStorage 的 `dsh.sessions.current`** 里，并在页面加载时
读回来，而且整个 UI 没有 URL 路由。所以如果所有标签共享一个持久化存储，每个标签切会话
都会覆写同一个键，新开标签和重启后全部标签都会落到同一个会话上——多标签并行不同会话
这件事就没了。

因此每个标签有自己的 `WKWebsiteDataStore`（按标签 UUID 标识，落在
`~/Library/WebKit/io.github.boy-grid.dsh-desktop/WebsiteDataStore/<uuid>/`）：会话彼此独立，
设置各自保留，重启后各回各自的会话。关闭标签时会连同它的存储一并删除；崩溃或强制退出
遗留下来的孤立存储在下次启动时清理。

> 这也是本应用要求 **macOS 14+** 的原因：带标识的 `WKWebsiteDataStore` 是 macOS 14 引入
> 的 API。

## 安全设计

- 应用把**自己拉起的进程 PID** 记录在状态目录的 `web.pid`；
- `stop` 只允许杀掉这个 PID 的进程树（SIGTERM → 等待 → SIGKILL）；
- 若端口上有服务但并非本应用启动（例如终端里手动起的 `dsh web`），
  `stop` 会**拒绝**操作并提示，避免误杀他人进程；
- Dock 退出（Quit）走同一套 `stop` 逻辑：只停托管实例。

## 故障排查

- 启动失败时，弹窗会直接显示**失败原因**，同时日志目录总会先被创建，
  原因也会写入 `logs/web.log`；
- 查看日志时路径含空格，记得加引号：

  ```sh
  cat "$HOME/Library/Application Support/DSH Desktop/logs/web.log"
  ```

- 从旧版（DeepSeek Harness Launcher）升级而来：旧状态目录
  `~/Library/Application Support/DeepSeek Harness Launcher` 已不再使用，
  确认旧实例已退出后可手动删除。

## 构建与安装

仓库内 `build.sh` 一键重建应用：拷贝资源 → 编译 agent → 签名 →（可选）注册。

```sh
cd deepseek-harness-desktop-for-macos
./build.sh --register                     # 重建到默认位置并刷新系统注册
./build.sh --output /tmp/test.app         # 构建到其他位置（不带注册）
```

默认输出 `~/Applications/DSH Desktop.app`。**系统要求 macOS 14+**（原因见上面的
"每个标签一个持久化存储"）。

> 注：签名顺序有讲究——`launcher` 脚本需先单独 `codesign -s -`，再签整个
> bundle，否则 codesign 会因 MacOS/ 内存在未签名的脚本子组件而报错
> （`build.sh` 已按此顺序处理）。
>
> 部署目标取自 `Info.plist` 的 `LSMinimumSystemVersion`，构建后再校验二进制的
> `minos` 与之一致。不显式传 `-target` 的话，swiftc 会把**构建机**的系统版本写进
> 二进制——在 macOS 26 上构建出的包在更早的系统上根本起不来，而 plist 却声称支持。

## 目录结构（仓库）

```
deepseek-harness-desktop-for-macos/
├── main.swift            # 入口（多文件目标下顶层语句只能放在 main.swift）
├── LauncherAgent.swift   # GUI 主程序（Swift/AppKit）：Dock 常驻、WebView 多标签、外链外放、退出清理、单实例
├── Preferences.swift     # 后端/DSH home/工作目录的设置模型、首次运行询问、偏好设置窗口
├── TabStore.swift        # 每标签持久化存储的创建、删除与孤立清理
├── launcher              # CLI 脚本：start/stop/status/open/launch、stock/mfw 双后端、按(后端,端口)分区的状态目录
├── Info.plist            # app bundle 元数据（CFBundleExecutable = LauncherAgent）
├── icon.icns             # 应用图标（DSH favicon 派生，见"重新生成图标"与 THIRD_PARTY_NOTICES.md）
├── make-icon.py          # 图标合成脚本（纯 Python 标准库）
├── build.sh              # 一键构建 / 签名 / 注册
├── tests/                # 测试套件（纯 bash，无外部依赖）
│   ├── run.sh            #   跑全部 t-*.sh，汇总失败与跳过
│   ├── lib/assert.sh     #   断言 helper
│   ├── t-0*.sh           #   路径解析 / 参数 / mfw 守卫 / 安全承诺 / lint / 启动全程
│   └── fixtures/         #   替身 dsh、替身 dsh-mfw、替身「他人的服务」
├── .github/workflows/    # CI：lint + 测试 + 构建并校验 bundle
├── LICENSE               # MIT
├── THIRD_PARTY_NOTICES.md
├── OPENSOURCE-PLAN.md    # 开源改造规划
├── Resources-README.md   # 构建后成为 Contents/Resources/README.md
└── README.md
```

构建产物 `DSH Desktop.app/Contents/`：

```
├── Info.plist
├── MacOS/
│   ├── LauncherAgent     # 编译自 LauncherAgent.swift
│   └── launcher          # 即仓库内的 launcher 脚本
└── Resources/
    ├── icon.icns
    └── README.md
```

## 重新生成图标

应用图标使用 DeepSeek Harness 网页自身的标志（**派生使用，出处见
`THIRD_PARTY_NOTICES.md`**）：从运行中的 GUI 拉取
`http://127.0.0.1:3080/favicon.svg`，光栅化后由 `make-icon.py` 合成到
macOS 风格的渐变圆角底上（纯 Python 标准库，无第三方依赖）。

```sh
# 1. 拉取网页标志并渲染成 1024×1024 PNG
curl -s http://127.0.0.1:3080/favicon.svg -o /tmp/favicon.svg
sed 's/width="50.000000" height="50.000000"/width="1024" height="1024"/' /tmp/favicon.svg > /tmp/favicon_1024.svg
sips -s format png /tmp/favicon_1024.svg --out /tmp/logo_1024.png

# 2. 合成（白色 logo + 投影 + 光晕 + 渐变圆角底）
python3 make-icon.py /tmp/logo_1024.png /tmp/icon_final_1024.png

# 3. 打包 .icns 并替换进应用
cd "DSH Desktop.app/Contents/Resources"
# （sips 生成各尺寸 → iconutil -c icns icon.iconset -o icon.icns）

# 4. 刷新系统注册与 Spotlight 索引
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "DSH Desktop.app" && mdimport -i "DSH Desktop.app"
```

## 许可与致谢

应用内 **「DSH Desktop → 关于 DSH Desktop」** 同样载有图标出处标注、商标说明与
免责声明。

- 本项目代码：**MIT**（见 `LICENSE`）；
- 托管的 DeepSeek Harness（`dsh`）为 DeepSeek 的开源项目，MIT 许可；
- 第三方声明与图标出处：见 `THIRD_PARTY_NOTICES.md`；
- 本应用与 DeepSeek 官方无关联。
