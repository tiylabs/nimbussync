import Foundation
import FileProvider
import ServiceManagement
import CloudreveDomainKit
import CloudreveStoreBridge

public enum EventEnrichmentError: Error, Equatable {
    case malformedHint
    case outsideScope
    case unavailable
}

public struct EventScopeGuard: Sendable {
    public let rootRemoteID: String
    public let rootURI: String
    public private(set) var rejectedCount: Int

    public init(rootRemoteID: String, rootURI: String) { self.rootRemoteID = rootRemoteID; self.rootURI = rootURI; self.rejectedCount = 0 }

    public mutating func accepts(remoteID: String?, fromURI: String?, toURI: String?) -> Bool {
        guard let remoteID, !remoteID.isEmpty, remoteID != rootRemoteID else { rejectedCount += 1; return false }
        let normalizedRoot = rootURI == "/" ? "/" : rootURI.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for uri in [fromURI, toURI].compactMap({ $0 }) {
            let normalized = uri.replacingOccurrences(of: "\\", with: "/")
            guard !normalized.contains("/../"), !normalized.hasSuffix("/..") else { rejectedCount += 1; return false }
            if normalizedRoot != "/" && normalized != "/\(normalizedRoot)" && !normalized.hasPrefix("/\(normalizedRoot)/") {
                rejectedCount += 1
                return false
            }
        }
        return true
    }
}

public struct RemoteEventPayload: Codable, Sendable, Equatable {
    public let type: String?
    public let id: String?
    public let from: String?
    public let to: String?
    public init(type: String?, id: String?, from: String?, to: String?) { self.type = type; self.id = id; self.from = from; self.to = to }
}

public struct StableRootObservation: Sendable, Equatable {
    public let remoteID: String
    public let uri: String
    public let accountID: String
    public let canRead: Bool
    public init(remoteID: String, uri: String, accountID: String, canRead: Bool) { self.remoteID = remoteID; self.uri = uri; self.accountID = accountID; self.canRead = canRead }
}

public enum RootConsistencyResult: Sendable, Equatable {
    case unchanged
    case routeUpdated(uri: String)
    case unavailable
    case scopeConflict
    case replaced
}

public struct StableRootChecker: Sendable {
    public let expectedRemoteID: String
    public let expectedAccountID: String
    public let existingScopes: [RemoteScope]
    public init(expectedRemoteID: String, expectedAccountID: String, existingScopes: [RemoteScope] = []) { self.expectedRemoteID = expectedRemoteID; self.expectedAccountID = expectedAccountID; self.existingScopes = existingScopes }

    public func check(_ observation: StableRootObservation, currentScope: RemoteScope) -> RootConsistencyResult {
        guard observation.canRead, observation.accountID == expectedAccountID else { return .unavailable }
        guard observation.remoteID == expectedRemoteID else { return .replaced }
        guard let newScope = try? RemoteScope(origin: currentScope.origin, accountID: currentScope.accountID, rootURI: observation.uri) else { return .unavailable }
        if existingScopes.contains(where: { $0.overlaps(newScope) && $0.rootURI != currentScope.rootURI }) { return .scopeConflict }
        return newScope.rootURI == currentScope.rootURI ? .unchanged : .routeUpdated(uri: newScope.rootURI)
    }
}

public struct EventHintDecoder: Sendable {
    public init() {}
    public func decode(_ hint: RemoteEventHint) throws -> RemoteEventPayload {
        guard let data = hint.payload?.data(using: .utf8), !data.isEmpty else { throw EventEnrichmentError.malformedHint }
        guard let payload = try? JSONDecoder().decode(RemoteEventPayload.self, from: data), payload.type != nil || payload.id != nil else { throw EventEnrichmentError.malformedHint }
        return payload
    }
}

public protocol RemoteEventEnricher: Sendable {
    func enrich(_ hint: RemoteEventHint) async throws -> EnrichedRemoteChange?
}

