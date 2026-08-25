# Phase 0 Exit Report

> 状态：Conditional Go
> 日期：2026-08-25
> 依据：`docs/03-phase-0-protocol-file-provider-spike.md`

## 1. 结论

Phase 0 的本地实现、协议模型、故障注入单元测试、Swift Package 测试、Xcode 三 Target Debug 构建、Rust XCFramework 生成和敏感信息扫描已通过。按照阶段方案，真实 Cloudreve Community/Pro、签名后的 Finder callback replay、Provider 上传恢复矩阵和多版本 macOS 实机证据尚未具备，因此结论为 **Conditional Go**，Phase 1 可以在所有未验证写能力继续 fail-closed 的前提下启动。

## 2. 已验证证据

| 范围 | 结果 | 证据 |
|---|---|---|
| Rust protocol/core/store/transfer/FFI | 通过 | `HOME=/tmp/... CARGO_HOME=/tmp/... cargo test --workspace`，共 11 + 6 + 3 个核心测试通过 |
| Swift Domain/Auth/Store/Event/File Provider/Diagnostics | 通过 | `swift test --disable-sandbox`，10 个测试通过 |
| Xcode 工程 | 通过 | `xcodebuild -project CloudreveMac.xcodeproj -scheme CloudreveMac ... CODE_SIGNING_ALLOWED=NO build` |
| 三个产品 Target | 可解析并构建 | `CloudreveMac`、`CloudreveFileProvider`、`CloudreveFileProviderUI` |
| Rust XCFramework | 通过 arm64 Debug/Release 构建 | `Scripts/xtask/build-xcframework.sh` |
| Page/anchor 上限 | 通过 | Page token 和 sync anchor 单元测试；均限制在 500 bytes 内 |
| SSE framing | 通过 | CRLF/LF、comment、多行 data、partial frame、CRLF 跨 chunk 测试 |
| journal/outbox | 通过 | 同事务写入、重启语义模型、signal ack 测试 |
| stale write / root replace / incomplete scan | 通过 | Rust mutation/reconciliation 测试 |
| secret/release scan | 通过 | Phase gate 内置扫描 |

## 3. Review 修复记录

1. 修复 CRLF 被拆分在两个网络 chunk 时的 SSE 错帧。
2. 修复 SSE stream EOF 丢失未完成 frame 的问题。
3. 修复 Swift current anchor 返回 next sequence、可能跳过首条 change 的问题。
4. 让旧 anchor 对 `min_valid_sequence` 做显式过期校验。
5. 禁止 local callback audit 误写 provider-visible journal。
6. 为 create replay 使用稳定的本地 item ID；不再为每次 replay 随机生成新 ID。
7. 为 memory backend 增加 stale modify/delete 的版本检查。
8. 将 Domain version、secret reference、upload parts、exclusion intent、operation lease 纳入持久化模型。
9. 将未验证的网络/Provider 写能力保持为 unsupported 或 unverified，不在 UI 中声明可写。

## 4. 尚未验证与降级

| 能力 | 当前状态 | 降级行为 |
|---|---|---|
| 真实 Cloudreve item/root identity | unverified | 不开启生产可写 mutation |
| Cloudreve conditional content write | unverified | stale/overwrite 路径 fail closed |
| Cloudreve idempotent create | unverified | 不宣称 create 生产可用 |
| upload Provider matrix | unverified | Provider 不进入可写支持矩阵 |
| refresh rotation unknown outcome | unverified | unknown outcome 要求重新授权，不循环刷新 |
| signed Finder entitlement/callback replay | unverified | 只通过本地 adapter/unit tests，不能宣称真实 Finder 通过 |
| trash/restore/excludedFromSync 实机握手 | unverified | `supportsSyncingTrash` 默认 false；排除 cleanup 需要精确 intent |

## 5. Phase 1 入口条件

- 继续使用 `Rust/crates/cloudreve-store` 的 schema fencing 和备份/quick-check 机制。
- 所有未验证 capability 继续使用 `unverified`，不能由实现层偷偷放宽。
- 真实测试实例、签名测试机和 Provider contract 数据在进入对应 Phase 1/2 任务时补齐。
- Phase 1 的 read path 可以启动；生产 write path、SSE supervisor 和正式产品 UI 仍遵循后续阶段边界。

