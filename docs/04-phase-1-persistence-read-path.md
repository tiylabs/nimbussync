# 阶段 1 实施计划：持久化、认证与 File Provider 读路径

> 阶段编号：Phase 1
> 阶段状态：Conditional Go（本地 Store/Auth/read-path 门禁完成；真实签名 App Group/Keychain/Finder/Cloudreve 规模证据待补）
> 目标版本：Technical Preview
> 前序阶段：[阶段 0：协议门禁与 File Provider Spike](./03-phase-0-protocol-file-provider-spike.md)
> 后续阶段：[阶段 2：写路径与上传恢复](./05-phase-2-write-path-upload-recovery.md)

## 1. 需求背景

阶段 0 只证明 Cloudreve 和 File Provider 契约可以成立。本阶段需要把 Spike 收敛成可维护的生产基础：稳定身份、可迁移数据库、Keychain、Domain provisioning、目录快照、change anchor、完整下载和最小用户入口。

读路径是后续所有写入和最终一致性的基础。若 item identity、目录分页、版本映射或离线快照不稳定，阶段 2 的 operation saga 和阶段 3 的 reconciliation 都无法安全工作。因此本阶段优先完成“可恢复的事实源”和“不会误报完整性”的 Finder 只读体验，再开放生产写路径。

## 2. 阶段目标

1. 建立正式工程模块、Rust crates、UniFFI API 和可重复构建流程。
2. 实现 registry/domain SQLite schema、migration、备份、损坏检测和 schema fencing。
3. 实现 OAuth、Keychain、跨进程 token refresh 和可恢复 Domain provisioning。
4. 实现多 Domain 的稳定 root/item identity、名称/类型/权限映射和范围防护。
5. 实现目录 snapshot 分页、change anchor 骨架、materialized/pending set 镜像。
6. 实现完整 `fetchContents`、取消、校验、临时文件和 eviction。
7. 提供首次启动、添加 Domain、菜单栏基础状态和 Finder 打开入口。
8. 在离线、重启和 100,000 item 规模下保持正确性和资源边界。

## 3. 前序状态

### 3.1 必须已完成

- 阶段 0 为 Go 或 Conditional Go；
- 最低 macOS、Cloudreve 基线和首批只读/可写能力矩阵已冻结；
- 稳定 item/root identity 和分页策略已有实测结论；
- Xcode Target、entitlement 和 Rust FFI 边界已建立；XCFramework 打包暂缓；
- 所有未通过能力都已有 fail-closed 行为。

### 3.2 允许存在

- Spike 代码可不具备生产 schema、抽象或完整错误处理；
- 只验证过单 Domain；
- mutation、上传恢复、SSE 和正式 UI 尚未实现；
- 部分 Provider 可保持 `unverified` 或只读。

### 3.3 开始检查

| 检查项 | 进入要求 |
|---|---|
| Phase 0 exit report | 已批准，未关闭风险有 owner 和降级方案 |
| Capability snapshot | 字段、来源、revision 和刷新条件明确 |
| FFI | DTO 已版本化，错误码稳定，大文件不跨 FFI 复制 |
| 数据保护 | Keychain/App Group/日志边界已经实机验证 |
| 测试环境 | 支持至少 5 Domain、10,000 单目录和 100,000 item 数据集 |

## 4. 范围与非范围

### 4.1 本阶段范围

- 正式工程和模块边界；
- registry/domain store、schema、migration、backup、repair state；
- Keychain credential、refresh coordination、重新授权基础；
- Domain create/recover/remove 的基础 provisioning saga；
- 多 Domain read-only 运行；
- item mapping、目录快照、page token、anchor、working/materialized/pending set；
- 完整下载、校验、取消、离线读取、eviction；
- 最小 onboarding/menu/settings shell；
- 基础日志、correlation ID、secret redaction；
- 读路径性能、内存和故障注入。

### 4.2 本阶段非范围

- 生产 create/modify/move/delete；
- 分片上传和跨进程续传；
- SSE 长连接和全量 reconciliation；
- 完整冲突中心、通知、Finder action、缩略图和排除规则；
- 发布签名、公证、DMG 和 11 种语言完成度。

## 5. 需求追踪

