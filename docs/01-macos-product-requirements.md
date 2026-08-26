# NimbusSync macOS 客户端产品需求文档

> 文档类型：产品需求文档（PRD）  
> 状态：Reviewed Draft 1.3
> 日期：2026-08-25  
> 目标产品名称：NimbusSync
> 参考实现：[`cloudreve/desktop@7144740`](https://github.com/cloudreve/desktop/tree/71447408df6db38362703fbbb61dc534ea210470)  
> 配套技术调研：[Cloudreve Desktop macOS 复刻方案调研](./00-macos-port-research.md)

## 1. 文档目的

本文档在盘点 Cloudreve Windows Desktop 实际功能与界面布局的基础上，定义 macOS 目标产品的：

- 产品目标、用户和核心场景；
- 功能边界与版本优先级；
- 页面、窗口、菜单栏和 Finder 信息架构；
- 同步、冲突、删除、忽略和恢复规则；
- 可验证的功能需求与验收标准；
- 性能、安全、兼容性和发布要求。

本文档描述产品应提供的能力，不替代 File Provider/Rust 核心的详细技术设计。

## 2. 产品定义

NimbusSync 是面向自托管 Cloudreve 用户的原生菜单栏与 Finder 云盘同步客户端。用户完成一次授权后，应能在 Finder 中浏览远端文件、按需下载、直接编辑，并让本地与 Cloudreve 自动保持一致。

### 2.1 核心价值

1. **Finder 原生访问**：用户不需要通过网页完成日常文件操作。
2. **按需占用空间**：默认展示完整远端目录，但只在打开文件时下载内容。
3. **可靠双向同步**：本地和远端变化都能自动传播，断网和进程重启后可恢复。
4. **多实例管理**：同一客户端可以连接多个 Cloudreve 实例、账号或远端目录。
5. **可理解的异常处理**：认证过期、冲突、空间不足和服务器不可达都有明确状态与恢复入口。

### 2.2 产品原则

- Finder 是文件操作主界面，菜单栏是状态与任务入口，设置窗口是配置入口。
- 正确性优先于实时性；SSE 丢失时必须依靠 reconciliation 恢复。
- 不静默覆盖冲突文件，不静默删除用户的远端数据。
- File Provider Extension 不依赖主应用持续运行。
- 菜单栏主应用负责实时事件与周期校准；用户退出或禁用登录启动后，已知 item 的按需读写仍可工作，但已 materialized 目录不会获得主动远端推送，产品必须明确这一新鲜度边界。
- 凭据只进入 Keychain，不进入普通配置、数据库、崩溃报告或日志。
- Domain 远端根绑定稳定实体身份；路径只作为可更新的路由信息，不能在原根被移动、删除或替换后悄悄绑定到同路径的新对象。
- File Provider 已确认的本地写入与服务端 SSE 回声必须合并，不能形成重复下载、重复提示或同步循环。
- 遵循 macOS 平台交互，不复制 Windows 控件和任意同步根行为。

### 2.3 非目标

1. 不在 1.0 中复刻 Cloudreve Web 的完整文件管理界面。
2. 不提供服务端管理、用户管理、存储策略管理和分享管理后台。
3. 不在 1.0 中提供 iOS/iPadOS 客户端。
4. 不把任意本地目录同步作为 File Provider 模式的一部分。
5. 不支持绕过 TLS 验证的“不安全连接”模式。
6. 不保证复用或兼容 Windows 客户端本地 inventory 数据库。
7. 不把 SSE 当作唯一变化来源或永久事件日志。
8. 不承诺所有 Cloudreve 存储 Provider 天然支持跨进程续传；只有通过能力门禁的 Provider 才进入 1.0 可写支持矩阵。
9. 1.0 不支持把 File Provider Domain 放到外置卷，也不接管“桌面/文稿”等系统已知文件夹。
10. 本产品不是 DLP 或 DRM 工具；权限撤销后会停止新的远端读取和写入，但不承诺安全擦除用户此前已下载、复制或导出的内容。

## 3. 参考项目功能与布局盘点

### 3.1 原产品信息架构

Windows 原项目是**托盘优先、无常驻主窗口**的应用：

```text
系统托盘
├── 左键：同步状态弹窗
├── 右键菜单
│   ├── 显示
│   ├── 添加新云盘
│   ├── 设置
│   └── 退出
├── 添加/重新授权窗口
└── 设置窗口

Windows Explorer
├── Cloud Files Sync Root
├── 占位文件与按需下载
├── 文件状态与自定义属性
├── 缩略图
├── 存储容量/同步状态面板
└── 右键菜单
    ├── 在线查看
    ├── 立即同步
    └── 解决冲突
```

托盘构造和菜单行为见 [`src-tauri/src/lib.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/src-tauri/src/lib.rs#L185-L238)。应用启动后销毁默认主窗口，仅保留后台服务与托盘入口。

### 3.2 原产品窗口布局

#### 3.2.1 同步状态弹窗

- 原始尺寸：`370 × 530`，不可缩放、无系统边框、跳过任务栏；
- 从托盘打开时停靠托盘图标，从其他入口打开时居中；
- 失去焦点自动关闭；
- 可选择关闭时隐藏以加速下次打开。

布局自上而下为：

1. Header：NimbusSync Logo、设置按钮；
2. Drive Chips：全部、各网盘、添加网盘；
3. Task List：`同步中` 与 `最近` 两组；
4. Footer：同步任务数量或“文件已是最新”。

任务行展示：

- 系统文件类型图标；
- 上传/下载/成功/失败角标；
- 文件名；
- 已处理字节、总字节、速度和进度条；
- 完成时间或错误信息；
- 点击父目录名称后在 Explorer 中定位文件。

弹窗布局和 1 秒状态轮询见 [`ui/src/pages/popup/index.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/popup/index.tsx)；任务行见 [`TaskItem.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/popup/TaskItem.tsx)。

#### 3.2.2 添加网盘/重新授权窗口

- 原始尺寸：`470 × 630`，固定大小、无系统边框；
- 采用居中单列向导；
- 根据站点 `manifest.json` 尝试展示实例图标；
- 状态机为：

```text
url_input
  → waiting
  → final_setup
  → setting_up
  → success
```

添加流程包括：

1. 输入 Cloudreve 站点 URL；
2. 请求 `/api/v4/site/ping`，检查最低版本 `4.12.0`；
3. 生成 PKCE，打开浏览器 OAuth；
4. 通过 Cloudreve 桌面授权约定的 `cloudreve://mount` deep link 接收 code/state/远端路径/用户 ID，并兼容旧 `cloudreve://callback/desktop` 路由；`nimbussync://` 仅用于客户端内部导航；
5. 输入挂载名称并选择空的本地文件夹；
6. 创建 Sync Root；
7. 成功后打开本地云盘。

重新授权会跳过本地目录设置，并要求重新登录的用户 ID 与原所有者一致。实现见 [`AddDrive.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/AddDrive.tsx) 和 [`siteValidation.ts`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/utils/siteValidation.ts#L4-L155)。

#### 3.2.3 设置窗口

- 原始尺寸：`700 × 500`，最小 `600 × 400`，可缩放；
- 左侧固定约 200 px 导航；
- 右侧滚动内容区；
- 一级栏目为：网盘、通用、关于。

网盘页面以卡片形式展示：

- 实例图标、网盘名称；
- 活跃/事件推送丢失/凭据过期状态；
- 实例地址和远端路径提示；
- 本地同步目录；
- 容量进度；
- 重新授权、忽略规则、删除；
- 添加网盘。

通用页面包括：

- 开机自启动；
- 快速打开状态弹窗；
- 语言；
- 凭据过期通知；
- 文件冲突通知；
- 日志目录、是否写文件、日志级别、最大日志文件数。

关于页面包括版本号、预览版标识、主页、GitHub、Issue 和 Discord 链接。布局见 [`settings/index.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/settings/index.tsx)。

### 3.3 原产品功能范围

| 功能 | 原项目状态 | 说明 | 目标优先级 |
|---|---|---|---:|
| 多 Cloudreve 网盘 | 已实现 | 每个网盘独立配置、Sync Root、任务队列 | P0 |
| Cloudreve v4 站点校验 | 已实现 | 原版最低版本硬编码为 4.12.0 | P0 |
| OAuth + PKCE | 已实现 | 浏览器登录、deep link 回调 | P0 |
| 实例图标 | 已实现 | 从 `manifest.json` 获取最大图标 | P1 |
| 重新授权 | 已实现 | 校验用户 ID，更新 token 与实例信息 | P0 |
| Finder/Explorer 云盘 | Windows 已实现 | CFAPI Sync Root；macOS 必须换 File Provider | P0 |
| 远端目录枚举 | 已实现 | 分页生成 placeholder | P0 |
| 按需下载 | 已实现 | CFAPI range fetch | P0 |
| 双向创建/修改/移动/删除 | 已实现 | 文件事件、API 操作和任务队列 | P0 |
| 远端 SSE 变化 | 已实现 | 重连、退避、新订阅后全量同步 | P0 |
| 全量校准 | 已实现基础 | 用于 SSE 新订阅和长期失败恢复 | P0 |
| ETag 冲突检测 | 已实现 | StaleVersion/ObjectExisted | P0 |
| 三种冲突动作 | 已实现 | 保留远端、覆盖远端、另存为 | P0 |
| 上传/下载任务列表 | 已实现 | 活跃与最近任务、进度和速度 | P0 |
| 任务取消/重试 UI | 未实现 | 队列有取消基础能力，UI 没有入口 | P1 |
| 持久化任务队列 | 已实现基础 | 启动时恢复未完成任务 | P0 |
| 真正跨进程断点续传 | 未完成 | 旧上传 session 会被删除后重建 | P0 重做 |
| 多存储 Provider 上传 | 已实现 | Local/Remote、OSS、COS、S3/KS3、OBS、OneDrive、七牛、又拍；Load Balance 需解析实际子策略 | P0 |
| 存储容量展示 | 已实现 | 设置卡片和 Explorer Provider Status | P1 |
| 在线查看 | 已实现 | Explorer 右键打开 Cloudreve Web 地址 | P1 |
| 立即同步 | 已实现 | Explorer 右键同步文件/目录 | P1 |
| 文件缩略图 | 已实现 | Explorer thumbnail provider | P1 |
| 共享/无权限标识 | 已实现 | Explorer custom item properties | P1 |
| Ignore 规则 | 已实现 | gitignore 风格、按网盘配置 | P1，需重定义 |
| 凭据过期通知 | 已实现 | 可关闭，点击进入设置 | P0 |
| 冲突交互通知 | 已实现 | Toast 内选择冲突动作 | P1 |
| 同步完成/失败通知 | 存在资源与部分路径 | 不等于完整端到端保证 | P1 |
| 开机启动 | 已实现 | Windows StartupTask | P0 |
| 多语言 | 已实现 | 11 种语言 | P1 |
| 日志设置 | 已实现 | 级别、文件开关、保留数量 | P1 |
| 暂停/继续网盘 | 未完成 | 有状态枚举，无完整 UI/接口 | P2 |
| 精确 `get_sync_status` | 未完成 | 当前固定返回 `idle` | P0 重做 |
| 启用/禁用网盘 | 未完成 | `enabled` 字段存在，接口未完成 | P2 |

“已实现”表示在参考提交中存在实际调用路径；“部分实现/未完成”不得作为目标产品的现成能力直接继承。

## 4. 目标用户与场景

### 4.1 目标用户

#### 用户 A：个人私有云用户

- 自建一个 Cloudreve 实例；
- 希望照片、文档和项目文件在 Finder 中可见；
- 不希望所有文件占满 Mac 磁盘；
- 需要断网后恢复和清晰的冲突提示。

#### 用户 B：多实例/多目录用户

- 同时连接家庭、公司或多个 Cloudreve 账号；
- 需要快速区分不同 Domain 的状态和容量；
- 希望从菜单栏筛选任务并快速打开对应目录。

#### 用户 C：技术支持/运维人员

- 需要查看错误、事件连接和任务状态；
- 需要导出脱敏诊断包；
- 需要确认版本、实例地址、最近一次同步和恢复结果。

### 4.2 核心用户场景

1. 首次连接一个 Cloudreve 远端目录并在 Finder 中打开。
2. 浏览完整目录，但不下载尚未打开的文件内容。
3. 双击文件触发下载，编辑保存后自动上传。
4. 在 Finder 中创建、移动、重命名和删除文件。
5. 网页端发生变化后，Finder 自动更新。
6. 网络断开、应用重启或 Extension 被终止后自动恢复。
7. 同一文件两端修改时，用户选择冲突处理方式。
8. 凭据过期后重新授权，不重新创建 Domain 或丢失状态。
9. 查看同步进度、失败原因并重试任务。
10. 移除网盘时只移除本地 Domain，不删除远端文件。
11. 在普通文件夹、同一 Domain 和不同 Domain 之间复制或拖放文件，结果与 Finder 语义一致。
12. 远端根目录被改名、移动、删除或撤销访问时，不误绑定到另一个同路径对象。

## 5. 版本范围与优先级

### 5.1 优先级定义

- **P0**：技术预览和核心可用版本必须完成；缺失时不能宣称可用同步客户端。
- **P1**：1.0 功能对齐版本必须完成；P0 + P1 构成“原项目主要用户能力一致”。
- **P2**：增强能力，不阻塞 1.0。

### 5.2 版本建议

| 版本 | 范围 |
|---|---|
| Technical Preview | 单 Domain、枚举、完整按需下载、基本上传、Keychain |
| 0.5 Beta | P0：多 Domain、双向同步、SSE/reconciliation、冲突、任务状态；写能力限于通过协议门禁的服务端/Provider |
| 1.0 | P0 + P1：Finder 增强、本机排除规则、缩略图、诊断、多语言、任务控制 |
| 1.x | P2：暂停/继续、选择性同步、网络策略和高级缓存策略 |

## 6. 目标产品信息架构与布局

### 6.1 整体结构

```text
macOS 菜单栏
├── 状态 Popover
│   ├── 网盘筛选
│   ├── 当前任务
│   ├── 最近活动/错误/冲突
│   └── 全局状态
├── 添加网盘窗口
├── 设置窗口
│   ├── 网盘
│   ├── 通用
│   ├── 通知
│   ├── 诊断
│   └── 关于
└── 冲突中心

Finder
├── 每个 Cloudreve 网盘对应一个 File Provider Domain
├── 系统管理的 dataless/materialized 文件
├── Finder 状态/装饰/缩略图
└── 自定义操作
    ├── 在 Cloudreve 中查看
    ├── 立即检查更新
    └── 解决冲突
```

### 6.2 菜单栏状态 Popover

建议宽度 `360–380 pt`，高度随内容自适应，最大约 `560 pt`。使用原生 `MenuBarExtra` 或 AppKit popover，不进入 Dock。

```text
┌──────────────────────────────────┐
│ Cloudreve                 [设置] │
│ [全部] [家庭云] [公司云]   [+]   │
├──────────────────────────────────┤
│ 需要处理                         │
│  ! 报告.docx  版本冲突   [处理]  │
│                                  │
│ 正在同步                         │
│  ↑ 视频.mp4   35%   4.1 MB/s    │
│  ███████░░░░                     │
│                                  │
│ 最近                             │
│  ✓ 照片.jpg   刚刚 · 家庭云      │
├──────────────────────────────────┤
│ ● 正在同步 2 个项目              │
└──────────────────────────────────┘
```

布局要求：

- 顶部显示产品标识、设置入口和添加网盘入口；
- 网盘较多时筛选项可横向滚动或折叠菜单；
- `需要处理` 优先于活跃任务，显示冲突、认证过期和永久失败；
- 活跃任务显示方向、进度、已处理/总量、速度和可取消操作；
- 最近活动默认展示最近 20 项，可定位 Finder；
- Footer 显示全局状态，不得在离线或 degraded 时显示“已是最新”；
- 状态更新采用本地事件流，轮询只作为降级方案。
- 用户退出菜单栏应用或关闭登录启动后，Popover 不再可用；Finder 仍按系统请求启动 Extension，重新打开应用后状态从持久化数据恢复。

### 6.3 添加网盘窗口

采用 macOS 原生向导窗口，建议初始尺寸约 `520 × 620 pt`。步骤：

1. **连接站点**：站点 URL、连接测试和服务端版本；
2. **浏览器授权**：等待、重新打开浏览器、取消；
3. **选择远端范围**：显示服务端返回的远端根；若协议不允许修改则只读展示；
4. **Domain 设置**：显示名称、实例图标、Finder 展示说明；
5. **初始化**：注册 Domain、首次枚举和健康检查；
6. **完成**：打开 Finder 或关闭。

macOS 不展示“选择任意本地文件夹”。应明确告知用户：网盘会出现在 Finder 的“位置”中，实际路径由系统管理。

### 6.4 设置窗口

建议使用 SwiftUI `Settings` + `NavigationSplitView`，初始约 `720 × 520 pt`，最小 `640 × 460 pt`。

左侧栏目：

1. 网盘；
2. 通用；
3. 通知；
4. 诊断；
5. 关于。

网盘详情卡片展示：

- 图标、名称、实例域名和远端根；
- Finder Domain 状态；
- `健康/同步中/离线/事件降级/凭据过期/错误`；
- 使用容量；
- 最近成功同步时间与最近错误；
- 在 Finder 打开、打开站点、重新授权；
- 排除规则；
- 移除网盘。

### 6.5 Finder 布局

- 每个 Cloudreve drive 映射为一个 `NSFileProviderDomain`；
- Domain 出现在 Finder “位置”区域，名称使用用户设置的网盘名称；
- 系统提供下载状态、保留下载和释放空间等标准行为；
- 应提供共享、无读取权限、冲突和错误等必要装饰；
- 缩略图失败不得阻塞文件枚举或打开；
- Domain 根不可被用户删除或移动。

### 6.6 冲突中心

冲突不能仅依赖一次性通知。菜单栏 `需要处理` 和独立冲突列表必须持久展示未解决冲突。

冲突详情至少显示：

- 文件名、Finder 位置和网盘；
- 本地版本时间、大小；
- 远端版本时间、大小；
- 冲突发生时间和原因；
- 保留远端、覆盖远端、保留两个版本；
- 在 Finder 中显示。

## 7. 详细功能需求

### 7.1 首次启动与权限

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-ONB-001 | 首次启动显示简短欢迎页 | P0 | 说明 Finder 云盘、按需下载和所需系统权限 |
| FR-ONB-002 | 首次启动可立即添加网盘 | P0 | 完成后 Domain 出现在 Finder |
| FR-ONB-003 | 无网盘时菜单栏显示空状态 | P0 | 提供“添加网盘”，不显示“已同步” |
| FR-ONB-004 | 通知权限按需请求 | P0 | 首次产生需通知事件前说明用途，拒绝后功能可继续 |
| FR-ONB-005 | 菜单栏主应用登录启动由用户控制 | P0 | 开关状态与 `SMAppService.mainApp` 实际状态一致；关闭后解释实时事件与通知会暂停，但 Finder 按需访问仍可用 |

### 7.2 站点连接与授权

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-AUTH-001 | 接受合法 HTTPS Cloudreve URL | P0 | Release 拒绝明文 HTTP；仅 Debug/测试允许 loopback HTTP，解析或 scheme 不合规时就地提示 |
| FR-AUTH-002 | 连接前请求 site ping | P0 | 区分 DNS、TLS、HTTP、API 和版本错误 |
| FR-AUTH-003 | 支持 Cloudreve v4 OAuth + PKCE | P0 | 使用系统默认浏览器，并通过 AppDelegate 接收严格校验的 callback |
| FR-AUTH-004 | 校验 OAuth state | P0 | state 不匹配时拒绝 token exchange |
| FR-AUTH-005 | token 仅保存到 Keychain | P0 | 配置、SQLite、日志均无明文 token |
| FR-AUTH-006 | 自动刷新 access token | P0 | 多进程刷新不会造成 refresh token 竞争失效 |
| FR-AUTH-007 | 支持重新授权 | P0 | 保持原 Domain/item identity，不重复创建网盘 |
| FR-AUTH-008 | 重新授权校验账号 | P0 | 与原 user ID 不一致时中止并给出可理解提示 |
| FR-AUTH-009 | 展示并保存实例图标 | P1 | 图标获取失败时使用默认图标，不阻塞授权 |
| FR-AUTH-010 | 不把内置 client secret 视为秘密 | P0 | 安全设计依赖 PKCE；任何公共客户端值可被公开 |

原版最低版本为 4.12.0。目标产品初始兼容基线可沿用 `>= 4.12.0`，但发布前必须用真实 Community/Pro 版本建立验证矩阵，再冻结最低版本。

### 7.3 网盘/Domain 管理

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-DOM-001 | 支持多个 Domain | P0 | 至少 5 个不同实例/账号可同时工作 |
| FR-DOM-002 | Domain 名称可配置 | P0 | 名称为空、重复或非法时明确提示 |
| FR-DOM-003 | Domain 绑定固定远端根实体 | P0 | 只枚举该稳定根 ID 的授权子树；根路径变化不等于换根 |
| FR-DOM-004 | 创建 Domain 后自动首次枚举 | P0 | Finder 中无需重启即可出现 |
| FR-DOM-005 | 可从设置在 Finder 中打开 Domain | P0 | Finder 定位到正确根目录 |
| FR-DOM-006 | 可打开 Cloudreve 站点 | P1 | 使用默认浏览器和 HTTPS 原地址 |
| FR-DOM-007 | 可移除 Domain | P0 | 明确提示“远端文件不会删除”；移除操作不调用远端 delete API |
| FR-DOM-008 | 清理本地缓存与元数据 | P0 | 安全移除完成后清除可删除的本地内容、journal 和 Keychain 项；系统保留的 dirty user data 交给用户，不影响其他 Domain |
| FR-DOM-009 | 支持暂停/继续 Domain | P2 | 暂停期间不主动上传/拉取，恢复后 reconciliation |
| FR-DOM-010 | 支持禁用但保留配置 | P2 | Finder Domain 可移除，重新启用后 identity 与配置复用 |
| FR-DOM-011 | 阻止同账号的重复或重叠远端范围 | P0 | 对规范化后相同、祖先或子孙 remote root 拒绝重复添加，避免两个 Domain 对同一远端树并发写入 |
| FR-DOM-012 | 移除前保护未上传数据 | P0 | 存在 dirty item、unknown outcome 或未完成写操作时禁止直接清空；须先同步、取消移除，或由系统保留用户数据到可见位置 |
| FR-DOM-013 | Domain 创建是可恢复流程 | P0 | 在 Keychain、registry、state DB 或系统 `addDomain` 任一步失败/崩溃后，重启可继续或回滚；不得留下无凭据 Domain、孤立凭据或重复 Domain |
| FR-DOM-014 | 远端根使用稳定身份绑定 | P0 | 保存根实体 ID 与当前 canonical URI；根改名/移动后若身份和授权仍有效则继续跟随，若被删除、替换、越权或造成范围重叠则冻结写入并提示处理，不按旧路径接管新对象 |
| FR-DOM-015 | 仅使用合法且不敏感的系统 Domain 标识 | P0 | identifier 不含 `/`、`:`、实例地址、账号或路径；重新授权和改名不改变 identifier |

### 7.4 Finder 枚举与按需下载

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-FP-001 | 枚举根目录和任意子目录 | P0 | 正确处理分页、空目录和深层目录；并发创建/改名/删除时无静默漏项或重项 |
| FR-FP-002 | 使用稳定 item identifier | P0 | rename/move 后 identifier 不因路径变化而改变 |
| FR-FP-003 | 显示 dataless 文件 | P0 | 不下载内容也能展示名称、类型、大小和修改时间 |
| FR-FP-004 | 打开文件时下载完整内容 | P0 | 校验长度与版本，取消操作能及时终止网络请求 |
| FR-FP-005 | 支持系统 eviction | P0 | 释放空间后 item 仍可见且能再次下载 |
| FR-FP-006 | 支持保留下载 | P1 | Finder 标准操作可令内容保持本地可用 |
| FR-FP-007 | 支持范围下载 | P2 | 大文件随机读取只拉取所需范围，失败可退回完整下载 |
| FR-FP-008 | 正确映射文件类型和时间 | P0 | Finder 信息与 Cloudreve metadata 一致 |
| FR-FP-009 | 根目录和只读 item 能力正确 | P0 | 不允许的删除、移动、写入不在 UI 中伪装可用 |
| FR-FP-010 | 远端链接/共享重定向有明确策略 | P1 | 不把 `sys:shared_redirect` 或未知 link 类型当普通目录跟随；过滤或只读入口行为有测试且不越过授权根 |
| FR-FP-011 | 维护 working set 与 materialized container 集合 | P0 | 远端变化能更新已落盘目录；总 item 数增长时不要求把全量树长期作为 working set |
| FR-FP-012 | 明确包、链接和特殊文件策略 | P1 | package 目录按目录同步并验证应用安全保存；Finder alias 当普通文件；本地符号链接和 socket/device/FIFO 等特殊文件不跟随、不上传且保留在本机；不保留跨 item hard link 关系，行为写入兼容矩阵 |
| FR-FP-013 | 明确 macOS 扩展元数据边界 | P1 | 1.0 只保证 data fork、服务端时间和由 Cloudreve 权限推导的可操作能力；不承诺 round-trip 本地创建时间、POSIX mode、Finder 标签/注释、任意 xattr、favorite、type/creator 或 resource fork，非空 resource fork 不得在静默丢弃后报告成功 |
| FR-FP-014 | 主应用退出时不误承诺远端新鲜度 | P0 | 系统实际调用 Extension 时可做有界目标校准；已 materialized 目录不会因普通遍历触发枚举，因此主应用恢复并校准前不得声称远端变化已完整到达 Finder |
| FR-FP-015 | 权限撤销后停止新的受保护操作 | P0 | 远端读取权限撤销后拒绝新的下载，写权限撤销后拒绝 mutation 并刷新 capabilities；UI 明示既有本地副本不具备远程擦除保证 |
| FR-FP-016 | item identifier 不泄露远端信息 | P0 | identifier 只使用本地不透明 ID，不包含实例、账号、路径、文件名或原始远端 ID |

### 7.5 本地操作上传

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-UP-001 | 创建文件自动上传 | P0 | Cloudreve 出现同一 item，Finder 返回最终版本；响应丢失后重试不产生重复文件 |
| FR-UP-002 | 创建目录自动同步 | P0 | 远端目录创建成功后返回稳定 ID；callback 重放不重复建目录 |
| FR-UP-003 | 修改文件自动上传 | P0 | 使用 previous version/ETag 防止静默覆盖 |
| FR-UP-004 | rename/move 传播到远端 | P0 | 不通过重新上传完整内容模拟移动 |
| FR-UP-005 | Finder 移到废纸篓与恢复 | P0 | 仅在删除语义通过能力门禁后启用；映射 Cloudreve 软删除/restore，保留原父级并支持 Finder 恢复 |
| FR-UP-006 | 支持空文件 | P0 | 0 字节文件通过经验证的 create/update 路径处理，不强行建立 Provider 分片会话；可创建、覆盖和下载 |
| FR-UP-007 | 支持发布矩阵内的上传 Provider | P0 | Local/Remote、OSS、COS、S3、KS3、OBS、OneDrive、七牛、又拍逐一建立 contract test；Load Balance 按实际选中子策略判定，未知策略 fail closed |
| FR-UP-008 | 上传任务持久化 | P0 | Extension 被终止后，等待系统重放 callback 并重新提供内容 URL；不得尝试打开已失效的临时路径 |
| FR-UP-009 | 真正分片续传 | P0 | callback 重放且源 fingerprint 一致时复用已完成分片；源变化或服务端无法确认 session 时安全废弃旧 session |
| FR-UP-010 | 上传进度可观察 | P0 | 进度、速度、处理字节至少每秒更新一次 |
| FR-UP-011 | 用户可取消当前传输尝试 | P1 | 取消快速终止当前网络/加密工作且不留下假成功；未同步的 Finder 修改仍保留为 pending，除非用户另行放弃或排除 |
| FR-UP-012 | 用户可重试失败任务 | P1 | 重试清除对应系统 backoff、保留 item identity 和可恢复 session，并由 File Provider 重新调度 |
| FR-UP-013 | File Provider callback 重放幂等 | P0 | create 使用系统稳定的临时 item identifier 关联原 operation；modify/delete 使用 item、base version 和字段集合关联，不重复创建或误删 |
| FR-UP-014 | 原子处理组合字段修改 | P0 | filename、parent、contents 同次变化时作为一个持久 operation 处理；不能出现新扩展名配旧内容的可见成功状态 |
| FR-UP-015 | 串行化同一 item 的连续编辑 | P0 | 上传期间再次保存会形成后继版本，不让旧上传结果覆盖较新的本地内容 |
| FR-UP-016 | 永久删除与递归删除受控 | P0 | 只有从废纸篓永久删除时调用永久删除语义；非递归非空目录返回 directory-not-empty，部分失败不标记整批成功 |
| FR-UP-017 | 未验证删除能力默认关闭 | P0 | Domain 创建时显式关闭 trash syncing；只有软删除、trash 枚举、restore 和永久删除均通过门禁后才开启，不依赖系统默认值 |
| FR-UP-018 | 支持 Finder 复制与跨边界拖放 | P0 | 从普通目录复制/移动入 Domain、同 Domain 复制、跨 Domain 复制均按 create callback 安全上传；复制出 Domain 只读取内容；跨边界移动只有在目标写入确认后才允许源侧删除 |
| FR-UP-019 | 防止目录移动形成环 | P0 | 除依赖系统本地保证外，提交远端 move 前按最新父链检查远端并发变化；无法证明无环时返回冲突并校准 |
| FR-UP-020 | 正确处理 File Provider 字段集合 | P0 | `contents` 与 `filename` 同步提交；不支持的 tag/favorite/xattr/type-and-creator/file-system-flags 等字段按系统协议返回 pending/unsupported，不能假成功或覆盖为默认值 |

### 7.6 远端事件与一致性恢复

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-EVT-001 | 订阅 Cloudreve 文件 SSE | P0 | 使用稳定 client ID，处理 subscribed/resumed/keep-alive/reconnect-required |
| FR-EVT-002 | SSE 事件写入本地 change journal | P0 | 事务完成后才通知 File Provider 枚举变化 |
| FR-EVT-003 | journal sequence 作为 sync anchor | P0 | 同一 anchor 重放得到一致结果 |
| FR-EVT-004 | 远端变化通知 File Provider | P0 | Replicated Extension 只 signal `.workingSet`；journal 中携带真实 parent，正常网络下 p95 5 秒内在 Finder 可见 |
| FR-EVT-005 | 新订阅触发 reconciliation | P0 | 不假设订阅前所有事件仍可恢复 |
| FR-EVT-006 | 事件缺口或恢复状态不明时触发 reconciliation | P0 | 服务端无单调事件 ID 时，不声称能精确检测任意缺口；异常断流、未知事件或无法确认 resumed 时一律校准，且不报告“已同步” |
| FR-EVT-007 | anchor 过期处理 | P0 | 返回 sync anchor expired，系统可重新枚举 |
| FR-EVT-008 | 周期安全校准 | P1 | 即使 SSE 一直连接，也能发现摘要不一致 |
| FR-EVT-009 | 离线恢复 | P0 | 网络恢复后自动重连并收敛，无需用户重启应用 |
| FR-EVT-010 | SSE 降级可见 | P0 | 菜单栏和网盘设置显示“实时事件不可用，正在定期检查” |
| FR-EVT-011 | 主应用未运行时正确降级 | P0 | Extension 仅在系统实际发起枚举/读写 callback 时做有界目标校准，不承诺主动发现已 materialized 目录的远端变化；重新打开主应用后先 reconciliation 再恢复 SSE/healthy |
| FR-EVT-012 | 变更通知可跨崩溃补发 | P0 | journal 提交后、`signalEnumerator` 前进程终止时，重启会从持久 signal outbox 重发；不依赖后续恰好再来一个 SSE 事件 |
| FR-EVT-013 | 本地写回声去重 | P0 | create/modify/delete callback 的成功结果不作为新的远端 change 回送给系统；对应 SSE 回声与已提交 operation 合并，除非服务端最终状态确有差异 |

### 7.7 任务与状态

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-TSK-001 | 展示活跃上传和下载任务 | P0 | 可按全部/Domain 筛选 |
| FR-TSK-002 | 展示方向、文件、进度、速度 | P0 | 未知总大小时使用不确定进度，不显示错误百分比 |
| FR-TSK-003 | 展示最近任务 | P0 | 默认最近 20 项，包含成功、失败、取消 |
| FR-TSK-004 | 在 Finder 中显示任务文件 | P0 | 已删除 item 给出“文件已不存在”而非无响应 |
| FR-TSK-005 | 失败任务显示可理解原因 | P0 | 用户文案与诊断错误码分离 |
| FR-TSK-006 | 持久展示需处理事项 | P0 | 认证过期、冲突、永久失败不会因关闭 popover 消失 |
| FR-TSK-007 | 状态不误报 | P0 | 离线、事件降级、reconciliation 中不得显示“已是最新” |
| FR-TSK-008 | 支持取消和重试 | P1 | 取消仅停止当前 attempt，不能伪装成放弃本地修改；操作结果和 pending 状态立即反映到列表 |
| FR-TSK-009 | 任务历史清理 | P1 | 支持清除已完成记录，不影响 item metadata |
| FR-TSK-010 | 系统 pending 状态与客户端任务一致 | P0 | UI 合并持久 task 与 File Provider pending/global progress；pending set 达到上限或尚未包含初始传输时不得据此宣称无任务 |

### 7.8 冲突处理

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-CNF-001 | 使用 ETag/version 检测冲突 | P0 | stale version 不会被当作普通重试覆盖远端 |
| FR-CNF-002 | 冲突持久化 | P0 | 重启后仍在“需要处理”列表中；本地冲突内容由系统 pending item 或用户已导出到可见位置的副本保护，不依赖旧 callback URL |
| FR-CNF-003 | 保留远端版本 | P0 | 丢弃本地修改前二次确认，并下载当前远端版本 |
| FR-CNF-004 | 覆盖远端版本 | P0 | 再次校验版本；若远端又变化，继续保持冲突 |
| FR-CNF-005 | 保留两个版本 | P0 | 本地版本保存为唯一冲突副本并上传，不覆盖任一现有版本 |
| FR-CNF-006 | 冲突通知 | P1 | 点击通知打开对应冲突，不在通知内执行不可逆覆盖 |
| FR-CNF-007 | Finder 冲突装饰 | P1 | 未解决 item 有明确但不过度干扰的状态标识 |
| FR-CNF-008 | 批量处理 | P2 | 同类型冲突可选择逐个或批量策略，危险动作需确认 |

### 7.9 Finder 增强操作

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-FND-001 | 在 Cloudreve 中查看 | P1 | 根据 item ID/URI 打开正确 Web 页面 |
| FR-FND-002 | 立即检查更新 | P1 | 触发指定 item/目录 reconciliation，不盲目重复上传 |
| FR-FND-003 | 解决冲突 | P1 | 仅对 Pending conflict item 可用 |
| FR-FND-004 | 提供缩略图 | P1 | 图片等支持类型有缩略图；失败回退文件图标 |
| FR-FND-005 | 共享状态装饰 | P1 | shared metadata 变化后 Finder 可刷新 |
| FR-FND-006 | 权限状态 | P1 | 无读/写权限时能力和装饰一致，不允许虚假操作 |
| FR-FND-007 | 容量入口 | P1 | 设置页展示容量并可打开服务端详情页 |

### 7.10 排除规则

File Provider Domain 是远端文件树的系统视图，不能完全复制普通目录 watcher 的 ignore 语义。目标产品将原版“忽略规则”定义为**本机排除规则**。远端排除是客户端视图过滤，本地排除使用系统 `excludedFromSync` 流程；二者都不能修改远端对象。

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-IGN-001 | 每个 Domain 可配置 gitignore 风格规则 | P1 | 一行一条，保存前验证语法 |
| FR-IGN-002 | 匹配的远端 item 不进入本机视图 | P1 | 从未出现过的 item 直接过滤；已出现的 item 通过本地 view-removal change 从 Finder 移除，但保留远端 identity 记录且不写远端 tombstone |
| FR-IGN-003 | 本地创建匹配 item 时排除同步 | P1 | 返回系统 `excludedFromSync`，由 Finder 保留本地内容；客户端记录可审计的 local-only 状态，不承诺排除后仍可提供自定义装饰 |
| FR-IGN-004 | 修改规则触发受控视图变更 | P1 | 新增排除项前列出受影响的 materialized/dirty item；dirty item 未同步或未另存前禁止排除，变更后发布 working-set change |
| FR-IGN-005 | 根目录不可被规则排除 | P1 | 规则验证阶段拒绝 |
| FR-IGN-006 | 排除不删除远端 | P1 | 添加规则不得调用 Cloudreve delete API |
| FR-IGN-007 | 排除清理回调与用户删除隔离 | P1 | 在返回 `excludedFromSync` 前持久化 exclusion intent；系统随后调用 `deleteItem` 时只完成本地排除握手，绝不进入远端 delete/trash 调用链 |
| FR-IGN-008 | 不开放 Finder 原生“排除同步”能力 | P1 | item 不声明 `.allowsExcludingFromSync`；所有排除经设置页规则进入，避免系统原生动作被误解为“仅隐藏远端对象” |

### 7.11 设置

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-SET-001 | 开机自启动 | P0 | 开关读取实际 Login Item 状态，失败可恢复 |
| FR-SET-002 | 跟随系统浅色/深色 | P0 | 无需重启切换 |
| FR-SET-003 | 通知总开关与分类开关 | P1 | 凭据、冲突、永久失败可分别控制 |
| FR-SET-004 | 语言选择 | P1 | 跟随系统或手动选择，切换无需重启主 UI |
| FR-SET-005 | 日志文件开关 | P1 | 明确哪些设置需重启主应用或等待 Extension 下次启动生效 |
| FR-SET-006 | 日志级别 | P1 | Trace/Debug/Info/Warn/Error，默认 Info |
| FR-SET-007 | 日志保留 | P1 | 可选 3/5/7/10 文件或等效大小策略 |
| FR-SET-008 | 打开日志目录 | P1 | Finder 打开 App Group 中可访问的诊断目录 |
| FR-SET-009 | 快速 popover | 不迁移 | 原生 popover无需暴露“保留 WebView 内存”设置 |
| FR-SET-010 | 缓存与磁盘用量 | P2 | 按 Domain 展示本地缓存，提供系统允许的释放入口 |

### 7.12 通知

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-NTF-001 | 凭据过期通知 | P0 | 每个 Domain 去重，点击进入重新授权 |
| FR-NTF-002 | 冲突通知 | P1 | 每个冲突去重，点击进入冲突详情 |
| FR-NTF-003 | 永久失败通知 | P1 | 重试耗尽或用户必须处理时才发送 |
| FR-NTF-004 | 同步完成通知默认关闭 | P1 | 避免大量文件时产生通知噪声 |
| FR-NTF-005 | 通知正文不泄露敏感路径 | P0 | 锁屏默认只展示必要文件名/Domain 名称 |
| FR-NTF-006 | 通知操作可恢复 | P0 | 应用未运行时点击仍能打开正确页面或排队处理 |

### 7.13 日志与诊断

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-DIA-001 | 结构化本地日志 | P0 | 包含 Domain/task/item 关联 ID，不包含 token |
| FR-DIA-002 | 敏感信息脱敏 | P0 | Authorization、refresh token、上传签名 URL 查询参数均脱敏 |
| FR-DIA-003 | 日志轮转 | P1 | 达到数量/大小限制后删除最旧日志 |
| FR-DIA-004 | 导出诊断包 | P1 | 包含版本、OS、状态摘要、脱敏日志，不包含文件内容和 token |
| FR-DIA-005 | 用户预览诊断范围 | P1 | 导出前说明会包含路径/文件名，允许进一步隐藏 |
| FR-DIA-006 | 健康检查 | P1 | 展示 API、认证、SSE、File Provider、数据库状态 |

### 7.14 国际化与可访问性

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-I18N-001 | 1.0 支持原版 11 种语言 | P1 | en-US、zh-CN、zh-TW、ja、de、fr、es、ko、ru、pl、it |
| FR-I18N-002 | 跟随系统语言 | P1 | 不支持的语言回退英文 |
| FR-I18N-003 | 日期、数字和字节本地化 | P1 | 不使用硬编码英文单位和日期顺序 |
| FR-A11Y-001 | VoiceOver 标签 | P0 | 所有图标按钮、进度和状态可读 |
| FR-A11Y-002 | 键盘操作 | P0 | 设置、向导和冲突操作无需鼠标完成 |
| FR-A11Y-003 | Reduce Motion | P1 | 避免不可关闭的庆祝动画和持续旋转干扰 |
| FR-A11Y-004 | 高对比度和非颜色状态 | P0 | 状态不能只靠红/绿圆点区分 |

### 7.15 应用生命周期

| ID | 需求 | 优先级 | 验收标准 |
|---|---|---:|---|
| FR-LIFE-001 | 关闭设置不退出同步 | P0 | 菜单栏主应用和 File Provider 继续运行 |
| FR-LIFE-002 | 菜单“退出”语义明确 | P0 | 主应用退出后 SSE、周期校准和通知暂停；File Provider 仍能按系统请求启动 Extension |
| FR-LIFE-003 | 睡眠唤醒恢复 | P0 | 自动恢复网络、SSE 和未完成任务 |
| FR-LIFE-004 | Extension 强杀恢复 | P0 | 无静默丢任务、无重复远端写入 |
| FR-LIFE-005 | 升级迁移 | P0 | 数据库迁移原子化，失败可回滚到可启动状态 |
| FR-LIFE-006 | 单实例主应用 | P1 | deep link 激活已有实例而非创建冲突窗口 |
| FR-LIFE-007 | 自动更新 | P2 | 签名更新、发布通道和回滚策略另行设计 |
| FR-LIFE-008 | 系统重放与 reimport | P0 | 正确处理 `mayAlreadyExist`、deletion-conflicted 与 import 完成回调，不复制已有远端 item |
| FR-LIFE-009 | 升级期间跨版本进程隔离 | P0 | 旧 Extension 遇到不兼容 schema 只读失败，新版本完成迁移前不并发写旧结构 |
| FR-LIFE-010 | 卸载前安全清理 | P1 | 提供“准备卸载”入口；先处理 dirty 数据，再移除所有 Domain、登录启动和本地凭据 |
| FR-LIFE-011 | 数据库损坏安全修复 | P0 | 先隔离原库并保护 pending/dirty 数据；仅 metadata 可重建，不能用空库覆盖未确认 operation |
| FR-LIFE-012 | callback 外不依赖游离后台任务 | P0 | 关键工作必须在系统 callback/`Progress` 生命周期内完成或先持久化；callback 返回后启动的 detached task 不得成为正确性前提 |

## 8. 状态与业务规则

### 8.1 Domain 状态

```text
initializing
  ├── healthy
  ├── offline
  ├── auth_expired
  ├── root_unavailable
  ├── scope_conflict
  └── error

healthy
  ├── syncing
  ├── reconciling
  ├── event_degraded
  ├── app_not_running
  ├── offline
  ├── root_unavailable
  ├── scope_conflict
  └── auth_expired
```

面向用户的汇总状态：

| 状态 | 用户文案 | 可执行动作 |
|---|---|---|
| Healthy | 已是最新 | 打开 Finder |
| Syncing | 正在同步 N 个项目 | 查看任务、取消可取消任务 |
| Reconciling | 正在检查更新 | 查看状态，不承诺已同步 |
| Offline | 离线，等待网络 | 重试 |
| Event degraded | 实时更新不可用，正在定期检查 | 立即检查、查看诊断 |
| App not running | Finder 可用，实时更新已暂停 | 打开 NimbusSync |
| Auth expired | 需要重新授权 | 重新授权 |
| Root unavailable | 远端根不可用 | 检查权限、重新选择或移除网盘 |
| Scope conflict | 网盘范围发生重叠 | 选择保留一个范围或调整远端目录 |
| Conflict | 有 N 个冲突待处理 | 打开冲突中心 |
| Error | 同步遇到问题 | 查看错误、重试、诊断 |
| Paused | 已暂停 | 继续同步，P2 |

状态优先级：`auth_expired > root_unavailable/scope_conflict > conflict/permanent_error > offline > reconciling > syncing > event_degraded/app_not_running > healthy`。不得用最后一次成功状态覆盖当前高优先级异常。

### 8.2 Item 状态

- `dataless`：只有 metadata，未下载内容；
- `downloading`：正在 materialize；
- `materialized`：内容在本机，未发生本地变化；
- `upload_queued`：本地版本等待上传；
- `uploading`：正在上传；
- `in_sync`：本地/远端版本一致；
- `conflict`：需要用户选择；
- `error`：当前操作失败；
- `remote_excluded`：远端对象仍存在，只从本机 Finder 视图过滤；
- `local_only_excluded`：本地对象由系统保留但不上传；数据库只保留诊断/恢复记录，等待规则变化或用户另行处理。

`materialized`/`dataless` 是系统所有的缓存状态，本地数据库只能通过 File Provider 的 materialized set 通知维护可恢复的镜像，不能把一次扫描结果当作永久真相。

### 8.3 任务状态

```text
queued → running → succeeded
             ├── retry_wait → running
             ├── failed
             └── cancelled
```

- 可恢复网络错误进入有限退避重试；
- 认证错误不消耗普通重试次数，转为 `auth_expired`；
- 版本冲突不进入自动重试，转为 `conflict`；
- 数据校验失败必须重新下载/上传相关内容，不得标记成功；
- `succeeded` 必须表示服务端已提交且本地 metadata 已落盘。

### 8.4 删除规则

1. Finder 将普通 item 移到废纸篓：若服务端门禁通过，则映射 Cloudreve 软删除并把 item 保留在 File Provider trash/working set；恢复映射 Cloudreve restore。
2. Finder 从废纸篓永久删除：才调用经验证的永久删除语义；远端删除后从 Finder 和本地 materialized 内容中移除。
3. 移除 Domain：不调用远端删除；先等待或处理 dirty/unknown-outcome operation，再使用系统的保留 dirty user data 模式，最后清理可安全删除的缓存、journal、配置和凭据。
4. 清除历史/日志：不得删除 item 或远端数据。
5. 任何批量破坏性操作都必须先解析精确 Domain 和 item 范围。
6. `excludedFromSync` 引起的系统 `deleteItem`：仅消费已持久化 exclusion intent 并完成本地清理，不调用远端 trash/delete；没有匹配 intent 时才按普通永久删除流程判断。

### 8.5 命名与冲突副本

- item identity 不使用路径；
- macOS 大小写与 Unicode 规范化冲突必须被检测；
- 冲突副本命名建议：`文件名（设备名 冲突副本 YYYY-MM-DD）.ext`；
- 若名称已存在，追加递增序号；
- 设备名应经过隐私处理，允许用户在设置中使用通用名称。

## 9. 异常与恢复需求

| 场景 | 期望行为 |
|---|---|
| 无网络启动 | Finder 保留已知 metadata/materialized 内容；新下载明确提示离线 |
| SSE 中断 | 显示 event degraded，退避重连并定期 reconciliation |
| access token 过期 | 自动刷新；成功后重放原请求 |
| refresh token 过期 | 停止需要认证的写操作，保留队列并提示重新授权 |
| 服务端返回 stale version | 创建持久冲突，不自动覆盖 |
| 磁盘空间不足 | 停止下载，返回系统可识别错误，保留可重试状态 |
| 上传分片失败 | 只重试失败分片，达到上限后进入 retry_wait/failed |
| Extension 被系统终止 | 下次启动从 operation/upload session 恢复 |
| 上传 callback 被重放 | 使用系统临时 item ID 或稳定 item/base version 找回原 operation；拿到新的内容 URL 并校验 fingerprint 后续传 |
| SQLite 损坏 | 停止写操作并隔离原库；从可信备份、File Provider pending set/callback 重放恢复未确认动作后，才重建 metadata 并全量校准 |
| 远端 item ID 不稳定 | 使用 identity mapping；无法确认身份时不执行破坏性操作 |
| 同名/大小写碰撞 | 显示明确错误或受控改名，不静默隐藏其中一个文件 |
| 私有 CA 不受信 | 提示证书信任错误，引导安装 CA；不允许直接忽略验证 |
| 主应用未运行 | 已知 item 的按需请求和本地 mutation 继续；已 materialized 目录可能保持旧远端视图，实时事件、周期校准与通知暂停；启动应用后先 reconciliation 再恢复 healthy |
| 移除时存在 dirty item | 阻止无提示清空，提供继续同步、保留到系统返回位置或取消移除 |
| refresh token 轮换时进程终止 | 保留全部文件操作；若服务端不能重放/查询刷新结果且旧 token 已失效，则进入重新授权，不循环使用旧 token 刷新 |
| 远端根改名、移动、删除或被同路径对象替换 | 以根实体 ID 验证身份；可安全跟随时更新 URI，否则停止 mutation 并提示重新选择或移除 Domain |

## 10. 非功能需求

### 10.1 性能目标

以下为 1.0 初始工程指标，需在 File Provider Spike 后冻结：

| 指标 | 目标 |
|---|---:|
| 菜单栏 popover 打开时间 | 本地缓存命中 p95 ≤ 300 ms |
| 状态/进度刷新间隔 | ≤ 1 秒 |
| 正常 SSE 远端变化可见延迟 | p95 ≤ 5 秒 |
| 普通目录首屏枚举 | 正常网络 p95 ≤ 2 秒 |
| 单 Domain item 规模 | 至少 100,000 |
| 单目录 item 规模 | 至少 10,000，必须分页且不一次性载入内存 |
| 主应用空闲内存 | 建议 ≤ 150 MB |
| Extension 常态内存 | 建议 ≤ 150 MB，峰值不得随总 item 数线性无限增长 |
| UI 主线程 | 网络、SQLite、哈希和图片解码不得阻塞主线程 |
| 枚举 page token | 不超过 File Provider 的 500-byte 限制，跨页顺序稳定 |
| 临时传输空间 | 有按 Domain 上限与启动清理；不得长期复制整份 materialized 文件作为第二缓存 |

### 10.2 可靠性目标

- 不允许已确认写入被静默丢失；
- 相同 operation 重放不产生重复文件或重复删除；
- 主应用或 Extension 任一进程异常终止后可自动恢复；
- journal 和数据库写入使用事务；
- 任务成功回调前持久化最终远端版本；
- 10,000 item 测试集在事件丢失后可通过 reconciliation 收敛；
- File Provider callback/reimport 重放不会重复创建、重复删除或覆盖较新内容；
- 排除流程产生的 `deleteItem` 不会进入远端删除调用链；
- Domain provisioning 中断后不会留下可见但不可恢复的半配置状态；
- 若启用匿名稳定性统计，目标 crash-free session ≥ 99.5%。

### 10.3 资源与能耗

- 菜单栏主应用不得使用无等待轮询维持 SSE 或状态刷新；空闲时由事件和有上限定时器驱动；
- 周期 reconciliation 对多 Domain 加随机抖动，用户交互和 File Provider 请求优先；
- 低电量、睡眠唤醒和受限网络下可以延后非紧急全量校准，但不得延后用户正在等待的下载或写入确认；
- Rust/Swift 网络任务必须响应系统取消，临时文件与上传 session 按明确保留策略回收。

### 10.4 安全与隐私

- token、OAuth code、上传签名 URL、Authorization Header 不得写日志；
- Keychain item 按 Domain 隔离，并使用最小 Access Group；
- App Group 数据库不存 secret；
- OAuth 使用 state + PKCE；
- URL scheme 回调验证来源数据，不信任 route 参数中的 user ID/远端路径；
- 网络只访问用户配置实例和上传流程返回的受信端点；
- Release 不通过明文 HTTP 发送 OAuth code、token 或文件内容；私有部署使用系统信任的证书或安装私有 CA；
- 支持系统代理和系统信任链；
- 默认不收集文件名、路径、服务器地址和使用统计；
- 诊断导出必须显式由用户触发。
- 远端权限撤销后立即停止新的下载和写入，但产品文案不得承诺擦除用户已经下载、复制到 Domain 外或由备份保留的内容。

### 10.5 兼容性

- 建议最低 macOS 13，最终版本在 Spike 后确认；
- 建议发布 universal2，支持 Apple Silicon 和 Intel；
- 支持 APFS 大小写敏感与不敏感卷；
- 支持 Cloudreve v4，发布前建立明确版本矩阵；
- Community/Pro 均按实际公开 API 兼容性测试，不从版本后缀推断授权权利。

## 11. 数据与观测指标

产品默认不上传遥测；以下指标至少应在本地诊断页可见：

- 每个 Domain 的 item 数、materialized 数和冲突数；
- 队列中 queued/running/retry/failed 任务数；
- 最近一次 SSE 事件时间和连接状态；
- 最近一次 reconciliation 时间、耗时和差异数量；
- 最近成功上传/下载时间；
- 当前上传/下载速率；
- 数据库大小、journal 最早/最新序号；
- 客户端、Extension、Rust core 和 Cloudreve 服务端版本。

若未来增加可选匿名遥测，必须单独征得同意，并且不上传实例域名、账号、路径、文件名、文件 ID、token 或内容摘要。

## 12. 1.0 端到端验收场景

### AC-001：首次添加网盘

1. 输入受支持 Cloudreve 地址；
2. 完成 OAuth；
3. 设置 Domain 名称；
4. Finder 出现新 Domain；
5. 浏览根目录和至少两层子目录；
6. Keychain 中存在凭据，普通配置中不存在 token。

### AC-002：按需下载与释放空间

1. Finder 显示未下载的大文件；
2. 打开后触发下载并展示进度；
3. 下载完成后内容校验正确；
4. 执行系统释放空间；
5. 文件恢复 dataless，但 metadata 和 Finder item 保留；
6. 再次打开可重新下载。

### AC-003：完整双向修改

1. Finder 创建、修改、移动、重命名文件，并分别执行移到废纸篓、恢复和永久删除；
2. Cloudreve Web 端逐项出现对应变化；
3. Web 端重复上述操作，包括软删除和恢复；
4. 验证普通目录到 Domain、同 Domain、跨 Domain 的复制，以及复制出 Domain；跨边界移动只在目标成功后删除源；
5. 在目录移动期间注入远端并发 move，验证不会形成父子环；
6. Finder 在目标延迟内更新；
7. 无重复 item、无错误路径、无静默覆盖。

### AC-004：事件丢失恢复

1. 断开 SSE；
2. 在 Web 端执行创建、移动、修改和删除；
3. 恢复连接并模拟无法续传；
4. 客户端进入 reconciling；
5. 全量校准后 Finder 与远端一致；
6. 在 journal commit 后、`signalEnumerator` 前终止主应用，重启后无需新 SSE 事件也能补发通知；
7. 本地写入对应的 SSE 回声不触发重复下载或同步循环；
8. 校准期间不显示“已是最新”。

### AC-005：上传断点续传

1. 上传一个多分片大文件；
2. 完成部分分片后强杀 Extension；
3. 验证系统重放 create/modify callback，并为同一待同步版本重新提供有效内容 URL；
4. 客户端通过稳定 callback identity 找回原 operation，并验证新内容 fingerprint；
5. 继续同一远端 session，或仅在服务端确认旧 session 无效后安全重建；
6. fingerprint 一致时已完成分片不全部重传；不一致时旧 session 不得混入新内容；
7. 最终文件内容与最新待同步本地版本一致。

### AC-006：三类冲突处理

分别制造并验证：

- 保留远端；
- 覆盖远端；
- 保留两个版本。

每种操作都必须在远端再次变化时防止覆盖错误版本，并在重启后保留未解决冲突。

### AC-007：凭据过期与重新授权

1. 使 refresh token 失效；
2. 客户端显示 auth expired 并保留任务；
3. 使用原账号重新授权；
4. 原 Domain identity 不变化；
5. 队列自动恢复；
6. 使用不同账号时明确拒绝；
7. 在 refresh 响应返回前后分别终止进程，验证轮换 token 可恢复，或在无法证明结果时稳定进入重新授权且不丢写队列。

### AC-008：安全移除网盘

1. 从设置选择移除；
2. 确认文案说明远端不受影响；
3. 先制造一个未上传本地修改和一个结果未知 operation，验证客户端阻止直接清空；
4. 选择继续同步，或使用系统保留 dirty user data 的移除模式并确认返回位置可访问；
5. Domain 从 Finder 消失；
6. 可安全清理的本地缓存、metadata 和 Keychain secret 被清理；
7. Cloudreve 远端文件完整保留；
8. 其他 Domain 不受影响。

### AC-009：文件系统边界

覆盖：

- 0 字节文件；
- 超大文件；
- 10,000 item 单目录；
- macOS package 目录、Finder alias、hard link、sparse file、resource fork 与 xattr；
- Unicode 组合字符；
- 仅大小写不同的名称；
- 长路径和非法名称；
- APFS 大小写敏感/不敏感环境。

### AC-010：生命周期恢复

在下载、上传、rename 和 reconciliation 中分别：

- 强杀 Extension；
- 强杀菜单栏主应用；
- 退出主应用；
- 睡眠并唤醒；
- 重启 macOS。

另在存在 pending upload/unknown outcome 时注入 SQLite/WAL 损坏，验证客户端隔离原库、保留 Keychain 恢复材料并通过系统 callback/pending set 重建事实，不自动覆盖为空状态。

最终状态必须收敛，且无重复远端操作或静默数据丢失。

### AC-011：后台与 working set 降级

1. 在已 materialized 目录中浏览并打开若干文件；
2. 退出菜单栏主应用，在 Web 端修改已 materialized 目录和从未访问目录；
3. 进入尚未 materialized 的目录或打开已知 dataless item 时，由系统 callback 启动 Extension 并做有界目标校准，不误报全局 healthy；
4. 验证仅重复浏览已 materialized 目录不会被客户端误判为已触发远端校准，该目录允许保持明确的 degraded/stale 状态；
5. 重新打开主应用，先完成事件重订阅和 reconciliation，再恢复实时状态；
6. 已 materialized 目录、working set 与远端最终一致，未要求把 100,000 item 全部常驻内存。

### AC-012：重复范围、升级与卸载

1. 同账号已添加 `/团队` 后，拒绝再次添加 `/团队`、`/团队/项目` 或其祖先范围；
2. 在旧 Extension 尚可能存活时升级应用，验证 schema fencing 阻止跨版本错误写入；
3. 使用“准备卸载”处理 dirty item 并移除全部 Domain；
4. 删除应用并重启后，无失联 Domain、登录项或孤立敏感凭据。

### AC-013：Domain 创建与排除安全

1. 分别在写入 Keychain、registry、state DB 和调用系统 `addDomain` 后注入崩溃，重启后验证流程只会继续或回滚一次；
2. 对已在 Finder 展示的远端 item 添加排除规则，Finder 移除本机表示但 Cloudreve 对象和内容保持不变；
3. 在 Finder 创建命中规则的本地文件，验证系统保留本地内容并随后调用排除清理；
4. 验证该清理 callback 命中 exclusion intent，不调用远端 trash/delete；
5. 移除规则后触发系统重新评估，本地排除项可重新提交，远端排除项可重新进入本机视图；
6. 在 exclusion intent 与用户永久删除竞争时，同一 item 串行处理且无误删。

### AC-014：远端根身份与权限撤销

1. 添加一个子目录 Domain，记录根实体 ID 和当前 URI；
2. 在 Web 端改名或移动该根，身份与授权仍有效时 Domain 跟随同一对象且 item identity 不变；
3. 把根移动到另一个已配置 Domain 范围或授权范围外，客户端冻结写入并报告范围冲突；
4. 删除根后在原路径创建同名目录，客户端不得自动把 Domain 绑定到新对象；
5. 撤销文件读取权限后新的 dataless 下载被拒绝，撤销写权限后 Finder capabilities 和 mutation 结果一致；
6. UI 明示此前下载或导出的副本不受远端安全擦除保证。

## 13. 发布阻断条件

出现以下任一情况不得发布 1.0：

- 已知路径会静默覆盖本地或远端新版本；
- Domain 移除可能删除远端文件；
- token、签名 URL 或 OAuth code 进入普通日志；
- Release 构建允许向明文 HTTP 端点发送凭据或文件内容；
- SSE 丢失后无法自动 reconciliation；
- Extension 重启导致任务假成功或重复创建文件；
- create/modify callback 重放无法关联原 operation，或恢复上传依赖已失效的临时路径；
- 服务端创建操作缺少幂等键或可证明的后置条件，响应丢失时可能生成重复 item；
- Cloudreve item identity 尚未验证；
- 目录分页在并发变更时可能无提示漏项/重项；
- 同账号可配置重叠远端根并产生双写；
- 大小写/Unicode 碰撞可能删除错误 item；
- Domain 移除或排除规则可能丢弃未上传内容；
- `excludedFromSync` 后续系统删除回调可能进入远端删除调用链；
- Finder 普通删除被映射为不可恢复的远端永久删除，或 trash/restore 状态无法一致收敛；
- 数据库自动重建会丢弃 pending operation、upload session 或冲突证据；
- 未完成签名、公证和升级迁移测试；
- 核心上传 Provider 无真实服务端 contract test；
- Domain 创建中断会留下孤立凭据、孤立数据库或不可用的系统 Domain。
- Domain identifier 包含 `/`、`:` 或敏感远端信息，导致系统拒绝注册或日志泄露；
- 远端根只按路径绑定，改名、移动、删除或同路径替换后可能同步到错误对象；
- journal 已提交但通知未发出时无法在重启后补发，或本地写回声会触发重复下载/循环；
- Finder 复制、跨 Domain 拖放或并发目录移动可能造成源数据提前删除、重复对象或目录环；
- refresh token 轮换的结果未知窗口会造成无限刷新循环、覆盖新凭据或丢失待处理写入。

## 14. 待确认产品决策

| 决策 | 建议默认 | 冻结时间 |
|---|---|---|
| 最低 macOS 版本 | macOS 13 | File Provider Spike 后 |
| Intel 支持 | universal2 支持 | 首个 Beta 前 |
| 最低 Cloudreve 版本 | 暂沿用 4.12.0 | 协议验证后 |
| 应用名称与图标 | NimbusSync；使用独立品牌资产，避免复用服务端品牌资产 | 首个公开构建前 |
| App Store 或站外分发 | Developer ID 站外分发优先 | 发布工程开始前 |
| 自动更新方案 | 1.0 后或 Beta 冻结前决定 | Beta 前 |
| partial fetch | P2；完整下载先行 | 大文件 Spike 后 |
| Ignore 的最终产品文案 | “本机排除规则” | UX 设计阶段 |
| 退出菜单语义 | 退出菜单栏主应用并暂停实时事件/通知，不禁用 File Provider | Beta 前实机验证 |
| Domain 移除策略 | 默认保护 dirty user data；无 dirty 数据才完整清理 | File Provider Spike 后 |
| Finder 删除语义 | 按服务端门禁显示“移到 Cloudreve 回收站”或“删除”，不猜测可恢复性 | 协议验证后 |
| 远端根移动语义 | 稳定 ID 和授权仍有效时跟随；身份不明、范围重叠或越权时冻结写入 | 协议验证后 |
| 匿名遥测 | 默认无遥测 | 如引入需单独 PRD |

## 15. 参考源码证据

- 功能声明：[`README.md`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/README.md#features)
- 页面路由：[`ui/src/App.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/App.tsx#L33-L50)
- 添加网盘：[`ui/src/pages/AddDrive.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/AddDrive.tsx)
- 托盘状态：[`ui/src/pages/popup/index.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/popup/index.tsx)
- 设置布局：[`ui/src/pages/settings/index.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/settings/index.tsx)
- 网盘设置：[`DrivesSection.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/settings/DrivesSection.tsx)
- 通用设置：[`GeneralSection.tsx`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/ui/src/pages/settings/GeneralSection.tsx)
- 窗口尺寸和行为：[`src-tauri/src/commands.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/src-tauri/src/commands.rs#L316-L518)
- CFAPI 回调：[`drive/callback.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/drive/callback.rs#L43-L138)
- 远端 SSE：[`drive/remote_events.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/drive/remote_events.rs#L58-L143)
- 同步计划：[`drive/sync.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/drive/sync.rs#L182-L227)
- 任务模型：[`tasks/types.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/tasks/types.rs)
- 冲突识别：[`tasks/upload.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/tasks/upload.rs#L166-L204)
- 冲突通知：[`utils/toast.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/utils/toast.rs#L103-L154)
- Explorer 右键命令：[`shellext/context_menu`](https://github.com/cloudreve/desktop/tree/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/shellext/context_menu)
- Provider 状态和容量：[`shellext/status_ui.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/shellext/status_ui.rs#L147-L280)
- 共享/权限状态：[`shellext/custom_state.rs`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/crates/cloudreve-sync/src/shellext/custom_state.rs#L37-L83)
- Windows 打包声明：[`package/AppxManifest.xml`](https://github.com/cloudreve/desktop/blob/71447408df6db38362703fbbb61dc534ea210470/package/AppxManifest.xml#L66-L124)

## 16. Apple 产品能力依据

- [Replicated File Provider extension](https://developer.apple.com/documentation/fileprovider/replicated-file-provider-extension)
- [Synchronizing the File Provider Extension](https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension)
- [Synchronizing files using File Provider extensions](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions)
- [WWDC21: Sync files to the cloud with FileProvider on macOS](https://developer.apple.com/videos/play/wwdc2021/10182/)
- [NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension)
- [NSFileProviderManager](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager)
- [NSFileProviderDomainState](https://developer.apple.com/documentation/fileprovider/nsfileproviderdomainstate)
- [NSFileProviderError/excludedFromSync](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/excludedfromsync)

---

本文档中 P0 + P1 是目标 1.0 的功能范围，但远端写能力以服务端与 Provider 能力矩阵为前置条件。任何与 File Provider 实机行为或 Cloudreve 实测契约冲突的需求，应先同步更新本文档、技术架构和对应验收标准，再修改实现；不能通过保留普通目录 watcher、盲目路径写入或降低数据保护要求来绕开系统同步模型。1.0 的完整验收范围为 AC-001 至 AC-014。
