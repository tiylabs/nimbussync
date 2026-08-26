# 阶段 3 实施计划：SSE、变更交付与最终一致性

> 阶段编号：Phase 3
> 阶段状态：Conditional Go（本地事件/一致性门禁完成；真实 SSE/Finder/长稳环境证据待补）
> 目标版本：0.5 Beta 一致性闭环
> 前序阶段：[阶段 2：写路径、上传恢复与冲突安全](./05-phase-2-write-path-upload-recovery.md)
> 后续阶段：[阶段 4：1.0 产品化与发布](./07-phase-4-product-release.md)

## 1. 需求背景

阶段 2 已能正确处理系统主动发起的读写请求，但主应用退出、SSE 断流、服务端重启、事件遗漏或本地数据库恢复后，Finder 与远端仍可能长期不一致。Cloudreve SSE 当前只提供变化线索，没有可依赖的全局单调事件序号，因此不能把“连接正常”或“收到 resumed”视为同步完成。

本阶段建立完整的远端变化闭环：SSE 提示、metadata re-fetch、provider-side journal、持久 signal outbox、working-set change enumeration、generation reconciliation 和状态归并。目标不是网络级 exactly-once，而是可恢复的至少一次执行与幂等收敛。

## 2. 阶段目标

1. 为每个启用 Domain 建立主应用 SSE supervisor 和稳定 client ID。
2. 实现严格 SSE framing、状态事件、退避、断流和事件缺口处理。
3. 实现 provider-side change journal、anchor、compaction 和持久 signal outbox 的完整交付协议。
4. 实现本地 mutation 与 SSE 回声去重，避免重复下载和同步循环。
5. 实现 working/materialized scope 与全 Domain generation reconciliation。
6. 实现 stable root identity 持续校验、trash 双树校准和安全 tombstone。
7. 实现 app-not-running、event-degraded、offline、reconciling 和 healthy 的可靠状态归并。
8. 实现多 Domain 公平调度、睡眠唤醒、网络恢复和 `SMAppService.mainApp` 登录启动。
9. 在事件丢失、进程终止、anchor 过期和数据库恢复后自动收敛。

## 3. 前序状态

### 3.1 必须已完成

- 阶段 2 的写路径、operation saga、upload recovery、conflict 和安全删除已通过；
- 所有本地 mutation 都能返回稳定最终 item/version；
- provider-side journal 与本地 operation 审计已分离；
- signal outbox、Domain version、materialized/pending set schema 已存在；
- capability snapshot 能表达 SSE、trash、root identity 和 Provider 能力；
- 多 Domain 读写不依赖主应用作为请求代理。

### 3.2 本阶段开始时允许存在

- 远端变化主要依赖用户重新进入 dataless 目录或手工检查；
- journal/outbox 已有基础测试，但没有长期 SSE producer；
- reconciliation 可只有单目录原型；
- UI 只显示粗粒度状态，没有正式通知和诊断页。

## 4. 范围与非范围

### 4.1 本阶段范围

- EventCoordinator、SSE supervisor、parser 和 reconnect policy；
- 事件 metadata enrichment、范围校验、去重和本地写回声合并；
- journal/anchor/compaction/outbox/Domain version 完整实现；
- materialized/pending set refresh 和 working-set membership；
- generation reconciliation、trash scan、tombstone 安全和恢复；
- stable root 持续验证与 scope conflict；
- heartbeat、状态 reducer、网络/睡眠/低电量调度；
- 多 Domain 并发预算和公平性；
- 登录启动和主应用退出降级语义；
- 事件与一致性的压力、长稳和故障注入。

### 4.2 本阶段非范围

- 完整设置、冲突中心和任务控制 UI；
- Finder custom action、thumbnail、正式 decoration；
- 本机排除规则编辑和批量预览；
- 11 种语言收尾、诊断包、签名、公证和 DMG；
- 自动更新和 partial fetch。

