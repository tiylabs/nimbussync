# 阶段 0 实施计划：协议门禁与 File Provider Spike

> 阶段编号：Phase 0
> 阶段状态：Conditional Go（本地工程/自动化门禁完成；真实 Cloudreve、签名 Finder 与 Provider 环境证据待补）
> 目标版本：Technical Preview 前置门禁
> 输入文档：[产品需求](./01-macos-product-requirements.md)、[技术架构](./02-macos-technical-architecture.md)
> 后续阶段：[阶段 1：持久化与读路径](./04-phase-1-persistence-read-path.md)

## 1. 需求背景

Cloudreve Windows 客户端依赖 CFAPI、路径型 inventory 和普通文件系统 watcher，不能直接迁移到 macOS。macOS 版本的核心风险不在界面，而在两组尚未被真实环境证明的契约：

1. Cloudreve 是否提供足够稳定的实体身份、分页、条件写、创建幂等、删除和上传恢复语义；
2. Replicated File Provider 在目标 macOS 版本上的 callback 重放、working set、trash、排除、Domain 移除和进程终止行为是否满足产品要求。

本阶段以最小可运行 Spike 和自动 contract test 消除这些风险。Spike 只证明协议和系统行为，不承担生产级数据迁移、完整 UI、多 Domain 或全部 Provider 的最终实现。

## 2. 阶段目标

1. 建立可签名运行的 macOS App、File Provider Extension、File Provider UI Extension 和 Rust XCFramework 最小工程。
2. 对技术架构第 19 节的协议门禁逐项形成可复现证据和能力矩阵。
3. 在真实 Finder 中跑通单 Domain 的枚举、完整下载、基础修改和 callback 重放。
4. 验证稳定 root/item identity、合法 identifier、working-set signal、Domain version 和进程强杀恢复。
5. 冻结最低 macOS、最低 Cloudreve 版本、首批可写 Provider 和必须降级的能力。
6. 输出明确的 Go、Conditional Go 或 No-Go 结论，为阶段 1 提供不可变输入。

## 3. 前序状态

### 3.1 已具备

- 已完成 Windows 参考实现调研；
- 已完成 PRD 1.3 和 Architecture Baseline 1.3；
- 已确定 Swift + Rust + Replicated File Provider 路线；
- 已列出稳定身份、条件 mutation、上传恢复、trash、SSE 和 TLS/代理门禁。

### 3.2 尚不具备

- 仓库尚无 Xcode 工程、Swift Target、Rust workspace 或签名配置；
- 尚无真实 Cloudreve Community/Pro 测试矩阵；
- 尚未证明 `FileResponse.id`、`primary_entity`、分页和 upload session 的实际语义；
- 尚未完成 File Provider entitlement、Domain 注册和 Finder 回调实机验证；
- 尚无正式 schema、生产 UI 或发布构建。

### 3.3 开始条件

| 条件 | 要求 |
|---|---|
| Apple 开发环境 | Xcode、Developer ID/开发签名、可运行 File Provider Extension 的测试机 |
| macOS 环境 | 至少覆盖计划最低版本和当前最新稳定版；Intel 可在阶段末补齐，但必须在 Beta 前完成 |
| Cloudreve 环境 | 至少一个可控 Community 实例；Pro 能力只在有合法环境时纳入矩阵 |
| Provider 环境 | 至少 Local/Remote 和一个对象存储；未取得环境的 Provider 标记为 unverified |
| 安全条件 | 测试 token、签名 URL 和真实文件内容不得进入仓库或 CI 日志 |

## 4. 范围与非范围

### 4.1 本阶段范围

- 工程骨架、Target、entitlement 和最小 FFI；
- OAuth/site ping/账号身份/remote root identity 的协议探测；
- 静态与并发分页、内容版本、条件写、创建后置验证；
- 单 Domain 枚举、完整 `fetchContents`、最小 `modifyItem`；
- callback replay、`.workingSet`、`NSFileProviderDomainState`、materialized/pending set 行为；
- trash、`excludedFromSync`、Domain removal、copy/move-out 和目录环行为实验；
- upload session、分片重放、completion 查询和 refresh token 轮换探测；
- 能力矩阵、风险台账、Spike 结论和阶段门禁脚本。

### 4.2 本阶段非范围

- 生产级多 Domain 管理；
- 完整持久化 schema 和 migration；
- 完整上传 Provider 实现；
- 菜单栏、设置、冲突中心和诊断 UI；
- 11 种语言、缩略图、排除规则产品化；
- 签名、公证、DMG 和升级发布。

## 5. 需求追踪

本阶段只验证需求成立所需的系统和服务端前提，不声明对应产品需求已完整交付。

