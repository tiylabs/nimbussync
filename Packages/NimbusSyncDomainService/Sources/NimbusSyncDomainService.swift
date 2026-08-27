import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit

public enum DomainProvisioningError: Error, Equatable {
    case overlappingScope
    case accountMismatch
    case rootUnavailable
    case invalidDisplayName
    case system(String)
    case rollbackRequired(String)
}

public struct VerifiedDomainIdentity: Equatable, Sendable {
    public let accountID: String
    public let rootRemoteID: String
    public let rootURI: String
    public init(accountID: String, rootRemoteID: String, rootURI: String) { self.accountID = accountID; self.rootRemoteID = rootRemoteID; self.rootURI = rootURI }
}

/// Resolves the untrusted OAuth callback hints through the authenticated
/// Cloudreve API before a Domain is persisted.
public final class CloudreveIdentityResolver: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration, delegate: SameOriginRedirectPolicy(), delegateQueue: nil)
        }
    }

    public func resolve(origin: URL, credential: Credential, rootURI: String) async throws -> VerifiedDomainIdentity {
        let user: UserResponse = try await request(origin: origin, credential: credential, path: "user/me", query: [])
        let root: RemoteRootResponse = try await request(origin: origin, credential: credential, path: "file/info", query: [URLQueryItem(name: "uri", value: rootURI), URLQueryItem(name: "extended", value: "true")])
        guard !user.id.isEmpty, !root.id.isEmpty, root.type == 1 else { throw DomainProvisioningError.rootUnavailable }
        let scope = try RemoteScope(origin: origin.absoluteString, accountID: user.id, rootURI: root.path)
        return VerifiedDomainIdentity(accountID: user.id, rootRemoteID: root.id, rootURI: scope.rootURI)
    }

    public func accountID(origin: URL, credential: Credential) async throws -> String {
        let user: UserResponse = try await request(origin: origin, credential: credential, path: "user/me", query: [])
        guard !user.id.isEmpty else { throw DomainProvisioningError.accountMismatch }
        return user.id
    }

    public func verifyFirstRead(origin: URL, credential: Credential, rootURI: String) async throws {
        let _: RemoteListResponse = try await request(origin: origin, credential: credential, path: "file", query: [URLQueryItem(name: "uri", value: rootURI), URLQueryItem(name: "page_size", value: "1")])
    }

    private func request<Value: Decodable>(origin: URL, credential: Credential, path: String, query: [URLQueryItem]) async throws -> Value {
        var components = URLComponents(url: origin.appendingPathComponent("api/v4").appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { throw CoreFailure(code: .network, retryable: true) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        if http.statusCode == 401 { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        guard (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        let envelope = try JSONDecoder().decode(APIEnvelope<Value>.self, from: data)
        guard envelope.code == 0, let value = envelope.data else { throw CoreFailure(code: .unknownOutcome, retryable: false) }
        return value
    }
}

private struct APIEnvelope<Value: Decodable>: Decodable { let code: Int; let msg: String?; let data: Value? }
private struct UserResponse: Decodable { let id: String }
private struct RemoteRootResponse: Decodable { let type: Int; let id: String; let path: String }
private struct RemoteListResponse: Decodable { let files: [RemoteRootResponse] }

private final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var request = request
        let current = task.currentRequest?.url
        let next = request.url
        if current?.scheme != next?.scheme || current?.host != next?.host || current?.port != next?.port { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(request)
    }
}

public actor DomainRegistryService {
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let lifecycle: DomainLifecycleService
    private let scopeGuard: ScopeGuard
    private let storeFactory: AppGroupStoreFactory?

    public init(store: SQLiteStateStore, vault: CredentialVault, lifecycle: DomainLifecycleService = DomainLifecycleService(), scopeGuard: ScopeGuard = ScopeGuard(), storeFactory: AppGroupStoreFactory? = nil) {
        self.store = store; self.vault = vault; self.lifecycle = lifecycle; self.scopeGuard = scopeGuard; self.storeFactory = storeFactory
    }

    public func provision(displayName: String, scope: RemoteScope, credential: Credential, capabilitySnapshot: CapabilitySnapshot, iconURL: URL? = nil, resolveIdentity: @Sendable () async throws -> VerifiedDomainIdentity, firstRead: @Sendable () async throws -> Void) async throws -> DomainDescriptor {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty,
              normalizedDisplayName.count <= 128,
              !normalizedDisplayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DomainProvisioningError.invalidDisplayName
        }
        let identity = try await resolveIdentity()
        guard identity.accountID == scope.accountID else { throw DomainProvisioningError.accountMismatch }
        guard !identity.rootRemoteID.isEmpty else { throw DomainProvisioningError.rootUnavailable }
        let verifiedScope = try RemoteScope(origin: scope.origin, accountID: identity.accountID, rootURI: identity.rootURI)
        let existing = try store.allDomains().compactMap { stored -> DomainDescriptor? in
            guard let oldScope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return nil }
            return DomainDescriptor(identifier: stored.identifier, displayName: stored.displayName, scope: oldScope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, iconURL: stored.iconURL)
        }
        try scopeGuard.validate(newScope: verifiedScope, existing: existing)
        guard !existing.contains(where: { $0.displayName.caseInsensitiveCompare(normalizedDisplayName) == .orderedSame }) else {
            throw DomainProvisioningError.invalidDisplayName
        }
        let descriptor = DomainDescriptor(displayName: normalizedDisplayName, scope: verifiedScope, rootRemoteID: identity.rootRemoteID, accountID: identity.accountID, secretReference: "credential-\(UUID().uuidString)", capabilitySnapshot: capabilitySnapshot, iconURL: iconURL)
        try store.beginProvisioning(domainID: descriptor.identifier, secretReference: descriptor.secretReference)
        var systemDomainAdded = false
        do {
            try vault.write(credential, reference: descriptor.secretReference)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .credentialWritten)
            let domainStore = try storeFactory?.domainStore(identifier: descriptor.identifier)
            try domainStore?.registerDomain(descriptor)
            try store.registerDomain(descriptor)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .domainDatabaseReady)
            let systemDomain = try lifecycle.makeSystemDomain(for: descriptor, trashEnabled: false)
            try await lifecycle.add(systemDomain)
            systemDomainAdded = true
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .systemDomainAdded)
            try await firstRead()
            try store.setDomainStatus(identifier: descriptor.identifier, status: .healthy)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .firstReadHealthy)
            try store.finishProvisioning(domainID: descriptor.identifier)
            return descriptor
        } catch {
            try? store.advanceProvisioning(domainID: descriptor.identifier, step: .rollbackRequired, error: String(describing: error))
            if !systemDomainAdded {
                try? vault.remove(reference: descriptor.secretReference)
                try? store.removeDomainRecord(identifier: descriptor.identifier)
                try? storeFactory?.removeDomainStore(identifier: descriptor.identifier)
            } else {
                try? store.setDomainStatus(identifier: descriptor.identifier, status: .repairRequired)
            }
            throw DomainProvisioningError.rollbackRequired(String(describing: error))
        }
    }

    public func recoverProvisioning() async {
        guard let records = try? store.incompleteProvisioning() else { return }
        guard let domains = try? await lifecycle.registeredDomains() else { return }
        let systemIDs = Set(domains.map(\.identifier))
        for record in records {
            let next = DomainProvisioningReducer.recover(record: record, systemDomainExists: systemIDs.contains(record.domainID))
            if next == .rollbackRequired {
                let stored: StoredDomain?
                do { stored = try store.domain(identifier: record.domainID) } catch { stored = nil }
                if let stored {
                    if systemIDs.contains(record.domainID) {
                        try? store.setDomainStatus(identifier: record.domainID, status: .repairRequired)
                    } else {
                        try? vault.remove(reference: stored.secretReference)
                        try? store.removeDomainRecord(identifier: record.domainID)
                        try? storeFactory?.removeDomainStore(identifier: record.domainID)
                        try? store.finishProvisioningRollback(domainID: record.domainID)
                    }
                } else {
                    if let secretReference = record.secretReference { try? vault.remove(reference: secretReference) }
                    try? storeFactory?.removeDomainStore(identifier: record.domainID)
                    try? store.finishProvisioningRollback(domainID: record.domainID)
                }
            } else if next == .registered {
                try? store.finishProvisioning(domainID: record.domainID)
                try? store.setDomainStatus(identifier: record.domainID, status: .healthy)
            } else {
                try? store.advanceProvisioning(domainID: record.domainID, step: next)
                if next != .registered { try? store.setDomainStatus(identifier: record.domainID, status: .repairRequired) }
            }
        }
    }

    public func descriptors() throws -> [DomainDescriptor] {
        try store.allDomains().compactMap { stored in
            guard let scope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return nil }
            var descriptor = DomainDescriptor(identifier: stored.identifier, displayName: stored.displayName, scope: scope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot, iconURL: stored.iconURL)
            descriptor.status = stored.status
            return descriptor
        }
    }
}

