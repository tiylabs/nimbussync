import Foundation
import FileProvider
import CryptoKit
import CloudreveDomainKit
import CloudreveStoreBridge

public struct SourceFingerprint: Codable, Equatable, Sendable {
    public let size: Int64
    public let baseVersion: Data
    public let edgeDigest: Data
    public let sourceGeneration: UInt64
    public init(content: Data?, baseVersion: Data, sourceGeneration: UInt64) {
        let content = content ?? Data()
        self.size = Int64(content.count)
        self.baseVersion = baseVersion
        let edge: Data
        if content.count <= 128 * 1024 { edge = content } else { edge = content.prefix(64 * 1024) + content.suffix(64 * 1024) }
        var length = UInt64(content.count).bigEndian
        var digestInput = Data(bytes: &length, count: MemoryLayout<UInt64>.size)
        digestInput.append(edge)
        self.edgeDigest = Data(CryptoKit.SHA256.hash(data: digestInput))
        self.sourceGeneration = sourceGeneration
    }
}

public enum MutationOperationKind: String, Sendable { case create, modify, trash, restore, delete }

public struct MutationReplay: Sendable {
    public let replayKey: String
    public let operationID: UUID
    public let sourceGeneration: UInt64
    public init(replayKey: String, operationID: UUID, sourceGeneration: UInt64) { self.replayKey = replayKey; self.operationID = operationID; self.sourceGeneration = sourceGeneration }
}

public final class FileProviderMutationCoordinator: @unchecked Sendable {
    private let store: SQLiteStateStore?
    private let backend: FileProviderBackend
    private let ownerID = UUID()

    public init(store: SQLiteStateStore?, backend: FileProviderBackend) { self.store = store; self.backend = backend }

    public func create(template: RemoteItem, content: Data?, fields: NSFileProviderItemFields, options: NSFileProviderCreateItemOptions) throws -> RemoteItem {
        guard let store else { return try backend.create(template: template, content: content, replayKey: template.itemIdentifier) }
        if template.kind == .symlink || template.kind == .unsupported {
            try store.createExclusionIntent(ExclusionIntent(itemIdentifier: template.itemIdentifier, systemItemIdentifier: template.itemIdentifier, ruleRevision: 1, kind: .unsupportedLocalType, sourceGeneration: 1))
            throw CoreFailure(code: .excludedFromSync, retryable: false, userActionRequired: false)
        }
        let replay = MutationReplay(replayKey: template.itemIdentifier, operationID: operationID(for: template.itemIdentifier), sourceGeneration: 1)
        let operation = try begin(replay: replay, kind: .create, itemIdentifier: template.itemIdentifier)
        if let result = try committedResult(operation) { return result }
        try ensureLease(operation)
        do {
            let item = try backend.create(template: template, content: content, replayKey: replay.replayKey)
            try commitRemoteResult(operationID: replay.operationID, item: item)
            return item
        } catch {
            preserveUnknownOutcome(operationID: replay.operationID, itemIdentifier: template.itemIdentifier, error: error)
            throw error
        }
    }