| 需求/验收 | 本阶段证明内容 |
|---|---|
| FR-AUTH-001 至 FR-AUTH-008 | HTTPS、site ping、OAuth PKCE、账号身份和刷新语义可实现 |
| FR-DOM-003、FR-DOM-011、FR-DOM-014、FR-DOM-015 | 稳定 root identity、范围重叠和合法 Domain identifier |
| FR-FP-001 至 FR-FP-005、FR-FP-011、FR-FP-016 | 枚举、dataless、完整下载、eviction、working/materialized set |
| FR-UP-001 至 FR-UP-006、FR-UP-013、FR-UP-014、FR-UP-018 至 FR-UP-020 | 最小写路径、callback replay、复合字段、复制和目录环 |
| FR-EVT-003、FR-EVT-004、FR-EVT-012、FR-EVT-013 | anchor、working-set signal、signal outbox 和本地回声模型 |
| FR-IGN-003、FR-IGN-007 | `excludedFromSync -> deleteItem` 系统握手 |
| FR-LIFE-004、FR-LIFE-008、FR-LIFE-012 | Extension 强杀、reimport 和 callback 生命周期 |
| AC-001、AC-002、AC-003、AC-005、AC-013、AC-014 | 验证关键子场景，不在本阶段宣称完整通过 |

## 6. 详细实施方案

### 6.1 工作包 P0-W1：工程与签名骨架

| 项目 | 实施内容 |
|---|---|
| 目标路径 | `NimbusSync.xcodeproj`、`Apps/NimbusSync/`、`Extensions/NimbusSyncFileProvider/`、`Extensions/NimbusSyncFileProviderUI/`、`Config/` |
| Xcode Target | 建立 App、Replicated File Provider、File Provider UI、Swift test 和 aggregate build target |
| Entitlement | 配置 App Sandbox、outgoing network、App Group、Keychain Group、File Provider document group；Debug testing entitlement 与 Release 隔离 |
| Domain | 使用 `crd-<uuid>`；显式设置 `supportsSyncingTrash = false`；不支持 external-volume/known-folder |
| 最小 UI | App 只提供添加/移除测试 Domain、打开 Finder、展示最后错误，不做正式视觉设计 |
| 自动化 | 增加 `Scripts/phase-gates/phase-0.sh`，串联 Rust、Swift、contract 和构建检查 |

完成证据：三个产品 Target 可签名运行，Finder 可发现 Extension，Release 配置不含 testing entitlement。

### 6.2 工作包 P0-W2：Rust workspace 与窄 FFI

| 目标路径 | 实施内容 |
|---|---|
| `Rust/crates/cloudreve-protocol` | 迁移 site ping、OAuth、文件 info/list、content URL、SSE DTO 和结构化错误 |
| `Rust/crates/cloudreve-core` | 提供 `validateSite`、`resolveRoot`、`listChildren`、`getItem`、`fetchContents`、最小 update 接口 |
| `Rust/crates/cloudreve-ffi` | 只暴露版本化 DTO、async 方法、受控 FD 和错误，不暴露 Tokio/trait object/path |
| `Scripts/xtask` | 构建 arm64/x86_64 静态库、UniFFI binding 和 XCFramework；生成 checksum |

实现约束：Spike 可使用临时内存 repository，但所有 ID、version 和错误 DTO 必须按最终接口设计，避免阶段 1 再破坏 FFI。

### 6.3 工作包 P0-W3：Cloudreve 协议探测器

在 `Tests/ContractTests/` 建立可参数化测试工具，测试输入来自环境变量或本机 Keychain，不提交凭据。

| 门禁 | 测试方法 | 通过判定 | 失败行为 |
|---|---|---|---|
| 账号身份 | token 后查询账号，多次刷新/重登 | ID 稳定且可校验原账号 | 禁止原 Domain 原地重授权 |
| 稳定实体 ID | create 后 rename/move/restore | ID 不变，或有可靠旧新映射 | 对应写能力只读 |
| 稳定根身份 | 绑定子目录后 rename/move/delete/同路径重建 | 可按 ID 找回当前 URI并识别替换 | 不支持可移动子目录 Domain |
| 完整分页 | 10,000 item，分页时并发 create/delete/rename | 无重无漏，或可构建稳定客户端快照 | 不支持该服务端版本 |
| 内容版本 | content change 与 metadata-only change | ETag/primary entity 行为可复现 | 不作为 contentVersion/条件写 |
| 条件内容写 | stale `previous` 更新 | 原子拒绝旧版本 | 禁用覆盖修改 |
| 幂等创建 | 注入响应丢失并重放 | 不重复，或可唯一查询后置条件 | 禁用对应 create |
| metadata mutation | rename/move/delete 竞态 | 有原子条件或等价幂等契约 | 禁用对应 mutation |
| trash/delete | soft delete、trash list、restore、permanent、recursive | 全链路可复现且部分失败可辨认 | `supportsSyncingTrash=false` |
| SSE | subscribed/resumed/reconnect-required、断流、未知事件 | 状态语义可复现 | event degraded + reconciliation |
| refresh rotation | 并发刷新、响应丢失、旧 token 重放 | 轮换与恢复语义明确 | unknown 时要求重新授权 |
| TLS/代理 | 系统根、私有 CA、系统代理、跨 origin redirect | 不泄露 Bearer，信任行为符合预期 | 不声明支持该环境 |

