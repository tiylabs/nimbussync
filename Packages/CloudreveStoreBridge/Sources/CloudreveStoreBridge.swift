import Foundation
import FileProvider
import CSQLite
import CloudreveDomainKit

public enum StoreBridgeError: Error, Equatable {
    case openFailed(String)
    case sql(String)
    case schemaFenced
    case corrupted
    case unknownDomain
}

public struct SchemaFence: Equatable, Sendable {
    public let version: Int
    public let generation: Int
    public let compatibilityMinimum: Int
    public let compatibilityMaximum: Int
    public let migrationState: String
    public init(version: Int, generation: Int, compatibilityMinimum: Int, compatibilityMaximum: Int, migrationState: String) { self.version = version; self.generation = generation; self.compatibilityMinimum = compatibilityMinimum; self.compatibilityMaximum = compatibilityMaximum; self.migrationState = migrationState }
    public func permits(processGeneration: Int, schemaVersion: Int) -> Bool { migrationState == "ready" && processGeneration == generation && schemaVersion >= compatibilityMinimum && schemaVersion <= compatibilityMaximum }
}

public struct JournalChange: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let epoch: UUID
    public let itemIdentifier: String
    public let oldParentIdentifier: String?
    public let newParentIdentifier: String?
    public let kind: String
    public let version: Data
    public let origin: String
    public let providerVisible: Bool
    public init(sequence: Int64, epoch: UUID, itemIdentifier: String, oldParentIdentifier: String?, newParentIdentifier: String?, kind: String, version: Data, origin: String, providerVisible: Bool) {
        self.sequence = sequence; self.epoch = epoch; self.itemIdentifier = itemIdentifier; self.oldParentIdentifier = oldParentIdentifier; self.newParentIdentifier = newParentIdentifier; self.kind = kind; self.version = version; self.origin = origin; self.providerVisible = providerVisible
    }
}

public struct JournalBatch: Equatable, Sendable {
    public let changes: [JournalChange]
    public let nextAnchor: SyncAnchor
    public let moreComing: Bool
    public init(changes: [JournalChange], nextAnchor: SyncAnchor, moreComing: Bool) { self.changes = changes; self.nextAnchor = nextAnchor; self.moreComing = moreComing }
}

public struct DirectoryPage: Equatable, Sendable {
    public let items: [RemoteItem]
    public let nextOffset: Int?
    public let generation: UInt64
    public let complete: Bool
    public init(items: [RemoteItem], nextOffset: Int?, generation: UInt64, complete: Bool) { self.items = items; self.nextOffset = nextOffset; self.generation = generation; self.complete = complete }
}

public struct PendingOperation: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let replayKey: String
    public let kind: String
    public let itemIdentifier: String?
    public var state: String
    public var sourceGeneration: UInt64
    public var cancelRequested: Bool
    public init(operationID: UUID = UUID(), replayKey: String, kind: String, itemIdentifier: String? = nil, state: String = "queued", sourceGeneration: UInt64 = 0, cancelRequested: Bool = false) {
        self.operationID = operationID; self.replayKey = replayKey; self.kind = kind; self.itemIdentifier = itemIdentifier; self.state = state; self.sourceGeneration = sourceGeneration; self.cancelRequested = cancelRequested
    }
}

public struct StoredOperation: Codable, Equatable, Sendable {
    public let operation: PendingOperation
    public let outcome: String?
    public let leaseOwner: UUID?
    public let leaseExpiresAt: Date?
    public let attempt: Int
    public init(operation: PendingOperation, outcome: String?, leaseOwner: UUID?, leaseExpiresAt: Date?, attempt: Int) { self.operation = operation; self.outcome = outcome; self.leaseOwner = leaseOwner; self.leaseExpiresAt = leaseExpiresAt; self.attempt = attempt }
}

public struct StoredDomain: Codable, Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let origin: String
    public let accountID: String
    public let rootRemoteID: String
    public let rootURI: String
    public let scopeKey: String
    public let status: DomainStatus
    public let secretReference: String
    public let capabilitySnapshot: CapabilitySnapshot
    public init(identifier: String, displayName: String, origin: String, accountID: String, rootRemoteID: String, rootURI: String, scopeKey: String, status: DomainStatus, secretReference: String, capabilitySnapshot: CapabilitySnapshot) {
        self.identifier = identifier; self.displayName = displayName; self.origin = origin; self.accountID = accountID; self.rootRemoteID = rootRemoteID; self.rootURI = rootURI; self.scopeKey = scopeKey; self.status = status; self.secretReference = secretReference; self.capabilitySnapshot = capabilitySnapshot
    }
}

public struct ExclusionIntent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case localCreate = "local_create", unsupportedLocalType = "unsupported_local_type", remoteViewFilter = "remote_view_filter" }
    public let intentID: UUID
    public let itemIdentifier: String?
    public let systemItemIdentifier: String?
    public let ruleRevision: UInt64
    public let kind: Kind
    public let sourceGeneration: UInt64
    public var state: String
    public init(intentID: UUID = UUID(), itemIdentifier: String?, systemItemIdentifier: String?, ruleRevision: UInt64, kind: Kind, sourceGeneration: UInt64, state: String = "active") {
        self.intentID = intentID; self.itemIdentifier = itemIdentifier; self.systemItemIdentifier = systemItemIdentifier; self.ruleRevision = ruleRevision; self.kind = kind; self.sourceGeneration = sourceGeneration; self.state = state
    }
}

public struct UploadPartCheckpoint: Codable, Equatable, Sendable {
    public let index: Int
    public let offset: Int64
    public let length: Int64
    public var sourceHash: Data
    public var etag: String?
    public var state: String
    public var attempt: Int
    public init(index: Int, offset: Int64, length: Int64, sourceHash: Data, etag: String? = nil, state: String = "pending", attempt: Int = 0) {
        self.index = index; self.offset = offset; self.length = length; self.sourceHash = sourceHash; self.etag = etag; self.state = state; self.attempt = attempt
    }
}

public struct UploadSessionCheckpoint: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let remoteSessionReference: String?
    public let secretReference: String?
    public let fingerprint: Data
    public let provider: String
    public let chunkSize: Int64
    public let expiresAt: Date?
    public var state: String
    public var parts: [UploadPartCheckpoint]
    public init(operationID: UUID, remoteSessionReference: String?, secretReference: String?, fingerprint: Data, provider: String, chunkSize: Int64, expiresAt: Date?, state: String = "active", parts: [UploadPartCheckpoint] = []) {
        self.operationID = operationID; self.remoteSessionReference = remoteSessionReference; self.secretReference = secretReference; self.fingerprint = fingerprint; self.provider = provider; self.chunkSize = chunkSize; self.expiresAt = expiresAt; self.state = state; self.parts = parts
    }
    public func canResume(fingerprint: Data, now: Date = Date()) -> Bool { self.fingerprint == fingerprint && (expiresAt == nil || expiresAt! > now) && state != "abandoned" }
}