    public func modify(item: RemoteItem, baseVersion: NSFileProviderItemVersion, fields: NSFileProviderItemFields, contents: Data?, options: NSFileProviderModifyItemOptions) throws -> RemoteItem {
        guard store != nil else { return try backend.modify(item: item, expectedVersion: baseVersion.contentVersion, changedFields: fields, content: contents, replayKey: item.itemIdentifier) }
        if fields.contains(.contents), let contents, let store,
           let pending = try store.pendingConflictResolution(itemIdentifier: item.itemIdentifier) {
            return try resolvePendingConflict(item: item, contents: contents, conflictID: pending.conflictID, resolution: pending.resolution, expectedRemoteVersion: pending.remoteVersion)
        }
        let fingerprint = SourceFingerprint(content: contents, baseVersion: baseVersion.contentVersion, sourceGeneration: 1)
        let replayKey = "modify|\(item.itemIdentifier)|\(baseVersion.contentVersion.base64EncodedString())|\(fields.rawValue)|\(fingerprint.edgeDigest.base64EncodedString())"
        let replay = MutationReplay(replayKey: replayKey, operationID: operationID(for: replayKey), sourceGeneration: fingerprint.sourceGeneration)
        let operation = try begin(replay: replay, kind: .modify, itemIdentifier: item.itemIdentifier)
        if let result = try committedResult(operation) { return result }
        try ensureLease(operation)
        do {
            let updated: RemoteItem
            if fields.contains(.parentItemIdentifier) && item.parentIdentifier == NSFileProviderItemIdentifier.trashContainer.rawValue {
                updated = try backend.trash(item: item, expectedVersion: baseVersion.contentVersion, replayKey: replay.replayKey)
            } else if item.trashed && fields.contains(.parentItemIdentifier) {
                updated = try backend.restore(item: item, expectedVersion: baseVersion.contentVersion, replayKey: replay.replayKey)
            } else {
                updated = try backend.modify(item: item, expectedVersion: baseVersion.contentVersion, changedFields: fields, content: contents, replayKey: replay.replayKey)
            }
            try commitRemoteResult(operationID: replay.operationID, item: updated)
            return updated
        } catch {
            recordConflictIfNeeded(item: item, baseVersion: baseVersion, fields: fields, contents: contents, error: error)
            preserveUnknownOutcome(operationID: replay.operationID, itemIdentifier: item.itemIdentifier, error: error)
            throw error
        }
    }