每项输出机器可读 `capability-report.json` 和人工结论 `capability-report.md`。报告只保存版本、布尔能力、耗时和脱敏错误。

### 6.4 工作包 P0-W4：Provider 上传恢复探测

对 Local/Remote、OSS、COS、S3、KS3、OBS、OneDrive、Qiniu、Upyun 和 Load Balance 建立同一测试协议：

| 场景 | 注入点 | 证据 |
|---|---|---|
| session 创建 | 响应前后断连 | session 是否可查询/复用 |
| 分片重放 | part 成功但本地未记录 | 重传是否幂等，ETag 是否稳定 |
| completion | Provider 完成后 callback 前断连 | 最终对象能否按稳定条件查询 |
| 进程终止 | 完成若干 part 后强杀 | 新进程能否从已完成 part 继续 |
| 源变化 | 相同路径换内容 | fingerprint 不一致时旧 part 不混入 |
| 空文件 | 0 字节 create/update | 是否有独立可靠路径 |
| 加密 | 非 16-byte 对齐分片 | AES-CTR counter 与全文件 offset 一致 |
| Load Balance | 多次选择子策略 | 能取得真实子 Provider，未知值 fail closed |

未完成真实测试的 Provider 标为 `unverified`，不得因为参考实现有代码就进入 1.0 可写矩阵。

### 6.5 工作包 P0-W5：File Provider 读路径 Spike

| 目标路径 | 实施内容 |
|---|---|
| `FileProviderExtension.swift` | 初始化单 Domain、返回 root item、创建目录和 working-set enumerator |
| `FileProviderItem.swift` | 映射 opaque ID、parent、filename、`contentType`、size、time、capabilities 和 version |
| `Enumerator.swift` | 支持分页、固定排序、page token、current anchor 和 anchor expiry |
| `ContentCoordinator.swift` | 在 `temporaryDirectoryURL` 流式完整下载，校验长度/版本，响应 cancellation |
| `DomainStateProjection.swift` | 持久 `NSFileProviderDomainVersion`，返回最小非敏感 `userInfo` |

必须实测：空目录、两层目录、dataless 文件、0 字节文件、完整下载、取消、eviction、同名大小写碰撞和 root filename。

### 6.6 工作包 P0-W6：File Provider 写路径与生命周期 Spike

本工作包只做协议验证，不形成最终 uploader：

1. 使用系统 template ID 关联 create replay；
2. 用 `baseVersion` 验证最小 content modify；
3. 验证 filename + contents、parent + contents 的 `stillPendingFields` 行为；
4. 验证 copy-in、copy-out、同 Domain copy、跨 Domain copy/move-out；
5. 验证 move 前父链检查可阻止远端并发形成目录环；
6. 验证 trash 开/关两种 Domain 行为；
7. 验证本机特殊文件与规则命中时 `excludedFromSync -> deleteItem`，精确 intent 不吞用户永久删除；
8. 验证 `mayAlreadyExist`、deletion-conflicted、root reimport 和 `importDidFinish`；
9. 在 callback 中止后确认旧 URL 失效，新 callback 提供新 URL；
10. 验证 `PreserveDirtyUserData` 返回位置和 `waitForChanges` 局限。

### 6.7 工作包 P0-W7：变更交付与故障注入

建立最小本地 journal、signal outbox 和回声匹配器，证明以下时序：

```text
remote/SSE change
  -> transaction(item + journal + outbox + domainVersion)
  -> signal .workingSet
  -> enumerateChanges
  -> acknowledge outbox revision
```

必须注入：journal commit 后终止、signal completion 前终止、signal 返回错误、重复 SSE、本地 mutation 的匹配/不匹配回声、anchor 过期和 Extension 强杀。匹配的本地回声不得二次发布，真实差异必须发布。

### 6.8 工作包 P0-W8：决策冻结

阶段结束时更新基线文档，而不是把不符合事实的假设留给实现：

| 决策 | 输出 |
|---|---|
| 最低 macOS | 明确版本及排除原因 |
| CPU 架构 | universal2 是否保留 |
| Cloudreve 版本 | Community/Pro 支持矩阵 |
| 可写能力 | create/update/move/trash/delete 的启用条件 |
| Provider | read-only、write、resumable、unsupported 四态矩阵 |
| root identity | 子目录 Domain 是否可安全跟随移动 |
| refresh token | 无交互恢复或必须重新授权的条件 |
| 分发 | Developer ID 站外分发是否保持 |