## 5. 需求追踪

| 需求/验收 | 本阶段交付范围 |
|---|---|
| FR-EVT-001 至 FR-EVT-013 | 全部远端事件、一致性和变更交付需求 |
| FR-FP-011、FR-FP-014、FR-FP-015 | working/materialized set、退出降级和权限撤销 |
| FR-DOM-003、FR-DOM-011、FR-DOM-014 | stable root 和动态 scope overlap |
| FR-TSK-006、FR-TSK-007、FR-TSK-010 | 需处理事项、状态不误报、pending projection |
| FR-SET-001 | `SMAppService.mainApp` 登录启动 |
| FR-LIFE-001 至 FR-LIFE-005、FR-LIFE-008、FR-LIFE-009、FR-LIFE-011、FR-LIFE-012 | App/Extension/OS 生命周期和恢复 |
| AC-004、AC-011 | 本阶段完整验收 |
| AC-003 | 补齐 Web 端变化自动传播到 Finder，与阶段 2 合并后技术链路完整 |
| AC-007、AC-010、AC-012、AC-014 | 完成事件/认证/生命周期/root consistency 子场景；最终用户文案在阶段 4 验收 |

## 6. 详细实施方案

### 6.1 工作包 P3-W1：EventCoordinator 与 SSE supervisor

在 `Packages/NimbusSyncEventCoordinator/` 和 `Rust/crates/cloudreve-protocol/` 实现：

| 组件 | 职责 |
|---|---|
| `EventCoordinator` | 每 Domain supervisor、生命周期、heartbeat、调度公平性 |
| `SSEClient` | 建连、认证、client ID、stream cancellation |
| `SSEParser` | CRLF/LF、comment、multi-line data、event/data framing、buffer limit |
| `ReconnectPolicy` | full jitter，1 秒起步、60 秒上限、持续失败 5 分钟探测 |
| `EventEnricher` | 按 remote ID/info/list 取得完整 metadata |
| `EventScopeGuard` | 验证 stable root 和授权范围，越界只计数 |

状态处理：

```text
resumed             -> 继续消费，但不证明无缺口
subscribed          -> 启动 reconciliation
reconnect-required  -> 重连 + reconciliation
unknown/malformed   -> event_degraded + reconciliation
stream ended/error  -> event_degraded + backoff + reconciliation
keep-alive          -> 更新连接活性，不更新同步完成时间
```

### 6.2 工作包 P3-W2：事件归一化与 metadata enrichment

SSE payload 仅作为 hint：

1. 验证 event type、file ID、from/to 和 Domain scope；
2. create/modify/rename 通过 info 或稳定父目录快照读取当前 metadata；
3. delete 同时查询普通树和 trash，区分 soft delete 与 permanent absence；
4. 将 remote ID 映射到 stable item UUID；
5. 计算 content/metadata version 和真实 old/new parent；
6. 在短事务中 upsert item、journal、outbox、Domain version；
7. 不把 SSE 原始 message、URI 或 signed URL写入默认日志。

事件无法 enrichment 时不猜测 delete/move，记录待校准 scope 并保持 degraded。

### 6.3 工作包 P3-W3：本地写回声去重

回声匹配使用多证据，而不是只比较路径：

| 证据 | 用途 |
|---|---|
| remote entity ID | 关联同一服务端对象 |
| active/committed operation | 确认客户端近期写入 |
| target parent/name/trash state | 验证 metadata 后置条件 |
| final content/metadata version | 区分完全匹配与服务端额外变化 |
| completion time/window | 仅辅助，不单独决定匹配 |

处理规则：

- 完全匹配：确认 echo watermark，不写 provider-visible journal；
- 部分不匹配：只为真实差异写 journal；
- 无法证明：按普通远端事件处理，不丢事件；
- duplicate/乱序：同 remote ID/version 幂等 upsert；
- delete echo：必须结合 normal/trash 后置状态，不能只看 path 消失。