public struct ConflictProjection: Codable, Equatable, Sendable {
    public let conflictID: UUID
    public let itemIdentifier: String
    public let kind: String
    public let baseSummary: String
    public let remoteSummary: String
    public let localSummary: String
    public let pendingItemIdentifier: String?
    public let sourceGeneration: UInt64
    public var state: String
    public init(conflictID: UUID = UUID(), itemIdentifier: String, kind: String, baseSummary: String, remoteSummary: String, localSummary: String, pendingItemIdentifier: String?, sourceGeneration: UInt64, state: String = "pending") {
        self.conflictID = conflictID; self.itemIdentifier = itemIdentifier; self.kind = kind; self.baseSummary = baseSummary; self.remoteSummary = remoteSummary; self.localSummary = localSummary; self.pendingItemIdentifier = pendingItemIdentifier; self.sourceGeneration = sourceGeneration; self.state = state
    }
}

public final class SQLiteStateStore: @unchecked Sendable {
    public static let schemaVersion = 1
    private var database: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else { throw StoreBridgeError.openFailed("sqlite3_open_v2: \(result)") }
        database = handle
        do { try configure(); try migrate() } catch { sqlite3_close(handle); database = nil; throw error }
    }

    deinit { if let database { sqlite3_close(database) } }

    public func quickCheck() throws -> Bool {
        try withLock {
            let value = try scalar("PRAGMA quick_check")
            return value == "ok"
        }
    }

    public func schemaFence() throws -> SchemaFence {
        try withLock {
            let statement = try prepare("SELECT version, generation, compat_min, compat_max, migration_state FROM schema_meta WHERE singleton = 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreBridgeError.schemaFenced }
            return SchemaFence(version: Int(sqlite3_column_int(statement, 0)), generation: Int(sqlite3_column_int(statement, 1)), compatibilityMinimum: Int(sqlite3_column_int(statement, 2)), compatibilityMaximum: Int(sqlite3_column_int(statement, 3)), migrationState: columnString(statement, 4) ?? "unknown")
        }
    }

    public func beginMigration(targetVersion: Int, compatibilityMinimum: Int, compatibilityMaximum: Int) throws {
        try withLock { try execute("UPDATE schema_meta SET migration_state = 'preparing', version = \(targetVersion), compat_min = \(compatibilityMinimum), compat_max = \(compatibilityMaximum) WHERE singleton = 1") }
    }

    public func publishMigration(generation: Int) throws {
        try withLock { try execute("UPDATE schema_meta SET generation = \(generation), migration_state = 'ready' WHERE singleton = 1") }
    }

    public func isolateForRepair() throws -> URL? {
        try withLock {
            guard let path = sqlite3_db_filename(database, "main") else { return nil }
            let original = URL(fileURLWithPath: String(cString: path))
            let repairURL = original.deletingLastPathComponent().appendingPathComponent("repair-\(UUID().uuidString)-\(original.lastPathComponent)")
            try FileManager.default.moveItem(at: original, to: repairURL)
            return repairURL
        }
    }

    public func migrate() throws {
        try withLock {
            try execute(Schema.sql)
            let version = Int(try scalar("SELECT version FROM schema_meta WHERE singleton = 1") ?? "0") ?? 0
            guard version == Self.schemaVersion else { throw StoreBridgeError.schemaFenced }
        }
    }

    public func backup(to destination: URL) throws {
        try withLock {
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(atPath: databaseURL.path, toPath: destination.path)
        }
    }

    private var databaseURL: URL {
        guard let database, let filename = sqlite3_db_filename(database, "main") else {
            return URL(fileURLWithPath: "/dev/null")
        }
        return URL(fileURLWithPath: String(cString: filename))
    }

    public func registerDomain(_ descriptor: DomainDescriptor) throws {
        try withLock {
            let json = try JSONEncoder().encode(descriptor.capabilitySnapshot)
            let scopeKey = descriptor.scope.key.replacingOccurrences(of: "\u{0}", with: "|")
            try execute("INSERT OR REPLACE INTO domains (domain_id, display_name, origin, account_id, root_entity_id, root_uri, scope_key, status, secret_ref, capability_revision, capability_snapshot) VALUES ('\(sql(descriptor.identifier))', '\(sql(descriptor.displayName))', '\(sql(descriptor.scope.origin))', '\(sql(descriptor.accountID))', '\(sql(descriptor.rootRemoteID))', '\(sql(descriptor.currentRootURI))', '\(sql(scopeKey))', '\(descriptor.status.rawValue)', '\(sql(descriptor.secretReference))', \(descriptor.capabilitySnapshot.revision), '\(sql(String(data: json, encoding: .utf8) ?? "{}"))')")
            try execute("INSERT OR IGNORE INTO sync_state (singleton, epoch, next_sequence, min_valid_sequence, domain_version_revision, reconcile_status) VALUES (1, '\(UUID().uuidString)', 1, 0, 0, 'initializing')")
        }
    }

    public func domain(identifier: String) throws -> StoredDomain? {
        try withLock {
            let statement = try prepare("SELECT domain_id, display_name, origin, account_id, root_entity_id, root_uri, scope_key, status, secret_ref, capability_snapshot FROM domains WHERE domain_id = '\(sql(identifier))' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let snapshotData = Data((columnString(statement, 9) ?? "{}").utf8)
			return StoredDomain(identifier: columnString(statement, 0) ?? identifier, displayName: columnString(statement, 1) ?? "NimbusSync", origin: columnString(statement, 2) ?? "", accountID: columnString(statement, 3) ?? "", rootRemoteID: columnString(statement, 4) ?? "", rootURI: columnString(statement, 5) ?? "/", scopeKey: columnString(statement, 6) ?? "", status: DomainStatus(rawValue: columnString(statement, 7) ?? "initializing") ?? .initializing, secretReference: columnString(statement, 8) ?? "", capabilitySnapshot: (try? JSONDecoder().decode(CapabilitySnapshot.self, from: snapshotData)) ?? CapabilitySnapshot())
        }
    }

    public func allDomains() throws -> [StoredDomain] {
        try withLock {
            let statement = try prepare("SELECT domain_id, display_name, origin, account_id, root_entity_id, root_uri, scope_key, status, secret_ref, capability_snapshot FROM domains ORDER BY display_name COLLATE NOCASE")
            defer { sqlite3_finalize(statement) }
            var domains: [StoredDomain] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let snapshotData = Data((columnString(statement, 9) ?? "{}").utf8)
				domains.append(StoredDomain(identifier: columnString(statement, 0) ?? "", displayName: columnString(statement, 1) ?? "NimbusSync", origin: columnString(statement, 2) ?? "", accountID: columnString(statement, 3) ?? "", rootRemoteID: columnString(statement, 4) ?? "", rootURI: columnString(statement, 5) ?? "/", scopeKey: columnString(statement, 6) ?? "", status: DomainStatus(rawValue: columnString(statement, 7) ?? "initializing") ?? .initializing, secretReference: columnString(statement, 8) ?? "", capabilitySnapshot: (try? JSONDecoder().decode(CapabilitySnapshot.self, from: snapshotData)) ?? CapabilitySnapshot()))
            }
            return domains
        }
    }

    public func setDomainStatus(identifier: String, status: DomainStatus) throws {
        try withLock { try execute("UPDATE domains SET status = '\(status.rawValue)' WHERE domain_id = '\(sql(identifier))'") }
    }

    public func recordHeartbeat(role: String, instanceID: UUID, bundleVersion: String, schemaGeneration: Int64, at date: Date = Date()) throws {
        try withLock { try execute("INSERT OR REPLACE INTO process_heartbeats (role, instance_id, bundle_version, schema_generation, last_seen) VALUES ('\(sql(role))', '\(instanceID.uuidString)', '\(sql(bundleVersion))', \(schemaGeneration), \(Int64(date.timeIntervalSince1970)))") }
    }

    public func heartbeat(role: String) throws -> Date? {
        try withLock { guard let value = try scalar("SELECT last_seen FROM process_heartbeats WHERE role = '\(sql(role))' LIMIT 1"), let timestamp = TimeInterval(value) else { return nil }; return Date(timeIntervalSince1970: timestamp) }
    }

    public func updateSyncState(eventClientID: String? = nil, eventAt: Date? = nil, reconcileAt: Date? = nil, reconcileStatus: String? = nil) throws {
        try withLock {
            var assignments: [String] = []
            if let eventClientID { assignments.append("event_client_id = '\(sql(eventClientID))'") }
            if let eventAt { assignments.append("last_event_at = \(Int64(eventAt.timeIntervalSince1970))") }
            if let reconcileAt { assignments.append("last_reconcile_at = \(Int64(reconcileAt.timeIntervalSince1970))") }
            if let reconcileStatus { assignments.append("reconcile_status = '\(sql(reconcileStatus))'") }
            if !assignments.isEmpty { try execute("UPDATE sync_state SET \(assignments.joined(separator: ", ")) WHERE singleton = 1") }
        }
    }

    public func startReconcile(runID: UUID, scope: String, generation: UInt64, phase: String, cursor: String?) throws {
        try withLock { try execute("INSERT OR REPLACE INTO reconcile_runs (run_id, scope, generation, phase, cursor, state, started_at) VALUES ('\(runID.uuidString)', '\(sql(scope))', \(generation), '\(sql(phase))', \(nullable(cursor)), 'active', unixepoch())") }
    }

    public func updateReconcile(runID: UUID, phase: String, cursor: String?, state: String) throws {
        try withLock { try execute("UPDATE reconcile_runs SET phase = '\(sql(phase))', cursor = \(nullable(cursor)), state = '\(sql(state))', completed_at = \(state == "completed" || state == "failed" ? "unixepoch()" : "NULL") WHERE run_id = '\(runID.uuidString)'") }
    }

    public func activeReconcileRuns() throws -> [(id: UUID, phase: String, cursor: String?, state: String)] {
        try withLock {
            let statement = try prepare("SELECT run_id, phase, cursor, state FROM reconcile_runs WHERE state = 'active' ORDER BY started_at")
            defer { sqlite3_finalize(statement) }
            var result: [(id: UUID, phase: String, cursor: String?, state: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append((UUID(uuidString: columnString(statement, 0) ?? "") ?? UUID(), columnString(statement, 1) ?? "prepared", columnString(statement, 2), columnString(statement, 3) ?? "active")) }
            return result
        }
    }

    public func syncState() throws -> (epoch: UUID, minSequence: Int64, currentSequence: Int64, eventClientID: String?, lastEventAt: Date?, lastReconcileAt: Date?, reconcileStatus: String) {
        try withLock {
            let statement = try prepare("SELECT epoch, min_valid_sequence, next_sequence, event_client_id, last_event_at, last_reconcile_at, reconcile_status FROM sync_state WHERE singleton = 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StoreBridgeError.unknownDomain }
            return (UUID(uuidString: columnString(statement, 0) ?? "") ?? UUID(), sqlite3_column_int64(statement, 1), sqlite3_column_int64(statement, 2).saturatingSub(1), columnString(statement, 3), sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))), sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5))), columnString(statement, 6) ?? "initializing")
        }
    }

    public func beginProvisioning(domainID: String, actionID: UUID = UUID()) throws {
        try withLock { try execute("INSERT OR REPLACE INTO domain_actions (action_id, domain_id, kind, step, state, error) VALUES ('\(actionID.uuidString)', '\(sql(domainID))', 'provision', 'prepared', 'active', NULL)") }
    }

    public func advanceProvisioning(domainID: String, step: DomainProvisioningStep, error: String? = nil) throws {
        try withLock { try execute("UPDATE domain_actions SET step = '\(step.rawValue)', state = '\(step == .rollbackRequired ? "rollback_required" : "active")', error = \(nullable(error)), updated_at = unixepoch() WHERE domain_id = '\(sql(domainID))' AND kind = 'provision' AND state IN ('active', 'rollback_required')") }
    }

    public func incompleteProvisioning() throws -> [DomainProvisioningRecord] {
        try withLock {
            let statement = try prepare("SELECT action_id, domain_id, step, error FROM domain_actions WHERE kind = 'provision' AND state != 'completed'")
            defer { sqlite3_finalize(statement) }
            var records: [DomainProvisioningRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(DomainProvisioningRecord(actionID: UUID(uuidString: columnString(statement, 0) ?? "") ?? UUID(), domainID: columnString(statement, 1) ?? "", step: DomainProvisioningStep(rawValue: columnString(statement, 2) ?? "prepared") ?? .prepared, systemDomainSeen: false, errorCode: columnString(statement, 3)))
            }
            return records
        }
    }

    public func finishProvisioning(domainID: String) throws {
        try withLock { try execute("UPDATE domain_actions SET step = 'registered', state = 'completed', updated_at = unixepoch() WHERE domain_id = '\(sql(domainID))' AND kind = 'provision'") }
    }

    public func removeDomainRecord(identifier: String) throws {
        try withLock { try execute("DELETE FROM domains WHERE domain_id = '\(sql(identifier))'"); try execute("DELETE FROM domain_actions WHERE domain_id = '\(sql(identifier))'") }
    }

    public func setPreference(key: String, value: String) throws {
        try withLock { try execute("INSERT OR REPLACE INTO preferences (key, value, updated_at) VALUES ('\(sql(key))', '\(sql(value))', unixepoch())") }
    }

    public func preference(key: String) throws -> String? {
        try withLock { try scalar("SELECT value FROM preferences WHERE key = '\(sql(key))' LIMIT 1") }
    }

    public func insertItem(_ item: RemoteItem) throws {
        try withLock {
            let content = item.version.content.hexString
            let metadata = item.version.metadata.hexString
            try execute("INSERT OR REPLACE INTO items (item_uuid, remote_entity_id, parent_uuid, remote_name, kind, current_remote_uri, content_version, metadata_version, size, remote_version, trashed, tombstone) VALUES ('\(sql(item.itemIdentifier))', \(nullable(item.remoteID)), \(nullable(item.parentIdentifier)), '\(sql(item.name))', '\(item.kind.rawValue)', '\(sql(item.uri))', X'\(content)', X'\(metadata)', \(item.size), \(nullable(item.remoteVersion)), \(item.trashed ? 1 : 0), \(item.tombstone ? 1 : 0))")
        }
    }

    public func item(identifier: String) throws -> RemoteItem? {
        try withLock {
            let statement = try prepare("SELECT item_uuid, remote_entity_id, parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone FROM items WHERE item_uuid = '\(sql(identifier))' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return itemFromStatement(statement)
        }
    }

    public func itemIdentifier(forRemoteID remoteID: String) throws -> String? {
        try withLock { try scalar("SELECT item_uuid FROM items WHERE remote_entity_id = '\(sql(remoteID))' AND tombstone = 0 LIMIT 1") }
    }

    public func upsertRemoteItem(_ item: RemoteItem) throws -> RemoteItem {
        let stable: RemoteItem
        if let remoteID = item.remoteID, let identifier = try itemIdentifier(forRemoteID: remoteID) {
            stable = item.withIdentity(identifier)
        } else {
            stable = item
        }
        try insertItem(stable)
        return stable
    }

    public func listChildren(parentIdentifier: String) throws -> [RemoteItem] {
        try withLock {
            let statement = try prepare("SELECT item_uuid, remote_entity_id, parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone FROM items WHERE parent_uuid = '\(sql(parentIdentifier))' AND tombstone = 0 ORDER BY remote_name COLLATE NOCASE, item_uuid")
            defer { sqlite3_finalize(statement) }
            var result: [RemoteItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(itemFromStatement(statement))
            }
            return result
        }
    }

    public func listChildrenPage(parentIdentifier: String, offset: Int, limit: Int) throws -> DirectoryPage {
        try withLock {
            let boundedLimit = max(1, min(limit, 500))
            let statement = try prepare("SELECT item_uuid, remote_entity_id, parent_uuid, remote_name, kind, current_remote_uri, size, remote_version, content_version, metadata_version, trashed, tombstone FROM items WHERE parent_uuid = '\(sql(parentIdentifier))' AND tombstone = 0 ORDER BY remote_name COLLATE NOCASE, item_uuid LIMIT \(boundedLimit + 1) OFFSET \(max(0, offset))")
            defer { sqlite3_finalize(statement) }
            var result: [RemoteItem] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(itemFromStatement(statement)) }
            let hasMore = result.count > boundedLimit
            if hasMore { result.removeLast() }
            return DirectoryPage(items: result, nextOffset: hasMore ? offset + result.count : nil, generation: 1, complete: !hasMore)
        }
    }

    public func markSnapshotComplete(parentIdentifier: String, generation: UInt64, serverCursor: String? = nil) throws {
        try withLock { try execute("INSERT OR REPLACE INTO directory_snapshots (parent_uuid, snapshot_generation, order_key, complete, server_cursor) VALUES ('\(sql(parentIdentifier))', \(generation), 'name,id', 1, \(nullable(serverCursor)))") }
    }

    public func recordSnapshotProgress(parentIdentifier: String, generation: UInt64, nextCursor: String?, complete: Bool) throws {
        try withLock { try execute("INSERT OR REPLACE INTO directory_snapshots (parent_uuid, snapshot_generation, order_key, complete, server_cursor) VALUES ('\(sql(parentIdentifier))', \(generation), 'name,id', \(complete ? 1 : 0), \(nullable(nextCursor)) )") }
    }

    public func snapshotCursor(parentIdentifier: String, generation: UInt64 = 1) throws -> String? {
        try withLock { try scalar("SELECT server_cursor FROM directory_snapshots WHERE parent_uuid = '\(sql(parentIdentifier))' AND snapshot_generation = \(generation) AND complete = 0 LIMIT 1") }
    }

    public func hasCompleteSnapshot(parentIdentifier: String) throws -> Bool {
        try withLock { (try scalar("SELECT complete FROM directory_snapshots WHERE parent_uuid = '\(sql(parentIdentifier))' LIMIT 1") ?? "0") == "1" }
    }

    public func appendProviderChange(itemIdentifier: String, oldParentIdentifier: String?, newParentIdentifier: String?, kind: String, version: Data, origin: String) throws -> JournalChange {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let sequence = Int64(try scalar("SELECT next_sequence FROM sync_state WHERE singleton = 1") ?? "0") ?? 0
                let epochString = try scalar("SELECT epoch FROM sync_state WHERE singleton = 1") ?? UUID().uuidString
                let epoch = UUID(uuidString: epochString) ?? UUID()
                try execute("INSERT INTO change_journal (sequence, epoch, item_uuid, old_parent_uuid, new_parent_uuid, change_kind, version, origin, delivery_audience) VALUES (\(sequence), '\(epoch.uuidString)', '\(sql(itemIdentifier))', \(nullable(oldParentIdentifier)), \(nullable(newParentIdentifier)), '\(sql(kind))', X'\(version.hexString)', '\(sql(origin))', 'working_set')")
                try execute("INSERT OR REPLACE INTO signal_outbox (signal_id, working_set_revision, state, attempt) VALUES ('\(UUID().uuidString)', \(sequence), 'pending', 0)")
                try execute("UPDATE sync_state SET next_sequence = \(sequence + 1), domain_version_revision = domain_version_revision + 1 WHERE singleton = 1")
                try execute("COMMIT")
                return JournalChange(sequence: sequence, epoch: epoch, itemIdentifier: itemIdentifier, oldParentIdentifier: oldParentIdentifier, newParentIdentifier: newParentIdentifier, kind: kind, version: version, origin: origin, providerVisible: true)
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func currentAnchor(domainIdentifier: String, scope: String) throws -> SyncAnchor {
        try withLock {
            let epoch = UUID(uuidString: try scalar("SELECT epoch FROM sync_state WHERE singleton = 1") ?? "") ?? UUID()
            let nextSequence = Int64(try scalar("SELECT next_sequence FROM sync_state WHERE singleton = 1") ?? "0") ?? 0
            let sequence = UInt64(max(0, nextSequence - 1))
            return SyncAnchor(domainIdentifier: domainIdentifier, scope: scope, epoch: epoch, sequence: sequence)
        }
    }

    public func enumerateChanges(domainIdentifier: String, scope: String, from anchor: SyncAnchor, limit: Int = 200) throws -> JournalBatch {
        try withLock {
            let current = try currentAnchorUnlocked(domainIdentifier: domainIdentifier, scope: scope)
            guard anchor.domainIdentifier == domainIdentifier, anchor.scope == scope, anchor.epoch == current.epoch else { throw StoreBridgeError.schemaFenced }
            let minimum = UInt64(max(0, Int64(try scalar("SELECT min_valid_sequence FROM sync_state WHERE singleton = 1") ?? "0") ?? 0))
            guard anchor.sequence >= minimum else { throw StoreBridgeError.schemaFenced }
            let statement = try prepare("SELECT sequence, epoch, item_uuid, old_parent_uuid, new_parent_uuid, change_kind, version, origin FROM change_journal WHERE sequence > \(anchor.sequence) ORDER BY sequence ASC LIMIT \(max(1, min(limit, 1000)))")
            defer { sqlite3_finalize(statement) }
            var changes: [JournalChange] = []
            var scannedLast = Int64(anchor.sequence)
            while sqlite3_step(statement) == SQLITE_ROW {
                scannedLast = sqlite3_column_int64(statement, 0)
                let epoch = UUID(uuidString: columnString(statement, 1) ?? "") ?? current.epoch
                let oldParent = columnString(statement, 3)
                let newParent = columnString(statement, 4)
                let kind = columnString(statement, 5) ?? ""
                let isWorkingSet = scope == NSFileProviderItemIdentifier.workingSet.rawValue
                let isInContainer = oldParent == scope || newParent == scope
                if isWorkingSet || isInContainer {
                    changes.append(JournalChange(sequence: sqlite3_column_int64(statement, 0), epoch: epoch, itemIdentifier: columnString(statement, 2) ?? "", oldParentIdentifier: oldParent, newParentIdentifier: newParent, kind: kind, version: columnBlob(statement, 6), origin: columnString(statement, 7) ?? "", providerVisible: true))
                }
            }
            let remaining = Int(try scalar("SELECT COUNT(*) FROM change_journal WHERE sequence > \(scannedLast)") ?? "0") ?? 0
            return JournalBatch(changes: changes, nextAnchor: SyncAnchor(domainIdentifier: domainIdentifier, scope: scope, epoch: current.epoch, sequence: UInt64(max(0, scannedLast))), moreComing: remaining > 0)
        }
    }

    public func pendingOutboxCount() throws -> Int {
        try withLock { Int(try scalar("SELECT COUNT(*) FROM signal_outbox WHERE state = 'pending'") ?? "0") ?? 0 }
    }

    public func latestPendingOutboxRevision() throws -> Int64? {
        try withLock {
            guard let value = try scalar("SELECT MAX(working_set_revision) FROM signal_outbox WHERE state = 'pending'") else { return nil }
            return Int64(value)
        }
    }

    public func acknowledgeOutbox(upTo revision: Int64) throws {
        try withLock { try execute("UPDATE signal_outbox SET state = 'acknowledged', acknowledged_at = unixepoch() WHERE working_set_revision <= \(revision)") }
    }

    public func compactJournal(hardLimit: Int64 = 1_000_000, retain: Int64 = 100_000) throws {
        try withLock {
            let count = Int64(try scalar("SELECT COUNT(*) FROM change_journal") ?? "0") ?? 0
            guard count > hardLimit else { return }
            let minimum = max(0, count - retain)
            try execute("DELETE FROM change_journal WHERE sequence < \(minimum)")
            try execute("UPDATE sync_state SET min_valid_sequence = \(minimum)")
        }
    }

    public func pendingSetState() throws -> (count: Int, capped: Bool) {
        try withLock {
            let count = Int(try scalar("SELECT COUNT(*) FROM pending_items") ?? "0") ?? 0
            return (count, false)
        }
    }

    public func setMaterialized(_ itemIdentifier: String, materialized: Bool) throws {
        try withLock { try execute("INSERT OR REPLACE INTO materialized_containers (item_uuid, is_materialized) VALUES ('\(sql(itemIdentifier))', \(materialized ? 1 : 0))") }
    }

    public func setPending(_ itemIdentifier: String, templateIdentifier: String?, uploadError: String? = nil, downloadError: String? = nil) throws {
        try withLock { try execute("INSERT OR REPLACE INTO pending_items (item_uuid, template_id, upload_error, download_error) VALUES ('\(sql(itemIdentifier))', \(nullable(templateIdentifier)), \(nullable(uploadError)), \(nullable(downloadError))") }
    }

    public func createExclusionIntent(_ intent: ExclusionIntent) throws {
        try withLock {
            try execute("INSERT INTO exclusion_intents (intent_id, item_uuid, system_item_identifier, rule_revision, kind, source_generation, state) VALUES ('\(intent.intentID.uuidString)', \(nullable(intent.itemIdentifier)), \(nullable(intent.systemItemIdentifier)), \(intent.ruleRevision), '\(intent.kind.rawValue)', \(intent.sourceGeneration), 'active')")
        }
    }

    public func consumeMatchingExclusionIntent(itemIdentifier: String?, systemItemIdentifier: String?, kind: ExclusionIntent.Kind, ruleRevision: UInt64, sourceGeneration: UInt64) throws -> Bool {
        try withLock {
            let itemClause = itemIdentifier.map { "item_uuid = '\(sql($0))'" } ?? "item_uuid IS NULL"
            let systemClause = systemItemIdentifier.map { "system_item_identifier = '\(sql($0))'" } ?? "system_item_identifier IS NULL"
            let query = "SELECT intent_id FROM exclusion_intents WHERE \(itemClause) AND \(systemClause) AND kind = '\(kind.rawValue)' AND rule_revision = \(ruleRevision) AND source_generation = \(sourceGeneration) AND state = 'active' LIMIT 1"
            guard let id = try scalar(query) else { return false }
            try execute("UPDATE exclusion_intents SET state = 'consumed', consumed_at = unixepoch() WHERE intent_id = '\(sql(id))'")
            return true
        }
    }

    public func saveUploadSession(_ session: UploadSessionCheckpoint) throws {
        try withLock {
            try execute("INSERT OR REPLACE INTO upload_sessions (operation_id, remote_session_ref, secret_ref, fingerprint, provider, chunk_size, expires_at, state) VALUES ('\(session.operationID.uuidString)', \(nullable(session.remoteSessionReference)), \(nullable(session.secretReference)), X'\(session.fingerprint.hexString)', '\(sql(session.provider))', \(session.chunkSize), \(session.expiresAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "NULL"), '\(sql(session.state))')")
            try execute("DELETE FROM upload_parts WHERE operation_id = '\(session.operationID.uuidString)'")
            for part in session.parts {
                try execute("INSERT INTO upload_parts (operation_id, part_index, offset, length, source_hash, etag, state, attempt) VALUES ('\(session.operationID.uuidString)', \(part.index), \(part.offset), \(part.length), X'\(part.sourceHash.hexString)', \(nullable(part.etag)), '\(sql(part.state))', \(part.attempt))")
            }
        }
    }

    public func uploadSession(operationID: UUID) throws -> UploadSessionCheckpoint? {
        try withLock {
            let statement = try prepare("SELECT remote_session_ref, secret_ref, fingerprint, provider, chunk_size, expires_at, state FROM upload_sessions WHERE operation_id = '\(operationID.uuidString)' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let remoteReference = columnString(statement, 0)
            let secretReference = columnString(statement, 1)
            let fingerprint = columnBlob(statement, 2)
            let provider = columnString(statement, 3) ?? "unknown"
            let chunkSize = sqlite3_column_int64(statement, 4)
            let expiresAt = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5)))
            let state = columnString(statement, 6) ?? "active"
            let partsStatement = try prepare("SELECT part_index, offset, length, source_hash, etag, state, attempt FROM upload_parts WHERE operation_id = '\(operationID.uuidString)' ORDER BY part_index")
            defer { sqlite3_finalize(partsStatement) }
            var parts: [UploadPartCheckpoint] = []
            while sqlite3_step(partsStatement) == SQLITE_ROW {
                parts.append(UploadPartCheckpoint(index: Int(sqlite3_column_int(partsStatement, 0)), offset: sqlite3_column_int64(partsStatement, 1), length: sqlite3_column_int64(partsStatement, 2), sourceHash: columnBlob(partsStatement, 3), etag: columnString(partsStatement, 4), state: columnString(partsStatement, 5) ?? "pending", attempt: Int(sqlite3_column_int(partsStatement, 6))))
            }
            return UploadSessionCheckpoint(operationID: operationID, remoteSessionReference: remoteReference, secretReference: secretReference, fingerprint: fingerprint, provider: provider, chunkSize: chunkSize, expiresAt: expiresAt, state: state, parts: parts)
        }
    }

    public func saveConflict(_ conflict: ConflictProjection) throws {
        try withLock { try execute("INSERT OR REPLACE INTO conflicts (conflict_id, item_uuid, kind, base_metadata, remote_metadata, local_metadata, pending_item_id, source_generation, state, resolution) VALUES ('\(conflict.conflictID.uuidString)', '\(sql(conflict.itemIdentifier))', '\(sql(conflict.kind))', '\(sql(conflict.baseSummary))', '\(sql(conflict.remoteSummary))', '\(sql(conflict.localSummary))', \(nullable(conflict.pendingItemIdentifier)), \(conflict.sourceGeneration), '\(sql(conflict.state))', NULL)") }
    }

    public func resolveConflict(conflictID: UUID, resolution: String) throws {
        try withLock { try execute("UPDATE conflicts SET state = 'resolved', resolution = '\(sql(resolution))' WHERE conflict_id = '\(conflictID.uuidString)'") }
    }

    public func pendingConflictCount() throws -> Int { try withLock { Int(try scalar("SELECT COUNT(*) FROM conflicts WHERE state = 'pending'") ?? "0") ?? 0 } }

    public func upsertOperation(_ operation: PendingOperation) throws -> PendingOperation {
        try withLock {
            if let existing = try storedOperation(replayKey: operation.replayKey) { return existing.operation }
            let encoded = try JSONEncoder().encode(operation).base64EncodedString()
            try execute("INSERT INTO operations (operation_id, replay_key, kind, item_uuid, state, source_generation, cancel_requested, outcome, created_at, updated_at) VALUES ('\(operation.operationID.uuidString)', '\(sql(operation.replayKey))', '\(sql(operation.kind))', \(nullable(operation.itemIdentifier)), '\(sql(operation.state))', \(operation.sourceGeneration), \(operation.cancelRequested ? 1 : 0), '\(encoded)', unixepoch(), unixepoch())")
            return operation
        }
    }

    public func operation(replayKey: String) throws -> StoredOperation? {
        try withLock { try storedOperation(replayKey: replayKey) }
    }

    public func commitOperation(operationID: UUID, state: String, itemIdentifier: String?, outcome: String? = nil) throws {
        try withLock {
            let encodedOutcome = outcome.map { Data($0.utf8).base64EncodedString() }
            try execute("UPDATE operations SET state = '\(sql(state))', item_uuid = \(nullable(itemIdentifier)), outcome = \(nullable(encodedOutcome)), lease_owner = NULL, lease_expires_at = NULL, updated_at = unixepoch() WHERE operation_id = '\(operationID.uuidString)'")
        }
    }

    public func cancelRequested(operationID: UUID) throws -> Bool {
        try withLock { (try scalar("SELECT cancel_requested FROM operations WHERE operation_id = '\(operationID.uuidString)' LIMIT 1") ?? "0") == "1" }
    }

    public func acquireOperationLease(operationID: UUID, owner: UUID, now: Date = Date(), duration: TimeInterval = 30) throws -> Bool {
        try withLock {
            let nowSeconds = Int64(now.timeIntervalSince1970)
            let expires = nowSeconds + Int64(duration)
            let result = try executeReturningChanges("UPDATE operations SET lease_owner = '\(owner.uuidString)', lease_expires_at = \(expires), attempt = attempt + 1 WHERE operation_id = '\(operationID.uuidString)' AND state NOT IN ('committed', 'cancelled', 'permanently_failed') AND (lease_expires_at IS NULL OR lease_expires_at <= \(nowSeconds))")
            return result > 0
        }
    }

    public func releaseOperationLease(operationID: UUID, owner: UUID) throws {
        try withLock { try execute("UPDATE operations SET lease_owner = NULL, lease_expires_at = NULL WHERE operation_id = '\(operationID.uuidString)' AND lease_owner = '\(owner.uuidString)'") }
    }

    public func requestCancel(operationID: UUID) throws {
        try withLock { try execute("UPDATE operations SET cancel_requested = 1 WHERE operation_id = '\(operationID.uuidString)'") }
    }

    public func hasDirtyWork() throws -> Bool {
        try withLock { Int(try scalar("SELECT (SELECT COUNT(*) FROM operations WHERE state NOT IN ('committed', 'cancelled', 'permanently_failed')) + (SELECT COUNT(*) FROM conflicts WHERE state = 'pending') + (SELECT COUNT(*) FROM upload_sessions WHERE state NOT IN ('completed', 'abandoned'))") ?? "0") ?? 0 > 0 }
    }

    private func currentAnchorUnlocked(domainIdentifier: String, scope: String) throws -> SyncAnchor {
        let epoch = UUID(uuidString: try scalar("SELECT epoch FROM sync_state WHERE singleton = 1") ?? "") ?? UUID()
        let nextSequence = Int64(try scalar("SELECT next_sequence FROM sync_state WHERE singleton = 1") ?? "0") ?? 0
        let sequence = UInt64(max(0, nextSequence - 1))
        return SyncAnchor(domainIdentifier: domainIdentifier, scope: scope, epoch: epoch, sequence: sequence)
    }

    private func storedOperation(replayKey: String) throws -> StoredOperation? {
        let statement = try prepare("SELECT operation_id, kind, item_uuid, state, source_generation, cancel_requested, outcome, lease_owner, lease_expires_at, attempt FROM operations WHERE replay_key = '\(sql(replayKey))' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let operation = PendingOperation(operationID: UUID(uuidString: columnString(statement, 0) ?? "") ?? UUID(), replayKey: replayKey, kind: columnString(statement, 1) ?? "", itemIdentifier: columnString(statement, 2), state: columnString(statement, 3) ?? "queued", sourceGeneration: UInt64(max(0, sqlite3_column_int64(statement, 4))), cancelRequested: sqlite3_column_int(statement, 5) != 0)
        let encodedOutcome = columnString(statement, 6)
        let outcome = encodedOutcome.flatMap { Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .utf8) } }
        let leaseOwner = columnString(statement, 7).flatMap(UUID.init(uuidString:))
        let leaseExpiresAt = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8)))
        return StoredOperation(operation: operation, outcome: outcome, leaseOwner: leaseOwner, leaseExpiresAt: leaseExpiresAt, attempt: Int(sqlite3_column_int(statement, 9)))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    private func configure() throws { try execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA synchronous = FULL; PRAGMA busy_timeout = 3000;") }

    private func execute(_ sql: String) throws {
        guard let database else { throw StoreBridgeError.openFailed("database closed") }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw StoreBridgeError.sql(detail)
        }
    }

    private func executeReturningChanges(_ sql: String) throws -> Int {
        guard let database else { throw StoreBridgeError.openFailed("database closed") }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw StoreBridgeError.sql(detail)
        }
        return Int(sqlite3_changes(database))
    }

    private func scalar(_ sql: String) throws -> String? {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnString(statement, 0)
    }

    private func queryString(_ sql: String) throws -> String? { try scalar(sql) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw StoreBridgeError.openFailed("database closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StoreBridgeError.sql(String(cString: sqlite3_errmsg(database))) }
        return statement
    }

    private func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let value = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func sql(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
    private func nullable(_ value: String?) -> String { value.map { "'\(sql($0))'" } ?? "NULL" }

    private func itemFromStatement(_ statement: OpaquePointer) -> RemoteItem {
        let itemIdentifier = columnString(statement, 0) ?? ""
        let remoteID = columnString(statement, 1)
        let parent = columnString(statement, 2)
        let name = columnString(statement, 3) ?? ""
        let kind = RemoteItemKind(rawValue: columnString(statement, 4) ?? "unsupported") ?? .unsupported
        let uri = columnString(statement, 5) ?? "/"
        let size = sqlite3_column_int64(statement, 6)
        let remoteVersion = columnString(statement, 7)
        let content = columnBlob(statement, 8)
        let metadata = columnBlob(statement, 9)
        return RemoteItem(itemIdentifier: itemIdentifier, remoteID: remoteID, parentIdentifier: parent, name: name, uri: uri, kind: kind, contentType: kind == .folder ? "public.folder" : "public.data", size: size, remoteVersion: remoteVersion, version: ItemVersion(content: content, metadata: metadata), canRead: true, canWrite: false, canAddChildren: false, canTrash: false, canDelete: false, trashed: sqlite3_column_int(statement, 10) != 0, tombstone: sqlite3_column_int(statement, 11) != 0)
    }
}

private enum Schema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS schema_meta (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL, generation INTEGER NOT NULL, compat_min INTEGER NOT NULL, compat_max INTEGER NOT NULL, migration_state TEXT NOT NULL);
    INSERT OR IGNORE INTO schema_meta VALUES (1, 1, 1, 1, 1, 'ready');
    CREATE TABLE IF NOT EXISTS domains (domain_id TEXT PRIMARY KEY, display_name TEXT NOT NULL, origin TEXT NOT NULL, account_id TEXT NOT NULL, root_entity_id TEXT NOT NULL, root_uri TEXT NOT NULL, scope_key TEXT NOT NULL, status TEXT NOT NULL, secret_ref TEXT NOT NULL, capability_revision INTEGER NOT NULL, capability_snapshot TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS domain_actions (action_id TEXT PRIMARY KEY, domain_id TEXT NOT NULL, kind TEXT NOT NULL, step TEXT NOT NULL, state TEXT NOT NULL, error TEXT);
    CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
    CREATE TABLE IF NOT EXISTS process_heartbeats (role TEXT PRIMARY KEY, instance_id TEXT NOT NULL, bundle_version TEXT NOT NULL, schema_generation INTEGER NOT NULL, last_seen INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS sync_state (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), epoch TEXT NOT NULL, next_sequence INTEGER NOT NULL DEFAULT 0, min_valid_sequence INTEGER NOT NULL DEFAULT 0, domain_version_revision INTEGER NOT NULL DEFAULT 0, reconcile_status TEXT NOT NULL DEFAULT 'initializing');
    CREATE TABLE IF NOT EXISTS items (item_uuid TEXT PRIMARY KEY, remote_entity_id TEXT, parent_uuid TEXT, remote_name TEXT NOT NULL, kind TEXT NOT NULL, current_remote_uri TEXT NOT NULL, content_version BLOB NOT NULL, metadata_version BLOB NOT NULL, size INTEGER NOT NULL DEFAULT 0, remote_version TEXT, trashed INTEGER NOT NULL DEFAULT 0, tombstone INTEGER NOT NULL DEFAULT 0);
    CREATE UNIQUE INDEX IF NOT EXISTS items_remote_id ON items(remote_entity_id) WHERE remote_entity_id IS NOT NULL AND tombstone = 0;
    CREATE INDEX IF NOT EXISTS items_parent_name ON items(parent_uuid, remote_name COLLATE NOCASE);
    CREATE TABLE IF NOT EXISTS directory_snapshots (parent_uuid TEXT PRIMARY KEY, snapshot_generation INTEGER NOT NULL, order_key TEXT NOT NULL, complete INTEGER NOT NULL, server_cursor TEXT, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
    CREATE TABLE IF NOT EXISTS materialized_containers (item_uuid TEXT PRIMARY KEY, is_materialized INTEGER NOT NULL, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
    CREATE TABLE IF NOT EXISTS system_set_state (set_kind TEXT PRIMARY KEY, system_anchor BLOB, refresh_required INTEGER NOT NULL DEFAULT 0, refresh_cursor BLOB, last_completed_at INTEGER);
    CREATE TABLE IF NOT EXISTS pending_items (item_uuid TEXT PRIMARY KEY, template_id TEXT, upload_error TEXT, download_error TEXT, updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
    CREATE TABLE IF NOT EXISTS change_journal (sequence INTEGER PRIMARY KEY, epoch TEXT NOT NULL, item_uuid TEXT NOT NULL, old_parent_uuid TEXT, new_parent_uuid TEXT, change_kind TEXT NOT NULL, version BLOB NOT NULL, origin TEXT NOT NULL, delivery_audience TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT (unixepoch()));
    CREATE TABLE IF NOT EXISTS signal_outbox (signal_id TEXT PRIMARY KEY, working_set_revision INTEGER NOT NULL UNIQUE, state TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 0, acknowledged_at INTEGER);
    CREATE TABLE IF NOT EXISTS pending_creations (system_template_id TEXT PRIMARY KEY, item_uuid TEXT NOT NULL, operation_id TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS operations (operation_id TEXT PRIMARY KEY, replay_key TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, item_uuid TEXT, state TEXT NOT NULL, source_generation INTEGER NOT NULL DEFAULT 0, cancel_requested INTEGER NOT NULL DEFAULT 0, lease_owner TEXT, lease_expires_at INTEGER, attempt INTEGER NOT NULL DEFAULT 0, next_retry_at INTEGER, outcome TEXT, created_at INTEGER NOT NULL DEFAULT (unixepoch()), updated_at INTEGER NOT NULL DEFAULT (unixepoch()));
    CREATE TABLE IF NOT EXISTS exclusion_intents (intent_id TEXT PRIMARY KEY, item_uuid TEXT, system_item_identifier TEXT, rule_revision INTEGER NOT NULL, kind TEXT NOT NULL, source_generation INTEGER NOT NULL, state TEXT NOT NULL, consumed_at INTEGER);
    CREATE TABLE IF NOT EXISTS upload_sessions (operation_id TEXT PRIMARY KEY, remote_session_ref TEXT, secret_ref TEXT, fingerprint TEXT NOT NULL, provider TEXT NOT NULL, chunk_size INTEGER NOT NULL, expires_at INTEGER, state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS upload_parts (operation_id TEXT NOT NULL, part_index INTEGER NOT NULL, offset INTEGER NOT NULL, length INTEGER NOT NULL, source_hash BLOB, etag TEXT, state TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(operation_id, part_index));
    CREATE TABLE IF NOT EXISTS tasks (task_id TEXT PRIMARY KEY, operation_id TEXT, direction TEXT NOT NULL, state TEXT NOT NULL, bytes INTEGER NOT NULL DEFAULT 0, total_bytes INTEGER, error_code TEXT);
    CREATE TABLE IF NOT EXISTS conflicts (conflict_id TEXT PRIMARY KEY, item_uuid TEXT, kind TEXT NOT NULL, base_metadata TEXT NOT NULL, remote_metadata TEXT NOT NULL, local_metadata TEXT NOT NULL, pending_item_id TEXT, source_generation INTEGER NOT NULL, state TEXT NOT NULL, resolution TEXT);
    CREATE TABLE IF NOT EXISTS reconcile_runs (run_id TEXT PRIMARY KEY, scope TEXT NOT NULL, generation INTEGER NOT NULL, phase TEXT NOT NULL, cursor TEXT, state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS auth_lease (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), owner_instance_id TEXT, lease_epoch INTEGER NOT NULL DEFAULT 0, expires_at INTEGER, credential_generation INTEGER NOT NULL DEFAULT 0, last_refresh_outcome TEXT);
    """
}

public final class AppGroupStoreFactory: @unchecked Sendable {
    private let fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func registryStore() throws -> SQLiteStateStore {
        guard let url = AppGroupPaths.registryURL(fileManager: fileManager) else { throw StoreBridgeError.openFailed("App Group is unavailable") }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try SQLiteStateStore(url: url)
    }

    public func domainStore(identifier: String) throws -> SQLiteStateStore {
        guard let url = try AppGroupPaths.prepareDomain(identifier, fileManager: fileManager) else { throw StoreBridgeError.openFailed("App Group is unavailable") }
        return try SQLiteStateStore(url: url)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Int64 {
    func saturatingSub(_ value: Int64) -> Int64 { self > value ? self - value : 0 }
}
