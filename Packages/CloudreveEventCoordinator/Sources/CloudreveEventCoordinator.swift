import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge

public struct SSEEvent: Equatable, Sendable {
    public let event: String?
    public let data: String
    public let id: String?
    public init(event: String?, data: String, id: String?) { self.event = event; self.data = data; self.id = id }
}

public enum SSEParserError: Error, Equatable { case frameTooLarge, invalidUTF8 }

public final class SSEParser: @unchecked Sendable {
    private var buffer = [UInt8]()
    private var event: String?
    private var id: String?
    private var dataLines: [String] = []
    private let maxFrameBytes: Int
    private let lock = NSLock()

    public init(maxFrameBytes: Int = 1024 * 1024) { self.maxFrameBytes = maxFrameBytes }

    public func append(_ bytes: Data) throws -> [SSEEvent] {
        try withLock {
            buffer.append(contentsOf: bytes)
            guard buffer.count <= maxFrameBytes else { throw SSEParserError.frameTooLarge }
            var events: [SSEEvent] = []
            while let end = lineEnd(in: buffer) {
                let lineBytes = Array(buffer.prefix(end.offset))
                buffer.removeFirst(end.offset + end.newlineLength)
                try consume(line: lineBytes, events: &events)
            }
            return events
        }
    }

    public func finish() throws -> [SSEEvent] {
        try withLock {
            var events: [SSEEvent] = []
            if !buffer.isEmpty { try consume(line: buffer, events: &events); buffer.removeAll(keepingCapacity: true) }
            flush(&events)
            return events
        }
    }

    private func consume(line rawLine: [UInt8], events: inout [SSEEvent]) throws {
        var line = rawLine
        if line.last == 13 { line.removeLast() }
        if line.isEmpty { flush(&events); return }
        guard let text = String(bytes: line, encoding: .utf8) else { throw SSEParserError.invalidUTF8 }
        if text.hasPrefix(":") { return }
        let split = text.firstIndex(of: ":")
        let field = split.map { String(text[..<$0]) } ?? text
        var value = split.map { String(text[text.index(after: $0)...]) } ?? ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        case "id": id = value
        default: break
        }
    }

    private func flush(_ events: inout [SSEEvent]) {
        guard event != nil || id != nil || !dataLines.isEmpty else { return }
        events.append(SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id))
        event = nil; id = nil; dataLines.removeAll(keepingCapacity: true)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}

private struct LineEnd { let offset: Int; let newlineLength: Int }
private func lineEnd(in data: [UInt8]) -> LineEnd? {
    for index in data.indices {
        if data[index] == 10 { return LineEnd(offset: index, newlineLength: 1) }
        if data[index] == 13 {
            if index + 1 == data.count { return nil }
            return LineEnd(offset: index, newlineLength: data[index + 1] == 10 ? 2 : 1)
        }
    }
    return nil
}

public struct ReconnectPolicy: Sendable {
    public private(set) var attempt = 0
    public let maximumDelay: TimeInterval
    public init(maximumDelay: TimeInterval = 60) { self.maximumDelay = maximumDelay }
    public mutating func reset() { attempt = 0 }
    public mutating func nextDelay(jitter: TimeInterval) -> TimeInterval {
        let base = min(maximumDelay, pow(2, Double(min(attempt, 6))))
        attempt += 1
        return min(maximumDelay, max(0, min(1, jitter)) * base)
    }
}

public enum RemoteEventKind: String, Sendable { case subscribed, resumed, keepAlive = "keep-alive", reconnectRequired = "reconnect-required", file, unknown }

public struct RemoteEventHint: Sendable {
    public let kind: RemoteEventKind
    public let remoteID: String?
    public let fromURI: String?
    public let toURI: String?
    public let payload: String?
    public init(kind: RemoteEventKind, remoteID: String? = nil, fromURI: String? = nil, toURI: String? = nil, payload: String? = nil) { self.kind = kind; self.remoteID = remoteID; self.fromURI = fromURI; self.toURI = toURI; self.payload = payload }
}