public actor EventNormalizationPipeline {
    private var scopeGuard: EventScopeGuard
    private let enricher: RemoteEventEnricher
    private let writer: EventJournalWriter
    private var seenVersions: [String: Data] = [:]
    private var pendingScopes: Set<String> = []

    public init(scopeGuard: EventScopeGuard, enricher: RemoteEventEnricher, writer: EventJournalWriter) { self.scopeGuard = scopeGuard; self.enricher = enricher; self.writer = writer }

    public func consume(_ hint: RemoteEventHint, echo: EchoEvidence? = nil) async -> EchoMatchResult {
        guard scopeGuard.accepts(remoteID: hint.remoteID, fromURI: hint.fromURI, toURI: hint.toURI) else {
            pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
            return .unknown
        }
        do {
            guard let change = try await enricher.enrich(hint) else {
                pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
                return .unknown
            }
            let match = EchoMatcher.match(echo, item: change.item)
            switch match {
            case .matched:
                seenVersions[change.item.remoteID ?? change.item.itemIdentifier] = change.item.version.content
                return .matched
            case .realDifference, .unknown:
                let versionKey = change.item.remoteID ?? change.item.itemIdentifier
                if seenVersions[versionKey] == change.item.version.content { return .matched }
                _ = try? await writer.commit(change)
                seenVersions[versionKey] = change.item.version.content
                return match
            }
        } catch {
            pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
            return .unknown
        }
    }

    public func scopesNeedingReconciliation() -> [String] { pendingScopes.sorted() }
    public func clearReconciledScope(_ scope: String) { pendingScopes.remove(scope) }
    public func rejectedEvents() -> Int { scopeGuard.rejectedCount }
}

public struct ReconcileItemSet: Sendable, Equatable {
    public let expectedRemoteIDs: Set<String>
    public let normalRemoteIDs: Set<String>
    public let trashRemoteIDs: Set<String>
    public let pendingRemoteIDs: Set<String>
    public let normalComplete: Bool
    public let trashComplete: Bool
    public init(expectedRemoteIDs: Set<String>, normalRemoteIDs: Set<String>, trashRemoteIDs: Set<String>, pendingRemoteIDs: Set<String>, normalComplete: Bool, trashComplete: Bool) { self.expectedRemoteIDs = expectedRemoteIDs; self.normalRemoteIDs = normalRemoteIDs; self.trashRemoteIDs = trashRemoteIDs; self.pendingRemoteIDs = pendingRemoteIDs; self.normalComplete = normalComplete; self.trashComplete = trashComplete }
}

public struct ReconcileSafety: Sendable {
    public init() {}
    public func tombstoneCandidates(_ set: ReconcileItemSet) -> [String] {
        guard set.normalComplete && set.trashComplete else { return [] }
        return set.expectedRemoteIDs.subtracting(set.normalRemoteIDs).subtracting(set.trashRemoteIDs).subtracting(set.pendingRemoteIDs).sorted()
    }
}

public actor ReconciliationCoordinator {
    private let store: SQLiteStateStore
    private var activeRun: ReconcileGeneration?
    private let safety = ReconcileSafety()

    public init(store: SQLiteStateStore) { self.store = store }

    public func begin(generation: UInt64, capabilityRevision: UInt64, rootRemoteID: String) throws -> ReconcileGeneration {
        let state = try store.syncState()
        let run = ReconcileGeneration(generation: generation, capabilityRevision: capabilityRevision, rootRemoteID: rootRemoteID, startSequence: state.currentSequence)
        activeRun = run
        try store.startReconcile(runID: run.runID, scope: "domain", generation: generation, phase: run.phase.rawValue, cursor: nil)
        try store.updateSyncState(reconcileStatus: "reconciling")
        return run
    }

    public func recordPage(cursor: String?, phase: ReconcileGeneration.Phase) throws {
        guard var run = activeRun else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
        run.cursor = cursor; run.phase = phase; activeRun = run
        try store.updateReconcile(runID: run.runID, phase: phase.rawValue, cursor: cursor, state: "active")
    }

    public func finish(run: ReconcileGeneration, safetySet: ReconcileItemSet, currentCapabilityRevision: UInt64, currentRootRemoteID: String) throws -> [String] {
        guard run.normalComplete && run.trashComplete else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
        var candidateRun = run
        try candidateRun.stabilize()
        try candidateRun.beginDeletionCommit(currentCapabilityRevision: currentCapabilityRevision, currentRootRemoteID: currentRootRemoteID)
        let tombstones = safety.tombstoneCandidates(safetySet)
        candidateRun.complete()
        activeRun = nil
        try store.updateReconcile(runID: candidateRun.runID, phase: candidateRun.phase.rawValue, cursor: nil, state: "completed")
        try store.updateSyncState(reconcileAt: Date(), reconcileStatus: "completed")
        return tombstones
    }

    public func abort() throws {
        guard let run = activeRun else { return }
        activeRun = nil
        try store.updateReconcile(runID: run.runID, phase: ReconcileGeneration.Phase.failed.rawValue, cursor: run.cursor, state: "failed")
        try store.updateSyncState(reconcileStatus: "error")
    }
}

