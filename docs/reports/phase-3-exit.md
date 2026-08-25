# Phase 3 Exit Report

> 状态：Conditional Go
> 日期：2026-08-25
> 依据：`docs/06-phase-3-events-consistency.md`

## 1. 结论

Phase 3 的本地一致性闭环已实现：SSE parser/supervisor、重连和 reconciliation trigger、事件 scope guard/enrichment interface、本地写回声多证据去重、journal/anchor/outbox drain、materialized/pending set tracker、generation reconciliation、stable root checker、heartbeat/login item/scheduler、状态 reducer 和 metrics projection 均已通过本地测试与工程构建。

阶段结论为 **Conditional Go**。当前环境没有运行真实 Cloudreve SSE、跨进程 File Provider signal、系统 sleep/wake、5 Domain 72 小时长稳或 root move/permission revoke 真实矩阵，因此不得宣称 AC-003/004/011 已在真实 Finder 闭环通过。

## 2. Review 修复记录

1. `resumed` 不再直接恢复 healthy，而是触发 `resumed_unknown_gap` reconciliation。
2. unknown/malformed SSE 不再作为普通文件事件交付，进入 degraded + reconcile。
3. `EventSupervisor` 每 Domain 持有 stream 生命周期和 full-jitter backoff；stream ended/error 会重连并校准。
4. scope guard 拒绝 root ID、越权 URI、路径穿越和 malformed hint；拒绝事件只计数，不执行 destructive action。
5. echo matcher 同时校验 remote ID、parent、name、trash state 和 final version；完全匹配不写 provider-visible journal，真实差异才写 journal。
6. outbox 只有 `signalEnumerator(.workingSet)` 成功后才 ack；startup/wake/Darwin signal 可 drain。
7. reconciliation 在 normal/trash 两树完整、capability revision/root ID 未变化前不提交 tombstone。
8. heartbeat、`app_not_running`、6 小时 working / 24 小时 full reconcile scheduler 和最多 2 个并发 Domain slot 已持久化/建模。
9. metrics 记录 SSE、reconcile、journal/outbox、echo、scope rejection 的本地摘要，不写原始 SSE/URL/token。

## 3. 验证结果

| 验证 | 结果 |
|---|---|
| Rust consistency/transfer/store tests | 通过，11 + 7 + 3 tests |
| Swift consistency/event tests | 通过，24 tests |
| Xcode Debug build | 通过，三产品 Target及新增 package dependency graph |
| Secret/release static scan | Phase gate 已覆盖 |
| Real Cloudreve SSE/enrichment | 未验证 |
| Real File Provider signal/working-set | 未验证 |
| 72-hour long-run / sleep-wake / kill | 未验证 |

## 4. 阶段边界

- 没有 monotonic server event sequence 时，SSE 只作为 hint，不作为删除或 healthy 证据。
- 主应用退出期间只允许 Extension 做有界 callback 工作，不能承诺主动 materialized-directory freshness。
- Provider-visible journal 的 destructive reconciliation 必须等待完整快照；anchor 过期必须重新枚举。
- Phase 4 只能消费这些稳定 projection/service，不能再重写一致性核心。

