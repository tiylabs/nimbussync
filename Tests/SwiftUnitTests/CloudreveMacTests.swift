import XCTest
import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit
import CloudreveEventCoordinator
import CloudreveFileProviderKit
import CloudreveObservability
import CloudreveDomainService
import CloudreveProductKit

final class CloudreveMacTests: XCTestCase {
    func testOpaqueIdentifiersAndScopeOverlap() throws {
        let domainID = CloudreveIdentifier.domain()
        XCTAssertTrue(CloudreveIdentifier.validate(domainID, prefix: CloudreveIdentifier.domainPrefix))
        XCTAssertFalse(CloudreveIdentifier.validate("crd-https://example.com", prefix: CloudreveIdentifier.domainPrefix))
        let root = try RemoteScope(origin: "https://example.com/", accountID: "account", rootURI: "/team")
        let child = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/team/docs")
        XCTAssertTrue(root.overlaps(child))
        XCTAssertEqual(root.origin, "https://example.com")
    }

    func testCloudreveRemoteURIKeepsFilesystemIdentityAndPath() throws {
        let root = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://account@my/team/")
        let child = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://account@my/team/docs")
        XCTAssertEqual(root.rootURI, "cloudreve://account@my/team")
        XCTAssertTrue(root.overlaps(child))
        XCTAssertEqual(try CloudreveRemoteURI.append(root.rootURI, name: "note.txt"), "cloudreve://account@my/team/note.txt")
        XCTAssertEqual(CloudreveRemoteURI.relativePath("cloudreve://account@my/team/docs/note.txt", root: root.rootURI), "docs/note.txt")
    }