### 6.4 工作包 P3-W4：Journal、Anchor 与 Signal Outbox

完整交付协议：

```text
provider-side change
  -> transaction(items + change_journal + signal_outbox + domainVersion)
  -> signal .workingSet
  -> system enumerateChanges(oldAnchor)
  -> deliver update/delete + newAnchor
  -> acknowledge signal revision
```

实现要求：

1. Anchor 编码 Domain、scope、epoch、sequence；
2. 不匹配/过旧 anchor 返回 `syncAnchorExpired`；
3. 按扫描 sequence 推进，即使当前 scope 过滤后为空；
4. 同批可压缩净变化，但不能跨 delete + recreate identity；
5. old/new parent 用于 container scope 过滤；
6. outbox 在 signal completion 成功后才确认；
7. App/Extension 启动、唤醒和 Darwin signal 都会 drain；
8. 软保留 7 天或 100,000 条覆盖更大者；
9. 硬上限 1,000,000 条或 256 MiB，超限压缩并更新 min valid sequence；
10. compaction 与活跃 enumerator/observer 完成时序有并发测试。

### 6.5 工作包 P3-W5：Working Set 与系统集合

| 集合 | 策略 |
|---|---|
| Materialized | 维护已落盘目录，远端变化时决定是否进入 working set |
| Pending | 合并本地 task，为 UI 和移除 preflight 提供补充证据 |
| Working set | materialized 目录直接子项、recent、active operation/conflict、pending、shared、trash 顶层 |

`materializedItemsDidChange` 和 `pendingItemsDidChange` 先持久化 refresh intent，在 callback 预算内增量推进 system anchor；主应用也订阅通知并接管未完成 refresh。materialized set 损坏时扩大 working set 并标 degraded，不能漏掉已落盘目录的远端变化。

### 6.6 工作包 P3-W6：Generation reconciliation

全量和 scope reconciliation 共用可恢复 state machine：

```text
prepared
  -> scanning_normal
  -> scanning_trash
  -> stabilizing
  -> committing_deletions
  -> completed
```

详细步骤：

1. 创建 run，记录起始 journal sequence 和 capability revision；
2. 校验 stable root ID/current URI；
3. 按目录广度优先分页，逐页 upsert `seen_generation`；
4. 启用 trash 时完整扫描 trash；
5. 新增/版本变化可逐页发布，删除必须等待完整扫描；
6. 未见且有 pending operation 的 item 转冲突/单项 verification；
7. normal 未见先查 trash；两侧完整未见才成为 tombstone candidate；
8. 回放扫描期间收到的 SSE，并复查受影响目录；
9. capability revision、分页稳定性或 root identity 变化时放弃删除阶段；
10. 最终事务提交 tombstone/journal/outbox/last success；
11. 失败保留旧有效 anchor 和差异证据，不显示 healthy；
12. 进程终止后从持久 cursor/phase 续跑或安全重启 generation。

### 6.7 工作包 P3-W7：Stable Root 与范围动态校验

每次全量 reconciliation、关键 mutation 和权限错误后执行 root check：

| 场景 | 行为 |
|---|---|
| 同 ID rename/move，仍在授权范围 | 更新 current URI、scope key，失效 path cache |
| 移入另一个可写 Domain 范围 | 两个受影响 Domain 均进入 `scope_conflict`，冻结写入 |
| 移出授权范围 | `root_unavailable`，停止下载新内容和 mutation |
| root 删除 | 不按旧路径寻找替代，保留本地状态并提示处理 |
| 原路径创建同名新 ID | 视为新对象，不接管 |
| 权限恢复 | 重新验证 account/root/scope 后 reconciliation，再恢复 healthy |

### 6.8 工作包 P3-W8：调度、网络和生命周期

