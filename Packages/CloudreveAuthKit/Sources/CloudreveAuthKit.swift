import Foundation
import Security
import Darwin
import AuthenticationServices
import CryptoKit
import CloudreveDomainKit

public struct Credential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let accessExpiry: Date
    public let refreshExpiry: Date?
    public let generation: UInt64
    public init(accessToken: String, refreshToken: String, accessExpiry: Date, refreshExpiry: Date? = nil, generation: UInt64 = 0) { self.accessToken = accessToken; self.refreshToken = refreshToken; self.accessExpiry = accessExpiry; self.refreshExpiry = refreshExpiry; self.generation = generation }
}

public protocol CredentialVault: Sendable {
    func read(reference: String) throws -> Credential?
    func write(_ credential: Credential, reference: String) throws
    func remove(reference: String) throws
}

public enum CredentialVaultError: Error, Equatable { case unavailable, invalidData, duplicate, unexpectedStatus(OSStatus) }

public enum KeychainAccessGroup {
    public static func current(suffix: String = "com.cloudreve.mac") -> String? {
        guard let task = SecTaskCreateFromSelf(nil), let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] else { return nil }
        return value.first { $0.hasSuffix(suffix) }
    }
}

public protocol OpaqueSecretVault: Sendable {
    func readSecret(reference: String) throws -> String?
    func writeSecret(_ secret: String, reference: String) throws
    func removeSecret(reference: String) throws
}

public final class MemoryOpaqueSecretVault: OpaqueSecretVault, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func readSecret(reference: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return values[reference] }
    public func writeSecret(_ secret: String, reference: String) throws { lock.lock(); values[reference] = secret; lock.unlock() }
    public func removeSecret(reference: String) throws { lock.lock(); values.removeValue(forKey: reference); lock.unlock() }
}

public final class KeychainOpaqueSecretVault: OpaqueSecretVault, @unchecked Sendable {
    private let accessGroup: String?
    public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }

    public func readSecret(reference: String) throws -> String? {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudreveMac.TransferSecret", kSecAttrAccount: reference, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVaultError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw CredentialVaultError.invalidData }
        return value
    }

    public func writeSecret(_ secret: String, reference: String) throws {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudreveMac.TransferSecret", kSecAttrAccount: reference]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        let data = Data(secret.utf8)
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialVaultError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess { throw CredentialVaultError.unexpectedStatus(status) }
    }

    public func removeSecret(reference: String) throws {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudreveMac.TransferSecret", kSecAttrAccount: reference]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVaultError.unexpectedStatus(status) }
    }
}

public enum RefreshCoordinatorError: Error, Equatable {
    case lockTimeout
    case unknownOutcome
    case generationChanged
}

public final class AppGroupAdvisoryLock: @unchecked Sendable {
    private let path: String
    private let timeout: TimeInterval

    public init(url: URL, timeout: TimeInterval = 10) {
        self.path = url.path
        self.timeout = timeout
    }

    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw RefreshCoordinatorError.lockTimeout }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw RefreshCoordinatorError.lockTimeout }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try await body()
    }
}

public final class MemoryCredentialVault: CredentialVault, @unchecked Sendable {
    private var values: [String: Credential] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(reference: String) throws -> Credential? { lock.lock(); defer { lock.unlock() }; return values[reference] }
    public func write(_ credential: Credential, reference: String) throws { lock.lock(); values[reference] = credential; lock.unlock() }
    public func remove(reference: String) throws { lock.lock(); values.removeValue(forKey: reference); lock.unlock() }
}

public final class KeychainCredentialVault: CredentialVault, @unchecked Sendable {
    private let accessGroup: String?
    public init(accessGroup: String? = nil) { self.accessGroup = accessGroup }

    public func read(reference: String) throws -> Credential? {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudreveMac.Credential", kSecAttrAccount: reference, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVaultError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw CredentialVaultError.invalidData }
        do { return try JSONDecoder().decode(Credential.self, from: data) } catch { throw CredentialVaultError.invalidData }
    }

    public func write(_ credential: Credential, reference: String) throws {
        let data = try JSONEncoder().encode(credential)
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudreveMac.Credential", kSecAttrAccount: reference]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialVaultError.unexpectedStatus(status) }
        } else if updateStatus != errSecSuccess {
            throw CredentialVaultError.unexpectedStatus(updateStatus)
        }
    }

    public func remove(reference: String) throws {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudreveMac.Credential", kSecAttrAccount: reference]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialVaultError.unexpectedStatus(status) }
    }
}

public struct OAuthCallback: Equatable, Sendable {
    public let code: String
    public let state: String
    public let host: String
    public let path: String
    public init(code: String, state: String, host: String, path: String) { self.code = code; self.state = state; self.host = host; self.path = path }
}

public final class OAuthCoordinator: @unchecked Sendable {
    public let redirectHost: String
    public let redirectPath: String
    private var expectedState: String?
    private let lock = NSLock()

    public init(redirectHost: String = "oauth", redirectPath: String = "/callback") { self.redirectHost = redirectHost; self.redirectPath = redirectPath }

