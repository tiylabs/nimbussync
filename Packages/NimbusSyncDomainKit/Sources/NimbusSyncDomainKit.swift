import Foundation
import CryptoKit

public enum CloudreveIdentifierError: Error, Equatable {
    case invalid(prefix: String)
    case sensitiveValue
}

public enum CloudreveIdentifier {
    public static let domainPrefix = "crd"
    public static let itemPrefix = "cri"

    public static func domain() -> String { "\(domainPrefix)-\(UUID().uuidString.lowercased())" }
    public static func item() -> String { "\(itemPrefix)-\(UUID().uuidString.lowercased())" }

    public static func item(forTemplate templateIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(templateIdentifier.utf8))
        let bytes = Array(digest.prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuid = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return "\(itemPrefix)-\(uuid)"
    }

    public static func validate(_ value: String, prefix: String) -> Bool {
        let expected = "\(prefix)-"
        guard value.hasPrefix(expected), value.count == expected.count + 36 else { return false }
        guard !value.contains("/"), !value.contains(":"), !value.contains("@") else { return false }
        return UUID(uuidString: String(value.dropFirst(expected.count))) != nil
    }
}

public struct RemoteScope: Codable, Hashable, Sendable {
    public let origin: String
    public let accountID: String
    public let rootURI: String

    public init(origin: String, accountID: String, rootURI: String) throws {
        guard !accountID.isEmpty, !accountID.contains(where: { $0 == "\0" || $0.isWhitespace }), var components = URLComponents(string: origin), components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw CloudreveIdentifierError.sensitiveValue
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        guard let canonicalOrigin = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw CloudreveIdentifierError.sensitiveValue }
        self.origin = canonicalOrigin
        self.accountID = accountID
        self.rootURI = try CloudreveRemoteURI.canonical(rootURI, accountID: accountID)
    }

    public var key: String { "\(origin)\u{0}\(accountID)\u{0}\(rootURI)" }

    public func overlaps(_ other: RemoteScope) -> Bool {
        guard origin == other.origin, accountID == other.accountID else { return false }
        return CloudreveRemoteURI.overlaps(rootURI, other.rootURI)
    }
}

