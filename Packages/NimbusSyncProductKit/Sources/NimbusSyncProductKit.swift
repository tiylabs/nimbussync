import Foundation
import UserNotifications
import AppKit
import CryptoKit
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveObservability
import CloudreveAuthKit

public enum ProductTaskDirection: String, Codable, Sendable { case upload, download, reconcile, other }
public enum ProductTaskState: String, Codable, Sendable { case queued, running, retrying, succeeded, failed, cancelled }

public struct ProductTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let domainIdentifier: String
    public let itemIdentifier: String?
    public let title: String
    public let direction: ProductTaskDirection
    public var state: ProductTaskState
    public var processedBytes: Int64
    public var totalBytes: Int64?
    public var speedBytesPerSecond: Int64?
    public var errorCode: String?
    public var updatedAt: Date
    public init(id: UUID = UUID(), domainIdentifier: String, itemIdentifier: String? = nil, title: String, direction: ProductTaskDirection, state: ProductTaskState, processedBytes: Int64 = 0, totalBytes: Int64? = nil, speedBytesPerSecond: Int64? = nil, errorCode: String? = nil, updatedAt: Date = Date()) { self.id = id; self.domainIdentifier = domainIdentifier; self.itemIdentifier = itemIdentifier; self.title = title; self.direction = direction; self.state = state; self.processedBytes = processedBytes; self.totalBytes = totalBytes; self.speedBytesPerSecond = speedBytesPerSecond; self.errorCode = errorCode; self.updatedAt = updatedAt }
    public var progress: Double? { guard let totalBytes, totalBytes > 0 else { return nil }; return min(1, max(0, Double(processedBytes) / Double(totalBytes))) }
}

public struct ProductTaskProjection: Sendable {
    public let tasks: [ProductTask]
    public init(tasks: [ProductTask]) { self.tasks = tasks }
    public var active: [ProductTask] { tasks.filter { [.queued, .running, .retrying].contains($0.state) } }
    public var recent: [ProductTask] { Array(tasks.sorted { $0.updatedAt > $1.updatedAt }.prefix(20)) }
}

public struct TaskProjection: Sendable {
    private var values: [UUID: ProductTask] = [:]
    public init() {}
    public mutating func upsert(_ task: ProductTask) { values[task.id] = task }
    public mutating func requestCancel(_ id: UUID) { guard var task = values[id], [.queued, .running, .retrying].contains(task.state) else { return }; task.state = .cancelled; task.updatedAt = Date(); values[id] = task }
    public mutating func retry(_ id: UUID) { guard var task = values[id], task.state == .failed else { return }; task.state = .retrying; task.errorCode = nil; task.updatedAt = Date(); values[id] = task }
    public func active() -> [ProductTask] { values.values.filter { [.queued, .running, .retrying].contains($0.state) }.sorted { $0.updatedAt > $1.updatedAt } }
    public func recent(limit: Int = 20) -> [ProductTask] { Array(values.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)) }
}

public struct ProductConflict: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let domainIdentifier: String
    public let itemIdentifier: String
    public let filename: String
    public let kind: String
    public let baseSummary: String
    public let localSummary: String
    public let remoteSummary: String
    public let remoteVersion: Data?
    public let createdAt: Date
    public var state: String
    public init(id: UUID, domainIdentifier: String, itemIdentifier: String, filename: String, kind: String, baseSummary: String, localSummary: String, remoteSummary: String, remoteVersion: Data? = nil, createdAt: Date, state: String = "pending") { self.id = id; self.domainIdentifier = domainIdentifier; self.itemIdentifier = itemIdentifier; self.filename = filename; self.kind = kind; self.baseSummary = baseSummary; self.localSummary = localSummary; self.remoteSummary = remoteSummary; self.remoteVersion = remoteVersion; self.createdAt = createdAt; self.state = state }
}

public struct ConflictCenterModel: Sendable {
    public var conflicts: [ProductConflict]
    public init(conflicts: [ProductConflict] = []) { self.conflicts = conflicts }
    public mutating func resolve(_ id: UUID) { if let index = conflicts.firstIndex(where: { $0.id == id }) { conflicts[index].state = "resolved" } }
    public var pending: [ProductConflict] { conflicts.filter { $0.state == "pending" }.sorted { $0.createdAt > $1.createdAt } }
}

