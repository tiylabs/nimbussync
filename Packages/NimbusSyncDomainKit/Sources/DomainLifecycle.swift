import Foundation
import FileProvider

public enum DomainLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier
    case overlappingScope
    case notFound
    case dirtyData
    case system(ErrorDescription)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "The File Provider domain identifier is invalid."
        case .overlappingScope:
            "This Cloudreve location overlaps an existing location."
        case .notFound:
            "The File Provider domain could not be found."
        case .dirtyData:
            "Local changes must be preserved before this domain can be removed."
        case let .system(description):
            description.userMessage
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case .invalidIdentifier:
            "invalid_domain_identifier"
        case .overlappingScope:
            "overlapping_scope"
        case .notFound:
            "domain_not_found"
        case .dirtyData:
            "dirty_data"
        case let .system(description):
            description.diagnosticDescription
        }
    }
}

private final class CallbackTimeoutGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func fail(_ error: DomainLifecycleError) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

private func withCallbackTimeout<Value: Sendable>(
    seconds: TimeInterval = 30,
    operation: (@escaping @Sendable (Result<Value, DomainLifecycleError>) -> Void) -> Void
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let gate = CallbackTimeoutGate(continuation)
        operation { result in
            switch result {
            case let .success(value): gate.succeed(value)
            case let .failure(error): gate.fail(error)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            gate.fail(.system(ErrorDescription("File Provider request timed out")))
        }
    }
}

public struct ErrorDescription: Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let domain: String?
    public let code: Int?

    public init(_ message: String, domain: String? = nil, code: Int? = nil) {
        self.message = message
        self.domain = domain
        self.code = code
    }

    public var description: String { diagnosticDescription }

    public var diagnosticDescription: String {
        guard let domain else { return "file_provider_request_failed" }
        if let code { return "file_provider_error:\(domain):\(code)" }
        return "file_provider_error:\(domain)"
    }

    public var userMessage: String {
        guard let domain, let code else {
            return "The File Provider service could not complete this request."
        }

        if domain == "NSFileProviderErrorDomain" {
            switch code {
            case -2001:
                return "NimbusSync's File Provider extension is unavailable. Quit and reopen NimbusSync, then try again."
            case -2002:
                return "macOS disabled the File Provider extension because NimbusSync is running from a translocated location. Move NimbusSync to Applications and reopen it."
            case -2003:
                return "An older NimbusSync File Provider extension is still running. Quit and reopen NimbusSync, then try again."
            case -2004:
                return "A newer NimbusSync File Provider extension is already installed. Update NimbusSync and try again."
            case -2011:
                return "This File Provider domain is disabled in System Settings. Enable NimbusSync under File Providers, then try again."
            case -2012:
                return "The File Provider service is temporarily unavailable. Try again in a moment."
            case -2014:
                return "NimbusSync's File Provider extension is missing from the app bundle. Reinstall NimbusSync and try again."
            default:
                break
            }
        }

        if domain == "NSFileProviderInternalErrorDomain", code == 12 {
            return "This File Provider domain is disabled in System Settings. Enable NimbusSync under File Providers, then try again."
        }

        if domain == "NSCocoaErrorDomain", code == 513 {
            return "The File Provider document storage is not writable. Check the app's permissions and try again."
        }

        if domain == "NSCocoaErrorDomain", code == 516 || (domain == "NSPOSIXErrorDomain" && code == 17) {
            return "A previous NimbusSync Finder location is still registered on this Mac. Remove the old location in System Settings > General > Login Items & Extensions > File Providers, then try again."
        }

        return "The File Provider service rejected this request. Check System Settings > General > Login Items & Extensions > File Providers, then try again."
    }
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
        try await withCallbackTimeout { (complete: @escaping @Sendable (Result<Void, DomainLifecycleError>) -> Void) in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    let nsError = error as NSError
                    complete(.failure(.system(ErrorDescription(error.localizedDescription, domain: nsError.domain, code: nsError.code))))
                }
                else { complete(.success(())) }
            }
        }
    }

    public func registeredDomains() async throws -> [RegisteredDomainSnapshot] {
        try await withCallbackTimeout { (complete: @escaping @Sendable (Result<[RegisteredDomainSnapshot], DomainLifecycleError>) -> Void) in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    let nsError = error as NSError
                    complete(.failure(.system(ErrorDescription(error.localizedDescription, domain: nsError.domain, code: nsError.code))))
                }
                else { complete(.success(domains.map { RegisteredDomainSnapshot(identifier: $0.identifier.rawValue, displayName: $0.displayName) })) }
            }
        }
    }

    public func systemDomainExists(_ identifier: String) async throws -> Bool {
        let domains = try await registeredDomains()
        return domains.contains { $0.identifier == identifier }
    }

    public func waitForChanges(below domain: NSFileProviderDomain) async throws -> Bool {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw DomainLifecycleError.system(ErrorDescription("File Provider manager is unavailable"))
        }
        return try await withCallbackTimeout(seconds: 15) { (complete: @escaping @Sendable (Result<Bool, DomainLifecycleError>) -> Void) in
            manager.waitForChanges(below: .rootContainer) { error in
                if let error {
                    let nsError = error as NSError
                    complete(.failure(.system(ErrorDescription(error.localizedDescription, domain: nsError.domain, code: nsError.code))))
                }
                else { complete(.success(true)) }
            }
        }
    }

    public func remove(_ domain: NSFileProviderDomain, preserveDirtyData: Bool) async throws -> URL? {
        if #available(macOS 14.0, *), preserveDirtyData {
            return try await withCallbackTimeout { (complete: @escaping @Sendable (Result<URL?, DomainLifecycleError>) -> Void) in
                NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) { location, error in
                    if let error {
                        let nsError = error as NSError
                        complete(.failure(.system(ErrorDescription(error.localizedDescription, domain: nsError.domain, code: nsError.code))))
                    }
                    else { complete(.success(location)) }
                }
            }
        }
        if preserveDirtyData { throw DomainLifecycleError.dirtyData }
        try await withCallbackTimeout { (complete: @escaping @Sendable (Result<Void, DomainLifecycleError>) -> Void) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    let nsError = error as NSError
                    complete(.failure(.system(ErrorDescription(error.localizedDescription, domain: nsError.domain, code: nsError.code))))
                }
                else { complete(.success(())) }
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
