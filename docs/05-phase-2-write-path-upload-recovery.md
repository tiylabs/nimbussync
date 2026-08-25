# 阶段 2 实施计划：写路径、上传恢复与冲突安全

> 阶段编号：Phase 2
> 阶段状态：Conditional Go（本地 operation/uploader/conflict/removal 门禁完成；真实 Cloudreve/Provider/Finder 写入证据待补）
> 目标版本：0.5 Beta 写能力
> 前序阶段：[阶段 1：持久化、认证与读路径](./04-phase-1-persistence-read-path.md)
> 后续阶段：[阶段 3：SSE 与最终一致性](./06-phase-3-events-consistency.md)

## 1. 需求背景

File Provider 的写入不是普通 API 请求。系统可能重放 create/modify/delete callback，Extension 可能在任意网络步骤被终止，content URL 在 callback 返回后失效，Cloudreve 的部分 mutation 又以 URI 为路由且不一定支持原子条件参数。若只把 Finder 操作直接转成一次 HTTP 请求，会产生重复对象、旧版本覆盖、误删和“服务端成功但本地以为失败”等数据损坏。

本阶段以持久 operation saga 为唯一写入入口，完成 create、modify、move、rename、trash、restore、delete、Provider 上传恢复和三类冲突解决。所有能力以阶段 0 的 capability snapshot 为门禁，不允许用前置查询冒充服务端原子条件。

## 2. 阶段目标

1. 实现所有 File Provider mutation callback 的持久、幂等、可取消执行。
2. 实现发布矩阵内 Provider 的流式上传、分片 checkpoint 和跨 Extension 生命周期恢复。
3. 实现稳定 route resolver、expected version、后置条件验证和 unknown outcome 收敛。
4. 实现 Finder create/modify/move/rename/copy/trash/restore/permanent delete。
5. 实现字段支持矩阵、特殊文件排除和 `excludedFromSync` 清理隔离。
6. 实现内容、名称、删除、移动和身份冲突的持久模型及三种 P0 解决动作。
7. 实现有 dirty 数据时的安全 Domain 移除，不调用远端 delete。
8. 在进程终止、网络中断、响应丢失和连续编辑下不丢数据、不重复写入。

## 3. 前序状态

### 3.1 必须已完成

- 阶段 1 的 Store v1、Auth v1、Domain provisioning 和读路径已通过门禁；
- item/root identity、route、contentVersion 和 metadataVersion 已稳定；
- Keychain/App Group、schema fencing、backup/repair 和 signal outbox 已可用；
- 支持矩阵明确每个 Cloudreve 版本和 Provider 的可写能力；
- 未验证的 create/mutation/trash/Provider 默认关闭。

### 3.2 本阶段开始时的系统能力

| 已有能力 | 状态 |
|---|---|
| 多 Domain | 可注册、枚举、下载、移除无 dirty 的 Domain |
| 认证 | OAuth、刷新、重新授权、跨进程互斥 |
| Store | item/snapshot/journal/outbox/task 基础 schema |
| Finder | dataless、完整下载、eviction |
| 写路径 | 只有 Phase 0 Spike，不可直接视为生产能力 |

## 4. 范围与非范围

### 4.1 本阶段范围

- operation/replay/lease/source-generation 状态机；
- 文件夹和文件 create；
- 内容 modify、rename、move 和复合字段；
- Finder copy-in/copy-out/跨 Domain move 语义；
- trash、restore、permanent/recursive delete；
- Provider 上传、加密、分片恢复、completion verification；
- 取消 attempt、失败重试 service 和任务进度；
- conflict store、三种解决动作；
- exclusion intent 和 unsupported local type；
- dirty data 安全 Domain 移除；
- 生产级错误映射和故障注入。

### 4.2 本阶段非范围

- 长期 SSE supervisor 和周期 reconciliation；
- 正式菜单栏任务控制、冲突中心视觉和通知；
- 缩略图、Finder 自定义 action、完整排除规则编辑 UI；
- 多语言完成度、签名、公证和发布渠道；
- partial content fetching。