| 需求/验收 | 本阶段交付范围 |
|---|---|
| FR-ONB-001 至 FR-ONB-003 | 欢迎、添加 Domain、空状态的最小可用版本 |
| FR-AUTH-001 至 FR-AUTH-008、FR-AUTH-010 | 站点校验、OAuth、Keychain、refresh、重新授权 |
| FR-DOM-001 至 FR-DOM-005、FR-DOM-011、FR-DOM-013 至 FR-DOM-015 | 多 Domain、稳定范围、provisioning 恢复 |
| FR-FP-001 至 FR-FP-005、FR-FP-008 至 FR-FP-011、FR-FP-014 至 FR-FP-016 | 完整生产读路径 |
| FR-TSK-001 至 FR-TSK-007、FR-TSK-010 | 下载任务和基础状态 projection |
| FR-DIA-001、FR-DIA-002 | 结构化日志和脱敏基础 |
| FR-A11Y-001、FR-A11Y-002、FR-A11Y-004 | 最小 UI 从第一阶段满足可访问性 |
| FR-LIFE-001、FR-LIFE-002、FR-LIFE-004、FR-LIFE-005、FR-LIFE-008、FR-LIFE-009、FR-LIFE-011、FR-LIFE-012 | 生命周期、迁移、损坏和 reimport 基础 |
| AC-001、AC-002、AC-009 | 本阶段完整验收 |
| AC-007、AC-010、AC-012、AC-013、AC-014 | 完成与读路径/认证/Domain 相关子场景 |

## 6. 详细实施方案

### 6.1 工作包 P1-W1：正式工程与依赖边界

| 路径 | 实施内容 |
|---|---|
| `NimbusSync.xcodeproj` | 固化 App、File Provider、File Provider UI、test、aggregate targets 和 scheme |
| `Config/*.xcconfig` | bundle ID、App Group、Keychain Group、deployment target、Debug/Release 能力 |
| `Packages/NimbusSyncDomainKit` | Domain descriptor、lifecycle、identity、scope guard、state reducer |
| `Packages/NimbusSyncAuthKit` | OAuth、Keychain、refresh lock、redactor |
| `Packages/NimbusSyncStoreBridge` | App Group URL、schema bootstrap、UniFFI repository wrapper |
| `Packages/NimbusSyncObservability` | OSLog、correlation ID、稳定错误码、脱敏 |
| `Rust/crates/*` | 按架构拆分 protocol、store、core、ffi，移除 Spike 临时耦合 |

工程规则：主应用和 Extension 各自加载静态 Core，不共享内存/runtime；UI 不拼 SQL；Rust 不持有 Apple Framework 对象；Release build phase 不访问网络。

### 6.2 工作包 P1-W2：Registry 与 Domain schema

实现架构第 8 节定义的生产 schema，阶段 1 至少包含：

| 表/能力 | 本阶段实现 |
|---|---|
| `domains` | stable root ID/current URI、scope、status、secret ref、capability snapshot |
| `domain_actions` | provision/remove 基础 saga 与启动恢复 |
| `schema_meta` | version、generation、compat range、migration state |
| `items` | opaque ID、remote ID、parent、provider name、kind、version、permission、tombstone |
| `directory_snapshots` | generation、cursor、complete、稳定 order key |
| `change_journal` | provider-side sequence、epoch、parent 和 version |
| `signal_outbox` | working-set revision 的可靠 signal |
| `sync_state` | anchor、Domain version、事件/校准占位状态 |
| `materialized_containers`、`system_set_state`、`pending_items` | 系统集合镜像 |
| `tasks` | 下载和基础 operation projection |

数据库要求：WAL、foreign keys、`synchronous=FULL`、3 秒 busy timeout、短事务、显式索引、online backup、`quick_check`、损坏隔离和 generation fencing。

迁移策略：首版仍建立 migration harness 和 downgrade/forward-compat 测试，禁止把“还没有历史版本”作为不设计升级机制的理由。

### 6.3 工作包 P1-W3：认证与凭据生命周期

| 模块 | 实施内容 |
|---|---|
| `OAuthCoordinator` | 默认浏览器、AppDelegate deep link、PKCE S256、一次性 state、严格 callback host/path |
| `CredentialVault` | 每 Domain 单一 Keychain item，保存 token、expiry、generation、token-family metadata |
| `TokenRefreshCoordinator` | App Group advisory lock、有上限等待、Keychain generation 修复、unknown refresh outcome |
| `SiteService` | HTTPS origin 规范化、site ping、版本/能力探测、manifest icon 基础 |
| 重新授权 | 服务端重新确认 account/root ID；账号不一致拒绝；Domain/item ID 不变 |

测试必须覆盖：两个进程并发刷新、owner 在请求前/响应后/Keychain 后终止、Keychain 锁定、refresh token 过期和错误日志脱敏。

### 6.4 工作包 P1-W4：Domain provisioning saga

创建流程：

```text
prepared
  -> credential_written
  -> domain_db_ready
  -> system_domain_added
  -> first_read_healthy
  -> registered
```

实现要点：

1. 生成 `crd-<uuid>` 并事务预留 scope；
2. 保存 stable root ID/current URI 和 capability revision；
3. 写 Keychain、初始化 Domain DB、调用 `addDomain`；
4. 使用 `getDomains` 对账，已存在同 identifier 视为幂等恢复；
5. 首次 root item 和一页枚举成功后才显示完成；
6. App 启动扫描半完成 action，继续或按反向顺序回滚；
7. 回滚只清本地状态，不调用 Cloudreve delete；
8. 同账号重叠 scope 在事务中 fail closed。

