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
        self.edgeDigest = Data(CryptoKit.SHA256.hash(data: Data(edge) + Data(String(content.count).utf8)))
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
            _ = try store.upsertRemoteItem(item)
            try store.commitOperation(operationID: replay.operationID, state: "committed", itemIdentifier: item.itemIdentifier, outcome: String(data: try JSONEncoder().encode(item), encoding: .utf8))
            return item
        } catch {
            try? store.commitOperation(operationID: replay.operationID, state: state(for: error), itemIdentifier: template.itemIdentifier)
            throw error
        }
    }

    public func modify(item: RemoteItem, baseVersion: NSFileProviderItemVersion, fields: NSFileProviderItemFields, contents: Data?, options: NSFileProviderModifyItemOptions) throws -> RemoteItem {
        guard let store else { return try backend.modify(item: item, expectedVersion: baseVersion.contentVersion, changedFields: fields, content: contents, replayKey: item.itemIdentifier) }
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
            _ = try store.upsertRemoteItem(updated)
            try store.commitOperation(operationID: replay.operationID, state: "committed", itemIdentifier: updated.itemIdentifier, outcome: String(data: try JSONEncoder().encode(updated), encoding: .utf8))
            return updated
        } catch {
            try? store.commitOperation(operationID: replay.operationID, state: state(for: error), itemIdentifier: item.itemIdentifier)
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
        if try store.consumeMatchingExclusionIntent(itemIdentifier: itemIdentifier, systemItemIdentifier: itemIdentifier, kind: .unsupportedLocalType, ruleRevision: 1, sourceGeneration: 1) { return }
        try ensureLease(operation)
        do {
            try backend.delete(identifier: itemIdentifier, expectedVersion: baseVersion.contentVersion, recursive: options.contains(.recursive))
            var tombstone = item
            tombstone.tombstone = true
            try store.insertItem(tombstone)
            try store.commitOperation(operationID: replay.operationID, state: "committed", itemIdentifier: itemIdentifier)
        } catch {
            try? store.commitOperation(operationID: replay.operationID, state: state(for: error), itemIdentifier: itemIdentifier)
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
        guard operation.operation.state == "committed" else { return nil }
        guard let outcome = operation.outcome, let data = outcome.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(RemoteItem.self, from: data)
    }

    private func ensureLease(_ operation: StoredOperation) throws {
        guard let store else { return }
        if operation.operation.state == "committed" { return }
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
            switch failure.code { case .versionConflict: return "conflict"; case .network: return "retry_wait"; case .authentication: return "auth_expired"; case .cancelled: return "cancelled"; default: return "unknown_outcome" }
        }
        return "unknown_outcome"
    }
}

public enum ConflictResolutionAction: Sendable { case keepRemote, overwriteRemote, keepBoth }

public final class ConflictResolutionService: @unchecked Sendable {
    private let store: SQLiteStateStore
    private let backend: FileProviderBackend
    public init(store: SQLiteStateStore, backend: FileProviderBackend) { self.store = store; self.backend = backend }

    public func keepRemote(conflict: ConflictProjection) throws -> RemoteItem {
        guard let item = try backend.item(identifier: conflict.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        try store.resolveConflict(conflictID: conflict.conflictID, resolution: "keep_remote")
        return item
    }

    public func overwriteRemote(conflict: ConflictProjection, localContent: Data) throws -> RemoteItem {
        guard let current = try backend.item(identifier: conflict.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        let updated = try backend.modify(item: current, expectedVersion: current.version.content, changedFields: [.contents], content: localContent, replayKey: "conflict-overwrite|\(conflict.conflictID.uuidString)")
        _ = try store.upsertRemoteItem(updated)
        try store.resolveConflict(conflictID: conflict.conflictID, resolution: "overwrite_remote")
        return updated
    }

    public func keepBoth(conflict: ConflictProjection, localContent: Data, baseName: String) throws -> RemoteItem {
        guard let current = try backend.item(identifier: conflict.itemIdentifier) else { throw CoreFailure(code: .notFound, retryable: false) }
        let copy = RemoteItem(itemIdentifier: CloudreveIdentifier.item(), remoteID: nil, parentIdentifier: current.parentIdentifier, name: uniqueName(baseName), uri: current.uri, kind: current.kind, contentType: current.contentType, size: Int64(localContent.count), version: ItemVersion(content: Data(), metadata: Data()), canRead: true, canWrite: current.canWrite, canAddChildren: current.canAddChildren, canTrash: current.canTrash, canDelete: current.canDelete)
        let created = try backend.create(template: copy, content: localContent, replayKey: "conflict-copy|\(conflict.conflictID.uuidString)")
        _ = try store.upsertRemoteItem(created)
        try store.resolveConflict(conflictID: conflict.conflictID, resolution: "keep_both")
        return created
    }

    private func uniqueName(_ name: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
		return "\(name) (NimbusSync conflict \(stamp))"
    }
}
