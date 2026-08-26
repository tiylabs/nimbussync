import Foundation
import FileProvider

public enum DomainLifecycleError: Error, Equatable {
    case invalidIdentifier
    case overlappingScope
    case notFound
    case dirtyData
    case system(ErrorDescription)
}

public struct ErrorDescription: Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct RegisteredDomainSnapshot: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public init(identifier: String, displayName: String) { self.identifier = identifier; self.displayName = displayName }
}

public enum DomainProvisioningStep: String, Codable, Sendable {
    case prepared
    case credentialWritten = "credential_written"
    case domainDatabaseReady = "domain_db_ready"
    case systemDomainAdded = "system_domain_added"
    case firstReadHealthy = "first_read_healthy"
    case registered
    case rollbackRequired = "rollback_required"
}

public struct DomainProvisioningRecord: Codable, Equatable, Sendable {
    public let actionID: UUID
    public let domainID: String
    public let secretReference: String?
    public var step: DomainProvisioningStep
    public var systemDomainSeen: Bool
    public var errorCode: String?
    public init(actionID: UUID = UUID(), domainID: String, secretReference: String? = nil, step: DomainProvisioningStep = .prepared, systemDomainSeen: Bool = false, errorCode: String? = nil) {
        self.actionID = actionID; self.domainID = domainID; self.secretReference = secretReference; self.step = step; self.systemDomainSeen = systemDomainSeen; self.errorCode = errorCode
    }
}

public enum DomainProvisioningReducer {
    public static func recover(record: DomainProvisioningRecord, systemDomainExists: Bool) -> DomainProvisioningStep {
        if record.step == .registered { return systemDomainExists ? .registered : .rollbackRequired }
        if record.step == .rollbackRequired { return .rollbackRequired }
        if !systemDomainExists {
            return .rollbackRequired
        }
        if systemDomainExists { return record.step == .firstReadHealthy ? .registered : .systemDomainAdded }
        return .rollbackRequired
    }
}

public struct ScopeGuard: Sendable {
    public init() {}
    public func validate(newScope: RemoteScope, existing: [DomainDescriptor]) throws {
        guard !existing.contains(where: { $0.scope.overlaps(newScope) }) else { throw DomainLifecycleError.overlappingScope }
    }
}

public final class DomainLifecycleService: @unchecked Sendable {
    public init() {}

    public func makeSystemDomain(for descriptor: DomainDescriptor, trashEnabled: Bool = false) throws -> NSFileProviderDomain {
        guard CloudreveIdentifier.validate(descriptor.identifier, prefix: CloudreveIdentifier.domainPrefix) else { throw DomainLifecycleError.invalidIdentifier }
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(descriptor.identifier), displayName: descriptor.displayName)
        if #available(macOS 13.0, *) { domain.supportsSyncingTrash = trashEnabled }
        return domain
    }

    public func add(_ domain: NSFileProviderDomain) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error { continuation.resume(throwing: DomainLifecycleError.system(ErrorDescription(error.localizedDescription))) }
                else { continuation.resume() }
            }
        }
    }

    public func registeredDomains() async throws -> [RegisteredDomainSnapshot] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[RegisteredDomainSnapshot], Error>) in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error { continuation.resume(throwing: DomainLifecycleError.system(ErrorDescription(error.localizedDescription))) }
                else { continuation.resume(returning: domains.map { RegisteredDomainSnapshot(identifier: $0.identifier.rawValue, displayName: $0.displayName) }) }
            }
        }
    }

    public func remove(_ domain: NSFileProviderDomain, preserveDirtyData: Bool) async throws -> URL? {
        if #available(macOS 14.0, *), preserveDirtyData {
            return try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) { location, error in
                    if let error { continuation.resume(throwing: DomainLifecycleError.system(ErrorDescription(error.localizedDescription))) }
                    else { continuation.resume(returning: location) }
                }
            }
        }
        if preserveDirtyData { throw DomainLifecycleError.dirtyData }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error { continuation.resume(throwing: DomainLifecycleError.system(ErrorDescription(error.localizedDescription))) }
                else { continuation.resume() }
            }
        }
        return nil
    }
}

public final class DomainStateProjection: NSObject, NSFileProviderDomainState {
    private(set) public var domainVersion: NSFileProviderDomainVersion
    private(set) public var userInfo: [AnyHashable: Any]

    public init(domainVersion: NSFileProviderDomainVersion = NSFileProviderDomainVersion(), authenticated: Bool = false, hasConflict: Bool = false) {
        self.domainVersion = domainVersion
        self.userInfo = ["authenticated": authenticated, "hasConflict": hasConflict]
        super.init()
    }

    public static func load(from url: URL, authenticated: Bool = false, hasConflict: Bool = false) -> DomainStateProjection {
        if let data = try? Data(contentsOf: url), let version = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFileProviderDomainVersion.self, from: data) {
            return DomainStateProjection(domainVersion: version, authenticated: authenticated, hasConflict: hasConflict)
        }
        return DomainStateProjection(authenticated: authenticated, hasConflict: hasConflict)
    }

    public func persist(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: domainVersion, requiringSecureCoding: true)
        try data.write(to: url, options: .atomic)
    }

    public func advance(authenticated: Bool? = nil, hasConflict: Bool? = nil) {
        domainVersion = domainVersion.next()
        var next = userInfo
        if let authenticated { next["authenticated"] = authenticated }
        if let hasConflict { next["hasConflict"] = hasConflict }
        userInfo = next
    }
}

public struct DomainRemovalPolicy: Sendable {
    public init() {}
    public func decision(hasDirtyOperations: Bool, pendingSetReliable: Bool, waitForChangesSucceeded: Bool) -> DomainRemovalDecision {
        if hasDirtyOperations || !pendingSetReliable || !waitForChangesSucceeded { return .preserveDirtyData }
        return .safe
    }
}

public enum AppGroupPaths {
    public static let identifier = "group.ai.tiy.nimbussync"

    public static func root(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static func registryURL(fileManager: FileManager = .default) -> URL? {
        root(fileManager: fileManager)?.appendingPathComponent("Registry/registry.sqlite3")
    }

    public static func domainURL(_ domainIdentifier: String, fileManager: FileManager = .default) -> URL? {
        guard CloudreveIdentifier.validate(domainIdentifier, prefix: CloudreveIdentifier.domainPrefix) else { return nil }
        return root(fileManager: fileManager)?.appendingPathComponent("Domains/\(domainIdentifier)/state.sqlite3")
    }

    public static func domainVersionURL(_ domainIdentifier: String, fileManager: FileManager = .default) -> URL? {
        guard CloudreveIdentifier.validate(domainIdentifier, prefix: CloudreveIdentifier.domainPrefix) else { return nil }
        return root(fileManager: fileManager)?.appendingPathComponent("Domains/\(domainIdentifier)/domain-version.archive")
    }

    public static func prepareDomain(_ domainIdentifier: String, fileManager: FileManager = .default) throws -> URL? {
        guard let url = domainURL(domainIdentifier, fileManager: fileManager) else { return nil }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
}
