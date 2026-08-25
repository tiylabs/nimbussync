import Foundation
import OSLog
import CloudreveDomainKit

public struct CorrelationID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString.lowercased() }
}

public enum SecretRedactor {
    public static func redact(_ value: String) -> String {
        var output = value
        let patterns = [
            #"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+"#,
            #"(?i)(bearer\s+)[^\s,;]+"#,
            #"(?i)((?:access|refresh|client|callback|upload)[_-]?(?:token|secret)\s*[=:]\s*)[^\s,;&]+"#,
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(of: pattern, with: "$1[REDACTED]", options: .regularExpression)
        }
        if var components = URLComponents(string: output), components.queryItems != nil {
            components.queryItems = components.queryItems?.map { URLQueryItem(name: $0.name, value: "[REDACTED]") }
            output = components.string ?? output
        }
        return output
    }
}

public struct DiagnosticManifest: Codable, Sendable {
    public let appVersion: String
    public let coreVersion: String
    public let schemaVersion: Int
    public let operatingSystem: String
    public let architecture: String
    public let domains: [DomainDiagnostic]
    public init(appVersion: String, coreVersion: String, schemaVersion: Int, operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString, architecture: String = "arm64", domains: [DomainDiagnostic] = []) {
        self.appVersion = appVersion; self.coreVersion = coreVersion; self.schemaVersion = schemaVersion; self.operatingSystem = operatingSystem; self.architecture = architecture; self.domains = domains
    }
}

public struct DomainDiagnostic: Codable, Sendable {
    public let identifier: String
    public let status: DomainStatus
    public let pendingOperations: Int
    public let pendingConflicts: Int
    public let pendingOutbox: Int
    public let lastReconcileAt: Date?
    public init(identifier: String, status: DomainStatus, pendingOperations: Int = 0, pendingConflicts: Int = 0, pendingOutbox: Int = 0, lastReconcileAt: Date? = nil) {
        self.identifier = identifier; self.status = status; self.pendingOperations = pendingOperations; self.pendingConflicts = pendingConflicts; self.pendingOutbox = pendingOutbox; self.lastReconcileAt = lastReconcileAt
    }
}

public struct HealthCheck: Codable, Sendable {
    public enum State: String, Codable, Sendable { case pass, degraded, fail, unknown }
    public let name: String
    public let state: State
    public let stableCode: String
    public let detail: String?
    public init(name: String, state: State, stableCode: String, detail: String? = nil) { self.name = name; self.state = state; self.stableCode = stableCode; self.detail = detail.map(SecretRedactor.redact) }
}

public final class CloudreveLogger: @unchecked Sendable {
    private let logger: Logger
	public init(subsystem: String = "ai.tiylabs.nimbussync", category: String = "core") { logger = Logger(subsystem: subsystem, category: category) }
    public func info(_ message: String, correlationID: CorrelationID = CorrelationID()) { logger.info("[\(correlationID.description, privacy: .public)] \(SecretRedactor.redact(message), privacy: .public)") }
    public func warning(_ message: String, correlationID: CorrelationID = CorrelationID()) { logger.warning("[\(correlationID.description, privacy: .public)] \(SecretRedactor.redact(message), privacy: .public)") }
    public func error(_ message: String, correlationID: CorrelationID = CorrelationID()) { logger.error("[\(correlationID.description, privacy: .public)] \(SecretRedactor.redact(message), privacy: .public)") }
}

public struct ConsistencyMetrics: Codable, Sendable, Equatable {
    public var sseLastEventAt: Date?
    public var sseReconnects: Int
    public var reconcileRuns: Int
    public var reconcileDifferences: Int
    public var journalMinimumSequence: Int64
    public var journalMaximumSequence: Int64
    public var journalBytes: Int64
    public var outboxAgeSeconds: Double?
    public var outboxAttempts: Int
    public var sqliteBusyCount: Int
    public var echoMatched: Int
    public var echoDifferences: Int
    public var scopeRejectedEvents: Int
    public init() { sseLastEventAt = nil; sseReconnects = 0; reconcileRuns = 0; reconcileDifferences = 0; journalMinimumSequence = 0; journalMaximumSequence = 0; journalBytes = 0; outboxAgeSeconds = nil; outboxAttempts = 0; sqliteBusyCount = 0; echoMatched = 0; echoDifferences = 0; scopeRejectedEvents = 0 }
}

public final class MetricsStore: @unchecked Sendable {
    private var metrics = ConsistencyMetrics()
    private let lock = NSLock()
    public init() {}
    public func recordSSEEvent(at date: Date = Date()) { lock.lock(); metrics.sseLastEventAt = date; lock.unlock() }
    public func recordReconnect() { lock.lock(); metrics.sseReconnects += 1; lock.unlock() }
    public func recordReconcile(differences: Int) { lock.lock(); metrics.reconcileRuns += 1; metrics.reconcileDifferences += differences; lock.unlock() }
    public func recordEcho(matched: Bool) { lock.lock(); if matched { metrics.echoMatched += 1 } else { metrics.echoDifferences += 1 }; lock.unlock() }
    public func recordRejectedScopeEvent() { lock.lock(); metrics.scopeRejectedEvents += 1; lock.unlock() }
    public func snapshot() -> ConsistencyMetrics { lock.lock(); defer { lock.unlock() }; return metrics }
}