## 7. 执行顺序与依赖

| 顺序 | 工作包 | 依赖 | 可并行项 |
|---:|---|---|---|
| 1 | P0-W1 工程骨架 | 无 | P0-W3 环境准备 |
| 2 | P0-W2 Rust/FFI | W1 的构建约定 | P0-W3 协议探测 |
| 3 | P0-W3 协议门禁 | 测试实例 | W4 Provider 探测 |
| 4 | P0-W5 读路径 Spike | W1、W2、稳定 list/info | W4 |
| 5 | P0-W6 写/生命周期 Spike | W5、条件写/创建初步结论 | 无 |
| 6 | P0-W7 变更交付 | W5、W6 | 门禁补测 |
| 7 | P0-W8 决策冻结 | W3 至 W7 证据 | 无 |

## 8. 验收标准

### 8.1 自动化门禁

- `cargo test --workspace` 通过；
- Swift unit tests 和最小 File Provider integration tests 通过；
- `cargo xtask build-xcframework` 对目标架构成功且 binding diff 干净；
- `Scripts/phase-gates/phase-0.sh` 一条命令生成门禁汇总；
- capability report 不含 token、完整 signed URL、文件内容或真实敏感路径；
- Release 配置扫描确认无 testing entitlement、HTTP 例外和关闭 TLS 验证选项。

### 8.2 真实 Finder 验收

1. 单 Domain 可注册、打开、移除并重新添加；
2. 根和两层子目录可分页枚举，dataless 文件可完整下载并 eviction；
3. 最小内容修改使用条件版本，stale write 不静默覆盖；
4. create callback 重放不产生重复远端对象；
5. 强杀 Extension 后由新 callback/新 URL 恢复，不访问旧 URL；
6. `.workingSet` 是唯一 signal 目标，远端变化可由 change enumeration 交付；
7. journal commit 与 signal 之间终止后能从 outbox 补发；
8. 本地 mutation 的 SSE 回声不形成重复 change；
9. `excludedFromSync` 清理和用户永久删除可区分；
10. root rename/move/delete/replace 不会误绑定新对象。

### 8.3 协议门禁验收

- 第 19 节所有门禁均有 `verified`、`unsupported` 或 `unverified` 结论，不允许空白；
- `unsupported` 有明确产品降级，`unverified` 不进入发布支持矩阵；
- 条件 metadata mutation、幂等创建或稳定 identity 任一不成立时，相关写能力默认关闭；
- 所有决定已同步回 PRD、架构和 capability snapshot 定义。

## 9. 阶段交付物

| 交付物 | 位置/形式 |
|---|---|
| 可运行 Spike | Xcode 三 Target + 最小 Rust XCFramework |
| Contract tests | `Tests/ContractTests/` |
| File Provider tests | `Tests/FileProviderTests/` |
| 聚合门禁 | `Scripts/phase-gates/phase-0.sh` |
| 能力矩阵 | `Artifacts/PhaseGates/phase-0/capability-report.{json,md}`，CI artifact |
| 故障注入报告 | `Artifacts/PhaseGates/phase-0/fault-injection.md`，CI artifact |
| 阶段结论 | `docs/reports/phase-0-exit.md` |

## 10. 阻断条件与退出规则

### 10.1 No-Go

- 无法获得 File Provider entitlement 或签名后的真实 Finder 环境；
- Cloudreve 无法提供稳定 item/root identity，且没有可靠映射；
- 内容条件写和创建幂等均无法成立，导致基础双向写不安全；
- callback replay 或系统临时内容 URL 行为与恢复模型冲突；
- 任何 Spike 路径会静默覆盖、误删或泄露凭据。

### 10.2 Conditional Go

- 某些 Provider 不支持恢复：从 1.0 可写矩阵移除，不阻塞 Local/Remote 等已验证 Provider；
- trash 不完整：保持 `supportsSyncingTrash=false` 并隐藏删除能力；
- SSE 恢复不可靠：进入 event degraded，并以 reconciliation 保证正确性；
- 子目录 root 不能按 ID 跟随：仅支持稳定根级范围或只读预览。

### 10.3 完成定义

只有同时满足以下条件才进入阶段 1：

1. 真实 Finder Spike 达标；
2. 协议能力矩阵冻结；
3. 所有 unsupported 能力都有 fail-closed 产品行为；
4. 阶段门禁脚本在干净环境可复现；
5. PRD/架构已按实测结果同步；
6. 阶段退出报告由产品、Swift、Rust 和测试负责人共同确认。