    func testCloudreveRemoteScopeRejectsNonMyFilesystemURI() {
        XCTAssertThrowsError(try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "cloudreve://account@share/team"))
    }

    func testHealthReducerRequiresAnchorAndReconciliation() {
        var input = HealthInputs()
        input.authenticated = true; input.rootAvailable = true; input.scopeValid = true; input.appRunning = true; input.validAnchor = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .reconciling)
        input.recentlyReconciled = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .healthy)
        input.eventDegraded = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .eventDegraded)
        input.offline = true
        XCTAssertEqual(DomainHealthReducer.reduce(input), .offline)
    }

    func testPageTokenAndAnchorStayBounded() throws {
        let token = PageToken(domainIdentifier: CloudreveIdentifier.domain(), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, snapshotGeneration: 3, offset: 10)
        XCTAssertLessThan(try token.encoded().count, 500)
        XCTAssertEqual(try PageToken.decode(token.encoded()), token)
        let anchor = SyncAnchor(domainIdentifier: token.domainIdentifier, scope: "working_set", epoch: UUID(), sequence: 20)
        XCTAssertLessThan(try anchor.encoded().count, 500)
        XCTAssertEqual(try SyncAnchor.decode(anchor.encoded()), anchor)
    }

    func testSQLiteDirectoryPagesRemainBoundedAtTenThousandItems() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-page-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let items = (0..<10_000).map { index in
            RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-\(index)", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: String(format: "item-%05d", index), uri: "/item-\(index)", kind: .file, contentType: "public.data", size: 0, version: ItemVersion(content: Data("v\(index)".utf8), metadata: Data("m\(index)".utf8)), canRead: true)
        }
        for item in items { try store.insertItem(item) }
        var offset = 0
        var count = 0
        while true {
            let page = try store.listChildrenPage(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, offset: offset, limit: 127)
            count += page.items.count
            XCTAssertLessThanOrEqual(page.items.count, 127)
            if let next = page.nextOffset { offset = next } else { break }
        }
        XCTAssertEqual(count, 10_000)
    }

    func testDomainVersionIsPersistedAndMonotonic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-domain-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let projection = DomainStateProjection(authenticated: true)
        let first = projection.domainVersion
        projection.advance(hasConflict: true)
        try projection.persist(to: url)
        let restored = DomainStateProjection.load(from: url, authenticated: true, hasConflict: true)
        XCTAssertGreaterThan(restored.domainVersion, first)
        XCTAssertEqual(restored.userInfo["hasConflict"] as? Bool, true)
    }

    func testSQLiteJournalAndOutboxAreRecoverable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-test-\(UUID().uuidString).sqlite3")
        defer {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let store = try SQLiteStateStore(url: url)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        let descriptor = DomainDescriptor(displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref")
        try store.registerDomain(descriptor)
        let change = try store.appendProviderChange(itemIdentifier: CloudreveIdentifier.item(), oldParentIdentifier: nil, newParentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, kind: "created", version: Data("v1".utf8), origin: "remote")
        XCTAssertEqual(change.sequence, 1)
        XCTAssertEqual(try store.pendingOutboxCount(), 1)
        let anchor = try store.currentAnchor(domainIdentifier: descriptor.identifier, scope: NSFileProviderItemIdentifier.rootContainer.rawValue)
        let batch = try store.enumerateChanges(domainIdentifier: descriptor.identifier, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, from: SyncAnchor(domainIdentifier: descriptor.identifier, scope: NSFileProviderItemIdentifier.rootContainer.rawValue, epoch: change.epoch, sequence: 0))
        XCTAssertEqual(batch.changes.count, 1)
        try store.acknowledgeOutbox(upTo: batch.changes[0].sequence)
        XCTAssertEqual(try store.pendingOutboxCount(), 0)
        XCTAssertTrue(try store.quickCheck())
        _ = anchor
    }

    func testSSEParserHandlesCRLFCommentsAndMultilineData() throws {
        let parser = SSEParser(maxFrameBytes: 1024)
        let events = try parser.append(Data(": keep\r\nevent: file\r\nid: 3\r\ndata: one\r\ndata: two\r\n\r\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "file", data: "one\ntwo", id: "3")])
    }

    func testSSEParserHandlesCRLFSplitAcrossChunks() throws {
        let parser = SSEParser(maxFrameBytes: 1024)
        XCTAssertTrue(try parser.append(Data("event: one\r".utf8)).isEmpty)
        XCTAssertEqual(try parser.append(Data("\ndata: first\r\n\r\n".utf8)), [SSEEvent(event: "one", data: "first", id: nil)])
    }

    func testOAuthStateIsSingleUse() throws {
        let coordinator = OAuthCoordinator()
        let state = coordinator.begin().state
        let url = URL(string: "nimbussync-macos://callback/desktop?code=abc&state=\(state)&path=%2Fteam&user_id=account")!
        XCTAssertEqual(try coordinator.validate(url: url).code, "abc")
        XCTAssertEqual(try coordinator.validate(url: URL(string: "nimbussync-macos://callback/desktop?code=abc&state=\(coordinator.begin().state)")!).path, "/desktop")
        XCTAssertThrowsError(try coordinator.validate(url: url))
        let oldSchemeURL = URL(string: "cloudreve-macos://oauth/callback?code=abc&state=\(state)")!
        XCTAssertThrowsError(try coordinator.validate(url: oldSchemeURL))
        XCTAssertFalse(coordinator.pkceChallenge(verifier: "verifier").contains("="))
    }

    func testConcurrentRefreshReusesCredentialWrittenByFirstOwner() async throws {
        let vault = MemoryCredentialVault()
        let initial = Credential(accessToken: "old", refreshToken: "refresh", accessExpiry: Date().addingTimeInterval(-60), generation: 1)
        let refreshed = Credential(accessToken: "new", refreshToken: "refresh-2", accessExpiry: Date().addingTimeInterval(3_600), generation: 2)
        try vault.write(initial, reference: "credential")
        let invocations = RefreshInvocationCounter()
        let coordinator = TokenRefreshCoordinator(vault: vault, leaseDuration: 1)
        async let first = coordinator.credential(reference: "credential") { _ in
            await invocations.increment()
            try await Task.sleep(for: .milliseconds(100))
            return refreshed
        }
        async let second = coordinator.credential(reference: "credential") { _ in
            await invocations.increment()
            return refreshed
        }
        _ = try await (first, second)
        let invocationCount = await invocations.value
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(try vault.read(reference: "credential")?.accessToken, "new")
    }

    func testFileProviderBackendRejectsStaleContent() throws {
        let item = RemoteItem(name: "file.txt", uri: "/file.txt", kind: .file, contentType: "public.data", size: 3, version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend(items: [item], contents: [item.itemIdentifier: Data("one".utf8)])
        XCTAssertThrowsError(try backend.content(identifier: item.itemIdentifier, expectedVersion: Data("old".utf8))) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .versionConflict)
        }
    }

    func testReplayCreateUsesStableTemplateIdentityAndOperationLease() throws {
        let first = CloudreveIdentifier.item(forTemplate: "template-42")
        let second = CloudreveIdentifier.item(forTemplate: "template-42")
        XCTAssertEqual(first, second)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-lease-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let operation = PendingOperation(replayKey: first, kind: "create", itemIdentifier: first)
        _ = try store.upsertOperation(operation)
        let owner = UUID()
        XCTAssertTrue(try store.acquireOperationLease(operationID: operation.operationID, owner: owner, now: Date(timeIntervalSince1970: 100), duration: 30))
        XCTAssertFalse(try store.acquireOperationLease(operationID: operation.operationID, owner: UUID(), now: Date(timeIntervalSince1970: 101), duration: 30))
        try store.releaseOperationLease(operationID: operation.operationID, owner: owner)
        XCTAssertTrue(try store.acquireOperationLease(operationID: operation.operationID, owner: UUID(), now: Date(timeIntervalSince1970: 101), duration: 30))
    }

    func testUploadSessionCheckpointPersistsOnlyOpaqueSecretReferenceAndParts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-upload-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let operationID = UUID()
        let session = UploadSessionCheckpoint(operationID: operationID, remoteSessionReference: "remote-session", secretReference: "keychain-ref", fingerprint: Data("fingerprint".utf8), provider: "s3", chunkSize: 4, expiresAt: Date().addingTimeInterval(600), parts: [UploadPartCheckpoint(index: 0, offset: 0, length: 4, sourceHash: Data("hash".utf8), etag: "etag", state: "completed")])
        try store.saveUploadSession(session)
        let restored = try XCTUnwrap(try store.uploadSession(operationID: operationID))
        XCTAssertEqual(restored.operationID, session.operationID)
        XCTAssertEqual(restored.remoteSessionReference, session.remoteSessionReference)
        XCTAssertEqual(restored.secretReference, session.secretReference)
        XCTAssertEqual(restored.fingerprint, session.fingerprint)
        XCTAssertEqual(restored.parts, session.parts)
        XCTAssertEqual(restored.expiresAt?.timeIntervalSince1970 ?? 0, floor(session.expiresAt?.timeIntervalSince1970 ?? 0), accuracy: 1)
    }

    func testMutationCoordinatorReplaysCommittedCreateWithoutDuplicate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-mutation-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: "template-create"), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "note.txt", uri: "/note.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend()
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        let first = try coordinator.create(template: template, content: Data("hello".utf8), fields: [.contents, .filename], options: [])
        let second = try coordinator.create(template: template, content: Data("hello".utf8), fields: [.contents, .filename], options: [])
        XCTAssertEqual(first.itemIdentifier, second.itemIdentifier)
        XCTAssertEqual(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).count, 1)
    }

    func testMutationCoordinatorRejectsStaleModifyAndNonRecursiveDirectoryDelete() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-mutation-stale-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let folder = RemoteItem(name: "folder", uri: "/folder", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("f1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canAddChildren: true, canTrash: true)
        let child = RemoteItem(parentIdentifier: folder.itemIdentifier, name: "child", uri: "/folder/child", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend(items: [folder, child], contents: [child.itemIdentifier: Data("old".utf8)])
        try store.insertItem(folder); try store.insertItem(child)
        let fresh = try backend.modify(item: child, expectedVersion: child.version.content, changedFields: [.contents], content: Data("remote".utf8), replayKey: "remote")
        XCTAssertNotEqual(fresh.version.content, child.version.content)
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        XCTAssertThrowsError(try coordinator.modify(item: child, baseVersion: NSFileProviderItemVersion(contentVersion: child.version.content, metadataVersion: child.version.metadata), fields: [.contents], contents: Data("local".utf8), options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .versionConflict)
        }
        XCTAssertThrowsError(try coordinator.delete(itemIdentifier: folder.itemIdentifier, baseVersion: NSFileProviderItemVersion(contentVersion: folder.version.content, metadataVersion: folder.version.metadata), options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .directoryNotEmpty)
        }
    }

    func testTrashRestoreRetainsOriginalParent() throws {
        let folder = RemoteItem(name: "folder", uri: "/folder", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("f1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        let child = RemoteItem(parentIdentifier: folder.itemIdentifier, name: "child", uri: "/folder/child", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, canWrite: true, canTrash: true)
        let backend = MemoryFileProviderBackend(items: [folder, child])
        let trashed = try backend.trash(item: child, expectedVersion: child.version.content, replayKey: "trash")
        XCTAssertEqual(trashed.parentIdentifier, NSFileProviderItemIdentifier.trashContainer.rawValue)
        XCTAssertEqual(trashed.trashOriginalParentIdentifier, folder.itemIdentifier)
        let restored = try backend.restore(item: trashed, expectedVersion: trashed.version.content, replayKey: "restore")
        XCTAssertEqual(restored.parentIdentifier, folder.itemIdentifier)
        XCTAssertNil(restored.trashOriginalParentIdentifier)
    }

    func testMemoryBackendRecursiveDeleteRemovesNestedDescendants() throws {
        let folder = RemoteItem(name: "folder", uri: "/folder", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("f".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true, canAddChildren: true)
        let child = RemoteItem(parentIdentifier: folder.itemIdentifier, name: "child", uri: "/folder/child", kind: .folder, contentType: "public.folder", version: ItemVersion(content: Data("c".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true, canAddChildren: true)
        let grandchild = RemoteItem(parentIdentifier: child.itemIdentifier, name: "grandchild", uri: "/folder/child/grandchild", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("g".utf8), metadata: Data("m".utf8)), canRead: true, canWrite: true)
        let backend = MemoryFileProviderBackend(items: [folder, child, grandchild])
        try backend.delete(identifier: folder.itemIdentifier, expectedVersion: folder.version.content, recursive: true)
        XCTAssertNil(try backend.item(identifier: folder.itemIdentifier))
        XCTAssertNil(try backend.item(identifier: child.itemIdentifier))
        XCTAssertNil(try backend.item(identifier: grandchild.itemIdentifier))
    }

    func testEventScopeGuardRejectsRootAndOutOfScopeHints() {
        var guarder = EventScopeGuard(rootRemoteID: "root", rootURI: "/team")
        XCTAssertFalse(guarder.accepts(remoteID: "root", fromURI: "/team", toURI: nil))
        XCTAssertFalse(guarder.accepts(remoteID: "child", fromURI: "/other/file", toURI: nil))
        XCTAssertTrue(guarder.accepts(remoteID: "child", fromURI: "/team/file", toURI: "/team/new"))
        XCTAssertEqual(guarder.rejectedCount, 2)
    }

    func testEchoMatcherRequiresParentNameTrashAndVersionEvidence() {
        let item = RemoteItem(itemIdentifier: "cri-item", remoteID: "remote", parentIdentifier: "cri-parent", name: "file.txt", uri: "/file.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true, trashed: false)
        let evidence = EchoEvidence(remoteID: "remote", operationID: UUID(), expectedParentIdentifier: "cri-parent", expectedName: "file.txt", expectedTrashed: false, expectedVersion: Data("v1".utf8))
        XCTAssertEqual(EchoMatcher.match(evidence, item: item), .matched)
        var moved = item; moved.parentIdentifier = "cri-other"
        XCTAssertEqual(EchoMatcher.match(evidence, item: moved), .realDifference)
    }

    func testGenerationReconciliationCannotCommitBeforeCompleteScan() throws {
        var run = ReconcileGeneration(generation: 2, capabilityRevision: 7, rootRemoteID: "root", startSequence: 4)
        run.startNormal(); run.finishNormal()
        XCTAssertThrowsError(try run.stabilize())
        run.startTrash(); run.finishTrash(); try run.stabilize()
        XCTAssertThrowsError(try run.beginDeletionCommit(currentCapabilityRevision: 8, currentRootRemoteID: "root"))
        XCTAssertEqual(run.phase, .failed)
    }

    func testFairSchedulerUsesBoundedRoundRobinSlots() async {
        let scheduler = FairDomainScheduler(limit: 2)
        await scheduler.enqueue("a"); await scheduler.enqueue("b"); await scheduler.enqueue("c")
        let first = await scheduler.next()
        let second = await scheduler.next()
        let third = await scheduler.next()
        XCTAssertEqual(first, "a")
        XCTAssertEqual(second, "b")
        XCTAssertNil(third)
        await scheduler.finish("a")
        let fourth = await scheduler.next()
        XCTAssertEqual(fourth, "c")
    }

    func testHealthProjectionDoesNotBecomeHealthyWhenAppQuits() {
        var projection = DomainConsistencyProjection()
        projection.inputs.authenticated = true; projection.inputs.rootAvailable = true; projection.inputs.scopeValid = true; projection.inputs.validAnchor = true; projection.inputs.recentlyReconciled = true; projection.inputs.appRunning = true
        XCTAssertEqual(projection.status(), .healthy)
        projection.setAppRunning(false)
        XCTAssertEqual(projection.status(), .appNotRunning)
    }

    func testReconcileSafetyDoesNotCreateTombstonesBeforeBothTreesComplete() {
        let safety = ReconcileSafety()
        let incomplete = ReconcileItemSet(expectedRemoteIDs: ["a", "b"], normalRemoteIDs: ["a"], trashRemoteIDs: [], pendingRemoteIDs: [], normalComplete: true, trashComplete: false)
        XCTAssertTrue(safety.tombstoneCandidates(incomplete).isEmpty)
        let complete = ReconcileItemSet(expectedRemoteIDs: ["a", "b"], normalRemoteIDs: ["a"], trashRemoteIDs: [], pendingRemoteIDs: [], normalComplete: true, trashComplete: true)
        XCTAssertEqual(safety.tombstoneCandidates(complete), ["b"])
    }

    func testReconcileSchedulerTriggersOnGapAndIntervals() {
        let scheduler = ReconcileScheduler(workingInterval: 60, fullInterval: 120)
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(scheduler.shouldReconcile(lastWorking: now.addingTimeInterval(-10), lastFull: now.addingTimeInterval(-10), now: now, reason: "anchor_expired"))
        XCTAssertFalse(scheduler.shouldReconcile(lastWorking: now.addingTimeInterval(-10), lastFull: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(scheduler.shouldReconcile(lastWorking: now.addingTimeInterval(-61), lastFull: now.addingTimeInterval(-10), now: now))
    }

    func testProductProjectionsAndReleaseFenceFailClosed() throws {
        var tasks = TaskProjection()
        let task = ProductTask(domainIdentifier: CloudreveIdentifier.domain(), title: "file.txt", direction: .upload, state: .failed)
        tasks.upsert(task); tasks.retry(task.id)
        XCTAssertEqual(tasks.active().first?.state, .retrying)
        XCTAssertTrue(UpgradeFence.canWrite(schemaVersion: 1, compatibilityMinimum: 1, compatibilityMaximum: 2, processGeneration: 3, currentGeneration: 3))
        XCTAssertFalse(UpgradeFence.canWrite(schemaVersion: 3, compatibilityMinimum: 1, compatibilityMaximum: 2, processGeneration: 3, currentGeneration: 3))
        let manifest = ReleaseManifest(version: "1.0.0", commit: "abc", swiftVersion: "6.2", rustVersion: "1.93", architectures: ["arm64"], artifacts: [:], supportMatrix: [SupportMatrixEntry(component: "S3", version: "v4", architecture: "arm64", status: .unverified, evidence: "none")], gates: ["build": true])
        XCTAssertFalse(manifest.isReleaseCandidate)
    }

    func testExclusionRuleValidationAndDeepLinksAreOpaque() async throws {
        let store = try SQLiteStateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-rules-\(UUID().uuidString).sqlite3"))
        let service = ExclusionRuleService(store: store)
        let rules = try await service.compile(revision: 1, text: "*.tmp\n# comment\nbuild/**")
        XCTAssertTrue(rules.matches(relativePath: "build/output.o"))
        XCTAssertTrue(rules.matches(relativePath: "notes.tmp"))
        XCTAssertFalse(rules.matches(relativePath: "folder/notes.txt"))
        let remoteItem = RemoteItem(name: "output.o", uri: "/team/build/output.o", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()))
        let impact = await service.preview(rules, items: [remoteItem], rootURI: "/team")
        XCTAssertEqual(impact.remoteMatches, 1)
        XCTAssertNil(DeepLinkRouter.destination(url: URL(string: "nimbussync-macos://conflict/not-an-id")!))
        let conflictID = UUID()
        XCTAssertEqual(DeepLinkRouter.destination(url: URL(string: "nimbussync-macos://conflict/\(conflictID.uuidString)")!), .conflict(conflictID))
        let itemID = CloudreveIdentifier.item()
        XCTAssertEqual(DeepLinkRouter.destination(url: URL(string: "nimbussync-macos://item/\(itemID)")!), .item(itemID))
        XCTAssertEqual(DeepLinkRouter.destination(url: URL(string: "nimbussync-macos://settings")!), .settings)
        XCTAssertNil(DeepLinkRouter.destination(url: URL(string: "cloudreve-macos://settings")!))
    }

    func testProvisioningRecoveryAndRemovalDefaultToFailClosed() {
        let record = DomainProvisioningRecord(domainID: CloudreveIdentifier.domain(), step: .systemDomainAdded)
        XCTAssertEqual(DomainProvisioningReducer.recover(record: record, systemDomainExists: false), .rollbackRequired)
        XCTAssertEqual(DomainProvisioningReducer.recover(record: record, systemDomainExists: true), .systemDomainAdded)
        let registered = DomainProvisioningRecord(domainID: CloudreveIdentifier.domain(), step: .registered)
        XCTAssertEqual(DomainProvisioningReducer.recover(record: registered, systemDomainExists: false), .rollbackRequired)
        XCTAssertEqual(DomainRemovalPolicy().decision(hasDirtyOperations: false, pendingSetReliable: false, waitForChangesSucceeded: true), .preserveDirtyData)
        XCTAssertEqual(DomainRemovalPolicy().decision(hasDirtyOperations: true, pendingSetReliable: true, waitForChangesSucceeded: true), .preserveDirtyData)
    }

    func testSecretRedactionDoesNotPersistCredentialMaterial() {
        let value = "Authorization: Bearer abc123 refresh_token=def456 https://example.com/file?token=ghi789"
        let redacted = SecretRedactor.redact(value)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("def456"))
        XCTAssertFalse(redacted.contains("ghi789"))
        XCTAssertTrue(redacted.contains("REDACTED"))
        XCTAssertFalse(SecretRedactor.redact("https://storage.example/file?X-Amz-Signature=leaked&x-goog-credential=also-leaked").contains("leaked"))
    }

    func testExclusionIntentMustMatchEveryReplayDimension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-exclusion-\(UUID().uuidString).sqlite3")
        defer { if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) } }
        let store = try SQLiteStateStore(url: url)
        let intent = ExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", ruleRevision: 4, kind: .unsupportedLocalType, sourceGeneration: 9)
        try store.createExclusionIntent(intent)
        XCTAssertFalse(try store.consumeMatchingExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .unsupportedLocalType, ruleRevision: 3, sourceGeneration: 9))
        XCTAssertTrue(try store.consumeMatchingExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .unsupportedLocalType, ruleRevision: 4, sourceGeneration: 9))
        XCTAssertFalse(try store.consumeMatchingExclusionIntent(itemIdentifier: "cri-item", systemItemIdentifier: "system-item", kind: .unsupportedLocalType, ruleRevision: 4, sourceGeneration: 9))
    }

    func testCapabilityWriteRequiresVerifiedRecoveryAndZeroByteSupport() {
        let provider = CapabilitySnapshot.Provider(name: "s3", read: .verified, write: .verified, resumable: .unverified, zeroByte: .verified, crypto: .verified)
        let snapshot = CapabilitySnapshot(revision: 1, stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, providers: [provider])
        XCTAssertFalse(snapshot.canWrite(provider: "s3"))
        let complete = CapabilitySnapshot.Provider(name: "s3", read: .verified, write: .verified, resumable: .verified, zeroByte: .verified, crypto: .verified)
        let verified = CapabilitySnapshot(revision: 2, stableItemIdentity: .verified, stableRootIdentity: .verified, conditionalContentWrite: .verified, idempotentCreate: .verified, providers: [complete])
        XCTAssertTrue(verified.canWrite(provider: "s3"))
    }

    func testProvisioningAndReconcileRecordsHaveRuntimeColumns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-schema-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let domainID = CloudreveIdentifier.domain()
        try store.beginProvisioning(domainID: domainID)
        try store.advanceProvisioning(domainID: domainID, step: .credentialWritten)
        XCTAssertEqual(try store.incompleteProvisioning().first?.step, .credentialWritten)
        let runID = UUID()
        try store.startReconcile(runID: runID, scope: "domain", generation: 1, phase: "prepared", cursor: nil)
        try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: "page:2", state: "active")
        XCTAssertEqual(try store.activeReconcileRuns().first?.id, runID)
    }

    func testPreparingMigrationIsRecoveredBeforeWritesResume() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-migration-recovery-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = try SQLiteStateStore(url: url)
            try store.beginMigration(targetVersion: SQLiteStateStore.schemaVersion, compatibilityMinimum: SQLiteStateStore.schemaVersion, compatibilityMaximum: SQLiteStateStore.schemaVersion)
            XCTAssertEqual(try store.schemaFence().migrationState, "preparing")
        }
        let reopened = try SQLiteStateStore(url: url)
        let fence = try reopened.schemaFence()
        XCTAssertEqual(fence.migrationState, "ready")
        XCTAssertTrue(fence.permits(processGeneration: fence.generation, schemaVersion: SQLiteStateStore.schemaVersion))
    }

    func testRemoteChangePersistsItemJournalAndOutboxAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-atomic-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let scope = try RemoteScope(origin: "https://example.com", accountID: "account", rootURI: "/")
        let descriptor = DomainDescriptor(displayName: "Test", scope: scope, rootRemoteID: "root", accountID: "account", secretReference: "credential-ref")
        try store.registerDomain(descriptor)
        let item = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: "remote-atomic", parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "atomic.txt", uri: "/atomic.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v1".utf8), metadata: Data("m1".utf8)), canRead: true)
        let change = try store.commitProviderChange(item: item, oldParentIdentifier: nil, newParentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, kind: "created", origin: "remote_event")
        XCTAssertEqual(try store.item(identifier: item.itemIdentifier), item)
        XCTAssertEqual(change.sequence, 1)
        XCTAssertEqual(try store.pendingOutboxCount(), 1)
    }

    func testRemoteMetadataDatesAndPermissionsSurviveStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-item-metadata-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_700_000_123)
        let item = RemoteItem(remoteID: "remote-metadata", name: "metadata.txt", uri: "/metadata.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data("v".utf8), metadata: Data("m".utf8)), creationDate: created, contentModificationDate: modified, canRead: true, canWrite: true)
        try store.insertItem(item)
        let restored = try XCTUnwrap(try store.item(identifier: item.itemIdentifier))
        XCTAssertEqual(try XCTUnwrap(restored.creationDate).timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(restored.contentModificationDate).timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(restored.canRead)
        XCTAssertTrue(restored.canWrite)
    }

    func testConflictProjectionRetainsCreationDateAndPendingDecorationState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-conflict-date-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_123)
        let conflict = ConflictProjection(conflictID: UUID(), itemIdentifier: "cri-item", kind: "version_conflict", baseSummary: "base", remoteSummary: "remote", localSummary: "local", pendingItemIdentifier: "cri-item", sourceGeneration: 2, createdAt: createdAt)
        try store.saveConflict(conflict)
        let restored = try XCTUnwrap(try store.pendingConflicts().first)
        XCTAssertEqual(restored.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(try store.hasPendingConflict(itemIdentifier: "cri-item"))
    }

    func testUnavailableFileProviderBackendNeverServesDetachedMemoryState() {
        let backend = UnavailableFileProviderBackend()
        XCTAssertThrowsError(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue)) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .database)
        }
    }

    func testCancelledMutationDoesNotReachBackend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-cancel-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: "cancel-template"), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "cancel.txt", uri: "/cancel.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let operationID = try XCTUnwrap(UUID(uuidString: String(template.itemIdentifier.dropFirst(4))))
        let backend = MemoryFileProviderBackend()
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        _ = try store.upsertOperation(PendingOperation(operationID: operationID, replayKey: template.itemIdentifier, kind: "create", itemIdentifier: template.itemIdentifier))
        try store.requestCancel(operationID: operationID)
        XCTAssertThrowsError(try coordinator.create(template: template, content: Data("cancel".utf8), fields: [.contents], options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .cancelled)
        }
        XCTAssertEqual(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).count, 0)
    }

    func testCommittedMutationWithoutDurableOutcomeFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudreve-missing-outcome-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try SQLiteStateStore(url: url)
        let template = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: "missing-outcome"), parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue, name: "outcome.txt", uri: "/outcome.txt", kind: .file, contentType: "public.data", version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: true)
        let operationID = try XCTUnwrap(UUID(uuidString: String(template.itemIdentifier.dropFirst(4))))
        _ = try store.upsertOperation(PendingOperation(operationID: operationID, replayKey: template.itemIdentifier, kind: "create", itemIdentifier: template.itemIdentifier))
        try store.commitOperation(operationID: operationID, state: "committed", itemIdentifier: template.itemIdentifier)
        let backend = MemoryFileProviderBackend()
        let coordinator = FileProviderMutationCoordinator(store: store, backend: backend)
        XCTAssertThrowsError(try coordinator.create(template: template, content: Data("outcome".utf8), fields: [.contents], options: [])) { error in
            XCTAssertEqual((error as? CoreFailure)?.code, .unknownOutcome)
        }
        XCTAssertEqual(try backend.children(parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue).count, 0)
    }

    func testCloudreveEventPayloadAcceptsReferenceFileIDAndSSEFrameLimit() throws {
        let decoder = EventHintDecoder()
        let payload = try decoder.decode(RemoteEventHint(kind: .file, payload: "{\"type\":\"create\",\"file_id\":\"remote-1\",\"from\":\"/team/a\",\"to\":\"\"}"))
        XCTAssertEqual(payload.id, "remote-1")
        XCTAssertEqual(payload.from, "/team/a")
        let parser = SSEParser(maxFrameBytes: 20)
        XCTAssertThrowsError(try parser.append(Data("data: 123456789\ndata: 123456789\n".utf8)))
    }
}

private actor RefreshInvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
