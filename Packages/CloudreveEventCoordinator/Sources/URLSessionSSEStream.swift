import Foundation
import CloudreveAuthKit
import CloudreveDomainKit

/// URLSession-backed SSE stream. The Authorization header is attached only to
/// the configured Cloudreve origin; signed storage URLs are never used here.
public final class URLSessionSSEStream: EventStream, @unchecked Sendable {
    private let state: SSEStreamState

    public init(origin: URL, uri: String, clientID: String, vault: CredentialVault, credentialReference: String) {
        self.state = SSEStreamState(origin: origin, uri: uri, clientID: clientID, vault: vault, credentialReference: credentialReference)
    }

    public func next() async throws -> SSEEvent? {
        try await state.next()
    }
}

private actor SSEStreamState {
    private let origin: URL
    private let uri: String
    private let clientID: String
    private let vault: CredentialVault
    private let credentialReference: String
    private let channel = AsyncStreamChannel()
    private var started = false

    init(origin: URL, uri: String, clientID: String, vault: CredentialVault, credentialReference: String) {
        self.origin = origin; self.uri = uri; self.clientID = clientID; self.vault = vault; self.credentialReference = credentialReference
    }

    func next() async throws -> SSEEvent? {
        if !started { started = true; start() }
        return try await channel.next()
    }

    private func start() {
        let channel = self.channel
        Task {
                do {
                    guard let credential = try vault.read(reference: credentialReference) else { throw CoreFailure(code: .authentication, retryable: false, userActionRequired: true) }
                    var components = URLComponents(url: origin.appendingPathComponent("api/v4/file/events"), resolvingAgainstBaseURL: false)
                    components?.queryItems = [URLQueryItem(name: "uri", value: uri)]
                    guard let url = components?.url else { throw CoreFailure(code: .network, retryable: false) }
                    var request = URLRequest(url: url, timeoutInterval: 60)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(clientID, forHTTPHeaderField: "X-Cr-Client-Id")
                    request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else { throw CoreFailure(code: .network, retryable: true) }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        let events = try parser.append(Data((line + "\n").utf8))
                        for event in events { await channel.yield(event) }
                    }
                    for event in try parser.finish() { await channel.yield(event) }
                    await channel.finish()
                } catch {
                    await channel.finish(error)
                }
        }
    }
}

private actor AsyncStreamChannel {
    private var values: [SSEEvent] = []
    private var waiter: CheckedContinuation<SSEEvent?, Error>?
    private var finished = false
    private var failure: Error?

    func yield(_ value: SSEEvent) {
        if let waiter { self.waiter = nil; waiter.resume(returning: value) } else { values.append(value) }
    }
    func finish(_ error: Error? = nil) {
        finished = true; failure = error
        if let waiter { self.waiter = nil; if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) } }
    }
    func next() async throws -> SSEEvent? {
        if !values.isEmpty { return values.removeFirst() }
        if let failure { throw failure }
        if finished { return nil }
        return try await withCheckedThrowingContinuation { continuation in waiter = continuation }
    }
}