    public func delete(itemIdentifier: String, baseVersion: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions) throws {
        guard let store else { return try backend.delete(identifier: itemIdentifier, expectedVersion: baseVersion.contentVersion, recursive: options.contains(.recursive)) }
        guard let item = try store.item(identifier: itemIdentifier) else { return }
        let replayKey = "delete|\(itemIdentifier)|\(baseVersion.contentVersion.base64EncodedString())|\(options.rawValue)"
        let replay = MutationReplay(replayKey: replayKey, operationID: operationID(for: replayKey), sourceGeneration: 1)
        let operation = try begin(replay: replay, kind: .delete, itemIdentifier: itemIdentifier)
        if operation.operation.state == "committed" { return }
        if operation.operation.state == "unknown_outcome" { throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true) }
        if try store.consumeMatchingExclusionIntent(itemIdentifier: itemIdentifier, systemItemIdentifier: itemIdentifier, kind: .unsupportedLocalType, ruleRevision: 1, sourceGeneration: 1) {
            try store.commitOperation(operationID: replay.operationID, state: "committed", itemIdentifier: itemIdentifier)
            return
        }
        try ensureLease(operation)
        do {
            try backend.delete(identifier: itemIdentifier, expectedVersion: baseVersion.contentVersion, recursive: options.contains(.recursive))
            var tombstone = item
            tombstone.tombstone = true
            if try store.cancelRequested(operationID: replay.operationID) {
                try store.commitOperationWithItem(operationID: replay.operationID, state: "unknown_outcome", item: tombstone)
                throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true)
            }
            try store.commitOperationWithItem(operationID: replay.operationID, state: "committed", item: tombstone)
        } catch {
            if let conflictedItem = try? store.item(identifier: itemIdentifier) {
                recordConflictIfNeeded(item: conflictedItem, baseVersion: baseVersion, fields: [], contents: nil, error: error)
            }
            preserveUnknownOutcome(operationID: replay.operationID, itemIdentifier: itemIdentifier, error: error)
            throw error
        }
    }

    private func begin(replay: MutationReplay, kind: MutationOperationKind, itemIdentifier: String) throws -> StoredOperation {
        guard let store else { throw CoreFailure(code: .database, retryable: false) }
        _ = try store.upsertOperation(PendingOperation(operationID: replay.operationID, replayKey: replay.replayKey, kind: kind.rawValue, itemIdentifier: itemIdentifier, sourceGeneration: replay.sourceGeneration))
        guard let operation = try store.operation(replayKey: replay.replayKey) else { throw CoreFailure(code: .database, retryable: false) }
        return operation
    }

    private func committedResult(_ operation: StoredOperation) throws -> RemoteItem? {
        if operation.operation.state == "unknown_outcome" {
            throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true)
        }
        guard operation.operation.state == "committed" else { return nil }
        guard let outcome = operation.outcome, let data = outcome.data(using: .utf8) else {
            throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true)
        }
        return try JSONDecoder().decode(RemoteItem.self, from: data)
    }

    private func commitRemoteResult(operationID: UUID, item: RemoteItem) throws {
        guard let store else { throw CoreFailure(code: .database, retryable: false) }
        let outcome = String(data: try JSONEncoder().encode(item), encoding: .utf8)
        if try store.cancelRequested(operationID: operationID) {
            try store.commitOperationWithItem(operationID: operationID, state: "unknown_outcome", item: item, outcome: outcome)
            throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true)
        }
        try store.commitOperationWithItem(operationID: operationID, state: "committed", item: item, outcome: outcome)
    }

    private func preserveUnknownOutcome(operationID: UUID, itemIdentifier: String, error: Error) {
        guard let store else { return }
        guard let operation = try? store.operation(operationID: operationID), operation.operation.state == "unknown_outcome" else {
            try? store.commitOperation(operationID: operationID, state: state(for: error), itemIdentifier: itemIdentifier)
            return
        }
    }

    private func recordConflictIfNeeded(item: RemoteItem, baseVersion: NSFileProviderItemVersion, fields: NSFileProviderItemFields, contents: Data?, error: Error) {
        guard let failure = error as? CoreFailure, failure.code == .versionConflict, let store else { return }
        let conflictID = operationID(for: "conflict|\(item.itemIdentifier)|\(baseVersion.contentVersion.base64EncodedString())")
        let localSummary = contents.map { "bytes:\($0.count)" } ?? (fields.isEmpty ? "metadata" : "pending content")
        let conflict = ConflictProjection(conflictID: conflictID, itemIdentifier: item.itemIdentifier, kind: "version_conflict", baseSummary: "version:\(short(baseVersion.contentVersion))", remoteSummary: "version:\(short(item.version.content))", localSummary: localSummary, pendingItemIdentifier: item.itemIdentifier, sourceGeneration: 1, remoteVersion: item.version.content)
        try? store.saveConflict(conflict)
        try? store.setPending(item.itemIdentifier, templateIdentifier: "conflict-local-change", uploadError: "version_conflict")
    }

    private func short(_ value: Data) -> String { value.prefix(8).map { String(format: "%02x", $0) }.joined() }

    private func ensureLease(_ operation: StoredOperation) throws {
        guard let store else { return }
        if operation.operation.state == "committed" { return }
        let cancellationRequested = try store.cancelRequested(operationID: operation.operation.operationID)
        if operation.operation.state == "cancelled" || cancellationRequested {
            try? store.commitOperation(operationID: operation.operation.operationID, state: "cancelled", itemIdentifier: operation.operation.itemIdentifier)
            throw CoreFailure(code: .cancelled, retryable: false)
        }
        guard try store.acquireOperationLease(operationID: operation.operation.operationID, owner: ownerID) else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
    }

    private func operationID(for replayKey: String) -> UUID {
        if replayKey.hasPrefix("cri-"), let value = UUID(uuidString: String(replayKey.dropFirst(4))) { return value }
        let digest = CryptoKit.SHA256.hash(data: Data(replayKey.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))") ?? UUID()
    }

    private func state(for error: Error) -> String {
        if let failure = error as? CoreFailure {
            switch failure.code { case .versionConflict: return "conflict"; case .authentication: return "auth_expired"; case .cancelled: return "cancelled"; default: return "unknown_outcome" }
        }
        return "unknown_outcome"
    }

    private func resolvePendingConflict(item: RemoteItem, contents: Data, conflictID: UUID, resolution: String, expectedRemoteVersion: Data?) throws -> RemoteItem {
        guard let store else { throw CoreFailure(code: .database, retryable: false) }
        let replayKey = "conflict-\(resolution)|\(conflictID.uuidString)"
        let operationID = operationID(for: replayKey)
        let operation = try beginOperation(operationID: operationID, replayKey: replayKey, kind: resolution, itemIdentifier: item.itemIdentifier)
        if let result = try committedResult(operation) {
            try store.completeConflictResolution(itemIdentifier: item.itemIdentifier, conflictID: conflictID, resolution: resolution.replacingOccurrences(of: "_pending", with: ""))
            return result
        }
        try ensureLease(operation)
        do {
            guard let current = try backend.item(identifier: item.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
            if let expectedRemoteVersion, current.version.content != expectedRemoteVersion {
                throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
            }
            let result: RemoteItem
            if resolution == "overwrite_remote_pending" {
                result = try backend.modify(item: current, expectedVersion: current.version.content, changedFields: [.contents], content: contents, replayKey: replayKey)
            } else if resolution == "keep_both_pending" {
                let copy = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: replayKey), remoteID: nil, parentIdentifier: current.parentIdentifier, name: uniqueName(current.name), uri: current.uri, kind: current.kind, contentType: current.contentType, size: Int64(contents.count), version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: current.canWrite, canAddChildren: current.canAddChildren, canTrash: current.canTrash, canDelete: current.canDelete)
                let created = try backend.create(template: copy, content: contents, replayKey: replayKey)
                _ = try store.commitProviderChange(item: created, oldParentIdentifier: nil, newParentIdentifier: created.parentIdentifier, kind: "conflict_copy", origin: "conflict_resolution")
                result = current
            } else {
                throw CoreFailure(code: .unsupportedMetadata, retryable: false, userActionRequired: true)
            }
            try commitRemoteResult(operationID: operationID, item: result)
            try store.completeConflictResolution(itemIdentifier: item.itemIdentifier, conflictID: conflictID, resolution: resolution.replacingOccurrences(of: "_pending", with: ""))
            return result
        } catch {
            preserveUnknownOutcome(operationID: operationID, itemIdentifier: item.itemIdentifier, error: error)
            throw error
        }
    }

    private func beginOperation(operationID: UUID, replayKey: String, kind: String, itemIdentifier: String) throws -> StoredOperation {
        guard let store else { throw CoreFailure(code: .database, retryable: false) }
        _ = try store.upsertOperation(PendingOperation(operationID: operationID, replayKey: replayKey, kind: kind, itemIdentifier: itemIdentifier, sourceGeneration: 1))
        guard let operation = try store.operation(replayKey: replayKey) else { throw CoreFailure(code: .database, retryable: false) }
        return operation
    }

    private func uniqueName(_ name: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(name) (NimbusSync conflict \(stamp))"
    }
}

