import Foundation
import FileProvider
import ServiceManagement
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit

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
        guard let remoteID, !remoteID.isEmpty, remoteID != rootRemoteID, !remoteID.contains(where: { $0.isWhitespace || $0 == "\0" }) else { rejectedCount += 1; return false }
        let normalizedRoot = canonicalURI(rootURI)
        guard normalizedRoot != nil else { rejectedCount += 1; return false }
        for uri in [fromURI, toURI].compactMap({ $0 }) {
            guard let normalized = canonicalURI(uri), let normalizedRoot else { rejectedCount += 1; return false }
            if normalizedRoot != "/" && normalized != normalizedRoot && !normalized.hasPrefix(normalizedRoot + "/") {
                rejectedCount += 1
                return false
            }
        }
        return true
    }
}

private func canonicalURI(_ value: String) -> String? {
    if value.hasPrefix("cloudreve://"), let components = URLComponents(string: value), let host = components.host, let path = CloudreveRemoteURI.path(value) {
        let user = components.user.map { "\($0)@" } ?? ""
        return "cloudreve://\(user)\(host.lowercased())\(path == "/" ? "" : path)"
    }
    let normalized = value.replacingOccurrences(of: "\\", with: "/")
    guard normalized.hasPrefix("/"), !normalized.contains("\0") else { return nil }
    var parts: [Substring] = []
    for part in normalized.split(separator: "/") {
        guard part != ".", part != ".." else { return nil }
        parts.append(part)
    }
    return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
}

private func canonicalURI(_ value: String, accountID: String) -> String? {
    try? CloudreveRemoteURI.canonical(value, accountID: accountID)
}

public struct RemoteEventPayload: Codable, Sendable, Equatable {
    public let type: String?
    public let id: String?
    public let from: String?
    public let to: String?
    public init(type: String?, id: String?, from: String?, to: String?) { self.type = type; self.id = id; self.from = from; self.to = to }

    private enum CodingKeys: String, CodingKey { case type; case id; case fileID = "file_id"; case from; case to }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        let directID = try container.decodeIfPresent(String.self, forKey: .id)
        let fileID = try container.decodeIfPresent(String.self, forKey: .fileID)
        id = directID ?? fileID
        from = try container.decodeIfPresent(String.self, forKey: .from)
        to = try container.decodeIfPresent(String.self, forKey: .to)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(to, forKey: .to)
    }
}

private struct EventAPIEnvelope<Value: Decodable>: Decodable {
    let code: Int
    let data: Value?
}

private struct EventFileDTO: Decodable {
    let type: Int
    let id: String
    let name: String
    let size: Int64?
    let path: String
    let permission: String?
    let capability: String?
    let updatedAt: String?
    let createdAt: String?
    let primaryEntity: String?

    enum CodingKeys: String, CodingKey {
        case type; case id; case name; case size; case path; case permission; case capability
        case updatedAt = "updated_at"; case createdAt = "created_at"; case primaryEntity = "primary_entity"
    }
}

private func parseEventDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: value)
}

/// Enriches Cloudreve's small `type/file_id/from/to` hint through the
/// authenticated `file/info` endpoint before touching local state.
public final class CloudreveEventEnricher: RemoteEventEnricher, @unchecked Sendable {
    private let origin: URL
    private let rootRemoteID: String
    private let rootURI: String
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let credentialReference: String
    private let session: URLSession
    private let credentialRefresh: CredentialRefreshService