| 事件 | 处理 |
|---|---|
| App launch | 扫描未完成 action/run/outbox，reconcile 后再建 SSE |
| App quit | 停止 SSE/周期任务，写 `app_not_running`；Extension 请求仍可工作 |
| Login | `SMAppService.mainApp` 状态与设置同步 |
| Sleep | 取消或持久化非关键网络任务，保留 operation/run cursor |
| Wake | 网络恢复、outbox drain、SSE 重连、受控 reconciliation |
| Network offline | 用户请求快速返回可重试错误，后台退避，不忙轮询 |
| Low power | 延后非紧急全量扫描，不延后用户正在等待的读写 |
| Server restart | SSE degraded，GET 探测，恢复后 reconciliation |

调度默认：每 Domain 1 个 SSE、1 个 reconciliation；全进程最多 2 个 Domain 同时校准。用户 fetch/mutation 高于后台 metadata 和全量扫描。

### 6.9 工作包 P3-W9：周期策略与状态归并

默认周期经配置常量管理并带抖动：

- 主应用在线时每 6 小时校准 working/materialized scope；
- 每 24 小时在空闲、非低电量时做全 Domain scan；
- SSE `subscribed`、reconnect-required、未知断流、anchor expiry、数据库恢复和用户手动检查立即触发；
- 同一 Domain 触发合并，不并发跑多个 generation；
- 高频变化目录允许短时间 debounce，但删除安全不被绕过。

状态 reducer 优先级：

```text
auth_expired
  > root_unavailable / scope_conflict
  > conflict / permanent_error
  > offline
  > reconciling
  > syncing
  > event_degraded / app_not_running
  > healthy
```

Healthy 必须同时满足有效 credential、root/scope、anchor、最近成功校准、无待处理错误/写入且主应用事件通道正常。

### 6.10 工作包 P3-W10：长稳、压力与可观测性

增加本地指标：SSE 最后事件/重连数、reconcile 耗时/扫描数/差异、journal min/max/size、outbox age/attempt、SQLite busy/WAL、root check 和 echo match 结果。

长稳场景：

1. 5 Domain 连续运行 72 小时；
2. 每分钟混合远端 create/modify/move/delete；
3. 周期 sleep/wake、网络切换和服务端重启；
4. 每小时随机终止 App 或 Extension；
5. 10,000 item 事件缺口后全量收敛；
6. journal 接近软/硬上限时 compaction；
7. 主应用退出 2 小时后恢复；
8. root move、permission revoke/restore 和 scope overlap。

## 7. 执行顺序与依赖

| 顺序 | 工作包 | 依赖 | 可并行项 |
|---:|---|---|---|
| 1 | W1 SSE supervisor | Phase 2 protocol/auth | W4 journal hardening |
| 2 | W2 Enrichment | W1、item repository | W3 echo matcher |
| 3 | W3 Echo | operation final state | W5 system sets |
| 4 | W4 Journal/outbox | Phase 1 schema | W5 |
| 5 | W6 Reconciliation | W2、W4、snapshot | W7 root checks |
| 6 | W7 Root/scope | W6、scope guard | W8 lifecycle |
| 7 | W8/W9 调度与状态 | W1、W6 | W10 metrics |
| 8 | 长稳与门禁 | 全部 | 无 |

## 8. 验收标准

### 8.1 端到端验收

- AC-004 全部通过；
- AC-011 全部通过；
- AC-014 的 stable root、权限撤销和 scope conflict 技术链路通过；最终 UI 文案在阶段 4 验收；
- AC-003 的 Web 端远端 create/modify/move/delete/trash/restore 能自动到达 Finder；
- AC-007 的 auth expiry/recovery 不丢 operation；
- AC-010 的 App/Extension kill、sleep/wake、restart 和 DB 恢复最终收敛；
- AC-012 的 schema fencing 和卸载前状态检查不被后台旧进程破坏。

### 8.2 正确性验收