阶段 1 的移除只开放无 dirty write 的 Domain；完整 dirty-data 安全移除在阶段 2 完成。

### 6.5 工作包 P1-W5：Item identity 与 metadata mapping

| 领域 | 实施要求 |
|---|---|
| Root | stable root ID 固定映射 `.rootContainer`，不创建普通 item UUID |
| 普通 item | `cri-<uuid>`，remote ID 单独存储，路径不参与身份 |
| Parent | 数据库 parent UUID；working-set item 返回真实 parent |
| Version | content/metadata 分离，规范二进制哈希，远端版本不可靠时禁用相关缓存语义 |
| Name | 优先交给 File Provider bounce；仅不可表示名称使用持久可逆映射 |
| Type | macOS 必须提供 `contentType`；file/folder/symlink 类型转换创建新 identity |
| Permission | 映射 read/write/add/trash/delete capability，未知权限按只读 |
| Privacy | identifier、日志和 Domain `userInfo` 不含远端 ID、文件名和路径 |

### 6.6 工作包 P1-W6：目录 snapshot 与枚举

实现 `Enumerator` 和 Core repository：

1. page token 小于 500 bytes，只保存版本、Domain、parent、snapshot generation 和 offset；
2. 远端 cursor 留在 SQLite，不进入 token；
3. 使用系统 suggested page size，并受服务端上限约束；
4. 只有最后一页成功后 snapshot 才标记 complete；
5. 离线只返回完整旧 snapshot，不把半页当完整目录；
6. 无稳定服务端 snapshot 时，先构建本地 generation 再向系统分页；
7. 首次无快照且超出 callback deadline 时返回可重试错误；
8. 并发远端变化写入后续 journal，不改变当前 generation 的排序；
9. 实现 root、普通 container 和 `.workingSet` enumerator；
10. `currentSyncAnchor` 与 `enumerateChanges` 支持 epoch/sequence 和 anchor expiry。

### 6.7 工作包 P1-W7：materialized/pending set 与 Domain state

| 能力 | 实施内容 |
|---|---|
| Materialized set | 持久 refresh intent、增量 anchor、已落盘目录集合 |
| Pending set | 有上限镜像，与本地 task 合并；不作为成功/安全移除的唯一依据 |
| Domain state | 持久 `NSFileProviderDomainVersion` 和最小非敏感 `userInfo` |
| Signal outbox | journal/domain state 同事务写 outbox，signal 成功后确认 revision |
| Working set | materialized 目录直接子项、recent、pending、shared、trash 顶层 |

本阶段没有正式 SSE，但通过测试控制端写入 provider-side change，验证 outbox、working-set change 和重启补发。

### 6.8 工作包 P1-W8：完整下载与 eviction

`ContentCoordinator` 流程：

```text
item/version lookup
  -> credential
  -> temporaryDirectoryURL + exclusive temp file
  -> streaming download/decrypt
  -> length/version/integrity check
  -> persist task result
  -> completion(temp URL + final item)
```

约束：

- 只实现完整下载，不实现 partial fetch；
- 使用固定 buffer，内容不整体载入内存；
- 取消必须终止网络和解密并快速 completion；
- 完成后不再修改系统接管的 temp file；
- 清理仅针对本客户端前缀、已知终态和超过最小保留时间的崩溃残留；
- 无读取权限、认证失败、离线、磁盘满、item 不存在映射为合法 File Provider/Cocoa 错误；
- materialized item 的 eviction 由系统执行，未上传状态不得错误标记为 evictable。

### 6.9 工作包 P1-W9：最小产品入口

| 界面 | 本阶段能力 |
|---|---|
| 首次启动 | 欢迎、添加网盘、说明 Finder/按需下载 |
| 添加网盘 | URL、OAuth、远端范围确认、Domain 名称、初始化、完成 |
| 菜单栏 | 无网盘、初始化、healthy、offline、auth expired、下载任务 |
| 设置 | Domain 列表、在 Finder 打开、重新授权、移除只读 Domain |
| 可访问性 | VoiceOver label、键盘操作、非颜色状态、动态内容不溢出 |

UI 只读 projection，不直接写同步表；命令调用 Domain/Auth service。

### 6.10 工作包 P1-W10：日志与基础诊断

- Swift `OSLog` 与 Rust `tracing` 使用统一 correlation ID；
- 默认只记录本地短 ID、阶段、耗时、字节数和稳定错误码；
- token、code、cookie、signed query、文件内容和完整路径自动脱敏；
- 提供开发版健康摘要：App/Extension/Core/schema/server 版本、Domain 状态、DB quick check；
- 增加 secret scanner 测试，扫描 SQLite dump、日志和失败 artifact。