    public init(origin: URL, rootURI: String, rootRemoteID: String = "", store: SQLiteStateStore, vault: CredentialVault, credentialReference: String, session: URLSession? = nil) {
        self.origin = origin; self.rootRemoteID = rootRemoteID; self.rootURI = rootURI; self.store = store; self.vault = vault; self.credentialReference = credentialReference
        self.credentialRefresh = CredentialRefreshService(vault: vault, session: session)
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration, delegate: EventRedirectPolicy(), delegateQueue: nil)
        }
    }

    public func enrich(_ hint: RemoteEventHint) async throws -> EnrichedRemoteChange? {
        guard let remoteID = hint.remoteID, !remoteID.isEmpty else { throw EventEnrichmentError.malformedHint }
        guard let file = try await fetchFile(id: remoteID) else { return nil }
        guard let normalizedPath = canonicalURI(file.path, accountID: URLComponents(string: rootURI)?.user ?? ""),
              file.id != rootRemoteID,
              CloudreveRemoteURI.isWithin(normalizedPath, root: rootURI) else {
            throw EventEnrichmentError.outsideScope
        }
        let existingIdentifier = try store.itemIdentifier(forRemoteID: remoteID)
        let parentIdentifier = try await parentIdentifier(for: normalizedPath, existingIdentifier: existingIdentifier)
        let kind: RemoteItemKind = file.type == 1 ? .folder : .file
        let contentRevision = file.primaryEntity ?? file.updatedAt ?? file.createdAt ?? file.id
        let readable = file.permission.map { $0.contains("r") } ?? true
        let writable = file.capability.map { $0.contains("w") } ?? false
        let item = RemoteItem(itemIdentifier: existingIdentifier ?? CloudreveIdentifier.item(), remoteID: file.id, parentIdentifier: parentIdentifier, name: file.name, uri: normalizedPath, kind: kind, contentType: kind == .folder ? "public.folder" : "public.data", size: max(0, file.size ?? 0), remoteVersion: file.primaryEntity, version: ItemVersion(content: VersionHasher.content(primaryEntity: contentRevision), metadata: VersionHasher.metadata(parent: parentIdentifier, name: file.name, kind: kind, permissionBits: readable ? 1 : 0, revision: file.updatedAt)), creationDate: parseEventDate(file.createdAt), contentModificationDate: parseEventDate(file.updatedAt), canRead: readable, canWrite: writable && readable, canAddChildren: writable && readable && kind == .folder, canTrash: writable && readable && (file.capability?.contains("d") ?? false), canDelete: false)
        return EnrichedRemoteChange(item: item, oldParentIdentifier: existingIdentifier.flatMap { try? store.item(identifier: $0)?.parentIdentifier }, newParentIdentifier: parentIdentifier, kind: hint.kind.rawValue)
    }

    private func fetchFile(id: String) async throws -> EventFileDTO? {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4/file/info"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "extended", value: "true")]
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        let credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EventEnrichmentError.unavailable }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        guard (200..<300).contains(http.statusCode) else { throw EventEnrichmentError.unavailable }
        let envelope = try JSONDecoder().decode(EventAPIEnvelope<EventFileDTO>.self, from: data)
        guard envelope.code == 0 else { return nil }
        return envelope.data
    }

    private func parentIdentifier(for path: String, existingIdentifier: String?) async throws -> String? {
        guard let parentURI = CloudreveRemoteURI.parent(path), let rootURI = canonicalURI(rootURI) else { throw EventEnrichmentError.unavailable }
        if parentURI == rootURI { return NSFileProviderItemIdentifier.rootContainer.rawValue }
        if let parentIdentifier = try store.itemIdentifier(forRemoteURI: parentURI) { return parentIdentifier }
        _ = existingIdentifier
        throw EventEnrichmentError.unavailable
    }
}

private final class EventRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let current = task.currentRequest?.url
        let next = request.url
        guard current?.scheme == next?.scheme, current?.host == next?.host, current?.port == next?.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}

private struct ReconcilePagination: Decodable {
    let page: Int?
    let pageSize: Int?
    let totalItems: Int64?
    let nextToken: String?
    enum CodingKeys: String, CodingKey { case page; case pageSize = "page_size"; case totalItems = "total_items"; case nextToken = "next_token" }
}

private struct ReconcileListDTO: Decodable { let files: [EventFileDTO]; let pagination: ReconcilePagination? }

private struct ReconcileWork: Codable {
    let uri: String
    let parent: String
}

private struct ReconcileCursor: Codable {
    let queue: [ReconcileWork]
    let current: ReconcileWork?
    let page: Int
    let token: String?
    let usedTokens: [String]
}

/// Performs a bounded, resumable normal-tree scan for a Domain. It never
/// creates tombstones when trash coverage is unavailable; missing-item
/// deletion remains fail-closed until a verified trash contract exists.
public final class CloudreveReconciliationService: @unchecked Sendable {
    private let origin: URL
    private let store: SQLiteStateStore
    private let registry: SQLiteStateStore?
    private let vault: CredentialVault
    private let credentialReference: String
    private let session: URLSession
    private let credentialRefresh: CredentialRefreshService

