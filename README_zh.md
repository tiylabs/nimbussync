<div align="center">

# NimbusSync

**面向自托管 Cloudreve 实例的原生 macOS File Provider 客户端。**

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?style=flat-square&logo=apple&logoColor=white)](#环境要求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](#架构)
[![Rust](https://img.shields.io/badge/Rust-workspace-DEA584?style=flat-square&logo=rust&logoColor=white)](#架构)
[![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-D22128?style=flat-square)](LICENSE)

[English](README.md) | 简体中文

</div>

NimbusSync 将 macOS 菜单栏应用、Replicated File Provider 扩展和自托管
Cloudreve 服务端连接起来。每个配置的远端根目录都会映射为一个 File
Provider Domain，Finder 可以浏览远端 metadata、按需下载文件内容；客户端
同时把恢复、事件一致性和诊断所需的状态持久化在本地。

> [!IMPORTANT]
> 这是一个以源码构建为主的 Technical Preview/Beta 工程仓库，不是 1.0
> 发布版，也不是已经发布到注册表的 Swift/Rust 包。本地 Rust、Swift、Xcode
> 以及静态安全/Release 门禁已经建立，但真实 Cloudreve mutation 语义、签名
> Finder 端到端行为、Provider 上传矩阵、公证和长稳证据仍未验证。当前 Phase 4
> 的 1.0 发布结论是 **No-Go**。

> [!NOTE]
> 完整的产品需求和架构材料位于 `docs/`，目前以中文为主。英文版和本中文版
> README 保持同一结构和事实口径，但不会把深层设计文档全部重复到首页。

## 当前状态

以下状态依据 2026-08-25 的阶段退出报告整理，并明确区分本地工程证据与真实
外部平台证据：

| 范围 | 当前状态 | 证据或边界 |
| --- | --- | --- |
| Rust protocol/core/store/FFI 基础 | 本地已验证 | Rust workspace 测试及阶段报告 |
| Swift Store/Auth/File Provider/Event/Product 模块 | 本地已验证 | Swift Package 测试及 Xcode Debug 构建 |
| 菜单栏 App 和扩展 Target 结构 | 本地已实现 | `NimbusSync`、`NimbusSyncFileProvider`、`NimbusSyncFileProviderUI` |
| 真实 Cloudreve root/item identity 与条件写 | 未验证 | 需要受控的 Cloudreve contract 环境 |
| Provider 上传完成与断点恢复矩阵 | 未验证 | 由 capability gate 控制，代码本身不能升级支持级别 |
| 签名 Finder callback replay 与 File Provider E2E | 未验证 | 需要签名扩展和真实 Finder 证据 |
| Developer ID、公证、Gatekeeper、干净机器升级 | 未验证 | 需要发布凭据和测试机器 |
| 1.0 Release Candidate | No-Go | 见 [`phase-4-release-readiness.md`](docs/reports/phase-4-release-readiness.md) |

当前实现使用 `verified` / `unsupported` / `unverified` 三态 capability 模型。
代码路径存在并不代表写能力已经开放：stable item identity、stable root identity、
conditional content write、idempotent create 必须先验证；选中的存储 Provider
还必须验证 write、resumable 和 zero-byte 行为。

## 为什么做 NimbusSync

macOS 云文件是系统集成问题，而不只是一个 HTTP 客户端。NimbusSync 围绕
Finder 边界上最容易造成数据损坏的故障设计：

- **Finder 原生 Domain**：使用 `NSFileProviderReplicatedExtension`，不把远端
  文件树伪装成一个由普通 watcher 驱动的本地目录。
- **可恢复的 callback**：operation replay key、lease、source fingerprint、
  upload checkpoint 和 conflict summary 都进入持久状态，不依赖游离内存任务。
- **显式一致性链路**：Cloudreve SSE 只作为变化提示；metadata enrichment、本地
  change journal、signal outbox 和 reconciliation 共同构成最终收敛路径。
- **稳定且不透明的 identity**：本地 Domain/item identifier 不暴露 origin、账号、
  远端路径或文件名；远端对象身份也不会仅由路径推断。
- **Fail-closed**：不完整扫描不会生成 tombstone，结果未知的写入不会盲目重试，
  未验证能力保持只读或不支持。

## 当前已经具备的内容

当前 checkout 已包含以下基础能力和产品入口：

### Swift macOS 产品层

- SwiftUI 菜单栏应用：onboarding、Domain 列表、Settings、Conflict Center、
  通知、deep link、诊断和登录启动基础能力。
- Replicated File Provider 扩展：item 映射、分页枚举、change enumeration、
  内容获取、mutation、custom action 和 Domain state projection。
- File Provider UI 扩展：校验不透明 item identifier，并将支持的交互动作路由回
  主应用；不持有凭据，也不持有持久 mutation 状态。
- Swift 共享模块：Domain 生命周期、OAuth/PKCE/Keychain、App Group SQLite、
  事件协调、File Provider adapter、产品 projection、observability 和 design token。

### 协议、状态与恢复基础

- Cloudreve origin 规范化、API envelope、文件 metadata DTO、分页、
  content/metadata version hash、Provider capability snapshot 和严格 SSE framing。
- Registry 与每个 Domain 的 SQLite 状态：WAL、foreign key、schema fence、migration
  hook、quick check、backup、repair isolation、directory snapshot、sync anchor、
  change journal、signal outbox、operation、conflict、exclusion intent 和 upload checkpoint。
- OAuth callback 校验、PKCE state、Keychain 凭据存储、App Group advisory refresh
  lock、有界 secret 存储，以及不跨 origin 转发 Bearer 的 redirect policy。
- create、modify、trash、restore、delete 的持久 mutation/replay 基础，包含 stale
  version rejection、source fingerprint、取消和冲突解决 service。生产写入仍受
  capability gate 控制，真实服务端契约尚未验证。
- SSE supervisor/reconnect、事件 scope guard、metadata enrichment、本地写回声匹配、
  working-set signal、outbox drain、generation reconciliation、stable-root 检查、
  health reducer 和 scheduler 模型。

### Rust workspace

Rust workspace 当前包含：

| Crate | 职责 |
| --- | --- |
| `cloudreve-protocol` | Cloudreve DTO、URI/scope 规则、capability snapshot、版本、page token、sync anchor、SSE parser 和 backoff |
| `cloudreve-store` | SQLite schema、domain/item、journal、anchor、outbox、operation、compaction 和 backup helper |
| `cloudreve-core` | HTTP client、远端 mutation 原语、health reducer、reconciliation、upload recovery 和 AES-CTR-at-offset helper |
| `cloudreve-ffi` | 用于版本和本地 identifier 校验的窄 C ABI，输出 static library |

`cloudreve-ffi` crate 仍保留在 Rust workspace 中，但 native artifact 打包会在产品
集成完成后再恢复。当前 Xcode project 直接链接 Swift Package products。

## 架构

```mermaid
flowchart LR
    Finder[Finder]
    App[NimbusSync.app<br/>菜单栏、设置、SSE、reconciliation]
    FP[NimbusSyncFileProvider.appex<br/>枚举、下载、mutation]
    FPUI[NimbusSyncFileProviderUI.appex<br/>交互动作]
    Store[(App Group SQLite<br/>registry + Domain state)]
    Keychain[(Keychain<br/>凭据 + upload secrets)]
    Cloudreve[Cloudreve HTTPS API / SSE]
    Rust[Rust workspace<br/>protocol / core / store / FFI]

    Finder <--> FP
    Finder <--> FPUI
    FPUI --> App
    App <--> Store
    FP <--> Store
    App <--> Keychain
    FP <--> Keychain
    App <--> Cloudreve
    FP <--> Cloudreve
```

最重要的状态交付链路是：

```text
远端事件或 reconciliation
  -> metadata enrichment 与 scope 校验
  -> SQLite item + journal + signal outbox 事务
  -> .workingSet signal
  -> File Provider change enumeration
```

本地 mutation 会先关联持久 operation 和 replay key。执行前检查 item/version，
只有 capability snapshot 允许时才访问写路径；最终 outcome 持久化后再返回给
File Provider。匹配的 SSE echo 只负责确认，不再次生成 provider-visible change。
主应用不是 Extension callback 必须依赖的 RPC 代理。

## 安全与数据边界

- OAuth access/refresh credential 与上传相关不透明 secret 只进入 Keychain；SQLite
  只保存引用和恢复所需的非敏感 metadata。
- App 与 File Provider 进程通过 App Group 和 SQLite 共享持久事实。Darwin notification
  只是唤醒提示，不是第二个状态存储。
- Release 配置只允许 HTTPS；Debug 可在显式开启时为受控测试使用 loopback HTTP。
- Bearer 不跨 origin 转发，也不发送到 signed storage URL。SSE payload、token、signed
  URL、文件内容和敏感路径不进入普通诊断。
- File Provider callback 不依赖主应用、旧 callback URL、旧 FD 或 callback 结束后仍未
  持久化的 detached task。
- Domain 移除在状态不确定时保留 dirty data，且不调用远端 Cloudreve delete API。排除
  cleanup 使用精确持久 intent，与用户主动删除保持独立。
- reconciliation 可以增量发布新增和更新，但只有完整且稳定的扫描才能提交破坏性
  tombstone。

## 环境要求

### 工具链

- macOS 13 或更高版本，依据 [`Package.swift`](Package.swift) 和 Xcode deployment settings。
- 支持 Swift 6 的 Xcode。本 checkout 当前在 Xcode 26.2、Swift 6.2.3 环境检查过；项目
  声明 Swift 6.0，但没有在仓库中锁定 Xcode 发行版。
- Stable Rust/Cargo。Rust workspace 使用 edition 2021 和 Apache-2.0 package metadata；
  本 checkout 当前在 Rust 1.93.1 环境检查过。
- 本地单元测试不需要真实 Cloudreve；任何真实服务端/Provider 支持结论都需要受控
  Cloudreve 实例和单独的外部验证。
- File Provider E2E 需要签名开发环境和真实 Finder 测试机；未签名构建只能证明编译路径。

### Clone

```sh
git clone git@github.com:tiylabs/nimbussync.git
cd nimbussync
```

如果 GitHub remote 需要权限，请使用仓库既有的认证方式。

## 构建

唯一的本地构建入口是 [`Scripts/build.sh`](Scripts/build.sh)。它可选读取机器本地的
`Config/build.local.sh`（可复制 [`Config/build.local.sh.example`](Config/build.local.sh.example)
创建），先执行仓库和 Release 配置检查，再构建 App 与两个 Extension，并把 App、zip
和 checksum 写入 `Dist/`。

```sh
Scripts/build.sh
```

默认输出为：

```text
.build/ci/derived/Build/Products/$CONFIGURATION/NimbusSync.app
Dist/NimbusSync.app
Dist/NimbusSync-0.1.0.zip
Dist/NimbusSync-0.1.0.zip.sha256
```

如需指定输出目录和版本：

```sh
CONFIGURATION=Debug \
SIGNING_MODE=unsigned \
BUILD_ROOT="$PWD/.build/debug" \
DIST_DIR="$PWD/Dist/debug" \
VERSION=dev \
Scripts/build.sh
```

如果执行签名构建，必须先把证书私钥导入当前用户的 keychain，并通过 Xcode 或系统方式
安装三个 provisioning profile，然后提供以下变量：

| 变量 | 必需 | 说明 |
| --- | --- | --- |
| `SIGNING_MODE` | 是 | 设置为 `signed` |
| `CONFIGURATION` | 否 | 通常使用 `Release`，默认 `Debug` |
| `DEVELOPMENT_TEAM` | 是 | Apple Developer Team ID |
| `CODE_SIGN_IDENTITY` | 是 | 当前 keychain 中的完整签名身份名称 |
| `NIMBUSSYNC_APP_PROFILE` | 是 | App profile UUID |
| `NIMBUSSYNC_FILE_PROVIDER_PROFILE` | 是 | File Provider profile UUID |
| `NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE` | 是 | File Provider UI profile UUID |
| `APP_GROUP_IDENTIFIER` | 否 | 默认 `group.ai.tiy.nimbussync` |
| `BUILD_ROOT`/`DIST_DIR`/`VERSION` | 否 | 构建目录、输出目录和 artifact 版本 |

构建入口不会替你导入证书或 profile。本地构建配置已加入 Git 忽略规则，因此证书名称、
profile UUID 和其他机器专用签名设置不会被提交。

也可以分别运行底层局部检查：

```sh
# Swift Package tests
swift test --disable-sandbox

# Rust workspace tests
(cd Rust && cargo test --workspace)

# 格式和空白检查
(cd Rust && cargo fmt --all --check)
git diff --check
```

需要实际注册 File Provider Domain 时必须使用 Apple Development 签名，未签名构建只能
验证编译。签名证书和 provisioning profile 需要由开发环境单独准备。

旧的阶段门禁脚本、GitHub Actions workflow、Rust XCFramework 打包脚本和独立 Release
脚本暂时移除，待产品开发和发布证据完成后再恢复。

## 仓库结构

```text
Apps/NimbusSync/                   SwiftUI 菜单栏 App 和生命周期
Extensions/NimbusSyncFileProvider/ Replicated File Provider 入口
Extensions/NimbusSyncFileProviderUI/交互式 File Provider action
Packages/                           共享 Swift 模块
  NimbusSyncDomainKit/              Domain identity、lifecycle、health、scope
  NimbusSyncAuthKit/                OAuth、PKCE、Keychain、refresh 协调
  NimbusSyncStoreBridge/            App Group SQLite 和持久状态
  NimbusSyncEventCoordinator/       SSE、journal 交付、reconciliation 模型
  NimbusSyncFileProviderKit/        Finder item、枚举、内容、mutation
  NimbusSyncProductKit/             产品 projection、任务、冲突、UI state
  NimbusSyncDesignSystem/           产品 design token
  NimbusSyncObservability/          脱敏诊断和 metrics
Rust/crates/                        平台无关 protocol/core/store/FFI
Config/                             Entitlement、Info.plist、Debug/Release 设置
Scripts/build.sh                    构建前检查、App 构建和打包
Tests/SwiftUnitTests/               Swift unit/invariant tests
docs/                               产品、架构、阶段计划、退出报告
```

更深层的阶段计划中有一些尚未出现在当前 checkout 的未来 Target 或 crate。上面的
结构严格依据当前文件整理，而不是把规划中的架构图当成已存在的目录。

## 文档导航

按任务选择入口：

| 主题 | 文档 |
| --- | --- |
| 调研与 macOS 平台映射 | [`docs/00-macos-port-research.md`](docs/00-macos-port-research.md) |
| 产品需求与验收场景 | [`docs/01-macos-product-requirements.md`](docs/01-macos-product-requirements.md) |
| 技术架构与不变量 | [`docs/02-macos-technical-architecture.md`](docs/02-macos-technical-architecture.md) |
| Phase 0 协议/File Provider Spike | [`docs/03-phase-0-protocol-file-provider-spike.md`](docs/03-phase-0-protocol-file-provider-spike.md) |
| Phase 1 持久化与读路径 | [`docs/04-phase-1-persistence-read-path.md`](docs/04-phase-1-persistence-read-path.md) |
| Phase 2 写路径与上传恢复 | [`docs/05-phase-2-write-path-upload-recovery.md`](docs/05-phase-2-write-path-upload-recovery.md) |
| Phase 3 SSE 与一致性 | [`docs/06-phase-3-events-consistency.md`](docs/06-phase-3-events-consistency.md) |
| Phase 4 产品化与发布 | [`docs/07-phase-4-product-release.md`](docs/07-phase-4-product-release.md) |
| 阶段退出证据 | [`docs/reports/`](docs/reports/) |
| 仓库约定与安全规则 | [`AGENTS.md`](AGENTS.md) |

阶段报告是“已经验证了什么”的事实来源。阶段计划描述目标范围和验收门槛，不能
替代签名 Finder 或真实服务端证据。

## 参与开发

修改代码前：

1. 阅读 [`AGENTS.md`](AGENTS.md) 以及对应的阶段计划/退出报告。
2. 保留工作区已有的本地改动；不要 reset、clean，也不要提交无关文件。
3. 让 remote identity、operation state 和 secret 继续通过现有 Store/Auth 边界管理。
4. 按改动范围补充 Swift 或 Rust 测试，重点覆盖 replay、stale version、取消、分页、
   anchor expiry、崩溃恢复、secret redaction 和 fail-closed 行为。
5. Review 前运行局部测试、格式检查和 `git diff --check`。

真实 Cloudreve credential、signed URL、响应 body、文件内容和私有路径不得进入 Git、
日志、诊断或 gate artifact。

## 视觉素材

当前仓库还没有产品截图或 Finder 录屏。未来最有价值的素材，是在签名 Technical
Preview 上用一个短流程展示菜单栏状态、onboarding 和 Finder Domain。签名 Finder
证据出现前，截图容易传递超过实际证据的确定性，因此本 README 使用源代码和报告支持
的 Mermaid 架构图作为视觉入口。

## 许可证

NimbusSync 使用 [Apache License 2.0](LICENSE)。Cloudreve 服务端部署、存储 Provider、
第三方 SDK 和品牌资产可能有各自的许可或使用条款；发布产品构建前需要单独审查。
