import Foundation
import Security
import Darwin
import AppKit
import CryptoKit
import OSLog
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
    public static func current(suffix: String = "ai.tiylabs.nimbussync") -> String? {
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
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "NimbusSync.TransferSecret", kSecAttrAccount: reference, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVaultError.unexpectedStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw CredentialVaultError.invalidData }
        return value
    }

    public func writeSecret(_ secret: String, reference: String) throws {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "NimbusSync.TransferSecret", kSecAttrAccount: reference]
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
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "NimbusSync.TransferSecret", kSecAttrAccount: reference]
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
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "NimbusSync.Credential", kSecAttrAccount: reference, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
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
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "NimbusSync.Credential", kSecAttrAccount: reference]
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
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "NimbusSync.Credential", kSecAttrAccount: reference]
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
    public let remotePath: String?
    public let accountIDHint: String?
    public let displayNameHint: String?
    public init(code: String, state: String, host: String, path: String, remotePath: String? = nil, accountIDHint: String? = nil, displayNameHint: String? = nil) {
        self.code = code; self.state = state; self.host = host; self.path = path; self.remotePath = remotePath; self.accountIDHint = accountIDHint; self.displayNameHint = displayNameHint
    }
}

public struct CloudreveOAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String
    public let scope: String
    public let redirectURI: String
    public init(clientID: String = "393a1839-f52e-498e-9972-e77cc2241eee", clientSecret: String = "8GaQIu3lOSdqYoDHi9cR8IZ4pvuMH8ya", scope: String = "profile email openid offline_access UserInfo.Write Workflow.Write Files.Write Shares.Write", redirectURI: String = "/callback/desktop") {
        self.clientID = clientID; self.clientSecret = clientSecret; self.scope = scope; self.redirectURI = redirectURI
    }
}

public final class OAuthCoordinator: @unchecked Sendable {
    public let redirectScheme: String
    public let redirectHost: String
    public let redirectPath: String
    private var expectedState: String?
    private let lock = NSLock()

    public init(redirectScheme: String = "cloudreve", redirectHost: String = "mount", redirectPath: String = "") { self.redirectScheme = redirectScheme; self.redirectHost = redirectHost; self.redirectPath = redirectPath }

    public func begin() -> (state: String, verifier: String) {
        let state = randomToken()
        let verifier = randomToken(length: 64)
        lock.lock(); expectedState = state; lock.unlock()
        return (state, verifier)
    }

    public func pkceChallenge(verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString
    }

    public func authorizationURL(origin: URL, state: String, verifier: String, configuration: CloudreveOAuthConfiguration = CloudreveOAuthConfiguration()) throws -> URL {
        var components = URLComponents(url: origin.appendingPathComponent("session/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkceChallenge(verifier: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        return url
    }

    public func matchesCallbackEndpoint(_ url: URL) -> Bool {
        guard url.scheme == redirectScheme else { return false }
        if url.host == redirectHost, url.path == redirectPath { return true }
        return redirectScheme == "cloudreve" && url.host == "callback" && url.path == "/desktop"
    }

    public func validate(url: URL) throws -> OAuthCallback {
        guard matchesCallbackEndpoint(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let query = components.queryItems, let code = query.first(where: { $0.name == "code" })?.value, let state = query.first(where: { $0.name == "state" })?.value else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        lock.lock(); let expected = expectedState; expectedState = nil; lock.unlock()
        guard expected == state else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        return OAuthCallback(code: code, state: state, host: url.host ?? "", path: url.path, remotePath: query.first(where: { $0.name == "path" })?.value, accountIDHint: query.first(where: { $0.name == "user_id" })?.value, displayNameHint: query.first(where: { $0.name == "name" })?.value)
    }
}

public struct OAuthAuthorizationResult: Sendable, Equatable {
    public let callback: OAuthCallback
    public let verifier: String
    public init(callback: OAuthCallback, verifier: String) { self.callback = callback; self.verifier = verifier }
}

public enum OAuthAuthorizationSessionError: Error, Equatable, LocalizedError {
    case authorizationInProgress
    case browserOpenFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .authorizationInProgress: "An authorization request is already in progress."
        case .browserOpenFailed: "The default browser could not be opened."
        case .cancelled: "Authorization was cancelled."
        }
    }
}

@MainActor
public final class OAuthAuthorizationSession {
    private struct PendingAuthorization {
        let correlation: String
        let verifier: String
        let continuation: CheckedContinuation<OAuthAuthorizationResult, Error>
    }