## 7. 执行顺序与依赖

| 顺序 | 工作包 | 依赖 | 可并行项 |
|---:|---|---|---|
| 1 | W1 工程边界 | Phase 0 | W2 schema 设计 |
| 2 | W2 Store | W1 FFI/build | W3 Auth |
| 3 | W3 Auth | W1、能力矩阵 | W4 saga 设计 |
| 4 | W4 Provisioning | W2、W3 | W5 mapping |
| 5 | W5 Item mapping | W2、root contract | W6 snapshot |
| 6 | W6 Enumeration | W5、分页 contract | W7 system sets |
| 7 | W7 Sets/DomainState | W2、W6 | W8 download |
| 8 | W8 Download | W3、W5 | W9 UI、W10 diagnostics |
| 9 | W9/W10 产品入口 | 前述 projection/service | 性能测试 |
| 10 | 集成与门禁 | 全部 | 无 |

## 8. 验收标准

### 8.1 功能验收

1. AC-001 全部通过；
2. AC-002 全部通过；
3. 5 个不同实例/账号 Domain 可并存，重叠范围被拒绝；
4. 重新授权保持 Domain/item identity，错误账号被拒绝；
5. root rename/move 后按 stable ID 更新 URI，同路径替换不接管；
6. 离线返回完整缓存，不完整 snapshot 不出现为完整目录；
7. read permission 撤销后新下载被拒绝，既有副本边界文案正确；
8. Extension 和 App 重启后 Domain version、anchor、outbox 和下载任务状态可恢复。

### 8.2 性能验收

| 指标 | 阶段门槛 |
|---|---:|
| 单 Domain item | 100,000 |
| 单目录 item | 10,000，稳定分页 |
| 普通目录首屏枚举 | 正常网络 p95 不高于 2 秒 |
| Popover 本地打开 | p95 不高于 300 ms |
| Extension 常态内存 | 建议不高于 150 MB，且不随总 item 数线性增长 |
| 下载内存 | 固定 buffer，不随文件大小增长 |
| Page token | 小于 500 bytes |

### 8.3 可靠性与安全验收

- provisioning 每一步终止后只会继续或回滚一次；
- migration 中止不会生成半 schema 或空库覆盖；
- SQLite 损坏会进入 repair state，pending/dirty 事实不被清空；
- Keychain refresh 并发只有一个网络 owner；unknown outcome 不循环刷新；
- journal commit 后终止仍可补发 working-set signal；
- File Provider 错误仅使用允许的 error domain；
- secret scanner 对日志、SQLite 和 CI artifact 无命中；
- Release 拒绝 HTTP、跨 origin Bearer 和无效证书。

### 8.4 自动化检查

阶段实现曾使用阶段聚合门禁；当前由 `Scripts/build.sh` 执行构建前仓库检查，Rust/Swift
测试和以下专项测试按开发命令直接运行：

```text
cargo test --workspace
xcodebuild Swift unit tests
xcodebuild File Provider integration tests
store migration/crash tests
100k item enumeration benchmark
secret scan
Release entitlement/config scan
```

## 9. 阶段交付物

| 交付物 | 说明 |
|---|---|
| 生产工程骨架 | Xcode targets、Swift packages、Rust crates、FFI 边界 |
| Store v1 | registry/domain schema、migration、backup、repair/fencing |
| Auth v1 | OAuth、Keychain、refresh、重新授权 |
| Read path v1 | 多 Domain、枚举、完整下载、eviction、离线 snapshot |
| 基础 UI | onboarding、添加 Domain、菜单栏状态、Finder 入口 |
| 自动化检查 | `Scripts/build.sh` 及 Rust/Swift 专项测试命令 |
| 阶段报告 | `docs/reports/phase-1-exit.md` |

## 10. 阻断条件与完成定义

### 10.1 阻断条件

- 100,000 item/10,000 单目录无法稳定分页或内存失控；
- item/root identity 在重启、rename 或 move 后漂移；
- provisioning、migration 或损坏恢复会丢凭据/状态；
- Extension 依赖主应用存活才能下载；
- token、signed URL 或 OAuth code 出现在日志/SQLite；
- callback 返回后依赖未持久化 detached task 才能保证正确。

### 10.2 完成定义

阶段 1 完成必须同时满足：

1. AC-001、AC-002 完整通过；
2. 本阶段需求追踪表中的条目有测试或明确延后记录；
3. 读路径性能和故障注入门禁通过；
4. store/auth/domain/read path API 冻结，阶段 2 无需绕过 repository；
5. 工作区无未解释生成物，阶段报告记录测试环境和证据；
6. 阶段 0 的 Conditional Go 降级仍被保留，没有被实现层偷偷放宽。