public struct EchoEvidence: Sendable, Equatable {
    public let remoteID: String
    public let operationID: UUID
    public let expectedParentIdentifier: String?
    public let expectedName: String?
    public let expectedTrashed: Bool?
    public let expectedVersion: Data?
    public init(remoteID: String, operationID: UUID, expectedParentIdentifier: String? = nil, expectedName: String? = nil, expectedTrashed: Bool? = nil, expectedVersion: Data? = nil) { self.remoteID = remoteID; self.operationID = operationID; self.expectedParentIdentifier = expectedParentIdentifier; self.expectedName = expectedName; self.expectedTrashed = expectedTrashed; self.expectedVersion = expectedVersion }
}

public enum EchoMatchResult: Equatable, Sendable { case matched, realDifference, unknown }

public enum EchoMatcher {
    public static func match(_ evidence: EchoEvidence?, item: RemoteItem?) -> EchoMatchResult {
        guard let evidence, let item, evidence.remoteID == item.remoteID else { return .unknown }
        if let parent = evidence.expectedParentIdentifier, parent != item.parentIdentifier { return .realDifference }
        if let name = evidence.expectedName, name != item.name { return .realDifference }
        if let trashed = evidence.expectedTrashed, trashed != item.trashed { return .realDifference }
        if let version = evidence.expectedVersion, version != item.version.content { return .realDifference }
        return .matched
    }
}

public protocol EventStream: Sendable {
    func next() async throws -> SSEEvent?
}

public protocol EventCoordinatorDelegate: Sendable {
    func handle(hint: RemoteEventHint) async
    func markEventDegraded() async
    func reconcile(reason: String) async
}

public actor EventCoordinator {
    private let delegate: EventCoordinatorDelegate
    private var running = false

    public init(delegate: EventCoordinatorDelegate) { self.delegate = delegate }

    public func stop() { running = false }

    public func run(stream: EventStream) async {
        running = true
        while running && !Task.isCancelled {
            do {
                guard let event = try await stream.next() else { await delegate.markEventDegraded(); await delegate.reconcile(reason: "stream_ended"); break }
                await consume(event)
            } catch {
                await delegate.markEventDegraded()
                await delegate.reconcile(reason: "stream_error")
                break
            }
        }
    }

    private func consume(_ event: SSEEvent) async {
        let eventName = event.event?.lowercased() ?? "message"
        switch eventName {
        case "subscribed": await delegate.reconcile(reason: "subscribed")
        case "resumed": await delegate.reconcile(reason: "resumed_unknown_gap")
        case "keep-alive", "keepalive": break
        case "reconnect-required": await delegate.markEventDegraded(); await delegate.reconcile(reason: "reconnect_required")
        default:
            guard let name = event.event?.lowercased(), ["event", "file", "create", "modify", "rename", "delete"].contains(name), !event.data.isEmpty else {
                await delegate.markEventDegraded()
                await delegate.reconcile(reason: "unknown_or_malformed_event")
                return
            }
            await delegate.handle(hint: RemoteEventHint(kind: .file, payload: event.data))
        }
    }
}

public protocol EventStreamFactory: Sendable {
    func open() async throws -> EventStream
}

public protocol EventSupervisorDelegate: EventCoordinatorDelegate {
    func setConnectionState(_ state: ConnectionState) async
}

public enum ConnectionState: String, Sendable { case connecting, subscribed, resumedUnknownGap = "resumed_unknown_gap", degraded, offline, stopped }