## 5. 需求追踪

| 需求/验收 | 本阶段交付范围 |
|---|---|
| FR-UP-001 至 FR-UP-020 | 全部写路径和上传需求 |
| FR-CNF-001 至 FR-CNF-005 | P0 冲突检测、持久化和解决动作 |
| FR-DOM-007、FR-DOM-008、FR-DOM-012 | 有 dirty 数据时的安全移除 |
| FR-FP-009、FR-FP-012、FR-FP-013、FR-FP-015 | capability、特殊类型、metadata 和权限 |
| FR-IGN-003、FR-IGN-006、FR-IGN-007 | 本地排除握手和删除隔离 |
| FR-TSK-001、FR-TSK-002、FR-TSK-005、FR-TSK-008、FR-TSK-010 | 写任务 projection、取消和重试 service |
| FR-LIFE-004、FR-LIFE-008、FR-LIFE-011、FR-LIFE-012 | 强杀、重放、reimport 和损坏恢复 |
| AC-003 | 完成本地到远端的 create/modify/move/rename/trash/restore/delete；远端到 Finder 自动传播在阶段 3 闭环 |
| AC-005、AC-008 | 本阶段完整验收 |
| AC-006 | 完成冲突引擎、内容保护和三种 resolution service；正式冲突中心 UX 在阶段 4 完成 |
| AC-009、AC-010、AC-012、AC-013、AC-014 | 完成写路径相关子场景 |

## 6. 详细实施方案

### 6.1 工作包 P2-W1：Operation saga 与 replay matcher

完善 `operations`、`pending_creations`、`tasks`、`conflicts` 和 lease repository。

```text
queued
  -> preflight
  -> remote_submitted
  -> verifying
  -> committed

异常分支：
  -> retry_wait
  -> awaiting_source_replay
  -> conflict
  -> unknown_outcome
  -> permanently_failed
```

| 要素 | 设计 |
|---|---|
| create replay key | 系统 template item identifier |
| modify replay key | item UUID + baseVersion + normalized changedFields + source generation |
| delete replay key | item UUID + baseVersion + recursive + intent kind |
| Lease | DB compare-and-swap + owner/expiry；网络返回后再核验 generation |
| Result | committed 保存可重放最终 item/error；callback 丢失时直接重放 |
| Unknown outcome | 先查询 remote ID/目标状态，不盲目重发 |
| Serialization | 同一 item 只有一个 active mutation；后继编辑使用更高 source generation |

任何 operation 成功必须在 callback 返回前提交最终 metadata、operation/task 状态；额外 provider-side change 才写 journal/outbox。

### 6.2 工作包 P2-W2：Source FD、fingerprint 与 callback 生命周期

| 目标路径 | 实施内容 |
|---|---|
| `MutationCoordinator.swift` | callback 生命周期、`Progress`、completion exactly-once guard |
| `ContentSource.swift` | Swift 打开 source URL，`dup` FD 给 Rust，所有权清晰 |
| `ReplayMatcher.swift` | 新 callback URL 与旧 operation/source generation 关联 |
| `cloudreve-transfer` | 流式读取、分片哈希、取消检查、固定 buffer |

Fingerprint 使用 size、base version、首尾分段哈希和流式完整/逐分片 plaintext SHA-256。mtime/inode 只作诊断。URL、FD 和绝对临时路径不持久化；Extension 终止后 operation 进入 `awaiting_source_replay`，只有系统提供新 URL 才续跑。

### 6.3 工作包 P2-W3：Create 和空文件

文件夹 create：

1. 校验 parent identity、权限、名称和 collision；
2. 先持久化 template ID 到 item/operation 映射；
3. 使用服务端幂等键，或阶段 0 已验证的唯一后置条件；
4. 响应丢失时查询 parent + name + client metadata/remote ID；
5. 返回 provider 分配的稳定 `cri-` item ID。

文件 create：

