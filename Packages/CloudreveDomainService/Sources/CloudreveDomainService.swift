import Foundation
import FileProvider
import CloudreveDomainKit
import CloudreveStoreBridge
import CloudreveAuthKit

public enum DomainProvisioningError: Error, Equatable {
    case overlappingScope
    case accountMismatch
    case rootUnavailable
    case system(String)
    case rollbackRequired(String)
}

public struct VerifiedDomainIdentity: Equatable, Sendable {
    public let accountID: String
    public let rootRemoteID: String
    public let rootURI: String
    public init(accountID: String, rootRemoteID: String, rootURI: String) { self.accountID = accountID; self.rootRemoteID = rootRemoteID; self.rootURI = rootURI }
}

public actor DomainRegistryService {
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let lifecycle: DomainLifecycleService
    private let scopeGuard: ScopeGuard

    public init(store: SQLiteStateStore, vault: CredentialVault, lifecycle: DomainLifecycleService = DomainLifecycleService(), scopeGuard: ScopeGuard = ScopeGuard()) {
        self.store = store; self.vault = vault; self.lifecycle = lifecycle; self.scopeGuard = scopeGuard
    }

    public func provision(displayName: String, scope: RemoteScope, credential: Credential, capabilitySnapshot: CapabilitySnapshot, resolveIdentity: @Sendable () async throws -> VerifiedDomainIdentity, firstRead: @Sendable () async throws -> Void) async throws -> DomainDescriptor {
        let identity = try await resolveIdentity()
        guard identity.accountID == scope.accountID else { throw DomainProvisioningError.accountMismatch }
        guard !identity.rootRemoteID.isEmpty else { throw DomainProvisioningError.rootUnavailable }
        let verifiedScope = try RemoteScope(origin: scope.origin, accountID: identity.accountID, rootURI: identity.rootURI)
        let existing = try store.allDomains().compactMap { stored -> DomainDescriptor? in
            guard let oldScope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return nil }
            let descriptor = try? DomainDescriptor(displayName: stored.displayName, scope: oldScope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot)
            return descriptor
        }
        try scopeGuard.validate(newScope: verifiedScope, existing: existing)
        let descriptor = DomainDescriptor(displayName: displayName, scope: verifiedScope, rootRemoteID: identity.rootRemoteID, accountID: identity.accountID, secretReference: "credential-\(UUID().uuidString)", capabilitySnapshot: capabilitySnapshot)
        try store.beginProvisioning(domainID: descriptor.identifier)
        do {
            try vault.write(credential, reference: descriptor.secretReference)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .credentialWritten)
            try store.registerDomain(descriptor)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .domainDatabaseReady)
            let systemDomain = try lifecycle.makeSystemDomain(for: descriptor, trashEnabled: false)
            try await lifecycle.add(systemDomain)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .systemDomainAdded)
            try await firstRead()
            try store.setDomainStatus(identifier: descriptor.identifier, status: .healthy)
            try store.advanceProvisioning(domainID: descriptor.identifier, step: .firstReadHealthy)
            try store.finishProvisioning(domainID: descriptor.identifier)
            return descriptor
        } catch {
            try? store.advanceProvisioning(domainID: descriptor.identifier, step: .rollbackRequired, error: String(describing: error))
            try? store.setDomainStatus(identifier: descriptor.identifier, status: .repairRequired)
            throw DomainProvisioningError.rollbackRequired(String(describing: error))
        }
    }

    public func recoverProvisioning() async {
        guard let records = try? store.incompleteProvisioning() else { return }
        guard let domains = try? await lifecycle.registeredDomains() else { return }
        let systemIDs = Set(domains.map(\.identifier))
        for record in records {
            let next = DomainProvisioningReducer.recover(record: record, systemDomainExists: systemIDs.contains(record.domainID))
            try? store.advanceProvisioning(domainID: record.domainID, step: next)
            if next == .rollbackRequired { try? store.setDomainStatus(identifier: record.domainID, status: .repairRequired) }
        }
    }

    public func descriptors() throws -> [DomainDescriptor] {
        try store.allDomains().compactMap { stored in
            guard let scope = try? RemoteScope(origin: stored.origin, accountID: stored.accountID, rootURI: stored.rootURI) else { return nil }
            var descriptor = try? DomainDescriptor(displayName: stored.displayName, scope: scope, rootRemoteID: stored.rootRemoteID, accountID: stored.accountID, secretReference: stored.secretReference, capabilitySnapshot: stored.capabilitySnapshot)
            descriptor?.status = stored.status
            return descriptor
        }
    }
}

public actor SafeDomainRemovalService {
    private let store: SQLiteStateStore
    private let vault: CredentialVault
    private let lifecycle: DomainLifecycleService

    public init(store: SQLiteStateStore, vault: CredentialVault, lifecycle: DomainLifecycleService = DomainLifecycleService()) { self.store = store; self.vault = vault; self.lifecycle = lifecycle }

    public func remove(descriptor: DomainDescriptor) async throws -> URL? {
        let domain = try lifecycle.makeSystemDomain(for: descriptor, trashEnabled: false)
        try store.setDomainStatus(identifier: descriptor.identifier, status: .removalPreflight)
        let manager = NSFileProviderManager(for: domain)
        let waitSucceeded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            manager?.waitForChanges(below: .rootContainer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: true) }
            }
        }
        let pending = try store.pendingSetState()
        let decision = DomainRemovalPolicy().decision(hasDirtyOperations: try store.hasDirtyWork(), pendingSetReliable: !pending.capped, waitForChangesSucceeded: waitSucceeded)
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
        return preserved
    }
}
