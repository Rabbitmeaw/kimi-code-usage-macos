# 开发说明

本项目是 SwiftUI／AppKit 实现的 macOS 原生窗口伴随工具。面向普通用户的功能与安装方法见 [README](../README.md)。

## 环境与构建

需要 macOS 13+、Swift 5.9+，以及 Xcode 或 Command Line Tools。没有第三方运行时依赖。发布 ZIP 面向 Apple Silicon；Intel 构建与运行尚未验证。

在仓库根目录执行：

```sh
zsh scripts/build-app.sh
```

构建产物为 `dist/Kimi Usage.app`。更新运行中的版本时可用 `APP_OUTPUT_PATH` 指定新的打包位置，避免覆盖正在运行的可执行文件。脚本使用 Swift release 构建，移除调试符号和本机源码路径，将 MIT 与 Unicode 许可复制至 App 资源目录，再执行签名与签名校验。默认使用 ad-hoc 签名，也可通过 `CODESIGN_IDENTITY` 指定签名身份。当前发布包未进行 Apple 公证。

应用图标源文件为 `Resources/AppIcon.png`：白底小猪存钱罐，采用粗线条和从左到右的轻微蓝紫线性渐变。构建脚本使用 macOS 自带的 `sips` 生成 16～512pt 的标准与 @2x 图像，在 `.build/app-icon/` 中通过 `iconutil` 转为 `AppIcon.icns`，并在签名前写入主 App 和 watcher 的资源目录。当前 macOS 可能为应用图标附加系统圆角底板，实际显示由系统处理。

本次启动与本地鉴权修复通过 44 组本地核心检查，由独立 Swift runner 执行。测试目录、测试脚本、诊断过程记录和构建产物由 `.gitignore` 排除，本地保留，不随仓库提交。已验证的范围包括：

- Desktop usage 数据结构、错误状态、缺失额度和 loopback 地址过滤。
- 首次启动服务记录迟到、重启后 token／端口变化、有界重试、取消等待、业务错误不重试，以及旧失效实例不覆盖有效错误。
- 缺失私有令牌初始化、合法实例过滤、已有凭据保持、异常文件保护、并发排他发布，以及本地授权与上游账号错误区分。
- 重置时间解析、按分钟向上取整，以及小时／天数格式。
- 多显示器坐标转换、四角边界、目标窗口过滤和安装样式计算。
- 样式缓存命中、文件修改时间／大小／引用变更、显示缩放、安装路径变化与失败恢复。
- 3～6 档颜色映射、边界选择、单 emoji 校验及无效输入。
- 旧版配置兼容、背景颜色／不透明度校验、自动跟随默认值和显示设置 JSON 往返。

这些检查覆盖数据与计算逻辑。发布前还需实际确认原生菜单、系统取色器、窗口跟随、遮挡、自由拖动，以及保存和重启恢复。自动跟随还需验证 Kimi 启动／真正退出、隐藏／最小化、手动退出后等待下次启动、关闭开关，以及从「应用程序」重新打开显示设置。

## 代码结构

| 文件 | 责任 |
| --- | --- |
| `QuotaClient.swift` | 定位 Desktop 本地服务、读取并解析额度 |
| `Models.swift` | 额度快照与重置倒计时格式 |
| `UsageStore.swift`、`UsageView.swift` | 显示状态、额度卡与按分钟更新 |
| `AppController.swift` | 原生菜单、刷新、窗口附着、显示设置和客户端生命周期 |
| `WindowGeometry.swift`、`KimiWindowLocator.swift` | 目标窗口定位与坐标计算 |
| `WindowStyleReader.swift` | 从 Kimi 安装样式计算上下留距 |
| `QuotaBandSettings.swift`、`BandSettingsWindow.swift` | 档位模型、颜色和设置草稿 |
| `EmojiCatalog.swift` | Unicode emoji 序列白名单 |

## 数据来源与刷新

默认读取 `~/.kimi-code`，也支持 `KIMI_CODE_HOME` 环境变量。客户端从 `server/instances` 下的实例记录定位官方 Desktop 服务，使用 `server.token` 中的本地服务 token 请求：

```text
GET /api/v1/oauth/usage?provider=managed:kimi-code
```

只接受 localhost、127.0.0.1 或 ::1 的有效端口地址。请求使用临时 URLSession；本工具不读取 OAuth 凭证、不打印 token、不读取会话正文，也不直接访问第三方服务器。账号登录和续期由官方服务负责。

Kimi Code 1.0.4 的 Desktop 实际启动时注入 `createDesktopAuthTokenService`：官方界面通过请求头注入进程内令牌，服务同时接受已有的私有 `server.token`，但不会创建该文件。因此仅使用 Desktop 的新用户可能从未生成持久令牌；文件缺失时，官方界面仍可正常使用，卡片原先却无法鉴权。仅凭文件缺失不能认定是重新登录删除，重新打开 Desktop 也不保证补回。