public enum ConflictResolutionAction: Sendable { case keepRemote, overwriteRemote, keepBoth }

public final class ConflictResolutionService: @unchecked Sendable {
    private let store: SQLiteStateStore
    private let backend: FileProviderBackend
    public init(store: SQLiteStateStore, backend: FileProviderBackend) { self.store = store; self.backend = backend }

    public func keepRemote(conflict: ConflictProjection) throws -> RemoteItem {
        guard let item = try backend.item(identifier: conflict.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        guard item.kind == .file else { throw CoreFailure(code: .awaitingSourceReplay, retryable: false, userActionRequired: true) }
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("nimbussync-conflict-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else { throw CoreFailure(code: .database, retryable: false) }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let refreshed = try backend.fetchContent(identifier: item.itemIdentifier, expectedVersion: nil, to: temporaryURL)
        _ = try store.commitProviderChange(item: refreshed, oldParentIdentifier: item.parentIdentifier, newParentIdentifier: refreshed.parentIdentifier, kind: "conflict_keep_remote", origin: "conflict_resolution")
        try store.resolveConflict(conflictID: conflict.conflictID, resolution: "keep_remote")
        try store.clearPending(item.itemIdentifier)
        return refreshed
    }

    public func prepareOverwriteRemote(conflict: ConflictProjection) throws {
        try store.markConflictResolutionPending(conflictID: conflict.conflictID, itemIdentifier: conflict.itemIdentifier, resolution: "overwrite_remote_pending")
    }

    public func prepareKeepBoth(conflict: ConflictProjection) throws {
        try store.markConflictResolutionPending(conflictID: conflict.conflictID, itemIdentifier: conflict.itemIdentifier, resolution: "keep_both_pending")
    }

    public func overwriteRemote(conflict: ConflictProjection, localContent: Data) throws -> RemoteItem {
        guard let current = try backend.item(identifier: conflict.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        if let remoteVersion = conflict.remoteVersion, current.version.content != remoteVersion {
            throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
        }
        let replayKey = "conflict-overwrite|\(conflict.conflictID.uuidString)"
        let operationID = operationID(for: replayKey)
        let operation = try beginOperation(operationID: operationID, replayKey: replayKey, kind: "conflict_overwrite", itemIdentifier: current.itemIdentifier)
        if let result = try committedResult(operation) { try store.resolveConflict(conflictID: conflict.conflictID, resolution: "overwrite_remote"); return result }
        guard try store.acquireOperationLease(operationID: operationID, owner: ownerID) else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
        let updated: RemoteItem
        do {
            updated = try backend.modify(item: current, expectedVersion: current.version.content, changedFields: [.contents], content: localContent, replayKey: replayKey)
            try store.commitOperationWithItem(operationID: operationID, state: "committed", item: updated, outcome: String(data: try JSONEncoder().encode(updated), encoding: .utf8))
        } catch {
            try? store.commitOperation(operationID: operationID, state: state(for: error), itemIdentifier: current.itemIdentifier)
            throw error
        }
        try store.resolveConflict(conflictID: conflict.conflictID, resolution: "overwrite_remote")
        return updated
    }

    public func keepBoth(conflict: ConflictProjection, localContent: Data, baseName: String) throws -> RemoteItem {
        guard let current = try backend.item(identifier: conflict.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        if let remoteVersion = conflict.remoteVersion, current.version.content != remoteVersion {
            throw CoreFailure(code: .versionConflict, retryable: false, userActionRequired: true)
        }
        let replayKey = "conflict-copy|\(conflict.conflictID.uuidString)"
        let copy = RemoteItem(itemIdentifier: CloudreveIdentifier.item(forTemplate: replayKey), remoteID: nil, parentIdentifier: current.parentIdentifier, name: uniqueName(baseName), uri: current.uri, kind: current.kind, contentType: current.contentType, size: Int64(localContent.count), version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: current.canWrite, canAddChildren: current.canAddChildren, canTrash: current.canTrash, canDelete: current.canDelete)
        let operationID = operationID(for: replayKey)
        let operation = try beginOperation(operationID: operationID, replayKey: replayKey, kind: "conflict_copy", itemIdentifier: copy.itemIdentifier)
        if let result = try committedResult(operation) { try store.resolveConflict(conflictID: conflict.conflictID, resolution: "keep_both"); return result }
        guard try store.acquireOperationLease(operationID: operationID, owner: ownerID) else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
        let created: RemoteItem
        do {
            created = try backend.create(template: copy, content: localContent, replayKey: replayKey)
            try store.commitOperationWithItem(operationID: operationID, state: "committed", item: created, outcome: String(data: try JSONEncoder().encode(created), encoding: .utf8))
        } catch {
            try? store.commitOperation(operationID: operationID, state: state(for: error), itemIdentifier: copy.itemIdentifier)
            throw error
        }
        try store.resolveConflict(conflictID: conflict.conflictID, resolution: "keep_both")
        return created
    }

    private let ownerID = UUID()

    private func beginOperation(operationID: UUID, replayKey: String, kind: String, itemIdentifier: String) throws -> StoredOperation {
        _ = try store.upsertOperation(PendingOperation(operationID: operationID, replayKey: replayKey, kind: kind, itemIdentifier: itemIdentifier, sourceGeneration: 1))
        guard let operation = try store.operation(replayKey: replayKey) else { throw CoreFailure(code: .database, retryable: false) }
        return operation
    }

    private func committedResult(_ operation: StoredOperation) throws -> RemoteItem? {
        guard operation.operation.state == "committed" else { return nil }
        guard let outcome = operation.outcome, let data = outcome.data(using: .utf8) else { throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true) }
        return try JSONDecoder().decode(RemoteItem.self, from: data)
    }

    private func operationID(for replayKey: String) -> UUID {
        let digest = CryptoKit.SHA256.hash(data: Data(replayKey.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))") ?? UUID()
    }

    private func state(for error: Error) -> String {
        if let failure = error as? CoreFailure {
            switch failure.code { case .versionConflict: return "conflict"; case .authentication: return "auth_expired"; default: return "unknown_outcome" }
        }
        return "unknown_outcome"
    }

    private func uniqueName(_ name: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
		return "\(name) (NimbusSync conflict \(stamp))"
    }
}