public struct ProductSnapshot: Equatable, Sendable {
    public var domains: [DomainDescriptor]
    public var tasks: [ProductTask]
    public var conflicts: [ProductConflict]
    public var metrics: ConsistencyMetrics
    public var notificationPreferences: NotificationPreferences
    public var exclusionRules: [String: String]
    public init(domains: [DomainDescriptor] = [], tasks: [ProductTask] = [], conflicts: [ProductConflict] = [], metrics: ConsistencyMetrics = ConsistencyMetrics(), notificationPreferences: NotificationPreferences = NotificationPreferences(), exclusionRules: [String: String] = [:]) { self.domains = domains; self.tasks = tasks; self.conflicts = conflicts; self.metrics = metrics; self.notificationPreferences = notificationPreferences; self.exclusionRules = exclusionRules }
    public var highestStatus: DomainStatus {
        domains.map(\.status).sorted { $0.priority > $1.priority }.first ?? .initializing
    }
    public var activeTasks: [ProductTask] { tasks.filter { [.queued, .running, .retrying].contains($0.state) } }
    public var actionableConflicts: [ProductConflict] { conflicts.filter { $0.state == "pending" } }
    public var taskProjection: ProductTaskProjection { ProductTaskProjection(tasks: tasks) }
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var authExpired: Bool
    public var conflicts: Bool
    public var permanentFailures: Bool
    public var syncComplete: Bool
    public init(enabled: Bool = true, authExpired: Bool = true, conflicts: Bool = true, permanentFailures: Bool = true, syncComplete: Bool = false) { self.enabled = enabled; self.authExpired = authExpired; self.conflicts = conflicts; self.permanentFailures = permanentFailures; self.syncComplete = syncComplete }
}

public enum ProductCopy {
    public static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), bundle: .module) }
}

public actor ProductStore {
    private let registry: SQLiteStateStore?
    private let storeFactory: AppGroupStoreFactory?
    private let userDefaults: UserDefaults
    private let metrics: MetricsStore
    private let notificationKey = "nimbussync.notification.preferences"

    public init(registry: SQLiteStateStore? = nil, storeFactory: AppGroupStoreFactory? = nil, userDefaults: UserDefaults = .standard, metrics: MetricsStore = MetricsStore()) { self.registry = registry; self.storeFactory = storeFactory; self.userDefaults = userDefaults; self.metrics = metrics }

    public func snapshot() -> ProductSnapshot {
        let domains = (try? registry?.allDomains() ?? [])?.compactMap { stored -> DomainDescriptor? in
            guard let scope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return nil }
            var descriptor = DomainDescriptor(displayName: stored.displayName, scope: scope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, iconURL: stored.iconURL)
            descriptor.status = stored.status
            return descriptor
        } ?? []
        var tasks: [ProductTask] = []
        var conflicts: [ProductConflict] = []
        for domain in domains {
            let domainStore: SQLiteStateStore?
            if let storeFactory { domainStore = try? storeFactory.domainStore(identifier: domain.identifier) } else { domainStore = nil }
            let storedOperations = (try? domainStore?.operations(limit: 100) ?? []) ?? []
            tasks.append(contentsOf: storedOperations.map { stored in
                let errorCode: String?
                switch stored.operation.state {
                case "unknown_outcome": errorCode = "unknown_outcome"
                case "conflict": errorCode = "version_conflict"
                case "auth_expired": errorCode = "authentication_required"
                default: errorCode = nil
                }
                return ProductTask(id: stored.operation.operationID, domainIdentifier: domain.identifier, itemIdentifier: stored.operation.itemIdentifier, title: stored.operation.itemIdentifier ?? stored.operation.kind, direction: direction(for: stored.operation.kind), state: taskState(for: stored.operation.state, cancelRequested: stored.operation.cancelRequested), errorCode: errorCode, updatedAt: stored.updatedAt)
            })
            let storedConflicts: [ConflictProjection]
            if let domainStore { storedConflicts = (try? domainStore.pendingConflicts(limit: 100)) ?? [] } else { storedConflicts = [] }
            conflicts.append(contentsOf: storedConflicts.map { conflict in
                let filename = (try? domainStore?.item(identifier: conflict.itemIdentifier)?.name) ?? conflict.itemIdentifier
                return ProductConflict(id: conflict.conflictID, domainIdentifier: domain.identifier, itemIdentifier: conflict.itemIdentifier, filename: filename, kind: conflict.kind, baseSummary: conflict.baseSummary, localSummary: conflict.localSummary, remoteSummary: conflict.remoteSummary, remoteVersion: conflict.remoteVersion, createdAt: conflict.createdAt, state: conflict.state)
            })
        }
        let preferences = userDefaults.data(forKey: notificationKey).flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) } ?? NotificationPreferences()
        return ProductSnapshot(domains: domains, tasks: tasks, conflicts: conflicts, metrics: metrics.snapshot(), notificationPreferences: preferences)
    }

    public func saveNotificationPreferences(_ preferences: NotificationPreferences) throws {
        userDefaults.set(try JSONEncoder().encode(preferences), forKey: notificationKey)
    }

    public func cancelTask(_ taskID: UUID) throws {
        guard let registry, let storeFactory else { return }
        for domain in try registry.allDomains() {
            guard let store = try? storeFactory.domainStore(identifier: domain.identifier) else { continue }
            if try store.operation(operationID: taskID) != nil {
                try store.requestCancel(operationID: taskID)
                return
            }
        }
    }

    public func retryTask(_ taskID: UUID) throws {
        guard let registry, let storeFactory else { return }
        for domain in try registry.allDomains() {
            guard let store = try? storeFactory.domainStore(identifier: domain.identifier) else { continue }
            if try store.operation(operationID: taskID) != nil {
                try store.retryOperation(operationID: taskID)
                return
            }
        }
    }

    public func clearTaskHistory() throws {
        guard let registry, let storeFactory else { return }
        for domain in try registry.allDomains() {
            try storeFactory.domainStore(identifier: domain.identifier).clearCompletedOperations()
        }
    }

    public func store() -> SQLiteStateStore? { registry }
}