卡片在存在合法实例且 `server.token` 真正不存在时，生成 32 字节安全随机 base64url 令牌。新文件以 0600 创建，完整写入私有临时文件后原子、排他发布到官方位置；并发创建时读取胜者，绝不覆盖已有令牌。已有空文件、宽松权限文件、符号链接或非普通文件只报错，不自动覆盖或改权限。不创建额外服务，不提取 Desktop 内存令牌。官方 Desktop 每次鉴权重新核对持久文件，新令牌无需重启即可使用。

App 安装位置不会改变额度数据目录。自定义 `KIMI_CODE_HOME` 必须传递给额度工具进程；Finder／LaunchAgent 启动不保证继承终端环境，当前工具不会自动扫描其他目录。只有 CLI 登录记录、没有支持上述接口的本地服务时无法读取。排查新用户持续获取失败时，应先核对两端的数据目录，再检查实例与登录状态。

界面将 `usedRatio` 换算成剩余百分比，并读取各额度窗口的 `resetAt`。未提供的额度保持缺失状态，不以 0% 代替。成功请求后才更新快照时间；失败保留旧快照并显示错误。

在已核对的 Kimi Code 1.0.4 中，官方套餐菜单显示同一个 `usedRatio` 的已使用整数百分比，并且只在打开账户菜单时获取一次用量；菜单保持打开不轮询。比较卡片与官方读数时，请先关闭并重新打开账户菜单，并对照卡片最近成功更新时间。官方重置时间向下取整到分钟，卡片向上取整，可能相差 1 分钟。

用量刷新间隔为 60 秒；卡片重新出现时，若上次数据已超过 60 秒，会立即刷新。每次读取遇到本地服务尚未连接，或令牌文件暂时不可用时，按 1、2、4、8 秒等待后重试，最多尝试 5 轮；每轮重新读取 token 与实例记录，恢复过程中保持获取状态。累计等待为 15 秒，实际网络请求超时另计。已连接服务返回本地授权、账号登录、业务或数据格式错误时不进入此重试；旧失效实例的连接错误也不会覆盖已收到的有效错误。取消刷新会立即结束等待。

倒计时使用 TimelineView 每分钟重算：5 小时窗口为 `0h00m`，7 天窗口为 `0d00h00m`，不足一天仍保留 `0d`。倒计时变化不会改写最近成功更新时间。

## 自动跟随与安装入口

v0.2.0 使用用户级 LaunchAgent 和 App bundle 内的独立 watcher。主 App 首次手动打开时，默认启用自动跟随，安装 `~/Library/LaunchAgents/com.yokinri.kimi-usage.follow.plist` 并加载 watcher。该用户级任务在登录时加载，但不会启动 Kimi。

watcher 通过 NSWorkspace 的应用事件观察 Kimi：初始检查时 Kimi 已在运行，或收到 Kimi 启动事件，才唤起主 App。主 App 在 Kimi 真正退出后自行关闭；隐藏或最小化只改变固定卡片可见性，不视为退出。自由模式同样遵循 `followsKimi` 开关，启用时也随 Kimi 退出而关闭。

后台唤起不弹显示设置，也不抢焦点。用户从「应用程序」首次打开或再次打开 App 时，会展示显示设置；Kimi 未运行时仍可管理配置。主 App 没有常驻 Dock 或菜单栏图标，应保留这个重新打开入口。

手动选择「退出 Kimi 额度」后，watcher 不会立即重新拉起；下一次 Kimi 启动时会再次唤起。watcher 自身重新加载时也会执行初始检查，Kimi 已运行时仍会唤起主 App。持续停用请关闭 `followsKimi` 并保存：主 App 对用户级任务执行 bootout 并移除 plist，当前主 App 可继续手动运行。用户也可以在 macOS 登录项设置中关闭后台活动。

安装流程为解压 ZIP、将 App 放至 `/Applications/Kimi Usage.app`，再手动打开一次。卸载应先在显示设置中关闭自动跟随并保存，再退出和移除 App，确保后台任务一并清理。

## 窗口与布局

卡片尺寸为 203×117pt。固定四角时隐藏标题、跟随 Kimi 窗口，失去前台焦点后允许其他应用正常遮挡；自由模式保留标题、使用浮动窗口层级并支持整卡拖动。右键菜单由独立 NSMenu 显示，可展开到卡片边界外。

v0.2.1 将固定模式窗口定位间隔调整为1秒，容差0.1秒；移动、缩放后约每秒更新位置，应用激活、隐藏、终止通知仍立即处理。自由模式及 macOS 会话不活跃时移除定位计时器，恢复固定模式或会话时重新创建并立即定位。定位先筛选目标进程与普通窗口，再解析几何；单次定位复用每块屏幕的边界；窗口排序索引仅在非活跃分支计算。现有位置去重与前台层级规则保留。

无需 Accessibility 或屏幕录制权限。窗口定位基于系统窗口列表；上下留距读取本机 Kimi 安装包 `Contents/Resources/desktop-dist/index.html` 引用的样式，计算顶部栏、账户区域尺寸、内边距和边框。固定模式且 Kimi 窗口可见时，约每30秒检查文件元数据；实例或显示缩放变化触发提前检查。安装路径、显示缩放或HTML及引用CSS的修改时间、大小变化时，重新读取解析；命中缓存时复用最近一次成功结果。读取失败可重试，不写死栏高。