    public func begin() -> (state: String, verifier: String) {
        let state = randomToken()
        let verifier = randomToken(length: 64)
        lock.lock(); expectedState = state; lock.unlock()
        return (state, verifier)
    }

    public func pkceChallenge(verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }

    public func validate(url: URL) throws -> OAuthCallback {
        guard url.host == redirectHost, url.path == redirectPath, let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let query = components.queryItems, let code = query.first(where: { $0.name == "code" })?.value, let state = query.first(where: { $0.name == "state" })?.value else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        lock.lock(); let expected = expectedState; expectedState = nil; lock.unlock()
        guard expected == state else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        return OAuthCallback(code: code, state: state, host: url.host ?? "", path: url.path)
    }
}

public struct RefreshLease: Equatable, Sendable {
    public let ownerID: UUID
    public let generation: UInt64
    public let expiresAt: Date
    public init(ownerID: UUID, generation: UInt64, expiresAt: Date) { self.ownerID = ownerID; self.generation = generation; self.expiresAt = expiresAt }
}

public actor TokenRefreshCoordinator {
    private let vault: CredentialVault
    private let crossProcessLock: AppGroupAdvisoryLock?
    private var activeLease: RefreshLease?
    private let leaseDuration: TimeInterval

    public init(vault: CredentialVault, leaseDuration: TimeInterval = 15, lock: AppGroupAdvisoryLock? = nil) { self.vault = vault; self.leaseDuration = leaseDuration; self.crossProcessLock = lock }

    public func credential(reference: String, now: Date = Date(), refresh: @Sendable (Credential) async throws -> Credential) async throws -> Credential {
        if let crossProcessLock {
            return try await crossProcessLock.withLock { [self] in
                try await refreshInsideLock(reference: reference, now: now, refresh: refresh)
            }
        }
        return try await refreshInsideLock(reference: reference, now: now, refresh: refresh)
    }

    private func refreshInsideLock(reference: String, now: Date, refresh: @Sendable (Credential) async throws -> Credential) async throws -> Credential {
        guard let current = try vault.read(reference: reference) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        if current.accessExpiry > now.addingTimeInterval(30) { return current }
        let owner = UUID()
        while let lease = activeLease, lease.expiresAt > now { try await Task.sleep(for: .milliseconds(50)); if Task.isCancelled { throw CoreFailure(code: .cancelled, retryable: false) } }
        let lease = RefreshLease(ownerID: owner, generation: current.generation, expiresAt: now.addingTimeInterval(leaseDuration))
        activeLease = lease
        defer { if activeLease?.ownerID == owner { activeLease = nil } }
        guard activeLease?.ownerID == owner else { throw CoreFailure(code: .unknownOutcome, retryable: false, userActionRequired: true) }
        do {
            let refreshed: Credential
            do {
                refreshed = try await refresh(current)
            } catch let error as RefreshCoordinatorError {
                throw error
            } catch {
                throw RefreshCoordinatorError.unknownOutcome
            }
            guard refreshed.generation > current.generation else { throw CredentialVaultError.invalidData }
            try vault.write(refreshed, reference: reference)
            return refreshed
        } catch {
            if activeLease?.ownerID == owner { activeLease = nil }
            throw error
        }
    }
}

public enum SiteOriginValidator {
    public static func normalize(_ value: String, allowLoopbackHTTP: Bool = false) throws -> URL {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = components.scheme?.lowercased(), let host = components.host, components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard scheme == "https" || (allowLoopbackHTTP && scheme == "http" && loopback) else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        components.scheme = scheme; components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")); components.query = nil; components.fragment = nil
        guard let url = components.url else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        return url
    }
}

public struct SiteCheckResult: Codable, Equatable, Sendable {
    public let origin: URL
    public let apiReachable: Bool
    public let serverVersion: String?
    public let title: String?
    public let iconURL: URL?
    public init(origin: URL, apiReachable: Bool, serverVersion: String?, title: String?, iconURL: URL?) { self.origin = origin; self.apiReachable = apiReachable; self.serverVersion = serverVersion; self.title = title; self.iconURL = iconURL }
}

public final class SiteService: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func validate(origin rawOrigin: String, allowLoopbackHTTP: Bool = false) async throws -> SiteCheckResult {
        let origin = try SiteOriginValidator.normalize(rawOrigin, allowLoopbackHTTP: allowLoopbackHTTP)
        let url = origin.appendingPathComponent("api/v4/site/config/login")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        guard (200..<300).contains(response.statusCode) else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        let payload = try? JSONDecoder().decode(SiteConfigResponse.self, from: data)
        return SiteCheckResult(origin: origin, apiReachable: true, serverVersion: payload?.data?.version, title: payload?.data?.title, iconURL: payload?.data?.icon.flatMap(URL.init(string:)))
    }
}

private struct SiteConfigResponse: Decodable {
    let data: SiteConfigValue?
}

private struct SiteConfigValue: Decodable {
    let version: String?
    let title: String?
    let icon: String?
}

private func randomToken(length: Int = 32) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
    return Data(bytes).base64URLEncodedString
}

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