private func direction(for kind: String) -> ProductTaskDirection {
    switch kind.lowercased() { case "create", "modify", "rename", "move", "trash", "restore", "delete": return .upload; default: return .other }
}

private func taskState(for state: String, cancelRequested: Bool = false) -> ProductTaskState {
    if cancelRequested && !["committed", "cancelled", "permanently_failed"].contains(state) { return .cancelled }
    switch state {
    case "queued": return .queued
    case "committed": return .succeeded
    case "cancelled": return .cancelled
    case "retry_wait": return .retrying
    case "permanently_failed", "conflict", "unknown_outcome", "auth_expired": return .failed
    default: return .running
    }
}

public actor NotificationCoordinator {
    private let center: UNUserNotificationCenter
    private let userDefaults: UserDefaults
    private let dedupeKey = "nimbussync.notification.dedupe"
    private let preferences: ProductStore

    public init(center: UNUserNotificationCenter = .current(), userDefaults: UserDefaults = .standard, preferences: ProductStore) { self.center = center; self.userDefaults = userDefaults; self.preferences = preferences }

    public func requestAuthorizationIfNeeded() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func configureCategories() {
        let categories = [
            UNNotificationCategory(identifier: "auth", actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "conflict", actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "failure", actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "complete", actions: [], intentIdentifiers: [], options: []),
        ]
        center.setNotificationCategories(Set(categories))
    }

    public func notify(kind: String, opaqueID: String, title: String, body: String, enabled: Bool) async throws {
        guard enabled else { return }
        var sent = userDefaults.stringArray(forKey: dedupeKey) ?? []
        let key = "\(kind):\(opaqueID)"
        guard !sent.contains(key) else { return }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.categoryIdentifier = kind; content.sound = .default
        let action = kind == "auth" ? "reauthorize" : (kind == "failure" ? "task" : kind)
        content.userInfo = ["deepLink": "nimbussync://\(action)/\(opaqueID)"]
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        try await center.add(request)
        sent.append(key); userDefaults.set(Array(sent.suffix(500)), forKey: dedupeKey)
    }
}

public enum DeepLinkDestination: Equatable, Sendable { case conflict(UUID), reauthorize(String), task(UUID), item(String), conflictItem(String), settings }

