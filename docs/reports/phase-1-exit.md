# Phase 1 Exit Report

> 状态：Conditional Go
> 日期：2026-08-25
> 依据：`docs/04-phase-1-persistence-read-path.md`

## 1. 结论

Phase 1 的本地 Store/Auth/Domain/read-path 工程基础已实现并通过本地自动化门禁，包含 registry/domain schema、migration/quick check、Keychain wrapper、跨进程 refresh lease、Domain provisioning recovery、stable identity、分页 snapshot、anchor/outbox、完整下载临时文件交接、最小菜单栏/设置入口和诊断脱敏。

阶段结论为 **Conditional Go**：真实 App Group/Keychain access group、签名 Extension、至少 5 个真实 Domain、Cloudreve 真实分页数据和 Finder 100,000 item 性能尚未在当前环境验证。未验证能力没有被标为 healthy 或可写。

## 2. Review 发现与修复

1. 分页 token 只携带 Domain、parent、generation、offset 和固定 sort；远端 cursor 保留在 Store，不进入 token。
2. 目录页使用稳定 name/id 排序和本地 snapshot page，完整目录只在最后一页成功后标记 complete。
3. 当前 anchor 使用已扫描 sequence，不再返回 next sequence 导致跳过 change。
4. journal scope 过滤推进扫描 sequence，即使当前 container 没有可见变化也不会卡住。
5. remote ID upsert 优先复用既有本地 item identity，避免重启/rename 生成新 Finder identity。
6. Domain version secure archive 加载/持久化，callback mutation 成功前先落盘状态。
7. App Group Store factory、registry/domain DB、schema secret reference 和 provisioning action recovery 已补齐。
8. refresh token 进入 Keychain vault；跨进程 advisory lock、generation、unknown outcome 和 PKCE state/challenge 已有实现。
9. 远端只读 backend 使用 URLSession，Bearer 不跟随跨 origin redirect，signed URL 下载不携带 Cloudreve Bearer。
10. 10,000 条目录数据的分页测试通过，单页限制为不超过 500 条。

## 3. 验证结果

| 验证 | 结果 |
|---|---|
| Rust workspace tests | 通过，11 core + 7 protocol + 3 store tests |
| Swift Package tests | 通过，13 tests；包含 10,000 item page benchmark |
| Xcode Debug build | 通过，CloudreveMac、FileProvider、FileProviderUI 及 Swift packages |
| Secret/release static scan | 通过 |
| App Group/Keychain real entitlement | 未验证，当前构建为 `CODE_SIGNING_ALLOWED=NO` |
| Finder read path/eviction real E2E | 未验证 |
| Cloudreve real pagination / root identity | 未验证 |

## 4. 仍然保持的阶段边界

- Phase 1 不开启生产 create/modify/move/delete、分片上传、长期 SSE 或完整冲突 UI。
- `StoreFileProviderBackend` 对未接入的远端写路径 fail closed。
- Remote backend 的缓存回退只使用完整 snapshot，不把半页作为完整目录。
- App Group、Keychain、真实 Cloudreve 和 Finder evidence 需要在 Phase 1/2 对应环境任务中补齐，不能通过静态报告伪造通过。