- 0 字节走经门禁验证的直接 create/update；
- 非空文件建立 upload session；
- `mayAlreadyExist` 先匹配现有对象；无法证明时返回冲突或 nil，不重复创建；
- parent 不存在返回带 parent context 的 `noSuchItem`；
- filename collision 使用 existing item 构建系统错误。

### 6.4 工作包 P2-W4：Modify、rename、move 与字段策略

`modifyItem` 对 `changedFields` 做显式分组：

| 字段 | 策略 |
|---|---|
| contents + filename | 同一 saga，不能出现新扩展名配旧内容 |
| parent + filename | 目标 parent/name 条件校验后执行 move/rename |
| parent + contents | move 和 upload 同一逻辑 operation，分步时准确返回 pending fields |
| creation/modification date | 服务端最终值只读返回；不假装 round-trip 本地时间 |
| tag/favorite/xattr/flags/type-and-creator | 返回对应 `stillPendingFields`；全不支持时原样返回整组 |
| resource fork | 非空时保留 pending 并返回稳定 unsupported/cannot-synchronize |

每次 path-based mutation 在请求前按 remote ID 重新解析当前 URI；move 前读取最新远端父链，目标位于当前子树或父链不完整时进入 conflict，避免远端并发形成环。

### 6.5 工作包 P2-W5：Finder copy 和跨边界 move

| 场景 | 实现 |
|---|---|
| 普通目录 -> Domain | 由 create template 上传；不依赖普通目录 security-scoped bookmark |
| 同 Domain copy | 仍以 create callback 为事实源；可在证明语义一致时用服务端 copy 优化 |
| Domain A -> Domain B | B create 成功后，Finder 才可继续 A 的源侧删除 |
| Domain -> 普通目录 | 只通过系统读取/materialization，不主动删除远端 |
| 跨边界 move | 目标确认成功前不删除源；源 delete 失败时保留双份并提示，不回滚已成功目标为数据丢失 |

测试需覆盖大文件、目录树、取消、目标 quota、源权限变化和两个 Domain 属于同/不同实例。

### 6.6 工作包 P2-W6：Provider uploader 与恢复

| 目标模块 | 实施内容 |
|---|---|
| `upload_sessions` | remote session ref、secret ref、fingerprint、Provider、chunk size、expiry、state |
| `upload_parts` | part index、offset、length、plaintext hash、ETag、state、attempt |
| `SecretVault` | callback secret、key/IV、小型恢复凭据写 Keychain |
| `ProviderAdapter` | Local/Remote、OSS、COS、S3、KS3、OBS、OneDrive、Qiniu、Upyun 穷举 |

恢复规则：

1. 每个 part 成功后先持久化 ETag/hash，再调度后续；
2. 恢复时重读已完成 part 对应源区间并校验 plaintext hash；
3. 只上传 pending/failed part；
4. completion 可重试或查询，结果未知进入 verifying；
5. 只有 session 明确无效/过期或 source generation 变化才废弃；
6. signed URL 不无限持久化，未知 Provider 不回退 Local；
7. AES-CTR counter 从全文件绝对 offset 推导；
8. 每个 Provider 的写/续传/空文件能力由 capability snapshot 控制。

### 6.7 工作包 P2-W7：Trash、restore 与永久删除

| 操作 | 实现 |
|---|---|
| Finder trash | parent 改为 `.trashContainer`，映射 Cloudreve soft delete，保存原 parent |
| Trash 枚举 | 返回顶层 trashed item；trashed 目录后代不进 working set |
| Restore | 从 `.trashContainer` reparent，调用 restore 并验证目标 parent/name |
| Permanent delete | 只在 trash 中且 `.allowsDeleting` 时进入 `deleteItem` |
| Non-recursive dir | 非空返回 `directoryNotEmpty` |
| Recursive dir | 逐项记录结果，部分失败不标整树成功 |
| Already absent | 普通树和 trash 均确认不存在时幂等成功 |