    public init(origin: URL, store: SQLiteStateStore, registry: SQLiteStateStore? = nil, vault: CredentialVault, credentialReference: String, session: URLSession? = nil) {
        self.origin = origin; self.store = store; self.registry = registry; self.vault = vault; self.credentialReference = credentialReference
        self.credentialRefresh = CredentialRefreshService(vault: vault, session: session)
        if let session { self.session = session }
        else { self.session = URLSession(configuration: .ephemeral, delegate: EventRedirectPolicy(), delegateQueue: nil) }
    }

    public func reconcile(descriptor: DomainDescriptor) async throws {
        let activeRun = try store.activeReconcileRuns().first(where: { $0.scope == descriptor.currentRootURI })
        let runID = activeRun?.id ?? UUID()
        var savedCursor = activeRun?.cursor.flatMap { try? JSONDecoder().decode(ReconcileCursor.self, from: Data($0.utf8)) }
        if savedCursor?.current == nil && savedCursor?.queue.isEmpty == true { savedCursor = nil }
        if activeRun == nil {
            try store.startReconcile(runID: runID, scope: descriptor.currentRootURI, generation: UInt64(Date().timeIntervalSince1970), phase: "prepared", cursor: nil)
        }
        try store.updateSyncState(reconcileStatus: "scanning_normal")
        do {
            let root = try await fetchFile(id: descriptor.rootRemoteID)
        guard root.id == descriptor.rootRemoteID, root.type == 1 else { throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true) }
        let rootPath = try CloudreveRemoteURI.canonical(root.path, accountID: descriptor.accountID)
        let rootScope = try RemoteScope(origin: descriptor.scope.origin, accountID: descriptor.accountID, rootURI: rootPath)
        if rootScope.rootURI != descriptor.currentRootURI {
            savedCursor = nil
            if let registry, try registry.allDomains().contains(where: { stored in
                guard stored.identifier != descriptor.identifier, let otherScope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return false }
                return otherScope.overlaps(rootScope)
            }) {
                throw CoreFailure(code: .scopeConflict, retryable: false, userActionRequired: true)
            }
            try store.updateDomainRootURI(identifier: descriptor.identifier, rootURI: rootScope.rootURI)
            try registry?.updateDomainRootURI(identifier: descriptor.identifier, rootURI: rootScope.rootURI)
        }
        var queue: [ReconcileWork] = savedCursor?.queue ?? [ReconcileWork(uri: rootScope.rootURI, parent: NSFileProviderItemIdentifier.rootContainer.rawValue)]
        var currentWork = savedCursor?.current
        var page = savedCursor?.page ?? 1
        var token = savedCursor?.token
        var usedTokens = Set(savedCursor?.usedTokens ?? [])
        var seen = Set<String>([descriptor.rootRemoteID])
        if savedCursor == nil {
            try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: rootScope.rootURI, state: "active")
        } else if let savedCursor {
            try persistCursor(runID: runID, queue: savedCursor.queue, current: savedCursor.current, page: savedCursor.page, token: savedCursor.token, usedTokens: Set(savedCursor.usedTokens))
        }
        while currentWork != nil || !queue.isEmpty {
            let current = currentWork ?? queue.removeFirst()
            currentWork = current
            repeat {
                let response = try await list(uri: current.uri, page: Int32(page), token: token)
                try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: token ?? "page:\(page)", state: "active")
                for file in response.files {
                    guard file.id != descriptor.rootRemoteID else { continue }
                    guard let normalizedPath = canonicalURI(file.path, accountID: descriptor.accountID), CloudreveRemoteURI.isWithin(normalizedPath, root: rootScope.rootURI) else { throw CoreFailure(code: .scopeConflict, retryable: false, userActionRequired: true) }
                    let itemIdentifier = try store.itemIdentifier(forRemoteID: file.id) ?? CloudreveIdentifier.item()
                    let item = try makeItem(file, parentIdentifier: current.parent, itemIdentifier: itemIdentifier, accountID: descriptor.accountID)
                    if let old = try store.item(identifier: itemIdentifier), old == item {
                        try store.insertItem(item)
                    } else {
                        _ = try store.commitProviderChange(item: item, oldParentIdentifier: try store.item(identifier: itemIdentifier)?.parentIdentifier, newParentIdentifier: item.parentIdentifier, kind: "reconciled", origin: "reconciliation")
                    }
                    seen.insert(file.id)
                    if file.type == 1 { queue.append(ReconcileWork(uri: normalizedPath, parent: itemIdentifier)) }
                }
                if let nextToken = response.pagination?.nextToken {
                    guard usedTokens.insert(nextToken).inserted else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
                    token = nextToken; page = 0
                    try persistCursor(runID: runID, queue: queue, current: current, page: page, token: token, usedTokens: usedTokens)
                } else if let total = response.pagination?.totalItems {
                    let effectivePageSize = max(1, response.pagination?.pageSize ?? response.files.count)
                    guard Int64(max(1, Int(page))) * Int64(effectivePageSize) < total, !response.files.isEmpty else { break }
                    page += 1; token = nil
                    try persistCursor(runID: runID, queue: queue, current: current, page: page, token: token, usedTokens: usedTokens)
                } else { break }
            } while true
            currentWork = nil
            page = 1
            token = nil
            usedTokens.removeAll()
            try persistCursor(runID: runID, queue: queue, current: nil, page: page, token: nil, usedTokens: usedTokens)
        }
        _ = seen
        try store.updateReconcile(runID: runID, phase: "completed", cursor: nil, state: "completed")
        try store.updateSyncState(reconcileAt: Date(), reconcileStatus: "completed")
        } catch {
            try? store.updateReconcile(runID: runID, phase: "failed", cursor: nil, state: "failed")
            throw error
        }
    }

    private func persistCursor(runID: UUID, queue: [ReconcileWork], current: ReconcileWork?, page: Int, token: String?, usedTokens: Set<String>) throws {
        let full = ReconcileCursor(queue: queue, current: current, page: page, token: token, usedTokens: usedTokens.sorted())
        var data = try JSONEncoder().encode(full)
        if data.count > 64 * 1024 {
            let bounded = ReconcileCursor(queue: [], current: nil, page: 1, token: nil, usedTokens: [])
            data = try JSONEncoder().encode(bounded)
        }
        try store.updateReconcile(runID: runID, phase: "scanning_normal", cursor: String(data: data, encoding: .utf8), state: "active")
    }

    private func fetchFile(id: String) async throws -> EventFileDTO {
        let value: EventFileDTO? = try await request(path: "file/info", query: [URLQueryItem(name: "id", value: id), URLQueryItem(name: "extended", value: "true")])
        guard let value else { throw CoreFailure(code: .rootUnavailable, retryable: false, userActionRequired: true) }
        return value
    }

    private func list(uri: String, page: Int32, token: String?) async throws -> ReconcileListDTO {
        var query = [URLQueryItem(name: "uri", value: uri), URLQueryItem(name: "page_size", value: "500"), URLQueryItem(name: "order_by", value: "name"), URLQueryItem(name: "order_direction", value: "asc")]
        if let token { query.append(URLQueryItem(name: "next_page_token", value: token)) } else { query.append(URLQueryItem(name: "page", value: String(page))) }
        guard let value: ReconcileListDTO = try await request(path: "file", query: query) else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
        return value
    }

    private func request<Value: Decodable>(path: String, query: [URLQueryItem]) async throws -> Value? {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4").appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        let credential = try await credentialRefresh.credential(origin: origin, reference: credentialReference)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        if http.statusCode == 401 { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        let envelope = try JSONDecoder().decode(EventAPIEnvelope<Value>.self, from: data)
        guard envelope.code == 0 else { return nil }
        return envelope.data
    }

    private func makeItem(_ file: EventFileDTO, parentIdentifier: String, itemIdentifier: String, accountID: String) throws -> RemoteItem {
        let kind: RemoteItemKind = file.type == 1 ? .folder : .file
        let normalizedPath = try CloudreveRemoteURI.canonical(file.path, accountID: accountID)
        let contentRevision = file.primaryEntity ?? file.updatedAt ?? file.createdAt ?? file.id
        let readable = file.permission.map { $0.contains("r") } ?? true
        let writable = file.capability.map { $0.contains("w") } ?? false
        return RemoteItem(itemIdentifier: itemIdentifier, remoteID: file.id, parentIdentifier: parentIdentifier, name: file.name, uri: normalizedPath, kind: kind, contentType: kind == .folder ? "public.folder" : "public.data", size: max(0, file.size ?? 0), remoteVersion: file.primaryEntity, version: ItemVersion(content: VersionHasher.content(primaryEntity: contentRevision), metadata: VersionHasher.metadata(parent: parentIdentifier, name: file.name, kind: kind, permissionBits: readable ? 1 : 0, revision: file.updatedAt)), creationDate: parseEventDate(file.createdAt), contentModificationDate: parseEventDate(file.updatedAt), canRead: readable, canWrite: writable && readable, canAddChildren: writable && readable && kind == .folder, canTrash: false, canDelete: false)
    }
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
    private var seenVersions: [String: ItemVersion] = [:]
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
                seenVersions[change.item.remoteID ?? change.item.itemIdentifier] = change.item.version
                return .matched
            case .realDifference, .unknown:
                let versionKey = change.item.remoteID ?? change.item.itemIdentifier
                if seenVersions[versionKey] == change.item.version { return .matched }
                do {
                    _ = try await writer.commit(change)
                } catch {
                    pendingScopes.insert(hint.fromURI ?? hint.toURI ?? "root")
                    return .unknown
                }
                seenVersions[versionKey] = change.item.version
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