    private let coordinator: OAuthCoordinator
    private let configuration: CloudreveOAuthConfiguration
    private let openURL: @MainActor @Sendable (URL) -> Bool
    private let logger = Logger(subsystem: "ai.tiylabs.nimbussync", category: "oauth")
    private var pending: PendingAuthorization?

    public init(coordinator: OAuthCoordinator = OAuthCoordinator(), configuration: CloudreveOAuthConfiguration = CloudreveOAuthConfiguration(), openURL: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.coordinator = coordinator; self.configuration = configuration; self.openURL = openURL
    }

    public func authorize(origin: URL, correlationID: UUID = UUID()) async throws -> OAuthAuthorizationResult {
        guard pending == nil else { throw OAuthAuthorizationSessionError.authorizationInProgress }
        let transaction = coordinator.begin()
        let url = try coordinator.authorizationURL(origin: origin, state: transaction.state, verifier: transaction.verifier, configuration: configuration)
        let correlation = correlationID.uuidString.lowercased()
        let originScheme = origin.scheme ?? "unknown"
        let callbackScheme = coordinator.redirectScheme
        let callbackHost = coordinator.redirectHost
        let callbackPath = coordinator.redirectPath
        logger.info("[\(correlation, privacy: .public)] oauth.authorization.started presentation=external_browser origin_scheme=\(originScheme, privacy: .public) callback_scheme=\(callbackScheme, privacy: .public) callback_host=\(callbackHost, privacy: .public) callback_path=\(callbackPath, privacy: .public)")
        return try await withCheckedThrowingContinuation { continuation in
            pending = PendingAuthorization(correlation: correlation, verifier: transaction.verifier, continuation: continuation)
            guard openURL(url) else {
                pending = nil
                logger.error("[\(correlation, privacy: .public)] oauth.authorization.failed_to_start")
                continuation.resume(throwing: OAuthAuthorizationSessionError.browserOpenFailed)
                return
            }
            logger.info("[\(correlation, privacy: .public)] oauth.authorization.waiting_for_callback expected_scheme=\(callbackScheme, privacy: .public)")
        }
    }

    @discardableResult
    public func receiveCallback(_ url: URL) -> Bool {
        guard coordinator.matchesCallbackEndpoint(url) else { return false }
        guard let pending else {
            logger.warning("oauth.callback.ignored reason=no_pending_authorization")
            return true
        }

        self.pending = nil
        let actualScheme = url.scheme ?? "missing"
        let actualHost = url.host ?? "missing"
        logger.info("[\(pending.correlation, privacy: .public)] oauth.callback.received scheme=\(actualScheme, privacy: .public) host=\(actualHost, privacy: .public) path=\(url.path, privacy: .public)")
        do {
            let callback = try coordinator.validate(url: url)
            logger.info("[\(pending.correlation, privacy: .public)] oauth.callback.validated remote_path_present=\(callback.remotePath != nil, privacy: .public) account_hint_present=\(callback.accountIDHint != nil, privacy: .public)")
            pending.continuation.resume(returning: OAuthAuthorizationResult(callback: callback, verifier: pending.verifier))
        } catch {
            let nsError = error as NSError
            logger.error("[\(pending.correlation, privacy: .public)] oauth.callback.rejected error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)")
            pending.continuation.resume(throwing: error)
        }
        return true
    }

    public func cancel() {
        guard let pending else { return }
        self.pending = nil
        logger.info("[\(pending.correlation, privacy: .public)] oauth.authorization.cancel_requested")
        pending.continuation.resume(throwing: OAuthAuthorizationSessionError.cancelled)
    }
}

public final class OAuthTokenExchange: @unchecked Sendable {
    private let session: URLSession
    private let configuration: CloudreveOAuthConfiguration
    private let logger = Logger(subsystem: "ai.tiylabs.nimbussync", category: "oauth")
    public init(session: URLSession? = nil, configuration: CloudreveOAuthConfiguration = CloudreveOAuthConfiguration()) {
        if let session { self.session = session }
        else { self.session = URLSession(configuration: .ephemeral, delegate: SameOriginRedirectPolicy(), delegateQueue: nil) }
        self.configuration = configuration
    }

