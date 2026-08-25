# Phase 2 Exit Report

> 状态：Conditional Go
> 日期：2026-08-25
> 依据：`docs/05-phase-2-write-path-upload-recovery.md`

## 1. 结论

Phase 2 的写路径基础已完成并通过本地 Rust/Swift/Xcode 门禁：持久 operation replay、lease、source fingerprint、stale version rejection、create/modify/delete adapter、trash/restore 分支、exclusion intent、upload session/part checkpoint、AES-CTR absolute offset、冲突 resolution service 和 dirty-domain removal preflight 已实现。

结论为 **Conditional Go**。真实 Cloudreve mutation/conditional-write 语义、各 Provider 的 upload completion/resume、签名 Finder callback replay、resource fork/package/symlink 的实机行为尚未完成外部环境验证。未验证能力仍由 capability snapshot fail closed。

## 2. Review 修复记录

1. create replay 由 template identifier 派生稳定 local item/operation identity，committed outcome 可直接重放，不重复 create。
2. operation 使用 DB compare-and-swap lease、owner/expiry/attempt，callback 重放不依赖内存 task。
3. modify/delete 按 base content version 做 stale 拒绝；非递归非空目录返回 `directoryNotEmpty`。
4. `contents + filename + parent` 共用 MutationCoordinator；未支持字段保留 `stillPendingFields`。
5. upload session 仅保存 opaque session/secret reference、fingerprint、part hash/ETag/state；callback URL/FD 不进入 Store。
6. 上传恢复会验证 source fingerprint；只上传 pending/failed part，完成后进入 completion verification。
7. AES-256-CTR counter 使用全文件 offset，跨 chunk 的密文与整文件加密一致。
8. `excludedFromSync` intent 必须同时命中 item/template、kind、rule revision、source generation，避免 cleanup 进入远端 delete。
9. conflict resolution 提供 keep remote、overwrite remote、keep both，并保存摘要而非完整内容或旧 callback URL。
10. Domain removal 先进入 preflight，`waitForChanges`/pending 不确定时使用 PreserveDirtyUserData，不调用 Cloudreve delete。

## 3. 验证结果

| 验证 | 结果 |
|---|---|
| Rust operation/transfer/reconcile tests | 通过，11 core + 7 protocol + 3 store tests |
| Swift mutation/upload/lease/paging tests | 通过，17 tests |
| 10,000 item read benchmark | 通过，单页 <= 127/500 bounded |
| Xcode Debug build | 通过，三产品 Target |
| Secret/release static scan | 通过 |
| Cloudreve real conditional write/idempotency | 未验证 |
| Provider matrix | 未验证 |
| Signed Finder kill/replay | 未验证 |

## 4. 不允许带入下一阶段的假设

- `CloudreveRemoteBackend` 在 capability snapshot 未证明 write/resumable/zero-byte 前不会开启写入。
- 旧 source URL、FD 和 signed URL 不会被 operation 持久化或跨 callback 使用。
- 本地 mutation completion 不凭空写 provider-visible journal；远端额外变化由 Phase 3 enrichment/journal 消费。
- Trash 同步默认关闭；只有真实 trash/restore/permanent-delete contract 通过才可以开启。