Domain 只有在完整 trash contract 通过时设置 `supportsSyncingTrash=true`。否则不声明 `.allowsTrashing/.allowsDeleting`，不能把 Finder 普通删除降级为永久删除。

### 6.8 工作包 P2-W8：Exclusion intent 与特殊文件

本阶段实现底层安全机制，正式规则编辑 UI 延后至阶段 4。

| Intent kind | 来源 | 后续 `deleteItem` 行为 |
|---|---|---|
| `local_create` | 用户规则命中本地 create/modify | 精确匹配后只完成本地排除清理 |
| `unsupported_local_type` | symlink/socket/device/FIFO 等 | 保留本机对象，不触发远端写/删 |
| `remote_view_filter` | 已显示远端 item 被规则过滤 | 通过 working-set deletion 移出视图，不拦截真实用户永久删除 |

匹配必须包含 item/template ID、kind、rule revision 和 source generation。没有精确 intent 的 delete 不能进入本地清理分支。

### 6.9 工作包 P2-W9：冲突模型与解决动作

冲突类型：content version、name collision、delete-vs-modify、move-vs-move、identity ambiguous、unsupported name、partial mutation。

| 动作 | 实施约束 |
|---|---|
| 保留远端 | 二次确认；放弃本地 operation；返回最新 item 并触发 fetch |
| 覆盖远端 | 用户确认后读取最新 ETag；条件写；远端再次变化仍保持冲突 |
| 保留两个 | 生成唯一副本名，以新 create operation 上传本地内容 |

冲突记录保存 base/local/remote 摘要、pending item ID 和 source generation，不保存 callback URL 或完整内容。本地内容默认依赖系统 pending item；无法保证重放时必须让用户导出或禁用该流程。

### 6.10 工作包 P2-W10：取消、重试和错误映射

- App 取消写 `cancel_requested` 并发送 Darwin signal；
- 执行进程在网络 buffer、part 和 completion 前检查 generation；
- 取消仅结束当前 attempt，dirty change 仍为 pending；
- 重试清除可控 backoff，并使用 `signalErrorResolved` 让系统重新调度；
- File Provider 错误只使用 NSFileProvider/Cocoa domain；
- authentication、network、permission、quota、collision、conflict、unknown outcome、directory not empty 均有稳定映射；
- `cannotSynchronize` 视为需显式 signal 才重试的错误，不用于临时网络抖动。

### 6.11 工作包 P2-W11：安全 Domain 移除

实现完整 removal saga：

1. 持久化 `removal_preflight`，停止该 Domain 主应用侧主动工作；
2. 调用 `waitForChanges(below: .rootContainer)`；
3. 查询 operation/session/conflict/unknown outcome 和 pending set；
4. 任何不确定均按有 dirty 数据处理；
5. 正常产品路径使用 `PreserveDirtyUserData`；
6. 等系统 remove completion 后再删 Keychain/DB/temp/log；
7. 展示并可打开 preserved location；
8. 整条调用链用 mock/assert 证明无 Cloudreve delete API。

## 7. 执行顺序与依赖

| 顺序 | 工作包 | 依赖 | 可并行项 |
|---:|---|---|---|
| 1 | W1 Operation saga | Phase 1 store | W2 Source FD |
| 2 | W2 Source/replay | W1 DTO | W3 create |
| 3 | W3 Create | W1、W2、能力矩阵 | W6 Provider adapters |
| 4 | W4 Modify/move | W1、route resolver | W5 copy |
| 5 | W6 Uploader | W2、W3 | W7 trash |
| 6 | W7 Trash/delete | W1、删除 contract | W8 exclusion |
| 7 | W9 Conflict | W3 至 W7 | W10 task control |
| 8 | W11 Removal | operation/pending/conflict 完整 | 故障注入 |
| 9 | 集成门禁 | 全部 | 无 |

## 8. 验收标准

### 8.1 端到端验收