    public func exchange(origin: URL, callback: OAuthCallback, verifier: String, now: Date = Date(), correlationID: UUID = UUID()) async throws -> Credential {
        let correlation = correlationID.uuidString.lowercased()
        logger.info("[\(correlation, privacy: .public)] oauth.token_exchange.started")
        let url = origin.appendingPathComponent("api/v4/session/oauth/token")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "client_secret", value: configuration.clientSecret),
            URLQueryItem(name: "code", value: callback.code),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logger.error("[\(correlation, privacy: .public)] oauth.token_exchange.non_http_response")
            throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
        }
        logger.info("[\(correlation, privacy: .public)] oauth.token_exchange.response status=\(http.statusCode, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        let token = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard !token.accessToken.isEmpty, !token.refreshToken.isEmpty, token.expiresIn > 0 else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        logger.info("[\(correlation, privacy: .public)] oauth.token_exchange.succeeded")
        return Credential(accessToken: token.accessToken, refreshToken: token.refreshToken, accessExpiry: now.addingTimeInterval(TimeInterval(token.expiresIn)), refreshExpiry: token.refreshTokenExpiresIn.map { now.addingTimeInterval(TimeInterval($0)) }, generation: 1)
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
    let refreshTokenExpiresIn: Int64?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token"; case expiresIn = "expires_in"; case refreshTokenExpiresIn = "refresh_token_expires_in" }
}

/// Cloudreve v4 refreshes OAuth credentials through the session refresh API,
/// whose response uses absolute ISO-8601 expiry fields rather than the
/// OAuth-code exchange's relative `expires_in` fields.
public final class OAuthCredentialRefresher: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else { self.session = URLSession(configuration: .ephemeral, delegate: SameOriginRedirectPolicy(), delegateQueue: nil) }
    }

    public func refresh(origin: URL, credential: Credential, now: Date = Date()) async throws -> Credential {
        guard credential.refreshExpiry.map({ $0 > now }) ?? true else {
            throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
        }
        let url = origin.appendingPathComponent("api/v4/session/token/refresh")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": credential.refreshToken])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true)
        }
        let envelope = try JSONDecoder().decode(RefreshEnvelope.self, from: data)
        guard envelope.code == 0, let token = envelope.data,
              !token.accessToken.isEmpty, !token.refreshToken.isEmpty,
              let accessExpiry = parseISO8601(token.accessExpiry),
              let refreshExpiry = parseISO8601(token.refreshExpiry),
              accessExpiry > now else {
            throw RefreshCoordinatorError.unknownOutcome
        }
        return Credential(accessToken: token.accessToken, refreshToken: token.refreshToken, accessExpiry: accessExpiry, refreshExpiry: refreshExpiry, generation: credential.generation + 1)
    }
}

/// Shared entry point used by the App, the File Provider process, and the
/// event/reconciliation workers. The advisory lock is optional for unit-test
/// vaults but is present whenever the App Group is available.
public final class CredentialRefreshService: @unchecked Sendable {
    private let vault: CredentialVault
    private let coordinator: TokenRefreshCoordinator
    private let refresher: OAuthCredentialRefresher

    public init(vault: CredentialVault, lockURL: URL? = AppGroupPaths.registryURL()?.deletingLastPathComponent().appendingPathComponent("credential-refresh.lock"), session: URLSession? = nil) {
        self.vault = vault
        let lock = lockURL.map { AppGroupAdvisoryLock(url: $0) }
        self.coordinator = TokenRefreshCoordinator(vault: vault, lock: lock)
        self.refresher = OAuthCredentialRefresher(session: session)
    }

    public func credential(origin: URL, reference: String, now: Date = Date(), forceRefresh: Bool = false) async throws -> Credential {
        try await coordinator.credential(reference: reference, now: now, forceRefresh: forceRefresh) { [refresher] current in
            try await refresher.refresh(origin: origin, credential: current, now: now)
        }
    }
}

private struct RefreshEnvelope: Decodable {
    let code: Int
    let data: RefreshedToken?
}

private struct RefreshedToken: Decodable {
    let accessToken: String
    let refreshToken: String
    let accessExpiry: String
    let refreshExpiry: String
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accessExpiry = "access_expires"
        case refreshExpiry = "refresh_expires"
    }
}