public enum CloudreveRemoteURI {
    public static func canonical(_ rawValue: String, accountID: String) throws -> String {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("cloudreve://") {
            guard var components = URLComponents(string: raw), let host = components.host, host.lowercased() == "my", components.password == nil, components.query == nil, components.fragment == nil else { throw CloudreveIdentifierError.sensitiveValue }
            let path = try normalizedPath(components.path)
            components.scheme = "cloudreve"
            components.host = host.lowercased()
            components.port = nil
            if components.user == nil && components.host == "my" { components.user = accountID }
            guard components.user == nil || components.user == accountID else { throw CloudreveIdentifierError.sensitiveValue }
            components.path = path
            guard let value = components.string else { throw CloudreveIdentifierError.sensitiveValue }
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let path = try normalizedPath(raw)
        var components = URLComponents()
        components.scheme = "cloudreve"
        components.user = accountID
        components.host = "my"
        components.path = path == "/" ? "" : path
        guard let value = components.string else { throw CloudreveIdentifierError.sensitiveValue }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func path(_ value: String) -> String? {
        if value.hasPrefix("cloudreve://"), let components = URLComponents(string: value) { return try? normalizedPath(components.path) }
        return try? normalizedPath(value)
    }

    public static func append(_ parent: String, name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw CloudreveIdentifierError.sensitiveValue }
        guard var components = URLComponents(string: parent), components.scheme == "cloudreve" else { throw CloudreveIdentifierError.sensitiveValue }
        let parentPath = try normalizedPath(components.path)
        components.path = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        guard let result = components.string else { throw CloudreveIdentifierError.sensitiveValue }
        return result
    }

    public static func parent(_ value: String) -> String? {
        guard var components = URLComponents(string: value), components.scheme == "cloudreve", let path = try? normalizedPath(components.path) else { return nil }
        let segments = path.split(separator: "/")
        components.path = segments.count <= 1 ? "/" : "/" + segments.dropLast().joined(separator: "/")
        return components.string
    }

    public static func overlaps(_ left: String, _ right: String) -> Bool {
        guard let leftComponents = URLComponents(string: left), let rightComponents = URLComponents(string: right), leftComponents.scheme == "cloudreve", rightComponents.scheme == "cloudreve", leftComponents.host?.lowercased() == rightComponents.host?.lowercased(), leftComponents.user == rightComponents.user, let leftPath = path(left), let rightPath = path(right) else { return false }
        return leftPath == rightPath || leftPath == "/" || rightPath == "/" || leftPath.hasPrefix(rightPath + "/") || rightPath.hasPrefix(leftPath + "/")
    }

    public static func isWithin(_ value: String, root: String) -> Bool {
        guard let valueComponents = URLComponents(string: value), let rootComponents = URLComponents(string: root), valueComponents.scheme == rootComponents.scheme, valueComponents.host?.lowercased() == rootComponents.host?.lowercased(), valueComponents.user == rootComponents.user, let valuePath = path(value), let rootPath = path(root) else { return false }
        return rootPath == "/" || valuePath == rootPath || valuePath.hasPrefix(rootPath + "/")
    }

    public static func relativePath(_ value: String, root: String) -> String? {
        guard isWithin(value, root: root), let valuePath = path(value), let rootPath = path(root) else { return nil }
        guard rootPath != "/" else { return valuePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return String(valuePath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private static func normalizedPath(_ rawPath: String) throws -> String {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.split(separator: "/").contains(where: { $0 == ".." || $0.contains("\0") }) else { throw CloudreveIdentifierError.sensitiveValue }
        let parts = normalized.split(separator: "/").filter { !$0.isEmpty && $0 != "." }
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }
}

public enum RemoteItemKind: String, Codable, Sendable {
    case file
    case folder
    case symlink
    case unsupported
}

public struct CapabilitySnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case verified, unsupported, unverified }
    public struct Provider: Codable, Equatable, Sendable {
        public let name: String
        public let read: State
        public let write: State
        public let resumable: State
        public let zeroByte: State
        public let crypto: State
        public init(name: String, read: State, write: State, resumable: State, zeroByte: State, crypto: State) {
            self.name = name; self.read = read; self.write = write; self.resumable = resumable; self.zeroByte = zeroByte; self.crypto = crypto
        }
    }

    public var revision: UInt64
    public var serverVersion: String?
    public var stableItemIdentity: State
    public var stableRootIdentity: State
    public var conditionalContentWrite: State
    public var idempotentCreate: State
    public var trashRestore: State
    public var sse: State
    public var providers: [Provider]

    public init(revision: UInt64 = 0, serverVersion: String? = nil, stableItemIdentity: State = .unverified, stableRootIdentity: State = .unverified, conditionalContentWrite: State = .unsupported, idempotentCreate: State = .unsupported, trashRestore: State = .unsupported, sse: State = .unverified, providers: [Provider] = []) {
        self.revision = revision; self.serverVersion = serverVersion; self.stableItemIdentity = stableItemIdentity; self.stableRootIdentity = stableRootIdentity; self.conditionalContentWrite = conditionalContentWrite; self.idempotentCreate = idempotentCreate; self.trashRestore = trashRestore; self.sse = sse; self.providers = providers
    }

    public var allowsWrite: Bool { stableItemIdentity == .verified && stableRootIdentity == .verified && conditionalContentWrite == .verified && idempotentCreate == .verified }
    public func provider(named name: String) -> Provider? { providers.first { $0.name == name } }
    public func canWrite(provider providerName: String) -> Bool {
        guard allowsWrite, let provider = provider(named: providerName) else { return false }
        return provider.write == .verified && provider.resumable == .verified && provider.zeroByte == .verified
    }
}

public struct ItemVersion: Codable, Equatable, Sendable {
    public let content: Data
    public let metadata: Data
    public init(content: Data, metadata: Data) { self.content = content; self.metadata = metadata }
}

public struct RemoteItem: Codable, Equatable, Sendable {
    public let itemIdentifier: String
    public var remoteID: String?
    public var parentIdentifier: String?
    public var trashOriginalParentIdentifier: String?
    public var name: String
    public var uri: String
    public var kind: RemoteItemKind
    public var contentType: String
    public var size: Int64
    public var remoteVersion: String?
    public var version: ItemVersion
    public var creationDate: Date?
    public var contentModificationDate: Date?
    public var canRead: Bool
    public var canWrite: Bool
    public var canAddChildren: Bool
    public var canTrash: Bool
    public var canDelete: Bool
    public var trashed: Bool
    public var tombstone: Bool

    public init(itemIdentifier: String = CloudreveIdentifier.item(), remoteID: String? = nil, parentIdentifier: String? = nil, name: String, uri: String, kind: RemoteItemKind, contentType: String, size: Int64 = 0, remoteVersion: String? = nil, version: ItemVersion, creationDate: Date? = nil, contentModificationDate: Date? = nil, trashOriginalParentIdentifier: String? = nil, canRead: Bool = true, canWrite: Bool = false, canAddChildren: Bool = false, canTrash: Bool = false, canDelete: Bool = false, trashed: Bool = false, tombstone: Bool = false) {
        self.itemIdentifier = itemIdentifier; self.remoteID = remoteID; self.parentIdentifier = parentIdentifier; self.trashOriginalParentIdentifier = trashOriginalParentIdentifier; self.name = name; self.uri = uri; self.kind = kind; self.contentType = contentType; self.size = size; self.remoteVersion = remoteVersion; self.version = version; self.creationDate = creationDate; self.contentModificationDate = contentModificationDate; self.canRead = canRead; self.canWrite = canWrite; self.canAddChildren = canAddChildren; self.canTrash = canTrash; self.canDelete = canDelete; self.trashed = trashed; self.tombstone = tombstone
    }

    public func withIdentity(_ identifier: String, parentIdentifier: String? = nil) -> RemoteItem {
        RemoteItem(itemIdentifier: identifier, remoteID: remoteID, parentIdentifier: parentIdentifier ?? self.parentIdentifier, name: name, uri: uri, kind: kind, contentType: contentType, size: size, remoteVersion: remoteVersion, version: version, creationDate: creationDate, contentModificationDate: contentModificationDate, trashOriginalParentIdentifier: trashOriginalParentIdentifier, canRead: canRead, canWrite: canWrite, canAddChildren: canAddChildren, canTrash: canTrash, canDelete: canDelete, trashed: trashed, tombstone: tombstone)
    }
}

public enum VersionHasher {
    public static func digest(_ parts: [Data]) -> Data {
        var input = Data()
        for part in parts {
            var length = UInt64(part.count).bigEndian
            input.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
            input.append(part)
        }
        return Data(SHA256.hash(data: input))
    }

    public static func content(primaryEntity: String) -> Data { digest([Data(primaryEntity.utf8)]) }
    public static func metadata(parent: String?, name: String, kind: RemoteItemKind, permissionBits: UInt64, revision: String?) -> Data {
        let parentData = parent.map { Data($0.utf8) } ?? Data()
        let revisionData = revision.map { Data($0.utf8) } ?? Data()
        return digest([parentData, Data(name.utf8), Data(kind.rawValue.utf8), Data(String(permissionBits).utf8), revisionData])
    }
}

public struct PageToken: Codable, Equatable, Sendable {
    public let version: UInt8
    public let domainIdentifier: String
    public let parentIdentifier: String
    public let snapshotGeneration: UInt64
    public let offset: Int
    public let sort: String

    public init(domainIdentifier: String, parentIdentifier: String, snapshotGeneration: UInt64, offset: Int, sort: String = "name") {
        self.version = 1; self.domainIdentifier = domainIdentifier; self.parentIdentifier = parentIdentifier; self.snapshotGeneration = snapshotGeneration; self.offset = offset; self.sort = sort
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        let result = data.base64EncodedString().data(using: .utf8)!
        guard result.count < 500 else { throw CloudreveIdentifierError.sensitiveValue }
        return result
    }

    public static func decode(_ data: Data) throws -> PageToken { try JSONDecoder().decode(PageToken.self, from: Data(base64Encoded: data) ?? Data()) }
}

public struct SyncAnchor: Codable, Equatable, Sendable {
    public let version: UInt8
    public let domainIdentifier: String
    public let scope: String
    public let epoch: UUID
    public let sequence: UInt64

    public init(domainIdentifier: String, scope: String, epoch: UUID, sequence: UInt64) { self.version = 1; self.domainIdentifier = domainIdentifier; self.scope = scope; self.epoch = epoch; self.sequence = sequence }
    public func encoded() throws -> Data {
        let encoded = try JSONEncoder().encode(self).base64EncodedData()
        guard encoded.count < 500 else { throw CloudreveIdentifierError.sensitiveValue }
        return encoded
    }
    public static func decode(_ data: Data) throws -> SyncAnchor { try JSONDecoder().decode(SyncAnchor.self, from: Data(base64Encoded: data) ?? Data()) }
}

public enum DomainStatus: String, Codable, Sendable {
    case initializing, healthy, syncing, reconciling, offline, eventDegraded = "event_degraded", appNotRunning = "app_not_running", authExpired = "auth_expired", rootUnavailable = "root_unavailable", scopeConflict = "scope_conflict", conflict, permanentError = "permanent_error", removalPreflight = "removal_preflight", repairRequired = "repair_required"
}

public struct HealthInputs: Equatable, Sendable {
    public var authenticated = false
    public var rootAvailable = false
    public var scopeValid = false
    public var hasConflict = false
    public var hasPermanentError = false
    public var offline = false
    public var reconciling = false
    public var syncing = false
    public var eventDegraded = false
    public var appRunning = false
    public var validAnchor = false
    public var recentlyReconciled = false
    public init() {}
}

public enum DomainHealthReducer {
    public static func reduce(_ input: HealthInputs) -> DomainStatus {
        if !input.authenticated { return .authExpired }
        if !input.rootAvailable { return .rootUnavailable }
        if !input.scopeValid { return .scopeConflict }
        if input.hasConflict { return .conflict }
        if input.hasPermanentError { return .permanentError }
        if input.offline { return .offline }
        if input.reconciling { return .reconciling }
        if input.syncing { return .syncing }
        if input.eventDegraded { return .eventDegraded }
        if !input.appRunning { return .appNotRunning }
        return input.validAnchor && input.recentlyReconciled ? .healthy : .reconciling
    }
}

public struct DomainDescriptor: Codable, Equatable, Sendable {
    public let identifier: String
    public var displayName: String
    public var iconURL: URL?
    public let scope: RemoteScope
    public let rootRemoteID: String
    public var currentRootURI: String
    public var accountID: String
    public var status: DomainStatus
    public var capabilitySnapshot: CapabilitySnapshot
    public var secretReference: String

    public init(identifier: String = CloudreveIdentifier.domain(), displayName: String, scope: RemoteScope, rootRemoteID: String, accountID: String, secretReference: String, capabilitySnapshot: CapabilitySnapshot = CapabilitySnapshot(), iconURL: URL? = nil) {
        self.identifier = identifier; self.displayName = displayName; self.iconURL = iconURL; self.scope = scope; self.rootRemoteID = rootRemoteID; self.currentRootURI = scope.rootURI; self.accountID = accountID; self.status = .initializing; self.capabilitySnapshot = capabilitySnapshot; self.secretReference = secretReference
    }
}

public enum CoreErrorCode: String, Codable, Sendable {
    case authentication, network, permissionDenied = "permission_denied", notFound = "not_found", quotaExceeded = "quota_exceeded", versionConflict = "version_conflict", nameCollision = "name_collision", invalidName = "invalid_name", integrityFailure = "integrity_failure", cancelled, unsupportedServer = "unsupported_server", database, unsupportedMetadata = "unsupported_metadata", rootUnavailable = "root_unavailable", scopeConflict = "scope_conflict", unknownOutcome = "unknown_outcome", awaitingSourceReplay = "awaiting_source_replay", excludedFromSync = "excluded_from_sync", directoryNotEmpty = "directory_not_empty", cannotSynchronize = "cannot_synchronize"
}

public struct CoreFailure: Error, Equatable, Sendable {
    public let code: CoreErrorCode
    public let retryable: Bool
    public let userActionRequired: Bool
    public let correlationID: UUID
    public let redactedContext: [String: String]
    public init(code: CoreErrorCode, retryable: Bool, userActionRequired: Bool = false, correlationID: UUID = UUID(), redactedContext: [String: String] = [:]) { self.code = code; self.retryable = retryable; self.userActionRequired = userActionRequired; self.correlationID = correlationID; self.redactedContext = redactedContext }
}

public enum DomainRemovalDecision: Equatable, Sendable {
    case safe
    case preserveDirtyData
    case blocked(reason: String)
}

public struct DomainRemovalPreflight: Sendable {
    public static func decide(hasDirtyWork: Bool, pendingSetReliable: Bool, waitForChangesSucceeded: Bool) -> DomainRemovalDecision {
        if hasDirtyWork || !pendingSetReliable || !waitForChangesSucceeded { return .preserveDirtyData }
        return .safe
    }
}