public enum DeepLinkRouter {
    public static func destination(url: URL) -> DeepLinkDestination? {
        guard url.scheme == "nimbussync", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let action: String
        let identifiers: ArraySlice<String>
        if let host = url.host, !host.isEmpty {
            action = host
            identifiers = pathComponents[...]
        } else if let first = pathComponents.first {
            action = first
            identifiers = pathComponents.dropFirst()
        } else {
            return .settings
        }
        switch action {
        case "conflict": guard let id = identifiers.first.flatMap(UUID.init(uuidString:)), identifiers.count == 1 else { return nil }; return .conflict(id)
        case "reauthorize": guard let id = identifiers.first, identifiers.count == 1, CloudreveIdentifier.validate(id, prefix: CloudreveIdentifier.domainPrefix) else { return nil }; return .reauthorize(id)
        case "task": guard let id = identifiers.first.flatMap(UUID.init(uuidString:)), identifiers.count == 1 else { return nil }; return .task(id)
        case "item": guard let id = identifiers.first, identifiers.count == 1, CloudreveIdentifier.validate(id, prefix: CloudreveIdentifier.itemPrefix) else { return nil }; return .item(id)
        case "conflict-item": guard let id = identifiers.first, identifiers.count == 1, CloudreveIdentifier.validate(id, prefix: CloudreveIdentifier.itemPrefix) else { return nil }; return .conflictItem(id)
        case "settings": return .settings
        default: return nil
        }
    }
}

public struct ExclusionRuleSet: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let rules: [String]
    public init(revision: UInt64, rules: [String]) throws { self.revision = revision; self.rules = try rules.map(ExclusionRuleSet.normalize) }
    public func matches(relativePath: String, isRoot: Bool = false) -> Bool {
        guard !isRoot else { return false }
        let path = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rules.contains { ExclusionRuleSet.match($0, path: path) }
    }
    public static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.contains("\0"), !trimmed.hasPrefix("/") else { throw CoreFailure(code: .invalidName, retryable: false, userActionRequired: true) }
        return trimmed.replacingOccurrences(of: "\\", with: "/")
    }
    private static func match(_ pattern: String, path: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*\\*", with: ".*").replacingOccurrences(of: "\\*", with: "[^/]*").replacingOccurrences(of: "\\?", with: "[^/]")
        return path.range(of: "^\(escaped)(?:/.*)?$", options: .regularExpression) != nil
    }
}

public struct ExclusionImpact: Equatable, Sendable { public let remoteMatches: Int; public let dirtyMatches: Int; public init(remoteMatches: Int, dirtyMatches: Int) { self.remoteMatches = remoteMatches; self.dirtyMatches = dirtyMatches } }

private func relativePath(_ uri: String, rootURI: String) -> String? {
    if uri.hasPrefix("cloudreve://") || rootURI.hasPrefix("cloudreve://") { return CloudreveRemoteURI.relativePath(uri, root: rootURI) }
    let normalizedURI = uri.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let normalizedRoot = rootURI.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard normalizedRoot.isEmpty || normalizedURI == normalizedRoot || normalizedURI.hasPrefix(normalizedRoot + "/") else { return nil }
    if normalizedRoot.isEmpty { return normalizedURI }
    return String(normalizedURI.dropFirst(normalizedRoot.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
}

public actor ExclusionRuleService {
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store }
    public func compile(revision: UInt64, text: String) throws -> ExclusionRuleSet {
        let rules = text.split(whereSeparator: \.isNewline).map(String.init).filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }
        return try ExclusionRuleSet(revision: revision, rules: rules)
    }
    public func preview(_ ruleSet: ExclusionRuleSet, items: [RemoteItem], rootURI: String = "/") -> ExclusionImpact {
        let matches = items.filter { item in
            guard let relativePath = relativePath(item.uri, rootURI: rootURI) else { return false }
            return ruleSet.matches(relativePath: relativePath)
        }
        return ExclusionImpact(remoteMatches: matches.count, dirtyMatches: matches.filter { !$0.tombstone && !$0.trashed }.count)
    }
    public func persist(_ ruleSet: ExclusionRuleSet, domainIdentifier: String) throws { let data = try JSONEncoder().encode(ruleSet); try store.setPreference(key: "exclusion.rules.\(domainIdentifier)", value: String(data: data, encoding: .utf8) ?? "") }
}

public struct ExclusionApplication: Sendable {
    public let ruleSet: ExclusionRuleSet
    public let impact: ExclusionImpact
    public let requiresDirtyPreservation: Bool
    public init(ruleSet: ExclusionRuleSet, impact: ExclusionImpact) { self.ruleSet = ruleSet; self.impact = impact; self.requiresDirtyPreservation = impact.dirtyMatches > 0 }
}