private func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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

    public func credential(reference: String, now: Date = Date(), forceRefresh: Bool = false, refresh: @Sendable (Credential) async throws -> Credential) async throws -> Credential {
        let observedGeneration = try vault.read(reference: reference)?.generation
        if let crossProcessLock {
            return try await crossProcessLock.withLock { [self] in
                try await refreshInsideLock(reference: reference, now: now, forceRefresh: forceRefresh, observedGeneration: observedGeneration, refresh: refresh)
            }
        }
        return try await refreshInsideLock(reference: reference, now: now, forceRefresh: forceRefresh, observedGeneration: observedGeneration, refresh: refresh)
    }

    private func refreshInsideLock(reference: String, now: Date, forceRefresh: Bool, observedGeneration: UInt64?, refresh: @Sendable (Credential) async throws -> Credential) async throws -> Credential {
        guard var current = try vault.read(reference: reference) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
        if forceRefresh, let observedGeneration, current.generation != observedGeneration { return current }
        if !forceRefresh && current.accessExpiry > now.addingTimeInterval(30) { return current }
        let owner = UUID()
        while let lease = activeLease, lease.expiresAt > Date() {
            try await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { throw CoreFailure(code: .cancelled, retryable: false) }
        }
        if let latest = try vault.read(reference: reference) {
            if forceRefresh && latest.generation != current.generation { return latest }
            current = latest
            if !forceRefresh && current.accessExpiry > Date().addingTimeInterval(30) { return current }
        }
        let lease = RefreshLease(ownerID: owner, generation: current.generation, expiresAt: Date().addingTimeInterval(leaseDuration))
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
        components.scheme = scheme
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.isEmpty ? "/" : "/\(path)"
        components.query = nil
        components.fragment = nil
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
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else { self.session = URLSession(configuration: .ephemeral, delegate: SameOriginRedirectPolicy(), delegateQueue: nil) }
    }

    public func validate(origin rawOrigin: String, allowLoopbackHTTP: Bool = false) async throws -> SiteCheckResult {
        let origin = try SiteOriginValidator.normalize(rawOrigin, allowLoopbackHTTP: allowLoopbackHTTP)
        let url = origin.appendingPathComponent("api/v4/site/ping")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CoreFailure(code: .network, retryable: true) }
        guard (200..<300).contains(response.statusCode) else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        let payload = try? JSONDecoder().decode(SitePingResponse.self, from: data)
        guard payload?.code == 0, let version = payload?.data, !version.isEmpty else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        let normalizedVersion = version.replacingOccurrences(of: "-pro", with: "")
        guard compareVersions(normalizedVersion, minimum: "4.12.0") >= 0 else { throw CoreFailure(code: .unsupportedServer, retryable: false, userActionRequired: true) }
        let manifest = try? await fetchManifest(origin: origin)
        return SiteCheckResult(origin: origin, apiReachable: true, serverVersion: normalizedVersion, title: manifest?.name, iconURL: manifest?.iconURL)
    }

    private func fetchManifest(origin: URL) async throws -> SiteManifestResult {
        let url = origin.appendingPathComponent("manifest.json")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CoreFailure(code: .network, retryable: true) }
        let manifest = try JSONDecoder().decode(SiteManifest.self, from: data)
        let iconURL = manifest.icons.compactMap { icon -> (URL, Int)? in
            guard let url = URL(string: icon.src, relativeTo: origin)?.absoluteURL,
                  url.scheme == origin.scheme,
                  url.host == origin.host,
                  url.port == origin.port else { return nil }
            let size = icon.sizes.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { part -> Int? in
                Int(part.split(separator: "x").first ?? "")
            }.max() ?? 0
            return (url, size)
        }.max { $0.1 < $1.1 }?.0
        return SiteManifestResult(name: manifest.name, iconURL: iconURL)
    }
}

private struct SitePingResponse: Decodable { let code: Int; let data: String; let msg: String? }

private struct SiteManifest: Decodable {
    let name: String?
    let icons: [SiteManifestIcon]
    enum CodingKeys: String, CodingKey { case name; case icons }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        icons = try container.decodeIfPresent([SiteManifestIcon].self, forKey: .icons) ?? []
    }
}

private struct SiteManifestIcon: Decodable {
    let src: String
    let sizes: String
    enum CodingKeys: String, CodingKey { case src; case sizes }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        src = try container.decode(String.self, forKey: .src)
        sizes = try container.decodeIfPresent(String.self, forKey: .sizes) ?? ""
    }
}

private struct SiteManifestResult {
    let name: String?
    let iconURL: URL?
}

private final class SameOriginRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let current = task.currentRequest?.url
        let next = request.url
        guard current?.scheme == next?.scheme, current?.host == next?.host, current?.port == next?.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private func compareVersions(_ left: String, minimum right: String) -> Int {
    let lhs = left.split(separator: ".").map { Int($0) ?? 0 }
    let rhs = right.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(lhs.count, rhs.count) {
        let l = index < lhs.count ? lhs[index] : 0
        let r = index < rhs.count ? rhs[index] : 0
        if l != r { return l < r ? -1 : 1 }
    }
    return 0
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