public actor SafeDomainRemovalService {
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let lifecycle: DomainLifecycleService
    private let storeFactory: AppGroupStoreFactory?

    public init(store: SQLiteStateStore, vault: CredentialVault, lifecycle: DomainLifecycleService = DomainLifecycleService(), storeFactory: AppGroupStoreFactory? = nil) { self.store = store; self.vault = vault; self.lifecycle = lifecycle; self.storeFactory = storeFactory }

    public func remove(descriptor: DomainDescriptor) async throws -> URL? {
        let domain = try lifecycle.makeSystemDomain(for: descriptor, trashEnabled: false)
        let domainStore = try storeFactory?.domainStore(identifier: descriptor.identifier) ?? store
        try domainStore.setDomainStatus(identifier: descriptor.identifier, status: .removalPreflight)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw DomainProvisioningError.system("File Provider manager is unavailable")
        }
        let waitSucceeded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            manager.waitForChanges(below: .rootContainer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: true) }
            }
        }
        let pending = try domainStore.pendingSetState()
        let decision = DomainRemovalPolicy().decision(hasDirtyOperations: try domainStore.hasDirtyWork(), pendingSetReliable: !pending.capped, waitForChangesSucceeded: waitSucceeded)
        guard decision == .safe || decision == .preserveDirtyData else { throw DomainProvisioningError.rollbackRequired("domain removal preflight blocked") }
        let preserve = decision == .preserveDirtyData
        let preserved: URL?
        if #available(macOS 14.0, *) {
            preserved = try await lifecycle.remove(domain, preserveDirtyData: preserve)
        } else if preserve {
            throw DomainProvisioningError.rollbackRequired("preserve dirty data requires macOS 14 or newer")
        } else {
            preserved = try await lifecycle.remove(domain, preserveDirtyData: false)
        }
        try vault.remove(reference: descriptor.secretReference)
        try store.removeDomainRecord(identifier: descriptor.identifier)
        if storeFactory != nil {
            try domainStore.removeDomainRecord(identifier: descriptor.identifier)
            try storeFactory?.removeDomainStore(identifier: descriptor.identifier)
        }
        return preserved
    }
}
