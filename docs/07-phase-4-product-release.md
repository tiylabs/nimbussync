# 阶段 4 实施计划：1.0 产品化、质量与发布

> 阶段编号：Phase 4
> 阶段状态：Conditional Go（产品化/自动化基础完成；1.0 发布证据未齐，当前 No-Go）
> 目标版本：1.0
> 前序阶段：[阶段 3：SSE、变更交付与最终一致性](./06-phase-3-events-consistency.md)
> 完整验收基线：[产品需求 AC-001 至 AC-014](./01-macos-product-requirements.md#12-10-端到端验收场景)

## 1. 需求背景

阶段 0 至 3 建立了协议、File Provider、持久化、读写路径和最终一致性。1.0 仍不能只以“同步核心可运行”为发布标准：用户需要可理解的菜单栏状态、设置、冲突处理、通知、Finder 操作、本机排除、诊断、多语言和安全卸载；工程还必须通过签名、公证、升级、兼容性、性能、可访问性和长稳验证。

本阶段不改变同步核心的不变量，而是把已验证的 service 和 projection 组合为完整产品，并执行发布级验证。任何 UI 都不能绕过 capability snapshot、operation saga、Keychain 或 Store 直接发起远端写入。

## 2. 阶段目标

1. 完成 PRD P0 + P1 的全部用户界面和 Finder 增强能力。
2. 完成任务中心、冲突中心、通知、设置、健康检查和脱敏诊断包。
3. 完成本机排除规则的安全预览、应用、撤销和 cleanup 保护。
4. 完成 11 种语言、VoiceOver、键盘、高对比度和 Reduce Motion。
5. 完成 universal2、Release entitlement、签名、公证、DMG、升级和卸载流程。
6. 完成 macOS 13 至发布时最新稳定版的兼容矩阵和真实 Finder E2E。
7. 完成全部 AC-001 至 AC-014 和发布阻断项审计。
8. 输出可发布构建、用户支持材料和可复现 release evidence。

## 3. 前序状态

### 3.1 必须已完成

- 阶段 0 至 3 均有通过的 exit report；
- 支持的 Cloudreve/Provider capability matrix 已冻结；
- 多 Domain、读写、上传恢复、冲突和最终一致性可通过 service API 使用；
- App 退出、SSE 降级、root/scope 异常和 auth expiry 有稳定 projection；
- mutation、删除、排除 cleanup、Domain removal 和 reconciliation 调用链已安全隔离；
- 核心故障注入和 72 小时长稳通过。

### 3.2 不允许带入的技术债

- UI 需要读取原始数据库表或拼 SQL；
- 任务取消需要持有旧 callback URL；
- Finder action 依赖未持久化内存状态；
- 未验证 Provider 在 UI 中显示为可写；
- 临时 HTTP/TLS 绕过或 testing entitlement 存在于 Release；
- 任何发布阻断项以“后续修复”状态进入 1.0 候选。

## 4. 范围与非范围

### 4.1 本阶段范围

- 完整菜单栏 popover、onboarding、添加 Domain、设置和冲突中心；
- 任务取消、重试、定位、历史清理；
- 通知分类、权限请求、去重和 deep link；
- Finder decoration、thumbnail、非 UI/UI custom action；
- 本机排除规则和特殊文件本地保留体验；
- 日志设置、健康检查、诊断包和隐私预览；
- 11 种语言和可访问性；
- 容量、实例图标、关于、版本和支持链接；
- migration、repair、准备卸载和清理流程；
- release CI、universal2、签名、公证、DMG 和 Gatekeeper；
- 全量 E2E、性能、长稳、兼容性和发布审计。

### 4.2 本阶段非范围

- partial content fetching；
- 选择性同步、暂停/继续 Domain、网络策略和高级缓存；
- 自动更新框架；
- 外置卷 Domain 和 Desktop/Documents known-folder replication；
- iOS/iPadOS、Web 管理后台和分享管理；
- Mac App Store 分发，除非另立决策并重做 entitlement/审核验证。

## 5. 需求追踪

本阶段完成所有未在前序阶段形成最终用户体验的 P0/P1：

| 需求组 | 本阶段重点 |
|---|---|
| FR-ONB-001 至 FR-ONB-005 | 正式首次启动、权限说明、空状态、登录启动 |
| FR-AUTH-007 至 FR-AUTH-009 | 正式重新授权与实例图标体验 |
| FR-DOM-001 至 FR-DOM-008、FR-DOM-011 至 FR-DOM-015 | Domain 设置、状态、打开、移除和异常恢复 UI |
| FR-FP-006、FR-FP-010 至 FR-FP-016 | Finder 保留下载、类型/权限/隐私边界 |
| FR-UP-010 至 FR-UP-012 | 进度、取消、重试 UI |
| FR-TSK-001 至 FR-TSK-010 | 菜单栏完整任务和状态体验 |
| FR-CNF-002 至 FR-CNF-007 | 持久冲突中心、通知和 Finder 装饰 |
| FR-FND-001 至 FR-FND-007 | Web 打开、立即检查、冲突 action、thumbnail、capacity |
| FR-IGN-001 至 FR-IGN-008 | 本机排除规则完整产品化 |
| FR-SET-001 至 FR-SET-008 | 设置与日志配置 |
| FR-NTF-001 至 FR-NTF-006 | 通知完整闭环 |
| FR-DIA-001 至 FR-DIA-006 | 日志、诊断、导出和健康检查 |
| FR-I18N-001 至 FR-I18N-003 | 11 种语言和本地格式 |
| FR-A11Y-001 至 FR-A11Y-004 | 可访问性完整验收 |
| FR-LIFE-001 至 FR-LIFE-006、FR-LIFE-008 至 FR-LIFE-012 | 生命周期、升级、卸载和修复 |
| AC-001 至 AC-014 | 1.0 全量验收 |

## 6. 详细实施方案

### 6.1 工作包 P4-W1：设计系统与导航壳

在 `Packages/NimbusSyncDesignSystem/` 建立受控 token 和组件：

| 领域 | 实施要求 |
|---|---|
| Color | 跟随 light/dark、高对比度；状态不只依赖颜色 |
| Typography | 系统字体、Dynamic Type 可读范围；紧凑工具界面不用 hero 字号 |
| Spacing/radius | 统一 4/8/12/16 spacing，卡片圆角不超过 8 pt |
| Icons | 优先 SF Symbols；不手绘常见系统操作图标 |
| Controls | toggle 表示布尔、menu 表示选项、icon button 有 tooltip/accessibility label |
| Layout | `NSStatusItem + NSPopover`、Settings `NavigationSplitView`、独立 onboarding/conflict windows |

状态文案统一由 `DomainHealthReducer` 输出，UI 不自行判断 healthy。所有 destructive action 使用明确对象范围和二次确认。

### 6.2 工作包 P4-W2：菜单栏 Popover 与任务中心

实现 `Apps/NimbusSync/MenuBar/`：

| 区域 | 能力 |
|---|---|
| Header | 产品标识、设置、添加 Domain |
| Domain filter | 全部/单 Domain，数量多时可横向滚动或菜单 |
| 需要处理 | auth、root/scope、conflict、permanent error 持久置顶 |
| 正在同步 | 方向、名称、字节、速度、进度、取消 attempt |
| 最近 | 最近 20 项、状态、时间、Domain、Finder 定位 |
| Footer | 全局状态；degraded/offline/app-not-running/reconciling 不显示已是最新 |

任务来源合并本地 task、pending set 和 global progress。pending set 达上限或遗漏初始传输时不推导“无任务”。Popover 打开只读本地 projection，p95 不高于 300 ms。

### 6.3 工作包 P4-W3：Onboarding、添加 Domain 与设置

正式添加流程：URL -> site validation -> OAuth -> root confirmation -> Domain config -> provisioning -> first health -> Finder。

设置栏目：

| 页面 | 能力 |
|---|---|
| 网盘 | 状态、origin、root、capacity、最近同步/错误、Finder、Web、重新授权、排除、移除 |
| 通用 | 登录启动、语言、外观跟随、必要生命周期说明 |
| 通知 | 总开关、auth/conflict/permanent failure/sync complete 分类 |
| 诊断 | 日志、health checks、版本、数据库/journal 摘要、导出 |
| 关于 | 版本、许可证、主页、源码、Issue/支持入口 |

Domain provisioning/removal 进度来自持久 saga。关闭设置不退出同步；退出主应用必须明确实时性降级。

### 6.4 工作包 P4-W4：冲突中心

在 `Apps/NimbusSync/ConflictCenter/` 实现：

1. 持久列表按 Domain、类型、时间筛选；
2. 详情展示 base/local/remote 的时间、大小和位置；
3. 保留远端前二次确认，明确本地改动结果；
4. 覆盖远端使用 resolution intent，等待新 callback URL，不从旧路径上传；
5. 保留两个版本展示最终副本名和 collision 处理；
6. 远端再次变化时保持冲突，不假成功；
7. deep link `nimbussync://conflict/<opaque-id>` 只携带本地 ID；
8. Finder action 和通知只导航，不直接执行不可逆覆盖。

### 6.5 工作包 P4-W5：Finder 增强

| 能力 | Target | 实施 |
|---|---|---|
| 立即检查更新 | File Provider | 非 UI custom action，持久化 scope reconcile intent |
| 在 Cloudreve 中查看 | File Provider UI | 提供反馈后唤起 App，App 按 item ID 查询受信 URL |
| 解决冲突 | File Provider UI | 仅 conflict predicate 可见，导航冲突中心 |
| Thumbnail | File Provider | `remote ID + contentVersion + sizeClass` cache，失败回退 |
| Decoration | File Provider | conflict、permission/shared、error 从持久状态派生 |
| Capacity | App settings | 展示服务端容量及更新时间，不阻塞 Finder |

File Provider UI 不读取 token/DB、不联网、不执行 mutation。Action predicate 只使用 item/domain `userInfo` 中的非敏感最小状态。

### 6.6 工作包 P4-W6：本机排除规则产品化

规则 UI：每 Domain 编辑、语法校验、默认规则说明、受影响对象预览、dirty 风险确认和应用进度。

应用流程：

```text
compile rule revision
  -> compute remote view additions/removals
  -> enumerate materialized/dirty impact
  -> block or preserve dirty data
  -> persist intents + new epoch
  -> publish working-set changes
  -> signalErrorResolved when rules are removed
```

验收重点：

- 根不可排除；
- 已显示远端 item 从本机视图移除但远端保留；
- 本地命中项由系统保留为仅此 Mac；
- unsupported local type 使用同一安全 intent；
- cleanup `deleteItem` 精确命中 intent，不进入远端 delete；
- rule update 与用户永久删除/本地编辑串行；
- 产品不声明 Finder 原生 `.allowsExcludingFromSync`。

### 6.7 工作包 P4-W7：通知与 deep link

| 通知 | 触发与去重 | 点击行为 |
|---|---|---|
| Auth expired | 每 Domain/credential generation 一次 | 打开重新授权 |
| Conflict | 每 conflict ID 一次 | 打开冲突详情 |
| Permanent failure | retry exhausted/需用户处理 | 打开任务或诊断 |
| Sync complete | 默认关闭，按批次聚合 | 打开任务历史 |

通知权限在首次需要前说明用途。锁屏正文默认只含必要文件名/Domain；敏感路径不展示。App 未运行时 deep link 激活同一实例并从 Store 重新加载状态。

### 6.8 工作包 P4-W8：日志、健康检查与诊断包

正式诊断能力：

| 项目 | 内容 |
|---|---|
| 日志设置 | 开关、级别、轮转数量/大小、哪些进程需重启 |
| Health | API、认证、SSE、File Provider、DB、schema、root/scope、outbox |
| Manifest | App/Extension/Core/schema/server/OS/arch 和能力摘要 |
| Counters | operation/task/conflict、journal、WAL、reconcile、SSE |
| Privacy preview | 导出前列出包含项，文件名/路径默认关闭 |
| Export | 用户主动选择位置；不含 token、signed URL、content 或原始数据库 |

CI 对日志 fixture、诊断包和 SQLite 导出摘要执行 secret scan。崩溃报告 breadcrumb 只含本地短 ID 和稳定错误码。

### 6.9 工作包 P4-W9：国际化与可访问性

使用 String Catalog 覆盖 `en-US`、`zh-CN`、`zh-TW`、`ja`、`de`、`fr`、`es`、`ko`、`ru`、`pl`、`it`。

| 领域 | 验收 |
|---|---|
| Localization | 无硬编码用户文案；日期、数字、字节、复数本地化 |
| Pseudolocalization | 30% 扩展文本下无截断、重叠或按钮溢出 |
| VoiceOver | 图标按钮、状态、进度、列表和冲突动作语义完整 |
| Keyboard | onboarding、settings、popover、conflict 无鼠标可完成 |
| Contrast | light/dark/increased contrast 均满足可辨识性 |
| Reduce Motion | 关闭非必要动画，无持续旋转干扰 |
| Color independence | 状态同时有图标/文字，不只使用红绿 |

### 6.10 工作包 P4-W10：升级、修复与准备卸载

| 流程 | 实施 |
|---|---|
| Upgrade | 新旧相邻 schema compatibility、generation fencing、shadow migration |
| Old Extension | 发现 generation/compat 不匹配时关闭连接并返回可重试升级中 |
| Repair | quick check、隔离 DB/WAL、恢复 backup、保护 operation/session/conflict |
| Reimport | 主应用持久化 intent，等待 `importDidFinish`，不把 completion 当完成 |
| Prepare uninstall | 逐 Domain wait/preserve/remove，注销 login item，最后清凭据 |
| Failed uninstall prep | 保留 action state，可重试，不清远端 |

升级测试覆盖从首个公开 Beta 到 1.0 的每个支持 schema，不只测试全新安装。

### 6.11 工作包 P4-W11：构建、供应链与发布

Release pipeline：

1. 锁定 SwiftPM/Cargo/rust-toolchain 依赖；
2. 构建 arm64、x86_64 和 universal XCFramework/App；
3. 验证 UniFFI generated binding 无未提交 drift；
4. 生成 SBOM、Rust/Swift 依赖许可证和 artifact checksum；
5. 执行 Release entitlement/config/secret scan；
6. Developer ID codesign，验证 nested `.appex` 和 Hardened Runtime；
7. `notarytool submit`、staple、`spctl`/Gatekeeper 实机验证；
8. 生成 DMG，验证首次安装、覆盖升级和干净卸载；
9. 产出 release manifest、版本号、commit、构建环境和测试报告；
10. 1.0 不引入自动更新框架，更新指引只链接受信官方发布页。

### 6.12 工作包 P4-W12：全量 QA 与发布演练

测试矩阵：

| 维度 | 覆盖 |
|---|---|
| macOS | 13、14、15、26 及发布时最新稳定版 |
| CPU | Apple Silicon、Intel |
| 文件系统 | APFS 大小写敏感/不敏感、低磁盘 |
| Cloudreve | 已声明支持的 Community/Pro 版本 |
| Provider | 发布可写矩阵全部 Provider |
| 网络 | 离线、超时、代理、私有 CA、切网、服务端重启 |
| 规模 | 100,000/Domain、10,000/目录、大文件、深目录 |
| 生命周期 | kill、sleep/wake、restart、upgrade、repair、uninstall |
| Finder | read/write/copy/move/trash/restore/delete/evict/keep downloaded/actions |

至少完成一次 release rehearsal：从签出 tag 到生成 notarized DMG，再在两台干净机器执行安装、AC smoke、升级和卸载。

## 7. 执行顺序与依赖

| 顺序 | 工作包 | 依赖 | 可并行项 |
|---:|---|---|---|
| 1 | W1 Design system | Phase 3 projections | W8 Diagnostics core |
| 2 | W2 Menu/task | W1、task projection | W3 Settings |
| 3 | W3 Onboarding/settings | W1、Domain/Auth services | W4 Conflict |
| 4 | W4 Conflict | conflict services | W5 Finder enhancements |
| 5 | W5 Finder enhancements | stable item/domain userInfo | W6 Exclusion UI |
| 6 | W6 Exclusion | Phase 2 intent + Phase 3 working set | W7 Notifications |
| 7 | W8/W9 Diagnostics/i18n/a11y | UI 基本稳定 | W10 Upgrade |
| 8 | W10 Upgrade/uninstall | schema/removal stable | W11 Release pipeline |
| 9 | W12 Full QA | 功能冻结 | 发布修复 |
| 10 | Release candidate | 所有门禁 | 无 |

## 8. 验收标准

### 8.1 产品验收

- PRD P0 + P1 全部有实现、测试和用户可见行为；
- AC-001 至 AC-014 在支持矩阵中全部通过；
- 菜单栏、设置、Finder 和通知对同一 Domain 状态文案一致；
- auth、root/scope、conflict、offline、reconciling、event degraded、app not running 不会被 healthy 覆盖；
- 所有 destructive action 明确对象范围并保护 dirty data；
- 未验证能力不出现在 UI，或显示为只读/不支持。

### 8.2 UX 与可访问性验收

1. Popover、设置、onboarding、冲突中心在最小窗口和 11 种语言下无截断/重叠；
2. 全流程可用键盘完成；
3. VoiceOver 顺序、名称、角色、状态和进度正确；
4. light/dark/increased contrast/reduce motion 通过；
5. 通知点击、Finder action 和 deep link 在 App 未运行时可恢复；
6. 错误文案可理解，诊断码与用户文案分离；
7. 不用可点击文本替代标准按钮，不嵌套无意义卡片。

### 8.3 安全与隐私验收

- Release 仅 HTTPS，Debug loopback 例外不进入产物；
- Bearer 不跨 origin，Provider signed URL 不携带 Cloudreve token；
- Keychain 是 secret 唯一持久化位置；
- 日志、通知、诊断包和 crash breadcrumb 通过 secret/privacy scan；
- File Provider UI 无 network/Keychain entitlement；
- Domain/item/deep-link ID 均为本地不透明值；
- 权限撤销文案不承诺远程擦除；
- 许可证、第三方 notices 和品牌资产授权完成审核。

### 8.4 发布工程验收

| 项目 | 通过标准 |
|---|---|
| Build | universal2 App/XCFramework，可复现且无构建期网络 |
| Codesign | App、两个 appex、framework 全部通过严格校验 |
| Notarization | submit accepted、ticket stapled |
| Gatekeeper | 干净机器首次打开无绕过步骤 |
| Upgrade | 支持 Beta -> 1.0，旧 Extension fencing 生效 |
| Uninstall prep | dirty data 保留，Domain/login item/credential 无孤儿 |
| DMG | 校验和、版本、许可证和安装说明一致 |
| SBOM | 与 lockfiles/产物依赖一致 |

### 8.5 性能与稳定性验收

- Popover p95 不高于 300 ms；
- 普通目录首屏 p95 不高于 2 秒；
- 正常 SSE 变化 p95 不高于 5 秒；
- 100,000 item/Domain、10,000 item/目录通过；
- App/Extension 常态内存建议不高于 150 MB；
- 72 小时长稳和随机 kill 无静默丢失、重复对象、循环或不可解释 journal 增长；
- 多 Domain 下用户 fetch/mutation 不被后台工作饿死；
- 空闲无高频轮询，sleep 后无持续网络活动。

### 8.6 自动化检查

当前开发构建使用 `Scripts/build.sh` 的构建前检查；Release workflow 暂缓，真实平台和
发布证据仍通过未来的独立环境任务提供：

```text
all Rust/Swift/store/contract/File Provider tests
AC-001..AC-014 automation and manual evidence manifest
UI snapshot + pseudolocalization + accessibility audit
performance and long-run approved reports
secret/privacy/license/SBOM scans
universal2 build + codesign + notarization + Gatekeeper
fresh install + upgrade + prepare-uninstall tests
```

## 9. 发布阻断审计

发布候选必须逐项关闭 PRD 第 13 节。以下类别不得豁免：

| 类别 | 阻断示例 |
|---|---|
| 数据正确性 | 静默覆盖、重复 create、错误 tombstone、目录环 |
| 删除安全 | Domain remove/排除 cleanup 进入远端 delete |
| 身份 | item/root 仅按路径，替换后接管新对象 |
| 恢复 | callback URL 失效、upload session 不可恢复、signal outbox 漏交付 |
| 一致性 | SSE 缺口不校准、本地回声形成循环、状态误报 healthy |
| 安全 | token/signed URL 泄露、HTTP Release、Bearer 跨 origin |
| 兼容性 | 支持矩阵 Provider 无 contract test、目标 OS/CPU 未验证 |
| 发布 | 签名、公证、升级、卸载任一失败 |

任何阻断项只能通过修复或缩小公开支持范围关闭，不能只在 release note 中声明“已知问题”。

## 10. 阶段交付物

| 交付物 | 说明 |
|---|---|
| 完整 1.0 App | 菜单栏、窗口、Finder 和通知体验 |
| Design system | tokens、components、String Catalog、a11y conventions |
| Finder enhancements | actions、decoration、thumbnail、capacity |
| Diagnostics | health checks、logs、privacy preview、export |
| Release pipeline | universal2、sign、notarize、DMG、SBOM/checksum |
| 测试证据 | AC-001 至 AC-014、性能、长稳、兼容和安全报告 |
| 支持矩阵 | macOS、CPU、Cloudreve、Provider、能力和已知降级 |
| 阶段报告 | `docs/reports/phase-4-release-readiness.md`，作为历史发布审计记录保留 |

## 11. 完成定义与发布决策

### 11.1 Release Candidate 条件

1. Phase 0 至 Phase 4 的历史验收条件在候选 commit 上全部有证据；
2. AC-001 至 AC-014 全部有当前候选版本证据；
3. 发布阻断项为零；
4. 支持矩阵、隐私文案、许可证和品牌决策冻结；
5. notarized DMG 在干净 Apple Silicon/Intel 机器通过安装、升级和卸载；
6. 数据迁移、repair 和 preserved dirty location 经人工复核；
7. release manifest 能追溯 commit、工具链、依赖、测试和 artifact checksum。

### 11.2 No-Go 条件

- 任一数据损坏、误删、凭据泄露或 identity 漂移路径未关闭；
- 任一公开可写 Provider 缺少真实 contract test；
- 事件缺失或进程终止后无法自动收敛；
- 签名、公证、Gatekeeper、升级或卸载失败；
- 可访问性阻塞核心流程；
- 实际支持范围与产品文案不一致。

### 11.3 发布后边界

1. 1.0 不包含自动更新、partial fetch、暂停/继续或选择性同步；
2. 未验证 Provider 保持只读或不支持；
3. 线上问题优先通过 capability fail-closed、停止相关 mutation 和保留 dirty data 降低风险；
4. 任何平台/协议假设变化必须先更新 PRD、架构、支持矩阵和阶段回归用例，再修改实现。