布局解析以 Kimi Code 1.0.4 默认页面缩放为已验证范围，不测量临时页面状态或手动缩放后的实际渲染高度。样式无法识别时，会提供重新读取入口并暂放在窗口侧边中部；适配新版本时应更新解析和相应样式 fixture。

## 配置与显示设置

配置通过 UserDefaults 保存。档位与外观使用 `quotaBandSettings.v1`，其中 `followsKimi` 默认开启，旧配置缺少该字段时也按开启处理。位置模式使用 `attachmentCorner`，自由坐标使用 `freePanelOrigin`。移动项目目录或升级 App 时，应保持 Bundle Identifier 和配置键稳定，以保留用户已有设置。

档位数限制为 3～6；最低下限为 0，其余下限严格递增。每档包含一个有效 emoji，可选自定义 RGB 颜色；未自定义时按档位数使用默认调色顺序。两条额度条共用同一设置。

颜色通道和背景不透明度均使用 0～1 的有限数值。设置窗口显示的是透明度，换算关系为「不透明度 = 1 − 透明度」。渐变由当前档位颜色与白色混合后过渡至原色，额度条本身保持不透明，与背景透明度独立。

设置窗口使用 ObservableObject 草稿；保存通过校验后才写入，取消或关闭不会修改已保存配置。「恢复默认」会同时重置档位、自定义颜色、背景和渐变。旧配置缺少外观字段时使用默认值，保留原有阈值与 emoji。

## 诊断

构建后在仓库根目录执行：

```sh
"dist/Kimi Usage.app/Contents/MacOS/KimiUsage" --check-usage
"dist/Kimi Usage.app/Contents/MacOS/KimiUsage" --diagnose-window
"dist/Kimi Usage.app/Contents/MacOS/KimiUsage" --diagnose-stack
```

- `--check-usage`：输出 5 小时／7 天已用百分比和成功读取时间。
- `--diagnose-window`：输出前台应用、目标窗口几何、样式留距及四角位置。
- `--diagnose-stack`：输出卡片、Kimi 和前台应用的窗口排列、层级及几何。

上述命令不打印 token 或窗口正文。用诊断结果区分服务未运行、登录过期、额度格式变化和布局解析失败，再针对相应模块修改。

右键菜单显示最近一次具体错误：

- 「未连接 Kimi Code」：没有合法实例，或所有实例连接失败；检查官方 App 是否运行及两端数据目录是否一致。
- 「Kimi 本地令牌不可用」：检查同一数据目录下的 `server.token` 是否为当前用户可读、非空的普通文件，权限应为 0600。仅检查文件状态，不要把文件内容发到 Issues。卡片不会覆盖已有异常文件；确认文件用途后由用户修复其权限或恢复文件。
- 「Kimi 本地服务拒绝访问」：本地 HTTP 401／403，尚未通过桌面服务鉴权；核对令牌与实例是否来自同一数据目录。
- 「Kimi 登录已过期」：已通过本地鉴权，但官方服务返回账号登录错误；此时才需要回到官方 App 登录。

官方 [`kimi web rotate-token`](https://github.com/moonshotai/kimi-code/blob/main/docs/en/reference/kimi-command.md#kimi-web-rotate-token) 可以创建持久令牌，运行实例下一次鉴权自动采用。但它会替换已有令牌、使旧客户端凭据失效，卡片不会自动执行该命令，也不把它作为所有故障的通用处理方式。

## 许可与发布

项目代码采用 [MIT License](../LICENSE)。emoji 校验数据来自 [Unicode Emoji 17.0 emoji-test.txt](https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt) 的 fully-qualified 与 minimally-qualified 序列；排除 component 和 unqualified 条目。源文件说明与数据哈希保留在 `EmojiCatalog.swift` 顶部。

Unicode 数据受 [Unicode License V3](../THIRD_PARTY_LICENSES/Unicode-LICENSE.txt) 约束。分发源码与 App 时需保留该许可，构建脚本已将其复制到 App 资源中；MIT 许可不替代 Unicode 的第三方许可。

发布仓库为 [Rabbitmeaw/kimi-code-usage-macos](https://github.com/Rabbitmeaw/kimi-code-usage-macos)，下载入口为 [Releases](https://github.com/Rabbitmeaw/kimi-code-usage-macos/releases/latest)。v0.2.3 发布 Apple Silicon ZIP；发布时核对主 App 与 watcher 的版本、图标、目标架构、签名校验、第三方许可和压缩包内容，并验证从 `/Applications` 安装后首次打开、后台唤起及卸载清理。不要将本地服务记录、凭证、个人配置或测试运行产物提交到仓库。

当前源码包含启动重试与缺失令牌初始化，公开 v0.2.3 安装包尚未包含这些修复。构建脚本的版本标识仍为 0.2.3；仓库提交与推送不等同于发布新 Release。