/// Production wiring for one Domain's live event path. It deliberately keeps
/// reconciliation as a persisted request until the full normal/trash scan
/// worker is available; an event stream can therefore never promote a Domain
/// to healthy on its own.
public actor DomainEventRuntime: EventSupervisorDelegate {
    private let store: SQLiteStateStore
    private let registry: SQLiteStateStore?
    private var pipeline: EventNormalizationPipeline
    private let reconciler: CloudreveReconciliationService
    private let outboxDrainer: SignalOutboxDrainer?
    private let vault: CredentialVault
    private var connectionState: ConnectionState = .stopped
    private let domainIdentifier: String
    private var currentRootURI: String
    private var streamRestartRequired = false
    private let onRootChanged: (@Sendable (String) async -> Void)?

    public init?(descriptor: DomainDescriptor, store: SQLiteStateStore, registry: SQLiteStateStore? = nil, vault: CredentialVault, onRootChanged: (@Sendable (String) async -> Void)? = nil) {
        guard let origin = URL(string: descriptor.scope.origin) else { return nil }
        self.store = store
        self.registry = registry
        self.domainIdentifier = descriptor.identifier
        self.currentRootURI = descriptor.currentRootURI
        self.onRootChanged = onRootChanged
        self.vault = vault
        let enricher = CloudreveEventEnricher(origin: origin, rootURI: descriptor.currentRootURI, rootRemoteID: descriptor.rootRemoteID, store: store, vault: vault, credentialReference: descriptor.secretReference)
        self.reconciler = CloudreveReconciliationService(origin: origin, store: store, registry: registry, vault: vault, credentialReference: descriptor.secretReference)
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(descriptor.identifier), displayName: descriptor.displayName)
        let signaller = NSFileProviderManager(for: domain).map(FileProviderWorkingSetSignaller.init(manager:))
        let drainer = signaller.map { SignalOutboxDrainer(store: store, signaller: $0) }
        self.outboxDrainer = drainer
        self.pipeline = EventNormalizationPipeline(scopeGuard: EventScopeGuard(rootRemoteID: descriptor.rootRemoteID, rootURI: descriptor.currentRootURI), enricher: enricher, writer: EventJournalWriter(store: store, outboxDrainer: drainer))
    }

    public func handle(hint: RemoteEventHint) async {
        let result = await pipeline.consume(hint)
        if result == .unknown { await reconcile(reason: "event_enrichment_unavailable") }
        else { try? store.updateSyncState(eventAt: Date(), reconcileStatus: "event_active") }
    }

    public func markEventDegraded() async {
        try? store.setDomainStatus(identifier: domainIdentifier, status: .eventDegraded)
        try? registry?.setDomainStatus(identifier: domainIdentifier, status: .eventDegraded)
        try? store.updateSyncState(reconcileStatus: "event_degraded")
    }

    public func markAuthenticationExpired() async {
        connectionState = .authExpired
        try? store.setDomainStatus(identifier: domainIdentifier, status: .authExpired)
        try? registry?.setDomainStatus(identifier: domainIdentifier, status: .authExpired)
        try? store.updateSyncState(reconcileStatus: "auth_expired")
    }

    public func reconcile(reason: String) async {
        try? store.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
        try? registry?.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
        try? store.updateSyncState(reconcileStatus: "requested:\(reason)")
        do {
            guard let descriptor = try store.domain(identifier: domainIdentifier), let scope = try? RemoteScope(origin: descriptor.origin, accountID: descriptor.accountID, rootURI: descriptor.rootURI) else { throw CoreFailure(code: .unknownOutcome, retryable: true) }
            var model = DomainDescriptor(identifier: descriptor.identifier, displayName: descriptor.displayName, scope: scope, rootRemoteID: descriptor.rootRemoteID, accountID: descriptor.accountID, secretReference: descriptor.secretReference, capabilitySnapshot: descriptor.capabilitySnapshot, iconURL: descriptor.iconURL)
            model.status = .reconciling
            try await reconciler.reconcile(descriptor: model)
            await outboxDrainer?.drain()
            let updated: StoredDomain?
            do { updated = try store.domain(identifier: domainIdentifier) } catch {
                await markEventDegraded()
                return
            }
            guard let updated else {
                await markEventDegraded()
                return
            }
            if updated.rootURI != currentRootURI {
                currentRootURI = updated.rootURI
                let updatedScope = try? RemoteScope(origin: updated.origin, accountID: updated.accountID, rootURI: updated.rootURI)
                if let updatedScope {
                    guard let updatedOrigin = URL(string: updated.origin) else {
                        await markEventDegraded()
                        return
                    }
                    let enricher = CloudreveEventEnricher(origin: updatedOrigin, rootURI: updatedScope.rootURI, rootRemoteID: updated.rootRemoteID, store: store, vault: vault, credentialReference: updated.secretReference)
                    pipeline = EventNormalizationPipeline(scopeGuard: EventScopeGuard(rootRemoteID: updated.rootRemoteID, rootURI: updatedScope.rootURI), enricher: enricher, writer: EventJournalWriter(store: store, outboxDrainer: outboxDrainer))
                    streamRestartRequired = true
                    await onRootChanged?(updatedScope.rootURI)
                }
            }
            guard let hasDirtyWork = try? store.hasDirtyWork() else {
                await markEventDegraded()
                return
            }
            let nextStatus: DomainStatus
            if connectionState == .subscribed {
                nextStatus = hasDirtyWork ? .syncing : .healthy
            } else {
                nextStatus = .eventDegraded
            }
            try? store.setDomainStatus(identifier: domainIdentifier, status: nextStatus)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: nextStatus)
        } catch let failure as CoreFailure {
            if failure.code == .scopeConflict {
                try? store.setDomainStatus(identifier: domainIdentifier, status: .scopeConflict)
                try? registry?.setDomainStatus(identifier: domainIdentifier, status: .scopeConflict)
                return
            }
            if failure.code == .authentication {
                await markAuthenticationExpired()
                return
            }
            try? store.updateSyncState(reconcileStatus: "error:\(failure.code.rawValue)")
            await markEventDegraded()
        } catch {
            try? store.updateSyncState(reconcileStatus: "error")
            await markEventDegraded()
        }
    }

    public func setConnectionState(_ state: ConnectionState) async {
        connectionState = state
        switch state {
        case .degraded: await markEventDegraded()
        case .offline:
            try? store.setDomainStatus(identifier: domainIdentifier, status: .offline)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: .offline)
        case .stopped:
            try? store.setDomainStatus(identifier: domainIdentifier, status: .appNotRunning)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: .appNotRunning)
        case .connecting:
            try? store.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
        case .subscribed:
            try? store.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
            try? registry?.setDomainStatus(identifier: domainIdentifier, status: .reconciling)
            await outboxDrainer?.drain()
        case .authExpired:
            await markAuthenticationExpired()
        case .resumedUnknownGap:
            await reconcile(reason: "connection_\(state.rawValue)")
        }
    }

    public func isAuthenticationExpired() async -> Bool { connectionState == .authExpired }

    public func shouldRestartStream() async -> Bool {
        defer { streamRestartRequired = false }
        return streamRestartRequired
    }
}