1. SSE 永远不作为删除和“已同步”的唯一证据；
2. 完整分页失败时不生成 tombstone；
3. journal commit 后、signal 前终止仍能补发；
4. 匹配本地回声不产生二次 working-set change；
5. anchor 过期明确返回错误并重新枚举；
6. 主应用退出期间不误报 healthy；
7. materialized 目录的远端变化在主应用运行时由 working set 更新；
8. root replace/越权/重叠不会继续写入；
9. 任何 unknown identity 都不执行破坏性操作；
10. journal compaction 不让有效 anchor 静默跳过变化。

### 8.3 性能与能耗验收

| 指标 | 阶段门槛 |
|---|---:|
| 正常 SSE 远端变化可见 | p95 不高于 5 秒 |
| 5 Domain SSE | 空闲无高频轮询，内存/CPU 稳定 |
| 10,000 item 缺口恢复 | 有界内存并最终一致 |
| Journal scan | 分页，无单次全表加载 |
| Reconciliation | 用户 fetch/mutation 不被后台扫描饿死 |
| Sleep | 进入睡眠后无持续网络或 busy loop |

### 8.4 故障注入验收

| 注入 | 必须结果 |
|---|---|
| SSE duplicate/乱序/未知事件 | 幂等或 degraded + reconcile |
| SSE 断流但 resumed | 不盲信恢复，按门禁决定校准 |
| 最后一页扫描前失败 | 不生成删除，保留旧 anchor |
| 扫描期间能力变化 | 当前 run 作废，不提交破坏性结果 |
| journal commit 后 kill | outbox 重启补发 |
| signal 成功但本地 ack 前 kill | 允许重复 signal，不丢 change |
| Compaction 与旧 anchor | 返回 anchor expired |
| App 退出后 Web 修改 | 明确 degraded；App 恢复后先校准再 healthy |
| root 同路径替换 | 不接管新 ID |

### 8.5 自动化门禁

`Scripts/phase-gates/phase-3.sh` 至少运行：

```text
SSE parser/property tests
event enrichment and echo tests
journal/anchor/outbox crash tests
reconciliation generation tests
materialized/pending set integration tests
multi-domain scheduler tests
AC-004/011/014 automated subset
72-hour long-run profile or latest approved report
```

## 9. 阶段交付物

| 交付物 | 说明 |
|---|---|
| EventCoordinator v1 | SSE supervisor、heartbeat、网络/睡眠生命周期 |
| Change delivery v1 | journal、anchor、outbox、Domain version、echo merge |
| Reconciliation v1 | scope/full scan、trash、tombstone、stable root |
| State projection v1 | Domain reducer、pending/materialized/working set |
| 长稳报告 | 72 小时、多 Domain、kill/network/server restart 数据 |
| 自动化门禁 | `Scripts/phase-gates/phase-3.sh` |
| 阶段报告 | `docs/reports/phase-3-exit.md` |

## 10. 阻断条件与完成定义

### 10.1 阻断条件

- SSE 丢失后无法自动 reconciliation；
- 不完整扫描可能生成批量删除；
- journal/outbox 任一崩溃窗口会永久漏通知；
- 本地写回声可能触发重复下载或同步循环；
- 主应用退出后仍显示 healthy；
- root 被替换、越权或形成范围重叠时仍允许写入；
- 多 Domain 调度会饿死用户请求或导致持续高能耗；
- anchor compaction 会静默跳过变化。

### 10.2 完成定义

阶段 3 完成必须同时满足：

1. AC-004、AC-011 完整通过，AC-014 技术链路通过；
2. 事件缺失、断网、服务端重启、App/Extension kill 后可自动收敛；
3. 72 小时长稳无同步循环、无不可解释 journal 增长、无数据损坏；
4. 状态 reducer 不误报 healthy；
5. 所有破坏性 reconciliation 都依赖完整快照和稳定身份；
6. 阶段 4 只需消费稳定 projection 和 service，不重写一致性核心。