/// Owns one stream per Domain. A stream ending is a reconnect condition, not
/// a healthy completion; each new subscription asks the delegate to reconcile.
public actor EventSupervisor {
    private let factory: EventStreamFactory
    private let delegate: EventSupervisorDelegate
    private var policy = ReconnectPolicy()
    private var running = false

    public init(factory: EventStreamFactory, delegate: EventSupervisorDelegate) { self.factory = factory; self.delegate = delegate }

    public func stop() async { running = false; await delegate.setConnectionState(.stopped) }

    public func run() async {
        running = true
        while running && !Task.isCancelled {
            await delegate.setConnectionState(.connecting)
            do {
                let stream = try await factory.open()
                await delegate.setConnectionState(.subscribed)
                let coordinator = EventCoordinator(delegate: delegate)
                await coordinator.run(stream: stream)
                guard running else { break }
                await delegate.setConnectionState(.degraded)
                await delegate.reconcile(reason: "stream_ended")
            } catch {
                await delegate.setConnectionState(.degraded)
                await delegate.markEventDegraded()
                await delegate.reconcile(reason: "connect_error")
            }
            let delay = policy.nextDelay(jitter: Double.random(in: 0...1))
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}

public protocol WorkingSetSignaller: Sendable {
    func signalWorkingSet() async throws
}

public final class FileProviderWorkingSetSignaller: WorkingSetSignaller, @unchecked Sendable {
    private let manager: NSFileProviderManager
    public init(manager: NSFileProviderManager) { self.manager = manager }
    public func signalWorkingSet() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.signalEnumerator(for: .workingSet) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

public actor SignalOutboxDrainer {
    private let store: SQLiteStateStore
    private let signaller: WorkingSetSignaller

    public init(store: SQLiteStateStore, signaller: WorkingSetSignaller) { self.store = store; self.signaller = signaller }

    public func drain() async {
        while let revision = try? store.latestPendingOutboxRevision() {
            do {
                try await signaller.signalWorkingSet()
                try store.acknowledgeOutbox(upTo: revision)
            } catch {
                return
            }
        }
    }
}

public struct EnrichedRemoteChange: Sendable, Equatable {
    public let item: RemoteItem
    public let oldParentIdentifier: String?
    public let newParentIdentifier: String?
    public let kind: String
    public init(item: RemoteItem, oldParentIdentifier: String?, newParentIdentifier: String?, kind: String) { self.item = item; self.oldParentIdentifier = oldParentIdentifier; self.newParentIdentifier = newParentIdentifier; self.kind = kind }
}

public actor EventJournalWriter {
    private let store: SQLiteStateStore
    private let outboxDrainer: SignalOutboxDrainer?

    public init(store: SQLiteStateStore, outboxDrainer: SignalOutboxDrainer? = nil) { self.store = store; self.outboxDrainer = outboxDrainer }

    public func commit(_ change: EnrichedRemoteChange) async throws -> JournalChange {
        try store.insertItem(change.item)
        let journal = try store.appendProviderChange(itemIdentifier: change.item.itemIdentifier, oldParentIdentifier: change.oldParentIdentifier, newParentIdentifier: change.newParentIdentifier, kind: change.kind, version: change.item.version.content, origin: "remote_event")
        await outboxDrainer?.drain()
        return journal
    }

    public func markReconcileStatus(_ status: String, at date: Date = Date()) {
        try? store.updateSyncState(reconcileAt: status == "completed" ? date : nil, reconcileStatus: status)
    }
}

public struct ReconcileScheduler: Sendable {
    public let workingInterval: TimeInterval
    public let fullInterval: TimeInterval
    public init(workingInterval: TimeInterval = 6 * 60 * 60, fullInterval: TimeInterval = 24 * 60 * 60) { self.workingInterval = workingInterval; self.fullInterval = fullInterval }
    public func shouldReconcile(lastWorking: Date?, lastFull: Date?, now: Date = Date(), reason: String? = nil) -> Bool {
        if reason != nil { return true }
        if lastWorking.map({ now.timeIntervalSince($0) >= workingInterval }) ?? true { return true }
        return lastFull.map({ now.timeIntervalSince($0) >= fullInterval }) ?? true
    }
}