public actor ExclusionApplicationService {
    private let rules: ExclusionRuleService
    private let store: SQLiteStateStore
    public init(store: SQLiteStateStore) { self.store = store; self.rules = ExclusionRuleService(store: store) }
    public func preview(revision: UInt64, text: String, items: [RemoteItem], rootURI: String = "/") async throws -> ExclusionApplication { let ruleSet = try await rules.compile(revision: revision, text: text); let impact = await rules.preview(ruleSet, items: items, rootURI: rootURI); return ExclusionApplication(ruleSet: ruleSet, impact: impact) }
    public func apply(_ application: ExclusionApplication, domainIdentifier: String, preserveDirty: Bool) async throws {
        guard !application.requiresDirtyPreservation || preserveDirty else { throw CoreFailure(code: .cannotSynchronize, retryable: false, userActionRequired: true) }
        try await rules.persist(application.ruleSet, domainIdentifier: domainIdentifier)
    }
}

public struct DiagnosticArchive: Sendable {
    public let manifest: DiagnosticManifest
    public let health: [HealthCheck]
    public init(manifest: DiagnosticManifest, health: [HealthCheck]) { self.manifest = manifest; self.health = health }
    public func export(to directory: URL, includeFileNames: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try encoder.encode(health).write(to: directory.appendingPathComponent("health.json"), options: .atomic)
        let privacy = ["includesFileNames": includeFileNames, "includesPaths": false, "includesTokens": false, "includesSignedURLs": false, "includesContent": false]
        try JSONSerialization.data(withJSONObject: privacy, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("privacy.json"), options: .atomic)
        return directory
    }
}

public enum ReleaseSupportStatus: String, Codable, Sendable { case verified, readOnly, unsupported, unverified }

public struct SupportMatrixEntry: Codable, Equatable, Sendable {
    public let component: String
    public let version: String
    public let architecture: String
    public let status: ReleaseSupportStatus
    public let evidence: String
    public init(component: String, version: String, architecture: String, status: ReleaseSupportStatus, evidence: String) { self.component = component; self.version = version; self.architecture = architecture; self.status = status; self.evidence = evidence }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let version: String
    public let commit: String
    public let swiftVersion: String
    public let rustVersion: String
    public let architectures: [String]
    public let artifacts: [String: String]
    public let supportMatrix: [SupportMatrixEntry]
    public let gates: [String: Bool]
    public init(version: String, commit: String, swiftVersion: String, rustVersion: String, architectures: [String], artifacts: [String: String], supportMatrix: [SupportMatrixEntry], gates: [String: Bool]) { self.version = version; self.commit = commit; self.swiftVersion = swiftVersion; self.rustVersion = rustVersion; self.architectures = architectures; self.artifacts = artifacts; self.supportMatrix = supportMatrix; self.gates = gates }
    public var isReleaseCandidate: Bool { gates.values.allSatisfy { $0 } && !supportMatrix.contains { $0.status == .unverified } }
}

public enum UpgradeFence {
    public static func canWrite(schemaVersion: Int, compatibilityMinimum: Int, compatibilityMaximum: Int, processGeneration: Int, currentGeneration: Int, migrationState: String = "ready") -> Bool {
        migrationState == "ready" && schemaVersion >= compatibilityMinimum && schemaVersion <= compatibilityMaximum && processGeneration == currentGeneration
    }
}

public enum RepairCoordinator {
    public static func check(_ store: SQLiteStateStore) throws -> HealthCheck {
        let healthy = try store.quickCheck()
        return HealthCheck(name: "Database", state: healthy ? .pass : .fail, stableCode: healthy ? "db_ok" : "db_quick_check_failed")
    }
    public static func quarantine(_ store: SQLiteStateStore) throws -> URL? { try store.isolateForRepair() }
}

public struct UninstallPreflight: Equatable, Sendable {
    public let domainIdentifier: String
    public let preserveDirtyData: Bool
    public let reason: String
    public init(domainIdentifier: String, preserveDirtyData: Bool, reason: String) { self.domainIdentifier = domainIdentifier; self.preserveDirtyData = preserveDirtyData; self.reason = reason }
}

public enum ReleaseArtifacts {
    public static func checksum(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256Digest.hex(data)
    }
}

private enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension DomainStatus {
    var priority: Int { switch self { case .authExpired: 100; case .rootUnavailable, .scopeConflict: 90; case .conflict, .permanentError: 80; case .offline: 70; case .reconciling: 60; case .syncing: 50; case .eventDegraded, .appNotRunning: 40; case .healthy: 10; default: 0 } }
}