public struct ReconcileGeneration: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, scanningNormal = "scanning_normal", scanningTrash = "scanning_trash", stabilizing, committingDeletions = "committing_deletions", completed, failed }
    public let runID: UUID
    public let generation: UInt64
    public let capabilityRevision: UInt64
    public let rootRemoteID: String
    public var phase: Phase
    public var normalComplete: Bool
    public var trashComplete: Bool
    public var cursor: String?
    public var startSequence: Int64
    public init(runID: UUID = UUID(), generation: UInt64, capabilityRevision: UInt64, rootRemoteID: String, startSequence: Int64) { self.runID = runID; self.generation = generation; self.capabilityRevision = capabilityRevision; self.rootRemoteID = rootRemoteID; self.phase = .prepared; self.normalComplete = false; self.trashComplete = false; self.cursor = nil; self.startSequence = startSequence }
    public mutating func startNormal() { phase = .scanningNormal }
    public mutating func startTrash() { phase = .scanningTrash }
    public mutating func finishNormal() { normalComplete = true }
    public mutating func finishTrash() { trashComplete = true }
    public mutating func stabilize() throws { guard normalComplete && trashComplete else { phase = .failed; throw CoreFailure(code: .unknownOutcome, retryable: true) }; phase = .stabilizing }
    public mutating func beginDeletionCommit(currentCapabilityRevision: UInt64, currentRootRemoteID: String) throws { guard phase == .stabilizing, capabilityRevision == currentCapabilityRevision, rootRemoteID == currentRootRemoteID else { phase = .failed; throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true) }; phase = .committingDeletions }
    public mutating func complete() { phase = .completed }
}

public actor MaterializedSetTracker {
    private let store: SQLiteStateStore
    private var degraded = false
    public init(store: SQLiteStateStore) { self.store = store }
    public func mark(_ identifier: String, materialized: Bool) { try? store.setMaterialized(identifier, materialized: materialized) }
    public func markDegraded() { degraded = true }
    public func isDegraded() -> Bool { degraded }
    public func shouldSignal(parentIdentifiers: [String], oldParent: String?, newParent: String?) -> Bool {
        let values = Set(parentIdentifiers)
        return oldParent.map(values.contains) ?? false || newParent.map(values.contains) ?? false
    }
}

public actor PendingSetTracker {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    public func update(itemIdentifier: String, templateIdentifier: String?, uploadError: String?, downloadError: String?) { try? store.setPending(itemIdentifier, templateIdentifier: templateIdentifier, uploadError: uploadError, downloadError: downloadError) }
    public func snapshot() -> (count: Int, capped: Bool) { (try? store.pendingSetState()) ?? (0, true) }
}

public actor FairDomainScheduler {
    private var queue: [String] = []
    private var active: Set<String> = []
    private let limit: Int
    public init(limit: Int = 2) { self.limit = max(1, limit) }
    public func enqueue(_ domainID: String) { if !queue.contains(domainID) && !active.contains(domainID) { queue.append(domainID) } }
    public func next() -> String? { guard active.count < limit, !queue.isEmpty else { return nil }; let value = queue.removeFirst(); active.insert(value); return value }
    public func finish(_ domainID: String) { active.remove(domainID) }
    public func queued() -> [String] { queue }
    public func activeDomains() -> [String] { active.sorted() }
}

public actor HeartbeatCoordinator {
    private var lastHeartbeat: Date?
    private var appRunning = true
    private let store: SQLiteStateStore?
    private let role: String
    private let instanceID: UUID
    public init(store: SQLiteStateStore? = nil, role: String = "app", instanceID: UUID = UUID()) { self.store = store; self.role = role; self.instanceID = instanceID }
    public func beat(at date: Date = Date()) { lastHeartbeat = date; appRunning = true; try? store?.recordHeartbeat(role: role, instanceID: instanceID, bundleVersion: "0.1.0", schemaGeneration: 1, at: date) }
    public func markQuit() { appRunning = false; try? store?.updateSyncState(reconcileStatus: "app_not_running") }
    public func isFresh(now: Date = Date(), timeout: TimeInterval = 90) -> Bool { appRunning && lastHeartbeat.map { now.timeIntervalSince($0) <= timeout } ?? false }
}

public final class LoginItemCoordinator: @unchecked Sendable {
    public init() {}
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

public struct DomainConsistencyProjection: Sendable {
    public var inputs: HealthInputs
    public init(inputs: HealthInputs = HealthInputs()) { self.inputs = inputs }
    public mutating func setAppRunning(_ value: Bool) { inputs.appRunning = value }
    public mutating func setEventDegraded(_ value: Bool) { inputs.eventDegraded = value }
    public mutating func setReconciling(_ value: Bool) { inputs.reconciling = value }
    public func status() -> DomainStatus { DomainHealthReducer.reduce(inputs) }
}