- AC-003 的本地到远端步骤全部通过；Web 端变化自动到达 Finder 延后阶段 3；
- AC-005 全部通过；
- AC-006 的三种冲突动作、二次版本校验、重启持久化和内容保护通过；正式 UI 验收延后阶段 4；
- AC-008 全部通过；
- AC-009 中 0 字节、超大文件、package/alias/symlink/hard link/resource fork/xattr 场景有明确结果；
- AC-010 中上传、rename、delete、Extension kill 和 SQLite 损坏路径通过；
- AC-013 中 `excludedFromSync -> deleteItem` 与永久删除竞争通过；
- AC-014 中写权限撤销和 root identity 异常时 mutation fail closed。

### 8.2 Provider 验收

每个发布矩阵 Provider 独立满足：

1. 新文件和覆盖上传；
2. 空文件能力与声明一致；
3. 部分 part 后强杀可恢复；
4. 相同 part 重放不破坏内容；
5. 源变化不会混用旧 part；
6. completion 响应丢失可验证结果；
7. secret 不进入 SQLite/日志；
8. 加密文件内容与服务端协议一致。

### 8.3 故障注入验收

| 注入点 | 必须结果 |
|---|---|
| operation commit 后、请求前 kill | 重放同 operation，不重复 create |
| 请求成功后、本地 commit 前 kill | 先 verification，不盲重发 |
| part 成功后、ETag 入库前 kill | Provider 幂等确认或安全查询 |
| upload 期间再次保存 | 旧 generation 不覆盖新内容 |
| callback 返回前取消 | 快速结束 attempt，dirty item 保留 |
| trash/restore/delete 超时 | 查询普通树和 trash 后收敛 |
| exclusion intent 与用户 delete 竞争 | 只有精确 intent 走本地清理，无远端误删 |
| Domain remove preflight 后新本地修改 | PreserveDirtyUserData 保留竞态产生的数据 |

### 8.4 自动化门禁

`Scripts/phase-gates/phase-2.sh` 至少包含：

```text
Rust operation/uploader unit and integration tests
Provider contract matrix
Swift mutation/replay/error-mapping tests
signed File Provider mutation tests
kill/replay fault suite
secret scan
AC-003/005/006/008 automated subset
```

## 9. 阶段交付物

| 交付物 | 说明 |
|---|---|
| Mutation v1 | create/modify/move/rename/trash/restore/delete adapters |
| Operation store | saga、lease、replay、source generation、unknown outcome |
| Transfer v1 | Provider adapters、session/part checkpoint、AES-CTR |
| Conflict v1 | 持久 conflict 和三种解决 service |
| Removal v1 | dirty data 安全移除和 preserved location |
| Provider 报告 | 每个 Provider 的 write/resume/zero-byte/crypto 证据 |
| 自动化门禁 | `Scripts/phase-gates/phase-2.sh` |
| 阶段报告 | `docs/reports/phase-2-exit.md` |

## 10. 阻断条件与完成定义

### 10.1 阻断条件

- callback 重放仍可能产生重复远端对象；
- 结果未知时只能盲目重试；
- 连续编辑可能被旧 upload completion 覆盖；
- 上传恢复依赖旧 content URL/FD；
- 普通 Finder 删除可能变成不可恢复远端永久删除；
- exclusion cleanup 可能进入远端 delete；
- Domain remove 可能丢 dirty data；
- 任一已声明支持 Provider 缺少真实 contract test。

### 10.2 完成定义

阶段 2 完成必须同时满足：

1. AC-005、AC-008 完整通过，AC-003 本地到远端链路和 AC-006 冲突引擎通过；
2. 所有可写能力均受 capability snapshot 控制；
3. kill/response-loss/source-change 故障套件通过；
4. 冲突至少保留一个可恢复版本；
5. 删除、排除、移除 Domain 三条调用链有独立测试并证明互不混淆；
6. 阶段报告列出每个 Provider 的支持级别和未关闭风险；
7. 阶段 3 可以只通过 journal/operation 接口接入 SSE，不修改写路径核心语义。
